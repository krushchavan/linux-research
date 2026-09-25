---
title: "tracefs and the Ring Buffer"
category: concept
tags: [tracing, ring-buffer, tracefs, lockless, per-cpu]
subsystem: tracing
kernel_version: "2.6.27"
researched: 2026-04-17
status: complete
explained: "[[tracefs-and-ring-buffer-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/trace/ring-buffer-design.html
  - https://www.kernel.org/doc/html/latest/trace/ftrace.html
  - https://lwn.net/Articles/340400/
  - https://kernel-internals.org/tracing/ftrace/
---

# tracefs and the Ring Buffer

> 📘 Plain-language version: [[tracefs-and-ring-buffer-explained]]

## Purpose

The tracing subsystem needs a place to store events produced at interrupt and NMI rate without introducing lock contention that would distort the very behaviour being observed. The lockless per-CPU ring buffer solves the data-plane problem: writes are atomic via `cmpxchg` and never block. tracefs solves the control-plane problem: it exposes all knobs and output files through the VFS, making the tracing framework fully controllable from a shell without a separate daemon.

## Mental Model

Think of tracefs as a **switchboard** and the ring buffer as a **ticker tape machine**. The switchboard (tracefs) has levers for selecting which tracer is active, which functions to watch, which events to enable, and which processes to filter. The ticker tape machine (ring buffer) runs independently — each CPU has its own continuous roll of tape, and writers just stamp the next position on their local roll without waiting for anyone else. Readers tear off a completed section of tape when they want to read, without stopping the machine.

## How It Works

At boot, `tracefs_init()` registers the `tracefs` filesystem type. When mounted (typically at `/sys/kernel/tracing`, or automounted under `/sys/kernel/debug/tracing` for backward compatibility with debugfs), it creates a tree of pseudo-files whose `read` and `write` operations directly manipulate tracing state. Important control files include: `current_tracer` (select the active plugin — `nop`, `function`, `function_graph`, `irqsoff`, etc.), `tracing_on` (binary gate that stops ring-buffer writes without removing instrumentation — useful for arming probes and firing later), `set_ftrace_filter` (a glob-based allowlist of functions to trace), and `trace_options` (a text interface to dozens of per-tracer flags). Under the `events/` subdirectory, one directory tree per subsystem exposes each tracepoint's `enable`, `filter`, and `trigger` files. The `instances/` directory allows creating independent trace instances, each with their own ring buffer and current_tracer setting, so concurrent tools cannot interfere with each other.

The ring buffer is the data highway beneath all of this. It is fundamentally per-CPU: each CPU has its own `ring_buffer_per_cpu`, a doubly-linked list of page-sized sub-buffers. This eliminates any cross-CPU coordination during writes. Each sub-buffer carries a commit timestamp so events can be placed in global order offline even though each CPU writes independently.

Writers enter through `ring_buffer_lock_reserve()`, which grabs space in the current tail page for one event. Because interrupts and NMIs can preempt an in-progress write on the same CPU, the design uses a stack discipline: nested writers (interrupt preempting normal context, NMI preempting interrupt) each get their own region, and the outer write cannot commit until all inner writes have completed. The actual cursor advance uses `cmpxchg` — the writer speculatively computes the new tail, then attempts to install it atomically; if another nested writer beat it, the cmpxchg fails and the writer retries. Once space is reserved, the event data is written directly into the ring buffer page. `ring_buffer_unlock_commit()` then advances `commit_page` only if no nested write is still in progress, maintaining the invariant that readers never see a partial event.

On the read side, a reader swaps its private scratch page with the ring buffer's `head_page` using a second `cmpxchg`. This swap is the only point of reader/writer coordination and is lock-free. After the swap, the reader owns that page exclusively and can parse it at leisure without holding any lock.

The `overwrite` option (controlled via tracefs) determines what happens when all sub-buffers are full. In the default overwrite mode, the oldest sub-buffer is recycled and its events are lost — this keeps the newest data and avoids blocking writers. With overwrite disabled, new events are dropped when the buffer is full — useful when the oldest events are more important (e.g. catching the root cause of a bug before the buffer fills with consequences).

Trace instances (`instances/` directory) create a completely independent `ring_buffer` and tracer state. This lets `trace-cmd` run a system-wide function trace while a developer runs an event trace in a separate instance; neither sees the other's events and neither's `current_tracer` setting interferes with the other.

## Key Data Structures

**`struct ring_buffer_per_cpu`** (`kernel/trace/ring_buffer.c`) — per-CPU ring buffer state; one instance per CPU per trace instance.
- `tail_page` — pointer to the page currently being written; advanced atomically by `cmpxchg`
- `commit_page` — the last fully committed page; readers consume up to here
- `head_page` — next page available for reader consumption; swapped out atomically
- `reader_page` — the consumer's private page, swapped in exchange for `head_page`
- `entries` — total committed event count (used for statistics)
- `overrun` — count of events dropped due to buffer-full condition

**`struct ring_buffer_event`** (`include/linux/ring_buffer.h`) — fixed-size header preceding each event's data in the buffer.
- `type_len` — encodes the event type (data, time-extend, padding) and data length in 5 bits; events ≤ 28 bytes fit without a separate length field
- `time_delta` — nanoseconds since the last timestamp; full 64-bit timestamps are emitted when the delta overflows

## Key Functions / Entry Points

**`ring_buffer_lock_reserve()`** (`kernel/trace/ring_buffer.c`) — called by every event producer; reserves `length` bytes in the tail page. Returns a pointer to the reserved region or NULL if dropped.

**`ring_buffer_unlock_commit()`** (`kernel/trace/ring_buffer.c`) — called after writing event data; commits the event and advances `commit_page` if no nested writes are pending.

**`ring_buffer_consume()`** (`kernel/trace/ring_buffer.c`) — reads and removes one event from the head page; called by `trace_pipe` readers in streaming mode.

**`ring_buffer_read_prepare()`** / **`ring_buffer_read_start()`** / **`ring_buffer_read()`** — the three-phase snapshot read path used by `trace` (non-consuming reads).

**`tracefs_create_file()`** (`fs/tracefs/inode.c`) — helper used throughout `kernel/trace/` to register control files with their `fops`.

## Important Flags & Config Options

- `CONFIG_TRACING` — master Kconfig switch; enables tracefs and the ring buffer infrastructure
- `CONFIG_RING_BUFFER` — the ring buffer library itself; selected by CONFIG_TRACING
- `buffer_size_kb` (tracefs file) — sets the per-CPU ring buffer size in kilobytes; default is 7 KB, typically tuned up to megabytes for production traces
- `buffer_subbuf_size_kb` — sets the size of individual sub-buffers; events cannot exceed this size; default is architecture page size
- `overwrite` (tracefs option) — `1` = overwrite oldest events when full (default); `0` = drop new events when full
- `tracing_on` (tracefs file) — `0` disables writes to the ring buffer without unregistering probes; `1` re-enables them

## Interactions with Other Subsystems

- **↑ Userspace**: shell tools read/write tracefs pseudo-files directly; `trace-cmd` uses `ioctl(BUFFER_GET_CPU_STATS)` and `read(trace_pipe_raw)` for high-performance bulk reads; `libftrace` wraps the tracefs API for library consumers
- **→ ftrace**: ftrace function callbacks call `ring_buffer_lock_reserve()` to deposit function events
- **→ Tracepoints**: the `TRACE_EVENT` output function calls `ring_buffer_lock_reserve()` + `ring_buffer_unlock_commit()` to write structured events
- **→ kprobes/uprobes**: kprobe event handlers write to the same ring buffer via the event tracing layer
- **← All consumers**: `trace_pipe` readers, `trace` snapshot readers, and BPF `bpf_trace_printk()` all drain from the same per-CPU buffers

## Design Decisions & Tradeoffs

**Per-CPU over global** — A single global buffer would require a lock on every write; even a spinlock is unacceptable at NMI rate. Per-CPU buffers eliminate contention entirely. The cost is that events from different CPUs arrive out of order in timestamp; consumers must sort by `time_delta` if they care about interleaving.

**`cmpxchg` over disabling interrupts** — An earlier version of the ring buffer disabled interrupts during writes. The lockless design using `cmpxchg` allows NMI handlers to write events even while a normal-context writer is in progress, which was essential for `hwlat` and other NMI-based tracers. The algorithm's correctness was not formally proved at merge time — the community accepted the risk because the code had been heavily tested and the author (Rostedt) had high credibility.

**Sub-buffer granularity** — Sub-buffers are page-sized to align with the VM's page table granularity. This makes ring-buffer-to-mmap mapping straightforward and avoids spanning a TLB entry across a commit boundary.

## How It Has Evolved

- **2.6.27 (2008)** — Initial per-CPU ring buffer with locking (spinlock on the write path)
- **2.6.32 (2009)** — Rostedt's lockless rewrite using `cmpxchg`; NMI-safe writes become possible
- **3.x** — `instances/` directory added; independent per-instance ring buffers
- **5.x** — `buffer_mmap` work begins: exposing the ring buffer as a directly mmap-able region for zero-copy consumers
- **6.x** — `user_events` adds a mechanism for userspace to write events into the kernel ring buffer

## Further Reading

1. [A lockless ring-buffer (LWN, 2009)](https://lwn.net/Articles/340400/) — Rostedt's algorithm explained with diagrams
2. [Lockless Ring Buffer Design](https://www.kernel.org/doc/html/latest/trace/ring-buffer-design.html) — authoritative kernel documentation
3. [One ring buffer to rule them all? (LWN, 2010)](https://lwn.net/Articles/388978/) — debate about whether ftrace's ring buffer should become the generic kernel buffer

## LKML Highlights

- **`[GIT PULL][for 2.6.32] lockless ring buffer`** (lwn.net/Articles/336961/) — Rostedt's pull request; reviewers noted the algorithm's complexity "near that of RCU" and the lack of a formal proof, but accepted it based on testing evidence.
