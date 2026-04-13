---
title: "Spinlock and raw_spinlock"
category: concept
tags: [locking, spinlock, qspinlock, mcs-lock, smp, concurrency]
subsystem: locking
kernel_version: "2.6.0"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/locking/
  - https://www.kernel.org/doc/html/latest/locking/locktypes.html
  - https://www.kernel.org/doc/html/latest/locking/spinlocks.html
  - https://lwn.net/Articles/590243/
  - https://lwn.net/Articles/561775/
  - https://lwn.net/Articles/268931/
---

# Spinlock and raw_spinlock

## Overview

Spinlocks are the kernel's lowest-level mutual exclusion primitive for contexts where sleeping is forbidden: interrupt handlers, softirqs, and any code path that must not yield the CPU. Rather than suspending the calling thread, a spinlock busy-waits — the CPU loops until the lock is available. Since Linux 3.15 the implementation uses **queued spinlocks (qspinlocks)**, an MCS-based algorithm that eliminates the cache-line storm that plagued the earlier ticket-lock design.

## How It Works

### The Cache-Line Problem With Ticket Locks

Before qspinlocks, Linux used ticket locks: two 16-bit counters in a 32-bit word — `head` (next to be served) and `tail` (next ticket issued). Acquiring incremented `tail` atomically and then spun on `head`. When the holder incremented `head` on release, every waiting CPU's cache line became invalid simultaneously, causing N cache-coherency transactions for N waiters. On 8+ core machines this produced measurable throughput collapses (up to 116% on VFS disk benchmarks per the qspinlock merge commit).

### Queued Spinlock (qspinlock) Design

`qspinlock` stores its entire state in one 32-bit word divided into three regions:

```
 31       16 15    9  8       2   1   0
[  tail:16 |  0   | locked:8 | pending | 0 ]
```

- **`locked` byte** (bits 8–15): 0 = free, 1 = held. A simple byte write releases the lock.
- **`pending` bit** (bit 9): set by the second contender to reserve the "next in line" slot without joining the full MCS queue.
- **`tail` field** (bits 16–31): encodes `(cpu_number << 2) | context_index`, pointing to the `mcs_spinlock` node of the queue tail.

Each CPU maintains a statically allocated array of four `mcs_spinlock` nodes — one for each preemption context (task, softirq, hardirq, NMI) — so a CPU can spin on up to four different spinlocks simultaneously across nesting levels.

**Uncontended path**: `queued_spin_lock()` executes a single `cmpxchg(val, 0, _Q_LOCKED_VAL)`. If the lock word was zero, it succeeds and the function returns — one atomic operation, no memory barrier overhead beyond the implicit `LOCK` prefix on x86.

**One waiter (pending bit) path**: When a second CPU arrives and finds the lock held but the pending bit clear, it sets the pending bit and then busy-waits on the `locked` byte. No MCS node is allocated. This avoids the setup overhead of the full queue for the very common "two-CPU contention" case.

**Queue path (≥3 contenders)**: The third CPU and beyond each take their `mcs_spinlock` node from the per-CPU array (indexed by current context — task, softirq, hardirq, or NMI), atomically swap it into the tail field, and link it to the previous tail node. Each CPU then spins on `node->locked`, which is only written by the previous node's CPU when it reaches the head of the queue. This means each CPU spins on its **own cache line**, not the main lock word — cache traffic is O(1) per release regardless of queue depth.

When the lock is released, `queued_spin_unlock()` writes zero to the `locked` byte. The CPU at the head of the queue observes this, sets its own `mcs_spinlock.locked = 1` to pass the token to the next node, and returns from `queued_spin_lock_slowpath()`.

### raw_spinlock_t vs. spinlock_t

`raw_spinlock_t` is unconditionally a qspinlock on all kernel configurations including `PREEMPT_RT`. It is the only safe choice in:
- Low-level interrupt handlers
- Clocksource / timekeeping code
- Architecture boot code that runs before the scheduler is initialized

`spinlock_t` is aliased to `raw_spinlock_t` on non-RT kernels. On `PREEMPT_RT`, `spinlock_t` becomes an `rt_mutex`-backed sleeping lock. This allows RT tasks to preempt lock holders and maintain bounded latency, but means `spinlock_t` can schedule on RT — so any code that must never schedule (NMI handlers, hardirq context) must use `raw_spinlock_t` explicitly.

### Interrupt Safety Variants

A critical rule: if the same spinlock can be acquired from both task context and an interrupt handler on the same CPU, the task context side must disable IRQs while holding the lock. Otherwise, an interrupt fires, the handler tries to acquire the same lock, and the CPU deadlocks spinning on a lock held by the task that the interrupt preempted.

```c
spin_lock(&lock)              // disables preemption only — use ONLY if no IRQ handler acquires this lock
spin_lock_bh(&lock)           // disables preemption + softirqs
spin_lock_irq(&lock)          // disables preemption + all IRQs
spin_lock_irqsave(&lock, flags) // disables IRQs, saves EFLAGS — safe even if IRQs were already off
```

The `_irqsave` variant is the safest and most portable; it correctly handles the case where the caller already had IRQs disabled.

## Key Data Structures

`qspinlock` (`include/asm-generic/qspinlock_types.h`):
```c
typedef struct qspinlock {
    union {
        atomic_t val;           // full 32-bit state word
        struct {
            u8  locked;         // locked byte (0=free, 1=held)
            u8  pending;        // pending bit
        };
        struct {
            u16 locked_pending; // locked + pending together
            u16 tail;           // MCS queue tail (cpu<<2 | ctx)
        };
    };
} arch_spinlock_t;
```

`mcs_spinlock` (`kernel/locking/mcs_spinlock.h`):
```c
struct mcs_spinlock {
    struct mcs_spinlock *next;  // next waiter in queue
    int locked;                 // 0=waiting, 1=may proceed
    int count;                  // nesting count within this context slot
};
```

`spinlock_t` (`include/linux/spinlock_types.h`) wraps `raw_spinlock_t` and adds lockdep instrumentation via an embedded `lockdep_map`.

## Key Functions

- `spin_lock(lock)` / `spin_unlock(lock)` — acquire/release; disable preemption
- `spin_lock_irqsave(lock, flags)` / `spin_unlock_irqrestore(lock, flags)` — IRQ-safe acquire/release
- `spin_trylock(lock)` — non-blocking; returns 1 on success, 0 on failure
- `queued_spin_lock()` — fast path: single `cmpxchg` on uncontended lock
- `queued_spin_lock_slowpath()` — slow path: pending bit or full MCS queue enrollment
- `queued_spin_unlock()` — releases by zeroing the locked byte

## Design Decisions

**Why 4 MCS nodes per CPU?** A single CPU can acquire spinlocks at up to 4 nesting levels: task → softirq → hardirq → NMI. The per-CPU array pre-allocates one node per level, indexed by the `context_index` field in the tail word, ensuring non-interfering queuing across nesting levels.

**Why a pending bit instead of immediately joining the MCS queue?** Enrolling in the MCS queue requires an atomic exchange to update the tail field, which has higher latency than a simple bit set. For the extremely common "one CPU waiting" case the pending bit avoids that overhead while still giving the waiter a local spin variable (it spins on the locked byte directly once the queue is empty).

## Config & Flags

- `CONFIG_QUEUED_SPINLOCKS` — selects qspinlock implementation (default on SMP x86/arm64)
- `CONFIG_QUEUED_RWLOCKS` — selects MCS-based queued rwlock (parallel design for rwlock_t)
- `CONFIG_PREEMPT_RT` — spinlock_t → sleeping lock; raw_spinlock_t remains spinning
- `CONFIG_DEBUG_SPINLOCK` — adds owner tracking, double-lock detection, unlock-without-lock BUG
- `CONFIG_LOCK_STAT` — per-lock contention statistics (requires `CONFIG_DEBUG_LOCK_ALLOC`)

## Further Reading

- [LWN: MCS locks and qspinlocks](https://lwn.net/Articles/590243/) — best explanation of the design
- [LWN: Ticket spinlocks](https://lwn.net/Articles/268931/) — history of the predecessor design
- [kernel.org: Lock types and rules](https://www.kernel.org/doc/html/latest/locking/locktypes.html) — PREEMPT_RT compatibility table
