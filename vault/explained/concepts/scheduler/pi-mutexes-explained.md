---
title: "PI Mutexes (Priority Inheritance) — Explained"
category: explained
original: "[[pi-mutexes]]"
subsystem: scheduler
tags: [explained, scheduler, priority-inheritance, rt-mutex, real-time]
converted: 2026-09-25
---

# PI mutexes, explained

> Plain-language companion to [[pi-mutexes|the technical note]]. Same facts, fewer identifiers.

## The problem

Under fixed-priority scheduling, a nasty three-way trap exists, called **priority inversion**:
1. a high-priority task H waits for a lock held by a low-priority task L
2. a medium-priority task M becomes runnable and, correctly, pre-empts L
3. L never runs, so it never releases the lock, so H never runs either

Every scheduling decision was "right", yet the most important task is stuck behind the least important one indefinitely. On a real-time system that means missed deadlines or a watchdog reset; the Mars Pathfinder mission hit exactly this in 1997. Without a fix, real-time guarantees collapse as soon as two tasks share a single lock.

## The idea in one paragraph

Picture a VIP car stuck behind a delivery truck parked in the VIP lane, waiting to pull into a loading bay, while a city bus keeps cutting in front of the truck. **Priority inheritance** gives the truck a temporary VIP pass: the lock holder is raised to the priority of its most important waiter, so the medium task can no longer get in the way. The holder finishes and releases the lock quickly, and the pass disappears the moment it does.

## Step by step

### Step 1: A special kind of lock
Linux does this with a dedicated lock type, the **rt_mutex**, separate from the ordinary mutex. It records its **owner** and keeps a **priority-sorted tree of waiters** (first-come-first-served among equal priorities). One spare bit of the owner field says "there are waiters", which forces unlock through the careful slow path.

### Step 2: The fast path
If the lock is free, one atomic compare-and-swap writes the caller in as owner. No trees, no priority logic: the uncontended case costs a single atomic instruction.

### Step 3: Blocking
If the lock is held, the caller:
1. takes the lock's internal spinlock
2. tries once more to take it, succeeding only if it's free *and* the caller is the highest-priority waiter, so a lower-priority task can't steal it from a higher one that's asleep
3. otherwise, joins the waiter tree
4. if it's now the top waiter, it becomes what the owner "sees" from this lock, and the owner's priority is recomputed
5. records which lock it's blocked on, and sleeps

On wake-up it retries; a signal or timeout makes it give up with an error.

### Step 4: Keeping the owner's view cheap
Each task keeps a small tree of just the **top waiter from each lock it owns**, not every waiter of every lock. Its effective priority is then its own priority or the best entry in that small tree, found in constant time. Since a task owns few locks at once, this stays small.

### Step 5: Boosting along a chain
This is the key step. The boosted owner might itself be blocked on *another* lock, owned by another task, and so on. Following each task's "blocked on" link, the kernel walks the chain and passes the boost along. Three rules keep that walk safe:
- **at most two locks held at once:** the walk releases the lower lock before taking the next. Holding every lock along the way would create lock-order cycles with walks going the other direction; the price is re-checking state at each step.
- **stop early** once priorities stop changing
- **deadlock and abuse limits:** if the walk reaches the lock it started from, there's a cycle and it returns "deadlock". It also stops after 48 hops, so a malicious chain can't turn every lock into a CPU sink. In-kernel callers that can't be in a cycle may skip the cycle check for speed.

### Step 6: Releasing
If nobody is waiting, a compare-and-swap clears the owner. Otherwise the slow path wakes the highest-priority waiter, removes it from the owner's small tree, and **recomputes the owner's priority**, which can now drop back toward normal. The woken waiter then competes to take the lock.

### Step 7: From user space
The same machinery powers user-space priority-inheriting pthread mutexes through two futex operations. The uncontended path never enters the kernel: a compare-and-swap writes the owner's thread ID into the lock word. On contention, the kernel finds or creates a small state object for that futex containing an rt_mutex, and the waiter blocks on it with full priority inheritance. A further futex operation moves waiters from a condition variable to a PI mutex atomically, so there's no window where their priority drops.

### Step 8: Deadline tasks and the real-time kernel
Deadline tasks don't use priority numbers, so a plain boost is meaningless. Instead, the lock holder temporarily **borrows the waiter's deadline**, letting it pre-empt every real-time task until that deadline, then drops it on unlock. In the fully pre-emptible real-time kernel, most kernel spinlocks become rt_mutex-backed sleeping locks, extending priority inheritance across nearly all kernel locking.

## The picture

```text
 H (prio 90) ──waits on──▶ lock A ──owned by──▶ L (prio 10 → boosted to 90)
                                                 │ blocked on
                                                 ▼
                                               lock B ──owned by──▶ K (prio 20 → boosted to 90)

 M (prio 50) can no longer pre-empt L or K
 walk: hold ≤2 locks at a time, stop when nothing changes, give up after 48 hops or a cycle
 unlock: owner's priority falls back as waiters leave
```

## Tradeoffs

- **What it gives you:** bounded blocking for high-priority tasks behind shared locks, with a one-instruction uncontended path in both kernel and user space.
- **What it costs / requires:** it's a separate lock type. Adding owner tracking, priority trees and chain walks to every ordinary mutex would slow down all of them, so priority inheritance is opt-in and free for everything else.
- **Where it bites:** it fixes only inversions caused by locks. Linus has argued priority inheritance is "fundamentally broken in the general case", since it can't handle inversions from CPU bandwidth, caches or memory-bus contention, and can give a false sense of correctness. **Proxy execution**, which lends the waiter's whole scheduling context rather than only its priority, is being developed as a more complete answer, especially for deadline tasks.

## How it got here

- **2.6.18 (2006):** rt_mutex and priority-inheriting futexes arrived (Ingo Molnár, Thomas Gleixner) from the real-time patch set. Linus initially objected, then accepted a version limited to locks.
- **2009:** requeue for condition variables (Darren Hart), closing the priority-drop window.
- **4.x:** the chain walk was hardened against tasks exiting mid-walk.
- **5.x:** deadline tasks can lend their deadline to a lock holder; an earlier crash in this cross-class boosting was fixed by Peter Zijlstra's 2017 series.
- **6.x:** the real-time kernel option (available since 6.1) builds kernel spinlocks, reader-writer locks and semaphores on rt_mutex; proxy execution is in development.

## Related

- Technical version: [[pi-mutexes]]
- [[futex-internals-explained|Futexes]], [[mutex-explained|Mutex]], [[spinlock-and-raw-spinlock-explained|Spinlocks]], [[locking-explained|Locking]]
- [[scheduler-explained|Scheduler]], [[rt-scheduler-explained|Real-time scheduler]], [[sched-deadline-explained|SCHED_DEADLINE]], [[preemption-model-explained|Preemption model]]
