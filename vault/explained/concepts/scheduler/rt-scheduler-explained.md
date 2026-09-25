---
title: "RT Scheduler — Explained"
category: explained
original: "[[rt-scheduler]]"
subsystem: scheduler
tags: [explained, scheduler, real-time, sched-fifo, throttling]
converted: 2026-09-25
---

# The real-time scheduler, explained

> Plain-language companion to [[rt-scheduler|the technical note]]. Same facts, fewer identifiers.

## The problem

Some tasks, such as audio servers, industrial controllers and network packet processors, need the CPU within a bounded time no matter what else is running. A "fair share" is meaningless when an audio buffer must be filled within 5 ms. What's needed is the opposite of fairness: a strict rule that a more important task **always** runs before a less important one. But a strictly unfair scheduler also lets one misbehaving task freeze the whole machine.

## The idea in one paragraph

The real-time scheduler is a **military rank system**. A general (priority 99) can always interrupt a private (priority 1). Within a rank there are two customs: **FIFO**, where whoever arrived first keeps going until they leave, and **round-robin**, where everyone of that rank takes turns. There's no virtual runtime and no fairness; rank is everything. Any real-time task outranks every normal task. A safety valve, **throttling**, keeps a small slice of CPU for everyone else by default.

## Step by step

### Step 1: Pick a policy and a priority
A task becomes real-time through a system call, which requires a privilege. Priorities run from 1 (lowest) to 99 (highest), the opposite direction from nice values.
- **FIFO:** runs until it blocks, yields, or is pre-empted by something higher. No time slice; among equals, the first to become runnable keeps the CPU until it yields.
- **Round-robin:** the same, but with a time slice (100 ms by default, adjustable). When it runs out, the task goes to the back of its priority level and gets a fresh slice, giving its peers a turn.

### Step 2: Queue it by priority
Each CPU's real-time queue is an array of lists, one per priority, plus a **bitmap** with one bit per level. When a task becomes runnable at priority P, bit P is set and the task is added to the end of list P.

### Step 3: Pick the next task in one instruction
This is the key step. To choose, the scheduler finds the first set bit in the bitmap, which is a single hardware instruction, and takes the head of that list. The cost is effectively constant no matter how many tasks are waiting. A tree or heap could handle more levels, but with only 99 priorities, the bitmap is the best fit.

### Step 4: Spread across CPUs
On multi-core machines, each CPU keeps a list of "pushable" tasks: real-time tasks that are runnable but not running. When a task arrives on a CPU already running a higher-priority one, the scheduler looks for another CPU where it would win, starting nearby to keep migration cheap. A CPU that becomes idle can also pull a waiting real-time task.

### Step 5: Throttle as a safety valve
Real-time tasks may by default use at most **950 ms of every 1000 ms**. When a CPU's real-time tasks use up their share, its real-time queue is throttled and a timer restores it at the next period. That reserved 5% lets normal tasks still run, even against misbehaving real-time processes. Setting the limit to "unlimited" disables throttling, which most real-time deployments do.

## The picture

```text
 priority bitmap:  99 98 … 50 … 10 … 1
                    0  0    1    1    0     ← first set bit = 50 (one instruction)
 queues:  [50] → irq-thread → audio-A → audio-B    (FIFO order within a level)
          [10] → logger
 normal (fair) tasks run only when every real-time level is empty
 throttle: ≤ 950 ms of real-time per 1000 ms, unless disabled
```

## Tradeoffs

- **What it gives you:** predictable, strictly prioritised scheduling with constant-time selection, as required by the POSIX real-time policies.
- **What it costs / requires:** deliberate unfairness. A priority-99 task can starve everything below it forever, which is why throttling exists. Interrupt threads run as FIFO priority 50 by default, above normal tasks but below explicitly high-priority real-time applications.
- **Where it bites:** real-time tasks sharing a lock can hit priority inversion unless the lock uses [[pi-mutexes-explained|priority inheritance]]. The default throttle is a compromise: some real-time applications legitimately want all of the CPU, so they disable it.

## How it got here

- **1.x:** POSIX real-time policies existed but were basic, with no multiprocessor support.
- **2.6.0:** per-CPU real-time queues and pushable tasks for multiprocessor balancing.
- **2.6.25 (2008):** throttling with the 95% default. Linus pushed back, arguing real-time applications should get full CPU; the compromise was a tunable setting rather than always enforcing it or removing it.
- **2.6.29:** real-time group scheduling.
- **~5.15+:** the real-time pre-emption work (Thomas Gleixner, Steven Rostedt), turning spinlocks into priority-inheriting sleeping locks, made the kernel itself suitable for hard real-time. See [[preemption-model-explained|preemption model]].

## Related

- Technical version: [[rt-scheduler]]
- [[scheduler-explained|Scheduler]], [[pi-mutexes-explained|PI mutexes]], [[preemption-model-explained|Preemption model]], [[sched-deadline|SCHED_DEADLINE]], [[runqueue|Run queue]], [[load-balancing-explained|Load balancing]]
- [[locking-explained|Locking]], [[interrupt-handling-explained|Interrupt handling]]
