---
title: "CPU Cgroups"
category: concept
tags: [scheduler, cgroups, cpu-shares, bandwidth, throttling, containers]
subsystem: scheduler
kernel_version: "2.6.24"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/sched/cpu-cgroup/
  - https://kernel-internals.org/sched/cpu-bandwidth/
  - https://kernel-internals.org/sched/
---

# CPU Cgroups

## Purpose

Without CPU resource control, any process can spawn unlimited threads and consume all CPU time on a shared system. CPU cgroups give administrators two orthogonal controls: *weight* (proportional CPU sharing — no group starves another) and *bandwidth* (hard quotas — a group is throttled when it hits its limit regardless of available CPU). Containers on shared infrastructure depend on both: weight ensures fair sharing under contention, bandwidth prevents a runaway container from monopolizing the host.

## Mental Model

Imagine a **restaurant with a fixed seating capacity**. CPU weight is like a reservation system: families with larger reservations get more tables proportionally, but if most reservations are empty on a slow night, anyone can use the extra tables. CPU bandwidth is like a strict time limit: every table must be vacated after exactly 90 minutes, no exceptions, even if no one else is waiting. Both rules can coexist: a large reservation AND a 90-minute limit.

## How It Works

### Group Scheduling Architecture

CPU cgroups are implemented via **group scheduling**, enabled by `CONFIG_FAIR_GROUP_SCHED`. Each cgroup maps to a `task_group` structure. Instead of all tasks competing in a single flat CFS tree, the hierarchy is mirrored in the scheduler: each `task_group` has per-CPU `sched_entity` objects (representing the *group* in the parent tree) and per-CPU `cfs_rq` objects (holding the group's tasks internally).

When the scheduler runs on a CPU, it sees the top-level `cfs_rq` containing both individual tasks and group entities. A group entity competes using the group's weight; when the group entity is selected to run, the scheduler descends into the group's `cfs_rq` and picks a task from within. This two-level scheduling provides isolation: tasks in group A and group B never directly compete in the same CFS tree.

### Weight-Based Sharing (Soft Limit)

Weight controls proportional CPU sharing. When all groups want to run simultaneously, CPU time is divided in proportion to their weights. When some groups are idle, their weight is redistributed to active groups — this is a *soft* limit.

**cgroup v1** uses `cpu.shares` (default 1024, range 2–262144):
- Setting `cpu.shares = 2048` gives twice the CPU time of a group with 1024
- The value has no absolute meaning; only ratios matter

**cgroup v2** uses `cpu.weight` (default 100, range 1–10000):
- The conversion: `shares = weight × 1024 / 100`
- The kernel always works in v1 share units internally; v2 weight is a rescaled interface

Both ultimately write to `task_group->shares` via `sched_group_set_shares()`. This function updates the per-CPU `sched_entity.load.weight` values and re-calculates the load weights of all group members, then propagates the change up the hierarchy.

### Bandwidth Control (Hard Limit)

Bandwidth throttling enforces a hard CPU cap via the `cfs_bandwidth` mechanism, enabled by `CONFIG_CFS_BANDWIDTH`.

**cgroup v1** exposes two separate files:
```
cpu.cfs_quota_us   # CPU time allowed per period (microseconds; -1 = unlimited)
cpu.cfs_period_us  # Period length (default 100,000 µs = 100ms)
```

**cgroup v2** combines them in a single file:
```
cpu.max   # Format: "quota period"
          # "50000 100000" = 50ms per 100ms period
          # "max 100000"   = unlimited
```

Internally, a `cfs_bandwidth` structure tracks the group's global quota pool:
- `quota` — the total nanoseconds of CPU time allowed per period
- `runtime` — nanoseconds remaining in the current period
- `period_timer` — hrtimer that fires at the period boundary to refill `runtime`

Each CPU's `cfs_rq` draws from this pool via `assign_cfs_rq_runtime()`. Rather than deducting from the global pool on every tick (which would require locking), each CPU draws a *slice* (default 5ms) at a time. The CPU can run the group's tasks until its local slice is exhausted, then either draws another slice or throttles if the global pool is empty.

**Throttling**: When `assign_cfs_rq_runtime()` finds the global pool exhausted, it calls `throttle_cfs_rq()`. This removes the `cfs_rq` from the local CFS tree (it stops contributing tasks), adds it to `cfs_bandwidth.throttled_cfs_rqs`, and sets `cfs_rq.throttled = 1`. Any tasks in the group simply don't get scheduled until the next period.

**Unthrottling**: At the period boundary, `sched_cfs_period_timer()` fires. It refills `cfs_bandwidth.runtime` to `quota`, then calls `unthrottle_cfs_rq()` for every throttled `cfs_rq`, re-inserting them into their respective CPU's CFS tree. Tasks that were queued but throttled resume scheduling immediately.

### Hierarchical Bandwidth (cgroup v2 only)

In cgroup v2, bandwidth is hierarchical: a child's effective quota cannot exceed its ancestors' quotas. If `/sys/fs/cgroup/container/`'s `cpu.max` is `"200000 100000"` (200ms per 100ms = 2 CPUs), and the child `container/app/` sets `cpu.max = "300000 100000"`, the child's effective quota is capped at 200ms by the parent. cgroup v1 does not enforce this inheritance.

## Key Data Structures

**`struct task_group`** (`kernel/sched/sched.h`) — the per-cgroup scheduler state.
- `shares` — CPU weight in v1 share units; set by `sched_group_set_shares()`
- `se[NR_CPUS]` — per-CPU `sched_entity *`; the group's representative in the parent `cfs_rq`
- `cfs_rq[NR_CPUS]` — per-CPU `cfs_rq *`; holds the group's tasks on each CPU
- `cfs_bandwidth` — quota tracking and throttle list (embedded; CONFIG_CFS_BANDWIDTH)

**`struct cfs_bandwidth`** (`kernel/sched/sched.h`) — bandwidth accounting for a `task_group`.
- `quota` — nanoseconds of CPU time per period
- `runtime` — nanoseconds remaining; decremented as CPUs draw slices
- `period_timer` — hrtimer for quota replenishment
- `throttled_cfs_rq` — list of throttled `cfs_rq` instances awaiting unthrottle
- `nr_throttled` — how many CPUs are currently throttled

## Key Functions / Entry Points

**`sched_group_set_shares()`** (`kernel/sched/fair.c`) — update group weight and propagate to all per-CPU group entities; called on writes to `cpu.shares` / `cpu.weight`.

**`throttle_cfs_rq()`** (`kernel/sched/fair.c`) — mark a `cfs_rq` as throttled, remove it from the CFS tree, add to the throttle list.

**`unthrottle_cfs_rq()`** (`kernel/sched/fair.c`) — re-insert a `cfs_rq` into the CFS tree after quota replenishment.

**`assign_cfs_rq_runtime()`** (`kernel/sched/fair.c`) — per-CPU quota draw: take a 5ms slice from the global pool; throttle if pool is empty.

**`sched_cfs_period_timer()`** (`kernel/sched/fair.c`) — hrtimer callback: refill quota, unthrottle all waiting `cfs_rq` instances.

## Important Flags & Config Options

- `CONFIG_FAIR_GROUP_SCHED` — enables the two-level scheduling hierarchy; required for CPU weight control
- `CONFIG_CFS_BANDWIDTH` — enables bandwidth throttling; requires `FAIR_GROUP_SCHED`
- `cpu.weight` (v2) / `cpu.shares` (v1) — weight control (soft limit)
- `cpu.max` (v2) / `cpu.cfs_quota_us` + `cpu.cfs_period_us` (v1) — bandwidth control (hard limit)
- `cpu.stat` (v2) — exposes `usage_usec`, `throttled_usec`, `nr_throttled` per group
- `/proc/sys/kernel/sched_cfs_bandwidth_slice_us` — the 5ms per-CPU draw size; tunable

## Interactions with Other Subsystems

- **↑ Userspace**: cgroup filesystem writes (`echo 50000 100000 > cpu.max`) trigger `sched_group_set_shares()` or bandwidth parameter updates
- **→ [[cfs-eevdf]]**: Group entities participate in the same CFS red-black tree as individual tasks; EEVDF's eligibility and deadline apply to group entities too
- **→ [[runqueue]]**: `throttle_cfs_rq()` removes the group's `cfs_rq` from the local tree; `rq->nr_running` decrements accordingly
- **← [[memory-management]]**: `memcg` (memory cgroup) operates orthogonally but often co-configured with CPU cgroups in container runtimes (Docker, Kubernetes)

## Design Decisions & Tradeoffs

**Per-CPU quota draw (5ms slices) vs. global tracking**: Deducting quota from a global counter on every tick would require cross-CPU locking. The slice approach lets each CPU operate independently until its 5ms is consumed, then contend for the next slice. This trades a small amount of quota precision (actual throttle point can be up to 5ms late) for significant lock contention reduction.

**Soft vs. hard limits as separate mechanisms**: Combining weight and bandwidth into one knob would be simpler but would conflate two distinct policies. A container might want high weight (to win contention when it's running) AND a hard cap (to prevent accidental runaway). Separating them gives operators fine-grained control.

**v1 vs. v2 hierarchy**: v1 per-CPU bandwidth accounting doesn't inherit quotas across the cgroup hierarchy — a child can set a quota that exceeds its parent's. v2 fixes this by enforcing the minimum across the ancestry. This makes v2 safer but requires migrating from v1 interfaces, which many existing tools depend on.

**Throttle granularity**: Throttling at the `cfs_rq` level (per CPU, per group) rather than the task level means all tasks in the group are throttled simultaneously. This is simpler and prevents partial-group throttling races but can cause priority inversion within the group — a high-priority task in a throttled group is blocked by the group's quota, not by anything it did.

## How It Has Evolved

| Version | Change |
|---------|--------|
| 2.6.24 | `CONFIG_FAIR_GROUP_SCHED` introduced; proportional CPU shares |
| 3.2 | `CONFIG_CFS_BANDWIDTH` added; hard quota throttling |
| 4.15 | cgroup v2 CPU controller with unified `cpu.weight` and `cpu.max` interfaces |
| 5.x | Hierarchical bandwidth enforcement in cgroup v2; `cpu.stat` improvements |

## Further Reading

1. [kernel-internals.org/sched/cpu-cgroup/](https://kernel-internals.org/sched/cpu-cgroup/)
2. [kernel-internals.org/sched/cpu-bandwidth/](https://kernel-internals.org/sched/cpu-bandwidth/)

## LKML Highlights

- **CFS bandwidth throttling introduction (3.2)**: Paul Turner's series adding `cfs_bandwidth`; the per-CPU slice design was explicitly chosen after benchmarking showed global per-tick accounting was a scalability bottleneck on >32-CPU systems.
- **cgroup v2 CPU controller (4.15)**: Tejun Heo's series unifying the interface and fixing the hierarchy enforcement gap in v1; discussion of migration pain from existing tooling vs. correctness gains.
