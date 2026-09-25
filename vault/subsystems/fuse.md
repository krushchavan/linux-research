---
title: "FUSE (Filesystem in USErspace)"
category: subsystem
tags: [fuse, filesystem, userspace, vfs, character-device]
maintainer: Miklos Szeredi
mailing_list: linux-fsdevel@vger.kernel.org
source_path: fs/fuse/
researched: 2026-04-05
status: complete
explained: "[[fuse-explained]]"
sources:
  - https://lwn.net/Articles/118574/
  - https://lwn.net/Articles/68104/
  - https://lwn.net/Articles/932079/
  - https://lwn.net/Articles/937433/
  - https://static.lwn.net/kerneldoc/filesystems/fuse.html
  - https://john-millikin.com/the-fuse-protocol
  - https://blogs.oracle.com/linux/an-overview-of-fuse-and-libfuse
---

# FUSE (Filesystem in USErspace) Subsystem

> 📘 Plain-language version: [[fuse-explained]]

## Overview

FUSE allows unprivileged programs to implement fully functional filesystems entirely in userspace. The kernel FUSE module intercepts VFS calls (lookup, read, write, readdir, etc.), serialises them into a request protocol over the `/dev/fuse` character device, and blocks the calling process until the userspace daemon replies. This enables filesystems like SSHFS (network via SSH), overlayfs-in-userspace, and database virtual filesystems to be built and deployed without kernel modifications.

## Mental Model

FUSE is a **synchronous RPC channel** between the kernel and a userspace daemon, dressed up as a filesystem. Every VFS operation becomes a message sent from the kernel to the daemon and a reply sent back. The `/dev/fuse` device is the pipe: the kernel writes requests to it; the daemon reads them, does the work (stat calls, network IO, database queries), and writes responses. The calling process is blocked during this round-trip, exactly as it would be blocked waiting for a disk read in a traditional filesystem.

## Architecture

```mermaid
flowchart TD
    APP["Application\n(open/read/write/stat)"]
    VFS["VFS Layer\n(namei, file ops)"]
    FUSE_K["FUSE Kernel Module\n(fs/fuse/)"]
    DEV["/dev/fuse\ncharacter device"]
    LIB["libfuse\nuserspace library"]
    DAEMON["Filesystem Daemon\n(sshfs, overlayfs, etc.)"]

    APP -->|syscalls| VFS
    VFS -->|fuse_inode ops| FUSE_K
    FUSE_K -->|enqueue request| DEV
    DEV -->|read()| LIB
    LIB -->|dispatch callback| DAEMON
    DAEMON -->|result| LIB
    LIB -->|write() response| DEV
    DEV -->|wake caller| FUSE_K
    FUSE_K -->|return to VFS| VFS
```

The kernel module registers as a filesystem type (`fuse`, `fuseblk`), mounts with the connection's `/dev/fuse` fd, and implements all VFS inode/file/dentry operations by forwarding them as FUSE protocol messages. Libfuse on the daemon side handles protocol framing; the daemon provides callbacks for each operation.

---

## Core Components

### [[fuse-connection]]

**Purpose** — A `fuse_conn` ties together the kernel-side state for one mounted FUSE filesystem: the request queues, capability flags negotiated at init time, and the reference to the `/dev/fuse` file. Without it there would be no place to coordinate concurrent requests from multiple processes.

**How it works** — When a FUSE filesystem is mounted, `fuse_get_tree()` opens the `/dev/fuse` device and creates a `fuse_conn`. Before the first real filesystem operation, the daemon sends a `FUSE_INIT` handshake: it proposes a protocol version and a bitmask of supported capabilities (`FUSE_ASYNC_READ`, `FUSE_WRITEBACK_CACHE`, `FUSE_PARALLEL_DIROPS`, etc.); the kernel replies with the intersection of what both sides understand. This negotiation is recorded in `fuse_conn.flags` and governs every subsequent operation.

```c
struct fuse_conn {
    spinlock_t          lock;
    atomic_t            count;         /* mount reference count */
    atomic_t            dev_count;     /* open /dev/fuse count */
    struct fuse_dev     *dev;          /* the /dev/fuse device */

    /* Request queues */
    struct fuse_iqueue  iq;            /* incoming (pending) queue */
    struct fuse_pqueue  pq;            /* processing (in-flight) queue */

    /* Negotiated capabilities */
    unsigned            flags;
    unsigned            max_read;
    unsigned            max_write;
    unsigned            max_pages;

    /* Connection state */
    unsigned            connected:1;
    unsigned            aborted:1;
    ...
};
```

**Key functions**:
- `fuse_conn_init()` — initialises queues, waitqueues, and default parameters
- `fuse_send_init()` — sends `FUSE_INIT` and processes the daemon's reply
- `fuse_conn_put()` — decrements refcount; frees the conn when it hits zero

---

### [[fuse-request-queue]]

**Purpose** — FUSE must handle concurrent VFS operations from multiple processes, each potentially blocking while the daemon works. Five separate queues sequence requests by priority and state without requiring a global lock on the hot path.

**How it works** — The `fuse_iqueue` (incoming queue) holds requests that have not yet been delivered to the daemon. It contains five sub-lists:

| Queue | Purpose |
|---|---|
| `interrupts` | `FUSE_INTERRUPT` requests; highest priority, served before any other |
| `forgets` | `FUSE_FORGET` (inode nlookup decrements); batched into `FUSE_BATCH_FORGET` |
| `pending` | Normal requests waiting to be read by the daemon |
| `processing` | Requests that have been read by the daemon but not yet replied to |
| `io` | Requests currently being copied in/out via read/write on `/dev/fuse` |

When the daemon calls `read()` on `/dev/fuse`, `fuse_dev_read()` dequeues the highest-priority request: interrupt requests first, then forget batches (up to a throttle limit), then pending. The request moves from `pending` to `processing`. When the daemon calls `write()` with a reply, `fuse_dev_write()` finds the matching request by `unique` ID and wakes the blocked kernel thread.

**Key struct**: `struct fuse_req` (`fs/fuse/fuse_i.h`)
- `in` / `out` — `fuse_args` describing request and response buffers
- `unique` — unique ID assigned at request creation; echoed in the response
- `waitq` — waitqueue for the blocking kernel thread
- `flags` — `FR_PENDING`, `FR_SENT`, `FR_FINISHED`, `FR_INTERRUPTED`, etc.

**Key functions**:
- `fuse_get_req()` — allocates a `fuse_req` from the slab cache and assigns a unique ID
- `fuse_request_send()` — enqueues and blocks until the reply arrives (synchronous path)
- `fuse_dev_read()` / `fuse_dev_write()` — the daemon's read/write handlers on `/dev/fuse`

---

### [[fuse-wire-protocol]]

**Purpose** — A stable, versioned binary protocol lets kernel and daemon evolve independently. The protocol version is negotiated at mount time; new opcodes are added but old ones are never removed.

**How it works** — Every message begins with a standard header:

```c
/* Kernel → Daemon (request) */
struct fuse_in_header {
    uint32_t  len;      /* total message size */
    uint32_t  opcode;   /* FUSE_LOOKUP, FUSE_READ, FUSE_WRITE, ... */
    uint64_t  unique;   /* correlation ID */
    uint64_t  nodeid;   /* target inode's nodeid */
    uint32_t  uid;      /* caller's UID */
    uint32_t  gid;
    uint32_t  pid;
    uint16_t  total_extlen;
    uint16_t  padding;
};

/* Daemon → Kernel (response) */
struct fuse_out_header {
    uint32_t  len;
    int32_t   error;    /* 0 = success, negative errno on error */
    uint64_t  unique;   /* must match the request */
};
```

After the header, each opcode has its own body struct. For example, `FUSE_LOOKUP` carries a filename string in the request and a `fuse_entry_out` (inode attributes + generation + TTLs) in the response.

Opcodes range from basic VFS operations (`FUSE_GETATTR=3`, `FUSE_SETATTR=4`, `FUSE_OPEN=14`, `FUSE_READ=15`, `FUSE_WRITE=16`, `FUSE_READDIR=28`) to advanced features (`FUSE_COPY_FILE_RANGE=47`, `FUSE_SETUPMAPPING=48` for DAX, `FUSE_URING_CMD` for io_uring).

Protocol versioning: the current major version is 7 (since 2008); the minor version increments with each new opcode. During `FUSE_INIT` the kernel proposes its version; the daemon responds with the version it will use. If the daemon is older, the kernel adapts by not sending opcodes the daemon doesn't understand (falling back to VFS defaults).

**Config & flags** — `FUSE_CAP_ASYNC_READ`, `FUSE_CAP_WRITEBACK_CACHE`, `FUSE_CAP_PARALLEL_DIROPS`, `FUSE_CAP_POSIX_LOCKS`, `FUSE_CAP_READDIRPLUS` — capability bits negotiated at `FUSE_INIT` that enable optional protocol features.

---

### [[fuse-vfs-integration]]

**Purpose** — Maps every Linux VFS inode/file/dentry/superblock operation to the corresponding FUSE opcode, making a FUSE mount indistinguishable from a kernel filesystem from the VFS's perspective.

**How it works** — FUSE registers `fuse_file_system_type` with the VFS. On mount, `fuse_fill_super()` sets up the superblock with FUSE-specific `super_operations`, creates the root inode (nodeid = 1), and registers `fuse_inode_operations` and `fuse_file_operations`. These operation tables contain thin wrappers that:

1. Allocate a `fuse_req` with the appropriate opcode.
2. Fill the request body from the VFS arguments (e.g. for `lookup`: the parent nodeid + name string).
3. Call `fuse_request_send()` (or the async variant).
4. Translate the response back to VFS types (e.g. `fuse_entry_out` → inode attributes → `struct kstat`).

FUSE inodes are `fuse_inode` structs (embedding `struct inode`) that store the daemon's `nodeid`, `generation`, attribute TTLs, and a lock for invalidation. The `fuse_inode.attr_version` counter tracks when the VFS cached attributes need refreshing.

Attribute TTLs (`entry_timeout`, `attr_timeout` from `fuse_entry_out` / `fuse_attr_out`) allow the kernel to cache inode attributes and dentry validity for a configurable duration, avoiding a FUSE round-trip on every stat call.

**Key struct**: `struct fuse_inode` (`fs/fuse/fuse_i.h`)
- `nodeid` — the daemon's identifier for this inode (stable across lookups)
- `generation` — combined with nodeid to form a globally unique inode reference
- `attr_version` — bumped on every attribute update; used to detect stale caches
- `i_time` — expiry time for cached attributes

**Key functions**:
- `fuse_lookup()` → sends `FUSE_LOOKUP`; creates/updates dentry and inode from response
- `fuse_getattr()` → sends `FUSE_GETATTR` if the cached `attr_timeout` has expired
- `fuse_readpages()` / `fuse_writepages()` → batch read/write via `FUSE_READ` / `FUSE_WRITE`

---

### [[fuse-interruption-and-abort]]

**Purpose** — A blocked VFS caller (waiting for the FUSE daemon to reply) must be interruptible by signals and by administrator abort, otherwise a crashed or deadlocked daemon would leave kernel threads stuck permanently.

**How it works** — All FUSE requests are submitted to `fuse_request_send()` with the task in `TASK_INTERRUPTIBLE` state. If the task receives a **fatal signal** (`SIGKILL` or an unhandled fatal signal) before the request reaches the daemon, the request is cancelled immediately and `-EINTR` is returned. If the request is already in-flight (the daemon has read it but not replied), the kernel sends a `FUSE_INTERRUPT` message with the target `unique` ID. The daemon is expected to reply to the original request with `-EINTR` as quickly as possible; the kernel waits up to 2 seconds before forcibly completing the original request with `-EINTR`.

**Abort** (full connection teardown): writing to `/sys/fs/fuse/connections/<id>/abort` or unmounting with `umount -f` sets `fuse_conn.aborted = true`. All pending requests complete immediately with `-EIO`, and all new requests return `-EIO` without touching the queue.

---

## How Components Interact

**Scenario 1 — `open("/mnt/fuse/file.txt", O_RDONLY)`**

1. VFS calls `fuse_lookup()` for `file.txt` in the parent dentry.
2. FUSE allocates `fuse_req` with opcode `FUSE_LOOKUP`, fills nodeid (parent) + name, enqueues in `iq.pending`.
3. The daemon's `read()` on `/dev/fuse` dequeues the request; daemon does its work (e.g. calls `stat()` on an underlying filesystem) and writes a `fuse_entry_out` response.
4. `fuse_dev_write()` finds the request by `unique`, fills `fuse_inode` from attributes, wakes the caller.
5. VFS calls `fuse_open()` → `FUSE_OPEN` round-trip; daemon returns a `fh` (file handle) that is stored in the kernel `struct file`.

**Scenario 2 — Signal arrives mid-read**

1. Application calls `read()` on an FUSE file; kernel sends `FUSE_READ` and blocks.
2. SIGTERM arrives; kernel checks: non-fatal, request already sent → enqueues `FUSE_INTERRUPT` with the original `unique` ID.
3. Daemon processes `FUSE_INTERRUPT`, cancels the pending read, replies with `-EINTR`.
4. Original `fuse_req` completes with `-EINTR`; application's `read()` returns `-EINTR`.

---

## Where It Fits in the Kernel

- **↑ Userspace**: libfuse provides a high-level API; daemon implements callbacks (`fuse_operations` struct). Mount is done via `mount(2)` with type `fuse` and options including `fd=N` (the `/dev/fuse` fd).
- **→ VFS / [[namei]]**: FUSE implements all VFS inode and file operations, making a FUSE mount look identical to an in-kernel filesystem to namei path lookup and file operations.
- **→ Page cache**: For cached reads/writes, FUSE participates in the page cache via `address_space_operations`. `FUSE_CAP_WRITEBACK_CACHE` enables writeback caching where dirty pages are aggregated before sending `FUSE_WRITE`.
- **→ Character device subsystem**: `/dev/fuse` is a character device; the FUSE module registers `fuse_dev_operations` (`read`/`write`/`poll`/`mmap`/`release`).
- **← Security modules (LSM)**: Each FUSE operation passes through LSM hooks normally; a FUSE filesystem is subject to SELinux/AppArmor policy like any other.

## Design Decisions & Tradeoffs

**Synchronous blocking**: FUSE blocks the calling process until the daemon replies. This is simple (no asynchronous callback infrastructure in the kernel) but means a slow daemon directly stalls user processes. The alternative — returning `-EAGAIN` and requiring userspace to retry — was rejected as incompatible with normal POSIX filesystem semantics.

**`nodeid` instead of kernel inode numbers**: The daemon assigns its own `nodeid` values for inodes (returned in `fuse_entry_out.nodeid`). This decouples the kernel inode number from the daemon's representation and allows the daemon to use any addressing scheme (paths, database keys, etc.).

**Attribute TTLs for caching**: Rather than round-tripping to the daemon on every stat, FUSE lets the daemon specify how long attribute and entry responses may be cached. A daemon serving a local filesystem can set large TTLs (seconds); a daemon serving a rapidly-changing remote source sets TTL to zero. This makes FUSE flexible across wildly different latency/consistency tradeoffs.

**Security: `allow_other` and `default_permissions`**: By default, only the mount owner can access a FUSE filesystem (enforced with ptrace-like checks). The `allow_other` mount option removes this restriction; `default_permissions` makes the kernel enforce POSIX permission bits itself rather than asking the daemon on every access. Both require `user_allow_other` in `/etc/fuse.conf`.

**io_uring integration (in progress)**: Traditional FUSE requires multiple threads blocked in `read()` on `/dev/fuse`. The io_uring path (`IORING_OP_URING_CMD`) allows a single thread per core to service requests without blocking, dramatically improving metadata throughput for network filesystems.

## How It Has Evolved

- **2.6.14 (2005)**: FUSE merged into mainline after years as an out-of-tree module.
- **2.6.26 (2008)**: Protocol version 7.10; `FUSE_ACCESS`, `FUSE_CREATE` opcodes.
- **3.15 (2014)**: `FUSE_READDIRPLUS` for more efficient directory reads (combines readdir + getattr).
- **4.2 (2015)**: `FUSE_WRITEBACK_CACHE` capability for better write performance.
- **4.20 (2019)**: `FUSE_COPY_FILE_RANGE` opcode (server-side copy optimisation).
- **5.4 (2019)**: DAX support (`FUSE_SETUPMAPPING` / `FUSE_REMOVEMAPPING`) for pmem-backed FUSE filesystems.
- **6.5 (2023)**: io_uring command interface for high-performance FUSE operations.
- **6.x (active)**: FUSE BPF — running BPF programs in the kernel to short-circuit or intercept FUSE operations without a full round-trip to the daemon.

## Recent Development Activity

- **FUSE BPF** (`lwn.net/Articles/937433`): attaches BPF programs to FUSE operations to implement overlay-like policies or short-circuit FUSE round-trips entirely for performance-critical paths.
- **io_uring integration**: per-core ring-based FUSE dispatch to eliminate thread-per-request overhead.
- **Passthrough mode**: allowing certain FUSE file operations to bypass the daemon and go directly to an underlying file, for overlay-style filesystems.

## Further Reading

1. **LWN — "FUSE - Filesystem in Userspace"** (2005): https://lwn.net/Articles/118574/ — First LWN coverage of the mainline merge.
2. **LWN — "FUSE and io_uring"** (2023): https://lwn.net/Articles/932079/
3. **LWN — "The FUSE BPF filesystem"** (2023): https://lwn.net/Articles/937433/
4. **Kernel docs — FUSE**: https://www.kernel.org/doc/html/next/filesystems/fuse.html
5. **John Millikin — "The FUSE Protocol"**: https://john-millikin.com/the-fuse-protocol — Detailed wire protocol reference.

## LKML Highlights

- **Initial mainline merge** (Miklos Szeredi, 2005): debate on security model for unprivileged mounts, resulting in the ptrace-check approach that restricts FUSE mounts to the mount owner by default.
- **Writeback cache** (~4.2): discussion on correctness implications of caching writes in the kernel before sending to the daemon — acceptable for local filesystems, dangerous for distributed ones where coherency depends on immediate write-through.
