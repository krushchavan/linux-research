---
title: "FUSE Wire Protocol"
category: concept
tags: [fuse, filesystems, userspace, ipc, protocol]
subsystem: fuse
kernel_version: "2.6.14"
researched: 2026-04-10
status: complete
sources:
  - https://john-millikin.com/the-fuse-protocol
  - https://www.man7.org/linux/man-pages/man4/fuse.4.html
  - https://github.com/libfuse/libfuse/blob/master/include/fuse_kernel.h
  - https://nuetzlich.net/the-fuse-wire-protocol/
  - https://www.kernel.org/doc/html/next/filesystems/fuse/fuse-io-uring.html
  - https://lwn.net/Articles/997400/
  - https://lwn.net/Articles/68104/
---

# FUSE Wire Protocol

## Purpose

The FUSE wire protocol is the binary message format and exchange rules that govern all communication between the kernel FUSE driver and a userspace filesystem daemon. Without a well-defined, versioned wire format, neither side could safely evolve independently — kernel upgrades would silently corrupt running daemons and new daemon features could never be safely advertised to older kernels. The protocol defines exactly what bytes flow through `/dev/fuse` in both directions, how capabilities are negotiated at mount time, and how cancellation and teardown are handled.

## Mental Model

Think of FUSE as a remote procedure call system where the "network" is a character device (`/dev/fuse`). The kernel is always the client: it encodes an operation as a binary message, writes it into the device, and then sleeps until the daemon writes a reply back. Every message pair is identified by a `unique` request ID so that a multi-threaded daemon can process requests out of order and the kernel can still match each reply to the waiting caller. The `FUSE_INIT` handshake at mount time is the TCP-style "SYN/SYN-ACK" that establishes which version of the protocol and which optional features both sides will use for the lifetime of the mount.

## How It Works

### The /dev/fuse Device Channel

Every FUSE mount is backed by an open file descriptor on `/dev/fuse`. The kernel registers the mount with the fd as its communication endpoint — this fd is what the daemon passes to `mount(2)` via the `fd=N` mount option. From that point on, the protocol flows as a half-duplex byte stream:

- The **kernel sends requests** by making them readable on the fd. The daemon calls `read(fd, buf, size)` to dequeue a pending request.
- The **daemon sends replies** by calling `write(fd, buf, size)` with a response buffer.

The minimum read buffer size the daemon must use is `FUSE_MIN_READ_BUFFER` (8192 bytes in early kernels, later raised to accommodate large scatter-gather writes). If the daemon supplies too small a buffer, the kernel returns `EIO`. A multi-threaded daemon can have multiple threads all blocking on `read()` simultaneously; the kernel delivers each request to exactly one reader.

For `FUSE_FORGET` and `FUSE_BATCH_FORGET`, the kernel does not expect a reply — the daemon simply discards after reading.

### Message Framing: fuse_in_header and fuse_out_header

Every kernel-to-daemon message is prefixed with `fuse_in_header` (`include/uapi/linux/fuse.h`):

```c
struct fuse_in_header {
    uint32_t len;       /* total size of this message (header + body) */
    uint32_t opcode;    /* operation code from enum fuse_opcode */
    uint64_t unique;    /* unique request ID, never reused while in-flight */
    uint64_t nodeid;    /* inode/object ID this operation targets */
    uint32_t uid;       /* UID of the requesting process */
    uint32_t gid;       /* GID of the requesting process */
    uint32_t pid;       /* PID of the requesting process */
    uint16_t total_extlen; /* total extension length in 8-byte units (v7.40+) */
    uint16_t padding;
};
```

The `opcode` field selects which operation-specific body structure follows the header. The `nodeid` is the kernel's internal inode handle — the daemon assigned these IDs to the kernel during earlier `FUSE_LOOKUP` or `FUSE_INIT` replies and must remember the mapping. The root directory is always `nodeid = 1`.

Every reply the daemon sends begins with `fuse_out_header`:

```c
struct fuse_out_header {
    uint32_t len;     /* total size of reply (header + body) */
    int32_t  error;   /* 0 for success, negative errno for failure */
    uint64_t unique;  /* must match the request's unique field */
};
```

If `error` is non-zero the reply has no payload — the kernel reads the error code and wakes the blocked caller with that errno. If `error` is zero, an opcode-specific response body follows immediately.

### FUSE_INIT: Capability Negotiation

Before any filesystem operation can be processed, the kernel sends a `FUSE_INIT` request. This is always the very first message on a new connection and must be handled before any other request. The request body is `fuse_init_in`:

```c
struct fuse_init_in {
    uint32_t major;        /* kernel's major protocol version (always 7) */
    uint32_t minor;        /* kernel's minor protocol version */
    uint32_t max_readahead;/* max bytes the kernel will readahead */
    uint32_t flags;        /* capability flags the kernel supports */
    uint32_t flags2;       /* extended capability flags (v7.36+) */
    uint32_t unused[11];
};
```

The daemon replies with `fuse_init_out`, which intersects capabilities:

```c
struct fuse_init_out {
    uint32_t major;
    uint32_t minor;
    uint32_t max_readahead;
    uint32_t flags;           /* capability flags both sides agree on */
    uint16_t max_background;  /* max concurrent background requests */
    uint16_t congestion_threshold; /* threshold to start returning EAGAIN */
    uint32_t max_write;       /* max write size daemon will accept */
    uint32_t time_gran;       /* timestamp granularity in nanoseconds */
    uint16_t max_pages;       /* max scatter-gather pages per request */
    uint16_t map_alignment;   /* alignment for mmap (v7.28+) */
    uint32_t flags2;
    uint32_t max_stack_depth; /* for passthrough stacking (v7.40+) */
    uint32_t request_timeout; /* in 1/10 sec units, 0 = disabled (v7.41+) */
    uint32_t unused[5];
};
```

Version negotiation works as follows: the negotiated minor version is `min(kernel_minor, daemon_minor)`. If the kernel's major version is larger than the daemon supports, the kernel re-sends `FUSE_INIT` conforming to the daemon's major. If the daemon's major is larger, it quietly falls back to the kernel's major. Neither side sends features requiring a higher minor than was negotiated.

The `flags` field performs capability OR-intersection — a feature is active only if both sides advertise it. Key capability flags include:

| Flag | Minor | Effect |
|------|-------|--------|
| `FUSE_ASYNC_READ` | 7.6 | Multiple concurrent read requests allowed |
| `FUSE_POSIX_LOCKS` | 7.7 | POSIX advisory locks forwarded to daemon |
| `FUSE_ATOMIC_O_TRUNC` | 7.9 | `O_TRUNC` handled in `FUSE_OPEN` atomically |
| `FUSE_BIG_WRITES` | 7.10 | Writes > 4 KiB supported |
| `FUSE_AUTO_INVAL_DATA` | 7.20 | Kernel auto-invalidates page cache |
| `FUSE_DO_READDIRPLUS` | 7.21 | Kernel may use `FUSE_READDIRPLUS` opcode |
| `FUSE_WRITEBACK_CACHE` | 7.23 | Write-back caching; kernel batches dirty pages |
| `FUSE_POSIX_ACL` | 7.26 | Kernel enforces POSIX ACLs |
| `FUSE_PASSTHROUGH` | 7.40 | Direct I/O bypass via backing fd |
| `FUSE_OVER_IO_URING` | 7.42 | Daemon may use io_uring channel (6.14+) |

### Core Opcodes and Their Message Bodies

The opcode defines the body that follows `fuse_in_header`. The most important operations:

**FUSE_LOOKUP (1)** — The kernel needs a nodeid for a name inside a parent directory. The request body is just a null-terminated filename string. The daemon replies with `fuse_entry_out` which contains the `nodeid`, a `generation` counter (nodeid + generation form a globally unique inode identity), attribute validity timeouts, and a full `fuse_attr`. Every time the kernel successfully resolves a name, it increments an internal `nlookup` counter for that inode; the daemon must not free the nodeid until the kernel has balanced those lookups with FORGET messages.

**FUSE_FORGET (2) / FUSE_BATCH_FORGET (42)** — These have no reply. `FUSE_FORGET` carries `fuse_forget_in { uint64_t nlookup; }` — the daemon decrements its lookup counter by that amount. When it reaches zero the daemon may reclaim resources for the nodeid. `FUSE_BATCH_FORGET` (v7.16+) sends a count followed by an array of `fuse_forget_one { nodeid, nlookup }` pairs, reducing per-forget syscall overhead for directories with many stale entries.

**FUSE_GETATTR (3)** — Returns current `fuse_attr` for the inode, plus `attr_valid` timeout seconds. The kernel caches attributes for at most `attr_valid` seconds before re-issuing GETATTR.

**FUSE_OPEN (14) / FUSE_OPENDIR (27)** — `fuse_open_in { flags, open_flags }` maps to an `open(2)`. The daemon allocates an opaque 64-bit file handle and returns it in `fuse_open_out { fh, open_flags }`. Subsequent READ/WRITE/FLUSH/RELEASE messages carry `fh` rather than looking up the inode again. `open_flags` can set `FOPEN_DIRECT_IO` (bypass page cache for this open), `FOPEN_KEEP_CACHE` (do not invalidate page cache), `FOPEN_NONSEEKABLE`, or `FOPEN_PASSTHROUGH` (back reads/writes directly through a kernel fd).

**FUSE_READ (15)** — `fuse_read_in { fh, offset, size, read_flags, lock_owner, flags }`. The daemon copies data into the reply buffer. Returning fewer bytes than `size` signals EOF; returning zero bytes at a non-zero offset is the standard EOF indicator.

**FUSE_WRITE (16)** — `fuse_write_in { fh, offset, size, write_flags, lock_owner, flags }` is followed immediately by `size` bytes of data inline in the request buffer. The daemon responds with `fuse_write_out { size }` — how many bytes were actually written; a short write is valid.

**FUSE_INTERRUPT (36)** — If the kernel wants to cancel an in-flight request (because the waiting process received a signal), it sends `fuse_interrupt_in { unique }` where `unique` matches the request to cancel. There is no reply to an INTERRUPT. The daemon may respond to the original request with `-EINTR` or finish it normally — both are accepted.

**FUSE_DESTROY (38)** — Sent when the filesystem is being unmounted. The daemon should flush all state and may reply with no payload. After DESTROY the connection is closed.

**FUSE_READDIRPLUS (44)** — Like `FUSE_READDIR` but each directory entry in the reply includes a full `fuse_entry_out` so the kernel can populate its dcache and attr cache in one round trip instead of issuing a LOOKUP per entry.

### Kernel-Initiated Notifications (Reverse Channel)

Besides replies, the daemon can also receive unsolicited **notify** messages from the kernel. These are normal `fuse_out_header`-prefixed writes with `unique = 0` and `error` set to a negative `FUSE_NOTIFY_*` code:

- `FUSE_NOTIFY_POLL` — wake a poll waiter
- `FUSE_NOTIFY_INVAL_INODE` — invalidate cached attributes/data for a nodeid
- `FUSE_NOTIFY_INVAL_ENTRY` — invalidate a specific dentry (nodeid + name)
- `FUSE_NOTIFY_STORE` — push data into the page cache for a nodeid
- `FUSE_NOTIFY_RETRIEVE` — pull data from the page cache (daemon reads from kernel)
- `FUSE_NOTIFY_DELETE` — inode has been deleted; remove from kernel cache
- `FUSE_NOTIFY_RESEND` — re-deliver a request that was lost across an abort (v7.40+)

Notifications travel in the write direction (daemon → kernel) and use the fd just like replies; the `unique = 0` sentinel distinguishes them from replies.

### Protocol Versioning History

The protocol lives at major version 7 since Linux 2.6.14 (2005). The minor version has incremented with each kernel that added new operations or structures:

| Minor | Kernel | Key additions |
|-------|--------|---------------|
| 7.2 | 2.6.14 | Initial stable release |
| 7.6 | 2.6.17 | `FUSE_INIT` flags, `max_readahead` |
| 7.7 | 2.6.18 | `FUSE_INTERRUPT`, POSIX locks |
| 7.9 | 2.6.20 | `FUSE_ATOMIC_O_TRUNC`, `blksize` in attr |
| 7.10 | 2.6.21 | `FUSE_BIG_WRITES` |
| 7.12 | 2.6.26 | `FUSE_IOCTL`, `FUSE_POLL` |
| 7.13 | 2.6.27 | `max_background`, `congestion_threshold` |
| 7.16 | 2.6.36 | `FUSE_BATCH_FORGET` |
| 7.18 | 3.0 | `FUSE_FALLOCATE` |
| 7.21 | 3.9 | `FUSE_READDIRPLUS`, `FUSE_RENAME2` |
| 7.23 | 3.15 | Writeback cache, nanosecond timestamps |
| 7.26 | 4.6 | `FUSE_POSIX_ACL` |
| 7.31 | 4.20 | `FUSE_LSEEK` |
| 7.34 | 5.10 | `FUSE_COPY_FILE_RANGE` |
| 7.36 | 5.13 | `flags2` field for extended capabilities |
| 7.40 | 6.6 | `FUSE_PASSTHROUGH`, `FUSE_NOTIFY_RESEND` |
| 7.42 | 6.14 | `FUSE_OVER_IO_URING`, io_uring transport |
| 7.45 | current | Latest (as of 2026) |

### FUSE-over-io_uring (v7.42 / Linux 6.14)

The classical `/dev/fuse` read/write path requires two syscalls per request (one read, one write) and a context switch per operation. For high-throughput workloads this overhead is significant.

Starting with Linux 6.14 and protocol v7.42, a daemon that negotiated `FUSE_OVER_IO_URING` can switch to an io_uring channel. The setup:

1. The daemon creates an io_uring instance and submits `IORING_OP_URING_CMD` SQEs targeting the `/dev/fuse` fd with sub-command `FUSE_URING_REQ_REGISTER` — these register per-CPU ring buffer slots the kernel can use to land requests.
2. The kernel receives a FUSE request; instead of enqueueing it for `read()`, it DMA-places it into a pre-registered ring slot and posts a CQE.
3. The daemon processes the CQE/request and submits the result via `FUSE_URING_REQ_COMMIT_AND_FETCH` — this both delivers the reply and re-registers the slot for the next request, all in one SQE.
4. Each CPU core has its own io_uring queue, eliminating cross-CPU contention on the single `/dev/fuse` fd lock.

Crucially, the daemon **must still service `/dev/fuse` via classical read/write** for notifications and interrupts — io_uring carries only normal request/reply traffic. The two transports coexist on the same connection.

## Key Data Structures

**`struct fuse_in_header`** (`include/uapi/linux/fuse.h`) — Fixed 40-byte prefix of every kernel-to-daemon message.
- `opcode` — selects the operation and the body struct that follows
- `unique` — monotonically increasing request ID; used to match replies; never zero
- `nodeid` — the kernel's handle for the target inode; assigned by the daemon during lookup

**`struct fuse_out_header`** (`include/uapi/linux/fuse.h`) — Fixed 16-byte prefix of every daemon-to-kernel reply.
- `error` — if non-zero, no payload follows; the kernel propagates this as `-errno` to the syscall

**`struct fuse_init_in` / `fuse_init_out`** — Negotiation structs; fields are additive across minor versions (earlier daemons send/receive shorter structs; the kernel zero-fills missing fields).

**`struct fuse_attr`** — The kernel's in-protocol representation of `struct stat`: inode, size, atime/mtime/ctime with nanosecond precision, mode, nlink, uid, gid, rdev, blksize.

**`struct fuse_entry_out`** — Wraps `fuse_attr` with `nodeid`, `generation`, and cache-validity timeouts (`attr_valid`, `entry_valid` in seconds and nanoseconds). Returned by LOOKUP and READDIRPLUS.

**`enum fuse_opcode`** — Defines all valid opcode values (1–53 as of v7.45). Gaps in the numbering reflect removed or reserved codes.

## Key Functions / Entry Points

**`fuse_dev_read()` / `fuse_dev_do_read()`** (`fs/fuse/dev.c`) — Called when the daemon reads from `/dev/fuse`; dequeues the next pending request from `fuse_conn.pending` and copies the `fuse_in_header` + body to userspace.

**`fuse_dev_write()` / `fuse_dev_do_write()`** (`fs/fuse/dev.c`) — Called when the daemon writes a reply; matches `unique` against the in-flight hash, unmarshals the response, and wakes the blocked kernel caller.

**`fuse_simple_request()`** (`fs/fuse/dev.c`) — The main kernel-side entry point for issuing a synchronous FUSE request; allocates a `fuse_req`, fills in the `fuse_in_header`, enqueues it, and sleeps until a reply arrives.

**`fuse_request_send_background()`** — Variant for fire-and-forget requests (FORGET, async writes).

**`fuse_conn_init()`** (`fs/fuse/inode.c`) — Initialises a new `fuse_conn` including the version fields; called at mount time just before the kernel sends `FUSE_INIT`.

## Important Flags & Config Options

**`max_background` / `congestion_threshold`** (negotiated in `FUSE_INIT`) — `max_background` caps concurrent background (async) requests before the kernel starts blocking new ones. `congestion_threshold` is the level at which the kernel marks the backing device as congested (affecting writeback pressure). Typical defaults: 12 / 9.

**`max_write`** — Negotiated maximum write payload; daemon should set this to the largest contiguous buffer it can handle. Larger values reduce write fragmentation.

**`time_gran`** — Nanoseconds between representable timestamps. A value of 1 means full nanosecond precision; 1000000000 means 1-second granularity (FAT-like).

**`FUSE_MAX_MAX_PAGES`** — Kernel compile-time limit (256) on scatter-gather pages per request, controlling the maximum effective `max_write`.

**`/sys/fs/fuse/connections/<conn-id>/`** — Per-connection sysfs directory exposing `waiting` (pending requests), `abort` (emergency teardown trigger), and `max_background`.

## Interactions with Other Subsystems

- **↑ Userspace**: The daemon reads/writes `/dev/fuse`. Any process with the correct permissions can implement the protocol — libfuse is the dominant library but the wire format is public. Go (bazil/fuse), Rust (fuser), and Python bindings all implement the same binary protocol.
- **→ VFS**: Every VFS operation on a FUSE-backed inode eventually calls a `fuse_*` operation (e.g. `fuse_lookup`, `fuse_read_iter`) which encodes a wire message. The VFS blocks the calling process until the daemon replies.
- **→ Page cache**: Operations like `FUSE_READ` and `FUSE_WRITE` interact with the page cache. With `FUSE_WRITEBACK_CACHE`, the kernel can coalesce dirty pages before issuing a single large `FUSE_WRITE`, reducing protocol round trips.
- **→ io_uring** (v7.42+): `FUSE_OVER_IO_URING` replaces the read/write device interface with `IORING_OP_URING_CMD` submission/completion, reducing syscall overhead at high request rates.
- **← [[fuse-connection]]**: `struct fuse_conn` holds the negotiated protocol parameters (minor version, flags, max_write) and is the kernel object that owns the fd.
- **← [[fuse-request-queue]]**: The queuing layer is what serialises concurrent kernel-side callers into the ordered stream that flows over the wire.

## Design Decisions & Tradeoffs

**Opaque nodeids assigned by the daemon**: The kernel never allocates inode IDs — the daemon does and hands them to the kernel via LOOKUP replies. This gives the daemon full control over its inode namespace and avoids any kernel-side inode table. The cost is the `nlookup` reference-counting protocol: the kernel must send FORGET messages when it drops cached dentries to prevent nodeid leaks. This is a source of correctness bugs in daemon implementations.

**No mandatory ACK for FORGET**: FORGET has no reply. This simplifies daemon implementation (no need to send a response) but means the kernel cannot know when the daemon has actually freed the nodeid. In practice this is safe because the kernel only recycles inode slots after all kernel-side references are gone, but it makes debugging nodeid leaks harder.

**Minor versions as independent variants, not SemVer**: Each minor version increment can add incompatible struct fields (the `fuse_init_out` struct has grown across every major kernel release). Both sides must be prepared to handle structs shorter than they expect. The kernel zeroes out fields the daemon didn't send; the daemon must ignore fields it doesn't recognise. This design allows rolling kernel/daemon upgrades with no hard coupling.

**Single `/dev/fuse` fd serialises all request reads**: With the classical transport, all daemon threads contend on a single fd lock when calling `read()`. For workloads that issue many small concurrent filesystem operations (e.g. `ls -lR` on a large tree), this becomes a bottleneck. The `FUSE_OVER_IO_URING` per-CPU queue design directly solves this, but at the cost of requiring a modern kernel and a more complex daemon.

**No zero-copy on the classical path**: The kernel copies request data from kernel memory into the daemon's `read()` buffer, and reply data from the daemon's `write()` buffer back into kernel memory. For large reads/writes this is two extra copies. `FUSE_PASSTHROUGH` avoids the copy for I/O by having the daemon expose a backing fd that the kernel reads/writes directly.

## How It Has Evolved

The protocol debuted in Linux 2.6.14 (2005) as a relatively minimal design: `FUSE_INIT`, basic file operations, and a clean separation of kernel and daemon concerns. The major expansions:

- **2.6.17–2.6.20**: Added the flag-based capability negotiation (`FUSE_INIT` flags), interrupts (`FUSE_INTERRUPT`), and POSIX lock forwarding — making FUSE viable for POSIX-compliant filesystems.
- **2.6.36**: `FUSE_BATCH_FORGET` reduced the syscall storm that occurred when evicting large directories; previously each dentry eviction sent a separate FORGET.
- **3.9**: `FUSE_READDIRPLUS` collapsed READDIR + per-entry LOOKUP into a single round trip, dramatically reducing latency for `ls -l` style operations.
- **3.15**: Write-back caching (`FUSE_WRITEBACK_CACHE`) let the kernel aggregate dirty pages before flushing, matching the behaviour of local filesystems and improving write throughput.
- **6.6**: `FUSE_PASSTHROUGH` enabled a new mode where the daemon hands the kernel a backing fd, bypassing the wire protocol for data reads and writes entirely — motivated by Lustre and QEMU virtio-fs performance requirements.
- **6.14**: `FUSE_OVER_IO_URING` replaced the bottleneck-prone single-fd read/write transport with per-CPU io_uring queues, the largest structural change to the wire protocol since its initial design.

## Further Reading

1. [The FUSE Protocol — john-millikin.com](https://john-millikin.com/the-fuse-protocol) — the most complete unofficial protocol reference; covers every opcode and version delta.
2. [fuse(4) man page — man7.org](https://www.man7.org/linux/man-pages/man4/fuse.4.html) — canonical reference for the device interface and message structures.
3. [FUSE-over-io-uring design — kernel.org](https://www.kernel.org/doc/html/next/filesystems/fuse/fuse-io-uring.html) — official documentation for the v7.42 io_uring transport.
4. [fuse: fuse-over-io-uring — LWN](https://lwn.net/Articles/997400/) — LWN coverage of the io_uring patchset with community discussion.
5. [FUSE — implementing filesystems in user space — LWN](https://lwn.net/Articles/68104/) — original 2004 introductory article; useful for historical context.
6. [libfuse/fuse_kernel.h — GitHub](https://github.com/libfuse/libfuse/blob/master/include/fuse_kernel.h) — the authoritative header defining all structs and opcodes; always up to date with the latest minor version.
7. [The FUSE Wire Protocol — nuetzlich.net](https://nuetzlich.net/the-fuse-wire-protocol/) — annotated walkthrough of the message format.

## LKML Highlights

- **[FUSE_BATCH_FORGET]** `<20100723...>` — Miklos Szeredi's v2.6.36 patch consolidating individual FORGET messages; the discussion quantified the syscall-rate improvement on large directory evictions and established the no-reply convention for FORGET.
- **[FUSE_READDIRPLUS]** `<20130315...>` — The READDIRPLUS patchset debate centred on whether the kernel should opportunistically use READDIRPLUS or require the daemon to opt in via `FUSE_DO_READDIRPLUS`; the opt-in model won to avoid breaking existing daemons that returned incorrect inode attributes in READDIR.
- **[FUSE-over-io-uring RFC v3]** `20240901-b4-fuse-uring-rfcv3-without-mmap-v3-0-9207f7391444@ddn.com` — DDN's RFC that became the v7.42 io_uring transport; the thread debated whether per-CPU queues or a shared ring was more appropriate and whether the classical `/dev/fuse` fallback should remain mandatory (it did, for notifications).
