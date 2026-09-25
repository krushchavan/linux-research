---
title: "Mutex — Explained"
category: explained
original: "[[mutex]]"
subsystem: locking
tags: [explained, locking, mutex, optimistic-spinning, priority-inheritance]
converted: 2026-09-25
---

# Kernel mutexes, explained

> Plain-language companion to [[mutex|the technical note]]. Same facts, fewer identifiers.

## The problem

Some critical sections in the kernel are long, or can block (allocating memory, doing I/O). Protecting them with a spinlock would leave waiting CPUs spinning uselessly for ages. A waiting task should **sleep** and be woken when the lock is free.

But sleeping and waking isn't free either. If the lock is usually held only briefly, a waiter that goes to sleep may be woken almost immediately, having paid a lot for nothing. And a steady stream of newcomers grabbing a just-released lock can **starve** the waiters who went to sleep. On top of that, real-time systems need protection from priority inversion, and graphics drivers need to take large, changing sets of locks without deadlocking.

## The idea in one paragraph

A mutex is a **sleeping lock with three gears**. If it's free, take it with one atomic instruction. If it's held by a task that's *running right now* on another CPU, spin briefly, because it'll probably be released in a moment. Only otherwise, go to sleep in a queue. Flags stored alongside the owner let the releaser **hand the lock directly** to a sleeping waiter so newcomers can't keep jumping the queue. Variants add priority inheritance and deadlock-free multi-lock acquisition.

## Step by step

### Step 1: The fast path
The mutex's owner field holds the owning task's pointer (tasks are aligned, so the low three bits are free for flags). Locking first tries one atomic compare-and-swap from "no owner" to "me". If the lock was free, that's the whole cost: no queue, no spinlock. This is the common case.

### Step 2: Optimistic spinning
This is the key step. If the lock is held but its owner is currently running on another CPU, the waiter bets the owner will finish soon, since kernel mutexes are typically held briefly. It joins a small **spin queue** (a queue where each waiter spins on its own flag, not the shared lock) and waits there. It gives up and goes to sleep if the owner is preempted, if it needs to reschedule itself (a signal, a higher-priority task), or if a waiter is already asleep asking for a handoff. It stops spinning with the lock if the owner releases it. Added in 3.0 (2011), this cut mutex latency substantially for system-call-heavy workloads.

### Step 3: Sleeping
If spinning doesn't pay off, the task adds itself to the mutex's wait list (guarded by a small internal raw spinlock) and sleeps uninterruptibly until woken. The interruptible variant sleeps so that a signal wakes it with an "interrupted" error; the killable variant does so only for a fatal signal.

### Step 4: Releasing, with handoff
On unlock, the flags in the owner field say what to do:
- **waiters:** someone is asleep and must be woken
- **handoff:** the first waiter asked to be given the lock directly; set the owner to that waiter *before* waking it, so a newcomer on the fast path can't steal it
- **pickup:** the chosen waiter is about to take the lock; don't wake it again

Handoff is what stops a constant stream of fast-path newcomers from starving sleeping waiters.

### Step 5: RT mutexes: priority inheritance
An **RT mutex** adds priority inheritance. If high-priority task B blocks on a lock held by low-priority task A, A is boosted to B's priority until it releases the lock, so medium-priority tasks can't keep A (and therefore B) waiting. If A is itself blocked on another RT mutex held by C, C is boosted too, all along the chain. On real-time kernels, ordinary spinlocks are built on RT mutexes, so this protection applies broadly there.

### Step 6: Wound/wait mutexes: many locks, no deadlock
Graphics drivers must lock a set of buffers that's only known at run time, so no fixed locking order is possible. With a **wound/wait mutex**, each attempt to take a set of locks gets a ticket from an ever-increasing counter. When a younger attempt (higher ticket) runs into a lock held by an older one, the younger backs off, releases what it has, and retries. The oldest attempt always wins, so progress is guaranteed.

## The picture

```text
 lock():
   compare-and-swap(owner: none → me) ✓ ──────────────────────────▶ held (fast path)
   ✗ owner running on another CPU? ── spin on own node ─ released? ─▶ held (spin path)
   ✗ otherwise ─▶ join wait list, set "waiters", sleep ────────────▶ woken with lock (slow path)

 unlock():  "handoff" set? ─▶ owner = first waiter, wake it (no stealing)
            "waiters" set? ─▶ wake first waiter
```

## Tradeoffs

- **What it gives you:** one atomic instruction when uncontended, no pointless sleeps when the owner is about to finish, fairness through handoff, priority inheritance, and deadlock-free multi-lock acquisition.
- **What it costs / requires:** process context only (no sleeping in interrupts), and a strict rule that only the owner may unlock.
- **Where it bites:** holding a mutex across something slow makes every waiter sleep. Before mutexes, semaphores filled this role: they allow release by a non-owner and recursive acquisition, so they're harder for lockdep to check and have no optimistic spinning. They remain only for legacy code and the few cases that truly need a non-owner release.

## How it got here

- **2006:** Ingo Molnar introduced the mutex with strict single-owner rules, recommending it over any other locking primitive.
- **3.0 (2011):** optimistic spinning.
- **Later:** handoff and pickup flags to prevent starvation; RT mutexes underpin spinlocks on PREEMPT_RT.

## Related

- Technical version: [[mutex]]
- [[locking-explained|Locking subsystem]], [[spinlock-and-raw-spinlock-explained|Spinlocks]], [[rwsem-reader-writer-semaphore-explained|Read/write semaphores]], [[lockdep-explained|Lockdep]]
- [[futex-internals-explained|Futexes (priority inheritance for user space)]], [[scheduler|Scheduler]]
