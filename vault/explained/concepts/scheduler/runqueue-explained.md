---
title: "Runqueue — Explained"
category: explained
original: "[[runqueue]]"
subsystem: scheduler
tags: [explained, scheduler, runqueue, smp]
converted: 2026-09-25
---

# The run queue, explained

> Plain-language companion to [[runqueue|the technical note]]. Same facts, fewer identifiers.

## The problem

Picking the next task to run is the scheduler's hottest path, happening constantly on every CPU. With one global queue of runnable tasks, every CPU would have to lock the same structure each time, and on many-core machines that lock would dominate everything. Before 2.6, that's roughly how it worked: one global queue under the Big Kernel Lock, scanned in full every time.

## The idea in one paragraph

Give each CPU its **own run queue**, like a supermarket where each checkout lane has its own line and cashier. Cashiers never coordinate to serve their next customer; only a store manager (the load balancer) occasionally looks across all lanes and moves customers from crowded ones to empty ones. The run queue is the root of all scheduling state for one CPU: who is runnable, who is running, and what time it is.

## Step by step

### Step 1: One per CPU
Each CPU gets its own run queue. Code running on a CPU can reach its own queue directly; reaching another CPU's queue is also possible, as long as the caller makes sure that CPU won't go offline meanwhile.

### Step 2: What's inside
- three **sub-queues**, one per main scheduling class: a tree ordered by virtual runtime for fair tasks, a priority bitmap with lists for real-time tasks, and a tree ordered by deadline for deadline tasks
- a pointer to the **running task**, and to this CPU's **idle task**, which runs when nothing else is runnable
- a **count of runnable tasks** across all classes, which also lets the scheduler quickly decide whether it can take the fair-only shortcut
- statistics: a context-switch count, and a running average of how long this CPU tends to stay idle

### Step 3: A clock per queue
Each run queue has a nanosecond **clock**, refreshed at the start of every scheduling event. It's the time source for every decision on that CPU. A second clock leaves out time stolen by the hypervisor, so a task inside a VM isn't charged for cycles the host took away.

### Step 4: The lock
This is the key step. Every change to a run queue (adding or removing a task, switching the running task) happens under that queue's **own lock**. It's a "raw" spinlock, meaning it stays a true busy-wait lock even on real-time kernels where most spinlocks become sleeping locks, because the scheduler core runs in interrupt context and can't sleep. Taking it also handles the interrupt state. Because each CPU has its own lock, CPUs choosing their next task never contend with each other.

### Step 5: Moving a task between CPUs
Migration needs **both** run queues locked. To avoid two CPUs deadlocking by locking each other's queues in opposite order, the kernel always locks the lower-numbered CPU's queue first.

### Step 6: Feeding the load balancer
The load balancer reads each queue's runnable count, load figures and average idle time. A CPU that's about to go idle uses its typical idle time to judge whether pulling work from elsewhere is worth the migration cost.

## The picture

```text
   CPU 0 run queue [own lock]         CPU 1 run queue [own lock]
   ├─ clock / clock minus steal       ├─ …
   ├─ running: task A   idle: idle0   │
   ├─ fair tree:  B C D               │
   ├─ real-time:  (empty)             │
   ├─ deadline:   (empty)             │
   └─ runnable = 4, avg idle …        └─ runnable = 0
            ▲                                  │
            └──── load balancer: lock both (lower CPU first), move a task ◀┘
```

## Tradeoffs

- **What it gives you:** no global lock on the hottest scheduler path, so selection scales with core count.
- **What it costs / requires:** queues can drift out of balance, so tasks pile up on one CPU while another idles. The load balancer fixes this at the price of migration latency and cache misses. The design bets that occasional migration costs less than contending for a global lock on every selection.
- **Where it bites:** for workloads with many short tasks, that bet sometimes loses. Cpusets and isolated CPUs exist partly to create areas where migration doesn't happen at all.

## How it got here

- **Before 2.6:** one global queue under the Big Kernel Lock, scanned in full on every selection.
- **2.6.0 (2003):** per-CPU run queues with the O(1) scheduler. Ingo Molnár's cover letter named global lock contention as the main scalability bottleneck.
- **2.6.23 (2007):** CFS put its fair queue, a single tree per CPU, inside the run queue, replacing the per-priority bitmap for normal tasks.
- **3.14 (2014):** a deadline sub-queue for deadline scheduling.
- **4.x+:** fields for NUMA- and topology-aware load balancing.

## Related

- Technical version: [[runqueue]]
- [[scheduler-explained|Scheduler]], [[scheduler-classes-explained|Scheduling classes]], [[load-balancing-explained|Load balancing]], [[context-switch-explained|Context switch]], [[cfs-eevdf-explained|CFS/EEVDF]], [[rt-scheduler-explained|Real-time scheduler]], [[sched-deadline-explained|SCHED_DEADLINE]]
- [[spinlock-and-raw-spinlock-explained|Spinlocks]], [[interrupt-handling-explained|Interrupt handling]]
