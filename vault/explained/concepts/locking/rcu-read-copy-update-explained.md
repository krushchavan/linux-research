---
title: "RCU: Read-Copy-Update — Explained"
category: explained
original: "[[rcu-read-copy-update]]"
subsystem: locking
tags: [explained, locking, rcu, grace-periods, scalability]
converted: 2026-09-25
---

# RCU (read-copy-update), explained

> Plain-language companion to [[rcu-read-copy-update|the technical note]]. Same facts, fewer identifiers.

## The problem

Many kernel structures are read constantly and changed rarely: routing tables, the process list, the dentry cache, module lists. Protecting them with a read/write lock still makes every reader write to the lock's shared memory, and writers make readers wait. Reference counting has the same flaw: each read bumps a shared counter, so the cache line holding it bounces between CPUs and reads stop scaling.

The ideal is for readers to pay **nothing**: no locks, no writes to shared memory, no waiting. But then how can a writer ever free an old object, when it can't tell whether some reader on another CPU is still looking at it?

## The idea in one paragraph

Think of a **printed city directory**. When an address changes, nobody snatches the old directory out of people's hands. The city prints a new edition and hands it out, and only shreds the old one once enough time has passed that everyone must have finished with it. RCU does the same: a writer **copies** the object, **updates** the copy, **publishes** it by swapping one pointer, and waits for a **grace period** (a stretch of time long enough that every reader who might have seen the old version has finished) before freeing the old one. Readers never know an update happened.

## Step by step

### Step 1: Readers mark a section and do nothing else
A reader brackets its access with "RCU read lock" and "unlock". On non-preemptible kernels these compile to **nothing at all**, not even a barrier: since a task inside the section can't be switched out, a context switch on a CPU proves that CPU has left every earlier reader section. On preemptible kernels they bump a per-task nesting counter: cheap, but not free.

Inside, the reader loads the protected pointer with a special dereference that stops the compiler (or CPU) from reading the target's fields before the pointer itself has arrived, which could otherwise return garbage on out-of-order hardware.

### Step 2: Writers copy, update and publish
A writer never modifies the live object. It:
1. **copies:** allocates a new version and fills it in
2. **publishes:** stores the new pointer with release ordering, so any reader who sees the new pointer also sees all its fields initialised
3. **defers the free:** either waits for a grace period (blocking), or queues a callback to run after one (non-blocking)

New readers now find the new version; old readers may still hold the old one, which the writer must leave alone until the grace period ends.

### Step 3: What counts as a grace period
This is the key step. A **grace period** ends once every CPU has passed through a **quiescent state**, a point where it can't be inside a reader section that started before the grace period began: a context switch, a return to user space, entering the idle loop, or being offline. Readers are never asked anything; RCU infers from these events that they've finished. Idle CPUs report passively through [[dyntick-idle-explained|dyntick-idle]] tracking, without being woken.

### Step 4: Collecting reports across thousands of CPUs
If every CPU cleared its bit in one global mask under one lock, huge machines would drown in contention. Since 2.6.29, **Tree RCU** arranges CPUs in a **combining tree**: each leaf covers 16 CPUs by default, each inner node 64 children on 64-bit systems. A CPU reporting a quiescent state clears its bit in its leaf; the last one to clear a leaf clears the leaf's bit in its parent, and so on. When the root clears, the grace period is over. On a 4,096-CPU machine, only about 64 CPUs ever contend for any one lock.

Each CPU keeps its pending callbacks in a **four-part list**: ready to run now, waiting for the current grace period, waiting for the next one, and not yet assigned. As grace periods complete, callbacks move along towards "ready".

### Step 5: Waiting cheaply, or quickly
Blocking waiters are batched: thousands of concurrent waits share one grace period, which is why a wait can take milliseconds (10 to 100 ms), a deliberate trade for throughput. When latency matters (say, in driver initialisation), an **expedited** grace period interrupts every CPU to force immediate reports, finishing in microseconds at the cost of disturbing real-time work.

### Step 6: Unloading modules safely
Waiting for a grace period doesn't mean queued callbacks have *run*; under memory pressure they can lag behind. A module that queued callbacks and then unloaded could have them run against freed code. The **barrier** operation queues a marker callback on every CPU and waits until all have run, proving every earlier callback has too. So: stop queuing, barrier, then unload.

### Step 7: Variants
- **Preemptible RCU:** reader sections can be preempted; blocked readers are tracked per tree node.
- **Sleepable RCU (SRCU):** readers may even sleep (needed by some filesystems), using per-CPU counters that must be polled, so it's slower and less scalable. Use it only when blocking inside a reader is unavoidable.
- **Tasks RCU:** for tracing and kprobes, with quiescent states only at voluntary switches or user space, and grace periods of hundreds of milliseconds.

## The picture

```text
 readers:   lock ─ p = deref(ptr) ─ use *p ─ unlock      (no writes to shared memory)

 writer:    new = copy(old); new.x = 5
            publish(ptr ← new)            readers from now on see "new"
            wait grace period ⋯⋯⋯⋯⋯⋯⋯⋯⋯ every CPU: switch / user / idle
            free(old)                     nobody can still hold "old"

 quiescent reports:  CPU bits ─▶ leaf (16 CPUs) ─▶ inner node (64) ─▶ root cleared = grace period done
```

## Tradeoffs

- **What it gives you:** read paths with zero (or near-zero) cost that scale to thousands of CPUs, used throughout networking, the VFS and memory management.
- **What it costs / requires:** writers keep old and new versions alive together and can't reclaim memory immediately; grace periods are long; the rules are strict (publish and read through the special operations).
- **Where it bites:** waiting for a grace period from inside a reader section deadlocks (or stalls without bound on preemptible kernels), so it's forbidden; queue a callback instead. RCU is a poor fit when memory must be reclaimed quickly. Stuck CPUs trigger "RCU stall" warnings after 21 seconds by default.

## How it got here

- **2.5.43 (2002):** Paul McKenney's first RCU, aimed at dentry-cache lock contention, using a flat CPU bitmask.
- **2.6.29 (2009):** Tree RCU with the combining tree (McKenney's benchmarks showed 3 to 4 times the throughput on 128 CPUs), plus the segmented callback list.
- **2.6.32:** already-elapsed grace periods detected to avoid redundant waits. **3.0 (2011):** RCU flavours unified; SRCU moved to per-CPU data.
- **4.20 (2018):** the separate bottom-half and sched update APIs folded into plain RCU.
- **5.5 (2020):** batched freeing without an embedded callback head, about 30% faster for network protocols creating many short-lived objects.
- **6.x:** polled grace-period APIs for contexts that can't sleep.

## Related

- Technical version: [[rcu-read-copy-update]]
- [[locking-explained|Locking subsystem]], [[dyntick-idle-explained|Dyntick-idle]], [[per-cpu-variables-explained|Per-CPU variables]], [[interrupt-handling-explained|Interrupt handling]]
- [[dentry-cache-explained|Dentry cache]], [[path-lookup-explained|Path lookup (RCU-walk)]], [[slub-slab-allocator-explained|SLUB allocator]], [[xarray-explained|XArray]]
