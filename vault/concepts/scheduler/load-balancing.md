---
title: "Load Balancing"
category: concept
tags: [scheduler, load-balancing, smp, sched-domain, pelt, numa]
subsystem: scheduler
kernel_version: "2.6.0"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/sched/load-balancing/
  - https://kernel-internals.org/sched/sched-domains/
  - https://kernel-internals.org/sched/wakeup/
  - https://kernel-internals.org/sched/
---

# Load Balancing

## Purpose

Per-CPU runqueues eliminate global lock contention during task selection, but they create a new problem: tasks can pile up on one CPU while others sit idle, wasting compute capacity. Load balancing periodically redistributes tasks across CPUs to maximize utilization while navigating competing concerns — cache locality (migrating a task flushes its hot cache lines), NUMA affinity (migrating across sockets incurs remote memory access latency), and energy efficiency (migrating to a more powerful core on a heterogeneous CPU costs power).

## Mental Model

Imagine a **bank with multiple teller windows** (CPUs). Customers (tasks) arrive and join whichever queue the greeter assigns them to. Periodically, the branch manager (load balancer) surveys all queues. If one window has 5 customers and another has 0, the manager moves 2–3 customers over. But the manager is smart: she doesn't move a customer who just started being served (cache hot), doesn't move customers to a window on the other side of the building if they can be served locally (NUMA), and moves customers in batches rather than one at a time to amortize the overhead. The assignment at arrival (wakeup CPU selection) also tries to minimize future balancing work.

## How It Works

### Scheduling Domains: The Topology Model

The kernel models CPU topology as a hierarchy of `sched_domain` structures, built during boot from topology callbacks:

1. **SMT** (Simultaneous Multi-Threading / hyperthreading siblings): share L1/L2 cache
2. **MC** (Multi-Core): cores sharing an L3 cache (LLC)
3. **PKG** (Package): the physical socket
4. **NUMA**: crosses NUMA node boundaries

Each domain contains a circular ring of `sched_group` structures, each `sched_group` representing a subset of CPUs at that level. A domain at the MC level might have two groups of four cores each (eight cores total on the package); a domain at the NUMA level has two groups representing the two sockets.

Domain parameters control balancing aggressiveness:
- `min_interval` / `max_interval` — how frequently to balance (scales with load)
- `imbalance_pct` — how unequal runqueue loads must be before migration fires (default ~125%)
- `flags` — `SD_LOAD_BALANCE`, `SD_BALANCE_WAKE`, `SD_NUMA`, etc.

The key insight is cost hierarchy: moving a task between SMT siblings is nearly free (shared L1/L2); between cores is moderate (L3 miss potential); between sockets is expensive (NUMA remote access). The domain hierarchy allows balancing to start with cheap migrations (SMT/MC level) before attempting expensive ones (NUMA).

### PELT: Measuring Load

Load balancing needs to compare CPU loads, but instantaneous `nr_running` is too noisy and doesn't capture task behavior. **PELT** (Per-Entity Load Tracking) computes exponentially weighted moving averages of CPU utilization per `sched_entity`. Older history (beyond ≈32ms, one decay period) contributes less than 1%. Each `sched_entity` carries a `sched_avg` struct with:
- `load_avg` — average load contribution (weighted by task priority)
- `util_avg` — average CPU utilization (fraction of capacity)
- `runnable_avg` — average time spent runnable (queued or running)

The load balancer reads `cfs_rq.avg.load_avg` (the sum of all tasks' load averages) to assess group busyness, rather than raw task counts.

### Three Balancing Triggers

**Periodic balancing**: The scheduler tick calls `trigger_load_balance()`, which sets a `SCHED_SOFTIRQ` flag if balancing is due. The softirq handler calls `run_rebalance_domains()`, which iterates from the narrowest domain to the broadest. For each level, `load_balance()` runs: it finds the busiest group in the domain by comparing load averages, then compares the busiest group to the local group. If the imbalance exceeds `imbalance_pct`, it calls `detach_tasks()` to migrate one or more tasks from the busiest CPU to the local one. Tasks are selected by the `can_migrate_task()` predicate, which excludes cache-hot tasks, pinned tasks, and tasks that would violate `cpuset` constraints.

**Idle balancing**: When a CPU runs out of work and enters idle, `newidle_balance()` fires immediately — before the CPU actually sleeps. This avoids a latency spike where a CPU is idle while work is available elsewhere. `newidle_balance()` walks domains outward from SMT to NUMA, pulling one batch of tasks if the expected idle duration exceeds the estimated migration cost. If the scan finds nothing, it exits quickly to minimize energy waste.

**Wakeup placement**: When a sleeping task wakes via `try_to_wake_up()`, `select_task_rq_fair()` chooses the target CPU. It applies two heuristics in order:

1. **Wake affinity**: If the waking task and the waker have recently communicated (waker called `wake_up()` often), they benefit from sharing an LLC domain — the wakee's working set is likely already cached near the waker's CPU. `wake_affine_idle()` checks if the waker's LLC domain has an idle CPU.

2. **Idlest CPU**: If wake affinity doesn't apply, the scheduler walks domains looking for the idlest suitable CPU, balancing at wakeup rather than waiting for the periodic balancer.

The `WF_SYNC` flag is set when the waker will immediately block after waking (e.g., a producer waking a consumer). In this case, the scheduler may place the wakee on the waker's CPU, which the waker is about to vacate — a "pass the torch" optimization.

### Heterogeneous CPUs: Misfit Tasks

On ARM big.LITTLE or Intel P+E (Performance+Efficiency) cores, CPUs have different compute capacities. A task using more than 80% of its current CPU class's capacity is flagged as "misfit" in `sched_entity.misfit = 1`. The next idle-balance opportunity migrates it to a higher-capacity CPU. Conversely, `select_task_rq_fair()` uses `task_fits_cpu()` to avoid placing CPU-hungry tasks on efficiency cores at wakeup.

### NUMA Automatic Balancing

With `CONFIG_NUMA_BALANCING`, the scheduler periodically unmaps page table entries for remote (off-node) memory. When the task faults on the unmapped page, the kernel records the access pattern in the task's `numa_faults` array. Over time, if the task shows strong affinity for a NUMA node's memory, the scheduler migrates both the task and its pages to that node together. This "scan, fault, decide, migrate" cycle is controlled by `sched_numa_balancing` sysctl and visible via `numastat`.

## Key Data Structures

**`struct sched_domain`** (`include/linux/sched/topology.h`) — one level of the topology hierarchy.
- `parent` / `child` — pointers up (broader) and down (narrower)
- `groups` — circular list of `sched_group` structs at this level
- `min_interval` / `max_interval` — balance frequency bounds
- `imbalance_pct` — trigger threshold (125 = 25% imbalance)
- `flags` — `SD_LOAD_BALANCE`, `SD_BALANCE_NEWIDLE`, `SD_BALANCE_WAKE`, `SD_NUMA`, `SD_ASYM_CPUCAPACITY`

**`struct sched_group`** (`include/linux/sched/topology.h`) — a set of CPUs within a domain.
- `cpumask` — which CPUs are in this group
- `sgc` — `sched_group_capacity`; the aggregate compute capacity of the group

**`struct sched_avg`** (`include/linux/sched/loadavg.h`) — per-entity PELT averages.
- `load_avg` — weighted average load (priority-scaled)
- `util_avg` — CPU utilization fraction (0–1024 = 0–100%)
- `runnable_avg` — average time the entity was runnable

## Key Functions / Entry Points

**`load_balance()`** (`kernel/sched/fair.c`) — periodic pull: find busiest group, compute imbalance, migrate tasks via `detach_tasks()`.

**`newidle_balance()`** (`kernel/sched/fair.c`) — idle-CPU immediate pull: walk domains outward, pull tasks if migration is cost-effective.

**`select_task_rq_fair()`** (`kernel/sched/fair.c`) — wakeup placement: wake affinity check, then idlest-CPU walk.

**`can_migrate_task()`** (`kernel/sched/fair.c`) — migration eligibility predicate: excludes pinned, cache-hot, and cpuset-violating tasks.

**`update_load_avg()`** (`kernel/sched/fair.c`) — PELT update: exponentially decay historical load and add current contribution; called on enqueue, dequeue, and tick.

## Important Flags & Config Options

- `CONFIG_NUMA_BALANCING` — enables automatic NUMA task and page migration
- `CONFIG_SCHED_SMT` / `CONFIG_SCHED_MC` — include SMT / multicore levels in the domain hierarchy
- `/proc/sys/kernel/sched_domain/` — per-domain tuning (exposed via `CONFIG_SCHED_DEBUG`)
- `/proc/sys/kernel/numa_balancing` — enable/disable automatic NUMA balancing at runtime
- `/proc/schedstat` — per-CPU and per-domain load balance statistics
- `isolcpus=<cpulist>` (kernel boot) — exclude CPUs from the scheduler domain; tasks never migrate there
- `taskset(1)` / `sched_setaffinity(2)` — pin tasks to specific CPUs; `can_migrate_task()` respects pinning

## Interactions with Other Subsystems

- **↑ Userspace**: `sched_setaffinity(2)` constrains which CPUs a task may run on; `numactl` controls NUMA placement
- **→ [[runqueue]]**: Load balancing reads `rq->nr_running`, `rq->avg_idle`, and class-level `sched_avg` values; writes by calling `dequeue_task()` on the source CPU and `enqueue_task()` on the target
- **→ [[cfs-eevdf]]**: PELT (`sched_avg`) is computed and maintained inside `fair_sched_class`; `select_task_rq_fair()` is a fair-class function
- **→ [[numa-memory-policy]]**: NUMA balancing triggers page migrations via `migrate_pages()`; the scheduler and mm subsystem coordinate via `numa_faults` and `numa_group`
- **← [[interrupt-handling]]**: The balance softirq (`SCHED_SOFTIRQ`) is raised from the timer interrupt handler via `trigger_load_balance()`

## Design Decisions & Tradeoffs

**Pull-based vs. push-based**: The primary mechanism pulls tasks to idle CPUs rather than pushing tasks from busy ones. Pull is simpler (only the pulling CPU needs to modify its own queue) and naturally load-tracks — idle CPUs pull work, busy CPUs don't push. Push (`push_rt_task()`) exists for RT tasks where latency is critical enough to justify the extra complexity.

**PELT vs. instantaneous load**: Raw `nr_running` is cheap to read but unstable — a single short-burst task briefly inflates the count. PELT smooths this but introduces lag: a CPU that suddenly becomes idle still looks "loaded" for a few milliseconds. The decay constant (≈32ms) is a tunable compromise.

**Imbalance threshold (125%)**: A 25% imbalance is required before migration fires. This prevents pathological oscillation where a task migrates back and forth between two CPUs that are alternately equally loaded. The threshold effectively reserves some imbalance as "acceptable" migration-cost headroom.

**NUMA balancing scan-and-fault**: Unmapping pages to detect access patterns is invasive — it causes faults that add latency. The scan rate is dynamically adjusted: if the task's memory is already on the right node, scans slow down (reducing overhead); if many faults show remote access, scans accelerate.

## How It Has Evolved

| Version | Change |
|---------|--------|
| 2.6.0 | Per-CPU runqueues + load balancer introduced with O(1) scheduler |
| 2.6.23 | Scheduling domains hierarchy; topology-aware balancing replaces flat load comparison |
| 3.x | PELT replaces static load accounting; per-entity exponential averaging |
| 3.13 | Automatic NUMA balancing (`CONFIG_NUMA_BALANCING`) |
| 4.x | Energy-aware scheduling; `struct em_perf_domain` for heterogeneous CPUs |
| 5.x | Misfit task handling for asymmetric CPU capacity (big.LITTLE, P+E cores) |

## Further Reading

1. [kernel-internals.org/sched/load-balancing/](https://kernel-internals.org/sched/load-balancing/)
2. [kernel-internals.org/sched/sched-domains/](https://kernel-internals.org/sched/sched-domains/)
3. [Capacity Aware Scheduling — kernel.org](https://static.lwn.net/kerneldoc/scheduler/sched-capacity.html)
4. [Improved load balancing with machine learning (LWN, 2024)](https://lwn.net/SubscriberLink/1027096/7fecce40a407a9c3/)

## LKML Highlights

- **Scheduling domains introduction (2.6.23)**: Ingo Molnár's series building the hierarchical topology model, explaining that flat CPU comparisons were incorrectly treating SMT siblings and NUMA nodes as equivalent migration targets.
- **PELT introduction (3.x)**: Paul Turner's series replacing static load with PELT, explaining the instability of `nr_running` as a load metric for migration decisions.
- **NUMA balancing (3.13)**: Rik van Riel and Mel Gorman's series implementing the scan-fault-migrate cycle; discussion of the cost of faults vs. the benefit of improved NUMA placement.
