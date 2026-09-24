---
title: "ublk Control Plane"
category: concept
tags: [ublk, block, io_uring, device-lifecycle, unprivileged]
subsystem: ublk
kernel_version: "6.0"
researched: 2026-09-24
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/block/ublk.html
  - https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/ublk_cmd.h
  - https://raw.githubusercontent.com/torvalds/linux/master/drivers/block/ublk_drv.c
  - https://lwn.net/Articles/903855/
  - https://kernelnewbies.org/Linux_6.16
  - https://kernelnewbies.org/Linux_7.0
  - https://github.com/ublk-org/ublksrv
---

# ublk Control Plane

## Purpose

A userspace block driver needs a way to ask the kernel to create a disk, describe its geometry and limits, wait until the server can take I/O, and later stop, resize, quiesce or delete it. The ublk control plane does this through io_uring commands on `/dev/ublk-control`. It turns a server's "I will handle I/O for a disk shaped like this" into a real `gendisk` and ties the disk's life to the server's.

## Mental Model

Think of it as **hot-plugging a virtual storage controller**. `ADD_DEV` installs the controller (a char device the driver talks through) without attaching any disk. `SET_PARAMS` programs its capabilities. `START_DEV` is the moment the disk appears on the bus, but only once every queue has a driver thread ready to take I/O. `STOP_DEV` unplugs the disk, and `DEL_DEV` removes the controller.

## How It Works

**Opening the control channel.** The `ublk_drv` module registers a misc device, `/dev/ublk-control`. A server opens it and submits `IORING_OP_URING_CMD` SQEs (128-byte SQEs, so there is room for the payload). Each carries a `struct ublksrv_ctrl_cmd`: `dev_id` (or -1 to allocate one), `queue_id`, and an `addr`/`len` pointing at a command-specific buffer. Since 6.2 opcodes are ioctl-encoded (`UBLK_U_CMD_ADD_DEV = _IOWR('u', 0x04, …)`), so LSMs and seccomp can recognise them. The legacy raw numbers are still accepted. `ublk_ctrl_uring_cmd()` dispatches every command synchronously, under the device's `ub->mutex`.

**Creating the device.** `UBLK_U_CMD_ADD_DEV` takes a `struct ublksrv_ctrl_dev_info` proposing `nr_hw_queues`, `queue_depth`, `max_io_buf_bytes` and a 64-bit `flags` feature mask. A server should first call `UBLK_U_CMD_GET_FEATURES` and only request bits the kernel supports. `ublk_ctrl_add_dev()` allocates a `struct ublk_device`, per-queue `struct ublk_queue`s (NUMA-local since 6.19), and a `blk_mq_tag_set` whose ops are either the classic or the batch variant. It creates the char device `/dev/ublkcN` and writes the final info (with the assigned `dev_id`) back. From this point the dev info is immutable, because everything else, including descriptor array sizes and mmap offsets, is derived from it.

**Describing the disk.** `UBLK_U_CMD_SET_PARAMS` supplies a `struct ublk_params` whose `types` bitmap says which sub-structs are present:
- `basic`: logical/physical block shift, `max_sectors`, `dev_sectors`, and attributes such as read-only, rotational, volatile cache, FUA
- `discard`: discard and write-zeroes limits
- `zoned`: open/active zone limits and zone-append size
- `dma` alignment and `seg` segment limits
- `integrity` (7.0): protection-information format

`devt` is read-only and reports the char/disk major:minor numbers back. Parameters can only be set before start, and they become the disk's `queue_limits`.

**Starting.** The server opens `/dev/ublkcN` and `mmap()`s each queue's read-only `ublksrv_io_desc` array (`ublk_ch_mmap()` uses `remap_pfn_range()` and clears `VM_MAYWRITE`). It then posts FETCH commands for every slot (see [[ublk-io-command-protocol]]). `UBLK_U_CMD_START_DEV` → `ublk_ctrl_start_dev()` waits until the ready count covers all queues, records the server pid, applies the params and calls `add_disk()`. `/dev/ublkbN` appears, with partitions scanned unless `UBLK_F_NO_AUTO_PART_SCAN` is set. Waiting for readiness matters, because otherwise the first partition-table read would hang with nobody to serve it.

**Running-state commands.**
- `GET_DEV_INFO`/`GET_DEV_INFO2` and `GET_PARAMS` let tools like `ublk list` inspect a device.
- `GET_QUEUE_AFFINITY` returns the CPU mask of each blk-mq hctx, so the server can pin threads near their submitters.
- `UPDATE_SIZE` (6.16) resizes a live disk.
- `QUIESCE_DEV` (6.16) pauses I/O for a planned server swap (see [[ublk-user-recovery]]).
- `REG_BUF`/`UNREG_BUF` register shared memory for [[ublk-zero-copy]].

**Teardown.** `UBLK_U_CMD_STOP_DEV` → `ublk_ctrl_stop_dev()` calls `del_gendisk()`. The driver cancels outstanding fetches, and pending I/O is failed (or held if recovery is configured). `TRY_STOP_DEV` (7.0, `UBLK_F_SAFE_STOP_DEV`) refuses with `-EBUSY` while the disk is still open, so a script cannot yank a mounted disk. `DEL_DEV` frees the char device and ID. `DEL_DEV_ASYNC` doesn't wait for the last char-device reference to drop.

**Unprivileged mode.** With `UBLK_F_UNPRIVILEGED_DEV` (6.2), `ADD_DEV` works without `CAP_SYS_ADMIN`. The kernel records `owner_uid`/`owner_gid`, and every later control command must include the char-device path (`dev_path_len` bytes at the start of the buffer). The kernel performs a permission check on that path, so udev rules and ownership decide who may drive the device, and devices are effectively scoped to the creating container. The number of such devices is capped by the `ublks_max` module parameter. Features that bypass isolation, such as registered-buffer zero-copy, still require `CAP_SYS_ADMIN`.

**Failure path.** If the server dies before `START_DEV`, closing `/dev/ublkcN` resets the queues and the device can be started again or deleted. After start, what happens depends on recovery flags. Without them the disk is removed as if unplugged.

## Key Data Structures

**`struct ublksrv_ctrl_cmd`** (`include/uapi/linux/ublk_cmd.h`) — payload of every control uring_cmd.
- `dev_id`, `queue_id` — target device/queue
- `addr`, `len` — command buffer
- `data[1]` — inline argument (e.g. new size, recovery pid)
- `dev_path_len` — length of the char-device path prefix in unprivileged mode

**`struct ublk_device`** (`drivers/block/ublk_drv.c`)
- `ub_disk`, `tag_set`, `queues[]` — the blk-mq plumbing
- `dev_info` — the negotiated `ublksrv_ctrl_dev_info`
- `params` — the stored `ublk_params`
- `mutex` — serialises control commands

## Key Functions / Entry Points

**`ublk_ctrl_uring_cmd()`** — `f_op->uring_cmd` of `/dev/ublk-control`; permission check then dispatch.
**`ublk_ctrl_add_dev()`** — allocate device, queues, tag set, char device.
**`ublk_ctrl_set_params()`** — validate and store `ublk_params`.
**`ublk_ctrl_start_dev()`** — wait for readiness, apply limits, `add_disk()`.
**`ublk_ctrl_stop_dev()` / `ublk_ctrl_del_dev()`** — teardown.
**`ublk_ch_mmap()`** — expose descriptor arrays to the server.

## Important Flags & Config Options

- `CONFIG_BLK_DEV_UBLK` — builds `ublk_drv`.
- `ublks_max` module parameter — max unprivileged devices (default 64).
- `UBLK_F_UNPRIVILEGED_DEV`, `UBLK_F_CMD_IOCTL_ENCODE` — access model and opcode encoding.
- `UBLK_F_UPDATE_SIZE`, `UBLK_F_QUIESCE`, `UBLK_F_SAFE_STOP_DEV`, `UBLK_F_NO_AUTO_PART_SCAN` — optional lifecycle commands/behaviours.
- `UBLK_F_ZONED`, `UBLK_F_INTEGRITY` — enable the corresponding param types.

## Interactions with Other Subsystems

- **↑ Userspace**: `ublk` CLI (ublksrv), rublk, kublk selftests, and libraries issue these commands. udev reacts to the new `ublkc`/`ublkb` nodes.
- **→ [[uring-cmd-passthrough]]**: every control command is a uring_cmd.
- **→ [[blk-mq]]**: tag set allocation, `add_disk()`/`del_gendisk()`, queue limits.
- **→ [[user-namespaces]] / [[lsm-framework]]**: unprivileged mode relies on file permissions of the char device, and ioctl encoding lets LSMs filter opcodes.

## Design Decisions & Tradeoffs

- **Two-stage add/start.** Splitting device creation from disk exposure lets the server set up threads and rings against a known device ID, and ensures the kernel never exposes a disk that cannot serve I/O. The cost is that `START_DEV` can block while waiting on userspace.
- **Control via io_uring too.** Reusing uring_cmd keeps one mechanism for everything, but it means even simple admin tools need an io_uring, which some hardened systems disable.
- **Immutable device info, mutable params before start.** Freezing queue count and depth avoids reallocating shared memory under the server's feet. Only size (6.16) was later made live-changeable, because that is what real deployments needed.
- **Path-based permission for unprivileged use.** Rather than inventing a new capability model, ublk reuses file permissions on `/dev/ublkcN`, so existing udev and container tooling decides access.

## How It Has Evolved

- **6.0** — ADD/DEL/START/STOP/SET_PARAMS/GET_PARAMS/GET_QUEUE_AFFINITY/GET_DEV_INFO.
- **6.1** — START/END_USER_RECOVERY.
- **6.2** — unprivileged devices, `GET_DEV_INFO2`, ioctl-encoded opcodes, `GET_FEATURES`.
- **6.6** — zoned params.
- **6.16** — `UPDATE_SIZE`, `QUIESCE_DEV`.
- **6.19** — NUMA-aware allocation of queue structures.
- **7.0** — `TRY_STOP_DEV`, integrity params.
- **2026** — `REG_BUF`/`UNREG_BUF` for shared-memory zero-copy; `UBLK_F_IO_DESC_SIZE` lets the descriptor grow.

## Further Reading

1. [An io_uring-based user-space block driver — LWN](https://lwn.net/Articles/903855/)
2. [ublk driver documentation — kernel.org](https://www.kernel.org/doc/html/latest/block/ublk.html)
3. [ublk_cmd.h uAPI](https://github.com/torvalds/linux/blob/master/include/uapi/linux/ublk_cmd.h)
4. [ublksrv README](https://github.com/ublk-org/ublksrv) — unprivileged-mode udev rules and CLI.

## LKML Highlights

- **Original ublk series (Ming Lei, 2022, `20220713140711.97356-1-ming.lei@redhat.com`)** — established the ADD → SET_PARAMS → START handshake over `/dev/ublk-control`.
- **Unprivileged ublk (Ming Lei, late 2022)** — added the device-path permission scheme and ioctl encoding so that containers can own ublk devices. The discussion centred on limiting the damage from unprivileged block devices.
- **"ublk: add UBLK_CMD_TRY_STOP_DEV" (2025–26)** — safe stop for orchestration tools that must not rip away a mounted disk.
