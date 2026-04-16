---
title: "BPF Ring Buffer"
category: concept
tags: [bpf, ring-buffer, events, tracing, zero-copy, ipc]
subsystem: bpf
kernel_version: "5.8"
researched: 2026-04-16
status: complete
sources:
  - https://lwn.net/Articles/821456/
  - https://lwn.net/Articles/740157/
  - https://www.kernel.org/doc/html/latest/bpf/index.html
---

# BPF Ring Buffer

## Purpose

High-frequency tracing programs need to push events to userspace efficiently. The previous mechanism — perf buffers (`BPF_MAP_TYPE_PERF_EVENT_ARRAY`) — required one buffer per CPU, each needing its own `epoll` fd and separate read loop. This wasted memory, complicated userspace code, and forced event ordering across CPUs onto the consumer. The BPF ring buffer is a single shared FIFO that multiple CPUs can write concurrently, with the physical pages mmap-ed directly into userspace to eliminate copy-on-read.

## Mental Model

The ring buffer is a **kernel–userspace shared memory window with one-sided ownership transfer**. The kernel side (BPF program) owns the write path; the userspace consumer owns the read path. When a BPF program commits a record, it appears in the userspace mapping immediately — there is no copy, no syscall, no bounce buffer. The only synchronization on the consumer side is reading two atomic positions (`consumer_pos`, `producer_pos`) to determine where records are available.

## How It Works

The ring buffer is backed by a power-of-two-sized physically-contiguous memory region (allocated via `__get_free_pages`). Two virtual mappings exist for this region:
1. **Kernel mapping** (`vmalloc`-backed): the BPF program writes here via helper calls.
2. **Userspace mapping** (via `mmap`): read-only; the consumer reads committed records here.

A pair of 64-bit counters (`consumer_pos`, `producer_pos`) are also mmap-ed to userspace (at a separate page). The consumer advances `consumer_pos` after consuming records; the producer advances `producer_pos` after committing. This eliminates any kernel involvement on the consumer's fast path — `bpf_ringbuf_poll()` reads the positions, walks records, and calls the user callback, all entirely in userspace.

### Write path (BPF program)

A BPF program calls `bpf_ringbuf_reserve(map, size, flags)`. The verifier marks the returned pointer as `PTR_TO_RINGBUF_MEM`; writes to it are validated for bounds (must not exceed `size`). Internally, `reserve` acquires a spinlock, checks if `producer_pos - consumer_pos < ring_size` (space available), writes a `struct bpf_ringbuf_hdr` (8 bytes: `len | busy_bit | discard_bit`) at the next position, advances `producer_pos`, and releases the lock.

The BPF program then writes event data into the returned pointer. When done, it calls `bpf_ringbuf_commit(data, flags)` which clears the `busy_bit` in the header, making the record visible to the consumer. Or it calls `bpf_ringbuf_discard(data, flags)` which sets the `discard_bit`, telling the consumer to skip the record.

`flags` on commit/discard:
- `BPF_RB_NO_WAKEUP` — do not wake the consumer (caller will batch several commits before waking)
- `BPF_RB_FORCE_WAKEUP` — wake consumer unconditionally
- `0` (default) — wake consumer if it is waiting (epoll/poll)

`bpf_ringbuf_output(map, data, size, flags)` is a simpler, copy-based API: it atomically reserves, copies, and commits in one helper call, analogous to `bpf_perf_event_output`. Preferred for small events where the zero-copy advantage of `reserve/commit` is irrelevant.

### Read path (userspace)

libbpf's `bpf_ring_buffer__poll(rb, timeout_ms)` implements the consumer:
1. Read `producer_pos` atomically.
2. Walk records from `consumer_pos` to `producer_pos`, skipping `discard_bit` records, calling the user callback for each non-discarded record.
3. After processing each record, advance `consumer_pos`.

The walk is purely in userspace (mmap reads). If `consumer_pos == producer_pos` and the timeout has not elapsed, the function calls `epoll_wait()` on the ring buffer's fd, blocking until the BPF program calls `wake_up_all()` (triggered on commit with `FORCE_WAKEUP` or default flags).

### User ring buffer (reverse direction)

`BPF_MAP_TYPE_USER_RINGBUF` (5.20) inverts the roles: userspace is the producer, BPF programs are the consumer. A single userspace process writes records using `ring_buffer_user__push()`; BPF programs drain them via the kfunc `bpf_user_ringbuf_drain(map, callback, ctx, flags)`. Used for efficient configuration injection from userspace into a running BPF program — for example, pushing firewall rule updates without syscall overhead.

### Comparison with perf buffer

| | Perf buffer | Ring buffer |
|--|------------|------------|
| Instances needed | One per CPU | One total |
| epoll fds | One per CPU | One |
| Memory | `NR_CPUS × size` | `size` |
| Ordering | Per-CPU only | Global (spinlock serialize) |
| Allocation | Per-event or fixed | Reserve-commit |
| Copy | Yes (perf ioctl path) | No (mmap shared pages) |
| Min kernel | 4.x | 5.8 |

The tradeoff: the ring buffer's single spinlock is a contention point when many CPUs write simultaneously. For very high frequency events on many-CPU machines, per-CPU perf buffers may still be preferable. Most modern BPF tracing tools (bpftrace, bcc with recent kernels) default to ring buffer.

## Key Data Structures

**`struct bpf_ringbuf`** (`kernel/bpf/ringbuf.c`):
- `mask` — `size - 1` for modular arithmetic
- `consumer_pos` — `atomic64_t`; read by consumer; advanced by consumer
- `producer_pos` — `atomic64_t`; advanced by producer spinlock path
- `spinlock` — protects reservation (not consumption)
- `data[]` — circular array of `bpf_ringbuf_hdr` + payload pairs

**`struct bpf_ringbuf_hdr`** (internal, 8 bytes):
- `len` — payload length in bytes
- `pg_off` — page offset for the record
- Bit `BPF_RINGBUF_BUSY_BIT` — set during reservation, cleared on commit
- Bit `BPF_RINGBUF_DISCARD_BIT` — set by `bpf_ringbuf_discard`; consumer skips these

## Key Functions / Entry Points

**`bpf_ringbuf_reserve()`** (`kernel/bpf/ringbuf.c`) — acquires spinlock, checks space, writes header, returns pointer to payload. O(1).

**`bpf_ringbuf_commit()`** — clears `BUSY_BIT`, optionally wakes consumer.

**`bpf_ringbuf_discard()`** — sets `DISCARD_BIT`, optionally wakes consumer.

**`bpf_ringbuf_output()`** — atomic reserve + memcpy + commit in one helper.

**`bpf_ringbuf_query(map, flags)`** — returns metadata: `BPF_RB_AVAIL_DATA` (bytes ready to consume), `BPF_RB_RING_SIZE`, `BPF_RB_CONS_POS`, `BPF_RB_PROD_POS`.

**`ring_buffer__poll()`** (`tools/lib/bpf/ringbuf.c`) — userspace consumer; walks records without entering the kernel.

## Important Flags & Config Options

- `BPF_RB_NO_WAKEUP` — suppress wakeup on commit; call `bpf_ringbuf_query` + explicit wake for batched delivery.
- `BPF_RB_FORCE_WAKEUP` — always wake consumer on commit, even if not sleeping.
- Map is always `BPF_F_MMAPABLE` implicitly — userspace sees the ring via mmap.
- Size must be a power of 2 and a multiple of the page size (enforced at `BPF_MAP_CREATE`).

## Interactions with Other Subsystems

- **→ [[bpf-verifier]]**: `bpf_ringbuf_reserve()` returns `PTR_TO_RINGBUF_MEM`; the verifier tracks that the pointer must be committed or discarded on every path (otherwise the ring is permanently stuck).
- **→ [[bpf-maps]]**: The ring buffer is implemented as a map type; created via `BPF_MAP_CREATE`, managed like any other map.
- **↑ Userspace**: `mmap()` the ring buffer map fd for the shared data region; `epoll` on the fd for wakeup notification.

## Design Decisions & Tradeoffs

**Shared ring over per-CPU rings** — The memory and fd overhead of per-CPU perf buffers forced userspace code to manage N separate ring consumers. A shared ring with a single spinlock for reservation simplifies the consumer dramatically. The reservation spinlock contention is measurable but acceptable because reservations are brief (write header, advance counter) and commitment (write data, clear bit) is spinlock-free.

**Reserve-commit protocol vs. copy** — `bpf_ringbuf_reserve()` gives the BPF program a pointer into the ring buffer backing store to write directly, avoiding a memcpy. `bpf_ringbuf_output()` does a copy for programs that cannot easily use the two-phase protocol. The cost of `reserve` is that the verifier must track whether each reserved pointer is committed or discarded on all paths — adding verification complexity.

**Mmap-based consumer** — Exposing the ring buffer pages directly to userspace via read-only mmap means that on the consumer hot path there are zero syscalls. The consumer reads atomic positions and record headers from shared memory. This is the key performance advantage over perf buffers (which required `ioctl` or `read` to consume).

## How It Has Evolved

- **5.8 (2020)**: `BPF_MAP_TYPE_RINGBUF` introduced; `bpf_ringbuf_reserve/commit/discard/output/query`.
- **5.20 (2022)**: `BPF_MAP_TYPE_USER_RINGBUF` for reverse direction; `bpf_user_ringbuf_drain` kfunc.
- **7.1 (2026)**: Documentation clarification for `BPF_RB_NO_WAKEUP` semantics in `bpf_ringbuf_discard` (Eyal Birger).

## Further Reading

1. [BPF ring buffer — LWN.net (2020)](https://lwn.net/Articles/821456/)
2. [A thorough introduction to eBPF — LWN.net (2017)](https://lwn.net/Articles/740157/)
