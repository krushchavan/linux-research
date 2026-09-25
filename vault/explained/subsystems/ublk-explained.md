---
title: "ublk — Explained"
category: explained
original: "[[ublk]]"
subsystem: ublk
tags: [explained, ublk, block, io_uring, userspace-drivers]
converted: 2026-09-25
---

# ublk, explained

> Plain-language companion to [[ublk|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Many "disks" aren't hardware at all: a disk image file (qcow2), a disk served over the network (NBD, Ceph), a compressed or replicated volume. Traditionally each of these was a driver inside the kernel (loop, nbd...), where bugs crash the machine and every new format needs kernel code.

Moving them to ordinary user-space programs is attractive, but earlier attempts (NBD over a socket, BUSE, TCMU with a shared ring) paid a heavy performance tax: context switches or a network protocol for every request.

ublk ("user-space block"), written by Ming Lei (Red Hat) and merged in **6.0** (2022), lets a normal process implement a block device with little or no performance loss. At launch its loop target actually benchmarked *faster* than the in-kernel loop driver.

## The big picture

ublk is **a block driver whose "hardware" is a user-space process, with io_uring as the doorbell and completion queue**. Think of the user-space server as a disk controller:
- It keeps empty "fetch" commands posted, the way a controller keeps receive slots open.
- When the block layer has a request, the kernel completes one of those commands. That is the doorbell.
- The server does the work and posts a single "commit and fetch" command, which returns the result *and* re-arms the slot.
- A shared-memory array of per-request descriptors plays the role of the controller's request entries.

Most of ublk's later history is about making the data movement across that boundary cheaper (copy → copy on demand → zero-copy → shared-memory zero-copy) or the doorbell cheaper (one command per I/O → batches).

```text
 client app ──read/write──▶ /dev/ublkbN (a real block device)
                                │ block layer request
                                ▼
                       ublk kernel driver
                                │ note to the server thread (task work)
                                ▼
                 fill descriptor ─▶ complete a pending "fetch" (doorbell)
                                │
                                ▼
         ublk server process (user space) ──▶ backend: file, network, memory
                                │
                    "commit and fetch" (result + re-arm)
                                ▼
                    block request completes ──▶ client

 control device: add / configure / start / stop / recover devices
```

## The pieces

### Control plane

Creates and tears down devices and agrees on their shape. See [[ublk-control-plane-explained|ublk-control-plane]].

1. The server sends an "add device" command on a control device, giving the number of queues, queue depth (up to 4096 × 4096), largest I/O size, and feature flags. The kernel creates the device's internal state and a per-device channel the server will talk to. After this, the basic shape is frozen.
2. A "set parameters" command supplies block sizes, maximum request size, discard, zoned, alignment and integrity limits.
3. The server maps the descriptor arrays into its memory and posts one "fetch" per request slot on every queue.
4. "Start" waits until every queue reports ready, then exposes the disk.
5. "Stop" removes the disk and cancels I/O; "delete" frees the rest. Later additions: live resize, quiesce, a safe stop that fails if the disk is still open, and feature discovery.

With the unprivileged option, a non-root user can create devices. Each command then names the device path so the kernel can check permissions, ownership is recorded, and the number of such devices is capped (64 by default).

### The I/O command protocol

The per-request handshake. See [[ublk-io-command-protocol-explained|ublk-io-command-protocol]].

1. Each slot is identified by (queue, tag), matching the block layer's own request tags one-to-one.
2. The server primes each slot with a "fetch" command, which stays pending for a long time.
3. When the block layer hands ublk a request, the driver can't talk to the server from there. It schedules **task work** on the server thread that owns the slot, because filling the server's buffer and completing its command must happen in that thread's own context.
4. In that thread, the driver fills the slot's descriptor (operation, flags, start sector, length, buffer address), copies write data into the server's buffer, and completes the fetch command. The slot now belongs to the server.
5. The server reads the descriptor, does the work, and sends "commit and fetch" with the result. The driver copies read data back, ends the block request, and the same command re-arms the slot.

At first there was one server thread per queue. Since 6.16, each slot can be served by whichever thread fetched it, so server thread pools no longer have to match hardware queues.

### Batch I/O

Removes the one-command-per-request overhead (7.0). See [[ublk-batch-io-explained|ublk-batch-io]].

1. Three per-queue commands replace the per-request ones: prime many slots at once; a **multishot** fetch that delivers a batch of tags into a buffer with one completion; and a commit that reports results for many tags at once.
2. Inside the kernel, new requests go into a per-queue queue of events. Writers take a lock; the single reader doesn't need one.
3. Several server threads may each post a fetch, and whichever is active takes the next batch, so load balances automatically.
4. Gain: about 12% more IOPS on 16-job copy workloads (37.8M → 42.4M), 3.7% with zero-copy.

### Zero-copy

Copying every byte between the client's pages and the server is ublk's main remaining overhead. See [[ublk-zero-copy]]. Four data paths, in the order they appeared:
1. **Copy** (default): the driver copies at dispatch and commit.
2. **Copy on demand** (~6.5): the server reads and writes the device channel at an offset that encodes (queue, tag), copying only what it needs, when it needs it.
3. **Registered-buffer zero-copy** (6.15): the driver installs the client request's pages into a registered-buffer slot of the server's io_uring. The server's fixed-buffer reads and writes against its backend then move data directly between the client's pages and the backend. A release callback keeps the request alive until the last user is done. In 6.16 the kernel can do this registration automatically at an index the server chose, saving two commands per I/O.
4. **Shared-memory zero-copy** (2026): when client and server map the same memory file, the server registers it. For direct I/O whose pages match, the descriptor carries a buffer index and offset instead of copied data. Anything else falls back to copying.

### User recovery

Keeps the disk alive while its server crashes and restarts, so a crash doesn't look like a disk being ripped out. See [[ublk-user-recovery]].

1. When the server dies, all its pending commands are cancelled.
2. Without recovery options, the device is torn down and I/O fails.
3. With recovery, requests the server hadn't seen are requeued, ones it owned are failed, and the device enters a **quiesced** state: new I/O waits instead of erroring. A "reissue" option requeues owned requests too, for backends where redoing is safe. A "fail I/O" option errors new I/O until recovery instead.
4. A new server process starts recovery, re-opens the channel, re-posts its fetches and ends recovery. Queued I/O then flows to it. Planned server upgrades reuse the same machinery (6.16).

## A request's journey

A 64 KiB write to a qcow2 image served by ublk with automatic buffer registration:

1. **Filesystem submits a write.** The block layer allocates tag 17 on queue 2 and hands the request to ublk.
2. **Bounce to the right thread.** ublk schedules task work on the server thread that fetched slot (2, 17).
3. **Doorbell.** In that thread, the driver fills descriptor (2, 17), registers the request's pages at the buffer index the server chose, and completes the pending fetch.
4. **Server translates.** The server maps the guest offset to a qcow2 cluster.
5. **Zero-copy write.** It issues a fixed-buffer write on the image file using that buffer index. Data goes from the client's pages to the image file with no copy.
6. **Commit.** When the write completes, the server sends "commit and fetch" with 65,536 bytes. The kernel unregisters the buffer, ends the block request, and re-arms the slot.
7. **Client sees completion.**

If the server crashed in the middle, the device would quiesce, client I/O would wait in the block layer, and after systemd restarted the server and it re-ran recovery, the queued I/O would drain to the new process.

## Tradeoffs

- **What it gives you:** block devices implemented as ordinary processes, with batching, zero-copy, crash recovery and performance close to (sometimes better than) in-kernel drivers.
- **What it costs / requires:** a hard dependency on io_uring; environments that disable io_uring for security can't use ublk. Every request needs a hop into the server thread's context.
- **Where it bites:** whether a request the server owned can be safely redone depends on the backend (a network write may already have landed), so recovery behaviour is a choice the operator must make; the kernel doesn't guess. Unprivileged devices raise the risk of hung I/O and of kernel bugs reachable from attacker-controlled disks, hence the device cap, creator scoping, and killing the server on timeout rather than waiting forever.

## How it got here

- **6.0 (2022):** merged through the io_uring tree, initially without documentation: one thread per queue, copy mode.
- **6.1–6.6:** crash recovery (Ziyang Zhang, Alibaba), unprivileged devices, and zoned devices. A "fused command" zero-copy design was merged for 6.4 and then pulled as too intrusive; copy-on-demand was the stopgap.
- **6.15:** real zero-copy via kernel-registered buffers (Keith Busch, Meta), chosen because it made kernel buffers behave like user-registered ones, with no new io_uring semantics. Zero-copy had been reserved in the interface since 2022.
- **6.16–6.19:** automatic buffer registration, quiesce, live resize, per-slot server threads, off-thread registration, NUMA-aware allocation.
- **7.0:** batch I/O and integrity metadata. **2026 (7.1 cycle):** shared-memory zero-copy and variable descriptor size, with review and hardening from Pure Storage engineers who run ublk in production.

## Related

- Technical version: [[ublk]]
- [[io_uring-explained|io_uring]]: the transport ublk rides on
- [[uring-cmd-passthrough-explained|Passthrough commands]], [[io-uring-task-work-explained|Task work]], [[registered-resources-explained|Registered resources]], [[provided-buffer-rings-explained|Provided buffer rings]]
- [[blk-mq-explained|blk-mq]] and [[block-explained|Block layer]]: ublk is a normal block driver to them
- [[ublk-control-plane-explained|ublk-control-plane]], [[ublk-io-command-protocol-explained|ublk-io-command-protocol]], [[ublk-batch-io-explained|ublk-batch-io]], [[ublk-zero-copy]], [[ublk-user-recovery]]
- [[get-user-pages-and-pinning|Page pinning]]
