---
title: "Futex Internals"
category: concept
tags: [locking, futex, userspace, priority-inheritance, synchronization, syscall]
subsystem: locking
kernel_version: "2.6.0"
researched: 2026-04-13
status: complete
explained: "[[futex-internals-explained]]"
sources:
  - https://kernel-internals.org/locking/
  - https://www.kernel.org/doc/html/latest/locking/futex-requeue-pi.html
  - https://lwn.net/Articles/360699/
  - https://lwn.net/Articles/823513/
  - https://lwn.net/Articles/940944/
  - https://lwn.net/Articles/685769/
---

# Futex Internals

> 📘 Plain-language version: [[futex-internals-explained]]

## Overview

A **futex** (fast userspace mutex) is a kernel mechanism that implements userspace synchronization with minimal syscall overhead. The key insight: most mutex acquisitions are uncontended. The pthreads library can handle the uncontended case entirely in userspace with one atomic instruction; the kernel is only involved when a thread must actually sleep or wake another. This design made futexes the foundation of `pthread_mutex_t`, `pthread_cond_t`, and `sem_t` on Linux.

## How It Works

### The Userspace Contract

A futex is identified by a 32-bit integer in user memory (the *futex word*). The pthreads library manages the value: typically 0 = unlocked, positive = locked, with the TID of the owner or a special sentinel for waiters encoded in specific bits (the details are library-defined, not kernel-defined). The kernel treats the futex word as an opaque integer whose value is used only for the compare-and-block check.

**Acquiring a mutex (uncontended)**:
```c
// Entirely in userspace — no syscall
if (atomic_cmpxchg(futex_word, 0, TID) == 0) {
    // lock acquired
}
```

**Acquiring a mutex (contended)**:
```c
old = atomic_cmpxchg(futex_word, 0, TID);
if (old != 0) {
    // mark that a waiter exists, then block:
    syscall(SYS_futex, futex_word, FUTEX_WAIT, expected_value, timeout, ...);
}
```

The `FUTEX_WAIT` syscall re-checks `*futex_word == expected_value` atomically with enqueuing the waiter. This prevents the TOCTOU race where the value changes between the userspace check and entering the kernel.

### Kernel: Hash Table and Futex Keys

The kernel maintains a global hash table `futex_queues[]` (256 buckets on small systems, up to 4096 on NUMA). Each bucket is a `futex_hash_bucket` containing a `plist_head` (priority-ordered linked list) of waiting `futex_q` structures.

The hash key depends on the futex type:
- **Private futex** (`FUTEX_PRIVATE_FLAG`): key is `{mm pointer, page-aligned address}`. Only threads sharing the same `mm` can see private futexes. Lookups do not require page-table walks. This is the fast path for `pthread_mutex_t`.
- **Shared futex**: key is `{struct inode *, page offset}`. Any process mapping the same underlying file/anonymous page at any address can participate. Requires `get_user_pages()` to resolve the key.

```c
// Simplified futex_wait path:
get_futex_key(uaddr, flags, &key);          // compute key
hash_bucket = hash_futex(&key);             // select bucket
spin_lock(&hash_bucket->lock);
ret = get_futex_value_locked(&val, uaddr);  // atomic read of futex word
if (val != expected) { spin_unlock(); return -EAGAIN; }
queue_me(&q, hash_bucket);                 // enqueue futex_q
spin_unlock(&hash_bucket->lock);
schedule();                                 // sleep
```

The crucial ordering: the value check and the enqueue happen while holding the bucket lock, so no race exists between the value changing and the task being added to the wait queue.

### FUTEX_WAKE

```c
// Simplified futex_wake path:
get_futex_key(uaddr, flags, &key);
hash_bucket = hash_futex(&key);
spin_lock(&hash_bucket->lock);
plist_for_each_entry_safe(q, ..., &hash_bucket->chain) {
    if (match_futex(&q->key, &key)) {
        wake_futex(q);    // removes from plist, calls wake_up_process()
        if (--nr_wake == 0) break;
    }
}
spin_unlock(&hash_bucket->lock);
```

### Priority Inheritance (PI) Futexes

Standard futexes do not prevent priority inversion: a high-priority task blocked on a futex held by a low-priority task may wait indefinitely while medium-priority tasks run. `FUTEX_LOCK_PI` / `FUTEX_UNLOCK_PI` add priority inheritance on top of the futex mechanism.

The futex word's upper bits encode the TID of the owner (set by the library). When a high-priority waiter calls `FUTEX_LOCK_PI`, the kernel locates the owner (by TID), creates a `futex_pi_state` structure, and calls `rt_mutex_lock()` on the PI futex's backing `rt_mutex`. If the owner is lower priority, `rt_mutex_lock()` boosts the owner's priority. The boost is transitive: if the owner is itself blocked on another PI futex, the chain is walked.

The **robust list** (`robust_list_head`, set via `set_robust_list(2)`) allows the kernel to clean up PI futexes held by a dying thread. On `do_exit()`, the kernel walks the robust list and calls `futex_exit_robust_list()`, unlocking each futex and setting the "owner dead" bit so waiting threads return `EOWNERDEAD`.

### FUTEX_REQUEUE and FUTEX_CMP_REQUEUE_PI

`FUTEX_CMP_REQUEUE_PI` supports `pthread_cond_broadcast()` without the thundering herd problem. The broadcast thread calls `FUTEX_CMP_REQUEUE_PI` specifying a source condition-variable futex and a destination mutex futex. The kernel wakes one waiter (to avoid herd) and *moves* the remaining waiters from the condition variable's bucket to the mutex's bucket. Those waiters will then compete for the mutex without all waking simultaneously.

The proxy-lock mechanism (`rt_mutex_start_proxy_lock()`) ensures that if the mutex is already free at requeue time, the kernel acquires the rt_mutex on behalf of the top waiter before waking it, guaranteeing PI state consistency.

### futex_waitv() (Linux 5.16)

`futex_waitv()` allows a task to atomically wait on any of N futex words simultaneously:

```c
struct futex_waitv waiters[N] = { ... };
syscall(SYS_futex_waitv, waiters, N, flags, timeout, clockid);
```

This enables games and runtimes (Wine, Proton) to wait on a set of condition variables without spawning per-variable waiter threads. The return value identifies which futex was woken.

## Key Data Structures

`struct futex_q` (`kernel/futex/futex.h`):
```c
struct futex_q {
    struct plist_node list;         // in hash bucket's priority list
    struct task_struct *task;       // sleeping task
    spinlock_t *lock_ptr;           // points to bucket lock
    union futex_key key;            // identifies this futex
    struct futex_pi_state *pi_state;// non-NULL for PI futexes
    struct rt_mutex_waiter *rt_waiter; // for PI proxy operations
    union futex_key *requeue_pi_key;// target key for REQUEUE_PI
    u32 bitset;                     // for FUTEX_WAIT_BITSET filtering
    atomic_t requeue_state;         // REQUEUE_PI state machine
};
```

`union futex_key` (`kernel/futex/futex.h`):
```c
union futex_key {
    struct { u64 i_seq; unsigned long pgoff; unsigned int offset; } shared;
    struct { union { struct mm_struct *mm; u64 __tmp; }; unsigned long address; unsigned int offset; } private;
    struct { u64 ptr; unsigned long word; unsigned int offset; } both;
};
```

`struct futex_hash_bucket` (`kernel/futex/futex.h`):
```c
struct futex_hash_bucket {
    atomic_t waiters;
    spinlock_t lock;
    struct plist_head chain;  // priority-sorted list of futex_q
} ____cacheline_aligned_in_smp;
```

## Key Functions

- `do_futex()` — main dispatch: decodes `op`, calls per-operation handler
- `futex_wait()` — `FUTEX_WAIT`: key lookup, value check, enqueue, schedule
- `futex_wake()` — `FUTEX_WAKE`: key lookup, dequeue, wake
- `futex_lock_pi()` / `futex_unlock_pi()` — PI futex ops; wrap rt_mutex
- `futex_requeue()` / `futex_cmp_requeue_pi()` — move waiters between buckets
- `futex_exit_robust_list()` — cleanup on thread death (walks robust_list)
- `do_futex_waitv()` — multi-futex wait (Linux 5.16+)

## Config & Flags

- `CONFIG_FUTEX` — enables futex support (required by glibc, required in practice)
- `CONFIG_FUTEX_PI` — enables `FUTEX_LOCK_PI` / `FUTEX_UNLOCK_PI` operations
- `CONFIG_HAVE_FUTEX_CMPXCHG` — architecture has atomic `cmpxchg`; required for most futex ops

## Further Reading

- [LWN: A futex overview and update](https://lwn.net/Articles/360699/) — comprehensive internals article
- [LWN: Rethinking the futex API](https://lwn.net/Articles/823513/) — motivation for futex2
- [LWN: A new futex API](https://lwn.net/Articles/940944/) — futex_waitv() and beyond
- [LWN: In pursuit of faster futexes](https://lwn.net/Articles/685769/) — scalability optimizations
- [kernel.org: Futex Requeue PI](https://www.kernel.org/doc/html/latest/locking/futex-requeue-pi.html)
