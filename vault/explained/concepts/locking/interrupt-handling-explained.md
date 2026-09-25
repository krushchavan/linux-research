---
title: "Interrupt Handling and Locking — Explained"
category: explained
original: "[[interrupt-handling]]"
subsystem: locking
tags: [explained, interrupts, softirq, threaded-irqs, locking]
converted: 2026-09-25
---

# Interrupt handling and locking, explained

> Plain-language companion to [[interrupt-handling|the technical note]]. Same facts, fewer identifiers.

## The problem

Hardware signals the CPU whenever it likes: a packet arrives, a disk read finishes, a timer fires. The CPU drops what it's doing and runs a handler. If that handler touches data the interrupted code was in the middle of changing, the data is corrupted. If the handler waits for a lock the interrupted code holds, on the same CPU, it waits forever, because the holder can't run until the handler finishes.

Handlers also have to be quick: while one runs, further interrupts on that CPU are blocked. Yet real devices need plenty of work done per event. The kernel needs a model of *where* that work runs, and a precise rule for which lock to use where.

## The idea in one paragraph

Arrange execution into **stacked contexts**, each able to interrupt the ones below. At the bottom is **process context**, which may sleep. Above it are **soft interrupts**, which may not sleep. Above those are **hard interrupts**, which run with interrupts off and must finish in microseconds. At the very top, **NMIs** interrupt everything and can use almost no kernel services. Each lock variant is suited to certain contexts, and using the wrong one in the wrong place is the root of most interrupt deadlocks. The hard-interrupt handler does the bare minimum and pushes the rest *down* the stack.

## Step by step

### Step 1: From the wire to the generic layer
When a device raises an interrupt, the CPU saves the interrupted thread's registers, jumps to a small stub, notes "now in a hard interrupt" in a per-CPU counter, and calls the generic interrupt layer. Each interrupt number has one **descriptor**, protected by a **raw** spinlock (one that always spins, even on real-time kernels, since it's taken where sleeping is impossible). The descriptor's lock is held around the generic bookkeeping but dropped before the driver's own handler runs.

### Step 2: A flow handler matched to the wiring
Each descriptor has a **flow handler** chosen for how its line behaves:
- **level-triggered:** mask the line, run the handlers, unmask. A level interrupt keeps firing until the device is serviced, so masking prevents a flood.
- **edge-triggered:** don't mask (masking risks missing an edge on some hardware); note if another edge arrived meanwhile, and rerun the handlers if so.
- **"end of interrupt" controllers** (like the x86 APIC): signal completion afterwards, with minimal masking.
- **per-CPU interrupts** (like the local timer): no locking needed, since each CPU has its own.

Separately, a **chip** table holds the controller's register operations (acknowledge, mask, unmask, end-of-interrupt, affinity, trigger type). Before 2.6.18, each architecture mixed the edge/level logic with register writes, so every new controller meant rewriting the flow logic; splitting the two lets architectures reuse generic flow handlers.

### Step 3: The driver handlers
Each driver that requests the interrupt adds a handler to the descriptor's chain. On a **shared** line, every handler is called in turn and says whether the interrupt was its own. Handlers run in hard-interrupt context: local interrupts off, no sleeping.

### Step 4: Pick the lock by who shares the data
This is the key step. The rule depends on which contexts share the data:
- **process and soft interrupt:** use the "disable bottom halves" spinlock. Otherwise a soft interrupt could fire on the same CPU while process code holds the lock and spin forever waiting for it.
- **process and hard interrupt:** use the "save and disable interrupts" spinlock, which records whether interrupts were enabled and restores that on release. The plain "disable interrupts" version always re-enables them on release, which is wrong if the caller already had them off.
- **soft and hard interrupt:** disable interrupts while holding the lock.
- **two different hard interrupts:** the save-and-restore form, always safe.
- **NMIs:** only raw spinlocks, with extreme care.

### Step 5: Push work down: bottom halves
Since hard handlers must be brief, most work is deferred:
- **Soft interrupts:** a fixed set of up to 32 kinds (10 used), run right after the hard handler returns. The same kind can run on several CPUs at once (networking receive on CPU 0 and 1 together), which is why networking relies on per-CPU data and RCU rather than one big lock. If they keep firing (a device storm), the kernel stops after a limited number of rounds and hands the backlog to a per-CPU thread, **ksoftirqd**, so other tasks can run.
- **Tasklets:** built on soft interrupts, but a given tasklet never runs on two CPUs at once. Simpler to write, with less parallelism.
- **Workqueues:** run by kernel worker threads in process context, so they may sleep, allocate memory normally and take mutexes. The pool of workers grows when all are sleeping and shrinks when idle.

### Step 6: Threaded interrupts
With a **threaded** interrupt, the hard handler only checks "is this mine?" and says "wake my thread". The real work runs in a dedicated kernel thread that can sleep, take mutexes and call anything. Two functions in two well-understood contexts replace a hard handler plus a tasklet or workqueue, each with different locking rules. The real-time patches pioneered this; a boot option forces all handlers into threads even on normal kernels, except those marked "never thread".

### Step 7: What changes on real-time kernels
With PREEMPT_RT, ordinary spinlocks become sleeping locks, and the "disable interrupts" variants no longer actually disable hardware interrupts, since long interrupts-off periods would ruin latency guarantees. The "disable bottom halves" variants still work as before. Code that must work under RT uses raw spinlocks, which is why the interrupt descriptor's own lock is raw.

## The picture

```text
 NMI            ── interrupts everything; almost no services
 hard interrupt ── interrupts off, microseconds: ack device, grab data, raise softirq / wake thread
 soft interrupt ── batch work after the hard handler; same kind on many CPUs at once
     └ too much? ─▶ ksoftirqd thread
 process ctx    ── workqueues, threaded handlers: may sleep

 shared data between…      lock with
 process ↔ softirq         spinlock + disable bottom halves
 process ↔ hard irq        spinlock + save/disable interrupts
 softirq ↔ hard irq        spinlock + disable interrupts
```

## Tradeoffs

- **What it gives you:** bounded response time for the urgent part, efficient batching for the middle part, and full kernel services for the complex part, with a clear rule for which lock goes where.
- **What it costs / requires:** three or four contexts to reason about, and a matching lock variant for every pairing; threaded handlers add a little scheduling overhead per interrupt.
- **Where it bites:** the single-CPU deadlocks from using a plain spinlock where a bottom-half or interrupt-disabling one was needed (lockdep catches these), and the different semantics on RT kernels.

## How it got here

- **Before 2.6.18:** each architecture had its own interrupt handling, tightly tied to its controller.
- **2.6.18:** the generic interrupt layer (Thomas Gleixner, Ingo Molnár), with flow handlers separated from chip operations.
- **2.6.30:** threaded interrupts, prototyped in the RT tree; the debate settled on opt-in rather than threading by default.
- **3.1:** a flag meaning "run this handler with interrupts disabled" removed (Peter Zijlstra), since every handler already ran that way and the flag had become misleading.
- **3.x:** the boot option forcing all handlers into threads. **5.x:** RT pieces merged into mainline, including local locks and, in 5.15, the RT option itself.

## Related

- Technical version: [[interrupt-handling]]
- [[locking-explained|Locking subsystem]], [[spinlock-and-raw-spinlock|Spinlocks]], [[local-lock-explained|Local locks]], [[per-cpu-variables-explained|Per-CPU variables]]
- [[rcu-read-copy-update-explained|RCU]], [[seqlocks-and-memory-barriers-explained|Sequence locks and barriers]], [[dyntick-idle-explained|Dyntick-idle]], [[scheduler|Scheduler]]
