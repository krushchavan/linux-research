---
title: "io_uring uring_cmd Passthrough"
category: concept
tags: [io_uring, uring-cmd, passthrough, nvme, ublk]
subsystem: io_uring
kernel_version: "5.19"
researched: 2026-09-24
status: complete
sources:
  - https://lwn.net/Articles/849751/
  - https://lwn.net/Articles/901219/
  - https://lwn.net/Articles/902466/
  - https://lwn.net/Articles/904198/
  - https://lwn.net/Articles/895528/
  - https://lwn.net/Articles/1002722/
  - https://lwn.net/Articles/1007721/
  - https://lwn.net/Articles/1051215/
  - https://kernel-internals.org/io-uring/io-uring-ops/
---

# io_uring uring_cmd Passthrough

## Purpose

io_uring's generic opcodes (read, write, send, recv…) can only express what the generic kernel interfaces express. Many devices and subsystems have richer native command sets. NVMe has hundreds of commands and new ones such as zoned append and flexible data placement, and a userspace block driver needs a protocol to fetch and complete requests. Before uring_cmd those were reachable only via synchronous `ioctl()`. `IORING_OP_URING_CMD` gives any file a way to accept its own commands through the ring, asynchronously, with batching and polled completion, without adding a new io_uring opcode per command.

## Mental Model

uring_cmd is **io_uring's async ioctl**. The ring provides the envelope: submission, async completion, batching, registered buffers, IOPOLL. The file's driver defines what's written on the letter inside. io_uring doesn't interpret the payload. It just delivers it to `file->f_op->uring_cmd()` and later delivers the driver's reply as a CQE.

## How It Works

**Ring setup.** A 64-byte SQE leaves only a small area for the command payload, so passthrough users typically create the ring with `IORING_SETUP_SQE128`, which doubles SQEs to 128 bytes and leaves up to 80 bytes of inline command (`sqe->cmd`). Many commands also return more than a 32-bit result, so `IORING_SETUP_CQE32` doubles CQEs to 32 bytes, with `big_cqe[]` carrying extra result words. For NVMe that's the 64-bit completion "result" dword pair.

**Issue.** The SQE carries `opcode = IORING_OP_URING_CMD`, the target `fd`, and `cmd_op`, a driver-defined command number such as `NVME_URING_CMD_IO`. `io_uring_cmd_prep()` records a pointer to the SQE payload in a `struct io_uring_cmd`, which is overlaid on the request (`io_kiocb_to_cmd()`), so there's no extra allocation. `io_uring_cmd()` then runs the LSM check `security_uring_cmd()` and calls `file->f_op->uring_cmd(ioucmd, issue_flags)`. `issue_flags` tells the driver the context: `IO_URING_F_NONBLOCK` for the inline attempt, `IO_URING_F_SQE128`/`_CQE32` for entry sizes, `IO_URING_F_IOPOLL` for polled rings, and `IO_URING_F_CANCEL` during cancellation.

**Driver response.** The handler has three choices:
1. **Complete inline**: return a result ≥ 0 or an error, and io_uring posts the CQE.
2. **Go async**: return `-EIOCBQUEUED` after submitting to hardware. When the hardware completes (often in IRQ context), the driver calls `io_uring_cmd_complete_in_task()` with a callback. That uses [[io-uring-task-work]] to run the callback in the submitter, which then calls `io_uring_cmd_done(ioucmd, res, res2, issue_flags)` to post the CQE (with `res2` in the big CQE).
3. **Return `-EAGAIN`** when it can't proceed without blocking. io_uring then retries from an [[io-wq]] worker without `NONBLOCK`.

Userspace may reuse the SQE slot as soon as submission returns, so an async command can't keep pointing into the ring. When a command goes async (punted, or retried after `-EAGAIN`), io_uring first copies the SQE into the request's async data and repoints `ioucmd->sqe` at that copy. Over time the rules for exactly when this copy happens have been tightened several times after use-after-reuse bugs.

**Polled passthrough.** On an `IORING_SETUP_IOPOLL` ring, NVMe passthrough submits to a polled hardware queue and registers the request on the ring's `iopoll_list`. `io_do_iopoll()` (from `io_uring_enter(GETEVENTS)` or [[sqpoll]]) calls `file->f_op->uring_cmd_iopoll()`, which spins on the completion queue. There are no interrupts at all, which is the configuration used for the highest IOPS results.

**Fixed buffers.** With `IORING_URING_CMD_FIXED` in `sqe->uring_cmd_flags` and a `buf_index`, the driver calls `io_uring_cmd_import_fixed()` to get an `iov_iter` over a [[registered-resources|registered buffer]], so there's no per-command page pinning. For ublk the buffer can even be a kernel bvec registered by the driver itself, which is the basis of ublk zero-copy.

**Cancellation.** Some uring_cmds are *long-lived*. A ublk "fetch request" command, for instance, sits pending until the block layer sends I/O. The driver marks those cancelable with `io_uring_cmd_mark_cancelable()`. On ring exit or `ASYNC_CANCEL`, io_uring calls the driver's `->uring_cmd` again with `IO_URING_F_CANCEL` so it can complete them. Without this, a ring with pending ublk fetches could never be torn down.

**The users.**
- **NVMe generic char devices (5.19)**: `/dev/ngXnY` exposes every namespace, including ones with unsupported formats, and `nvme_ns_chr_uring_cmd()` accepts `struct nvme_uring_cmd` (opcode, nsid, cdw10–15, data address/length). This gives async, batched access to any NVMe command. Kanchan Joshi and Anuj Gupta (Samsung) drove it, and its IOPS approach raw block-device I/O while skipping the block layer's generic request path.
- **ublk (6.0, Ming Lei)**: a userspace block driver. The server sends `UBLK_U_IO_FETCH_REQ` uring_cmds that complete when the kernel has an I/O for it, and it answers with `UBLK_U_IO_COMMIT_AND_FETCH_REQ`. The whole control loop is uring_cmd.
- **Sockets (6.7)**: `SOCKET_URING_OP_SIOCINQ`, `SIOCOUTQ`, `GETSOCKOPT`, `SETSOCKOPT`, and later timestamp retrieval, so event loops don't need synchronous syscalls for socket control.
- **FUSE over io_uring (6.14, Bernd Schubert)**: the FUSE server registers per-CPU queues and exchanges requests and replies via uring_cmds instead of `read`/`write` on `/dev/fuse` ([[fuse]]).
- **Others**: btrfs encoded reads (6.13), block-device discard (`BLOCK_URING_CMD_DISCARD`, 6.12), and virtio-blk passthrough (posted).

**Security.** Passthrough bypasses the permission logic that generic paths get from the VFS and block layer. NVMe requires `CAP_SYS_ADMIN` for admin commands and file-mode checks for I/O commands. `security_uring_cmd()` (6.0, Luis Chamberlain and Paul Moore) was added after the observation that SELinux and Smack had no way to police these commands at all. The debate became LWN's "Security requirements for new kernel features" story: should new user-facing interfaces be required to have LSM hooks from day one?

## Key Data Structures

**`struct io_uring_cmd`** (`include/linux/io_uring/cmd.h`) — the command as seen by drivers.
- `file` — target file
- `sqe` — pointer to the (possibly copied) SQE, and so to the command payload
- `cmd_op` — driver-defined command number
- `flags` — `IORING_URING_CMD_FIXED`, cancelable, polled
- `pdu[]` — small driver-private scratch area (32 bytes) inside the request

**`struct nvme_uring_cmd`** (`include/uapi/linux/nvme_ioctl.h`) — NVMe passthrough payload: `opcode`, `flags`, `nsid`, `cdw2`–`cdw15`, `addr`, `data_len`, `metadata`, `timeout_ms`.

**`file_operations` hooks** — `uring_cmd(struct io_uring_cmd *, unsigned int issue_flags)` and `uring_cmd_iopoll(struct io_uring_cmd *, struct io_comp_batch *, unsigned int)`.

## Key Functions / Entry Points

**`io_uring_cmd_prep()` / `io_uring_cmd()`** (`io_uring/uring_cmd.c`) — prepare and issue; call the file's `->uring_cmd`.

**`io_uring_cmd_done()`** — driver-called completion; posts CQE with `res` and optional `res2`.

**`io_uring_cmd_complete_in_task()`** — schedule a completion callback in the submitter's context.

**`io_uring_cmd_import_fixed()`** — map a registered buffer for a command.

**`io_uring_cmd_mark_cancelable()`** — register a long-lived command for cancellation callbacks.

**`nvme_ns_chr_uring_cmd()`** (`drivers/nvme/host/ioctl.c`) — the NVMe handler.

## Important Flags & Config Options

- **`IORING_SETUP_SQE128` / `IORING_SETUP_CQE32`** — big entries; nearly always used with passthrough.
- **`IORING_SETUP_IOPOLL`** — polled passthrough via `->uring_cmd_iopoll`.
- **`IORING_URING_CMD_FIXED`** — use a registered buffer.
- **`CONFIG_BLK_DEV_UBLK`**, **`CONFIG_FUSE_IO_URING`**, **`CONFIG_NVME_CORE`** — the main consumers.
- **LSM**: SELinux permission `io_uring { cmd }`; Smack checks the device label.

## Interactions with Other Subsystems

- **↑ Userspace**: liburing `io_uring_prep_uring_cmd()` / `io_uring_prep_cmd_sock()`; xNVMe, SPDK-style userspace stacks, and ublk servers (ublksrv, rublk).
- **→ Drivers**: NVMe, [[ublk]], [[fuse]], sockets and btrfs implement `->uring_cmd`.
- **→ [[block]]**: NVMe passthrough builds raw `struct request`s with `REQ_OP_DRV_IN/OUT`, skipping bio splitting and the I/O scheduler.
- **→ [[security]]**: `security_uring_cmd()` LSM hook.
- **→ [[registered-resources]]**: fixed buffers and kernel-registered bvecs.
- **→ [[io-uring-task-work]]**: completions bounce to task context.

## Design Decisions & Tradeoffs

**One generic opcode instead of many.** Adding io_uring opcodes for every NVMe command would bloat the core and couple it to device specs. uring_cmd keeps the core generic and pushes command semantics into drivers. The cost is that the core can't validate payloads, so each driver must do its own checks.

**Big SQEs/CQEs as a ring-wide choice.** 128-byte SQEs make passthrough allocation-free but double ring memory for every request on that ring, generic ones included. Mixed-size rings (`IORING_SETUP_CQE_MIXED`, and later SQE equivalents) let big and small entries share a ring.

**Bypassing generic layers.** NVMe passthrough skips the block layer's generic paths. That gives access to new device features immediately and cuts overhead, but loses I/O scheduling, cgroup I/O control and generic accounting, and pushes safety checks into the driver.

**LSM coverage retrofitted.** The feature merged without LSM hooks, which prompted a broader argument (2022) about requiring security hooks for new user-facing interfaces. The hook was added in 6.0.

## How It Has Evolved

- **2021** — RFCs by Jens Axboe for a generic passthrough mechanism with an in-SQE command area.
- **5.19** — `IORING_OP_URING_CMD`, SQE128/CQE32, NVMe char-device passthrough.
- **6.0** — ublk; `security_uring_cmd()`; IOPOLL for passthrough.
- **6.1–6.2** — fixed-buffer passthrough; NVMe multipath passthrough.
- **6.7** — socket uring_cmds.
- **6.12–6.14** — block discard, btrfs encoded read, FUSE over io_uring.
- **6.15** — ublk zero-copy via kernel bvec registration.
- **2025–2026** — kernel-managed buffer rings for FUSE; BPF-based per-request extensions proposed as an alternative to growing driver command sets.

## Further Reading

1. [An io_uring-based user-space block driver — LWN (2022)](https://lwn.net/Articles/904198/)
2. [io_uring passthrough support — patch posting (2021)](https://lwn.net/Articles/849751/)
3. [Security requirements for new kernel features — LWN (2022)](https://lwn.net/Articles/902466/)
4. [lsm,io_uring: add LSM hooks for the new uring_cmd file op — patch posting](https://lwn.net/Articles/901219/)
5. [ublk zero-copy support — patch posting (2025)](https://lwn.net/Articles/1007721/)
6. [virtio-blk: add io_uring passthrough support — patch posting](https://lwn.net/Articles/1002722/)
7. [fuse/io-uring: kernel-managed buffer rings and zero-copy — patch posting](https://lwn.net/Articles/1051215/)

## LKML Highlights

> lore.kernel.org was unreachable from this run.

- **"io_uring passthrough support" v4 (Jens Axboe, Mar 2021)** — splits the SQE into a header and a 40-byte command area (later grown with SQE128). It stresses no extra allocations and no new branches on the io_uring hot path.
- **"lsm,io_uring: add LSM hooks for the new uring_cmd file op" (Luis Chamberlain, 2022)** — added after it emerged that uring_cmd shipped with no LSM coverage. The resulting debate, covered by LWN, was about whether LSM hooks should be a merge prerequisite.
- **`<20251218083319.3485503-1-joannelkoong@gmail.com>`** — Joanne Koong's kernel-managed buffer rings for FUSE-over-io_uring, the next step in turning uring_cmd channels into zero-copy data paths.
