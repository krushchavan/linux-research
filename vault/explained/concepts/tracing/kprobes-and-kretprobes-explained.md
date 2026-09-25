---
title: "kprobes and kretprobes — Explained"
category: explained
original: "[[kprobes-and-kretprobes]]"
subsystem: tracing
tags: [explained, tracing, kprobes, dynamic-instrumentation, bpf]
converted: 2026-09-25
---

# kprobes and kretprobes, explained

> Plain-language companion to [[kprobes-and-kretprobes|the technical note]]. Same facts, fewer identifiers.

## The problem

Tracepoints only exist where developers thought to put them, and ftrace's hooks sit only at function entries. When you need to see what's happening at some *other* spot in a running kernel (the middle of a function, an uninstrumented helper, the value a function returns), there's nothing there to attach to, and rebuilding and rebooting the kernel is often out of the question. You need to plant a probe on almost any instruction of a live kernel, safely, while other CPUs are running that same code.

## The idea in one paragraph

A kprobe is **surgery on a running patient**. The kernel removes the first byte of the target instruction, puts a **pager** (a breakpoint instruction) in its place, and keeps the original safe in a pocket. When execution hits the pager, the kernel runs your handler, then carefully performs the original instruction on the side, optionally runs a follow-up handler, and carries on as if nothing happened. Nothing stops, nothing reboots. The risks: probe the wrong spot and the patient crashes; probe code that's been inlined or renamed away and the pager never goes off.

## Step by step

### Step 1: Check and prepare
Registering a probe first checks the address is allowed. The kprobe machinery itself, and code specially marked as off-limits, can't be probed, which prevents recursion. The kernel then copies the original instruction (on x86, enough bytes for at least one whole instruction, since lengths vary) into a private buffer.

### Step 2: Plant the breakpoint
The first byte of the target is overwritten with a breakpoint instruction. The probe is added to a hash table keyed by address.

### Step 3: Hit and handle
When a CPU reaches the breakpoint, it traps and saves all registers. The handler finds the probe from the address and calls the **pre-handler** with the saved registers. The pre-handler runs in the same context as the probed code, with pre-emption and possibly interrupts disabled, and can even change registers to alter what happens next.

### Step 4: Run the original instruction on the side
This is the key step. The saved original instruction is placed in a per-CPU trampoline, the CPU's **single-step** flag is set, and execution resumes at the trampoline. The CPU runs the real instruction with all its effects, then immediately traps again because of the single-step flag. That second handler calls the optional **post-handler**, clears the flag, and resumes just after the probed instruction. The breakpoint stays in place for the next hit.

### Step 5: Optimise hot probes
Two traps per hit cost roughly 0.5–1 µs. With **optimised probes**, once a probe has been hit enough times, the kernel checks whether the surrounding code is safe (all within one function, no jumps into the middle, instructions safe to run elsewhere) and, if so, swaps the breakpoint for a 5-byte **direct jump** to the trampoline. That cuts the cost about tenfold, to around 0.07–0.1 µs.

### Step 6: Catch returns (kretprobes)
Instead of probing every return instruction, a **kretprobe** probes the function's entry. On entry it saves the real return address and replaces it with a trampoline's address. When the function returns, it lands in the trampoline, which calls the **return handler** with the return value and then jumps to the real return address. Each active call needs its own saved address, so a fixed pool of per-call records is **pre-allocated**. If recursion or concurrency uses them all up, further calls are skipped and counted as missed, which is better than failing an allocation in interrupt context.

### Step 7: Use them from outside
kprobes can be defined as trace events through tracefs (so hits land in the ring buffer like any tracepoint), added with perf, or, most commonly today, used by **BPF** programs doing in-kernel aggregation. fprobe (5.0) attaches by function name through ftrace's patching instead of a breakpoint, and is the preferred base for new BPF kprobe programs.

## The picture

```text
 register:  target: [mov ...][...]   → save "mov ..." → target: [INT3][...]
 hit:       INT3 trap → pre-handler(regs)
            → trampoline: mov ...  (single-step flag on) → trap → post-handler
            → resume after the original instruction
 optimised: target: [JMP trampoline]  (~10× cheaper per hit)
 kretprobe: entry: save real return address, swap in trampoline
            ret → trampoline → return handler(return value) → real caller
```

## Tradeoffs

- **What it gives you:** instrumentation of almost any kernel instruction on a live system, with no rebuild; the ability to reach code with no tracepoints or compiled-in hooks.
- **What it costs / requires:** a trap per hit (or two, with single-stepping), unless optimised; pre-allocated memory for return probes.
- **Where it bites:** it's deliberately **fragile**. If a function is inlined, only any out-of-line copy is probed and calls from inlined sites are invisible; if it's renamed between kernels, the probe silently does nothing. That's intentional: making no promises lets developers and compilers inline and reorganise freely. Production monitoring that needs stability should use tracepoints; kprobes are the power tool for ad-hoc debugging.

## How it got here

- **2.6.9 (2004):** kprobes merged, breakpoint-based on x86; review focused on making patching atomic with respect to other CPUs.
- **2.6.16 (2006):** kretprobes.
- **2.6.26 (2008):** jump optimisation, cutting per-hit cost about tenfold.
- **3.x:** kprobes exposed as trace events through tracefs.
- **5.0 (2019):** fprobe, name-based and built on ftrace. **5.5 (2020):** BPF entry/exit hooks on ftrace trampolines; kprobe-based BPF starts moving to fprobe.

## Related

- Technical version: [[kprobes-and-kretprobes]]
- [[tracing-explained|Tracing subsystem]], [[ftrace-explained|ftrace]], [[tracepoints-and-trace-event|Tracepoints]], [[uprobes-and-usdt|uprobes and USDT]], [[tracefs-and-ring-buffer|tracefs and ring buffer]], [[perf-events-explained|perf events]]
- [[bpf-explained|BPF]], [[bpf-program-types-explained|BPF program types]]
