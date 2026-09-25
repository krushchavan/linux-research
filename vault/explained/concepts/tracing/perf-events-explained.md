---
title: "perf Events — Explained"
category: explained
original: "[[perf-events]]"
subsystem: tracing
tags: [explained, tracing, perf, pmu, profiling]
converted: 2026-09-25
---

# perf events, explained

> Plain-language companion to [[perf-events|the technical note]]. Same facts, fewer identifiers.

## The problem

ftrace records individual events, but many performance questions are **statistical**: which functions eat the CPU time? How often do we miss the cache? Where do branches mispredict? Recording every instruction would produce terabytes of data per second. What's needed is a way to count hardware events and take **samples** of where the program is, cheaply, across the whole workload.

## The idea in one paragraph

perf events are a **strobe light attached to a rev counter**. The rev counter is the CPU's **performance monitoring unit (PMU)**, which counts physical events such as cycles, cache misses and branch mispredictions in dedicated registers. The strobe is sampling: every N events, the counter fires an interrupt, and the kernel freezes the current instruction pointer (and optionally the call stack) and records it. Neither tells you about any single event, but over many samples the hot paths stand out, because they appear in the most snapshots.

## Step by step

### Step 1: Open an event
One system call creates an event and returns a file descriptor. The request says:
- **what** to count: a hardware counter, a kernel software counter, a tracepoint, a probe, or a hardware watchpoint
- **how often** to sample: every N events, or at a target frequency that the kernel adjusts N to hit
- **what to capture** per sample: instruction pointer, thread, timestamp, call chain, registers, raw hardware data

The descriptor can be switched on, off and reset, and **mapped** to read samples.

### Step 2: Program the hardware
For a hardware event, the CPU-specific driver chooses which event a counter register tracks and preloads the counter with **minus the sample period** (say −10,000). When it counts up past zero, the PMU raises an **NMI**.

### Step 3: Take the sample
This is the key step. The NMI handler records the interrupted instruction pointer and, if asked, a call stack, using one of three unwinding methods:
- **frame pointers:** fast, but unreliable if the code was built without them
- **DWARF:** accurate, but copies up to 64 KB of raw stack into each sample to unwind later
- **last branch record (Intel):** hardware remembers the last 16–32 taken branches, at near-zero cost and with no stack copying

It writes the sample to a ring buffer and re-arms the counter for the next period. Because it's an NMI, sampling reaches everywhere, including code running with interrupts off, which timer-based profiling would miss.

### Step 4: Hand samples to user space
perf's ring buffer is **mapped into the profiler's memory**: the kernel advances a write position, the reader advances a read position after consuming. `perf record` reads it in a tight loop and saves the records to a file for later analysis and flame graphs.

### Step 5: More events than counters
Hardware has few counters (e.g. 4 programmable plus 3 fixed on Intel Skylake). Ask for 10 events and the kernel **time-slices** them, swapping which ones are on the hardware at context switches. Each event records how long it actually ran versus how long it was enabled, and perf scales the raw count up by that ratio, marking the result as an estimate.

### Step 6: Software counters and tracepoints
Software counters, such as page faults and context switches, are counted directly by kernel code at the right spot, no PMU needed, and can drive sampling the same way. Tracepoint events add perf's sample data (stack, thread, timing) to any tracepoint's own fields, all through the same buffer, so events of different types can be lined up by timestamp. BPF programs can also attach to perf events.

### Step 7: Who may profile
A setting controls access in tiers, because a cycle count is harmless but a call chain full of kernel addresses reveals the kernel's layout: from anyone, including kernel addresses, down to root only (or holders of a dedicated **perfmon** capability, since 5.8). Many distributions let unprivileged users profile only their own processes.

## The picture

```text
 PMU counter preloaded to −10000 ── counts cache misses ──▶ overflow → NMI
                                                             │
     sample { IP, TID, time, stack (frame ptr | DWARF | LBR) } ▼
                         ring buffer (mmap'd) ──▶ perf record ─▶ perf.data ─▶ report
 10 events, 7 counters: rotate at context switch; estimate = raw × enabled/running
```

## Tradeoffs

- **What it gives you:** low-overhead, whole-system profiling (at 99–999 Hz, kilobytes per second of data), hardware counters for cache and branch behaviour, and one interface for many event types.
- **What it costs / requires:** one system call covering hardware counters, software counters, tracepoints, probes and breakpoints makes for a configuration structure with nearly 100 fields. NMI handlers must be extremely careful about re-entry and stack use.
- **Where it bites:** sampling can miss **rare** code entirely; a function that runs once a second for 1 ms may never show up. Exact event tracing (ftrace, trace-cmd) is better for that. Multiplexed counts are estimates, not exact figures.

## How it got here

- **2.6.31 (2009):** the unified perf interface (Peter Zijlstra's patches, championed by Ingo Molnár), replacing per-architecture performance-counter interfaces.
- **2.6.33:** tracepoints as perf events.
- **3.x:** DWARF unwinding and Intel last-branch-record support.
- **4.1 (2015):** choice of clock source. **4.4:** Intel Processor Trace for full instruction-level recording.
- **5.8 (2020):** the perfmon capability, so profiling doesn't need full root.
- **6.x:** AMD instruction-based sampling work and ring-buffer improvements.

## Related

- Technical version: [[perf-events]]
- [[tracing-explained|Tracing subsystem]], [[ftrace-explained|ftrace]], [[tracepoints-and-trace-event-explained|Tracepoints]], [[kprobes-and-kretprobes-explained|kprobes]], [[uprobes-and-usdt-explained|uprobes and USDT]], [[tracefs-and-ring-buffer-explained|tracefs and ring buffer]]
- [[bpf-explained|BPF]], [[scheduler-explained|Scheduler]], [[mm-explained|Memory management]], [[kernel-hardening-explained|Kernel hardening]]
