---
title: "Dyntick-Idle (NO_HZ) — Explained"
category: explained
original: "[[dyntick-idle]]"
subsystem: locking
tags: [explained, timers, nohz, rcu, power]
converted: 2026-09-25
---

# Dyntick-idle (NO_HZ), explained

> Plain-language companion to [[dyntick-idle|the technical note]]. Same facts, fewer identifiers.

## The problem

Traditionally, every CPU received a timer interrupt at a fixed rate (the "tick", typically 250 or 1,000 times a second) whether or not there was anything to do. An idle CPU was woken hundreds of times a second only to find no work. That wastes power on battery devices, costs expensive exits to the hypervisor in virtual machines, and injects jitter into real-time and HPC jobs.

Simply turning the tick off is harder than it sounds, because other parts of the kernel quietly depend on it. The biggest is **RCU**, which uses ticks to learn when each CPU has passed a point where it can't be reading shared data. A CPU that stops ticking looks, to RCU, like one that never finishes, and could stall it forever.

## The idea in one paragraph

Replace the "snooze every few minutes" alarm with a **smart alarm clock**. Before an idle CPU sleeps, it looks at all its pending timers, finds the earliest, sets a **single one-shot alarm** for that moment, and sleeps undisturbed until then. To keep RCU happy, the sleeping CPU declares itself to be in a continuous "not reading anything" state, which RCU can check from outside without waking it.

## Step by step

### Step 1: Going idle
When a CPU's run queue empties and it heads into the idle loop, it:
1. finds its next pending event, across high-resolution timers and the timer wheel
2. programs its local timer hardware to fire once at that moment (a **one-shot** alarm)
3. records that its periodic tick is stopped

Then it enters its hardware idle state. No ticks arrive unless that timer fires or some other interrupt comes in.

### Step 2: Waking up
When it wakes (from the timer, an external interrupt, or another CPU's nudge), it reads the current time and accounts for how long it slept. Since no ticks fired, the kernel rebuilds its tick count and load statistics from the hardware clock rather than from ticks. It restarts the periodic tick if needed, and resumes load accounting.

### Step 3: Telling RCU "I'm not here"
This is the key step. RCU grace periods need every CPU to pass through a **quiescent state**, a moment with no RCU reader running. With ticks, any tick that landed outside a reader counted. A tickless idle CPU gives no such signal.

The fix is an **extended quiescent state**, tracked by a per-CPU counter:
- **even** means "idle or in user space: no RCU readers possible"
- **odd** means "active in the kernel"

Entering idle bumps the counter to even (with a full memory barrier); leaving bumps it to odd. When RCU looks for CPUs that haven't reported in, an even counter means that CPU has been quiescent the whole time and can be counted as done, without waking it.

An interrupt arriving during idle might run RCU readers, so interrupt entry bumps the counter to odd for the handler and back afterwards; NMIs arriving on top of interrupts are handled with a separate nesting count. A counter rather than a flag needs only cheap atomic increments, and its value also carries the nesting information.

### Step 4: Going further: no ticks while busy (NO_HZ_FULL)
CPUs named at boot can drop the tick even while running, if they have exactly **one** runnable task. That removes about 1% overhead and, more importantly, the jitter that stalls HPC jobs at synchronisation barriers. The duties the tick normally performs must be covered some other way:
- **every user/kernel crossing is tracked**, and each return to user space counts as an RCU quiescent state, since a single task running user code can't be inside an RCU reader
- **RCU callbacks are offloaded** to helper threads on housekeeping CPUs, so an isolated CPU isn't woken to run them
- **a residual 1 Hz tick** remains for load averages and other bookkeeping, and unbound work and timers move to other CPUs

A CPU drops back to normal ticking if a second task becomes runnable, a POSIX CPU timer is active, a perf event needs periodic sampling, or it queues an RCU callback without offloading configured.

### Step 5: The hardware abstraction underneath
All of this rests on **clockevents** (2.6.21), a uniform driver interface for timers that can fire once at a chosen time. Before it, timer drivers were per-architecture and periodic only. Some CPUs' local timers stop in deep sleep states; a global broadcast timer then fires on their behalf.

## The picture

```text
 periodic:   |tick|tick|tick|tick|tick|tick|tick|tick|   (idle CPU woken every time)
 dyntick:    idle ──────────── sleep ──────────── ⏰ next timer
             counter: odd → even (RCU: "quiescent, don't wait for me")
             interrupt arrives:  even → odd (handler may read RCU data) → even

 NO_HZ_FULL CPU (one task):  user ▸ kernel ▸ user ▸ …   each return to user = quiescent
                             1 Hz housekeeping tick only; RCU callbacks run elsewhere
```

## Tradeoffs

- **What it gives you:** 2 to 3 times lower power use on battery devices, fewer VM exits, deep hardware sleep states, and near-zero OS jitter on isolated CPUs.
- **What it costs / requires:** extra work on every idle entry and exit (scan timers, reprogram hardware, fix up accounting), which adds microseconds; for NO_HZ_FULL, tracking every user/kernel crossing, offloading callbacks, and careful CPU and interrupt placement.
- **Where it bites:** NO_HZ_FULL needs the boot CPU and at least one other CPU to keep ticking for timekeeping; changing the isolated set needs a reboot; POSIX CPU timers can miss deadlines on isolated CPUs. Systems needing sub-microsecond idle transitions may prefer a periodic tick.

## How it got here

- **2.6.21 (2007):** dyntick-idle for x86-64, together with clockevents. **2.6.27 (2008):** extended to ARM, MIPS and PowerPC.
- **3.10 (2013):** "full dynticks" (Frederic Weisbecker, Paul McKenney), with substantial RCU rework around user/kernel tracking.
- **~4.x (2014–2016):** load accounting fixed for tickless periods; isolating CPUs now sets up RCU callback offloading automatically.
- **5.x:** an older RCU workaround for tickless idle removed; RCU's idle tracking merged into the general user/kernel tracking state.
- **Open:** a truly tickless kernel, without even the 1 Hz residual tick, which Linus Torvalds noted would be needed to lift the one-task restriction.

## Related

- Technical version: [[dyntick-idle]]
- [[rcu-read-copy-update|RCU]], [[interrupt-handling-explained|Interrupt handling]], [[per-cpu-variables|Per-CPU variables]], [[locking-explained|Locking subsystem]]
- [[scheduler|Scheduler]], [[cpuset-controller-explained|cpuset (CPU isolation)]]
