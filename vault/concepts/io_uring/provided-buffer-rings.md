---
title: "io_uring Provided Buffer Rings"
category: concept
tags: [io_uring, provided-buffers, buffer-selection, networking, memory]
subsystem: io_uring
kernel_version: "5.7"
researched: 2026-09-24
status: complete
sources:
  - https://kernel-internals.org/io-uring/fixed-buffers/
  - https://kernel-internals.org/io-uring/networking/
  - https://kernel-internals.org/io-uring/multishot-ops/
  - https://github.com/axboe/liburing/wiki/What's-new-with-io_uring-in-6.11-and-6.12
  - https://man.archlinux.org/man/extra/liburing/io_uring_provided_buffers.7.en
  - https://www.spinics.net/lists/io-uring/msg24644.html
  - https://lwn.net/Articles/1051215/
---

# io_uring Provided Buffer Rings

## Purpose

A readiness-based server (epoll) allocates a receive buffer only when a socket is readable. A completion-based API like io_uring normally needs the buffer *at submission*, so a server with 100,000 mostly idle connections would have 100,000 buffers tied up in pending `recv`s. Provided buffers fix this. The application hands the kernel a pool of buffers up front, and the kernel picks one only when data actually arrives. Memory use then scales with *active* traffic instead of connection count. This mechanism is also what makes multishot receive possible.

## Mental Model

A provided buffer ring is a **shared tray of empty cups**. The application keeps refilling the tray at one end (the tail). When a request finally needs a cup (data arrived), the kernel takes the next one from the other end (the head) and tells the application in the completion which cup it filled (the buffer id). Cups are grouped by size or purpose (buffer group id), and each request says which tray to draw from.

## How It Works

**The legacy scheme (5.7).** The first design, `IORING_OP_PROVIDE_BUFFERS`, was itself an SQE: it handed the kernel a contiguous range split into N buffers with consecutive ids, and the kernel stored each one as a `struct io_buffer` on a linked list. It worked, but replenishing buffers meant submitting more SQEs, and every selection took list locks. It is still supported but discouraged.

**Registering a ring (5.19).** The modern design is a shared-memory ring. Userspace allocates an array of `struct io_uring_buf { __u64 addr; __u32 len; __u16 bid; __u16 resv; }` entries (a power-of-two count) and calls `io_uring_register(IORING_REGISTER_PBUF_RING)` with a `struct io_uring_buf_reg` naming the ring address, entry count and **buffer group id** (`bgid`). The ring header `struct io_uring_buf_ring` overlays the first entry. Its 16-bit `tail` sits in the `resv` field of entry 0, so the structure has no separate header and entries stay naturally aligned. `io_register_pbuf_ring()` pins or maps the ring, creates a `struct io_buffer_list` for the group, and stores it in the ring's `ctx->io_bl_xa` xarray keyed by `bgid`. With `IOU_PBUF_RING_MMAP` (6.4), the kernel allocates the ring memory and userspace `mmap`s it at an offset derived from the bgid. That avoids pinning user memory and works under `IORING_SETUP_NO_MMAP` restrictions.

**Providing buffers.** To add buffers, userspace writes entries at `tail & mask` and publishes them with a release store to `tail` (liburing: `io_uring_buf_ring_add()` then `io_uring_buf_ring_advance()`). No syscall is involved. The kernel keeps its own private `head` in the `io_buffer_list`, so the only shared mutable word is `tail`. The ring is single-producer (userspace) and single-consumer (kernel).

**Selecting a buffer.** A request with `IOSQE_BUFFER_SELECT` and `sqe->buf_group = bgid` has no buffer at submission. When the opcode handler is ready to transfer data, for example `io_recv()` after the socket became readable, it calls `io_buffer_select()`. That looks up the list and calls `io_ring_buffer_select()`, which acquire-reads `tail`, compares it to `head`, and takes the entry at `head & mask`. The request records the chosen buffer and sets `REQ_F_BUFFER_RING`. The ring head is committed at completion. On success the CQE carries `IORING_CQE_F_BUFFER`, and the buffer id sits in the upper 16 bits of `cqe->flags` (`>> IORING_CQE_BUFFER_SHIFT`). The application processes the data and eventually puts that buffer back on the ring.

**Recycling on retry.** A selected buffer might not get used. The receive can find no data after all and return `-EAGAIN`, then go back to waiting on poll. Holding the buffer while waiting would defeat the whole point, so `io_kbuf_recycle()` returns it. For ring buffers that just means not advancing `head` (the buffer was never committed), so the next selection picks the same entry again.

**Running dry.** If `head == tail` when selection is attempted, the request completes with `-ENOBUFS`. For a multishot recv this is a terminating CQE (no `IORING_CQE_F_MORE`). The application must refill the ring and re-arm. This is deliberate backpressure: the kernel won't queue unbounded data on the application's behalf. `IORING_REGISTER_PBUF_STATUS` (6.8) lets userspace read the kernel's current `head` to see how far consumption has progressed.

**Bundles (6.10).** With small buffers, a busy socket might need several buffers for one receive. `IORING_RECVSEND_BUNDLE` lets a single `recv` take a *run* of consecutive ring buffers via `io_buffers_select()`/`io_buffers_peek()`. It fills them in order, and one CQE reports the starting bid and total byte count. The application walks forward from that bid. The same flag on `send` lets one SQE transmit a sequence of provided buffers, which is useful for send queues managed as rings.

**Incremental consumption (6.12).** Bundles solve "buffers too small". `IOU_PBUF_RING_INC` solves the opposite, where buffers are big (say 64 KiB) but messages are small. With this flag a buffer isn't retired after one use. The kernel advances an internal offset inside it and hands out the remainder on the next selection. Several CQEs can reference the same bid, and `IORING_CQE_F_BUF_MORE` tells the application the kernel still owns the rest of that buffer. Memory utilisation improves a lot, and applications can register fewer, larger buffers.

**Kernel-managed rings (2026).** Patches from Joanne Koong for FUSE-over-io_uring add rings whose buffers are allocated and owned by the kernel. That enables zero-copy between the FUSE server and the page cache without user-registered memory. As of this writing it is posted as a series and not yet confirmed merged.

## Key Data Structures

**`struct io_buffer_list`** (`io_uring/kbuf.h`) — one buffer group.
- `buf_ring` / `buf_list` — the shared ring (ring mode) or the legacy list
- `bgid` — group id
- `head`, `mask`, `nr_entries` — kernel-side consumer state
- `flags` — `IOBL_BUF_RING`, `IOBL_INC`
- `region` — backing memory when kernel-allocated

**`struct io_uring_buf_ring` / `struct io_uring_buf`** (`include/uapi/linux/io_uring.h`) — the shared ring and its entries (`addr`, `len`, `bid`).

**`struct io_uring_buf_reg`** — registration argument: `ring_addr`, `ring_entries`, `bgid`, `flags`.

**`struct io_buffer`** — legacy provided buffer (list node, `addr`, `len`, `bid`).

## Key Functions / Entry Points

**`io_register_pbuf_ring()` / `io_unregister_pbuf_ring()`** (`io_uring/kbuf.c`) — register/unregister a ring group.

**`io_buffer_select()`** — select one buffer for a request (ring or legacy).

**`io_buffers_select()` / `io_buffers_peek()`** — select a bundle of buffers.

**`io_kbuf_recycle()`** — give an uncommitted buffer back after `-EAGAIN`.

**`io_put_kbuf()` / `io_put_kbufs()`** — commit consumption and compute the CQE buffer flags at completion.

**`io_provide_buffers()`** — legacy `IORING_OP_PROVIDE_BUFFERS` handler.

## Important Flags & Config Options

- **`IOSQE_BUFFER_SELECT`** + `sqe->buf_group` — request kernel buffer selection.
- **`IORING_REGISTER_PBUF_RING` / `IORING_UNREGISTER_PBUF_RING`** (5.19).
- **`IOU_PBUF_RING_MMAP`** (6.4) — kernel-allocated ring memory.
- **`IOU_PBUF_RING_INC`** (6.12) — incremental consumption; CQE flag `IORING_CQE_F_BUF_MORE`.
- **`IORING_RECVSEND_BUNDLE`** (6.10) — multi-buffer recv/send.
- **`IORING_REGISTER_PBUF_STATUS`** (6.8) — query kernel head.
- **CQE flags** — `IORING_CQE_F_BUFFER`, bid in `flags >> IORING_CQE_BUFFER_SHIFT`.

## Interactions with Other Subsystems

- **↑ Userspace**: liburing `io_uring_setup_buf_ring()`, `io_uring_buf_ring_add()`, `io_uring_buf_ring_advance()`, `io_uring_prep_recv_multishot()`.
- **→ [[net]]**: recv/recvmsg handlers select buffers only after the socket reports data. Bundles size the `iov_iter` from several ring entries.
- **→ [[vfs]]**: reads on pipes and other streaming files can also use buffer selection, as can multishot read (6.7).
- **← [[io-uring-async-poll-and-multishot]]**: multishot recv *requires* provided buffers, since one SQE produces many completions and each needs its own buffer.
- **← [[fuse]]**: FUSE-over-io_uring uses buffer rings for request payloads and is driving kernel-managed rings.

## Design Decisions & Tradeoffs

**Late binding of buffers.** Choosing the buffer at data-arrival time makes memory proportional to throughput rather than connections. The cost is that the application must keep the ring stocked, and running dry terminates multishot requests.

**Shared ring instead of SQEs (5.19).** Replenishing via `PROVIDE_BUFFERS` SQEs cost a submission per refill and took locks during selection. The ring design needs no syscall and no lock (under `uring_lock` the kernel is the only consumer), at the cost of a trickier ABI where the tail overlays entry 0's reserved field.

**Commit at completion, not selection.** Delaying the head advance until completion makes recycling trivial and avoids leaking buffers on retries. It also means a buffer is only "consumed" when a CQE says so, which keeps the contract simple.

**Incremental and bundle modes as opt-ins.** The two answer opposite problems (buffers too big vs. too small). Both are flags, so existing ring users see no behaviour change.

## How It Has Evolved

- **5.7** — `IORING_OP_PROVIDE_BUFFERS` / `REMOVE_BUFFERS` (list-based).
- **5.19** — ring-mapped provided buffers (`IORING_REGISTER_PBUF_RING`), in time for multishot accept/recv.
- **6.0** — multishot recv built on buffer rings.
- **6.4** — `IOU_PBUF_RING_MMAP`.
- **6.7** — multishot read uses buffer selection.
- **6.8** — `IORING_REGISTER_PBUF_STATUS`.
- **6.10** — recv/send bundles.
- **6.12** — incremental consumption (`IOU_PBUF_RING_INC`).
- **2026 (posted)** — kernel-managed buffer rings for FUSE zero-copy.

## Further Reading

1. [`io_uring_provided_buffers(7)`](https://man.archlinux.org/man/extra/liburing/io_uring_provided_buffers.7.en) — the authoritative overview.
2. [kernel-internals.org — Fixed buffers and buffer rings](https://kernel-internals.org/io-uring/fixed-buffers/)
3. [kernel-internals.org — Networking with io_uring](https://kernel-internals.org/io-uring/networking/)
4. [liburing wiki — What's new in 6.11 and 6.12](https://github.com/axboe/liburing/wiki/What's-new-with-io_uring-in-6.11-and-6.12)
5. [Add support for incremental buffer consumption — patchset v4](https://www.spinics.net/lists/io-uring/msg24644.html)
6. [fuse/io-uring: add kernel-managed buffer rings and zero-copy — patch posting](https://lwn.net/Articles/1051215/)

## LKML Highlights

> lore.kernel.org was unreachable from this run; these are drawn from list mirrors.

- **"Add support for incremental buffer consumption" (Jens Axboe, v4, 2024)** — argues that fixed-size buffers force a bad choice between waste and exhaustion. It lets the kernel carve a large buffer across many completions, flagged with `IORING_CQE_F_BUF_MORE`.
- **`<20251218083319.3485503-1-joannelkoong@gmail.com>`** — Joanne Koong's "fuse/io-uring: add kernel-managed buffer rings and zero-copy" (Dec 2025, 25 patches). It adds a buffer type provided and managed by the kernel rather than userspace, and reports roughly 20–25% higher buffered-read throughput for FUSE servers.
