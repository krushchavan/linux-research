---
title: "I/O Controller (blkcg)"
category: concept
tags: [cgroups, io, block-layer, bandwidth, qos, blkcg]
subsystem: cgroups
kernel_version: "2.6.33"
researched: 2026-04-16
status: complete
explained: "[[io-controller-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html
  - https://kernel-internals.org/sched/cpu-cgroup/
  - https://lwn.net/Articles/679786/
---

# I/O Controller (blkcg)

> 📘 Plain-language version: [[io-controller-explained]]

## Purpose

The I/O controller limits and accounts for block device bandwidth and IOPS consumed by cgroup trees. Without it, a single container doing heavy I/O can saturate a shared disk and starve all other containers of storage access. It provides three complementary mechanisms: hard BPS/IOPS limits (`io.max`), proportional weight scheduling (`io.weight` via iocost), and latency protection (`io.latency`).

## Mental Model

Think of a shared highway with toll booths. `io.max` is a hard speed limit: a vehicle exceeding it is forced to wait. `io.weight` is the number of lanes assigned to each group: a group with twice the weight gets twice as many lanes when the highway is congested. `io.latency` is a protected carpool lane: if a cgroup's vehicles are being delayed, other groups give way to keep the lane flowing.

## How It Works

### Data model

The I/O controller introduces two per-cgroup structures. `struct blkcg` (one per cgroup) is the controller's top-level per-cgroup state, embedded via `blkcg->css`. `struct blkcg_gq` (one per (blkcg, request_queue) pair, called a "blkg") stores per-device accounting and scheduling state. A cgroup that does I/O to three block devices will have three blkgs, each hanging off `blkcg->blkg_list`.

When a BIO is submitted for a device, `blkcg_bio_issue_check()` locates or creates the appropriate blkg using `blkg_lookup_create()`. The blkg holds a reference to both the blkcg and the request_queue, keeping both alive as long as I/O is in flight.

### Hard limits via blk-throttle

`io.max` installs BPS and IOPS limits using the blk-throttle subsystem (`block/blk-throttle.c`). Each blkg that has an active limit carries a `struct throtl_grp` with four token buckets: read BPS, write BPS, read IOPS, write IOPS.

When a BIO arrives in `blk_throtl_bio()`:
1. The function checks whether the BIO would violate the applicable limit for its direction.
2. If within budget, the token bucket is decremented and the BIO passes through immediately.
3. If the bucket is empty, the BIO is queued on `throtl_grp->pending_tree` and a `hrtimer` is armed to reissue it when the bucket refills (refill rate = limit / second).

The timer period is adaptive: if a single cgroup has many small BIOs queued, the timer fires frequently to release them in bursts that match the configured rate.

### Proportional scheduling via iocost

`io.weight` (range 1–10000, default 100) uses the iocost controller (`block/blk-iocost.c`), a cost-model scheduler. iocost assigns a *cost* to each I/O based on an estimated time model (seek latency + transfer time for the device type), then schedules cgroups using a virtual-time algorithm similar to CFS.

Each cgroup accumulates virtual time at a rate proportional to its weight. When a BIO is issued, its cost is added to the cgroup's virtual time. If the cgroup is ahead of the global virtual time (it has consumed more than its share), the BIO is delayed. If it is behind (it has used less than its share), the BIO is issued immediately and the cgroup builds up "credit" it can spend in bursts.

The device cost model is described in `io.cost.model` and can be tuned manually or auto-calibrated. `io.cost.qos` provides a Quality-of-Service layer on top: it specifies target latency percentiles, and iocost uses these to dynamically throttle workloads that are driving latency too high.

### Latency protection via io.latency

`io.latency` (target latency in microseconds) protects a workload from I/O interference. The controller monitors the cgroup's average I/O completion latency. If the cgroup is experiencing latency above its target, the controller reduces the I/O share of sibling cgroups on the same device, not the protected cgroup's share. This is the inverse of throttling: instead of punishing the protected cgroup when it exceeds a limit, the controller punishes other cgroups when they cause the protected cgroup to suffer.

### Writeback integration with the memory controller

Dirty page writeback is jointly owned by the I/O and memory controllers. When a process writes to a file and the page becomes dirty, `page_mkwrite()` tags the page with its owning cgroup. The writeback path uses `wb_cgroup_of_inode()` to determine which cgroup's I/O budget to deduct the writeback BIO from.

This matters because a process can dirty many pages and then migrate to a different cgroup. Without this accounting, the writeback I/O would be charged to the wrong cgroup. The joint tracking ensures the cgroup that caused the dirty pages bears the I/O cost when they are flushed.

## Key Data Structures

**`struct blkcg`** (`block/blk-cgroup.h`) — per-cgroup I/O controller state
- `css` — embedded `cgroup_subsys_state`
- `blkg_list` — list of `blkcg_gq` nodes, one per (cgroup, device) pair
- `stats` — aggregated I/O statistics (bytes read/written, IOs, discards)
- `iostat_cpu` — per-cpu I/O stats for lockless accumulation

**`struct blkcg_gq` (blkg)** (`block/blk-cgroup.h`) — per-(cgroup, device) accounting and scheduling
- `blkcg` — owning blkcg
- `q` — owning request_queue (device)
- `pd` — array of per-policy data pointers (throtl_grp, ioc_gq, etc.)
- `iostat` — per-cpu stats for this device
- `online` — true while the device is accessible

**`struct throtl_grp`** (`block/blk-throttle.c`) — per-cgroup hard-limit state
- `bps[READ/WRITE]` — configured BPS limits
- `iops[READ/WRITE]` — configured IOPS limits
- `bytes_disp[READ/WRITE]` — bytes dispatched in current window
- `pending_tree` — RB-tree of queued BIOs
- `pending_timer` — hrtimer for limit replenishment

## Key Functions / Entry Points

**`blkcg_bio_issue_check()`** (`block/blk-cgroup.h`) — called at BIO submission; finds the blkg and checks all active policies

**`blk_throtl_bio()`** (`block/blk-throttle.c`) — evaluates and potentially delays a BIO against `io.max` limits

**`ioc_rqos_throttle()`** (`block/blk-iocost.c`) — iocost admission path; calculates virtual time and delays if over budget

**`blkg_lookup_create()`** (`block/blk-cgroup.c`) — finds or creates the blkg for a (blkcg, request_queue) pair

**`cgroup_writeback_by_id()`** (`fs/fs-writeback.c`) — selects the appropriate writeback worker for a given cgroup

## Important Flags & Config Options

- `CONFIG_BLK_CGROUP` — enables cgroup I/O accounting (blkcg infrastructure)
- `CONFIG_BLK_DEV_THROTTLING` — enables blk-throttle (`io.max` limits)
- `CONFIG_BLK_CGROUP_IOCOST` — enables the iocost cost-model controller (`io.weight` and `io.cost.*`)
- `CONFIG_BLK_CGROUP_IOLATENCY` — enables the latency protection controller (`io.latency`)

Interface files per cgroup directory:
- `io.stat` — per-device read/write bytes and IOs (read-only)
- `io.weight` — proportional weight (1–10000)
- `io.max` — per-device BPS and IOPS hard limits
- `io.latency` — per-device latency target in microseconds
- `io.cost.qos` / `io.cost.model` — iocost tuning

## Interactions with Other Subsystems

- **↑ Userspace**: container runtimes write `io.max` and `io.weight` to configure per-container I/O policy; `io.stat` is read for monitoring
- **→ Block layer**: the controller sits in the BIO submission path; every BIO touching a cgroup-aware device goes through `blkcg_bio_issue_check()`
- **→ [[memory-cgroup]]**: writeback attribution requires cooperation — dirty pages carry cgroup ownership from `page_mkwrite()` to the writeback BIO
- **← [[cgroup-core]]**: the core calls `css_alloc()` to create `blkcg` and `css_free()` to destroy it; blkg lifecycle is tied to device hotplug events

## Design Decisions & Tradeoffs

**Three separate mechanisms** (throttle, iocost, iolatency) exist because no single mechanism solves all use cases. `io.max` is simple and predictable but wasteful (a cgroup at its limit cannot use spare capacity). iocost is work-conserving and proportional but requires a device cost model that may be imprecise. `io.latency` protects latency-sensitive workloads but does so at the expense of throughput for siblings. Production deployments typically combine `io.latency` for databases with `io.weight` for background tasks.

**Per-device blkg rather than per-cgroup** was chosen because I/O policies are inherently per-device: a 500 IOPS limit on an SSD means something very different from a 500 IOPS limit on a spinning disk. The blkg indirection lets operators set device-specific policies while sharing one cgroup hierarchy.

**Writeback attribution complexity** is a known cost of accurate accounting. The alternative (charging all writeback to the writing process's current cgroup) would be incorrect after migration but simpler to implement. The kernel chose accuracy.

## How It Has Evolved

- **2.6.33 (2010)** — CFQ I/O scheduler integrated with cgroups (v1 `blkio` controller); proportional weight via CFQ
- **4.5 (2016)** — v2 `io` controller introduced with `io.max` (blk-throttle) and `io.weight` initially
- **5.4 (2019)** — iocost controller added, replacing CFQ-based scheduling with a cost-model approach better suited to SSDs
- **5.14 (2021)** — `io.stat` enhanced with discard statistics; `io.latency` stabilized

## Further Reading

1. [Control Group v2: I/O — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html#io)
2. [io_uring and cgroup I/O accounting — LWN.net](https://lwn.net/Articles/844138/)
