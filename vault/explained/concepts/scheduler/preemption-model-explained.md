---
title: "Preemption Model — Explained"
category: explained
original: "[[preemption-model]]"
subsystem: scheduler
tags: [explained, scheduler, preemption, preempt-rt, latency]
converted: 2026-09-25
---

# The preemption model, explained

> Plain-language companion to [[preemption-model|the technical note]]. Same facts, fewer identifiers.

## The problem

When a more important task becomes ready, when is the kernel allowed to take the CPU away from the one currently running? If a task is executing kernel code and can't be interrupted, it can hold the CPU for an unbounded time. That's fine for a batch server, and a disaster for audio playback or a safety-critical control loop. But every extra chance to pre-empt costs a check, and sometimes a cache miss. The pre-emption model is the main knob setting the whole system's balance between **worst-case latency** and **throughput**.

## The idea in one paragraph

Think of a bank teller. With **no pre-emption**, every customer finishes their whole transaction before the next begins: great throughput, but the person with a two-second question waits behind a mortgage refinancing. With **full pre-emption**, a manager can tap the teller on the shoulder mid-transaction for an urgent wire transfer: less throughput, but nobody waits more than a few hundred microseconds. **PREEMPT_RT** is the bank remodelled so that even locking the safe doesn't stop the teller being interrupted. Mechanically, pre-emption always has three parts: a **request** flag, a **gate** that must be open, and **checkpoints** where the kernel looks at both.

## Step by step

### Step 1: The request
When the scheduler decides the running task should give way, it sets a **"needs rescheduling" flag** on it. That's only a request, not a transfer of control. The two main sources:
- the **timer tick**, when the task has used up its fair slice
- **wake-ups**, when a newly woken task should run before the current one

### Step 2: The gate
The request only takes effect when a per-task counter, the **pre-emption count**, is zero and interrupts are enabled. The counter packs several nesting depths into one number: explicit "don't pre-empt me" sections, softirq nesting, hardware interrupt nesting, and an NMI bit. Taking a spinlock (on a normal kernel) bumps it, so a task holding any spinlock can't be pre-empted. This is the key step: that guarantee is what makes per-CPU data safe, since a task can't migrate to another CPU in the middle of an update. The same counter answers "am I in interrupt context?" and "is it safe to sleep here?".

### Step 3: The checkpoints
The flag is acted on at specific places:
1. **return from a hardware interrupt into kernel code** (full pre-emption only)
2. **re-enabling pre-emption**, when the last "don't pre-empt" section ends
3. **voluntary yield points** sprinkled through long kernel loops; in the no-pre-emption and voluntary models, these are the only in-kernel checkpoints
4. **return to user space**, checked in every model, which guarantees no task can run in user space forever

### Step 4: The classic three models
- **None:** the traditional server model. The kernel yields only when code explicitly calls the scheduler, at yield points, or on return to user space. Latency can reach tens of milliseconds or more. Chosen by most server distributions.
- **Voluntary:** adds many yield points in long kernel paths (memory allocation, filesystem journalling). Typical latency is still tens of milliseconds, with no pre-emption on interrupt return. The usual desktop choice until the mid-2010s.
- **Full:** enables checkpoints 1 and 2. Latency drops to hundreds of microseconds. Used for embedded systems and desktops with audio and video needs.

### Step 5: The real-time model
The most invasive option. Ordinary spinlocks become **sleeping locks** built on the priority-inheriting rt_mutex, so holding a lock no longer blocks pre-emption. Softirqs run in their own pre-emptible threads, and so do interrupt handlers, except where a genuine busy-wait "raw" spinlock is still used (scheduler internals, interrupt controllers, and a few other places that truly can't sleep). [[pi-mutexes-explained|Priority inheritance]] boosts a low-priority lock holder when a high-priority task waits for it, passing the boost along chains of locks. With tuning, worst-case latency is 10–100 µs, as needed for professional audio, medical and industrial control.

### Step 6: Lazy pre-emption (6.13+)
A newer, in-between mode adds a second, **lazy** request flag. Most wake-ups set only the lazy flag, which is honoured at yield points and timer ticks rather than on every interrupt return, so the running task gets to use more of its slice. Wake-ups of high-priority or real-time tasks still set the urgent flag. This recovers much of the voluntary model's throughput while keeping full pre-emption's machinery, with no dependence on hand-placed yield points. The long-term plan is to shrink the choices down to lazy and real-time.

### Step 7: Choosing at boot
With **dynamic pre-emption** (5.12+), one kernel binary can boot as none, voluntary or full, chosen on the kernel command line. The bookkeeping is always kept even in "none" mode, costing a few nanoseconds per lock operation (early Arm benchmarks showed 1–2% on some microbenchmarks), which was judged worth it so distributions can ship one kernel for both servers and desktops. Fedora and Ubuntu have moved to it.

## The picture

```text
 request:     "needs rescheduling" flag  (tick, wake-up)   [+ lazy flag in 6.13+]
 gate:        pre-emption count == 0 and interrupts on
 checkpoints:          none   voluntary   full   RT
   return to user        ✓        ✓         ✓     ✓
   yield points          few      many      ✓     ✓
   interrupt return      ✗        ✗         ✓     ✓
   end of no-preempt     ✗        ✗         ✓     ✓
   while holding lock    ✗        ✗         ✗     ✓ (sleeping locks)
 latency:              10s ms    10s ms   100s µs  10–100 µs
```

## Tradeoffs

- **What it gives you:** a choice along the latency/throughput curve, from a throughput-first server to deterministic real-time, now selectable at boot on one kernel.
- **What it costs / requires:** every checkpoint is a branch and potential cache miss. A database doing long kernel-side scans loses throughput under full pre-emption; an audio system can't tolerate a 50 ms stall. The real-time model adds overhead on every lock and changes memory-ordering behaviour, hurting lock-heavy workloads.
- **Where it bites:** the voluntary model depends on developers remembering to add yield points; a new long code path without one is a latency regression waiting to happen. Lazy pre-emption is meant to end that dependence. Under the real-time model, every spinlock user changes behaviour without any source change, which is why subsystems like printk took years to make safe.

## How it got here

- **Before 2.6:** kernel code was never pre-empted, only user space.
- **2.6.0 (2003):** full pre-emption (Robert Love and others), a milestone for desktop and embedded use.
- **~2.6.12 (2005):** the voluntary model. Ingo Molnár's 2004 patch argued explicit yield points gave 80% of the latency benefit for 20% of the risk, and started a 20-year debate over whether scattering them was sustainable.
- **2004–2024:** the real-time patch set (Molnár, Thomas Gleixner, Steven Rostedt) lived out of tree, merging piece by piece: high-resolution timers, threaded interrupts, and finally a printk rework (2021–2024) that was the last blocker.
- **5.12 (2021):** dynamic pre-emption (Michal Hocko).
- **6.12 (2024):** real-time support fully merged for x86, arm64 and RISC-V, ending a two-decade effort.
- **6.13 (2025):** lazy pre-emption (Thomas Gleixner).

## Related

- Technical version: [[preemption-model]]
- [[scheduler-explained|Scheduler]], [[context-switch-explained|Context switch]], [[pi-mutexes-explained|PI mutexes]], [[rt-scheduler|Real-time scheduler]], [[cpu-cgroups-explained|CPU cgroups]]
- [[locking-explained|Locking]], [[spinlock-and-raw-spinlock-explained|Spinlocks]], [[per-cpu-variables-explained|Per-CPU variables]], [[interrupt-handling-explained|Interrupt handling]]
