---
title: "Lockdep: Runtime Locking Correctness Validator — Explained"
category: explained
original: "[[lockdep]]"
subsystem: locking
tags: [explained, locking, lockdep, deadlock-detection, debugging]
converted: 2026-09-25
---

# Lockdep, explained

> Plain-language companion to [[lockdep|the technical note]]. Same facts, fewer identifiers.

## The problem

Deadlocks are rare, timing-dependent and miserable to debug. Two code paths that take the same two locks in opposite orders can run for years without trouble, until two CPUs hit them at exactly the wrong moment and the machine hangs. A lock taken inside an interrupt handler and elsewhere with interrupts enabled is a similar trap: fine until an interrupt lands at just the wrong instant on the same CPU.

Waiting for such deadlocks to happen in testing, let alone in production, is hopeless. What's needed is a tool that spots the *possibility* the first time the dangerous pattern appears, even if it didn't deadlock this time.

## The idea in one paragraph

**Lockdep** watches every lock taken and released, and builds a **graph of ordering facts** between lock **classes** (kinds of lock, not individual locks): "a lock of kind B was taken while one of kind A was held" becomes an edge from A to B. Whenever a new edge would close a **cycle**, some interleaving *could* deadlock, and lockdep reports it immediately with full traces. It also records which interrupt contexts each class has been used in, and flags combinations that could deadlock if an interrupt arrived at the wrong moment.

## Step by step

### Step 1: Group locks into classes
This is the key idea. A running kernel may have millions of inode locks, but they're all one kind: "an inode's read/write lock". Lockdep tracks **classes**, identified by a static key variable that each lock is registered against when it's initialised. Memory stays proportional to the number of lock kinds (usually a few thousand), not the number of locks.

### Step 2: Record ordering, find cycles
Each task keeps a small stack of the locks it currently holds. When it takes lock B while holding A, lockdep adds an edge A → B. It then searches the graph for an existing path from B back to A. If there is one, two CPUs doing the two sequences in opposite order could deadlock, and lockdep prints a warning with both lock names, where each was taken, and the chain of dependencies.

Edges are also labelled by whether each side was a reader or an exclusive holder. Only "strong" paths, those that would truly block, count toward a deadlock, so read locks that can safely nest don't raise false alarms.

### Step 3: Check interrupt safety
Each class accumulates a record of the contexts it's been used in:
- **hardirq-safe:** taken inside a hard interrupt handler
- **hardirq-unsafe:** taken with hard interrupts enabled
- the same pair for soft interrupts

A class that is both hardirq-safe and hardirq-unsafe is a deadlock waiting to happen: code holds it with interrupts on, an interrupt arrives on that CPU, and the handler spins forever on the same lock. Lockdep flags this the first time it sees the combination, even if no such interrupt has ever actually arrived. In its reports, short codes after each lock's name summarise how it was used in each context.

### Step 4: Cache validated chains
The full set of locks held at an acquisition is a **chain**. Lockdep hashes each chain to a 64-bit value and remembers ones already validated. Repeating a familiar pattern costs one lookup instead of a graph search, which keeps the overhead bearable.

### Step 5: Let developers state their assumptions
- **assert held:** warn if the current task *doesn't* hold a given lock, turning "caller must hold X" comments into checks
- **pin / unpin:** warn if a lock is released between the two, catching accidental unlocks inside callbacks
- **subclasses:** split one kind of lock into several classes, for instance to tell lockdep that nesting inode locks at different directory depths is intentional

## The picture

```text
 path 1:  take A ─ take B        edge A → B
 path 2:  take B ─ take A        new edge B → A … path A → B exists → CYCLE → report now

 class "rx lock" usage:  taken in hard interrupt ✓ (hardirq-safe)
                         taken with interrupts on ✓ (hardirq-unsafe)  → report: possible IRQ deadlock

 held locks {A, C, D} → hash → seen before? skip search : validate + remember
```

## Tradeoffs

- **What it gives you:** deadlocks and interrupt-context mistakes caught the first time the pattern occurs, with precise traces, usually by automated testing and fuzzing (the 0-day bot, syzbot) long before production.
- **What it costs / requires:** roughly 10 to 30% overhead, so it's for development, CI and distribution debug kernels, not production; correct class annotations where one lock kind legitimately nests.
- **Where it bites:** the default limit of 8,191 classes. Running out usually signals a module being loaded and unloaded repeatedly, re-registering its locks each time without freeing the old classes. Mis-annotated nesting causes false reports until subclasses are added.

## How it got here

- **2.6.18 (2006):** lockdep introduced by Ingo Molnar, since production deadlocks were so hard to reproduce. It's remained the main tool for catching lock bugs ever since.

## Related

- Technical version: [[lockdep]]
- [[locking-explained|Locking subsystem]], [[spinlock-and-raw-spinlock|Spinlocks]], [[mutex|Mutexes]], [[rwsem-reader-writer-semaphore|Read/write semaphores]]
- [[interrupt-handling-explained|Interrupt handling]], [[local-lock-explained|Local locks]], [[vfs-locking-model-explained|VFS locking model]]
