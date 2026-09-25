---
title: "FUSE Wire Protocol — Explained"
category: explained
original: "[[fuse-wire-protocol]]"
subsystem: fuse
tags: [explained, fuse, protocol, versioning, io_uring]
converted: 2026-09-25
---

# The FUSE wire protocol, explained

> Plain-language companion to [[fuse-wire-protocol|the technical note]]. Same facts, fewer identifiers.

## The problem

The kernel and a [[fuse-explained|FUSE]] daemon are separate programs that get upgraded separately: a 2026 kernel may talk to a daemon written in 2010, and vice versa. They need an exact, shared agreement on what bytes cross between them, or an upgrade on one side would silently corrupt the other. The agreement also has to let new features be added and advertised safely, let a multi-threaded daemon answer requests out of order, and let the kernel cancel requests and tear things down.

## The idea in one paragraph

Treat FUSE as a **remote procedure call** system whose "network" is the character device `/dev/fuse`. The kernel is always the client: it writes a binary request and sleeps until the daemon writes back a reply. Every request carries a **unique ID** so replies can arrive in any order and still find their caller. At mount time, an **init** handshake, rather like a TCP connection setup, fixes which protocol version and which optional features both sides will use for the life of the mount.

## Step by step

### Step 1: The channel
The daemon opens `/dev/fuse` and passes the descriptor to `mount`. From then on:
- the kernel **sends requests** by making them readable; a daemon thread calls `read` to take one
- the daemon **sends replies** by calling `write`

The daemon's read buffer must be at least a minimum size (8 KB in early kernels, raised later), or the read fails. Several daemon threads can block in `read` at once; each request goes to exactly one of them. Forget messages expect no reply.

### Step 2: Framing every message
Every request starts with a fixed 40-byte header: total length, **operation code**, unique ID, the target's **node ID**, and the caller's user, group and process IDs. The operation code decides what body follows. Node IDs are handles the daemon gave the kernel in earlier lookup replies; the root is always 1.

Every reply starts with a 16-byte header: length, an error code, and the same unique ID. A non-zero error means no body; the kernel returns that error to the waiting program. Zero means an operation-specific body follows.

### Step 3: The init handshake
This is the key step. The first message on every connection is **init**. The kernel sends its version (major 7, plus its minor), how much it may read ahead, and flag words listing every feature it supports. The daemon replies with its own version and flags, plus limits: maximum write size, timestamp granularity, background request limits, pages per request and, in newer versions, a request timeout.

The agreed minor version is the smaller of the two. A feature is on only if both sides flagged it. If major versions differ, the side with the higher one falls back. Neither side then uses anything newer than the agreed minor version. Structures only ever grow at the end, so each side copes with shorter versions: the kernel zero-fills fields an older daemon didn't send, and daemons ignore fields they don't know. This is what allows kernels and daemons to be upgraded independently.

Features negotiated this way include concurrent reads, POSIX locks, atomic truncate-on-open, writes over 4 KB, automatic cache invalidation, combined directory listing with attributes, write-back caching, POSIX ACLs, passthrough, and the io_uring transport.

### Step 4: The core operations
- **Lookup:** "what is *name* in directory *N*?" The reply gives the child's node ID, a generation number (together a unique identity), attributes, and how long they may be cached. Each successful lookup raises the kernel's count of references the daemon must keep.
- **Forget / batch forget:** no reply. "Drop *n* lookups of node *N*." When a node's count reaches zero, the daemon may free it. The batch form (2.6.36) carries many at once, avoiding a flood of messages when large directories are evicted.
- **Getattr:** current attributes plus how long they're valid.
- **Open / opendir:** the daemon returns an opaque 64-bit file handle used in later reads, writes, flushes and releases, plus flags (bypass the cache, keep the cache, not seekable, or pass through to a backing file).
- **Read:** file handle, offset and size; data comes back in the reply, and returning fewer bytes signals end of file.
- **Write:** the data travels inline after the request body; the reply says how many bytes were written, and short writes are allowed.
- **Interrupt:** "cancel request *U*". No reply; the daemon may answer the original with "interrupted" or finish it normally.
- **Destroy:** sent at unmount; the daemon flushes its state.
- **Readdirplus:** a directory listing where every entry carries full lookup results, so `ls -l` needs one round trip instead of one per file.

### Step 5: Notifications from the daemon
The daemon can also write unsolicited **notifications**, marked by a unique ID of 0 and a special code in the error field: wake a poll waiter, invalidate an inode's cached attributes or data, invalidate one directory entry, push data into the page cache, fetch data from it, announce a deletion, or ask the kernel to resend a request lost across an abort.

### Step 6: The io_uring transport (6.14, protocol 7.42)
The classic path costs two system calls and a context switch per request, and all daemon threads contend on one descriptor's lock. With io_uring:
1. the daemon registers per-CPU slots on its io_uring with a command aimed at the FUSE device
2. the kernel places each request straight into a slot and posts a completion
3. the daemon handles it and submits one command that both delivers the reply and re-arms the slot for the next request
4. each CPU has its own queue, so there's no cross-CPU contention

Interrupts and notifications still use classic reads and writes, so the daemon must keep servicing the device too. The two transports coexist.

## The picture

```text
 kernel ──read()──▶ daemon         [ len | opcode | unique | node | uid gid pid ] + body
 kernel ◀─write()── daemon         [ len | error  | unique ] + body (if error = 0)
                                   [ len | NOTIFY | unique = 0 ] + body   (daemon → kernel)

 INIT:  kernel {7.x, features}  ⇄  daemon {7.y, features, limits}
        agreed = min(x, y);  features on only if both flagged

 io_uring: per-CPU slot ─ request lands ─ commit reply + fetch next (one command)
```

## Tradeoffs

- **What it gives you:** independent upgrades on both sides, out-of-order replies, cancellation, and a public format that libraries in C, Go, Rust and Python all implement.
- **What it costs / requires:** daemons must get lookup/forget counting exactly right; the classic path copies all data in and out of the kernel (passthrough avoids this for file data); every structure change needs careful handling of shorter versions.
- **Where it bites:** forget has no acknowledgement, so the kernel can't tell when a node was really freed, making daemon-side leaks hard to debug. The single device lock throttles metadata-heavy workloads like `ls -lR` on the classic transport.

## How it got here

- **2.6.14 (2005):** protocol 7 debuts with init and basic file operations.
- **2.6.17–2.6.20:** flag-based feature negotiation, interrupts and POSIX lock forwarding, making FUSE viable for POSIX-compliant filesystems.
- **2.6.36:** batched forgets. **3.9:** readdirplus, opt-in so daemons returning wrong attributes in plain listings didn't break.
- **3.15:** write-back caching and nanosecond timestamps.
- **6.6:** passthrough, where the daemon hands the kernel a backing file and data skips the protocol entirely.
- **6.14:** the io_uring transport, the biggest structural change since the start; minor version 7.45 is the latest as of 2026.

## Related

- Technical version: [[fuse-wire-protocol]]
- [[fuse-explained|FUSE subsystem]], [[fuse-connection-explained|Connection]], [[fuse-request-queue-explained|Request queue]], [[fuse-vfs-integration-explained|VFS integration]]
- [[io_uring-explained|io_uring]], [[uring-cmd-passthrough-explained|io_uring command passthrough]], [[page-cache-explained|Page cache]]
