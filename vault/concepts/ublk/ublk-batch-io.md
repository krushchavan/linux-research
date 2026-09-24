---
title: "ublk Batch I/O"
category: concept
tags: [ublk, io_uring, multishot, batching, performance]
subsystem: ublk
kernel_version: "7.0"
researched: 2026-09-24
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/block/ublk.html
  - https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/ublk_cmd.h
  - https://raw.githubusercontent.com/torvalds/linux/master/drivers/block/ublk_drv.c
  - https://ratatoskr.run/linux-block/2026/01/6434724/t
  - https://lkml.org/lkml/2025/11/28/663
  - https://kernelnewbies.org/Linux_7.0
---

# ublk Batch I/O

## Purpose

The classic [[ublk-io-command-protocol]] costs one uring_cmd SQE and one CQE per block request, and each slot is permanently bound to the task that fetched it. At tens of millions of IOPS the per-command overhead is significant, and a fixed binding means one busy thread cannot shed work to an idle one. `UBLK_F_BATCH_IO` (7.0) replaces per-slot commands with per-queue commands that deliver and commit many I/Os at once, with any server task able to take any I/O.

## Mental Model

The classic protocol is a pager per table. Batch I/O is a **kitchen ticket printer**: any number of cooks can stand at the pass, and whoever's turn it is tears off the next strip of tickets, however many have accumulated. Cooks then hand back a tray of finished dishes together.

## How It Works

**Preparation.** After `ADD_DEV` with `UBLK_F_BATCH_IO`, the server doesn't send `FETCH_REQ` per slot. Instead it sends `UBLK_U_IO_PREP_IO_CMDS` with a `struct ublk_batch_io` header (`q_id`, `nr_elem`, `elem_bytes`, `flags`) and a buffer of elements. Each element is a `ublk_elem_header {tag, buf_index, result}`, optionally followed by a buffer address (`UBLK_BATCH_F_HAS_BUF_ADDR`) or zone LBA (`UBLK_BATCH_F_HAS_ZONE_LBA`). This primes many slots in one command and marks them ready for `START_DEV`.

**Fetching with multishot.** Each server task that wants work submits `UBLK_U_IO_FETCH_IO_CMDS`, a **multishot** uring_cmd bound to an io_uring [[provided-buffer-rings|provided buffer group]]. The kernel keeps these fetch commands on a per-queue list, `fcmd_head`, and at most one is `active_fcmd` at any moment.

**Request arrival.** blk-mq calls `ublk_batch_queue_rq()` (or `ublk_batch_queue_rqs()` for a plug list). The driver pushes the request's tag into the queue's `evts_fifo` under `evts_lock`, which is cheap for the many concurrent writers. If this is the last request in the current blk-mq batch, it takes the next fetch command (`__ublk_acquire_fcmd()`) and schedules task-work on that command's task. In that context `ublk_batch_dispatch()` loops:
- `__ublk_batch_dispatch()` picks a buffer from the provided-buffer ring (`io_uring_cmd_buffer_select()`).
- It dequeues as many tags as fit from the FIFO. The single consumer is lockless, and ordering against producers is maintained with `smp_mb()` pairs.
- For each tag, `ublk_batch_prep_dispatch()` fills the descriptor, copies WRITE data if in copy mode, and auto-registers the buffer if `UBLK_F_AUTO_BUF_REG` is set (see [[ublk-zero-copy]]).
- `ublk_batch_fetch_post_cqe()` posts a multishot CQE whose buffer holds the tag list.

The multishot command stays armed, so one SQE delivers an unbounded stream of batches. The buffer size caps how many tags go in one CQE. If more events are pending when the active fetch runs out of buffers, the next fetch command on the list becomes active. Work therefore flows to whichever tasks keep fetches posted, and that is how load balancing happens.

**Committing.** The server processes the tags however it likes, in any order and on any thread, then sends `UBLK_U_IO_COMMIT_IO_CMDS` with an element array of `{tag, buf_index, result}`. `ublk_batch_commit_io()` walks the array and finishes each request via `__ublk_complete_rq()`. Commit is not tied to the fetching task. That flexibility is the main point of the feature.

**Failure path.** On cancellation `ublk_batch_cancel_queue()` splices `fcmd_head` into a local list, returns the active fetch, and completes each with an abort. `ublk_abort_batch_queue()` drains remaining FIFO tags and fails or requeues their requests according to [[ublk-user-recovery]] flags. Fixes in 2026 included snapshotting the commit element buffer before walking it, so a server cannot change it mid-processing.

## Key Data Structures

**`struct ublk_batch_io`** (uapi) — header for PREP/COMMIT/FETCH.
- `q_id` — queue
- `flags` — `HAS_BUF_ADDR`, `HAS_ZONE_LBA`, `AUTO_BUF_REG_FALLBACK`
- `nr_elem`, `elem_bytes` — element count and stride (8 bytes + optional 8 + 8)

**`struct ublk_elem_header`** (uapi) — `tag`, `buf_index` (for auto buffer registration), `result` (commit only).

**`struct ublk_queue`** batch fields (`drivers/block/ublk_drv.c`)
- `evts_fifo`, `evts_lock` — pending tags, multi-producer/single-consumer
- `fcmd_head`, `active_fcmd` — posted fetch commands and the one currently draining

## Key Functions / Entry Points

**`ublk_batch_queue_rq()` / `ublk_batch_queue_rqs()`** — blk-mq entry in batch mode.
**`ublk_batch_queue_cmd()` / `ublk_batch_queue_cmd_list()`** — push tags, acquire a fetch command.
**`ublk_batch_tw_cb()` → `ublk_batch_dispatch()`** — drain the FIFO into multishot CQEs.
**`ublk_batch_commit_io()`** — process a COMMIT_IO_CMDS element.
**`ublk_batch_cancel_queue()`, `ublk_abort_batch_queue()`** — teardown.

## Important Flags & Config Options

- `UBLK_F_BATCH_IO` — enables the model; the per-I/O FETCH/COMMIT commands are rejected on such devices.
- `UBLK_BATCH_F_AUTO_BUF_REG_FALLBACK` — per-batch equivalent of the auto-reg fallback flag.
- The provided-buffer ring size chosen by the server controls maximum batch size.

## Interactions with Other Subsystems

- **↑ Userspace**: a server needs liburing multishot uring_cmd support and a provided buffer ring per fetching task. The kublk selftests implement the reference loop.
- **→ [[io-uring-async-poll-and-multishot]]**: multishot CQE semantics (`IORING_CQE_F_MORE`).
- **→ [[provided-buffer-rings]]**: buffer selection for tag lists.
- **← [[blk-mq]]**: `queue_rqs` plug batching feeds naturally into FIFO bulk inserts.

## Design Decisions & Tradeoffs

- **Per-queue instead of per-I/O commands.** This amortises submission and completion cost, giving about +12% IOPS at 16 jobs in copy mode (37.8M → 42.4M) and +3.7% with zero-copy. The gain is smaller with zero-copy because data movement no longer dominates.
- **Single active fetch, many posted.** One consumer keeps the FIFO lockless on the read side. Letting several tasks queue fetches gives natural work distribution without a kernel-side scheduler.
- **Exclusive with the classic protocol.** Mixing models on one device would complicate slot ownership and cancellation, so a device picks one at `ADD_DEV`.
- **Complexity cost.** The series grew to 24–27 patches over six revisions. Memory-ordering between FIFO producers and the consumer needed careful barrier work, and early fixes followed the merge.

## How It Has Evolved

- **Nov 2025** — V4 posted (27 patches).
- **Jan 2026** — V6 (24 patches); merged for **7.0**.
- **Early–mid 2026** — BATCH_IO fix series (cancellation, commit buffer snapshotting).

## Further Reading

1. [ublk driver documentation — Batch I/O section, kernel.org](https://www.kernel.org/doc/html/latest/block/ublk.html)
2. [Linux 7.0 — Kernelnewbies](https://kernelnewbies.org/Linux_7.0)
3. [PATCH V6 00/24: ublk: add UBLK_F_BATCH_IO — archive](https://ratatoskr.run/linux-block/2026/01/6434724/t)

## LKML Highlights

- **"[PATCH V4 00/27] ublk: add UBLK_F_BATCH_IO" (Ming Lei, Nov 2025)** — sets out the motivation: per-I/O daemons still bind work to threads, and per-I/O commands cost too much at scale.
- **"[PATCH V6 00/24] ublk: add UBLK_F_BATCH_IO" (Ming Lei, Jan 2026)** — final form. Caleb Sander Mateos's review pushed several refactors toward safer helper functions before merge.
- **"[PATCH 0/3] ublk: BATCH_IO fixes" (Jan 2026)** — early post-merge fixes to cancellation and ordering.
