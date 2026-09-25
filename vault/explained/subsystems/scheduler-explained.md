---
title: "Scheduler Subsystem — Explained"
category: explained
original: "[[scheduler]]"
subsystem: scheduler
tags: [explained, scheduler, cfs, eevdf, real-time]
converted: 2026-09-25
---

# The scheduler, explained

> Plain-language companion to [[scheduler|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

At every moment, each CPU must be running exactly one task, and something has to decide which. The goals conflict:
- **fairness:** no task is starved
- **low latency:** interactive work responds promptly
- **throughput:** batch jobs keep the CPUs busy
- **determinism:** real-time tasks run within tight time bounds

An audio thread can't wait 10 ms because a batch job happens to be "owed" CPU time, yet a runaway real-time task mustn't freeze the machine. And all of this has to scale to many cores without one global lock that every CPU fights over.

## The big picture

Think of the scheduler as a **tournament bracket played out on every scheduling decision**. Tasks are seeded into brackets by their class: deadline tasks always go straight to the finals, real-time tasks play in the semi-finals, and the great majority of tasks compete in the fair bracket. A lower bracket can never beat a higher one. Within the fair bracket, the winner is the eligible task with the earliest *virtual deadline*.

```text
 timer tick / blocking call / yield
            │
            ▼
      schedule() on this CPU ── per-CPU run queue (own lock)
            │  ask each class in order, first one with a task wins
            ▼
   stop ─▶ deadline ─▶ real-time ─▶ fair (EEVDF) ─▶ idle
            │              │             │
       earliest-      priority      tree ordered by
       deadline tree  bitmap        virtual runtime
            │
            ▼
     context switch ── load balancing moves tasks between CPUs
                       (SMT siblings → shared cache → NUMA nodes)
```

## The pieces

### Scheduling classes
Each policy needs different bookkeeping: the fair class a tree ordered by virtual runtime, real-time a priority bitmap, deadline a tree ordered by deadline. Rather than filling the core with special cases, each policy is a self-contained **class** with a fixed set of operations: add a task, remove it, pick the next one, account for the one leaving, react to a timer tick, and so on.

The five classes form a fixed chain from highest to lowest: stop, deadline, real-time, fair, idle. The core asks each in turn, and the first to offer a task wins. The **stop** class, used for CPU hotplug and migration, sits at the top so it can pre-empt even the highest real-time task with no special code: its place in the chain *is* the special case. When deadline scheduling arrived in 3.14, it slotted in above real-time by implementing the operations, with no change to the core. Because almost every task is usually fair-scheduled, the core has a shortcut that asks the fair class directly when nothing else is runnable. See [[scheduler-classes|scheduling classes]].

### The per-CPU run queue
Every CPU has its **own** run queue, so choosing the next task never means locking another CPU. It holds separate sub-queues for fair, real-time and deadline tasks, the running task, and a nanosecond clock. A second version of that clock leaves out time stolen by a hypervisor, so decisions stay accurate inside VMs. When a queue has no runnable tasks, the CPU runs its idle task. See [[runqueue|run queue]].

### The fair scheduler (CFS, now EEVDF)
This handles most tasks. Its foundation is **virtual runtime**: each task's clock advances with the CPU time it uses, scaled by its priority weight. A task at nice −5 accrues virtual time at about a third of the real rate; one at nice +5 at about three times it. Always favouring the task that's "behind" gives higher-priority tasks proportionally more CPU; each nice step works out to roughly a 10% difference. Tasks sit in a tree ordered by virtual runtime, with the leftmost cached.

Since 6.6, selection uses **EEVDF**, which adds two ideas:
- **eligibility:** a task may run only if it isn't ahead of the weighted average
- **virtual deadline:** a task's virtual runtime plus its requested slice; asking for shorter slices means earlier deadlines

The scheduler picks the eligible task with the earliest virtual deadline. A waking task is placed a little behind the average, so it gets scheduled promptly without monopolising the CPU, and pre-empts the running task if its deadline is earlier. See [[cfs-eevdf-explained|CFS/EEVDF]].

### The real-time scheduler
For tasks needing deterministic access, two standard policies:
- **FIFO:** run until blocking or yielding, with no time slice
- **round-robin:** a 100 ms slice by default, then to the back of its priority level

Priorities run from 1 to 99. A bitmap marks which levels have tasks, so finding the highest is constant time. On multi-core machines, real-time tasks get pushed to other CPUs when a higher-priority one arrives. To stop real-time tasks starving everything else, they are **throttled** by default to 950 ms out of every 1000 ms; this can be disabled. Setting these policies needs a privilege. See [[rt-scheduler|real-time scheduler]].

### Deadline scheduling
Real-time priorities are assigned by hand and prone to priority inversion. **Deadline scheduling** lets a task declare a runtime budget, a deadline, and a period instead. The kernel runs **admission control**: if the total declared utilisation would go past 100%, the request is refused. Each period, the task's budget counts down; when it hits zero the task is throttled until a timer refills it at the next period. Among deadline tasks, the one with the earliest absolute deadline runs (earliest deadline first). Unused budget from idle deadline tasks can be reclaimed (a mechanism called GRUB). See [[sched-deadline|SCHED_DEADLINE]].

### The context switch
A "needs rescheduling" flag is set on the current task and checked at safe points such as interrupt exit. The switch itself:
1. lock the run queue, refresh its clock, take the old task off the queue if it's blocking
2. pick the next task
3. switch the **address space** (loading new page tables and flushing the TLB); kernel threads borrow the previous task's page tables and avoid the flush
4. switch **registers and stack** in a small piece of architecture-specific assembly
5. in the new task, mark the old one as no longer on a CPU, which is what lets a concurrent wake-up on another CPU safely move it

See [[context-switch-explained|context switch]] and [[preemption-model|preemption model]].

### Load balancing
Per-CPU queues can drift out of balance. The kernel models the hardware as nested **scheduling domains** (hyperthread siblings, cores sharing a cache, sockets/NUMA nodes), each with its own balancing aggressiveness. Balancing happens three ways:
- **periodically**, working outward from the smallest domain and pulling from the busiest group if the imbalance passes a threshold
- **when a CPU goes idle**, pulling work at once if it's worth the migration cost
- **on wake-up**, choosing a CPU: prefer one sharing a cache with the waker, then the idlest

Load is measured with **PELT**, a decaying average in which history older than about 32 ms counts for under 1%. On mixed big/little CPUs, a task using more than 80% of a small core's capacity is flagged as a "misfit" and moved to a bigger one. See [[load-balancing-explained|load balancing]].

### CPU cgroups
Containers need isolation: one mustn't starve another by spawning endless threads. Each group gets its own per-CPU fair queue plus a scheduling entity that competes in its parent's queue with the group's weight, a two-level hierarchy.
- **soft limit (weight):** proportional shares
- **hard limit (bandwidth):** a quota per period, e.g. 50 ms per 100 ms. Each CPU borrows 5 ms slices from the group's pool; when the pool is empty, the group's queues are throttled until a timer refills it at the next period.

See [[cpu-cgroups-explained|CPU cgroups]] and [[cgroups-explained|cgroups]].

## A request's journey

A task blocks on an empty pipe and is later woken:

1. **Block.** The task marks itself as sleeping and calls the scheduler, which removes it from its CPU's fair queue and switches to someone else.
2. **Wake.** Data arrives; the writer wakes the reader. The wake-up path waits until the task has fully left its old CPU (that "on a CPU" marker from the context switch).
3. **Choose a CPU.** Wake-up placement prefers a CPU sharing a cache with the waker, then the idlest suitable one.
4. **Queue it.** The task goes back into that CPU's fair queue, placed a little behind the average virtual runtime.
5. **Pre-empt?** This is the key moment. If the woken task's virtual deadline is earlier than the running task's, the target CPU is flagged for rescheduling. That's how EEVDF gets a latency-sensitive wake-up onto the CPU quickly without a pile of special-case heuristics.
6. **Switch.** At the next safe point, the scheduler picks the task with the earliest eligible deadline and context-switches to it.

## Tradeoffs

- **What it gives you:** pluggable policies for everything from batch to hard deadlines, no global lock, principled latency through virtual deadlines, and container isolation.
- **What it costs / requires:** per-CPU queues can leave one CPU overloaded while another idles, so load balancing has to fix it, at the price of migration latency and cache misses. Fairness is approximate within a scheduling window; shorter windows mean more switches. The class abstraction gives up some optimisation, clawed back by the fair-class shortcut.
- **Where it bites:** the default 95% real-time cap can delay real-time tasks by up to 50 ms in the worst case, fine for most real-time work but not hard real-time, which needs the fully pre-emptible kernel. Group bandwidth throttling has had recurring bugs where refills raced with throttling, stalling tasks indefinitely (2016–2019).

## How it got here

- **Up to 2.4:** a scheduler that scanned every runnable task, adequate at small scale.
- **2.6.0 (2003):** Ingo Molnár's O(1) scheduler, with a 140-priority bitmap but opaque interactivity heuristics.
- **2.6.23 (2007):** CFS replaced it, refining Con Kolivas's ideas, with virtual runtime making fairness auditable; scheduling classes arrived at the same time. In 2.6.25, Linus pushed back on the 95% real-time cap, and the compromise was to make it tunable.
- **3.14 (2014):** deadline scheduling with admission control.
- **3.x–5.x:** PELT load tracking; energy-aware placement on mixed CPUs.
- **6.6 (2023):** EEVDF replaced CFS's task selection. Peter Zijlstra's cover letter argued CFS's wake-up heuristics had become unmaintainable, tuned for one workload at the expense of others, and virtual deadlines subsume most of them. Refinement continues: latency-nice (a per-task request for shorter slices), adaptive pre-emption, and experimental machine-learning load balancing.

## Related

- Technical version: [[scheduler]]
- [[scheduler-classes|Scheduling classes]], [[runqueue|Run queue]], [[cfs-eevdf-explained|CFS/EEVDF]], [[rt-scheduler|Real-time scheduler]], [[sched-deadline|SCHED_DEADLINE]], [[context-switch-explained|Context switch]], [[load-balancing-explained|Load balancing]], [[cpu-cgroups-explained|CPU cgroups]], [[preemption-model|Preemption model]], [[pi-mutexes|PI mutexes]]
- [[cgroups-explained|cgroups]], [[locking-explained|Locking]], [[interrupt-handling-explained|Interrupt handling]], [[mm-explained|Memory management]], [[numa-memory-policy|NUMA memory policy]]
