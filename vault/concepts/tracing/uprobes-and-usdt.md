---
title: "uprobes and USDT"
category: concept
tags: [tracing, uprobes, usdt, userspace-tracing, breakpoints, bpf]
subsystem: tracing
kernel_version: "3.5"
researched: 2026-04-17
status: complete
sources:
  - https://kernel-internals.org/tracing/kprobes-tracepoints/
  - https://www.kernel.org/doc/html/latest/trace/tracepoints.html
  - https://static.lwn.net/kerneldoc/trace/uprobetracer.html
  - https://lwn.net/Articles/793749/
---

# uprobes and USDT

## Purpose

kprobes instrument the kernel; uprobes bring the same INT3-based dynamic instrumentation to userspace binaries without requiring source modification, ptrace attachment, or application restarts. USDT (User Statically Defined Tracepoints) extends this by letting application developers place stable, named probe markers in their binaries that tools can attach to by name rather than by fragile file offsets.

## Mental Model

Think of uprobes as a **library card system for userspace code**. A kprobe puts an INT3 directly into kernel memory, which the kernel owns outright. Userspace pages are shared across many processes via copy-on-write mappings. When you register a uprobe, the kernel applies the INT3 to a CoW clone of the affected page — every process that has the file mapped sees the probe simultaneously, but their private data pages remain unaffected. When the probe fires, the kernel is notified just as with kprobes, but the context is user process execution rather than kernel execution. USDT adds an index in the ELF binary — like an annotated table of contents — so that tools can say "attach to the `connection_established` probe in `nginx`" rather than calculating a raw file offset.

## How It Works

A uprobe is identified by an (inode, file-offset) pair rather than a kernel virtual address. This inode-based identity means the probe is independent of any particular process — it fires for *all* processes that map the probed binary, including processes that start after the probe is registered.

**Registration**: `uprobe_register(inode, offset, consumer)` walks all existing page-table mappings of the target (inode, offset). For each mapping, if the page is currently resident in memory, the kernel performs a copy-on-write clone (creating a private copy of the page for that mapping's mm) and patches `0xCC` (INT3) at the target offset within the cloned page. Processes that share the original page continue executing the unmodified original; they get the patched page on their next fault into that address. Future `mmap()` calls that map the same binary also receive the patched page transparently.

**Trap handling**: When a user process executes the INT3, the CPU takes a breakpoint exception. The fault handler checks whether this is a known uprobe location (by looking up the inode + page-offset in the uprobe hash). If it is a uprobe, the handler saves the thread's `pt_regs`, calls each registered consumer's handler in turn (BPF program, trace consumer, etc.), then arranges to single-step the original instruction. The single-step uses a per-thread trampoline page mapped into the process's address space: the saved original bytes are placed in the trampoline, TF is set, and execution resumes there. After single-stepping, a debug trap fires, the trampoline page is no longer needed for this invocation, and execution continues at the correct post-instruction address.

**Overhead model**: When the probe fires, all overhead is paid as a user-space trap (similar to a SIGTRAP signal delivery): the cost is a mode switch, `pt_regs` save, the handler, and a mode switch back. This is substantially more expensive than a kernel kprobe hit (no mode switch), but still far cheaper than ptrace-based approaches (which require a separate debug process and IPC round-trips).

**USDT** markers are placed by developers using `DTRACE_PROBE` or `STAP_PROBE` macros (or their equivalents in libstapsdt, libbpf's USDT support, or systemtap). These compile to: a `nop` instruction at the probe site, and an ELF note in the `.probes` section recording the probe name, provider, and argument types/locations. Because the marker is a NOP at runtime, an unprobed USDT application has zero tracing overhead — not even a conditional branch.

When bpftrace, perf, or trace-cmd attaches to a USDT probe, it: (1) reads the ELF `.probes` section via `libelf`; (2) resolves the named probe to a file offset; (3) calls `uprobe_register()` at that offset; (4) patches the NOP to INT3 via the CoW mechanism described above. This means the binary ships ready to be traced: the table of contents is baked in at build time, and tracing tools just look it up.

Since Linux 4.7, BPF programs can attach to uprobes (and thus USDT probes), gaining access to all the same BPF map and helper infrastructure available on kprobes. A bpftrace one-liner like `uprobe:/usr/bin/nginx:ngx_http_request_handler { @latency = hist(elapsed); }` uses exactly this path.

## Key Data Structures

**`struct uprobe`** (`kernel/events/uprobes.c`) — per-(inode, offset) probe descriptor; shared across all processes mapping the binary.
- `inode` — the filesystem inode of the probed binary
- `offset` — byte offset within the file at which INT3 is placed
- `consumers` — list of `uprobe_consumer` structs, one per attached tool; called in sequence on each hit
- `arch_uprobe.insn[]` — saved original bytes from the probe site (enough for one full instruction)

**`struct uprobe_consumer`** (`include/linux/uprobes.h`) — registered handler; one per tool (BPF, trace, etc.).
- `handler` — function called on each probe hit; receives task and `pt_regs`
- `ret_handler` — optional: called when the probed function returns (like kretprobe)
- `filter` — optional: per-mm filter; allows limiting which processes trigger the probe

**`struct xol_area`** (`kernel/events/uprobes.c`) — per-mm "execute-out-of-line" trampoline area; a special MAP_SHARED region in the process's address space used for single-stepping the displaced instruction.

## Key Functions / Entry Points

**`uprobe_register()`** (`kernel/events/uprobes.c`) — registers a consumer; inserts an uprobe into the global inode-keyed tree; applies INT3 patches to all existing mappings via CoW.

**`uprobe_unregister()`** (`kernel/events/uprobes.c`) — removes a consumer; when the last consumer is removed, restores the original instruction in all mappings.

**`handle_swbp()`** (`arch/x86/kernel/uprobes.c`) — the x86 INT3 fault handler for user-space breakpoints; identifies the uprobe, calls consumers, sets up out-of-line single-step.

**`handle_trampoline()`** (`kernel/events/uprobes.c`) — called after out-of-line single-step completes (via debug trap); restores normal execution and calls `ret_handler` if set.

## Important Flags & Config Options

- `CONFIG_UPROBES` — master Kconfig for uprobe support
- `CONFIG_UPROBE_EVENTS` — exposes uprobes to tracefs via `uprobe_events` file; syntax: `p:<label> /path/to/binary:0xoffset`
- `uprobe_events` (tracefs) — control file for registering uprobes as structured ring-buffer events, readable like any tracepoint
- `events/uprobes/<EVENT>/enable` (tracefs) — enable/disable a registered uprobe event

## Interactions with Other Subsystems

- **↑ Userspace**: `perf probe -x /binary func` adds uprobes via the perf interface; bpftrace `uprobe:` / `usdt:` probes use uprobe_register via libbpf; tracefs `uprobe_events` file for direct kernel interface
- **→ Memory Management**: uprobe page patching uses CoW (`break_cow()`) to create private copies of pages before patching, so the original shared page is never modified
- **→ Ring Buffer**: when uprobe events are enabled via tracefs, each hit writes a structured record to the ring buffer
- **← BPF**: BPF `BPF_PROG_TYPE_KPROBE` programs can attach to uprobes (the type name is historical); BPF programs access argument values via `bpf_probe_read_user()`

## Design Decisions & Tradeoffs

**Inode-based identity over address-based** — kprobes use virtual addresses; uprobes use (inode, offset) because the same binary may be mapped at different virtual addresses in different processes (ASLR), and the same physical page may be shared. Inode-based identity ensures a single probe registration covers all processes running the same binary simultaneously.

**CoW patching over per-process patching** — An alternative would be to patch each process's page independently. CoW patching is more efficient: the patched page is shared among all mapped processes (until any of them writes to it and gets their own private copy), so the INT3 is installed once and takes effect everywhere. The tradeoff is that unprobed processes that happen to have a write-fault in the same page will get their own copy automatically, which is the normal CoW semantics.

**USDT NOP size matches INT3 size** — On x86, both NOP and INT3 are 1 byte. USDT markers compile to a 1-byte NOP specifically so that patching to INT3 requires touching exactly one byte, making the transition atomic without any of the multi-byte `text_poke_bp()` complexity used in ftrace.

## How It Has Evolved

- **3.5 (2012)** — uprobes merged; basic INT3 patching with CoW for x86
- **3.10** — `uprobe_events` in tracefs: uprobes exposed as structured trace events
- **4.7 (2016)** — BPF `BPF_PROG_TYPE_KPROBE` programs can attach to uprobes; USDT probes addressable via BPF
- **4.8+** — `ret_handler` support in `uprobe_consumer` (return probes for userspace)
- **5.17+ / 6.x** — libbpf USDT support (`bpf_usdt_arg()` helpers); BPF programs can read USDT argument values without manual offset calculations

## Further Reading

1. [Uprobe-tracer: Uprobe-based Event Tracing (kernel.org)](https://static.lwn.net/kerneldoc/trace/uprobetracer.html) — tracefs uprobe_events syntax and examples
2. [Kernel analysis with bpftrace (LWN, 2019)](https://lwn.net/Articles/793749/) — practical USDT + bpftrace patterns
3. [Using the Linux Kernel Tracepoints (kernel.org)](https://www.kernel.org/doc/html/latest/trace/tracepoints.html) — complementary reading on static tracepoints (kernel-side analogue)

## LKML Highlights

- **uprobe merge thread (2012)** — Debate focused on the CoW page cloning strategy and whether per-process patching would be more efficient; the single-probe-covers-all-processes model was accepted as the right default since most users probe system-wide workloads.
