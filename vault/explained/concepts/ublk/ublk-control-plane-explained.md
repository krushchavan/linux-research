---
title: "ublk Control Plane — Explained"
category: explained
original: "[[ublk-control-plane]]"
subsystem: ublk
tags: [explained, ublk, block, lifecycle, unprivileged]
converted: 2026-09-25
---

# The ublk control plane, explained

> Plain-language companion to [[ublk-control-plane|the technical note]]. Same facts, fewer identifiers.

## The problem

A block device served by a user-space process needs a lifecycle. The process has to ask the kernel to create a disk, describe its size and limits, and then the disk must appear only once the process is really ready to serve it. Later it may need to be resized, paused, stopped or deleted, and the disk's life has to be tied to the server's.

There's a trap in the timing. The moment a new disk appears, the system reads its partition table. If nobody is ready to answer that read, it hangs.

## The idea in one paragraph

Think of it as **hot-plugging a virtual storage controller**. "Add device" installs the controller (a channel the server talks through) without attaching a disk. "Set parameters" programs its capabilities. "Start" is the moment the disk appears, and only once every queue has a server thread ready to take I/O. "Stop" unplugs the disk, and "delete" removes the controller. All of these are io_uring commands sent to one control device.

## Step by step

### Step 1: Open the control channel
The ublk driver provides a control device. The server opens it and sends io_uring passthrough commands, each naming a device ID (or asking for a new one), a queue, and a buffer with the command's data. Since 6.2 the command codes use the standard ioctl encoding, so security modules and seccomp can recognise them. Every control command runs under the device's lock.

### Step 2: Discover features, then add the device
The server first asks which features the running kernel supports, and requests only those. "Add device" proposes a number of hardware queues, a queue depth, a largest I/O size, and a set of feature flags. The kernel allocates the device, its queues (on the local NUMA node since 6.19), and the block layer's tag set, creates a per-device channel, and writes the final settings (including the assigned ID) back.

From here the settings are **frozen**. The size of the shared descriptor arrays and their mapping offsets are derived from them, and changing them later would pull memory out from under the server.

### Step 3: Describe the disk
"Set parameters" says what kind of disk this is, in optional sections:
- basics: block sizes, maximum request size, disk size, and attributes such as read-only, rotational, volatile write cache
- discard and write-zeroes limits
- zoned-device limits
- alignment and segment limits
- integrity format (7.0)

These can only be set before start, and become the disk's queue limits.

### Step 4: The server gets ready
The server opens the per-device channel, maps each queue's descriptor array read-only into its memory, and posts a "fetch" command for every slot.

### Step 5: Start: the disk appears
This is the key step. "Start" waits until every queue reports ready, records the server's process ID, applies the parameters, and then adds the disk. It appears as a block device and its partitions are scanned (unless disabled). Because start waited for readiness, that first partition-table read gets answered.

### Step 6: While it runs
Tools can read back device info and parameters. The server can ask which CPUs each hardware queue serves, so it can pin threads near the submitters. Later additions let a live disk be resized (6.16), paused for a planned server swap (6.16), and register shared memory for zero-copy (2026).

### Step 7: Stop and delete
"Stop" removes the disk, cancels outstanding fetches, and fails pending I/O (or holds it if recovery is configured). A safe variant (7.0) refuses while the disk is still open, so a script can't yank a mounted disk. "Delete" frees the channel and ID; an asynchronous variant doesn't wait for the last reference to the channel to go.

If the server dies before start, closing its channel resets the queues and the device can be started again or deleted. After start, it depends on recovery settings; without them, the disk vanishes as if unplugged.

### Step 8: Unprivileged mode
With the unprivileged option (6.2), "add device" doesn't need admin rights. The kernel records the owning user and group, and every later command must include the channel's device path. The kernel checks ordinary file permissions on that path, so udev rules and file ownership decide who may drive the device, which effectively scopes it to the container that created it. The number of such devices is capped (64 by default), and features that bypass isolation, like registered-buffer zero-copy, still need admin rights.

## The picture

```text
 control device                         kernel                      visible to system
 ──────────────                         ──────                      ─────────────────
 get features  ──────────────────────▶  what's supported
 add device (queues, depth, flags) ──▶  device + queues + channel   /dev/ublkcN
 set parameters (sizes, limits) ─────▶  stored limits
       server: map descriptors, post a fetch per slot
 start ──────────────────────────────▶  wait: all queues ready?
                                        yes → add disk ──────────▶  /dev/ublkbN (+ partitions)
 resize / quiesce / register buffers ▶  live changes
 stop (or safe stop: refuse if open) ▶  remove disk
 delete ─────────────────────────────▶  free channel + ID
```

## Tradeoffs

- **What it gives you:** a disk that only appears when it can actually serve I/O, a single mechanism (io_uring) for control and data, and non-root devices governed by ordinary file permissions.
- **What it costs / requires:** "start" can block while waiting on user space; even simple admin tools need an io_uring, which some hardened systems disable.
- **Where it bites:** queue count and depth are fixed for the device's life; only size was later made changeable live, because that's what deployments needed. Unprivileged block devices widen the attack surface, which is why they are capped, scoped to their creator, and denied some features.

## How it got here

- **6.0:** add, delete, start, stop, parameters, queue affinity and device info, in Ming Lei's original series.
- **6.1:** recovery start and end commands.
- **6.2:** unprivileged devices, ioctl-encoded commands, and feature discovery, so containers can own ublk devices.
- **6.6:** zoned parameters. **6.16:** live resize and quiesce. **6.19:** NUMA-aware allocation.
- **7.0:** safe stop and integrity parameters. **2026:** shared-memory buffer registration and growable descriptors.

## Related

- Technical version: [[ublk-control-plane]]
- [[ublk-explained|ublk]]: the subsystem overview
- [[ublk-io-command-protocol-explained|ublk-io-command-protocol]]: what the server does after start
- [[ublk-user-recovery-explained|ublk-user-recovery]], [[ublk-zero-copy-explained|ublk-zero-copy]]
- [[uring-cmd-passthrough-explained|Passthrough commands]], [[blk-mq-explained|blk-mq]]
- [[user-namespaces-explained|User namespaces]], [[lsm-framework-explained|LSM framework]]
