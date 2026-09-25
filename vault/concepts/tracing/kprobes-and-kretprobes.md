---
title: "kprobes and kretprobes"
category: concept
tags: [tracing, kprobes, kretprobes, dynamic-instrumentation, breakpoints]
subsystem: tracing
kernel_version: "2.6.9"
researched: 2026-04-17
status: complete
explained: "[[kprobes-and-kretprobes-explained]]"
sources:
  - https://kernel-internals.org/tracing/kprobes-tracepoints/
  - https://www.kernel.org/doc/html/latest/trace/kprobes.html
  - https://lwn.net/Articles/343766/
---

# kprobes and kretprobes

> 📘 Plain-language version: [[kprobes-and-kretprobes-explained]]

## Purpose

Tracepoints cover developer-chosen locations; kprobes cover everywhere else. A kprobe lets a developer or operator attach a handler to *any* kernel instruction at runtime — a function entry, a return site, an individual arithmetic instruction — without kernel recompilation. This makes kprobes the primary escape hatch for debugging uninstrumented kernel code and for attaching BPF programs to arbitrary kernel functions.

## Mental Model

Think of kprobes as a **surgical implant** performed on a running patient. The surgeon (kernel kprobe machinery) removes one byte of the patient's code, inserts a pager (INT3), and stores the removed byte safely in a pocket. When the pager fires, the surgeon performs the procedure (pre-handler), carefully reinstates the original operation (single-step), optionally does a follow-up (post-handler), then puts the pager back. The patient never stops running — there is no full-stop, no reboot. The risk is that the surgeon must be precise: cut the wrong place and the patient crashes; cut a place that has since been removed (inlined or renamed) and the pager is simply never called.

## How It Works

When `register_kprobe()` is called with a target address, the kprobe machinery first validates the address is probe-able (not in the kprobes implementation itself, not in certain critical sections marked with `NOKPROBE_SYMBOL`). It then copies the instruction(s) at that address to a per-kprobe `ainsn` buffer (the out-of-line copy). On x86, because instructions are variable-length, the machinery copies enough bytes to complete at least one full instruction. It then overwrites the first byte at the target address with `0xCC` (INT3).

When execution reaches the INT3, the CPU takes a breakpoint trap, saving full register state. The trap handler identifies the kprobe by looking up the faulting IP in the kprobe hash table, then calls the registered `pre_handler` with a pointer to the `kprobe` struct and the saved `pt_regs`. The pre-handler runs in the same context as the probed code (with preemption and possibly interrupts disabled).

After the pre-handler, the machinery arranges to single-step the original instruction. It does this by copying the saved instruction to a per-CPU trampoline buffer, setting the TF (trap flag) in EFLAGS, then returning from the trap with the instruction pointer set to the trampoline. The CPU executes the original instruction with all its side effects (register modifications, memory writes), then raises a debug trap because TF is set. The debug trap handler calls the optional `post_handler`, then restores TF, restores the IP to `probe_address + instruction_length`, and resumes normal execution. The INT3 is still in place, so the next call to the same function hits it again.

With `CONFIG_OPTPROBES=y`, once a kprobe has been hit a threshold number of times, the machinery attempts to optimise it: if the probe region is within one function, no control flow jumps into the middle of it, and the instructions are safe to execute out-of-line, the INT3 is replaced with a 5-byte `JMP` (direct jump to the out-of-line trampoline). This eliminates the breakpoint trap overhead (~0.5–1.0 µs → ~0.07–0.1 µs per hit) but takes a moment to apply.

**kretprobes** capture function returns without placing a probe at every `ret` instruction. Instead, a kprobe is installed at the function entry point. On entry, the entry kprobe handler saves the current return address from the stack and replaces it with the address of a per-architecture trampoline. When the function executes `ret`, the CPU jumps to the trampoline instead of the original return address. The trampoline calls the registered `return_handler` with the saved return value (in `pt_regs`), then jumps to the saved return address to resume normal execution. The `maxactive` field in `kretprobe` pre-allocates `kretprobe_instance` objects — one per concurrent execution of the probed function — so that recursive or multi-CPU invocations each get their own saved return address without contention.

The key limitation of kprobes is **compiler opacity**. If `tcp_sendmsg` is inlined by the compiler, there is no standalone `tcp_sendmsg` symbol to probe; only the out-of-line version (if any) is visible. If the function is renamed between kernel builds, the probe silently does nothing (address lookup returns nothing or hits the wrong function). These are not bugs — they are intentional non-guarantees that keep compiler and kernel developers free to optimise aggressively. Production monitoring that needs stability should use tracepoints; kprobes are for ad-hoc debugging.

Since Linux 5.0, `fprobe` wraps kprobes with a name-based interface: you register by function name rather than address, and fprobe resolves the name at registration time, attaches an optimised hook via the ftrace path (not INT3), and provides a handler with `pt_regs`. fprobe is the preferred substrate for new BPF `kprobe` programs because it uses ftrace's direct-call mechanism rather than the INT3 trap path.

## Key Data Structures

**`struct kprobe`** (`include/linux/kprobes.h`) — one instance per registered probe.
- `addr` — the exact kernel virtual address being probed; set by the caller or derived from a symbol name via `kallsyms_lookup_name()`
- `symbol_name` — optional: caller specifies a symbol name; the kprobe layer resolves it to `addr` at registration time
- `pre_handler` — called before the probed instruction; receives `(kprobe*, pt_regs*)`; may modify registers to alter execution
- `post_handler` — called after single-step completes; optional; receives register state after the instruction
- `ainsn` — `arch_specific_insn` containing the saved original instruction bytes and out-of-line execution copy

**`struct kretprobe`** (`include/linux/kprobes.h`) — extends kprobe for function-return capture.
- `handler` — called when the probed function returns; `pt_regs` reflects the state at the `ret` instruction
- `entry_handler` — called at function entry; can store per-invocation data in the `kretprobe_instance`
- `data_size` — bytes of per-invocation private storage in each `kretprobe_instance`
- `maxactive` — pre-allocated instance pool size; if all instances are in use, new invocations are silently skipped

**`struct kretprobe_instance`** (`include/linux/kprobes.h`) — per-active-invocation state.
- `ret_addr` — the saved real return address; restored when the trampoline fires
- `data[]` — per-invocation private storage (size = `kretprobe.data_size`)

## Key Functions / Entry Points

**`register_kprobe()`** (`kernel/kprobes.c`) — validates the target address, copies the instruction out-of-line, patches INT3, adds to the global hash table.

**`unregister_kprobe()`** (`kernel/kprobes.c`) — restores the original instruction, waits for in-flight handlers to complete (via RCU), removes from hash table.

**`register_kretprobe()`** / **`unregister_kretprobe()`** (`kernel/kprobes.c`) — manage the kretprobe; the underlying entry kprobe is registered automatically.

**`kprobe_int3_handler()`** (arch/x86/kernel/kprobes/core.c) — the x86 INT3 trap handler entry point; looks up the kprobe from the faulting IP and dispatches to pre_handler.

**`kprobe_debug_handler()`** — the TF debug trap handler; calls post_handler and resumes normal execution after single-step.

## Important Flags & Config Options

- `CONFIG_KPROBES` — master Kconfig for kprobe/kretprobe support
- `CONFIG_OPTPROBES` — enables jump-optimisation (INT3 → direct JMP after warmup); reduces per-hit overhead ~10×
- `CONFIG_KRETPROBES` — kretprobe support (usually selected with CONFIG_KPROBES)
- `CONFIG_KPROBE_EVENTS` — exposes kprobes to tracefs via the `kprobe_events` file; syntax: `p:label func+offset %reg`; the traced kprobe writes structured events to the ring buffer like any tracepoint
- `NOKPROBE_SYMBOL(func)` — annotation in kernel source marking a function as un-probeable (prevents recursion into kprobe machinery itself)

## Interactions with Other Subsystems

- **↑ Userspace**: `kprobe_events` tracefs file; `perf probe` command adds kprobes via perf's ABI; BPF `bpf_attach_kprobe()` / `BPF_PROG_TYPE_KPROBE`
- **→ Ring Buffer**: when kprobe events are enabled via tracefs, each kprobe hit writes a structured record to the ring buffer using the standard event tracing path
- **→ ftrace**: `fprobe` (since 5.0) uses ftrace's dynamic patching instead of INT3; BPF `fentry`/`fexit` (since 5.5) takes this further with per-ops trampolines
- **← BPF**: BPF programs are the most common modern consumer; they attach to kprobes to run in-kernel aggregation logic that would be too expensive to export to userspace event-by-event

## Design Decisions & Tradeoffs

**INT3 over compile-time instrumentation** — INT3 can attach to any running kernel without recompilation but costs a trap (~0.5–1 µs). Compile-time instrumentation (like ftrace's NOP patching) costs nothing when inactive but requires the kernel to have been compiled with it. kprobes fill the gap: they can reach code that was never compiled with `-pg` or that lacks tracepoints.

**Deliberate fragility** — The kprobe ABI guarantees *nothing* about which addresses will continue to exist across kernel versions. This is intentional: it lets compiler and kernel developers inline, rename, and reorganise freely. Tools that need stability should use tracepoints; kprobes are the power tool with no safety guard.

**`maxactive` pre-allocation** — Dynamic allocation of kretprobe instances at probe-hit time would be fine in most cases but fails under heavy recursion or high concurrency with allocation limits. Pre-allocation via `maxactive` trades memory for predictability: the cost of missing instances under extreme concurrency is silently dropped probes (counted in `kretprobe.nmissed`), which is preferable to allocation failures in interrupt context.

## How It Has Evolved

- **2.6.9 (2004)** — kprobes first merged; INT3-based for x86
- **2.6.16 (2006)** — kretprobes added (return address hijacking mechanism)
- **2.6.26 (2008)** — Jump optimisation (`CONFIG_OPTPROBES`) reduces hit overhead ~10×
- **3.x** — `kprobe_events` in tracefs: kprobes exposed as structured trace events readable via ring buffer
- **5.0 (2019)** — `fprobe` API: name-based attachment using ftrace infrastructure; lower overhead than INT3
- **5.5 (2020)** — BPF `fentry`/`fexit` uses ftrace trampolines; kprobe-backed BPF begins migrating to fprobe

## Further Reading

1. [Kernel Probes (Kprobes) — kernel.org](https://www.kernel.org/doc/html/latest/trace/kprobes.html) — authoritative design and API documentation
2. [Dynamic probes with ftrace (LWN, 2009)](https://lwn.net/Articles/343766/) — kprobe integration with ftrace infrastructure
3. [Kernel analysis with bpftrace (LWN, 2019)](https://lwn.net/Articles/793749/) — practical kprobe usage through bpftrace

## LKML Highlights

- **kprobes initial merge (2004)** — Reviewed for correctness of the INT3 + single-step sequence on SMP; discussion centred on ensuring the patch was atomic with respect to concurrent execution on other CPUs.
