---
title: "Tracepoints and TRACE_EVENT"
category: concept
tags: [tracing, tracepoints, trace-event, jump-labels, abi]
subsystem: tracing
kernel_version: "2.6.28"
researched: 2026-04-17
status: complete
explained: "[[tracepoints-and-trace-event-explained]]"
sources:
  - https://kernel-internals.org/tracing/kprobes-tracepoints/
  - https://www.kernel.org/doc/html/latest/trace/tracepoints.html
  - https://www.kernel.org/doc/html/latest/trace/events.html
  - https://lwn.net/Articles/442113/
---

# Tracepoints and TRACE_EVENT

> 📘 Plain-language version: [[tracepoints-and-trace-event-explained]]

## Purpose

kprobes can attach to any kernel instruction but break silently whenever a function is renamed, inlined, or its calling convention changes between kernel versions. Tracepoints provide named, developer-placed hooks whose names and field layouts are treated as a stable ABI — analogous to a syscall interface — so that monitoring tools built against one kernel continue to work on newer kernels without modification.

## Mental Model

Think of tracepoints as **electrical junction boxes** wired into a building during construction, with labelled ports (the tracepoint name and fields). When no monitoring equipment is connected, the junction box is capped with a blank plate (a NOP instruction). When you plug in a probe, the blank plate is swapped for a live connector. The junction box design (field names, types, order) is frozen at the time of installation and cannot be changed without replacing the entire wiring — the same guarantee tracepoints make across kernel versions.

## How It Works

A tracepoint starts as a macro invocation in a header file. `DECLARE_TRACE(name, proto, args)` declares the tracepoint and generates an inline function `trace_name(args...)` that any subsystem code can call. The richer `TRACE_EVENT(name, TP_PROTO(...), TP_ARGS(...), TP_STRUCT__entry(...), TP_fast_assign(...), TP_printk(...))` macro additionally specifies how to serialise the arguments into the ring buffer and how to format them for human-readable output.

At the call site — say, inside the scheduler's `__schedule()` function — `trace_sched_switch(prev, next, prev_state)` expands to an inline function. Inside that function, a `static_key_false(&__tracepoint_sched_switch.key)` check acts as the gate. When no probe is attached, `static_key_false` returns false, and the compiler emits the check as an unconditional NOP (via the jump-label mechanism). This is genuine zero overhead: no branch instruction appears in the hot path.

When a probe is attached (e.g. by writing `1` to `events/sched/sched_switch/enable` in tracefs, or by a BPF program calling `tracepoint_probe_register()`), the jump-label infrastructure patches that NOP to a short forward branch using `text_poke()`. The branch target is the probe body, which serialises the event fields into the ring buffer via `TP_fast_assign`. For the TRACE_EVENT macro, the serialisation copies the `prev_comm`, `prev_pid`, `prev_prio`, `next_comm`, `next_pid`, and `next_prio` fields into a compact binary record whose layout is described by the `TP_STRUCT__entry` section. A `format` file is automatically generated under `events/sched/sched_switch/` containing: field names, types, byte offsets, and the `TP_printk` format string. This is the key to ABI stability — consumers parse the `format` file to discover field offsets dynamically rather than hardcoding them.

The stability guarantee is explicit: tracepoint names and their fields are versioned kernel interfaces. Renaming a tracepoint field, changing its type, or reordering fields requires the same scrutiny as changing a syscall signature. Adding new fields at the end is generally acceptable if it doesn't break the format-file description; removing fields requires explicit ABI coordination. This guarantee was established pragmatically after the 2.6.39 `powertop` incident, when a field removal broke a userspace tool that had directly decoded the binary format (see Design Decisions).

The `TRACE_EVENT` macro also creates a `trace_sched_switch_enabled()` helper that allows call sites to cheaply check whether the tracepoint is active before computing expensive arguments — this avoids the cost of building argument values that would only be discarded.

Event filters (`filter` file under each event) allow server-side rejection of events before they reach the ring buffer: a filter expression like `prev_pid == 1234` is compiled into a simple comparator that runs inside the tracepoint handler, dropping non-matching events before `ring_buffer_lock_reserve()` is called.

Event triggers extend this further: a trigger attached to a tracepoint can execute kernel-side actions (capture a stack trace, take a ring-buffer snapshot, enable another event) whenever the event fires and optionally passes a filter condition. This composes well with the histogram engine: `hist:keys=prev_pid,next_pid` on `sched_switch` counts context-switch pairs entirely in-kernel.

## Key Data Structures

**`struct tracepoint`** (`include/linux/tracepoint.h`) — the per-tracepoint kernel object; one instance per `DECLARE_TRACE`.
- `key` — a `static_key_false` jump-label; this is the sole per-call overhead when the tracepoint is disabled (a NOP patched into the call site)
- `funcs` — `__rcu`-protected pointer to an array of registered probe callbacks; typically 1–2 entries; updated via RCU when probes are added/removed
- `name` — stable string name as it appears in tracefs

**`struct trace_event_call`** (`include/linux/trace_events.h`) — richer descriptor generated by `TRACE_EVENT`; holds serialisation and formatting metadata.
- `fmt` — the `TP_printk` format string
- `fields` — list of `ftrace_event_field` structs describing each field's name, type, offset, and size (this is what the `format` file exposes)
- `reg` — registration function that connects the event to tracefs

## Key Functions / Entry Points

**`trace_name()`** — the generated inline call-site function; checks the `static_key` and dispatches to probes if active.

**`trace_name_enabled()`** — returns true if the tracepoint has any active probe; useful to guard expensive argument computation.

**`tracepoint_probe_register()`** (`kernel/tracepoint.c`) — attaches a callback to a named tracepoint; patches the jump-label NOP to a branch.

**`tracepoint_probe_unregister()`** (`kernel/tracepoint.c`) — detaches a callback; uses RCU to wait for all in-flight invocations to complete before freeing.

**`register_trace_event()`** (`kernel/trace/trace_events.c`) — registers a `trace_event_call` with the ftrace event system, creating the tracefs files.

## Important Flags & Config Options

- `CONFIG_TRACEPOINTS` — enables the tracepoint infrastructure; selected by `CONFIG_TRACING`
- `CONFIG_JUMP_LABEL` — enables the jump-label patching optimisation; without it, `static_key_false` falls back to a runtime variable check (still cheap but not zero)
- `events/<subsys>/<event>/enable` (tracefs) — write `1`/`0` to activate/deactivate an event
- `events/<subsys>/<event>/filter` (tracefs) — boolean filter expression; fields and operators from the `format` file
- `events/<subsys>/<event>/trigger` (tracefs) — trigger actions: `traceon`, `traceoff`, `stacktrace`, `snapshot`, `hist:...`
- `set_event` (tracefs) — bulk event enable/disable with subsystem wildcards (`sched:*`)

## Interactions with Other Subsystems

- **↑ Userspace**: tools parse `events/<event>/format` to decode ring-buffer binary records; `perf list tracepoint` enumerates all available tracepoints; BPF `bpf_attach_tracepoint()` registers a BPF program as a probe
- **→ Ring Buffer**: `TP_fast_assign` writes directly into reserved ring-buffer space via `ring_buffer_lock_reserve()`
- **→ Jump Labels**: `static_key_false` relies on the jump-label subsystem for NOP→branch patching via `text_poke()`
- **← All subsystems**: every kernel subsystem that cares about observability places `trace_<event>()` calls at semantically meaningful points; the MM subsystem has `kmem` tracepoints, the scheduler has `sched` tracepoints, networking has `net`, etc.

## Design Decisions & Tradeoffs

**Stable ABI over flexibility** — The 2011 decision to freeze tracepoint field layouts as ABI was controversial. Kernel developers are free to refactor internals, but tracepoints at key boundary points must retain their field names and types. This creates a real cost: a developer who wants to rename a field in `sched_switch` must either keep the old field (with possible deprecation annotation) or coordinate with tool maintainers. The benefit is that monitoring infrastructure built once continues to work across kernel upgrades — critical for long-lived production environments.

**`TRACE_EVENT` over raw `DECLARE_TRACE`** — `DECLARE_TRACE` gives maximum flexibility (no format metadata, callers decide entirely what to do with args). `TRACE_EVENT` trades flexibility for integration: it generates ring-buffer serialisation, format files, and tracefs wiring automatically. The TRACE_EVENT route is the overwhelmingly common choice because the integration cost is paid once at definition time and the benefits (tracefs visibility, filter support, perf integration) are immediate.

**Jump labels over conditional branches** — A `static_key_false` check with jump-label support compiles to a NOP when false (zero overhead); without jump-label support it compiles to a memory load + conditional branch (still cheap, but measurable at millions of calls/second). The `CONFIG_JUMP_LABEL` dependency means tracepoint overhead on x86 with a modern kernel is genuinely zero when disabled.

## How It Has Evolved

- **2.6.28 (2008)** — Initial `TRACE_EVENT` macro system alongside ftrace
- **2.6.39 (2011)** — The powertop ABI incident: a field removal broke a userspace tool, resulting in field layouts being declared stable ABI
- **3.x** — `filter` and `trigger` support added to tracefs event files
- **4.1 (2015)** — `hist` triggers for in-kernel histogram aggregation attached to tracepoints
- **4.17 (2018)** — Synthetic events: tracepoints that are fired programmatically from trigger actions on two correlated events
- **5.14 (2021)** — `user_events`: userspace processes can define TRACE_EVENT-compatible tracepoints and fire them into the kernel ring buffer

## Further Reading

1. [Using the Linux Kernel Tracepoints (kernel.org)](https://www.kernel.org/doc/html/latest/trace/tracepoints.html) — official design documentation
2. [Event Tracing (kernel.org)](https://www.kernel.org/doc/html/latest/trace/events.html) — tracefs event interface, filters, triggers
3. [Ftrace, perf, and the tracing ABI (LWN, 2012)](https://lwn.net/Articles/442113/) — the ABI stability debate

## LKML Highlights

- **Powertop ABI thread (2011)** — When 2.6.39 removed `lock_depth` from a tracepoint, `powertop` broke. Linus said: "if you made an interface that can be used without parsing the interface description, then we're stuck with the interface." This settled the debate: tracepoint field layouts are ABI.
