---
title: "ublk I/O Command Protocol"
category: concept
tags: [ublk, io_uring, uring-cmd, blk-mq, task-work]
subsystem: ublk
kernel_version: "6.0"
researched: 2026-09-24
status: complete
explained: "[[ublk-io-command-protocol-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/block/ublk.html
  - https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/ublk_cmd.h
  - https://raw.githubusercontent.com/torvalds/linux/master/drivers/block/ublk_drv.c
  - https://lwn.net/Articles/903855/
  - https://lwn.net/Articles/900690/
  - https://kernelnewbies.org/Linux_6.16
---

# ublk I/O Command Protocol

> 📘 Plain-language version: [[ublk-io-command-protocol-explained]]

## Purpose

Once a ublk disk exists, every block request must reach the userspace server and every completion must come back. A syscall per request in each direction would make ublk far slower than an in-kernel driver. The FETCH / COMMIT_AND_FETCH protocol puts both directions on io_uring: one long-lived command per I/O slot, a shared read-only descriptor array, and a single combined command that returns a result and re-arms the slot.

## Mental Model

Think of **a restaurant pager per table**. The server hands the kernel a pager for every table (`FETCH_REQ`). When an order (request) arrives at table 17, the kernel writes the order on table 17's ticket (the descriptor) and buzzes that pager (completes the CQE). The waiter serves the order, then returns the pager while reporting the bill (`COMMIT_AND_FETCH_REQ`), and the same pager is ready for the next order at that table.

## How It Works

**Slots and descriptors.** A device has `nr_hw_queues` queues, each with `queue_depth` slots. A slot is identified by `(q_id, tag)`, and the blk-mq tag of the request *is* the slot tag, so no mapping table is needed. For each queue the driver allocates an array of `struct ublksrv_io_desc` (op/flags, `nr_sectors`, `start_sector`, `addr`). The server maps it read-only via `mmap()` of `/dev/ublkcN` at `UBLKSRV_CMD_BUF_OFFSET` plus the queue offset. The kernel writes descriptors and the server only reads them, so a buggy server cannot corrupt kernel state through them.

**Priming.** For each slot the server submits an `IORING_OP_URING_CMD` with `cmd_op = UBLK_U_IO_FETCH_REQ` on `/dev/ublkcN`. The payload is a `struct ublksrv_io_cmd {q_id, tag, result, addr}`, where `addr` is the server buffer for this slot in copy mode. `ublk_ch_uring_cmd()` checks that the queue is not being cancelled and hands off to `ublk_fetch()`. That records the command in `struct ublk_io`, sets `UBLK_IO_FLAG_ACTIVE`, remembers `current` as the slot's daemon `task`, marks the command cancelable, and returns `-EIOCBQUEUED`, so the SQE stays pending in the ring indefinitely. `ublk_mark_io_ready()` counts slots, and once all are primed `START_DEV` can proceed ([[ublk-control-plane]]).

**Request arrives (fast path).** blk-mq calls `ublk_queue_rq()` (or `ublk_queue_rqs()` for a plug list) on the hctx. `ublk_prep_req()` rejects I/O while the queue is cancelling or in fail-IO mode. The submitting task could be any process on any CPU, but completing the server's uring_cmd and touching its memory must happen in the server's context. So `ublk_queue_cmd()` stores the request in the command's PDU and calls `io_uring_cmd_complete_in_task()` with `ublk_cmd_tw_cb()`, which queues [[io-uring-task-work]] on the daemon task. When that task next enters the kernel (or immediately, if it's waiting in `io_uring_enter`), `ublk_dispatch_req()` runs:
- `ublk_setup_iod()` fills the descriptor (op, flags such as FUA/META/NOUNMAP, sectors, buffer address).
- `ublk_start_io()` copies WRITE payload into the server buffer (`ublk_map_io()` → `ublk_copy_user_pages()`), unless a zero-copy or user-copy mode is active (see [[ublk-zero-copy]]).
- `ublk_complete_io_cmd()` flips the slot to `UBLK_IO_FLAG_OWNED_BY_SRV` and calls `io_uring_cmd_done()`, so the FETCH's CQE appears in the server's CQ.

**Server processes and commits.** The server reaps the CQE (its `user_data` identifies the tag), reads descriptor `[tag]`, does the work, then submits `UBLK_U_IO_COMMIT_AND_FETCH_REQ` with `result` = bytes done or a negative errno. The driver verifies that the slot is owned by the server and that the caller is the slot's daemon. `__ublk_complete_rq()` copies READ data from the server buffer into the request pages (`ublk_unmap_io()`), calls `blk_update_request()`/`__blk_mq_end_request()` (batched via `blk_mq_add_to_batch()` when possible), and re-arms the slot with the same uring_cmd. One SQE therefore both completes the previous request and waits for the next. The steady-state cost is one SQE and one CQE per I/O.

**The NEED_GET_DATA variant.** In plain copy mode the server must supply a WRITE buffer *before* it knows the request size. With `UBLK_F_NEED_GET_DATA` (6.0), a WRITE is first delivered with no data. The server allocates a buffer and issues `UBLK_U_IO_NEED_GET_DATA` with its address, and only then does the kernel copy the payload. That costs an extra round trip but suits servers that manage memory per request.

**Daemon ownership.** In the original design one daemon task served a whole queue, and every slot's commands had to come from it. `UBLK_F_PER_IO_DAEMON` (6.16, Uday Shankar) makes ownership per slot: whichever task issued a slot's FETCH owns that slot. Server thread count is therefore independent of `nr_hw_queues`, and load can be spread by tag. Later still, [[ublk-batch-io]] removes fixed ownership entirely.

**Failure and cancellation path.** When a server's ring is torn down or it cancels commands, io_uring calls the driver's `->uring_cmd` with `IO_URING_F_CANCEL`. `ublk_uring_cmd_cancel_fn()` → `ublk_start_cancel()` marks the queue cancelling and quiesces it, so `queue_rq` stops dispatching. `ublk_cancel_cmd()` then completes each still-ACTIVE fetch with an abort result and sets `UBLK_IO_FLAG_CANCELED`. Requests the server already owned are handled later by `ublk_abort_queue()` in the char-device release path (see [[ublk-user-recovery]]). Requests that time out go through `ublk_timeout()`. For unprivileged devices it sends `SIGKILL` to the server so a malicious or stuck server cannot hang the system forever.

## Key Data Structures

**`struct ublksrv_io_desc`** (uapi) — one per slot, kernel-written, server-read.
- `op_flags` — op in bits 0–7 (`UBLK_IO_OP_READ/WRITE/FLUSH/DISCARD/WRITE_ZEROES/ZONE_*`), flags above
- `nr_sectors` (or `nr_zones`), `start_sector`
- `addr` — server buffer address, or a shmem index/offset in shared-memory zero-copy

**`struct ublksrv_io_cmd`** (uapi) — payload of per-I/O uring_cmds.
- `q_id`, `tag` — slot
- `result` — commit result
- `addr` / `zone_append_lba` — buffer (fetch) or zone-append result

**`struct ublk_queue`** (`drivers/block/ublk_drv.c`)
- `ios[]` — per-slot `struct ublk_io`
- `io_cmd_buf` — the descriptor array mmap'd by the server
- `q_id`, `q_depth`, `flags`, `cancel_lock`

## Key Functions / Entry Points

**`ublk_queue_rq()` / `ublk_queue_rqs()`** — blk-mq `queue_rq`/`queue_rqs`.
**`ublk_cmd_tw_cb()` → `ublk_dispatch_req()`** — task-work delivery to the server.
**`ublk_ch_uring_cmd()` / `ublk_ch_uring_cmd_local()`** — `f_op->uring_cmd` of `/dev/ublkcN`.
**`ublk_fetch()`**, **`ublk_get_data()`** — FETCH and NEED_GET_DATA handling.
**`__ublk_complete_rq()`** — finish a request after commit.
**`ublk_uring_cmd_cancel_fn()`**, **`ublk_cancel_cmd()`**, **`ublk_timeout()`** — cancellation/timeout paths.

## Important Flags & Config Options

- `UBLK_F_PER_IO_DAEMON` — per-slot rather than per-queue daemon.
- `UBLK_F_NEED_GET_DATA` — two-phase WRITE.
- `UBLK_F_URING_CMD_COMP_IN_TASK` — historically forced task-work completion. It is now always done this way and the flag is kept for compatibility.
- `UBLK_F_IO_DESC_SIZE` — descriptor size taken from `dev_info.io_desc_size`, allowing it to be extended.
- `UBLK_F_ZONED` — adds zone ops and `zone_append_lba` in the commit.

## Interactions with Other Subsystems

- **↑ Userspace**: server event loop built on liburing: `io_uring_prep_uring_cmd()`, reap CQE, act, commit.
- **→ [[uring-cmd-passthrough]]**: long-lived cancelable uring_cmds are the transport.
- **→ [[io-uring-task-work]]**: dispatch into the server's context.
- **← [[blk-mq]]**: tags define slots, and `queue_rq`, timeouts and quiesce drive the protocol.

## Design Decisions & Tradeoffs

- **Commit and fetch in one command.** Merging "here is my answer" and "give me the next one" halves the SQE count compared with separate commands, the same trick NVMe uses with SQ/CQ doorbells.
- **Read-only shared descriptors, data via copy.** Keeping descriptors read-only for the server and copying data made the first version simple and safe. It also left data copy as the dominant cost, which drove years of [[ublk-zero-copy]] work.
- **Bouncing through task_work.** This guarantees the correct `mm` and ring context for copying and completion. The cost is a context hop and, before per-I/O daemons, a hard binding of queues to threads.
- **Tag = slot.** Reusing blk-mq tags avoids an allocator, but it means queue depth fixes the number of pending uring_cmds, which is at most 4096 per queue.

## How It Has Evolved

- **6.0** — per-queue daemon, FETCH/COMMIT_AND_FETCH, NEED_GET_DATA.
- **6.2** — ioctl-encoded `UBLK_U_IO_*` opcodes.
- **6.6** — zoned ops and zone-append LBA return.
- **6.15** — `REGISTER_IO_BUF`/`UNREGISTER_IO_BUF` join the command set.
- **6.16** — per-I/O daemons.
- **7.0** — batch commands as an alternative protocol ([[ublk-batch-io]]).

## Further Reading

1. [An io_uring-based user-space block driver — LWN](https://lwn.net/Articles/903855/) — walks through FETCH/COMMIT.
2. [ublk: add io_uring based userspace block driver — LWN patch posting](https://lwn.net/Articles/900690/)
3. [ublk driver documentation — kernel.org](https://www.kernel.org/doc/html/latest/block/ublk.html)

## LKML Highlights

- **"[PATCH V5 0/2] ublk: add io_uring based userspace block driver" (`20220713140711.97356-1-ming.lei@redhat.com`)** — defines the protocol. Ming Lei's reply in the thread reports ublk-loop beating kernel loop.
- **"ublk: decouple server threads from ublk_queues/hctxs" (Uday Shankar, 2025)** — introduced per-I/O daemons, motivated by servers whose thread model did not match the hctx count.
