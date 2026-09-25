---
title: "rwsem: Reader-Writer Semaphore — Explained"
category: explained
original: "[[rwsem-reader-writer-semaphore]]"
subsystem: locking
tags: [explained, locking, rwsem, readers-writers, vfs]
converted: 2026-09-25
---

# Read/write semaphores, explained

> Plain-language companion to [[rwsem-reader-writer-semaphore|the technical note]]. Same facts, fewer identifiers.

## The problem

Some kernel structures are read far more often than they're changed: every inode, superblock and address space, for example. An ordinary mutex would make readers queue behind one another for no reason, since readers don't interfere with each other. What's wanted is a lock that lets **many readers in together** but gives a **writer exclusive access**, and that may sleep, since the work under it can block.

Such locks have two classic hazards. A continuous flow of readers can **starve** a waiting writer forever. And, as with mutexes, sleeping when the holder is about to finish anyway wastes time.

## The idea in one paragraph

Pack the whole lock into **one word**: a "writer holds it" bit, a "someone is waiting" bit, a "hand off to the next waiter" bit, and a **reader count** in the upper bits. A reader gets in with a single atomic add, as long as no writer holds or is owed the lock. A writer gets in only when the word is completely zero. Waiters spin briefly if the owner is running, and otherwise sleep. When a writer has waited too long, the handoff bit makes newcomer readers queue up behind it.

## Step by step

### Step 1: One word of state
- bit 0: a writer holds the lock
- bit 1: tasks are sleeping on the wait list
- bit 2: hand off to the first waiter on release
- bits 8 and up: the number of readers (each reader adds 256)

A separate owner field records the owner (and whether it's readers or a writer), with a spin queue and a wait list alongside.

### Step 2: Readers
Taking a read lock adds one reader's worth to the count and checks the result. If no writer holds the lock and none is owed it, **that addition was the acquisition**: no retry loop needed. Otherwise the reader goes to the slow path: spin if the writer is running, else sleep. Releasing a read lock subtracts; if that leaves only the "waiting" bit set (no readers left, someone waiting), it wakes the queue.

### Step 3: Writers
Taking the write lock is one compare-and-swap from "all zero" to "writer holds it". If anyone (readers or another writer) holds it, the writer tries optimistic spinning and then sleeps.

### Step 4: Stopping writer starvation
This is the key step. Readers only check for a writer that *holds* the lock, so a steady stream of new readers could keep a waiting writer out indefinitely. Since 5.2, once a writer has waited long enough, the **handoff** bit is set. New readers that see it take the slow path even though no writer holds the lock, so when the current readers drain, the waiting writer gets the lock next.

### Step 5: Optimistic spinning
Before sleeping, a waiter checks whether the current owner is running on a CPU. If so, it joins a spin queue and spins on its own node, just like mutexes, giving up if the owner is preempted, the lock is released, or the waiter itself must reschedule. Writers gained this in 3.16 and readers in 4.13.

### Step 6: Who gets woken
Wake-ups look at the front of the queue. A writer there is woken alone; if readers are at the front, the whole run of readers up to the next writer is woken together, since they can all hold the lock at once.

### Step 7: Downgrading
A writer can atomically turn its write lock into a read lock: clear the writer bit, add one reader, and wake readers waiting at the front. The VFS uses this to do the writing part of an operation exclusively, then let other readers in for the read-only rest.

## The picture

```text
 state word:  [ reader count … | handoff | waiters | writer ]
 read lock:   add 256 → writer bit set or handoff set? slow path : done
 write lock:  compare-and-swap 0 → "writer" : else spin / sleep
 release:     front of queue is a writer? wake it : wake all leading readers

 writer waiting too long ─▶ set handoff ─▶ new readers queue ─▶ writer goes next
```

## Tradeoffs

- **What it gives you:** concurrent readers, exclusive writers, single-instruction acquisition in the common cases, no pointless sleeps, batch reader wake-ups, and protection against writer starvation.
- **What it costs / requires:** process context only (it sleeps), and a more complex state word than a plain mutex.
- **Where it bites:** a writer blocks all new readers once handoff is set, so a slow writer stalls a whole read-heavy path; and the handoff adds latency for readers. On real-time kernels, the separate *spinning* read/write lock becomes a sleeping lock, while this semaphore is unchanged since it already sleeps.

## How it got here

- **2.4:** the original counter-based version.
- **3.16 (2014):** optimistic spinning for writers.
- **4.13 (2017):** optimistic spinning for readers.
- **5.2 (2019):** a full rework: one shared implementation for x86 and generic code, and the handoff bit against writer starvation.

## Related

- Technical version: [[rwsem-reader-writer-semaphore]]
- [[locking-explained|Locking subsystem]], [[mutex-explained|Mutexes]], [[lockdep-explained|Lockdep]]
- [[vfs-locking-model-explained|VFS locking model]], [[address-space-explained|Address space]]
