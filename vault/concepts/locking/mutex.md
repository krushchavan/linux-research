---
title: "Mutex"
category: concept
tags: [locking, mutex, synchronization, sleeping-lock, priority-inheritance, optimistic-spinning]
subsystem: locking
kernel_version: "2.6.16"
researched: 2026-04-13
status: complete
explained: "[[mutex-explained]]"
sources:
  - https://kernel-internals.org/locking/
  - https://www.kernel.org/doc/html/latest/locking/mutex-design.html
  - https://www.kernel.org/doc/html/latest/locking/locktypes.html
  - https://lwn.net/Articles/167034/
  - https://lwn.net/Articles/602393/
---

# Mutex

> 📘 Plain-language version: [[mutex-explained]]

## Overview

A mutex (`struct mutex`) is the kernel's standard sleeping mutual exclusion lock: at most one task holds it at a time, and any other task that tries to acquire it while it is held is descheduled and woken only when the lock is released. Mutexes are the preferred primitive for critical sections in process context that can tolerate scheduler overhead — they are strictly more efficient than spinlocks for hold times that exceed the cost of a sleep/wake cycle.

## How It Works

### Fast Path: Uncontended Acquisition

`mutex_lock()` begins with a single `cmpxchg` on `mutex->owner`, attempting to change it from `0` to `(unsigned long)current`. If the lock is free, this single atomic instruction acquires it. No spinlock, no queue, no system call cost. This is the common case.

### Mid Path: Optimistic Spinning

If the fast path fails (the lock is held), `mutex_lock_and_spin()` checks whether the owner is *currently running* on another CPU via `owner_on_cpu()`. The intuition: if the owner is actively scheduled and the lock hold time is short (typical for kernel mutexes), spinning briefly is cheaper than sleeping and waking. The waiter acquires a node in the **optimistic spin queue (OSQ)** — an MCS-like structure embedded in the mutex as `osq` — and spins on its own local `mcs_spinlock.locked` field.

The waiter exits the OSQ and falls to the slow path if:
- The owner is preempted (no longer on a CPU)
- The owner releases the lock (fast path succeeds)
- The waiter itself needs to reschedule (e.g., it receives a signal or higher-priority task arrives)
- A waiter with higher priority is already sleeping (handoff mode)

This mid path was added in Linux 3.0 (2011) and significantly reduced mutex contention latency for syscall-heavy workloads.

### Slow Path: Sleep and Wake

If optimistic spinning fails, the task appends a `mutex_waiter` to `mutex->wait_list` (a linked list protected by `mutex->wait_lock`, a raw spinlock) and calls `schedule()` with state `TASK_UNINTERRUPTIBLE`. The task is parked until woken.

On release, `mutex_unlock()` examines the flag bits encoded in the low bits of `owner`:

- **`MUTEX_FLAG_WAITERS` (bit 0)**: a waiter is sleeping; the slow-path unlock must wake it.
- **`MUTEX_FLAG_HANDOFF` (bit 1)**: the top waiter has requested a direct handoff — the unlock path should set `owner` to point directly at the waiter's task before waking it, preventing a new uncontended acquirer from stealing the lock.
- **`MUTEX_FLAG_PICKUP` (bit 2)**: the waiter has been designated and is about to pick up the lock; the unlock path should not wake it again.

The HANDOFF mechanism prevents a thundering-herd situation where a continuous stream of new, uncontended acquirers repeatedly win the fast path and starve sleeping waiters.

`mutex_lock_interruptible()` places the task in `TASK_INTERRUPTIBLE` instead, returning `-EINTR` if a signal arrives before the lock is granted.

### rt_mutex: Priority Inheritance

`rt_mutex` extends the mutex design with full **priority inheritance (PI)**. When high-priority task B blocks on an rt_mutex held by low-priority task A, the kernel boosts A's scheduling priority to B's, preventing priority inversion. The boost is propagated transitively: if A is itself blocked on another rt_mutex held by C, C is also boosted.

The PI chain is stored as a linked list of `rt_mutex_waiter` structures. Boosting calls `rt_mutex_setprio()` which adjusts the scheduler's priority via `__setscheduler_prio()`. On `PREEMPT_RT`, `spinlock_t` internally uses `rt_mutex`, so PI applies to many common spinlock scenarios automatically.

### ww_mutex: Wound/Wait for Dynamic Lock Sets

Graphics and GPU drivers must acquire a dynamically-determined set of buffer object (BO) locks; classic lock ordering is impractical when the set is unknown at compile time. `ww_mutex` (wound/wait mutex) solves this with a global **transaction stamp**: each `ww_acquire_ctx` receives a monotonically increasing stamp at `ww_acquire_init()` time. If task A (stamp 5) tries to acquire a lock held by task B (stamp 3), and B's stamp is *older* (lower), A backs off ("is wounded") and retries. This guarantees progress because the task with the oldest stamp always wins.

## Key Data Structures

`struct mutex` (`include/linux/mutex.h`):
```c
struct mutex {
    atomic_long_t   owner;       // current owner task_struct ptr | flags
    raw_spinlock_t  wait_lock;   // protects wait_list
    struct optimistic_spin_queue osq; // MCS queue for optimistic spinners
    struct list_head wait_list;  // sleeping waiters (struct mutex_waiter)
#ifdef CONFIG_DEBUG_MUTEXES
    void            *magic;      // debug: expected to equal &mutex
#endif
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    struct lockdep_map dep_map;  // lockdep instrumentation
#endif
};
```

The `owner` field encoding:
- Bits 63–3: pointer to the owning `task_struct` (word-aligned, so lower 3 bits are free)
- Bit 0: `MUTEX_FLAG_WAITERS`
- Bit 1: `MUTEX_FLAG_HANDOFF`
- Bit 2: `MUTEX_FLAG_PICKUP`

`struct mutex_waiter` (`kernel/locking/mutex.c`):
```c
struct mutex_waiter {
    struct list_head list;       // position in mutex->wait_list
    struct task_struct *task;    // sleeping task
    struct ww_acquire_ctx *ww_ctx; // non-NULL for ww_mutex waiters
#ifdef CONFIG_DEBUG_MUTEXES
    void *magic;
#endif
};
```

## Key Functions

- `mutex_init(mutex)` / `DEFINE_MUTEX(name)` — dynamic / static initialization
- `mutex_lock(mutex)` — acquire; sleeps if held (uninterruptible)
- `mutex_lock_interruptible(mutex)` — acquire; returns `-EINTR` on signal
- `mutex_lock_killable(mutex)` — acquire; returns `-EINTR` only for `SIGKILL`
- `mutex_trylock(mutex)` — non-blocking; returns 1 on success, 0 on failure
- `mutex_unlock(mutex)` — release; wakes first sleeper if `WAITERS` flag set
- `mutex_is_locked(mutex)` — predicate; true if owner field is non-zero

## Mutex vs. Semaphore

The `semaphore` predates `mutex` in the kernel but has fewer semantic constraints (any task can `up()` it, recursive `down()` is legal). In 2006, Ingo Molnar introduced `mutex` with strict single-owner semantics and called it "always prefer them to any other locking primitive." Mutexes can be instrumented more precisely by Lockdep, support optimistic spinning, and have leaner data structures. Semaphores remain for legacy code and the handful of cases where non-owner release is semantically required.

## Config & Flags

- `CONFIG_MUTEX_SPIN_ON_OWNER` — enables optimistic spinning mid-path (default y on SMP)
- `CONFIG_DEBUG_MUTEXES` — adds owner/magic field checks; BUGs on rule violations (double unlock, unlock-from-wrong-context)
- `CONFIG_DEBUG_LOCK_ALLOC` — enables Lockdep instrumentation
- `CONFIG_PREEMPT_RT` — replaces spinlock_t internals of mutex with rt_mutex chains

## Further Reading

- [kernel.org: Generic Mutex Subsystem](https://www.kernel.org/doc/html/latest/locking/mutex-design.html)
- [LWN: The mutex API](https://lwn.net/Articles/167034/) — introduction article from 2006
- [LWN: MCS spinlocks and mutex optimistic spinning](https://lwn.net/Articles/604641/)
