---
title: "Scheduler Classes"
category: concept
tags: [scheduler, sched-class, scheduling-policy, vtable, real-time]
subsystem: scheduler
kernel_version: "2.6.23"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/sched/scheduler-classes/
  - https://kernel-internals.org/sched/
---

# Scheduler Classes

## Purpose

Different scheduling policies — proportional fairness for desktop tasks, fixed-priority preemption for audio servers, bandwidth-guaranteed slots for real-time control loops — make fundamentally incompatible assumptions about their data structures and selection algorithms. Embedding all three as conditionals inside the scheduler core would make it unmaintainable; scheduling classes solve this by encapsulating each policy behind a common vtable.

## Mental Model

Think of scheduling classes as **elevator dispatch algorithms** inside a building. Each floor (CPU) has a dispatcher (the scheduler core) that doesn't know or care whether it's running a FIFO-style algorithm or a deadline-based one — it just calls the dispatcher's API. The building management decides which algorithm to plug in at each floor; the algorithm itself handles the details. The building always checks penthouse (stop class) first, then executive (deadline), then normal floors (fair/idle).

## How It Works

The mechanism starts with `struct sched_class`, a vtable defined in `kernel/sched/sched.h`. Every scheduling policy registers its own instance of this structure with the functions it implements. Five classes exist in the current kernel, forming a statically ordered priority chain:

1. `stop_sched_class` — for `stop_machine()`, CPU hotplug, and task migration helpers; must preempt everything
2. `dl_sched_class` — `SCHED_DEADLINE` tasks with CBS bandwidth guarantees
3. `rt_sched_class` — `SCHED_FIFO` and `SCHED_RR` real-time tasks
4. `fair_sched_class` — `SCHED_NORMAL`, `SCHED_BATCH`, and `SCHED_IDLE` (the vast majority of processes)
5. `idle_sched_class` — the per-CPU idle thread; always runnable, never selected over anything else

`__schedule()` in `kernel/sched/core.c` drives task selection. After locking the runqueue and updating the clock, it calls `pick_next_task(rq, prev, &rf)`. This function iterates the chain from `stop_sched_class` downward, calling each class's `pick_next_task` callback. The first class that returns a non-NULL task wins — that task runs next. Lower classes never execute unless all higher-priority classes have nothing runnable.

The chain ordering handles cases that would otherwise require special-casing. The stop class must preempt SCHED_FIFO priority-99 RT tasks during CPU migrations; placing it first in the chain achieves this without any `if (is_stop_task)` checks in the core.

Because the fair class handles the overwhelming majority of tasks on typical systems, `pick_next_task()` includes an optimization: if `nr_running == cfs_rq.nr_running` (all tasks are CFS), it bypasses the chain and calls `pick_next_task_fair()` directly, saving the vtable traversal overhead.

When SCHED_DEADLINE was added in Linux 3.14, it slotted into the chain above RT purely by implementing the `sched_class` interface. No changes to `__schedule()` or any other class were needed — the extensibility the architecture promised in 2.6.23 was validated a decade later.

Each task's `task_struct` carries a pointer `sched_class` that identifies which class manages it. When a task changes policy via `sched_setscheduler()`, the kernel calls `dequeue_task()` on the old class, updates `p->sched_class`, and calls `enqueue_task()` on the new class.

## Key Data Structures

**`struct sched_class`** (`kernel/sched/sched.h`) — vtable binding a scheduling policy to the scheduler core.
- `enqueue_task` — called when a task becomes runnable (wakeup, fork, policy change)
- `dequeue_task` — called when a task blocks, exits, or migrates
- `pick_next_task` — returns the best runnable task; NULL if none
- `put_prev_task` — account for the outgoing task before picking the next (update stats, re-queue if still runnable)
- `set_next_task` — called after the next task is chosen; update class state
- `task_tick` — timer interrupt callback: advance accounting, check preemption
- `prio_changed` — react to `setpriority()` / `sched_setparam()` without requeuing if unnecessary
- `update_curr` — refresh runtime accounting (vruntime for fair, budget for deadline)
- `switched_to` — called after a task's class changes; allows the new class to initialize state

## Key Functions / Entry Points

**`pick_next_task()`** (`kernel/sched/core.c`) — outer scheduler loop; walks the class chain until a runnable task is found, with a fair-class fast path.

**`enqueue_task()`** / **`dequeue_task()`** (`kernel/sched/core.c`) — wrappers that call the class-specific enqueue/dequeue callbacks and update `rq->nr_running`.

**`sched_setscheduler()`** (`kernel/sched/core.c`) — userspace-visible function that changes a task's scheduling class with appropriate locking, PI (priority inheritance) checks, and class transitions.

## Important Flags & Config Options

- `CONFIG_FAIR_GROUP_SCHED` — enables group scheduling within the fair class (needed for CPU cgroup weight control)
- `CONFIG_RT_GROUP_SCHED` — enables group scheduling for RT tasks
- `CONFIG_SCHED_DEBUG` — exposes `/proc/sched_debug` with per-task class details and runqueue state

## Interactions with Other Subsystems

- **↑ Userspace**: `sched_setscheduler(2)`, `sched_setattr(2)` change `p->sched_class`; `nice(1)` and `renice(1)` adjust weight within the fair class
- **→ [[runqueue]]**: Each class manages tasks within a class-specific sub-queue inside `struct rq` (`cfs_rq`, `rt_rq`, `dl_rq`)
- **← [[interrupt-handling]]**: Timer ticks call `task_tick` on the current task's class; IRQ threads run under `rt_sched_class`
- **← [[locking]]**: `rq->__lock` must be held when calling class vtable functions that modify runqueue state

## Design Decisions & Tradeoffs

The vtable abstraction trades raw performance for modularity. An if-else chain would theoretically allow the compiler to inline all three paths; vtable dispatch prevents this. The fast path (bypassing the chain when all tasks are fair) is the primary concession to performance — it recovers most of the overhead for the common case.

The five-class hard-coded chain (rather than a dynamic registration system) was a deliberate choice: dynamic ordering would require runtime priority management between classes, reintroducing the complexity the static chain avoids. New "classes" that don't need to fit between existing ones (e.g., SCHED_NORMAL variants) are instead added as policies within the fair class.

## How It Has Evolved

- **2.6.23 (2007)**: Classes introduced alongside CFS; four classes at launch (stop, RT, fair, idle)
- **3.14 (2014)**: SCHED_DEADLINE adds `dl_sched_class` between RT and stop; validates the extensible design
- **4.x**: `set_next_task` callback added to allow classes to do post-selection setup
- **6.6 (2023)**: Fair class internals replaced by EEVDF; class interface unchanged, demonstrating isolation

## Further Reading

1. [CFS Scheduler Design — kernel.org](https://static.lwn.net/kerneldoc/scheduler/sched-design-CFS.html) — covers the class system at introduction
2. [kernel-internals.org/sched/scheduler-classes/](https://kernel-internals.org/sched/scheduler-classes/)

## LKML Highlights

- **CFS introduction (2007)**: Ingo Molnár's cover letter for the CFS patch introduced the class abstraction, framing it as essential for adding SCHED_DEADLINE later without touching the core.
- **SCHED_DEADLINE merge (3.14)**: Juri Lelli's series added `dl_sched_class` with zero changes to `__schedule()`, demonstrating the design's extensibility exactly as promised.
