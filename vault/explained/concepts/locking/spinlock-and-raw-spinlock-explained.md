---
title: "Spinlock and raw_spinlock — Explained"
category: explained
original: "[[spinlock-and-raw-spinlock]]"
subsystem: locking
tags: [explained, locking, spinlock, qspinlock, preempt-rt]
converted: 2026-09-25
---

# Spinlocks and raw spinlocks, explained

> Plain-language companion to [[spinlock-and-raw-spinlock|the technical note]]. Same facts, fewer identifiers.

## The problem

Interrupt handlers, soft interrupts and other code that must never give up the CPU can't sleep while waiting for a lock. A waiting CPU has to **spin**, checking the lock over and over until it's free.

The naive way to spin is costly on big machines. The old **ticket lock** kept two counters (next ticket to serve, next ticket to hand out) in one word, and every waiter spun reading that same word. On each release the word changed, so every waiting CPU's copy of that cache line was invalidated at once, meaning N waiters caused N rounds of cache-coherency traffic. On machines with 8 or more cores, throughput collapsed under contention.

## The idea in one paragraph

Make waiters **queue up and each spin on its own spot**. Since 3.15 the kernel's spinlock is a **queued spinlock** that fits in one 32-bit word: a "locked" byte, a "pending" bit, and a pointer to the tail of a queue. An uncontended lock is one atomic instruction. A second arrival sets the pending bit and waits. Third and later arrivals join a queue in which each CPU spins on a node in its **own** cache line, and a release pokes only the next waiter in line. Cache traffic per release stays constant however long the queue gets.

## Step by step

### Step 1: One word, three parts
- **locked** byte: 0 is free, 1 is held; releasing is a single byte write of zero
- **pending** bit: set by the second contender to reserve "next in line" without joining the full queue
- **tail**: identifies the last waiter's queue node, as (CPU number, context level)

### Step 2: Nobody else around
Locking tries one atomic compare-and-swap from zero to "locked". If the word was zero, the lock is taken. That's one atomic operation, the whole cost in the common case.

### Step 3: One other waiter
A second CPU finding the lock held with no pending bit sets the pending bit and spins on the locked byte. It doesn't set up a queue node, since swapping into the tail costs more than setting a bit, and "two CPUs contending" is by far the most common contended case.

### Step 4: A real queue
This is the key step. A third CPU (and beyond) takes a queue node from its own per-CPU set, atomically swaps it in as the new tail, links it behind the previous tail, and then spins on a flag **inside its own node**. That flag is only written by the CPU ahead of it when it's handing over. Every waiter spins on its own cache line rather than the lock word. When the holder releases the lock, the head of the queue takes it and flips the next node's flag to move the line along.

Each CPU has **four** nodes, one per context level (task, soft interrupt, hard interrupt, NMI), because code at one level can be interrupted by the next while itself waiting for a lock, and the queues mustn't interfere.

### Step 5: Raw versus ordinary spinlocks
- A **raw** spinlock is always a queued spinlock that really spins, on every kernel configuration including real-time ones. It's the only safe choice in low-level interrupt handlers, clock and timekeeping code, and early boot code.
- An **ordinary** spinlock is the same thing on normal kernels. On real-time kernels it becomes a sleeping lock (built on an RT mutex), so high-priority tasks can preempt the holder and latency stays bounded. So on RT, an ordinary spinlock can actually sleep, and code that must never sleep has to use raw ones.

### Step 6: Interrupt safety
If a lock is taken both in normal code and in an interrupt handler on the same CPU, the normal code must disable interrupts while holding it. Otherwise the interrupt fires, the handler spins on the lock, and the holder it interrupted can never run to release it. The variants:
- **plain:** disables preemption only; only when no interrupt handler takes this lock
- **bottom-half:** also disables soft interrupts
- **irq:** also disables all interrupts
- **irqsave:** disables interrupts and remembers whether they were already off, restoring that exact state on release; the safest and most portable

## The picture

```text
 lock word: [ tail (CPU, level) | pending | locked ]

 CPU0: CAS 0 → locked ✓                         holds lock
 CPU1: sets pending, spins on "locked"          next in line
 CPU2: node → tail, spins on node2.flag ─┐
 CPU3: node → tail, spins on node3.flag ─┤      each on its own cache line
 release: locked = 0 → CPU1 takes it → queue head moves up → pokes next node only
```

## Tradeoffs

- **What it gives you:** a lock usable anywhere, even in NMIs with raw spinlocks, costing one atomic instruction uncontended and constant cache traffic per handover however many CPUs wait. The merge reported gains of up to 116% on VFS disk benchmarks.
- **What it costs / requires:** holders must never sleep, and waiters burn CPU time, so critical sections must be short; the code is more complex than ticket locks, though the lock is still 32 bits.
- **Where it bites:** forgetting to disable interrupts for a lock shared with an interrupt handler (a single-CPU deadlock), and on RT kernels, using an ordinary spinlock where sleeping is impossible.

## How it got here

- **Before 3.15:** ticket spinlocks, fair but prone to cache-line storms on larger machines.
- **3.15 (2014):** queued spinlocks based on MCS queue locks replaced ticket locks; a matching queued design exists for read/write spinlocks.
- **PREEMPT_RT:** the raw/ordinary split, so real-time kernels can make ordinary spinlocks sleepable while raw ones keep spinning.

## Related

- Technical version: [[spinlock-and-raw-spinlock]]
- [[locking-explained|Locking subsystem]], [[mutex-explained|Mutexes (which reuse the same queued spinning idea)]], [[local-lock-explained|Local locks]], [[lockdep-explained|Lockdep]]
- [[interrupt-handling-explained|Interrupt handling]], [[per-cpu-variables-explained|Per-CPU variables]]
