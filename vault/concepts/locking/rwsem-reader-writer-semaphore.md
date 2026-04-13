---
title: "rwsem: Reader-Writer Semaphore"
category: concept
tags: [locking, rwsem, reader-writer, synchronization, sleeping-lock, optimistic-spinning]
subsystem: locking
kernel_version: "2.4.0"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/locking/
  - https://www.kernel.org/doc/html/latest/locking/locktypes.html
  - https://lwn.net/Articles/598577/
  - https://lwn.net/Articles/724384/
  - https://lwn.net/Articles/788946/
---

# rwsem: Reader-Writer Semaphore

## Overview

`rw_semaphore` is the kernel's sleeping reader-writer lock. Multiple readers can hold it simultaneously, but a writer requires exclusive access. It is the workhorse of the VFS layer — every `inode`, `super_block`, and `address_space` carries an `i_rwsem` — and appears wherever a data structure has a strongly read-dominated access pattern with occasional write-side updates.

## How It Works

### State Word

All state is packed into a single `atomic_long_t count`:

```
  Bit 63 (sign): 0 = no writer locked, effectively negative if WRITER_LOCKED
  Bit  0: RWSEM_WRITER_LOCKED  — a writer holds the lock
  Bit  1: RWSEM_FLAG_WAITERS   — at least one task is sleeping on the wait list
  Bit  2: RWSEM_FLAG_HANDOFF   — unlock should hand directly to first waiter
  Bits 8+: reader count         — each reader adds RWSEM_READER_BIAS (=256)
```

The current reader count is `count >> RWSEM_READER_SHIFT` (i.e., bits 8 and above, divided by `RWSEM_READER_BIAS`).

### Reader Acquisition

`down_read()` atomically adds `RWSEM_READER_BIAS` to `count` and checks whether `RWSEM_WRITER_LOCKED` or writer-waiter bits are set. If neither is set, the read succeeds immediately — the increment *is* the lock acquisition; no CAS loop is needed beyond the atomic add. If a writer is present or waiting, the reader falls to the slow path: it checks the OSQ for optimistic spinning (if the write owner is running on another CPU), then joins the wait list and sleeps.

`up_read()` subtracts `RWSEM_READER_BIAS`. If the result is exactly `RWSEM_FLAG_WAITERS` (meaning no more readers and a waiter is queued), it calls `rwsem_wake()` to check whether to wake a writer or a batch of readers.

### Writer Acquisition

`down_write()` performs `cmpxchg(count, 0, RWSEM_WRITER_LOCKED)`. If the lock is completely free (count == 0), this sets bit 0 and the writer proceeds. If any readers or another writer holds the lock, the writer checks the OSQ (optimistic spinning) then sleeps.

The **handoff mechanism** (introduced Linux 5.2) prevents writer starvation under sustained reader load. If a writer has been sleeping in the queue for long enough that new readers keep bypassing it, the `RWSEM_FLAG_HANDOFF` bit is set in `count`. Once set, new read acquirers that see this bit fall to the slow path even if no `WRITER_LOCKED` bit is set, ensuring the waiting writer gets the lock on the next `up_read()`.

### Optimistic Spinning

Both readers and writers participate in **optimistic spinning** (added for writers in Linux 3.16, for readers in Linux 4.13). Before sleeping, a waiter checks `owner_on_cpu()` — whether the current lock owner is actively running. If so, the waiter acquires a node in the OSQ (`osq_lock()`) and spins on its local `mcs_spinlock.locked` field. Exit conditions for the spin are the same as for mutex: owner preempted, lock released, or waiter itself needs to reschedule.

### Wake-Up Policy

`rwsem_wake()` wakes the first entry in the wait list. If it is a writer, only that writer is woken. If it is a reader, all contiguous readers at the front of the queue are woken simultaneously — the "reader wake-up batch" — because all of them can hold the lock concurrently.

### downgrade_write()

`downgrade_write()` atomically converts a write lock to a read lock. It clears `RWSEM_WRITER_LOCKED`, adds `RWSEM_READER_BIAS`, and wakes any sleeping readers at the front of the wait list. This is used in the VFS to hold a write lock for the write portion of an operation and then drop to a read lock for the remaining read-only part, improving concurrency.

## Key Data Structures

`struct rw_semaphore` (`include/linux/rwsem.h`):
```c
struct rw_semaphore {
    atomic_long_t count;         // packed state: reader count + flags
    atomic_long_t owner;         // current owner task ptr + reader/writer flag
    struct optimistic_spin_queue osq; // OSQ for optimistic spinners
    raw_spinlock_t  wait_lock;   // protects wait_list
    struct list_head wait_list;  // sleeping waiters (rwsem_waiter structs)
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    struct lockdep_map dep_map;
#endif
};
```

`struct rwsem_waiter` (`kernel/locking/rwsem.c`):
```c
struct rwsem_waiter {
    struct list_head    list;
    struct task_struct *task;
    enum rwsem_waiter_type type;  // RWSEM_WAITING_FOR_WRITE or _FOR_READ
    unsigned long       timeout;  // absolute jiffies; for handoff detection
    bool                handoff_set; // true once HANDOFF flag is set for this waiter
};
```

## Key Functions

- `down_read(sem)` / `up_read(sem)` — read-side acquire/release
- `down_write(sem)` / `up_write(sem)` — write-side acquire/release
- `down_read_trylock(sem)` / `down_write_trylock(sem)` — non-blocking variants
- `down_read_interruptible(sem)` — returns `-EINTR` on signal
- `downgrade_write(sem)` — atomic write → read conversion
- `rwsem_wake()` — internal: wakes writer or batch of readers
- `rwsem_down_read_slowpath()` — optimistic spin + sleep for readers
- `rwsem_down_write_slowpath()` — optimistic spin + sleep for writers

## Evolution

| Version | Change |
|---------|--------|
| 2.4 | Original implementation: simple counter-based |
| 3.16 (2014) | Writer optimistic spinning added |
| 4.13 (2017) | Reader optimistic spinning added |
| 5.2 (2019) | Full rearchitecture: unified x86/generic impl, HANDOFF flag to prevent writer starvation |

## Config & Flags

- `CONFIG_RWSEM_SPIN_ON_OWNER` — implied by `CONFIG_MUTEX_SPIN_ON_OWNER`; enables OSQ-based spinning
- `CONFIG_DEBUG_RWSEMS` — adds assertions for lock rule violations
- `CONFIG_DEBUG_LOCK_ALLOC` — Lockdep instrumentation
- On `PREEMPT_RT`: `rwlock_t` (the *spinning* reader-writer lock) becomes a sleeping lock; `rw_semaphore` is unaffected (already sleeping)

## Further Reading

- [LWN: rwsem optimistic spinning](https://lwn.net/Articles/598577/)
- [LWN: rwsem rearchitecture 2019](https://lwn.net/Articles/788946/)
- [LWN: Reader optimistic spinning 2017](https://lwn.net/Articles/724384/)
