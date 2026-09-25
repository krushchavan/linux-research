---
title: "Cpuset Controller"
category: concept
tags: [cgroups, cpuset, numa, cpu-affinity, memory-nodes, isolation]
subsystem: cgroups
kernel_version: "2.6.0"
researched: 2026-04-16
status: complete
explained: "[[cpuset-controller-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html
  - https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v1/cpusets.html
  - https://lwn.net/Articles/679786/
---

# Cpuset Controller

> 📘 Plain-language version: [[cpuset-controller-explained]]

## Purpose

The cpuset controller pins a cgroup's tasks to a specified subset of CPUs and NUMA memory nodes. On multi-socket NUMA servers, accessing remote memory can be 2–3× slower than local memory; cpusets prevent a container's pages from being allocated on a far node. For real-time and HPC workloads, cpusets provide exclusive CPU domains, eliminating scheduler interference from unrelated processes.

## Mental Model

Imagine a large office building with several floors (NUMA nodes), each floor having its own elevator bank (CPUs) and supply room (memory). The cpuset controller lets the building manager assign a company to specific floors. The company's employees (tasks) can only use the elevators and supplies on their assigned floors. If you want a department to have an entire floor to itself without sharing it with the mailroom (partition mode), you can carve that floor out entirely.

## How It Works

### Basic CPU and memory node assignment

Each cgroup has a `struct cpuset` with `cpus_allowed` and `mems_allowed` fields holding the requested CPU and memory node masks. But tasks see *effective* masks (`effective_cpus`, `effective_mems`), which are computed as the intersection of the cgroup's request with its parent's effective mask. A child can never gain access to a CPU or memory node the parent doesn't have.

When userspace writes to `cpuset.cpus`, `cpuset_write_resmask()` validates the new mask, computes the new effective mask by intersecting with the parent's `effective_cpus`, and calls `cpuset_update_tasks_cpumask()`. This function iterates every task in the cgroup (via `css_task_iter`) and calls `set_cpus_allowed_ptr(task, effective_cpus)`, which updates the task's scheduler affinity mask. The scheduler then confines the task to the specified CPUs at the next scheduling decision.

Memory node changes similarly call `cpuset_migrate_mm()` if `cpuset.memory_migrate` is set, which moves the process's pages to the new node set via `migrate_pages()`.

### Effective mask propagation

When a cpuset's mask changes, the change cascades downward through all descendants. `update_cpumasks_hier()` walks the subtree, recomputing effective masks level by level and applying them to tasks. This ensures the invariant is never violated: a descendant's effective mask is always a subset of its ancestor's.

CPU hotplug uses the same path: when a CPU goes offline, `cpuset_update_active_cpus()` fires and recomputes all effective masks, potentially migrating tasks from the removed CPU.

### Partition root mode

`cpuset.cpus.partition = root` is a v2-only feature that goes beyond simple affinity: it *carves out* the cpuset's CPUs from the parent domain entirely, creating a scheduling isolation domain. No tasks outside the partition (including the parent's own tasks) may run on those CPUs. The partition root must own at least one CPU that is in the parent's `effective_cpus`.

When a partition root is created, `update_prstate()` removes the partition's CPUs from the parent's effective mask and reconfigures `sched_domain` rebuild so the CPUs form an isolated scheduling domain. This is used for co-location scenarios (e.g. a latency-sensitive database that must never share CPUs with batch jobs).

A cgroup that sets `partition = member` (the default) participates in the parent's scheduling domain normally.

### NUMA memory policy

`cpuset.mems` changes interact with per-process NUMA memory policies (`set_mempolicy()`). If a task's memory policy references nodes outside the new `effective_mems`, the kernel rebinds the policy to the intersection. If a task's preferred node is no longer available, allocation falls back to any node in `effective_mems`.

## Key Data Structures

**`struct cpuset`** (`kernel/cgroup/cpuset.c`) — per-cgroup cpuset controller state
- `css` — embedded `cgroup_subsys_state`
- `cpus_allowed` — requested CPU mask (as written by userspace)
- `mems_allowed` — requested memory node mask
- `effective_cpus` — intersection of `cpus_allowed` with parent's `effective_cpus`; what tasks actually use
- `effective_mems` — same for memory nodes
- `partition_root_state` — `PRS_DISABLED`, `PRS_ENABLED_ROOT`, `PRS_ENABLED_ISOLATED`; drives partition behaviour
- `flags` — `CS_MEMORY_MIGRATE`, `CS_SPREAD_PAGE`, `CS_SPREAD_SLAB`

## Key Functions / Entry Points

**`cpuset_write_resmask()`** (`kernel/cgroup/cpuset.c`) — handles writes to `cpuset.cpus` or `cpuset.mems`; validates and propagates the new mask

**`cpuset_update_tasks_cpumask()`** (`kernel/cgroup/cpuset.c`) — applies a new effective CPU mask to all tasks in the cgroup

**`update_cpumasks_hier()`** (`kernel/cgroup/cpuset.c`) — cascades effective mask changes through the entire subtree

**`cpuset_attach()`** (`kernel/cgroup/cpuset.c`) — called when a task migrates into the cgroup; enforces memory migration if `CS_MEMORY_MIGRATE` is set

**`cpuset_update_active_cpus()`** (`kernel/cgroup/cpuset.c`) — CPU hotplug callback; rebuilds effective masks when CPUs go offline/online

**`update_prstate()`** (`kernel/cgroup/cpuset.c`) — handles partition root state transitions; triggers `sched_domain` rebuild

## Important Flags & Config Options

- `CONFIG_CPUSETS` — enables the cpuset controller
- `CONFIG_NUMA` — required for memory node controls to be meaningful
- `cpuset.cpus` — requested CPU list (e.g. `0-3,8`)
- `cpuset.cpus.effective` — read-only actual CPU list after parent intersection
- `cpuset.mems` — requested memory node list (e.g. `0,1`)
- `cpuset.mems.effective` — read-only actual memory nodes
- `cpuset.cpus.partition` — `root` / `isolated` / `member` (v2); controls partition isolation
- `cpuset.memory_migrate` — (v1 flag) triggers page migration when mems change

## Interactions with Other Subsystems

- **↑ Userspace**: container runtimes and job schedulers write `cpuset.cpus` and `cpuset.mems` to isolate workloads; `numactl` uses cpusets internally
- **→ [[scheduler]]**: cpusets call `set_cpus_allowed_ptr()` to update task affinity masks; partition root transitions trigger `sched_domain` rebuilds via `partition_and_rebuild_sched_domains()`
- **→ [[numa-memory-policy]]**: mems changes interact with per-task NUMA policies; the kernel rebinds policies to the new effective_mems
- **← [[cgroup-core]]**: the core calls `cpuset_attach()` when tasks migrate; CPU hotplug calls `cpuset_update_active_cpus()`

## Design Decisions & Tradeoffs

**Effective mask intersection** ensures safety without requiring special permissions: any cgroup can set `cpuset.cpus` to any value, but the effective set is always constrained by the parent. This means a child cannot escalate to CPUs the parent doesn't own, providing safe delegation.

**Partition mode** deliberately *removes* CPUs from the parent domain. This is an unusual design: most kernel resource controls allow sharing, not exclusive ownership. The reason is scheduling isolation: for real-time tasks, having even one other task occasionally wander onto "your" CPU causes unacceptable jitter. Removing the CPU from the parent's domain guarantees this cannot happen.

**Cpusets as the historical root** — the cpuset mechanism predates the generic cgroup framework. The original `cpuset` pseudo-filesystem was merged in 2.6.0 for NUMA HPC workloads, and was subsequently re-implemented as a cgroup controller when the cgroup infrastructure arrived in 2.6.24. This history explains why cpusets have more functionality (spread flags, partition roots, memory migration) than newer controllers.

## How It Has Evolved

- **2.6.0 (2003)** — original `cpuset` filesystem introduced for NUMA HPC at SGI
- **2.6.24 (2008)** — reimplemented as a cgroup controller
- **5.0 (2019)** — `cpuset.cpus.partition` introduced in v2 for CPU isolation domains
- **5.17 (2022)** — partition isolated mode (`isolated`) added, preventing load balancing across the partition boundary entirely

## Further Reading

1. [Control Group v2: Cpuset — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html#cpuset)
2. [Cpusets v1 documentation — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v1/cpusets.html)
3. [CPU partitioning with cgroup v2 — LWN.net](https://lwn.net/Articles/799737/)
