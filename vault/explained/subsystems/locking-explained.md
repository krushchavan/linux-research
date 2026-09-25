---
title: "Locking Subsystem — Explained"
category: explained
original: "[[locking]]"
subsystem: locking
tags: [explained, locking, spinlocks, mutexes, lockdep]
converted: 2026-09-25
---

# The kernel locking subsystem, explained

> Plain-language companion to [[locking|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

The kernel runs on many CPUs at once, and interrupts can break in at almost any moment. Whenever two of them touch the same data (a list, a counter, an inode) without coordination, the data gets corrupted. So the kernel needs ways to take turns.

No single tool fits every case. Interrupt handlers can't sleep, so they need locks that wait by spinning. Long operations in normal task context should sleep rather than burn a CPU. Data read constantly but written rarely should be readable without taking any lock. And with thousands of locks in play, some ordering mistake that could deadlock is almost inevitable, and ideally should be caught before it ever happens in production.

## The big picture

Think of the subsystem as a **toolkit organised by execution context**. Hard interrupts can preempt everything, then soft interrupts, then kernel threads and process context. The golden rule: **never do something a tier can't tolerate**. You can't sleep while holding a spinning lock, and you can't take a sleeping lock from interrupt context. Pick the primitive that fits the most restrictive context that will ever hold it.

```text
 context               can use
 hard interrupt   ──▶  raw spinlocks
 soft interrupt   ──▶  raw spinlocks, spinlocks, local locks
 task context     ──▶  everything: spinlocks, seqlocks, mutexes, rt-mutexes,
                       read/write semaphores, wound/wait mutexes, RCU, per-CPU data, atomics

 lockdep watches every acquisition ──▶ reports possible deadlocks the first time they're possible
```

## The pieces

### Spinlocks
For code that must never sleep (interrupt handlers, soft interrupts, short bounded sections), a spinlock makes a waiting CPU busy-wait instead of queuing in the scheduler. Since 3.15 it's a **queued spinlock** packed into one 32-bit word: a "locked" byte, a "pending" bit, and a pointer to the tail of a queue of waiters. The first extra waiter sets the pending bit; later ones join a queue, each spinning on **its own** per-CPU node. On release, only the next waiter in line is signalled.

The older ticket lock had every waiter spinning on the same shared word, so each release set off a storm of cache-line traffic across CPUs. Queuing removes that. Taking a spinlock also disables preemption (and optionally interrupts), and on single-CPU builds it compiles down to preemption toggling alone.

On real-time kernels (PREEMPT_RT), an ordinary spinlock becomes a sleeping lock so high-priority tasks can preempt the holder. Code that truly can't sleep, such as low-level interrupt and clock code, uses a **raw** spinlock, which always spins. See [[spinlock-and-raw-spinlock-explained|spinlocks]].

### Mutexes
A mutex lets waiters **sleep** during long critical sections in task context. Its owner field holds the owning task plus flags: waiters present, hand the lock directly to the next waiter, next waiter picking it up. Taking it has three paths:
1. **Fast:** one atomic compare-and-swap on an unowned lock, and that's the whole cost.
2. **Middle (optimistic spinning):** if the owner is *running* on another CPU, it'll probably release soon, so spin briefly in a queue rather than sleep and wake. Give up if the owner is preempted.
3. **Slow:** join the wait list and sleep. On unlock, if the handoff flag is set, the lock goes straight to the first waiter, so it isn't beaten by a newcomer.

**RT mutexes** add **priority inheritance**: if a high-priority task waits on a lock held by a low-priority one, the holder is temporarily boosted, along the whole chain if the holder is itself waiting. **Wound/wait mutexes** help graphics drivers that must take a changing set of locks: each attempt carries a global ticket, and a newer one blocking an older one is "wounded" and must back off and retry, guaranteeing progress. See [[mutex-explained|mutexes]].

### Read/write semaphores
These let **many readers or one writer** in: good for read-heavy structures like inodes, address spaces and memory maps. One word holds a writer bit, flags, and a reader count. Readers add to the count if no writer holds or waits for the lock; a writer sets its bit when the count is empty, otherwise it queues. Both sides can spin optimistically while the owner runs. A handoff flag (5.2) stops a steady stream of readers from starving writers. On release, a writer wakes the next writer, or all readers queued at the front. See [[rwsem-reader-writer-semaphore-explained|read/write semaphores]].

### Sequence locks
For small data read constantly and written rarely, such as the kernel's timekeeping, readers take **no lock at all**. A counter goes odd while a write is in progress and even when it's done. A reader notes the counter, reads the data, and checks the counter again; if it changed or was odd, it retries. A spinlock alongside keeps writers from colliding with each other. Typed variants (5.10) tell lockdep which lock serialises the writers, and a "latch" variant keeps two copies so a reader, even in an NMI, can always find a consistent one. See [[seqlocks-and-memory-barriers-explained|sequence locks]].

### Local locks
Protecting per-CPU data used to mean bare "disable preemption" calls. A **local lock** names that critical section. On normal kernels it still just disables preemption (or interrupts), with no lock object at all. On RT kernels it becomes a real per-CPU lock that can be preempted, and in both cases lockdep can see it and catch misuse. See [[local-lock-explained|local locks]].

### Lockdep
This is the key safety tool. **Lockdep** watches every lock acquisition and builds a graph of "held A, then took B" edges between lock **classes** (lock types, not each individual lock). As soon as a new edge would close a cycle, meaning some order of events *could* deadlock, it reports it with a full trace, even though no deadlock has actually happened.

It also checks interrupt safety: a lock ever taken in an interrupt handler must never be taken elsewhere with interrupts enabled, or an interrupt arriving at the wrong moment would deadlock. Each class records which contexts it has been used in. Validated chains of held locks are remembered by hash, so repeats skip the graph search. Tracking classes instead of instances keeps memory bounded (typically under 10,000 classes), rather than one entry per inode lock among millions. See [[lockdep-explained|lockdep]].

### Futexes
User-space mutexes are built on **futexes**: a 32-bit word in user memory. Uncontended locking is one atomic operation in user space, with no system call. Only under contention does the library call the kernel to **wait** on the word; the kernel files the waiter in a global hash table (by address and process, or by page for shared futexes) and puts it to sleep. A **wake** call walks the matching bucket and wakes waiters. Priority-inheritance futexes track the owner in the word and boost it through RT mutexes, robust lists clean up after threads that die holding locks, and a wait-on-many call (5.16) lets games and runtimes wait on several words at once. See [[futex-internals-explained|futexes]].

## A request's journey

Task B wants a mutex that task A holds:

1. **Fast path fails.** B's compare-and-swap finds the lock owned.
2. **Spin while it's worth it.** A is running on another CPU, so B joins the optimistic-spin queue, spinning on its own node rather than the shared lock.
3. **Owner preempted.** A's time slice ends. B sees A is no longer on a CPU, leaves the spin queue, and takes the slow path.
4. **Sleep.** B adds itself to the wait list, sets the waiters flag, and sleeps.
5. **Handoff.** A later unlocks, sees the waiters flag, and wakes B, which takes the lock. This is the key point: B only paid for sleeping once spinning had stopped being a good bet.

Lockdep checks every step: had B been holding some other lock X, and A were ever seen taking X while holding this mutex, lockdep would report the potential deadlock at once.

## Tradeoffs

- **What it gives you:** a primitive for every context and access pattern, scalable spinning without cache storms, sleeping locks that avoid needless sleeps, lock-free reads where it matters, priority inheritance for real-time, and deadlock detection before deadlocks happen.
- **What it costs / requires:** knowing which primitive is legal where; more complex lock code (queues, handoffs, flags); lockdep's runtime overhead in debug builds.
- **Where it bites:** sleeping in the wrong context, interrupt-unsafe nesting, and the raw-versus-ordinary spinlock split on RT kernels. Lockdep's class limit (8,191 by default) is sometimes hit on large modular systems, and the futex hash table (256 to 4,096 buckets) can become a bottleneck with thousands of threads.

## How it got here

- **2.4 → 2.6:** removing the Big Kernel Lock, which had serialised the whole kernel, in favour of fine-grained locking for SMP.
- **2.6.18 (2006):** lockdep (Ingo Molnar). **2.6.25 (2008):** priority-inheritance and robust futexes.
- **3.0 (2011):** optimistic spinning in mutexes. **3.15 (2014):** queued spinlocks replace ticket locks.
- **4.0 (2015):** local locks from the RT tree. **4.13 (2017):** reader optimistic spinning in read/write semaphores. **5.2 (2019):** the read/write semaphore rework with handoff (Waiman Long).
- **5.16 (2022):** waiting on multiple futexes. **Ongoing:** NUMA-aware queued spinlocks (Peter Zijlstra, Waiman Long) that prefer handing the lock to the same node, bigger futex tables, and continued PREEMPT_RT mainlining.

## Related

- Technical version: [[locking]]
- [[spinlock-and-raw-spinlock-explained|Spinlocks]], [[mutex-explained|Mutexes]], [[rwsem-reader-writer-semaphore-explained|Read/write semaphores]], [[seqlocks-and-memory-barriers-explained|Sequence locks]], [[local-lock-explained|Local locks]], [[lockdep-explained|Lockdep]], [[futex-internals-explained|Futexes]]
- [[rcu-read-copy-update-explained|RCU]], [[per-cpu-variables-explained|Per-CPU variables]], [[interrupt-handling-explained|Interrupt handling]]
- [[vfs-locking-model-explained|VFS locking model]], [[scheduler|Scheduler]]
