---
title: "Futex Internals — Explained"
category: explained
original: "[[futex-internals]]"
subsystem: locking
tags: [explained, locking, futex, pthreads, priority-inheritance]
converted: 2026-09-25
---

# Futex internals, explained

> Plain-language companion to [[futex-internals|the technical note]]. Same facts, fewer identifiers.

## The problem

Programs lock mutexes constantly, and most of the time nobody else wants the lock. Making a system call for every lock and unlock would waste a trip into the kernel on a case that needs no help at all. But when a lock *is* contended, a thread must be able to sleep and be woken reliably, and only the kernel can do that.

The dangerous moment is the gap between a thread seeing "locked" in user space and going to sleep in the kernel. If the owner unlocks in that gap and nobody notices, the sleeper may never be woken.

## The idea in one paragraph

A **futex** ("fast user-space mutex") is just a 32-bit integer in the program's memory. The threading library handles the **uncontended case entirely in user space** with one atomic instruction. Only when a thread really must wait does it ask the kernel: "put me to sleep, *but only if* this word still holds the value I saw." The kernel re-checks the value and queues the thread as one indivisible step, which closes the gap. It's the foundation of pthread mutexes, condition variables and semaphores on Linux.

## Step by step

### Step 1: The library owns the word
The kernel treats the futex word as an opaque number, used only for its "compare, then sleep" check. The library decides what values mean: typically 0 for unlocked, with the owner's thread ID or a "someone is waiting" marker when locked.

### Step 2: The uncontended case never enters the kernel
To lock, the library tries an atomic compare-and-swap from 0 to its thread ID. If it succeeds, the lock is held. No system call happens.

### Step 3: Waiting, without the race
This is the key step. If the lock is taken, the library marks that a waiter exists and asks the kernel to wait, passing the value it expects to see. The kernel:
1. works out a **key** for this futex
2. picks a **hash bucket** from a global table (256 buckets on small systems, up to 4,096 on NUMA machines) and locks it
3. reads the word; if it no longer matches the expected value, it returns "try again" immediately
4. otherwise, queues the thread in the bucket, unlocks, and sleeps

Because the check and the queueing happen under the bucket's lock, an unlock can't slip in between them.

### Step 4: Two kinds of key
- **Private futexes** (threads of one process) are keyed by (address space, address). No page-table walk is needed, which makes this the fast path for ordinary pthread mutexes.
- **Shared futexes** (across processes) are keyed by the underlying file or page and the offset within it, so different processes mapping the same page at different addresses find the same futex. Working this out requires looking up the page.

### Step 5: Waking
To wake, the kernel computes the same key, locks the bucket, walks its list for matching waiters, removes and wakes up to the requested number, and unlocks.

### Step 6: Priority inheritance
Plain futexes allow **priority inversion**: a high-priority thread waits on a lock held by a low-priority one, while medium-priority threads keep the owner from running. Priority-inheritance futexes fix this. The word holds the owner's thread ID; when a waiter blocks, the kernel finds the owner, sets up shared state backed by a real-time mutex, and **boosts** the owner's priority, and the owner's owner's if that one is waiting too.

If a thread dies holding such locks, a per-thread **robust list** it registered earlier lets the kernel release each lock at exit and mark it "owner died", so waiters learn what happened rather than hanging.

### Step 7: Broadcasting without a stampede
Waking every thread waiting on a condition variable would have them all rush for the same mutex at once. **Requeue** wakes just one and *moves* the rest from the condition variable's queue onto the mutex's queue, where they'll be woken one at a time. For priority-inheritance mutexes, if the mutex happens to be free at requeue time, the kernel takes it on behalf of the top waiter before waking it, keeping the priority state consistent.

### Step 8: Waiting on many at once
Since 5.16, a thread can wait on up to N futex words in one call and learn which one woke it. Games and runtimes such as Wine and Proton use this instead of one waiter thread per condition.

## The picture

```text
 lock, uncontended:  CAS(word, 0 → my TID)  ✓   (no kernel)

 lock, contended:    CAS fails → mark "waiter" → futex(WAIT, word, expected)
   kernel: key → bucket → lock bucket → word == expected ? queue + sleep : "try again"

 unlock:             word = 0 → waiter marked? → futex(WAKE, word, 1)
   kernel: key → bucket → lock bucket → wake first matching waiter
```

## Tradeoffs

- **What it gives you:** locks that cost one atomic instruction when uncontended, a race-free sleep and wake path, priority inheritance, clean-up after dying threads, stampede-free broadcasts, and multi-wait.
- **What it costs / requires:** a careful contract between the library and the kernel about what the word means; page lookups for shared futexes.
- **Where it bites:** the global hash table is shared by every futex, so workloads with thousands of threads can contend on buckets, and people have proposed per-page or per-address-space tables. Plain futexes still allow priority inversion unless the priority-inheritance variant is used.

## How it got here

- **2.6.25 (2008):** priority-inheritance and robust futexes, since POSIX requires priority inheritance and clean-up when threads die.
- **5.16:** waiting on multiple futexes at once.
- **Ongoing:** "futex2" API rethinking, and scalability work on the hash table.

## Related

- Technical version: [[futex-internals]]
- [[locking-explained|Locking subsystem]], [[mutex-explained|Mutexes and RT mutexes]], [[spinlock-and-raw-spinlock-explained|Spinlocks]]
- [[get-user-pages-and-pinning-explained|Looking up user pages]], [[scheduler-explained|Scheduler]]
