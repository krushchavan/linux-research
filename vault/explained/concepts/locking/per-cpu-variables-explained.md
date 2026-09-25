---
title: "Per-CPU Variables — Explained"
category: explained
original: "[[per-cpu-variables]]"
subsystem: locking
tags: [explained, locking, per-cpu, cache-coherency, scalability]
converted: 2026-09-25
---

# Per-CPU variables, explained

> Plain-language companion to [[per-cpu-variables|the technical note]]. Same facts, fewer identifiers.

## The problem

When several CPUs update the same variable, say a counter of packets received, the hardware has to shuttle the cache line holding it from core to core on every update, and each trip can cost hundreds of nanoseconds. Atomic instructions keep the value correct but don't avoid that traffic. On a many-core machine, a single hot shared counter can become a bottleneck all by itself.

For lots of kernel data (statistics, caches of free objects, per-CPU queues) there's no real need for one shared copy at all.

## The idea in one paragraph

Give every CPU **its own copy**. Picture a row of post boxes, one per CPU, all at the same "address": when you write, you write to your own CPU's box; when you read, you read your own. Nobody else touches your box unless they deliberately reach across, which the design discourages. Since each core only ever touches its own copy, cache lines never bounce, and most accesses need no lock, because a CPU can't race with itself. When a total is needed (for `/proc/stat`, say), the copies are added up.

## Step by step

### Step 1: A template, copied per CPU at boot
Per-CPU variables declared in the kernel are gathered into a special section of the kernel image. That section is only a **template**. At boot the kernel makes one copy for every possible CPU and records, for each CPU, the distance from the template to its copy. Reaching CPU N's copy of a variable is then arithmetic: the template address plus CPU N's offset.

The first block of per-CPU memory has three parts: the static variables, a reserved area for loadable modules' static per-CPU variables (8 KiB by default), and a dynamic area for runtime allocations. A boot option chooses how that block is laid out: **embedded** in early boot memory, contiguous per NUMA node (the default), or mapped **page by page** when contiguous memory is scarce.

### Step 2: Allocating at run time
Code whose per-CPU needs aren't known at compile time (drivers, modules) allocates per-CPU memory dynamically. It gets back a special pseudo-pointer, not a real address and not directly usable, that becomes CPU N's copy when that CPU's offset is added. Later allocation chunks come from vmalloc space. Keeping static and dynamic separate means rarely-present code doesn't bloat every kernel with static per-CPU data.

### Step 3: Don't move while you work
This is the key rule. A task must not be moved to a different CPU between working out "I'm on CPU N" and finishing with CPU N's copy; otherwise it would carry on changing CPU N's copy while running somewhere else, exactly the race per-CPU data is meant to avoid. The classic accessor pair disables preemption, returns this CPU's copy, and re-enables preemption when done. No sleeping in between. Accessors for a *specific* CPU skip this, for when the CPU is already known and stable (such as in CPU hotplug callbacks).

### Step 4: The one-instruction shortcut
The preferred modern operations (read, write, increment, add, exchange, compare-and-exchange on "this CPU's copy") use a CPU register that already points at the current CPU's per-CPU area. On x86 that's a segment register, so incrementing this CPU's counter compiles to a **single instruction** that both finds the copy and updates it. With no gap between working out the address and using it, preemption can't slip a migration in. That's safe with respect to *which CPU*, though not against an interrupt handler on the same CPU touching the same copy. Lighter variants skip even that, for code that has already disabled preemption and interrupts (inside an interrupt handler, for example).

### Step 5: Looking at other CPUs' copies
Reading another CPU's copy is fine as a snapshot. Writing to it is strongly discouraged, because it can race with that CPU's own unlocked updates. The recommended way is to send that CPU an inter-processor interrupt and let it update its own copy.

## The picture

```text
 template (in the kernel image)      CPU0 copy     CPU1 copy     CPU2 copy
 rx_count  @ +0x40           ──▶      +off[0]       +off[1]       +off[2]

 CPU1: "increment this CPU's rx_count" ─▶ one instruction: [cpu-area register + 0x40] += 1
       no lock, no cache line leaves CPU1

 /proc/stat total = CPU0 copy + CPU1 copy + CPU2 copy + …
```

## Tradeoffs

- **What it gives you:** no cache-line bouncing, lock-free updates, and single-instruction access on x86 and arm64.
- **What it costs / requires:** memory multiplied by the number of possible CPUs; totals must be summed and are only approximate while updates continue; careful handling of preemption and interrupts.
- **Where it bites:** forgetting that the one-instruction operations aren't safe against interrupt handlers touching the same data, or writing to another CPU's copy. On real-time kernels, long preemption-disabled sections for per-CPU access hurt latency, which motivated work on tying migration prevention to locks instead.

## How it got here

- **2.6.0–2.6.12:** per-CPU variables and the classic accessors; per-CPU page lists and statistics made them a hot path.
- **2.6.30 (2009):** Christoph Lameter's chunk-based dynamic allocator, laying all CPUs' data out at a fixed stride instead of keeping an array of per-CPU pointers sized for the maximum possible CPU count.
- **~3.x:** the "this CPU" operations became the preferred API, with single-instruction versions for x86 and arm64.
- **5.x+:** real-time work (Thomas Gleixner, Peter Zijlstra) on preventing migration through lock ownership rather than disabling preemption, with lockdep checks for per-CPU accesses made without the proper lock.

## Related

- Technical version: [[per-cpu-variables]]
- [[locking-explained|Locking subsystem]], [[local-lock-explained|Local locks]], [[interrupt-handling-explained|Interrupt handling]]
- [[rcu-read-copy-update-explained|RCU]], [[per-cpu-page-allocator-pcp-explained|Per-CPU page lists]], [[vmalloc-explained|vmalloc]]
