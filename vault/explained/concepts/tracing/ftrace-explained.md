---
title: "ftrace — Explained"
category: explained
original: "[[ftrace]]"
subsystem: tracing
tags: [explained, tracing, ftrace, live-patching, latency]
converted: 2026-09-25
---

# ftrace, explained

> Plain-language companion to [[ftrace|the technical note]]. Same facts, fewer identifiers.

## The problem

Many kernel problems (a scheduling hiccup, interrupts disabled for too long, an unexpected code path) only happen on a live system and can't be reproduced in a lab. To catch them you want to trace **any kernel function**, on demand, without rebuilding the kernel. But the kernel makes millions of function calls per second, so any hook left in every function must cost **nothing** when tracing is off. Even a perfectly predicted "is tracing on?" branch isn't free at that rate.

## The idea in one paragraph

ftrace is like a **motion-sensor system pre-wired into every room** of a building when it's built. When nobody's watching, each sensor is swapped for a dummy housing that draws no power. When you want to watch, the control panel (tracefs) reconnects just the sensors you want to the recorder (the ring buffer). The "wiring" is a call the compiler puts at the start of every function; at boot the kernel **overwrites each call with a no-op**, and turning tracing on overwrites the chosen no-ops back into calls.

## Step by step

### Step 1: The compiler leaves a hook
With dynamic ftrace (the normal setup), the compiler puts a call to a special stub at the very first byte of every kernel function, before any other code. The linker collects the address of every such call site into a table.

### Step 2: Boot turns every hook into a no-op
At boot, ftrace walks that table and replaces each call with a 5-byte no-op, the cheapest instruction sequence that fills the space. From then on, untraced functions pay nothing.

### Step 3: Patching live code safely
This is the key step. Other CPUs may be running the very instruction being rewritten, so the kernel can't overwrite 5 bytes in one go. The patching routine:
1. writes a **breakpoint** into the first byte, so any CPU that arrives mid-patch traps and waits
2. writes the remaining 4 bytes
3. waits until every CPU has passed through the breakpoint handler and so has seen the partial write
4. replaces the first byte with the final instruction byte

Every CPU sees either the old instruction or the new one, never a torn mix, and there's no need to stop all CPUs.

### Step 4: Turn tracing on
Selecting the function tracer rewrites the chosen functions' no-ops into calls to a small assembly **dispatcher**. It saves registers, looks up which callbacks want this function (a hash keyed by address), and calls each one with the function's address and its caller's address. Tracing can be limited by function-name patterns, module, or process.

### Step 5: Timing whole call trees
The **function graph** tracer hooks both entry and exit. On entry it replaces the function's return address with a handler, saving the real one on a per-task stack; on return, the handler records how long the call took and jumps back to where it should have gone. The output is an indented call tree with durations, flagged at a glance: + over 10 µs, ! over 100 µs, # over 1 ms.

### Step 6: Latency tracers
The irqs-off, preempt-off and wake-up tracers trace functions only **inside** a latency-sensitive window, such as from interrupts being disabled until they're re-enabled. They keep the **longest** window seen with its full call trace, replacing it only when a longer one comes along, and a threshold skips short windows. This is the tool for "why does my system occasionally miss a deadline?".

### Step 7: Aggregate in the kernel
**Histogram triggers** (4.1) attach to any event and update in-kernel tables instead of logging each occurrence, e.g. "total bytes written per process, sorted", read out with a single cat. **Synthetic events** (4.17) combine two probes, such as entry and exit, into a new event carrying the latency between them.

### Step 8: A backbone for BPF
Since 5.5, BPF's function entry and exit programs attach through ftrace's patching, using a dedicated trampoline per program that calls the compiled BPF code directly. Attached, they cost about as much as a function call, rather than a breakpoint trap like kprobes; detached, nothing.

## The picture

```text
 compile:  func: call hook ; push … ; …            (every function)
 boot:     func: nop5      ; push … ; …            (zero cost)
 enable:   func: call dispatcher ; push … ; …      (only selected functions)
                       └─▶ callbacks(func addr, caller addr) ─▶ ring buffer

 live patch of 5 bytes:  [INT3][old..] → [INT3][new..] → wait all CPUs → [new][new..]
 graph tracer: return address → handler → record duration → real caller
```

## Tradeoffs

- **What it gives you:** tracing of any kernel function on a running system at zero cost when off; call trees with timings; worst-case latency capture; in-kernel aggregation.
- **What it costs / requires:** the complexity of safe live patching on multi-core machines, which is clearly worth it given how many function calls the kernel makes. Only one tracer plugin can be the current one at a time, though several callback sets can coexist.
- **Where it bites:** histogram triggers use a restricted mini-language rather than arbitrary code, so complex aggregation needs BPF instead. Without dynamic ftrace, the hooks are real calls all the time, with significant overhead.

## How it got here

- **2.6.27 (2008):** the first function tracer, with hooks that were real calls all the time.
- **2.6.28:** structured trace events. **2.6.29:** function graph tracer (Frédéric Weisbecker).
- **2.6.30:** dynamic ftrace: no-op patching at boot, and genuinely zero cost when inactive.
- **4.1 (2015):** histogram triggers. **4.17 (2018):** synthetic events.
- **5.5 (2020):** BPF entry/exit programs built on ftrace trampolines. **6.x:** fprobe, a name-based attachment interface on top of ftrace.

## Related

- Technical version: [[ftrace]]
- [[tracing-explained|Tracing subsystem]], [[tracefs-and-ring-buffer|tracefs and ring buffer]], [[tracepoints-and-trace-event|Tracepoints]], [[kprobes-and-kretprobes|kprobes]], [[perf-events|perf events]]
- [[bpf-explained|BPF]], [[scheduler-explained|Scheduler]], [[preemption-model-explained|Preemption model]]
