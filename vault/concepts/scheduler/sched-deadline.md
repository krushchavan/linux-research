---
title: "SCHED_DEADLINE"
category: concept
tags: [scheduler, real-time, deadline, cbs, edf, admission-control]
subsystem: scheduler
kernel_version: "3.14"
researched: 2026-04-13
status: complete
explained: "[[sched-deadline-explained]]"
sources:
  - https://kernel-internals.org/sched/deadline/
  - https://kernel-internals.org/sched/
---

# SCHED_DEADLINE

> 📘 Plain-language version: [[sched-deadline-explained]]

## Purpose

Traditional real-time scheduling (`SCHED_FIFO`, `SCHED_RR`) uses fixed priorities: the administrator assigns a number and the system enforces strict precedence. This works but is fragile — an RT task that consumes more CPU than expected can starve everything at lower priorities without any automatic enforcement. `SCHED_DEADLINE` inverts this: tasks declare *how much CPU they need and by when*, and the kernel enforces those declarations with hard guarantees and admission control that refuses tasks it cannot schedule.

## Mental Model

Think of `SCHED_DEADLINE` as a **contract-based service**: a task says "I need 5ms of CPU every 20ms, and I must finish by the 20ms mark." The kernel's admission desk checks whether it can honor this contract alongside all existing contracts. If yes, the task gets its 5ms on time, every period, guaranteed. If no, the application is told to try again or negotiate different terms. There's no priority gaming — just bandwidth declarations with math behind them.

## How It Works

Each `SCHED_DEADLINE` task declares three parameters via `sched_setattr(2)`:

- **`sched_runtime`** (D): how many nanoseconds of CPU time the task needs per period
- **`sched_deadline`** (d): the relative deadline by which the task must finish each activation  
- **`sched_period`** (P): how often the task repeats (defaults to `sched_deadline` if unset)

These define the task's utilization: `U = sched_runtime / sched_period`.

Before the kernel accepts the parameters, it runs **admission control**. It sums the utilization of all existing `SCHED_DEADLINE` tasks on all CPUs. If adding the new task would push total utilization above 100%, `sched_setattr()` returns `-EBUSY`. This mathematical guarantee ensures that every admitted task can always meet its deadline — the kernel never takes on more than it can deliver.

Once admitted, the **CBS (Constant Bandwidth Server)** algorithm enforces the contract. Each task starts each period with a budget of `sched_runtime` nanoseconds. The kernel tracks remaining budget in `sched_dl_entity.runtime`. On every timer tick, `task_tick_dl()` decrements the budget by the elapsed time. When the budget hits zero, the task is immediately *throttled* — removed from the runqueue — and an hrtimer (`dl_task_timer`) is armed for the next period boundary.

At the period boundary, `dl_task_timer()` fires, replenishes the budget to `sched_runtime`, sets a new absolute deadline (`now + sched_deadline`), and re-enqueues the task.

Task selection within `dl_sched_class` uses **Earliest Deadline First (EDF)**: the `dl_rq` is a red-black tree ordered by absolute deadline. `pick_next_task_dl()` always returns the leftmost node — the task whose deadline expires soonest. EDF is theoretically optimal: it maximizes the number of tasks that can meet their deadlines on a single CPU, and with CBS providing isolation between tasks, it extends to SMP.

Because `dl_sched_class` sits above `rt_sched_class` in the scheduler class chain, any `SCHED_DEADLINE` task preempts any RT or CFS task. The system-level admission control ensures this priority is justified — if the kernel has accepted a task's contract, it will honor it.

**GRUB** (Greedy Reclamation of Unused Bandwidth) is an optional extension: when a `SCHED_DEADLINE` task finishes early and blocks before exhausting its budget, GRUB allows other tasks to use the reclaimed bandwidth. This improves utilization without violating guarantees — a task using extra bandwidth is still preempted the moment any DEADLINE task needs its promised CPU time.

On SMP systems, `SCHED_DEADLINE` tasks can migrate between CPUs. Migration is constrained by bandwidth: when a task migrates, the per-CPU bandwidth accounting must be updated to prevent double-counting. `cpudl` (CPU-deadline) tracks the earliest deadline on each CPU, enabling efficient placement decisions that minimize deadline misses.

## Key Data Structures

**`struct sched_dl_entity`** (`include/linux/sched.h`) — embedded in `task_struct`; deadline scheduling state.
- `dl_runtime` — declared runtime per period (nanoseconds)
- `dl_deadline` — declared relative deadline (nanoseconds)
- `dl_period` — period (nanoseconds); equal to `dl_deadline` if not set
- `runtime` — remaining budget in the current period
- `deadline` — absolute deadline for the current activation (nanoseconds, monotonic)
- `dl_throttled` — set when budget is exhausted; task is off runqueue
- `dl_timer` — hrtimer for period replenishment

**`struct dl_rq`** (`kernel/sched/sched.h`) — per-CPU deadline runqueue.
- `rb_root_cached` — red-black tree ordered by absolute deadline; leftmost = earliest deadline
- `running_bw` — bandwidth currently in use (fixed-point fraction of total CPU)
- `this_bw` — total bandwidth committed on this CPU
- `extra_bw` — reclaimed idle bandwidth available for GRUB

**`struct dl_bw`** (`kernel/sched/deadline.c`) — system-wide bandwidth accounting.
- `total_bw` — sum of all admitted `SCHED_DEADLINE` utilizations
- `bw` — per-CPU bandwidth limit (1 by default = 100% per CPU)

## Key Functions / Entry Points

**`dl_task_timer()`** (`kernel/sched/deadline.c`) — hrtimer callback: replenish `runtime` to `dl_runtime`, compute new `deadline`, re-enqueue the task.

**`pick_next_task_dl()`** (`kernel/sched/deadline.c`) — EDF selection: return the leftmost (earliest-deadline) node from `dl_rq`.

**`task_tick_dl()`** (`kernel/sched/deadline.c`) — timer tick: decrement `runtime`, throttle immediately if exhausted.

**`dl_overflow()`** (`kernel/sched/deadline.c`) — admission control check: compute whether adding the new task's utilization would exceed capacity; called from `sched_setattr()`.

**`enqueue_task_dl()`** / **`dequeue_task_dl()`** (`kernel/sched/deadline.c`) — insert/remove from the EDF red-black tree; update deadline ordering.

## Important Flags & Config Options

- `sched_setattr(2)` — userspace API for setting and changing DEADLINE parameters
- `/proc/sys/kernel/sched_dl_period_max_us` / `sched_dl_period_min_us` — bounds on allowed `sched_period` values
- `CAP_SYS_NICE` — required to set `SCHED_DEADLINE`
- `CONFIG_SMP` — enables the `cpudl` structure for multi-CPU deadline-aware placement

## Interactions with Other Subsystems

- **↑ Userspace**: `sched_setattr(2)` with `SCHED_DEADLINE`; `pthread_setschedattr()` for threads; `chrt -d` command
- **→ [[scheduler-classes]]**: `dl_sched_class` is placed above `rt_sched_class` in the priority chain; any admitted DEADLINE task preempts any RT task
- **→ [[runqueue]]**: Budget tracking uses `rq->clock_task` (excludes VM guest time); `dl_rq` is embedded in `struct rq`
- **← [[locking]]**: `rq->__lock` protects all `dl_rq` modifications; `dl_bw` uses its own lock for system-wide accounting

## Design Decisions & Tradeoffs

**Admission control as a contract**: Unlike RT priorities, `SCHED_DEADLINE` refuses tasks the system cannot handle. This is safer for production use but means applications must negotiate their bandwidth declaration — getting parameters wrong results in either `-EBUSY` (too high) or missed deadlines in practice (too low).

**CBS isolation**: Each task's budget is independent. A misbehaving task (consuming budget fast) is throttled without affecting other DEADLINE tasks. This isolation comes at a cost: a task that finishes its work early cannot use its leftover budget unless GRUB is enabled.

**EDF optimality**: EDF maximizes schedulability on a single CPU — it is proven to schedule any set of tasks that any other algorithm can schedule. The CBS + EDF combination extends this to SMP with admission control bounds.

**`sched_period` vs. `sched_deadline`**: Separating the period from the deadline allows "sporadic server" behavior: a task may have a 10ms period but only a 5ms deadline, meaning it must finish in the first half of its period. This is common in control applications where results must be available before the next actuation.

## How It Has Evolved

| Version | Change |
|---------|--------|
| 3.14 (2014) | `SCHED_DEADLINE` merged: CBS + EDF + admission control; Juri Lelli, Claudio Scordino |
| 3.14+ | GRUB bandwidth reclamation added |
| 4.x | SMP migration improvements; `cpudl` for per-CPU deadline tracking |
| 5.x | Integration with energy-aware scheduling for heterogeneous CPUs |

## Further Reading

1. [kernel-internals.org/sched/deadline/](https://kernel-internals.org/sched/deadline/)
2. [An EDF scheduling class for the Linux kernel — RTLWS11 paper (LWN)](https://static.lwn.net/images/conf/rtlws11/papers/proc/p16.pdf)
3. [Scheduler documentation — kernel.org](https://static.lwn.net/kerneldoc/scheduler/index.html)

## LKML Highlights

- **SCHED_DEADLINE merge (3.14)**: Juri Lelli's cover letter explaining the CBS algorithm and admission control, and why bandwidth-based scheduling is fundamentally safer than priority-based RT for production systems.
- **GRUB addition**: Thread discussing the tradeoff between strict isolation (no reclamation) and utilization efficiency (GRUB), settling on GRUB as opt-in via the existing CBS framework.
