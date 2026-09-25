---
title: "ftrace"
category: concept
tags: [tracing, ftrace, function-tracing, dynamic-patching, latency]
subsystem: tracing
kernel_version: "2.6.27"
researched: 2026-04-17
status: complete
explained: "[[ftrace-explained]]"
sources:
  - https://kernel-internals.org/tracing/ftrace/
  - https://kernel-internals.org/tracing/ftrace-advanced/
  - https://www.kernel.org/doc/html/latest/trace/ftrace.html
  - https://lwn.net/Articles/442113/
---

# ftrace

> 📘 Plain-language version: [[ftrace-explained]]

## Purpose

ftrace is the Linux kernel's built-in function tracing framework, providing zero-overhead-when-inactive instrumentation of every kernel function without requiring recompilation. It is the primary tool for diagnosing scheduler latency, interrupt latency, and execution path issues — problems that can only be caught at the moment they occur, not reproduced in a lab.

## Mental Model

Think of ftrace as a **motion-sensor security system** that has been pre-wired into every room (function) of a building (kernel) at construction time. When nobody is watching, the sensors are deliberately disabled — physically replaced with dummy no-op housings — so there is zero power draw and zero disturbance. When you want to watch, the control panel (tracefs) re-activates specific sensors, wiring them back to the recording system (ring buffer). Because the wiring was done at build time, enabling monitoring is instant and requires no construction work at runtime.

## How It Works

The ftrace story begins at compile time. When `CONFIG_DYNAMIC_FTRACE=y`, the compiler is given `-pg -mfentry` flags, causing it to emit a `call __fentry__` (on x86) at the very first byte of every kernel function before any prologue code runs. At the same time, the linker collects the addresses of all these call sites into the `__mcount_loc` ELF section.

At boot, `ftrace_init()` walks every entry in `__mcount_loc` and uses `text_poke_bp()` to overwrite each `call __fentry__` with a 5-byte NOP. The `text_poke_bp()` primitive works by: (1) placing an INT3 at byte 0 of the target site — this traps any CPU that reaches it during the patch; (2) writing bytes 1–4 of the new instruction; (3) waiting for all CPUs to pass through the INT3 handler, confirming they have observed the partial write; (4) replacing byte 0 with the final byte of the NOP. This ensures the transition is atomic from the perspective of any executing CPU. After init, every instrumented function has zero overhead — a 5-byte NOP is the cheapest possible instruction sequence that takes up the space.

When a tracer is enabled via `echo function > /sys/kernel/tracing/current_tracer`, ftrace reverses this process for the selected set of functions. Each patched site gets a `call ftrace_caller` instruction instead of a NOP. `ftrace_caller` is a small assembly stub that: saves the caller and callee IPs; looks up the per-function `ftrace_ops` list (a sorted hash table keyed by IP); and invokes each registered callback. Each callback receives the `ip` (function address) and `parent_ip` (caller address), which is sufficient for basic function tracing.

The `function_graph` tracer extends this by hooking both entry and return. On entry it modifies the stack frame to replace the real return address with `return_to_handler`; on return `return_to_handler` looks up the saved return address from a per-task stack, records the timestamp delta, and jumps to the original return address. This produces a full call-tree with per-function durations. Symbols marking durations appear in output: `+` indicates >10 µs, `!` >100 µs, `#` >1 ms — a quick visual indicator of where time is being spent.

Latency tracers (`irqsoff`, `preemptoff`, `wakeup`) use a different strategy: they enable function tracing only within a latency-sensitive window (e.g. from the moment interrupts are disabled to when they are re-enabled). The tracer records the longest observed window along with its complete call trace, overwriting previous records only when a longer window is found. This makes ftrace the right tool for diagnosing "why does my system occasionally miss a deadline" problems that cannot be reproduced with synthetic tests.

The histogram engine in ftrace (introduced in 4.1 via `hist` triggers) allows in-kernel aggregation. A trigger attached to an event (tracepoint, kprobe, or uprobe) can evaluate expressions and update in-kernel hash maps (histograms) without writing individual events to the ring buffer. For example, `hist:keys=pid:vals=bytes_req:sort=bytes_req.descending` attached to `sys_enter_write` accumulates total bytes written per PID, producing a sorted summary with a single `cat` of the `hist` file — zero per-event userspace round-trips. Synthetic events combine data from two probes (e.g. entry and exit timestamps) to derive a latency metric and fire it as a new named event, enabling multi-event correlation entirely in-kernel.

Since Linux 5.5, ftrace's dynamic patching machinery serves as the backend for BPF `fentry`/`fexit` programs, which are attached by name (resolved to an address at attach time) and use per-`ftrace_ops` trampolines for near-zero overhead. This was a major shift: instead of kprobes (INT3-based), BPF programs now get direct-call overhead equivalent to a function call when attached and true zero overhead when detached.

## Key Data Structures

**`struct ftrace_ops`** (`include/linux/ftrace.h`) — one instance per registered tracer or BPF program.
- `func` — the callback invoked at each traced site; receives `ip` (callee) and `parent_ip` (caller)
- `flags` — bitfield: `FTRACE_OPS_FL_SAVE_REGS` (save full `pt_regs` for BPF), `FTRACE_OPS_FL_RECURSION` (recursion guard), `FTRACE_OPS_FL_RCU` (RCU-safe invocation)
- `trampoline` — address of the per-ops trampoline; BPF uses this to call the JIT'd program directly without going through the generic `ftrace_caller` dispatch loop
- `hash` — `ftrace_ops_hash` filtering which function addresses this ops monitors

**`struct ftrace_func_entry`** (`include/linux/ftrace.h`) — one entry in the per-ops hash table.
- `ip` — the kernel function address being monitored

## Key Functions / Entry Points

**`register_ftrace_function()`** (`kernel/trace/ftrace.c`) — installs an `ftrace_ops` and patches the relevant function sites from NOP to `call ftrace_caller`.

**`unregister_ftrace_function()`** (`kernel/trace/ftrace.c`) — removes an `ftrace_ops`; patches sites back to NOP if no other ops monitors them.

**`ftrace_set_filter()`** / **`ftrace_set_notrace()`** (`kernel/trace/ftrace.c`) — restrict the set of functions monitored by an ops; accept glob patterns and module-scoped filters (`:mod:ext4`).

**`ftrace_caller`** (arch/x86/kernel/ftrace_64.S) — the assembly stub called at each instrumented site; saves registers, dispatches to callbacks, restores registers.

**`text_poke_bp()`** (`arch/x86/kernel/alternative.c`) — INT3-based safe live-patching primitive used to transition sites between NOP and `call ftrace_caller`.

**`ftrace_graph_entry()`** / **`ftrace_graph_return()`** — function-graph tracer callbacks that record entry time and duration.

## Important Flags & Config Options

- `CONFIG_FUNCTION_TRACER` — enables the basic function tracer
- `CONFIG_FUNCTION_GRAPH_TRACER` — enables function_graph (entry+exit with timing)
- `CONFIG_DYNAMIC_FTRACE` — enables NOP patching at boot; without this, `__fentry__` calls are real function calls at all times (significant overhead)
- `CONFIG_HAVE_FENTRY` — arch support for `__fentry__` (pre-function call); required for CONFIG_DYNAMIC_FTRACE on x86
- `current_tracer` (tracefs) — selects active tracer; writing clears the ring buffer
- `set_ftrace_filter` / `set_ftrace_notrace` (tracefs) — glob-based function include/exclude lists
- `set_ftrace_pid` / `set_ftrace_notrace_pid` (tracefs) — per-process tracing control
- `tracing_thresh` (tracefs) — latency tracers only record windows longer than this value (microseconds)
- `max_graph_depth` (tracefs) — limits function_graph call tree depth to reduce noise

## Interactions with Other Subsystems

- **↑ Userspace**: controlled entirely through tracefs file reads/writes; `trace-cmd` automates multi-step workflows; `perf ftrace` exposes ftrace via the perf tool interface
- **→ Ring Buffer**: all ftrace callbacks deposit events via `ring_buffer_lock_reserve()` / `ring_buffer_unlock_commit()`
- **→ BPF**: BPF `fentry`/`fexit` programs use ftrace's per-ops trampolines as their attachment mechanism since Linux 5.5
- **← Scheduler**: `wakeup` and `wakeup_rt` latency tracers instrument `try_to_wake_up()` and `__schedule()` to measure scheduling latency

## Design Decisions & Tradeoffs

**NOP patching over runtime conditionals** — An alternative would be a single `if (tracing_enabled)` check per function. NOP patching achieves true zero overhead (no branch, no cache miss) at the cost of the `text_poke_bp()` complexity needed for SMP safety. The tradeoff is clearly worth it: the kernel has millions of function calls per second, and even a perfectly-predicted branch has nonzero CPU cost.

**Modular tracer plugins over a monolith** — Each tracer (function, function_graph, irqsoff, wakeup, blk, mmiotrace) is a separate plugin registered via `register_tracer()`. This allows specialised tracers to share the ring buffer and tracefs infrastructure without coupling. The cost is that only one `current_tracer` can be active at a time (though multiple `ftrace_ops` can coexist via the per-ops hash).

**Histograms in-kernel over userspace aggregation** — Before `hist` triggers, high-rate events had to be streamed to userspace for aggregation, which imposed enormous overhead for events that fire millions of times per second. In-kernel histograms move the aggregation to the kernel, with the tradeoff that the aggregation logic must be expressed in a restricted domain-specific language rather than arbitrary code (BPF closes that gap).

## How It Has Evolved

- **2.6.27 (2008)** — Initial function tracer with static instrumentation (real `mcount` calls at all times)
- **2.6.28** — `TRACE_EVENT` system introduced alongside ftrace
- **2.6.29** — function_graph tracer (Frédéric Weisbecker); entry+exit with nanosecond durations
- **2.6.30** — `CONFIG_DYNAMIC_FTRACE`: NOP patching at boot; true zero overhead when inactive
- **4.1 (2015)** — `hist` triggers for in-kernel histogram aggregation
- **4.17 (2018)** — Synthetic events for two-probe correlated latency measurement
- **5.5 (2020)** — BPF `fentry`/`fexit` hooks backed by ftrace trampolines
- **6.x** — Ongoing work on `fprobe` as a higher-level, stable-name-based attachment API over ftrace

## Further Reading

1. [ftrace — Function Tracer (kernel.org)](https://www.kernel.org/doc/html/latest/trace/ftrace.html) — comprehensive control-file reference
2. [Function Tracer Design (kernel.org)](https://static.lwn.net/kerneldoc/trace/ftrace-design.html) — internal design of the patching mechanism
3. [Ftrace, perf, and the tracing ABI (LWN, 2012)](https://lwn.net/Articles/442113/) — ABI stability debate; Linus on interface design
4. [kernel-internals.org: ftrace](https://kernel-internals.org/tracing/ftrace/) — practical examples with ring buffer architecture detail

## LKML Highlights

- **ABI stability thread (2012)** — When a tracepoint field removal broke `powertop`, Linus said "if you made an interface that can be used without parsing the description, we're stuck with the interface", establishing tracepoint binary formats as stable ABI (see lwn.net/Articles/442113/).
