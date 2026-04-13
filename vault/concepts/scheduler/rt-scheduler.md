---
title: "RT Scheduler"
category: concept
tags: [scheduler, real-time, sched-fifo, sched-rr, priority, rt-throttle]
subsystem: scheduler
kernel_version: "2.6.0"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/sched/rt-scheduler/
  - https://kernel-internals.org/sched/
---

# RT Scheduler

## Purpose

Some tasks — audio servers, industrial controllers, network packet processors — need the CPU within a bounded time window regardless of what else is running. The nice-value fairness of CFS cannot provide this: a fair share is meaningless when you need to play an audio buffer within 5ms. The RT scheduler provides fixed-priority preemptive scheduling where a higher-priority task always runs before any lower-priority task, period.

## Mental Model

The RT scheduler is a **military rank system**: a general (priority 99) can always interrupt a private (priority 1). Within the same rank, `SCHED_FIFO` means "whoever arrived first stays until they leave"; `SCHED_RR` means "everyone in the same rank gets a rotation". There's no fairness or virtual runtime — rank is everything, and the highest rank always wins.

## How It Works

The RT scheduler implements two POSIX-mandated policies, both visible to userspace via `sched_setscheduler(2)`:

**SCHED_FIFO**: A task runs until it explicitly yields, blocks, or is preempted by a higher-priority task. There is no timeslice. If two SCHED_FIFO tasks share the same priority, the one that became runnable first runs until it voluntarily yields.

**SCHED_RR**: Like SCHED_FIFO but with a default 100ms timeslice (configurable via `/proc/sys/kernel/sched_rr_timeslice_ms`). On each timer tick, `task_tick_rt()` decrements `sched_rt_entity.time_slice`. When it reaches zero, the task is moved to the back of its priority level's queue and the timeslice is reset — giving other tasks at the same priority a turn.

RT priorities run from 1 (lowest) to 99 (highest), the inverse of nice values (which run -20 to +19). Priority 99 RT > priority 1 RT > any CFS task.

The per-CPU `rt_rq` structure uses a bitmap-plus-FIFO-lists design for O(1) task selection. `struct rt_prio_array` contains a 101-bit bitmap (one bit per priority level, plus a sentinel) and an array of list heads. When a task at priority P becomes runnable, bit P is set in the bitmap and the task is appended to `queue[P]`. Selection via `pick_next_task_rt()` calls `sched_find_first_bit()` on the bitmap — a single hardware instruction — then takes the head of the resulting list. On most hardware this is effectively O(1) regardless of how many tasks are queued.

On SMP systems, the RT scheduler maintains "pushable tasks" lists: RT tasks that are runnable but not currently executing and could be migrated. When an RT task at priority P is enqueued on a CPU that already has a higher-priority RT task running, `push_rt_task()` scans other CPUs for one where priority P would win. The scanning starts from the current CPU's scheduling domain to minimize migration cost.

**RT bandwidth throttling** prevents RT tasks from starving the entire system. The kernel maintains a global RT runtime budget: by default, RT tasks may consume at most 950ms out of every 1000ms period. These are controlled by:
- `/proc/sys/kernel/sched_rt_period_us` (default: 1,000,000 — one second)
- `/proc/sys/kernel/sched_rt_runtime_us` (default: 950,000 — 95%)

When a CPU's RT tasks have consumed their per-CPU share (derived from the global budget), `sched_rt_runtime_exceeded()` throttles the `rt_rq` and sets a timer to restore it at the next period boundary. Setting `sched_rt_runtime_us` to -1 disables throttling entirely — useful for `CONFIG_PREEMPT_RT` systems where RT tasks must never be delayed.

## Key Data Structures

**`struct sched_rt_entity`** (`include/linux/sched.h`) — embedded in `task_struct`; RT-specific scheduling state.
- `run_list` — `list_head` for position in the per-priority FIFO queue
- `time_slice` — remaining RR timeslice in jiffies; not used for SCHED_FIFO
- `timeout` — RLIMIT_RTTIME watchdog counter
- `on_rq` / `on_list` — membership flags (on runqueue, on FIFO list)

**`struct rt_prio_array`** (`kernel/sched/sched.h`) — the O(1) priority-indexed structure.
- `bitmap[DECLARE_BITMAP(101)]` — one bit per priority; set when that level has runnable tasks
- `queue[100]` — per-priority `list_head`; tasks at the same priority queue here

**`struct rt_rq`** (`kernel/sched/sched.h`) — per-CPU RT runqueue.
- `active` — the `rt_prio_array` for this CPU
- `rt_nr_running` — count of runnable RT tasks
- `rt_nr_boosted` — tasks running above their normal priority (via PI)
- `rt_throttled` — set when the CPU's RT quota is exhausted

## Key Functions / Entry Points

**`enqueue_task_rt()`** (`kernel/sched/rt.c`) — add an RT task to the priority bitmap and FIFO list on wakeup or migration.

**`pick_next_task_rt()`** (`kernel/sched/rt.c`) — bitmap scan → highest-priority non-empty queue → head of that queue's FIFO list.

**`task_tick_rt()`** (`kernel/sched/rt.c`) — timer tick: decrement RR timeslice, requeue on expiry; check RT bandwidth.

**`push_rt_task()`** / **`pull_rt_task()`** (`kernel/sched/rt.c`) — SMP migration: push an overflowing RT task to a less-loaded CPU, or pull an RT task to a newly idle CPU.

**`sched_rt_runtime_exceeded()`** (`kernel/sched/rt.c`) — check if the current period's RT budget is exhausted; throttle the `rt_rq` if so.

## Important Flags & Config Options

- `CAP_SYS_NICE` — required to set SCHED_FIFO or SCHED_RR; without it, `sched_setscheduler()` returns `-EPERM`
- `/proc/sys/kernel/sched_rt_period_us` — throttling period (default 1s)
- `/proc/sys/kernel/sched_rt_runtime_us` — RT budget per period (-1 = unlimited)
- `/proc/sys/kernel/sched_rr_timeslice_ms` — SCHED_RR timeslice (default 100ms)
- `CONFIG_PREEMPT_RT` — converts spinlocks to sleeping mutexes, enabling full kernel preemptibility for RT tasks; see [[preemption-model]]

## Interactions with Other Subsystems

- **↑ Userspace**: `sched_setscheduler(2)`, `sched_setparam(2)` set RT priority; `pthread_setschedparam(3)` for threads
- **→ [[runqueue]]**: RT tasks live in `rq->rt` (`rt_rq`); RT bandwidth timer fires on the per-CPU hrtimer
- **→ [[locking]]**: `pthread_mutexattr_setprotocol(PTHREAD_PRIO_INHERIT)` enables PI (priority inheritance) for RT mutexes, implemented via `rt_mutex` in the kernel; see [[pi-mutexes]]
- **← [[interrupt-handling]]**: IRQ threads run as SCHED_FIFO priority 50 by default, placing them above normal CFS tasks but below explicit RT applications

## Design Decisions & Tradeoffs

**Fixed priorities vs. fairness**: RT scheduling is explicitly unfair — a priority-99 task can run forever and starve everything else. This is the desired behavior for real-time applications. The safety valve is RT bandwidth throttling, which reserves a CPU fraction for normal tasks even against misbehaving RT processes.

**Bitmap O(1) vs. more complex structures**: A heap or tree would support more priority levels but RT priority levels (1–99) are bounded and small. The bitmap with hardware bit-scan is optimal for this constrained range.

**Throttling at 95% by default**: Linus pushed back on this default in 2.6.25, arguing legitimate RT applications should have full CPU access. The compromise: make it a sysctl knob (set to -1 to disable) rather than either enforcing it always or removing it. Most real-time deployments disable throttling.

## How It Has Evolved

- **Linux 1.x**: POSIX RT scheduling present but rudimentary; no SMP support
- **2.6.0**: Per-CPU RT runqueues; pushable tasks for SMP load balancing
- **2.6.25 (2008)**: RT bandwidth throttling added; the 95% default and its sysctl
- **2.6.29**: RT group scheduling (`CONFIG_RT_GROUP_SCHED`)
- **PREEMPT_RT (mainlined ~5.15+)**: Full kernel preemptibility, making the kernel safe for hard RT workloads

## Further Reading

1. [kernel-internals.org/sched/rt-scheduler/](https://kernel-internals.org/sched/rt-scheduler/)
2. [Real-Time Linux Foundation — EDF scheduling paper (LWN)](https://static.lwn.net/images/conf/rtlws11/papers/proc/p16.pdf)

## LKML Highlights

- **RT throttling controversy (2.6.25)**: Linus's thread questioning the 95% default and the resulting decision to make it tunable rather than remove it entirely.
- **PREEMPT_RT mainlining**: The multi-year effort to merge the real-time preemption patch; Thomas Gleixner and Steven Rostedt's series converting spinlocks to `rt_mutex`.
