---
title: "io_uring Internals"
category: concept
tags: [io_uring, async-io, ring-buffer, kernel-io, performance]
subsystem: io_uring
kernel_version: "5.1"
researched: 2026-04-12
status: complete
explained: "[[io-uring-internals-explained]]"
sources:
  - https://kernel-internals.org/io-uring/
  - https://kernel-internals.org/io-uring/io-uring-arch/
  - https://kernel-internals.org/io-uring/life-of-request/
  - https://kernel-internals.org/io-uring/io-uring-ops/
  - https://kernel-internals.org/io-uring/fixed-buffers/
  - https://kernel-internals.org/io-uring/security/
  - https://kernel-internals.org/io-uring/multishot-ops/
  - https://kernel-internals.org/io-uring/io-uring-vs-epoll/
  - https://lwn.net/Articles/776703/
  - https://lwn.net/Articles/810414/
---

# io_uring Internals

> 📘 Plain-language version: [[io-uring-internals-explained]]

## Purpose

io_uring is Linux's high-performance asynchronous I/O framework, introduced in kernel 5.1 by Jens Axboe. It replaces the broken promise of POSIX AIO — which was either restricted to `O_DIRECT` block I/O or implemented as a hidden userspace thread pool — with a genuine kernel-backed async interface that works uniformly across files, sockets, and pipes. The central insight is that submission and completion are completely decoupled: userspace describes what it wants in a shared-memory ring, the kernel processes it whenever it can, and results appear in a second shared-memory ring. On the fast path, neither side ever needs to make a syscall.

## Mental Model

Think of io_uring as a two-lane highway shared between userspace and the kernel. Userspace writes job tickets (SQEs) into one lane's inbox and drives away without waiting; the kernel picks them up, does the work, and drops result slips (CQEs) in the second lane's outbox. No tollbooth (syscall) is needed unless the lanes are congested or either side needs to wait for the other.

## How It Works

### The Submission/Completion Ring Layout

`io_uring_setup(depth, params)` is the entry point. It allocates three memory regions and returns a file descriptor that represents the entire ring context:

1. **SQ ring** — metadata ring: head/tail counters, flags, and an `array[]` of indices into the SQE array.
2. **SQE array** — the actual operation descriptors, at fixed offsets so userspace can write them without atomics.
3. **CQ ring** — completion ring: head/tail counters and an inline array of `struct io_uring_cqe` results.

Userspace maps all three regions with `mmap` (using `IORING_OFF_SQ_RING`, `IORING_OFF_SQES`, `IORING_OFF_CQ_RING` offsets on the returned fd). After that, `io_uring_setup` never needs to be called again — the rings live in shared memory.

The key struct on the kernel side is **`struct io_ring_ctx`** (`io_uring/io_uring.c`), allocated once per `io_uring_setup` call. It anchors everything: ring buffer pointers, the io-wq thread pool, the registered file and buffer tables, the SQPOLL thread reference, and all the per-ring locks. Its lifetime is tied to the io_uring file descriptor — when the last reference drops (close or process exit), `io_ring_ctx_free()` tears down the entire context.

### Preparing and Submitting a Request

Userspace fills in a **`struct io_uring_sqe`** (64 bytes, in `include/uapi/linux/io_uring.h`). The fields that matter most:

- `opcode` — 8-bit operation selector (`IORING_OP_READ`, `IORING_OP_SENDMSG`, `IORING_OP_ACCEPT`, etc.)
- `flags` — `IOSQE_FIXED_FILE`, `IOSQE_IO_LINK`, `IOSQE_BUFFER_SELECT`, etc.
- `fd` — file descriptor (or fixed-file index if `IOSQE_FIXED_FILE`)
- `addr` / `len` / `off` — buffer pointer, length, offset
- `user_data` — opaque 64-bit cookie; echoed verbatim into the matching CQE for correlation

The liburing helper `io_uring_prep_read(sqe, fd, buf, len, offset)` sets these fields, then `io_uring_submit()` advances the SQ tail with a store-release memory barrier. That barrier is the entire "submission" — no syscall required in the common case.

There are two paths the kernel takes from here:

**Standard path**: the application calls `io_uring_enter(ring_fd, to_submit, min_complete, flags, sig)`. Inside the kernel, `io_uring_enter()` calls `io_submit_sqes()`, which iterates from the last-seen head to the new tail. For each index in `sq->array[]`, the kernel calls `io_get_sqe()` to read the SQE, then `io_init_req()` to allocate a **`struct io_kiocb`** from a slab cache and populate it from the SQE. `io_init_req` also snapshots the caller's credentials (`get_current_cred()` into `req->creds`) — this snapshot will later govern permission checks in worker threads.

**SQPOLL path**: if `IORING_SETUP_SQPOLL` was set at setup time, a dedicated `sq_thread` kernel thread (`io_sq_thread()`, `io_uring/sqpoll.c`) polls the SQ ring in a tight loop. Userspace writes the SQE and advances the tail; the thread drains it without any syscall. When the ring has been idle for `sq_thread_idle` milliseconds, the thread parks and sets `IORING_SQ_NEED_WAKEUP` in the SQ flags, telling userspace to call `io_uring_enter` once more to wake it.

### Dispatch: Inline vs. Async

Once the kernel has a populated `struct io_kiocb`, it calls `io_queue_sqe(req)`, which calls `io_issue_sqe(req, IO_URING_F_NONBLOCK)`. This invokes the opcode handler — e.g., `io_read()` for `IORING_OP_READ` — with the non-blocking flag set.

**Inline fast path**: if the operation can complete immediately (page cache hit, socket buffer has data, filesystem respects `IOCB_NOWAIT`), `io_read()` returns a positive byte count or a non-retryable error. The kernel calls `io_req_complete_post(req, result)` directly, fills the CQE, and returns. The caller harvests it with `io_uring_peek_cqe()` — still zero syscalls.

**Async slow path**: if `io_read()` returns `-EAGAIN` (cold cache miss, O_DIRECT latency, filesystem lock contention), the kernel enqueues the request to **io-wq** by calling `io_queue_async(req)`. io-wq is a per-ring work queue (`struct io_wq`, `io_uring/io-wq.c`) backed by a pool of kernel threads that scale with the workload. The worker thread calls `io_wq_submit_work()`, which calls `io_issue_sqe(req, 0)` — this time without `IO_URING_F_NONBLOCK`, so the handler is free to sleep on page faults, block layer completions, or filesystem locks. The worker applies `override_creds(req->creds)` before the call and `revert_creds()` after, so the filesystem and block layer see the submitter's permissions rather than the worker thread's.

### Completion and Harvesting

When either path finishes, `io_req_complete_post()` writes the result:

1. Sets `req->cqe.res` to bytes transferred (or `-errno`).
2. Copies `user_data`, `res`, and `flags` into the next free slot of the CQ ring via `io_fill_cqe_req()`.
3. Calls `io_commit_cqring()`, which advances the CQ tail with a store-release barrier.

Userspace can harvest completions with pure userspace code: `io_uring_peek_cqe()` reads the CQ head under an acquire barrier, checks `tail != head`, and returns a pointer to the CQE. After processing, `io_uring_cqe_seen()` advances the head — again with a store-release — signaling the kernel that the slot is free. No syscall, no lock. If userspace needs to *block* until a completion appears, it calls `io_uring_enter(..., IORING_ENTER_GETEVENTS)`, which puts the caller to sleep until the minimum number of completions is available.

One important edge case: **CQ overflow**. If userspace falls behind and the CQ ring fills, kernels with `IORING_FEAT_NODROP` buffer excess CQEs internally and drain them later; older kernels drop them and increment an overflow counter. The right defense is to size the CQ ring larger than the SQ ring (via `IORING_SETUP_CQSIZE`) and keep up with harvesting.

## Key Data Structures

**`struct io_ring_ctx`** (`io_uring/io_uring.c`) — per-ring anchor; owns everything.
- `sq_sqes` — pointer to the mmap'd SQE array
- `rings` — pointer to the shared SQ/CQ ring metadata (`struct io_rings`)
- `io_wq` — the worker thread pool for async operations
- `sq_data` — SQPOLL thread state (`struct io_sq_data`)
- `file_table` / `buf_table` — registered file and buffer tables

**`struct io_kiocb`** (`io_uring/io_kiocb.h`) — kernel-internal in-flight request; slab-allocated.
- `opcode`, `flags` — copied from SQE
- `file` — resolved `struct file *`
- `creds` — snapshotted submitter credentials
- `cqe` — pre-built CQE result slot
- `work` — `struct io_wq_work` for enqueuing to io-wq

**`struct io_uring_sqe`** (`include/uapi/linux/io_uring.h`) — 64-byte userspace→kernel descriptor.

**`struct io_uring_cqe`** (`include/uapi/linux/io_uring.h`) — 16-byte kernel→userspace result.
- `user_data` — echoed from SQE for matching
- `res` — bytes transferred or `-errno`
- `flags` — `IORING_CQE_F_MORE` (multishot), `IORING_CQE_F_SOCK_NONEMPTY`, etc.

## Key Functions / Entry Points

**`io_uring_setup()`** (`io_uring/io_uring.c`) — allocates `io_ring_ctx`, sets up rings, returns fd; called once per ring.

**`io_submit_sqes()`** (`io_uring/io_uring.c`) — drains the SQ ring, allocating and dispatching `io_kiocb` per entry; called by `io_uring_enter` or the SQPOLL thread.

**`io_issue_sqe()`** (`io_uring/io_uring.c`) — dispatches to the opcode handler; called with `IO_URING_F_NONBLOCK` for the inline attempt and without it in io-wq workers.

**`io_req_complete_post()`** (`io_uring/io_uring.c`) — writes the CQE and advances the CQ tail; the terminal call for every request.

**`io_wq_submit_work()`** (`io_uring/io-wq.c`) — worker thread entry point; applies credentials and retries the operation without NONBLOCK.

**`io_sq_thread()`** (`io_uring/sqpoll.c`) — SQPOLL kernel thread; polls the SQ ring and calls `io_submit_sqes()` in a loop.

## Important Flags & Config Options

**Setup flags** (`io_uring_setup` params):

| Flag | Purpose |
|------|---------|
| `IORING_SETUP_SQPOLL` | Spawn an SQPOLL kernel thread; eliminates `io_uring_enter` for submission |
| `IORING_SETUP_SQ_AFF` | Pin the SQPOLL thread to a specific CPU (use `sq_thread_cpu`) |
| `IORING_SETUP_CQSIZE` | Override CQ depth (useful to size it larger than SQ to absorb bursts) |
| `IORING_SETUP_SINGLE_ISSUER` | (6.2+) Restrict submission to a single thread; enables internal optimizations |
| `IORING_SETUP_DEFER_TASKRUN` | (6.1+) Run completions in the submitting task rather than spawning io-wq threads |

**SQE flags** (`io_uring_sqe.flags`):

| Flag | Effect |
|------|--------|
| `IOSQE_FIXED_FILE` | Use registered file table index; skips per-op `fdget()` |
| `IOSQE_IO_LINK` | Soft-link to next SQE; cancel chain on failure |
| `IOSQE_IO_HARDLINK` | Hard-link; continue chain regardless of result |
| `IOSQE_ASYNC` | Force async execution even if inline would succeed |
| `IOSQE_BUFFER_SELECT` | Kernel selects buffer from provided buffer pool at completion time |

**Registration operations** (`io_uring_register`):

| Operation | Effect |
|-----------|--------|
| `IORING_REGISTER_BUFFERS` | Pre-pin userspace memory; use with `READ_FIXED`/`WRITE_FIXED` |
| `IORING_REGISTER_FILES` | Pre-store `struct file *` pointers; use with `IOSQE_FIXED_FILE` |
| `IORING_REGISTER_IOWQ_MAX_WORKERS` | Cap io-wq thread count to prevent worker explosion |
| `IORING_REGISTER_RESTRICTIONS` | Permanently whitelist allowed opcodes and flags |
| `IORING_REGISTER_PROBE` | Query opcode support before use |

## Interactions with Other Subsystems

- **↑ Userspace**: Userspace communicates entirely through shared-memory ring reads/writes and — only when blocking is needed — through `io_uring_enter(2)` and `io_uring_register(2)`. liburing wraps both into a clean API.
- **→ [[VFS]]**: Every read/write/open/close/stat operation goes through the VFS layer. io_uring calls `call_read_iter()`, `call_write_iter()`, `do_filp_open()`, etc., exactly as a direct syscall would, inheriting all VFS caching and locking semantics.
- **→ [[Block Layer]]**: O_DIRECT and buffered misses generate `struct bio` submissions to the block layer; io-wq workers sleep on bio completion just as `direct_IO` paths do.
- **→ [[Memory Management]]**: Fixed buffers call `pin_user_pages_fast()` to lock pages against reclaim. Standard I/O calls `get_user_pages()` per operation. Buffer rings use per-ring folio accounting.
- **→ [[Network Stack]]**: Socket operations (`ACCEPT`, `SEND`, `RECV`, `CONNECT`) call the normal socket path; multishot recv keeps a per-socket io_uring hook for zero-copy delivery.
- **→ [[locking -> seqlocks-and-memory-barriers|Memory Ordering]]**: The SQ and CQ rings use acquire-release semantics on head/tail counters. No spinlocks are taken on the submission or completion fast path, making the ring truly lock-free between userspace and the SQPOLL thread.
- **← [[Security]]**: Seccomp does **not** govern async operations dispatched by io-wq; `IORING_REGISTER_RESTRICTIONS` and `IORING_SETUP_DEFER_TASKRUN` are the kernel's mitigations. Android 12+ and Chrome OS both block `io_uring_setup` in their sandbox seccomp profiles.

## Design Decisions & Tradeoffs

**Separate SQE array from the SQ ring index array**: SQEs are 64 bytes and userspace needs to fill them without racing against the kernel advancing the head. By separating the index array (which the kernel reads) from the SQE array (which userspace writes), userspace can prepare multiple SQEs concurrently and then batch-submit by updating the tail once.

**Shared memory instead of syscall-per-operation**: The original AIO interface required a syscall for every `io_submit()` and every `io_getevents()`. io_uring trades a one-time `mmap` for zero-syscall steady-state, which becomes decisive above ~500K IOPS where system call overhead alone is measurable.

**io-wq instead of per-process thread pools**: Rather than making userspace manage threads for blocking I/O (as POSIX AIO does), io_uring maintains a kernel-side per-ring thread pool. This keeps the interface simple while allowing the kernel to schedule workers efficiently. The downside is that io-wq threads can pile up under load; `IORING_REGISTER_IOWQ_MAX_WORKERS` was added to cap them.

**Credential snapshotting**: Running work in kernel threads requires care about who "owns" the operation. The decision to snapshot credentials at `io_init_req()` and apply them via `override_creds()` in workers keeps permission semantics predictable and matches what a direct syscall would do. The cost is a `get_current_cred()` per submission.

**Seccomp bypass is a known tradeoff**: Making io_uring truly zero-syscall in the async path means seccomp cannot filter individual operations. The kernel accepts this tradeoff and compensates with `IORING_REGISTER_RESTRICTIONS` (which moves access control into the kernel) and `IORING_SETUP_DEFER_TASKRUN` (which routes completions back into the submitting task, bypassing io-wq entirely for many workloads).

**8-bit opcode field**: Limits io_uring to 256 operations. With ~50+ opcodes as of 6.x kernels, headroom exists but is not unlimited. The decision was to keep SQEs at exactly 64 bytes (one cache line) and accept the opcode limit rather than grow the structure.

## How It Has Evolved

**5.1 (May 2019)** — Initial release: NOP, vectored read/write, fixed-buffer I/O, fsync, poll-add.

**5.2–5.3** — Network support: sendmsg/recvmsg; `io_uring_register` for files and buffers.

**5.4–5.5** — Timeouts, operation cancellation, linked requests, SQPOLL stabilization, accept/connect.

**5.6** — File management opcodes: openat, close, statx, fadvise, fallocate, renameat, unlinkat. Splice support.

**5.10** — Restricted `io_uring_enter` to the creating task; hardened credential model. `IORING_SETUP_ATTACH_WQ` for sharing io-wq pools across rings.

**5.13** — Multishot poll (`IORING_POLL_ADD_MULTI`).

**5.19** — Multishot accept; provided buffer rings (`io_uring_buf_ring`) for unknown-size socket I/O.

**5.20 / 6.0** — Multishot recv; zero-copy send (`IORING_OP_SEND_ZC`, `IORING_OP_SENDMSG_ZC`).

**6.1** — `IORING_SETUP_DEFER_TASKRUN`: completions run in the submitting task's context via task_work, eliminating io-wq threads for single-threaded servers and closing the seccomp bypass for those setups.

**6.2** — `IORING_SETUP_SINGLE_ISSUER`: declares that only one thread submits, enabling lockless SQ processing and removing the last acquisition points on the submission fast path.

## Further Reading

1. [Ringing in a new asynchronous I/O API — LWN.net (2019)](https://lwn.net/Articles/776703/) — original introduction and design rationale by Jonathan Corbet
2. [The rapid growth of io_uring — LWN.net (2020)](https://lwn.net/Articles/810414/) — surveys the explosion of opcodes in 5.6
3. [Operations restrictions for io_uring — LWN.net (2021)](https://lwn.net/Articles/826053/) — deep dive on `IORING_REGISTER_RESTRICTIONS`
4. [Zero-copy network transmission with io_uring — LWN.net (2022)](https://lwn.net/Articles/879724/) — the zero-copy send design
5. [kernel-internals.org io_uring series](https://kernel-internals.org/io-uring/) — comprehensive multi-part walkthrough
6. [io_uring.c source](https://elixir.bootlin.com/linux/latest/source/io_uring/io_uring.c) — primary implementation (~7000 lines as of 6.x)

## LKML Highlights

- **Original RFC thread (Jan 2019)**: Jens Axboe posted the first RFC showing how the ring-buffer design eliminates the copy cost and syscall overhead of AIO. Key debate: whether to use a single ring or separate SQ/CQ rings. The two-ring design won because completion order differs from submission order.

- **io-wq introduction (5.3)**: Discussion around replacing the old `workqueue`-based async dispatch with a dedicated per-ring thread pool. The tradeoff between worker proliferation and latency was central; the `max_workers` knob was a direct outcome.

- **DEFER_TASKRUN RFC (6.1)**: Proposed as the long-term answer to the seccomp bypass concern — routing completions through `task_work_add()` so they run in the submitting process's context on return to userspace, eliminating the need for io-wq threads on the completion side entirely.
