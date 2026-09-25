---
title: "Tracepoints and TRACE_EVENT — Explained"
category: explained
original: "[[tracepoints-and-trace-event]]"
subsystem: tracing
tags: [explained, tracing, tracepoints, jump-labels, abi]
converted: 2026-09-25
---

# Tracepoints, explained

> Plain-language companion to [[tracepoints-and-trace-event|the technical note]]. Same facts, fewer identifiers.

## The problem

kprobes can attach almost anywhere, but they break silently whenever a function is renamed, inlined or changes shape between kernel versions. Monitoring tools that run for years in production need hooks that **stay put**: the same names, carrying the same data, on every kernel. And since those hooks sit in hot paths such as the scheduler, they must cost nothing when no one is listening.

## The idea in one paragraph

Tracepoints are **junction boxes wired into the building during construction**, with labelled ports. Developers place named hooks at meaningful points in kernel code. When nothing is plugged in, the box is covered with a blank plate: a single no-op instruction. Plugging in a probe swaps the plate for a live connector. The labels (event name, field names and types) are fixed once installed, like a system-call interface, so tools keep working across kernel versions.

## Step by step

### Step 1: Declare the event
A developer declares a tracepoint in a header. The simple form only defines the hook. The richer **trace event** form also says which fields to record, how to copy them quickly into the ring buffer, and how to print them.

### Step 2: Call it from kernel code
Inside, say, the scheduler, the code calls the generated "trace sched switch" function with the previous and next task. That call is inline and starts with a **static key** check.

### Step 3: Zero cost when off
This is the key step. With **jump labels**, the disabled check is compiled as a plain no-op: no branch, no memory load. Attaching a probe (by enabling the event in tracefs, or a BPF program registering) live-patches that no-op into a short jump to the probe code. Without jump-label support, the check falls back to a variable test, still cheap but measurable at millions of calls per second. A companion "is this enabled?" check lets callers skip computing expensive arguments when no one is listening.

### Step 4: Record the fields
When active, the probe copies the declared fields (for a context switch: previous and next task's name, process ID and priority) into a compact binary record in the ring buffer. Probes are held in a small RCU-protected list, so adding and removing them never disturbs callers already inside.

### Step 5: Publish a format description
Each event gets a **format** file listing its fields' names, types, offsets and sizes, and how to print it. Tools read this to decode binary records instead of hard-coding offsets. That's the mechanism that makes a stable interface workable.

### Step 6: Filter and trigger in the kernel
Each event has a **filter** (e.g. "previous process ID is 1234") that runs inside the probe and throws away non-matching events before any buffer space is reserved. **Triggers** run actions when an event fires (optionally only if a filter matches): capture a stack trace, take a snapshot, turn tracing on or off, or enable another event. Triggers also feed the in-kernel histogram engine, e.g. counting pairs of context-switching processes without any user-space round trips.

### Step 7: Keep the promise
Names and field layouts are treated as interfaces: renaming, retyping or reordering a field gets the same scrutiny as changing a system call. Adding fields at the end is generally acceptable; removing one needs coordination with tool authors.

## The picture

```text
 kernel code:   … trace_sched_switch(prev, next) …
 disabled:      [ nop ]                       ← zero cost
 enabled:       [ jmp probe ] → filter? → copy fields → ring buffer record
 format file:   field:prev_pid  offset:24 size:4 …   ← tools decode by reading this
 trigger:       hist:keys=prev_pid,next_pid → in-kernel table
```

## Tradeoffs

- **What it gives you:** stable, self-describing events that work across kernel versions; zero overhead when disabled; filtering, triggers and aggregation in the kernel. The trace event form wires up the buffer format, tracefs files and perf support automatically, which is why it's nearly always chosen over the bare hook.
- **What it costs / requires:** developers can't freely change a tracepoint's fields. Renaming a field in a key event means keeping the old one or coordinating with tool maintainers.
- **Where it bites:** the stability rule came from pain: in 2.6.39 a field removal broke powertop, which had decoded the binary layout directly. Linus ruled that an interface usable without parsing its description is one "we're stuck with", which settled that field layouts are part of the kernel's interface.

## How it got here

- **2.6.28 (2008):** the trace event system, alongside ftrace.
- **2.6.39 (2011):** the powertop breakage, after which field layouts were declared stable.
- **3.x:** filters and triggers on event files.
- **4.1 (2015):** histogram triggers. **4.17 (2018):** synthetic events built from two correlated events.
- **5.14 (2021):** user-space programs can define compatible events and fire them into the kernel buffer.

## Related

- Technical version: [[tracepoints-and-trace-event]]
- [[tracing-explained|Tracing subsystem]], [[ftrace-explained|ftrace]], [[kprobes-and-kretprobes-explained|kprobes]], [[tracefs-and-ring-buffer-explained|tracefs and ring buffer]], [[perf-events-explained|perf events]], [[uprobes-and-usdt-explained|uprobes and USDT]]
- [[bpf-explained|BPF]], [[scheduler-explained|Scheduler]], [[rcu-read-copy-update-explained|RCU]]
