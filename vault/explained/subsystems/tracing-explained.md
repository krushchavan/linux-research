---
title: "Linux Kernel Tracing Subsystem — Explained"
category: explained
original: "[[tracing]]"
subsystem: tracing
tags: [explained, tracing, ftrace, kprobes, perf]
converted: 2026-09-25
---

# The tracing subsystem, explained

> Plain-language companion to [[tracing|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

When a production kernel misbehaves (a latency spike, a slow syscall, a mystery CPU hog), you need to see what it's doing **while it runs**, without rebuilding or rebooting it. But observation has costs and conflicting needs:
- instrumentation that's always compiled in must cost **nothing** when nobody is looking
- recording events can't take locks, because events fire from interrupts and NMIs
- some questions need stable, named events; others need a probe on an arbitrary instruction nobody planned for
- some need exact event logs, others statistical sampling and hardware counters

No single tool fits all of these, so Linux deliberately provides several that share one foundation.

## The big picture

Think of a **telescope with interchangeable lenses**. The mount never changes: a control filesystem (**tracefs**) and a **lock-free per-CPU ring buffer**. The lenses are swapped in as needed: function tracing, tracepoints, dynamic kernel probes, user-space probes, and performance counters. Tools like trace-cmd, perf and bpftrace are the eyepiece that interprets what comes through. Adding a new lens never requires rebuilding the mount.

```text
 instrumentation:  ftrace   tracepoints   kprobes   uprobes/USDT        perf events
                     │          │            │           │                  │
                     └──────────┴─────┬──────┴───────────┘                  │
                                      ▼                                     ▼
                       lock-free per-CPU ring buffer              perf's mmap'd ring buffer
                                      │                                     │
                     tracefs (/sys/kernel/tracing): control + output        │
                                      │                                     │
 front ends:          echo/cat, trace-cmd, kernelshark        perf       bpftrace/BCC (both)
```

## The pieces

### tracefs and the ring buffer
tracefs, mounted at /sys/kernel/tracing, is the control panel: choose the active tracer, switch recording on and off without removing instrumentation ("arm now, fire later"), filter which functions are traced, and enable, filter or trigger individual events.

Under it sits a **per-CPU ring buffer** made of linked page-sized chunks. Writers claim space with atomic compare-and-swap, so there's no lock on the write path. If an interrupt or NMI interrupts a writer mid-event, it does its own nested write, and the interrupted writer can't commit until the nested one finishes. Readers swap a private spare page with the next full one, also lock-free. When the buffer is full, it overwrites the oldest data by default, or drops new events if configured to. Separate **instances** give independent buffers, so one tool can record without disturbing a system-wide trace. See [[tracefs-and-ring-buffer-explained|tracefs and the ring buffer]].

### ftrace
ftrace is a function tracer that's **free when idle**. The compiler puts a call at the start of every traceable function; at boot, the kernel replaces each call with a no-op, using a breakpoint-based patching trick that avoids stopping all CPUs. Enabling function tracing turns the no-ops back into calls to a small stub that runs the registered callbacks. The **function graph** tracer also hooks returns (by swapping the return address), producing call trees with durations and markers for slow calls. **Latency tracers** record the longest stretch with interrupts off, pre-emption off, or wake-up delay, with a full call trace. **Histogram triggers** aggregate data in the kernel ("bytes requested per process, sorted"), and **synthetic events** combine two probes, such as syscall entry and exit, into a derived latency event. BPF's function entry and exit hooks reuse this patching machinery. See [[ftrace-explained|ftrace]].

### Tracepoints
Tracepoints are named hooks that developers place in kernel code, with a **stable interface**: their names and fields are treated as user-visible and mustn't change. When nothing is attached, each costs a single no-op instruction; attaching patches it into a jump. The richer form also describes how to record and print the event, published as a format file so tools can decode binary records without hard-coding offsets. See [[tracepoints-and-trace-event-explained|tracepoints]].

### kprobes and kretprobes
kprobes can attach to **almost any kernel instruction** at runtime. The kernel saves the original instruction, overwrites its first byte with a breakpoint, and on a hit runs the handler, single-steps the original instruction out of line, and continues. That costs roughly 0.5–1 µs per hit, or about 0.07 µs when the kernel can use a direct jump instead (optimised probes). Return probes swap the function's return address for a trampoline. The price of flexibility is fragility: inlined or renamed functions silently escape the probe, which is why tracepoints are preferred for production monitoring. fprobe (5.0) is a higher-level, name-based variant safe for BPF. See [[kprobes-and-kretprobes-explained|kprobes]].

### uprobes and USDT
uprobes bring the same breakpoint approach to **user-space programs**, without ptrace. A probe is registered on a (file, offset) pair; mapped pages containing it get a copy-on-write patched version, so one registration covers every process running that binary. **USDT** markers are no-ops that developers compile into programs with metadata describing each probe; tools find them, and enabling one is purely a kernel-side patch, costing nothing when inactive. See [[uprobes-and-usdt|uprobes and USDT]].

### perf events
perf events **sample** the system and read **hardware counters**. One system call creates an event: a hardware counter, software counter, tracepoint or probe, with a sample rate and a choice of what to capture. For hardware events, the CPU's performance unit is programmed to interrupt (via NMI) after N events; the handler records the instruction pointer and optionally a call stack into a ring buffer shared with user space. With more events than hardware counters (e.g. 4 general plus 3 fixed on Skylake), the kernel time-slices them and scales the results. Stacks can be unwound with frame pointers (fast, unreliable without them), DWARF data (accurate, but copies up to 64 KB of stack per sample), or Intel's last-branch record hardware. See [[perf-events-explained|perf events]].

## A request's journey

`bpftrace -e 'kprobe:tcp_sendmsg { @bytes = hist(arg2); }'`:

1. **Resolve.** bpftrace looks up the address of the TCP send function.
2. **Load.** It loads a BPF program of the kprobe type.
3. **Probe.** The kernel saves the function's first instruction and plants a breakpoint.
4. **Fire.** Whenever any process sends on TCP, the breakpoint traps and the JIT-compiled BPF program runs in the kernel.
5. **Aggregate in place.** This is the key moment: the program reads the length argument from the saved registers and updates a histogram map **inside the kernel**. No per-event record goes to user space, so even very frequent events are cheap to summarise.
6. **Clean up.** On exit, the original instruction is restored.

## Tradeoffs

- **What it gives you:** zero-cost-when-off instrumentation everywhere, lock-free recording even from NMIs, stable events for tools, dynamic probes for everything else, and in-kernel aggregation.
- **What it costs / requires:** per-CPU buffers avoid locks but produce events out of order across CPUs (timestamps help but don't fully fix this). Live code patching requires careful breakpoint-based sequences on multi-core machines.
- **Where it bites:** tracepoints became stable interfaces after a tool (powertop) broke in 2.6.39 when a field was removed. Linus's view was that an interface usable without parsing its description is one "we're stuck with", so changing tracepoints now needs interface review. kprobes deliberately have no stability promise, so code can still be renamed and inlined freely. The many tools (ftrace, perf, LTTng, bpftrace) are intentional: Steven Rostedt argued "diversity brings innovation", and shared libraries let them reuse the kernel side.

## How it got here

- **2.6.27 (2008):** ftrace (Steven Rostedt), with a per-CPU but still locked buffer. **2.6.28:** structured trace events.
- **2.6.29:** function graph tracer (Frédéric Weisbecker). **2.6.31:** perf events (Ingo Molnár, Peter Zijlstra). **2.6.32:** lock-free ring buffer.
- **3.5 (2012):** uprobes. **4.1 (2015):** in-kernel histograms. **4.7:** BPF on uprobes and USDT. **4.17:** synthetic events.
- **5.0:** fprobe. **5.5:** BPF function entry/exit hooks built on ftrace. **5.14:** user-space-defined events.
- **Ongoing:** moving BPF from kprobes to fprobe, shared tracing libraries, Arm hardware tracing, and memory-mapping the ring buffer directly to cut copying.

## Related

- Technical version: [[tracing]]
- [[tracefs-and-ring-buffer-explained|tracefs and ring buffer]], [[ftrace-explained|ftrace]], [[tracepoints-and-trace-event-explained|Tracepoints]], [[kprobes-and-kretprobes-explained|kprobes]], [[uprobes-and-usdt|uprobes and USDT]], [[perf-events-explained|perf events]]
- [[bpf-explained|BPF]], [[bpf-program-types-explained|BPF program types]], [[scheduler-explained|Scheduler]], [[mm-explained|Memory management]], [[interrupt-handling-explained|Interrupt handling]]
