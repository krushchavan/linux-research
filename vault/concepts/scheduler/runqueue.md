---
title: "Runqueue"
category: concept
tags: [scheduler, runqueue, per-cpu, struct-rq, smp]
subsystem: scheduler
kernel_version: "2.6.23"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/sched/runqueues/
  - https://kernel-internals.org/sched/
---

# Runqueue

## Purpose

The runqueue is the per-CPU data structure that holds all scheduling state for a single processor: which tasks are runnable, what the current time is, which task is currently executing, and the sub-queues for each scheduling class. Having one runqueue per CPU instead of a global queue is the foundational SMP scalability decision in the Linux scheduler — it eliminates contention during task selection, the hottest scheduler path.

## Mental Model

Think of each CPU as a **checkout lane at a supermarket**. Each lane (CPU) has its own queue (runqueue) and its own cashier (task selector). A store manager (load balancer) periodically checks whether some lanes are overwhelmed while others are idle and moves customers (tasks) between lanes. This way, the cashiers never need to coordinate with each other to serve the next customer — only the manager needs to take a global view, and only occasionally.

## How It Works

`struct rq` is defined in `kernel/sched/sched.h` and is instantiated once per CPU via the `runqueues` per-CPU variable. `this_rq()` returns the runqueue for the current CPU without any locking (it's per-CPU, so no other CPU can modify it concurrently); `cpu_rq(n)` returns the runqueue for CPU `n`.

The runqueue clock (`rq->clock`) is the primary time source for all scheduling decisions on that CPU. It advances in nanoseconds and is updated by `update_rq_clock()` at the start of every scheduling event. `rq->clock_task` is a parallel clock that excludes time spent in VM guest context — this matters in virtualized environments where the host may have stolen cycles that shouldn't count against the task's execution time.

Three sub-queues live embedded in the `rq`:
- `rq->cfs` — a `cfs_rq` holding fair-class tasks in a virtual-runtime-ordered red-black tree
- `rq->rt` — an `rt_rq` holding real-time tasks in a 100-priority bitmap with FIFO lists
- `rq->dl` — a `dl_rq` holding deadline tasks in an earliest-deadline-first red-black tree

`rq->curr` always points to the currently executing task. `rq->idle` points to the per-CPU idle thread, which runs when `nr_running == 0`. `rq->nr_running` is the sum of runnable tasks across all three sub-queues; it is the quick check `pick_next_task()` uses to decide whether to attempt the fair-class fast path.

All modifications to the runqueue — enqueuing, dequeuing, updating `curr` — require holding `rq->__lock`, a raw spinlock. "Raw" means it is never converted to a sleeping lock even under `CONFIG_PREEMPT_RT`; spinlocks in the scheduler core cannot sleep because they run in IRQ context. Acquiring the lock is done via `rq_lock(rq, &rf)` which also manages IRQ state through the `rq_flags` structure.

Task migration between CPUs requires locking both runqueues. The kernel uses a double-lock protocol with a fixed ordering (lower CPU number first) to prevent deadlock.

The `rq` also maintains `nr_switches` (total context switches) and per-CPU load statistics used by the load balancer. `rq->avg_idle` tracks the average time the CPU spends idle per idle period — `newidle_balance()` uses this to decide whether a migration attempt is worth the cost.

## Key Data Structures

**`struct rq`** (`kernel/sched/sched.h`) — the per-CPU root of all scheduler state.
- `__lock` — raw spinlock; must be held for all runqueue modifications
- `nr_running` — total runnable tasks across all scheduling classes
- `curr` — `task_struct *` of the currently executing task
- `idle` — `task_struct *` of this CPU's idle thread
- `clock` — monotonic nanosecond clock, updated by `update_rq_clock()`
- `clock_task` — same as `clock` minus VM guest steal time
- `cfs` — embedded `cfs_rq` for fair-class tasks
- `rt` — embedded `rt_rq` for RT tasks
- `dl` — embedded `dl_rq` for SCHED_DEADLINE tasks
- `nr_switches` — total context switches (voluntary + involuntary)
- `avg_idle` — EWMA of idle time per idle period; used by `newidle_balance()`
- `rd` — pointer to the root domain for NUMA-aware load balancing

## Key Functions / Entry Points

**`this_rq()`** (`kernel/sched/sched.h`) — returns the current CPU's `struct rq *`; per-CPU access, no lock needed.

**`cpu_rq(cpu)`** (`kernel/sched/sched.h`) — returns `struct rq *` for an arbitrary CPU; caller must ensure the target CPU won't go offline.

**`rq_lock(rq, rf)`** / **`rq_unlock(rq, rf)`** (`kernel/sched/sched.h`) — acquire/release `rq->__lock` with proper IRQ state management through the `rq_flags` structure.

**`update_rq_clock(rq)`** (`kernel/sched/core.c`) — advance `rq->clock` and `rq->clock_task`; called at the start of every scheduling event before touching per-task accounting.

**`task_rq(p)`** (`kernel/sched/sched.h`) — return the runqueue that task `p` currently lives on (read `p->cpu` under appropriate locking).

## Important Flags & Config Options

- `CONFIG_SMP` — enables per-CPU runqueues and the load balancer; on UP systems the single runqueue still uses the same structure
- `CONFIG_NUMA_BALANCING` — adds NUMA-aware fields to `struct rq` for automatic page migration
- `/proc/schedstat` — exposes per-CPU runqueue statistics including switch counts and load averages

## Interactions with Other Subsystems

- **↑ Userspace**: `sched_getaffinity(2)` / `sched_setaffinity(2)` read and constrain which runqueues a task may appear on
- **→ [[scheduler-classes]]**: Each class manages its tasks within the class-specific sub-queue embedded in `struct rq`
- **→ [[load-balancing]]**: The load balancer reads `rq->nr_running`, `rq->avg_idle`, and class-level load metrics to decide whether to migrate tasks
- **← [[interrupt-handling]]**: Timer IRQs call `scheduler_tick()` which reads `rq->clock` and drives `task_tick()` on the current class

## Design Decisions & Tradeoffs

Per-CPU runqueues eliminate the global lock bottleneck that would dominate on many-core systems. The tradeoff is load imbalance — tasks can pile up on one CPU while others idle. The load balancer compensates, but introduces migration latency and cache miss cost every time it moves a task. The design implicitly assumes that the cost of occasional migration is lower than the cost of global lock contention on every task selection. For workloads with many short tasks, this assumption sometimes breaks down; `cpuset` and `isolcpus` exist partly to create domains where migration simply doesn't happen.

## How It Has Evolved

- **Pre-2.6**: A single global runqueue protected by the BKL (Big Kernel Lock); task selection was O(n) and fully serialized
- **2.6.0 (2003)**: Per-CPU runqueues introduced with the O(1) scheduler; eliminated global lock from the hot path
- **2.6.23 (2007)**: CFS embedded `cfs_rq` inside `struct rq`, replacing the per-priority bitmap with a single red-black tree per CPU
- **3.14 (2014)**: `dl_rq` added for SCHED_DEADLINE tasks
- **4.x+**: Root domain (`rd`) and NUMA-aware fields added to support topology-aware load balancing

## Further Reading

1. [kernel-internals.org/sched/runqueues/](https://kernel-internals.org/sched/runqueues/)
2. [Scheduler documentation — kernel.org](https://static.lwn.net/kerneldoc/scheduler/index.html)

## LKML Highlights

- **O(1) scheduler introduction (2.6.0)**: Ingo Molnár's series moved from a global queue to per-CPU runqueues; the cover letter explained that global lock contention was the primary scalability bottleneck being addressed.
