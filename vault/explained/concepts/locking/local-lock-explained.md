---
title: "local_lock: Per-CPU Critical Sections — Explained"
category: explained
original: "[[local-lock]]"
subsystem: locking
tags: [explained, locking, per-cpu, preempt-rt, lockdep]
converted: 2026-09-25
---

# Local locks, explained

> Plain-language companion to [[local-lock|the technical note]]. Same facts, fewer identifiers.

## The problem

Much kernel data is kept **per CPU**: each CPU has its own copy, so other CPUs never touch it. The only danger is on the *same* CPU, where the running code could be preempted (or interrupted) halfway through an update and something else on that CPU could then touch the same copy. The traditional fix was a bare "disable preemption" (or "disable interrupts") around the update.

That works, but it has two drawbacks:
1. **Lockdep can't see it.** The deadlock checker has no idea what's being protected, so it can't catch mistakes like taking a sleeping lock inside that region.
2. **It breaks real-time kernels.** On PREEMPT_RT, disabling preemption stops a high-priority task from running, which ruins latency guarantees. RT needs to be able to preempt even inside such sections.

## The idea in one paragraph

Give each per-CPU critical section a **named lock** that means different things on different kernels. On a normal kernel, taking a **local lock** is just "disable preemption" (or interrupts), exactly what the code did before, at zero extra cost, but now named and visible to lockdep. On a real-time kernel, the same call takes a real **per-CPU lock**, so the holder can be preempted by more important work while nothing else on that CPU can touch the data.

## Step by step

### Step 1: Declare one lock per piece of per-CPU data
Alongside a per-CPU variable, declare a per-CPU local lock and initialise it. Each protected variable gets its own lock. That names the intent, and lets lockdep keep separate dependency chains for separate per-CPU domains.

### Step 2: Use it around updates
Take the local lock, get this CPU's copy, change it, release the lock. There are variants that also disable interrupts, and that save and restore the interrupt state.

### Step 3: What it compiles to on a normal kernel
This is the key step. Taking a local lock becomes "disable preemption"; the interrupt variants become "disable interrupts" or "save and disable interrupts". There's **no lock object** to spin on. When lock debugging is on, a small lockdep record inside the local lock is exercised, so lockdep sees the acquisition even though nothing actually waits.

### Step 4: What it becomes on a real-time kernel
The local lock is a genuine per-CPU spinlock, one per CPU, which on RT is itself a sleeping lock. So:
- the holder **can** be preempted by a higher-priority task
- other tasks on the same CPU still can't get at that CPU's copy at the same time
- the interrupt-disabling variants still disable interrupts, even on RT, so interrupt handlers can't break in

### Step 5: What it is not
A local lock only guards against other code on the **same CPU**. It is not a replacement for an ordinary spinlock protecting data that several CPUs share. For per-CPU data, same-CPU protection is exactly right, because other CPUs use their own copies.

## The picture

```text
                      normal kernel             real-time kernel           lockdep sees it?
 disable preemption   disables preemption       disables preemption        no
 spinlock             queued spinlock           sleeping RT mutex          yes
 local lock           disables preemption       per-CPU lock (preemptible) yes
 local lock + irq     disables interrupts       disables interrupts        yes

 CPU 3:  local_lock ─▶ this CPU's counter += 1 ─▶ local_unlock
 CPU 7:  its own counter, its own local lock: never contends with CPU 3
```

## Tradeoffs

- **What it gives you:** named, lockdep-checked per-CPU critical sections at zero cost on normal kernels, and preemptible ones on real-time kernels.
- **What it costs / requires:** declaring and initialising a lock per protected variable, and choosing the right variant for interrupt safety.
- **Where it bites:** using a local lock where data is actually shared between CPUs gives no protection at all. The "try" variant has no meaningful failure on normal kernels.

## How it got here

- **PREEMPT_RT tree:** developed there, because RT needed preemptible per-CPU sections.
- **5.8:** merged into mainline, solving lockdep visibility and RT compatibility at once.

## Related

- Technical version: [[local-lock]]
- [[locking-explained|Locking subsystem]], [[per-cpu-variables|Per-CPU variables]], [[spinlock-and-raw-spinlock|Spinlocks]], [[lockdep|Lockdep]]
- [[interrupt-handling-explained|Interrupt handling]], [[per-cpu-page-allocator-pcp-explained|Per-CPU page lists]]
