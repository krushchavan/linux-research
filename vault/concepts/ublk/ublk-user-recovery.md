---
title: "ublk User Recovery"
category: concept
tags: [ublk, recovery, fault-tolerance, blk-mq, quiesce]
subsystem: ublk
kernel_version: "6.1"
researched: 2026-09-24
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/block/ublk.html
  - https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/ublk_cmd.h
  - https://raw.githubusercontent.com/torvalds/linux/master/drivers/block/ublk_drv.c
  - https://lwn.net/Articles/906097/
  - https://lwn.net/Articles/909066/
  - https://kernelnewbies.org/Linux_6.1
  - https://kernelnewbies.org/Linux_6.16
---

# ublk User Recovery

## Purpose

Moving a block driver into userspace means it can crash like any process. Without special handling, a server crash makes `/dev/ublkbN` vanish and fails every outstanding I/O, which to a mounted filesystem looks like a yanked disk. User recovery keeps the block device (and its users) alive, holds or fails I/O according to policy, and lets a replacement server process take over.

## Mental Model

This is **a call-centre transfer**. The caller (the filesystem) stays on hold with music (a quiesced queue) while the agent (server) who dropped the call is replaced. The new agent picks up the same line (same `/dev/ublkbN`, same tags) and resumes. The policy flags decide what happens to the question the old agent was halfway through answering: drop it with an error, ask it again, or tell every caller "try later" until someone picks up.

## How It Works

**Detection.** A server process that exits (or crashes) closes `/dev/ublkcN` and its io_uring instances. io_uring teardown invokes the driver's cancel hook for every pending fetch ([[ublk-io-command-protocol]]). `ublk_uring_cmd_cancel_fn()` → `ublk_start_cancel()` sets the canceling flag on the device and all queues (under `cancel_mutex`) and quiesces the blk-mq queues so `queue_rq` stops dispatching. `ublk_cancel_cmd()` then completes each still-ACTIVE fetch with an abort and marks it `UBLK_IO_FLAG_CANCELED`.

**Release work.** The final close of `/dev/ublkcN` schedules `ublk_ch_release_work_fn()`. It first waits until no zero-copy buffer references remain: `ublk_check_and_reset_active_ref()` requires `ref + task_registered_buffers` to be exactly the initial value or zero, and otherwise reschedules itself. A request can't be failed or requeued while a registered-buffer backend I/O may still be touching its pages. Then `ublk_abort_queue()` handles every request in `UBLK_IO_FLAG_OWNED_BY_SRV` state via `__ublk_fail_req()`, and the device's policy decides the outcome:

- **No recovery flags**: owned requests fail with `-EIO`, and the device is stopped and removed as on `STOP_DEV`.
- **`UBLK_F_USER_RECOVERY`** (6.1): owned requests are *failed* (the kernel can't know whether the old server's write landed), while requests not yet delivered are *requeued*. The device goes to `UBLK_S_DEV_QUIESCED`, and new client I/O waits in blk-mq. `/dev/ublkbN` stays present.
- **`UBLK_F_USER_RECOVERY_REISSUE`** (6.1): owned requests are *requeued* too and will be reissued to the new server. This is only safe for backends where a duplicated write is harmless (idempotent or read-only).
- **`UBLK_F_USER_RECOVERY_FAIL_IO`** (~6.13): the device enters `UBLK_S_DEV_FAIL_IO`, so outstanding *and new* I/O fail immediately until recovery completes. This suits clients (such as multipath or databases) that prefer a fast error to an indefinite hang.

Finally `ublk_reset_ch_dev()` reinitialises every slot's `ublk_io`, clears the old `mm` and ready counters, and the char device becomes openable again.

**Recovery.** A supervisor (systemd, an orchestrator) launches the new server, which:
1. sends `UBLK_U_CMD_START_USER_RECOVERY`. `ublk_ctrl_start_recovery()` verifies the device is quiesced or failing and that the old daemon is gone, and prepares for new readiness.
2. opens `/dev/ublkcN`, mmaps descriptors and re-posts FETCH (or batch PREP/FETCH) for every slot. The new server must rebuild its own state, such as reopening image files and reconnecting to storage. The kernel only preserves the block device.
3. sends `UBLK_U_CMD_END_USER_RECOVERY`. `ublk_ctrl_end_recovery()` waits for all slots to be ready, records the new `ublksrv_pid`, sets `UBLK_S_DEV_LIVE`, and unquiesces the queues, and requeued requests dispatch to the new process.

**Planned handover: quiesce (`UBLK_F_QUIESCE`, 6.16).** To upgrade a server without a crash, `UBLK_U_CMD_QUIESCE_DEV` → `ublk_ctrl_quiesce_dev()` drives the same state transition deliberately. Queues are quiesced, fetches are cancelled via `ublk_quiesce_uring_cmd()`, and the old server can exit cleanly. The new server then follows the same START/END recovery steps.

**Failure path during recovery.** If the replacement also dies, the same release path runs again. If nobody recovers, I/O stays queued (`QUIESCED`) or failing (`FAIL_IO`) until an admin sends `STOP_DEV`/`DEL_DEV`. Request timeouts still apply, and for unprivileged devices `ublk_timeout()` kills a stuck server.

## Key Data Structures

**`struct ublk_device`** recovery-relevant fields (`drivers/block/ublk_drv.c`)
- `dev_info.state` — `UBLK_S_DEV_LIVE`, `QUIESCED`, `FAIL_IO`, `DEAD`
- `dev_info.flags` — which recovery policy is active
- `ublksrv_tgid`, `mm` — identity of the current daemon; cleared by `ublk_reset_ch_dev()`
- `mutex` > `cancel_mutex` — lock order for control vs cancellation

**`struct ublk_io`** — `flags` (`ACTIVE`, `OWNED_BY_SRV`, `CANCELED`) decide whether a request is requeued or failed; `ref`/`task_registered_buffers` gate release.

## Key Functions / Entry Points

**`ublk_uring_cmd_cancel_fn()` / `ublk_start_cancel()` / `ublk_cancel_cmd()`** — react to ring teardown.
**`ublk_ch_release_work_fn()`** — main crash-handling worker.
**`ublk_abort_queue()` / `__ublk_fail_req()`** — apply requeue-or-fail policy.
**`ublk_ctrl_start_recovery()` / `ublk_ctrl_end_recovery()`** — recovery control commands.
**`ublk_ctrl_quiesce_dev()`** — planned quiesce.

## Important Flags & Config Options

- `UBLK_F_USER_RECOVERY` — keep the device and requeue undelivered I/O.
- `UBLK_F_USER_RECOVERY_REISSUE` — also reissue delivered I/O (idempotent backends only).
- `UBLK_F_USER_RECOVERY_FAIL_IO` — fail fast while no server is attached.
- `UBLK_F_QUIESCE` — enables `UBLK_U_CMD_QUIESCE_DEV` for planned handover.

## Interactions with Other Subsystems

- **↑ Userspace**: supervisors restart servers, and the ublksrv `ublk recover` command drives START/END recovery. Servers must persist enough state to resume.
- **→ [[blk-mq]]**: `blk_mq_quiesce_queue()`, requeue lists, and `blk_mq_unquiesce_queue()` implement "hold" semantics.
- **→ [[uring-cmd-passthrough]]**: cancelable uring_cmds are how the kernel notices the server is gone.
- **→ [[ublk-zero-copy]]**: buffer references must drain before requests are touched.

## Design Decisions & Tradeoffs

- **Policy flags instead of one behaviour.** Only the backend knows whether reissuing a write is safe. Offering fail, reissue and fail-fast lets each server choose its correctness model, at the cost of three flags to understand.
- **Kernel preserves only the device, not server state.** Keeping the kernel side minimal (disk, tags, queued requests) means all real state recovery is the server's job. This keeps the kernel simple but requires servers to be written for restartability.
- **Hold by default rather than error.** `QUIESCED` makes crashes invisible to clients if recovery is quick, but a missing supervisor can leave I/O blocked indefinitely. `FAIL_IO` exists for users that can't tolerate that.
- **Wait for buffer references.** Zero-copy made release asynchronous (a delayed work item that retries), trading prompt teardown for memory safety.

## How It Has Evolved

- **6.1** — `USER_RECOVERY` and `USER_RECOVERY_REISSUE` (Ziyang Zhang, Alibaba), proposed weeks after ublk's merge.
- **~6.13** — `USER_RECOVERY_FAIL_IO` (Uday Shankar).
- **6.15–6.17** — release path reworked to handle registered zero-copy buffers (`ref` and `task_registered_buffers` accounting).
- **6.16** — `UBLK_F_QUIESCE` for planned upgrades.
- **7.0** — batch-mode cancellation paths (`ublk_batch_cancel_queue()`).

## Further Reading

1. [Crash recovery for user-space block drivers — LWN (2022)](https://lwn.net/Articles/906097/)
2. [ublk_drv: add USER_RECOVERY support — LWN patch posting](https://lwn.net/Articles/909066/)
3. [ublk driver documentation — User recovery, kernel.org](https://www.kernel.org/doc/html/latest/block/ublk.html)
4. [Linux 6.1 — Kernelnewbies](https://kernelnewbies.org/Linux_6.1)

## LKML Highlights

- **"ublk_drv: add USER_RECOVERY support" (Ziyang Zhang, Aug–Sep 2022)** — designed the START/END recovery bracket and debated with Ming Lei whether issued requests should be failed or reissued. That debate produced the separate `REISSUE` flag.
- **"ublk: support UBLK_F_USER_RECOVERY_FAIL_IO" (Uday Shankar, 2024)** — fail-fast recovery for clients that must not hang.
- **"ublk: add feature UBLK_F_QUIESCE" (Ming Lei, 2025)** — reuses recovery machinery for zero-downtime server upgrades.
