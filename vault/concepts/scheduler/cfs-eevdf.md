---
title: "CFS and EEVDF: The Fair Scheduler"
category: concept
tags: [scheduler, cfs, eevdf, vruntime, fairness, red-black-tree]
subsystem: scheduler
kernel_version: "2.6.23"
researched: 2026-04-13
status: complete
explained: "[[cfs-eevdf-explained]]"
sources:
  - https://kernel-internals.org/sched/cfs/
  - https://kernel-internals.org/sched/eevdf/
  - https://kernel-internals.org/sched/scheduler-evolution/
  - https://lwn.net/Articles/925371/
  - https://lwn.net/Articles/969062/
  - https://static.lwn.net/kerneldoc/scheduler/sched-design-CFS.html
---

# CFS and EEVDF: The Fair Scheduler

> 📘 Plain-language version: [[cfs-eevdf-explained]]

## Purpose

The fair scheduler handles the vast majority of processes on a Linux system — every shell, daemon, container workload, and interactive application that hasn't explicitly requested real-time priority. It must achieve three simultaneous and partly conflicting goals: fairness (no process is permanently starved relative to its priority weight), low latency (interactive processes get CPU promptly when they wake up), and high throughput (batch workloads fully utilize the CPU without unnecessary context switches).

## Mental Model

Imagine a **virtual clock that runs at different speeds for different tasks**. A high-priority task's clock runs slow — it accumulates "virtual time" slowly, so it's always seen as having consumed less virtual CPU than it actually has. A low-priority task's clock runs fast. The scheduler always picks whoever has the smallest virtual time so far, which automatically gives high-priority tasks more real CPU without any explicit special-casing. EEVDF adds a twist: instead of picking purely the smallest virtual time, it picks the task with the earliest *deadline* among those who haven't yet exceeded their fair share — this lets latency-sensitive tasks jump the queue without violating fairness guarantees.

## How It Works

### CFS: Virtual Runtime Fairness (2.6.23–6.5)

CFS was introduced in Linux 2.6.23 as a replacement for the O(1) scheduler's opaque interactivity heuristics. Its central concept is `vruntime` — a per-task accumulator that measures how much virtual CPU time the task has consumed:

```
vruntime += (real time elapsed) × (NICE_0_WEIGHT / task_weight)
```

`NICE_0_WEIGHT` is 1024 (the weight of a nice-0 task). A task at nice -5 has weight 3121, so its vruntime grows at ≈0.33× the real rate. A task at nice +5 has weight 335, growing at ≈3.1×. The scheduler always selects the task with the smallest vruntime. Over time, the ratio of CPU consumed by any two tasks converges to the ratio of their weights — mathematically provable fairness, not heuristic-based.

The weight-to-nice mapping uses a fixed table where each nice step provides ≈1.25× difference, so each increment causes roughly 10% throughput variation. The extreme values (nice -20: weight 88761 vs. nice +19: weight 15) give a ≈5917:1 ratio.

All runnable fair-class tasks live in a per-CPU `cfs_rq->tasks_timeline` red-black tree keyed by vruntime. The tree caches its leftmost node, enabling O(1) access to the minimum-vruntime task. Every timer tick, `update_curr()` (called via `task_tick_fair()`) computes elapsed real time, multiplies by the weight ratio, adds to `vruntime`, and updates `rq->clock_task`. It then checks whether the current task has consumed more than its ideal share of the scheduling period — if so, `resched_curr()` sets `TIF_NEED_RESCHED`.

When a task wakes from sleep, its vruntime would be far behind the currently running tasks, unfairly entitling it to monopolize the CPU after a long sleep. `place_entity()` corrects this by advancing the waking task's vruntime to approximately `avg_vruntime - half_slice`, positioning it near the front of the queue but not so far ahead that it starves others.

### EEVDF: Eligible Virtual Deadline First (6.6+)

CFS worked well but accumulated a collection of fragile wakeup heuristics (`WAKEUP_PREEMPTION`, `NEXT_BUDDY`, `LAST_BUDDY`, `CACHE_HOT_BUDDY`) designed to improve interactive latency. These heuristics were tuned for some workloads and degraded others, and they interacted poorly with each other. The fundamental problem: CFS selects by smallest vruntime, which is a fairness criterion, not a latency criterion. A task processing a network packet with a 1ms deadline has no scheduling advantage over a batch task that happened to sleep briefly.

EEVDF, merged in 6.6 based on a 1995 paper by Ion Stoica and Hussein Abdel-Wahab, adds two concepts:

**Eligibility**: A task is eligible if its vruntime ≤ `avg_vruntime` — it hasn't consumed more than its fair share. Only eligible tasks are candidates for selection.

**Virtual deadline**: Each task receives a deadline `vd = vruntime + calc_delta_fair(slice, se)`. Tasks requesting shorter slices (`sysctl sched_min_granularity_ns` or future latency-nice values) get earlier deadlines because `calc_delta_fair(shorter_slice, se)` is smaller.

`pick_eevdf()` (replacing the old leftmost-node selection) traverses the red-black tree to find the eligible task with the earliest virtual deadline. This naturally schedules latency-sensitive tasks (with short slices → early deadlines) before batch tasks, without special-casing. The old heuristics were removed because the virtual deadline mechanism subsumes them.

`wakeup_preempt_fair()` now compares virtual deadlines: if the woken task's vd < running task's vd, set `TIF_NEED_RESCHED`. This is more principled than the old `WAKEUP_PREEMPTION` heuristic.

### Group Scheduling

With `CONFIG_FAIR_GROUP_SCHED`, cgroups add a second level. Each `task_group` has per-CPU `sched_entity` objects (representing the group) and per-CPU `cfs_rq` objects (holding the group's tasks). The group's `sched_entity` competes in the parent `cfs_rq` using the group's assigned weight; inside the group, tasks compete independently in the group's `cfs_rq`. This creates a two-level hierarchy without merging all tasks into a flat tree.

## Key Data Structures

**`struct sched_entity`** (`include/linux/sched.h`) — embedded in `task_struct`; the unit the fair scheduler tracks.
- `load` — weight derived from nice value; used in vruntime calculations
- `vruntime` — accumulated virtual runtime (nanoseconds, weighted)
- `exec_start` — wall-clock timestamp of last `update_curr()` invocation
- `sum_exec_runtime` — total real CPU consumed (unweighted, nanoseconds)
- `run_node` — `rb_node` for position in the `cfs_rq` red-black tree
- `deadline` — EEVDF virtual deadline for this activation
- `slice` — requested time slice (shorter → earlier deadline → sooner scheduling)
- `on_rq` — 1 if currently in the runqueue

**`struct cfs_rq`** (`kernel/sched/sched.h`) — per-CPU fair-class runqueue.
- `tasks_timeline` — `rb_root_cached`; the red-black tree with cached leftmost node
- `curr` — currently executing `sched_entity`
- `avg_vruntime` — weighted average vruntime of runnable entities; used for eligibility
- `nr_queued` — count of runnable tasks
- `load` — aggregate load weight of all queued tasks

## Key Functions / Entry Points

**`update_curr()`** (`kernel/sched/fair.c`) — tick and context-switch handler: compute elapsed real time, advance `vruntime`, update statistics; called by `task_tick_fair()` and `put_prev_entity()`.

**`enqueue_entity()`** / **`dequeue_entity()`** (`kernel/sched/fair.c`) — insert/remove a `sched_entity` from the red-black tree; called on wakeup/block/migration.

**`place_entity()`** (`kernel/sched/fair.c`) — set `vruntime` for a newly waking or forked task; positions it near `avg_vruntime - half_slice`.

**`pick_eevdf()`** (`kernel/sched/fair.c`) — EEVDF task selection: find the eligible entity with the earliest virtual deadline; replaces the old leftmost-node lookup.

**`wakeup_preempt_fair()`** (`kernel/sched/fair.c`) — decide whether a waking task should preempt the current one by comparing virtual deadlines.

## Important Flags & Config Options

- `CONFIG_FAIR_GROUP_SCHED` — enables cgroup group scheduling within the fair class
- `CONFIG_CFS_BANDWIDTH` — enables hard CPU quotas via `cfs_bandwidth` (requires `FAIR_GROUP_SCHED`)
- `/proc/sys/kernel/sched_latency_ns` — target scheduling latency; all runnable tasks get a proportional slice within this window (default: 6ms for ≤8 tasks, scales up)
- `/proc/sys/kernel/sched_min_granularity_ns` — minimum task slice; prevents thrashing on large task counts (default: 0.75ms)
- `/proc/sys/kernel/sched_wakeup_granularity_ns` — minimum vruntime advantage for a waking task to preempt the running task
- `/proc/$PID/sched` — per-task vruntime, exec time, nr_switches, and scheduling counters

## Interactions with Other Subsystems

- **↑ Userspace**: `nice(2)` / `setpriority(2)` change the task weight; `sched_setattr(2)` can set a custom time slice
- **→ [[runqueue]]**: All fair-class tasks live in `rq->cfs` (a `cfs_rq`); `update_curr()` reads `rq->clock_task`
- **→ [[cpu-cgroups]]**: `task_group` adds a second level of `sched_entity` / `cfs_rq` for group-aware scheduling
- **← [[load-balancing]]**: PELT (Per-Entity Load Tracking) computes `sched_avg` inside `sched_entity`; load balancer reads these averages to decide migration
- **← [[interrupt-handling]]**: Timer ticks drive `task_tick_fair()` → `update_curr()` → potential `resched_curr()`

## Design Decisions & Tradeoffs

**Virtual runtime vs. real fairness**: CFS is not instantaneously fair — tasks run in slices. The scheduler latency (`sched_latency_ns`) bounds the unfairness window. Reducing latency increases context switch frequency and overhead; the default 6ms is a measured compromise for desktop latency.

**EEVDF over accumulated heuristics**: CFS's wakeup heuristics (`NEXT_BUDDY`, `LAST_BUDDY`, `WAKEUP_PREEMPTION`) were each solving a real problem but interacted poorly. EEVDF's virtual deadline provides a single principled mechanism: a task that needs to be scheduled sooner requests a shorter slice, gets an earlier deadline, and wins selection without fighting other heuristics.

**Red-black tree vs. simpler structures**: A sorted linked list would be O(n) for insertion; a heap would be O(log n) but more complex. The red-black tree gives O(log n) for all operations with good cache behavior on typical task counts (most systems have <100 runnable tasks per CPU at a time).

## How It Has Evolved

| Version | Change |
|---------|--------|
| 2.6.23 (2007) | CFS replaces O(1) scheduler; virtual runtime, red-black tree |
| 2.6.24 | Group scheduling (`CONFIG_FAIR_GROUP_SCHED`); `task_group` hierarchy |
| 3.x | PELT (Per-Entity Load Tracking): exponential averaging for load metrics |
| 5.x | Removal of several CFS wakeup heuristics (partial cleanup) |
| 6.6 (2023) | EEVDF replaces CFS task selection; `pick_eevdf()` subsumes wakeup heuristics |
| 6.6+ | Ongoing: latency-nice interface, EEVDF + group scheduling integration |

## Further Reading

1. [An EEVDF CPU scheduler for Linux (LWN, 2023)](https://lwn.net/Articles/925371/)
2. [Completing the EEVDF scheduler (LWN, 2024)](https://lwn.net/Articles/969062/)
3. [CFS Scheduler Design — kernel.org](https://static.lwn.net/kerneldoc/scheduler/sched-design-CFS.html)

## LKML Highlights

- **CFS introduction (2007)**: Ingo Molnár's cover letter explained that CFS makes fairness mathematically provable rather than heuristic-dependent, citing Con Kolivas's RSDL as the inspiration.
- **EEVDF RFC (2023)**: Peter Zijlstra's series framed EEVDF as a principled replacement for the accumulation of CFS heuristics, showing per-benchmark data where EEVDF matched or beat CFS without special-casing.
