---
title: "io_uring uring_cmd Passthrough — Explained"
category: explained
original: "[[uring-cmd-passthrough]]"
subsystem: io_uring
tags: [explained, io_uring, passthrough, nvme, ublk]
converted: 2026-09-25
---

# io_uring passthrough commands (uring_cmd), explained

> Plain-language companion to [[uring-cmd-passthrough|the technical note]]. Same facts, fewer identifiers.

## The problem

io_uring's generic operations (read, write, send, receive...) can only express what the kernel's generic file and socket interfaces express. Many devices have far richer native command sets. NVMe has hundreds of commands, with new ones such as zoned append and flexible data placement. A user-space block driver needs its own protocol to fetch and complete requests.

Before this feature, those were reachable only through `ioctl`, a synchronous call: one command, one system call, wait for the answer. Adding a new io_uring operation for every device command would bloat io_uring and tie it to device specifications.

## The idea in one paragraph

Give any file a way to accept *its own* commands through the ring. uring_cmd is **io_uring's asynchronous ioctl**. The ring provides the envelope: submission, asynchronous completion, batching, registered buffers, completion polling. The driver defines what is written on the letter inside. io_uring doesn't interpret the payload; it delivers it to the file's driver and later delivers the driver's reply as a completion.

## Step by step

### Step 1: Make room in the ring
A normal 64-byte request entry leaves little space for a command. So passthrough users usually create the ring with **double-size entries** (128 bytes), leaving up to 80 bytes for the inline command. Many commands also return more than a 32-bit result, so completions can be doubled to 32 bytes too. For NVMe that carries the device's 64-bit completion result.

### Step 2: Submit the command
The request names the file, a driver-defined command number, and the payload. io_uring records where the payload is, with no extra allocation, runs a security-module check, and hands the command to the file's driver. It also tells the driver the context: is this the "don't block" first attempt, are entries big, is this a polled ring, or is this a cancellation.

### Step 3: The driver answers in one of three ways
1. **Done now:** return a result, and io_uring posts the completion.
2. **Done later:** submit to the hardware and say "queued". When the hardware finishes (often in an interrupt), the driver asks for a callback to run in the submitter's thread via task work, and that callback posts the completion, including any extra result words.
3. **Would block:** io_uring retries from a helper thread that is allowed to sleep.

### Step 4: Copy the command before going async
The application may reuse a request slot as soon as submission returns. So a command that goes asynchronous can't keep pointing into the ring. Before that happens, io_uring copies the entry into the request itself and points the driver at the copy. The rules for exactly when this copy happens have been tightened several times after bugs where a reused slot was read.

### Step 5: Polled completion, no interrupts
On a polled ring, NVMe passthrough submits to a polled hardware queue. When the application asks for completions (or the SQPOLL thread runs), io_uring spins on the device's completion queue instead of waiting for an interrupt. There are no interrupts at all. This is the configuration behind the highest IOPS results.

### Step 6: Use registered buffers
A command can name a registered buffer, so the driver builds its I/O directly from pre-pinned pages with no per-command pinning. For ublk, the buffer can even be the kernel's own pages registered by the driver, which is the basis of ublk zero-copy.

### Step 7: Cancel long-lived commands
Some commands are meant to sit pending for a long time. A ublk "fetch request" waits until the block layer has I/O for the server. The driver marks those cancelable. When the ring is closed or a cancel is requested, io_uring calls the driver again with a "cancel" flag so it can complete them. Without this, a ring with pending ublk fetches could never be torn down.

## Who uses it

- **NVMe (5.19):** character devices that expose every namespace, including formats the block layer doesn't support, give asynchronous, batched access to any NVMe command. Driven by Kanchan Joshi and Anuj Gupta (Samsung). Performance approaches raw block-device I/O while skipping the block layer's generic request path.
- **ublk (6.0, Ming Lei):** a block driver implemented in user space. The server sends "fetch" commands that complete when the kernel has I/O for it, and answers with "commit and fetch". The whole control loop is uring_cmd.
- **Sockets (6.7):** queue-size queries, get/set socket options and timestamps, so event loops don't need synchronous calls for socket control.
- **FUSE over io_uring (6.14, Bernd Schubert):** the FUSE server exchanges requests and replies through per-CPU queues of commands instead of reading and writing a device file.
- **Others:** btrfs encoded reads, block-device discard, and virtio-blk passthrough (posted).

## Security

Passthrough bypasses the permission logic the generic paths get from the filesystem and block layers. NVMe itself requires admin rights for admin commands and checks the file's open mode for I/O commands.

The feature shipped (5.19) with no security-module hook, so SELinux and Smack couldn't police these commands at all. A hook was added in 6.0 by Luis Chamberlain and Paul Moore. The episode triggered a wider debate, covered by LWN, about whether new user-facing interfaces should be required to have security hooks from day one.

## The picture

```text
 application ─▶ ring entry (128 bytes): file, command number, payload
                     │
                     ▼
              io_uring: security check, hand to the file's driver
                     │
   ┌─────────────────┼──────────────────────┐
 done now        queued to hardware      would block
   │                 │ interrupt / poll        │
   │                 ▼                         ▼
   │        callback in submitter's      helper thread retries
   │        thread (task work)                 │
   └────────────────┬┴─────────────────────────┘
                    ▼
        completion (32 bytes: result + extra device result)

 drivers: NVMe char devices · ublk · sockets · FUSE · btrfs · block discard
```

## Tradeoffs

- **What it gives you:** asynchronous, batched, pollable access to any device's native commands, with new device features available immediately and without a new io_uring operation per command.
- **What it costs / requires:** io_uring can't validate payloads, so each driver must. Big entries are a ring-wide choice that doubles ring memory for every request on that ring, generic ones included. Mixed-size rings later let big and small entries share a ring.
- **Where it bites:** skipping the block layer's generic paths also skips I/O scheduling, cgroup I/O control and generic accounting, and pushes safety checks into the driver.

## How it got here

- **2021:** Jens Axboe's RFCs for a generic passthrough mechanism with a command area inside the request entry, adding no allocations or branches to the hot path.
- **5.19:** the passthrough operation, big entries, and NVMe passthrough.
- **6.0:** ublk, the security hook, and polled passthrough.
- **6.1–6.7:** registered buffers for passthrough, NVMe multipath, and socket commands.
- **6.12–6.15:** block discard, btrfs encoded reads, FUSE over io_uring, and ublk zero-copy.
- **2025–2026:** kernel-managed buffer rings for FUSE; BPF-based per-request extensions proposed as an alternative to growing driver command sets.

## Related

- Technical version: [[uring-cmd-passthrough]]
- [[io_uring-explained|io_uring]]: the subsystem overview
- [[registered-resources-explained|Registered resources]]: fixed and kernel-registered buffers
- [[io-uring-task-work-explained|Task work]]: how completions bounce to the submitter
- [[sqpoll-explained|SQPOLL]], [[io-wq-explained|io-wq]]
- [[ublk-explained|ublk]], [[fuse|FUSE]], [[block-explained|Block layer]], [[security|Security]]
