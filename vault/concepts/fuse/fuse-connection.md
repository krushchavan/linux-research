---
title: "FUSE Connection"
category: concept
tags: [fuse, filesystems, userspace, ipc, mount]
subsystem: fuse
kernel_version: "2.6.14"
researched: 2026-04-08
status: complete
explained: "[[fuse-connection-explained]]"
sources:
  - https://static.lwn.net/kerneldoc/filesystems/fuse.html
  - https://www.kernel.org/doc/html/next/filesystems/fuse.html
  - https://john-millikin.com/the-fuse-protocol
  - https://github.com/torvalds/linux/blob/master/fs/fuse/fuse_i.h
  - https://github.com/torvalds/linux/blob/master/fs/fuse/inode.c
  - https://docs.kernel.org/next/filesystems/fuse-io-uring.html
  - https://lwn.net/Articles/974925/
  - https://lwn.net/Articles/68104/
---

# FUSE Connection

> 📘 Plain-language version: [[fuse-connection-explained]]

## Purpose

The FUSE connection is the persistent kernel object that owns the communication channel between the kernel VFS layer and a userspace filesystem daemon. Without it there is no way for the kernel to route filesystem operations to a process running outside the kernel, nor any way to multiplex multiple mounted filesystems onto a single daemon without confusing their request streams.

## Mental Model

Think of `struct fuse_conn` as the kernel's end of a telephone exchange switchboard. Every filesystem operation that arrives at the VFS for a FUSE-backed mount is converted into a message and posted to a shared inbox (`/dev/fuse`). The daemon on the other end picks up messages, processes them, and posts replies. The connection object is the switchboard itself: it holds the queues, tracks outstanding calls, enforces flow-control limits, and remembers which features both sides agreed to during initial negotiation.

## How It Works

### Birth: opening `/dev/fuse` and mounting

The connection's life begins when a userspace daemon opens `/dev/fuse` and passes the resulting file descriptor to the `mount` syscall. Inside `fuse_fill_super()` (`fs/fuse/inode.c`) the kernel validates that the fd actually refers to a FUSE device, that the calling process belongs to the same user namespace that opened the device, and that the required mount options (`rootmode`, `user_id`, `group_id`) are present. Once these checks pass, `fuse_fill_super_common()` allocates and initialises the central `struct fuse_conn` via `fuse_conn_init()`.

`fuse_conn_init()` sets up everything the connection needs to live:

- Two spinlocks: `fc->lock` for general protection and `fc->bg_lock` for background-request bookkeeping.
- A reference count (`fc->count`) seeded to 1 and a device-instance count (`fc->dev_count`) also at 1.
- The input queue `fc->iq` (a `struct fuse_iqueue`) with its `pending` and `interrupts` lists and a `waitq` for the daemon's `read()` calls to sleep on.
- Background-request limits: `fc->max_background` defaulting to 12 and `fc->congestion_threshold` at a fraction of that.
- Namespace references: `fc->pid_ns` and `fc->user_ns` capture the calling process's namespaces so that later capability checks remain correct even if the daemon changes namespaces.
- `fc->connected = 1` — the flag that gates all subsequent request submission.

At this point the connection exists but is not yet useful. The kernel then calls `fuse_send_init()`, which enqueues a `FUSE_INIT` request into `fc->iq.pending`. The very next `read()` on `/dev/fuse` by the daemon will dequeue this message.

### Handshake: `FUSE_INIT` negotiation

The `FUSE_INIT` exchange is the protocol handshake. The kernel sends its supported major/minor version (currently 7.x) and a 64-bit `flags` bitmask advertising every capability it can support — things like `FUSE_WRITEBACK_CACHE`, `FUSE_PARALLEL_DIROPS`, `FUSE_ASYNC_DIO`, `FUSE_POSIX_ACL`, and the newer `FUSE_PASSTHROUGH` and `FUSE_URING_COMMS` bits.

The daemon reads this message, selects the capabilities it understands, and writes back a reply carrying:
- Its own version numbers (so the kernel can downgrade the protocol if needed).
- `max_write` — the largest single write payload the daemon can accept.
- `max_readahead` — how much the kernel may speculatively read ahead.
- `max_background` and `congestion_threshold` — the daemon's preferred limits.
- Its own `flags` bitmask, which is ANDed with the kernel's offer to produce the final agreed capability set.

`fuse_init_request()` in `dev.c` processes the response and writes the negotiated values back into `struct fuse_conn`: `fc->max_write`, `fc->max_read`, `fc->max_pages`, `fc->max_background`, `fc->congestion_threshold`, and all the capability bit-fields. After this point the connection is fully live and the superblock's root inode is exposed to VFS.

### Steady state: request queuing and dispatch

Every VFS operation on a FUSE-backed inode eventually calls `fuse_simple_request()` or `fuse_simple_background()`, which place a `struct fuse_req` onto one of the connection's queues:

- **`fc->iq.pending`** — foreground (synchronous) requests that must complete before the calling process can continue.
- **`fc->iq.interrupts`** — interrupt notifications to tell the daemon a pending request was killed by a signal.
- **Background queue** (tracked via `fc->bg_lock`) — asynchronous requests that can be serviced concurrently up to `fc->max_background`.

When the daemon calls `read()` on `/dev/fuse`, the kernel's `fuse_dev_read()` wakes from `fc->iq.waitq`, dequeues the highest-priority pending request (interrupts before foreground before background), serialises it into the read buffer as a `fuse_in_header` followed by operation-specific payload, then moves the request to `fd->pq.processing` (the per-device processing queue inside `struct fuse_dev`) so that the kernel can match the reply when it arrives.

The requesting kernel thread then sleeps on `req->waitq`. When the daemon calls `write()` with the response, `fuse_dev_write()` locates the matching `struct fuse_req` in `pq.processing` by `req->in.h.unique` (the request ID), copies the response payload, and wakes the sleeping thread via `req->waitq`.

### Flow control and congestion

If the number of outstanding background requests reaches `fc->congestion_threshold`, the kernel marks the backing device congested via `set_bdi_congested()`. Once the queue drains below the threshold, the flag is cleared. If background requests reach `fc->max_background`, new background submissions block entirely until the queue shrinks. This back-pressure prevents a slow or stuck daemon from causing unbounded memory growth in the kernel's request pool.

For foreground requests, the kernel checks whether the calling process is already blocked on a `ptrace`-able process owned by the mount owner (a deadlock risk); if so it aborts with `-EPERM` rather than sleeping forever.

### Connection abort

There are four ways a connection can terminate ungracefully:

1. **Daemon exits** — the last file descriptor on `/dev/fuse` closes. `fuse_dev_release()` calls `fuse_abort_conn()`.
2. **Control filesystem abort** — writing to `/sys/fs/fuse/connections/<N>/abort` calls `fuse_abort_conn()` directly.
3. **Forced unmount** — `umount -f` triggers `fuse_conn_abort()` from the VFS unmount path.
4. **`ENODEV` from unmount** — once the superblock is torn down, new requests get `-ENODEV`; after a sysfs abort they get `-ECONNABORTED` (distinguished by the `FUSE_ABORT_ERROR` capability flag).

`fuse_abort_conn()` sets `fc->connected = 0`, then walks both `iq.pending` and every per-device `pq.processing` list, wakes each sleeping `req->waitq`, and returns `-EIO` (or `-ENOTCONN`) to all callers. Requests that arrive after the abort are rejected immediately at submission time.

### Reference counting and final teardown

`struct fuse_conn` is reference-counted. Each `struct fuse_mount` (one per superblock sharing this connection) holds a reference, and each open `/dev/fuse` file descriptor creates a `struct fuse_dev` that holds another. When the last reference drops, `fuse_conn_put()` runs:

1. Releases DAX resources if the mount used direct-access mode.
2. Cancels the request-timeout watchdog (`fc->timeout.work`).
3. Invokes the queue-specific cleanup callback (`fc->iq.ops->release()`).
4. Frees write-synchronisation buckets (`fuse_sync_bucket`).
5. Schedules `delayed_release()` via RCU to handle the final `user_ns` put and call `fc->release()`.

The RCU delay ensures that any RCU-protected walk of the connection list that is in flight at the moment of the last `put` completes before the memory is freed.

### io_uring communication path (kernel 6.14+)

Starting with kernel 6.14, FUSE supports an alternative communication path that bypasses the `read()`/`write()` loop on `/dev/fuse`. The daemon registers per-CPU ring entries with `IORING_OP_URING_CMD` + `FUSE_URING_REQ_REGISTER`. The kernel then enqueues requests directly onto ring queue slots via `fuse_uring_queue_fuse_req()` and signals the daemon through io_uring completion events. The daemon processes the CQE and re-arms with `FUSE_URING_REQ_COMMIT_AND_FETCH`, atomically committing the reply and fetching the next pending request. This eliminates per-request context switches; the traditional path is still used for notifications and interrupts that the ring path does not yet support. The io_uring flag is stored in `fc->io_uring:1`.

## Key Data Structures

**`struct fuse_conn`** (`fs/fuse/fuse_i.h`) — the master per-connection object; one instance per `/dev/fuse` fd (or per CUSE device).
- `lock` — spinlock protecting most fields
- `count` — reference count; freed when it reaches zero
- `dev_count` — number of open `/dev/fuse` file descriptors
- `connected` — 1 while alive, 0 after abort; gates request submission
- `iq` (`struct fuse_iqueue`) — input queue: `pending` list, `interrupts` list, `waitq`
- `max_background`, `congestion_threshold` — flow-control knobs
- `bg_lock` — spinlock for background queue
- `mounts` — list of `struct fuse_mount` sharing this connection
- `devices` — list of `struct fuse_dev` instances
- `max_write`, `max_read`, `max_pages` — negotiated buffer limits
- Capability bits: `writeback_cache`, `parallel_dirops`, `async_dio`, `posix_acl`, `passthrough`, `io_uring`, …
- `ring` (`struct fuse_ring *`) — io_uring path data, NULL on traditional path
- `timeout.work` — delayed work that aborts requests exceeding `req_timeout`

**`struct fuse_iqueue`** (`fs/fuse/fuse_i.h`) — the input (pending) side of the connection.
- `connected` — mirrors `fc->connected` for queue-local checks
- `pending` — list of `struct fuse_req` waiting to be read by the daemon
- `interrupts` — higher-priority list of interrupt notifications
- `waitq` — the daemon's `read()` sleeps here
- `ops` — pluggable callbacks (`fuse_iqueue_ops`) used by CUSE and virtiofs to override dispatch

**`struct fuse_dev`** (`fs/fuse/fuse_i.h`) — one per open `/dev/fuse` fd.
- `fc` — back-pointer to the owning `fuse_conn`
- `pq` (`struct fuse_pqueue`) — processing queue: requests dispatched but not yet answered
- `entry` — links into `fc->devices`

**`struct fuse_mount`** (`fs/fuse/fuse_i.h`) — one per superblock (a connection can be shared across bind-mounts).
- `fc` — the shared connection
- `sb` — the superblock
- `fc_entry` — links into `fc->mounts`

## Key Functions / Entry Points

**`fuse_conn_init()`** (`fs/fuse/inode.c`) — zeroes and sets up a freshly allocated `fuse_conn`; called from `fuse_fill_super_common()` at mount time.

**`fuse_send_init()`** (`fs/fuse/inode.c`) — enqueues the `FUSE_INIT` request that starts the handshake; called immediately after `fuse_conn_init()`.

**`fuse_dev_read()`** (`fs/fuse/dev.c`) — called when the daemon reads `/dev/fuse`; dequeues from `iq.interrupts` then `iq.pending`, copies to userspace, moves request to `pq.processing`.

**`fuse_dev_write()`** (`fs/fuse/dev.c`) — called when the daemon writes a reply; locates the matching request in `pq.processing` by unique ID, copies response, wakes the waiting kernel thread.

**`fuse_abort_conn()`** (`fs/fuse/dev.c`) — sets `fc->connected = 0`, drains all queues, returns errors to all waiters; called on daemon exit, forced unmount, or sysfs abort.

**`fuse_conn_put()`** (`fs/fuse/inode.c`) — drops a reference; schedules RCU-delayed teardown when count reaches zero.

**`fuse_simple_request()`** (`fs/fuse/dev.c`) — the standard foreground request path; allocates a `fuse_req`, enqueues it on `iq.pending`, sleeps on `req->waitq`, returns when the daemon has replied.

**`fuse_uring_queue_fuse_req()`** (`fs/fuse/uring.c`) — io_uring fastpath; posts request directly to a ring slot instead of the `iq.pending` list.

## Important Flags & Config Options

| Symbol | Location | Effect |
|---|---|---|
| `FUSE_WRITEBACK_CACHE` | `fuse_conn.writeback_cache` | Enables page-cache write-back mode; improves write performance but may cause stale-data issues with external writers |
| `FUSE_PARALLEL_DIROPS` | `fuse_conn.parallel_dirops` | Allows concurrent `readdir`/`lookup` on the same directory; improves performance on content-addressable stores |
| `FUSE_ASYNC_DIO` | `fuse_conn.async_dio` | Lets direct-I/O operations complete asynchronously |
| `FUSE_POSIX_ACL` | `fuse_conn.posix_acl` | Enables POSIX ACL enforcement in the kernel for the mounted filesystem |
| `FUSE_ABORT_ERROR` | negotiated capability | Distinguishes `-ECONNABORTED` (sysfs abort) from `-ENODEV` (unmount) on `/dev/fuse` reads |
| `max_background` sysctl | `/proc/sys/fs/fuse/max_background` | System-wide default for `fc->max_background` (default 12) |
| `congestion_threshold` sysctl | `/proc/sys/fs/fuse/congestion_threshold` | System-wide default for `fc->congestion_threshold` (default 75% of max_background) |
| `CONFIG_FUSE_FS` | Kconfig | Compile FUSE kernel module |
| `CONFIG_VIRTIO_FS` | Kconfig | Compile virtiofs (uses `fuse_conn` with a virtio transport back-end instead of `/dev/fuse`) |

## Interactions with Other Subsystems

- **↑ Userspace**: the daemon reads requests from `/dev/fuse` (or io_uring CQEs) and writes replies; mount(2) passes the fd during `fuse_fill_super`.
- **→ VFS**: `fuse_conn` underpins the `super_block`; VFS calls `fuse_*_inode_ops` which translate to FUSE protocol messages routed through the connection.
- **→ Block/BDI**: `fuse_fill_super_common()` registers a backing-device-info (`bdi`) so the page-writeback subsystem knows congestion state; `fuse_abort_conn` clears the congestion flag.
- **→ io_uring**: in 6.14+, the connection optionally routes requests through `struct fuse_ring` rather than the character device.
- **← Security / namespaces**: `fc->user_ns` and `fc->pid_ns` are used to translate uid/gid/pid values in request and reply headers between kernel and userspace representations.
- **← CUSE**: the Character-device-in-Userspace driver allocates its own `fuse_conn` with a custom `fuse_iqueue_ops` but otherwise reuses the entire request-queuing machinery.
- **← virtiofs**: guest kernel allocates a `fuse_conn` backed by a `virtio_fs_vq` transport; the `fuse_iqueue_ops` redirect `pending` enqueue to a virtqueue instead of `/dev/fuse`.

## Design Decisions & Tradeoffs

**Single fd for the entire connection.** Early FUSE designs considered per-operation channels but settled on a single character device fd. This simplifies the kernel's reference counting and abort logic at the cost of making the daemon a single-threaded bottleneck unless it explicitly manages concurrency.

**Capability negotiation rather than versioning.** Rather than bumping the protocol major version for every new feature (which would require daemon updates), FUSE uses a stable major version (7) and a growing 64-bit flags bitmask. Older daemons simply ignore unknown bits. The downside is that the flags field has grown large and the semantics of feature combinations can be subtle.

**`connected` flag vs. per-request cancellation.** Aborting a connection clears a single `fc->connected` flag and drains all queues atomically under `fc->lock`. This is simple and reliable but coarse: there is no way to abort only a subset of requests without external work. The per-request interrupt path (via `iq.interrupts`) provides finer granularity for signal delivery.

**Reference counting across mounts and devices.** Allowing multiple `fuse_mount` instances to share one `fuse_conn` (as happens with `mount --bind`) means the daemon's fd lifetime is decoupled from any individual mount, which is correct but makes the teardown order complex. The RCU-delayed final release was added to handle races where an RCU reader still holds a pointer to the connection just as the last reference drops.

## How It Has Evolved

- **2.6.14 (2005)**: initial upstream merge; basic `fuse_conn` with `pending`/`processing` queues and `/dev/fuse`.
- **2.6.29**: `max_background` and `congestion_threshold` added to `FUSE_INIT` (protocol 7.13), giving daemons control over flow-control knobs.
- **3.15**: `FUSE_WRITEBACK_CACHE` capability added, enabling page-cache buffering for FUSE writes and substantially improving write throughput for local filesystems like SSHFS.
- **4.8**: `FUSE_PARALLEL_DIROPS` added; prevents the artificial serialisation of all directory operations that blocked concurrent metadata-heavy workloads.
- **4.20**: `FUSE_ABORT_ERROR` capability added to distinguish sysfs abort from normal unmount.
- **5.4**: virtiofs introduced; `fuse_iqueue_ops` made pluggable so virtiofs could reuse `fuse_conn` with a virtqueue back-end.
- **6.1**: server recovery mechanism proposed (`FUSE_DEV_IOC_ATTACH`, `tag=` mount option) to allow a crashed daemon to reconnect to an existing connection without requiring a full unmount/remount.
- **6.14**: io_uring communication path (`FUSE_URING_COMMS`) merged, replacing the `read()`/`write()` loop with submission-queue entries for lower per-request latency.

## Further Reading

1. [FUSE — The Linux Kernel documentation](https://www.kernel.org/doc/html/next/filesystems/fuse.html) — canonical reference covering connection lifecycle and security model
2. [FUSE-over-io-uring design](https://docs.kernel.org/next/filesystems/fuse-io-uring.html) — design rationale for the io_uring communication path
3. [Introducing FUSE (LWN, 2001)](https://lwn.net/Articles/68104/) — original architecture overview
4. [FUSE passthrough read/write (LWN)](https://lwn.net/Articles/835312/) — passthrough mode design
5. [fuse: introduce fuse server recovery mechanism (LWN)](https://lwn.net/Articles/974925/) — recovery and reconnection design
6. [fuse: fuse-over-io-uring (LWN)](https://lwn.net/Articles/997400/) — io_uring integration discussion
7. [The FUSE Protocol](https://john-millikin.com/the-fuse-protocol) — detailed wire-level protocol documentation
8. [`fs/fuse/fuse_i.h`](https://github.com/torvalds/linux/blob/master/fs/fuse/fuse_i.h) — definitive struct definitions

## LKML Highlights

- **fuse: introduce fuse server recovery mechanism** (`20221129155656.3070-1-hao.xu@linux.alibaba.com`) — proposes `tag=` mount option and `FUSE_DEV_IOC_ATTACH` ioctl so a crashed daemon can reclaim an existing `fuse_conn` without unmounting; debate centred on security boundary (rescue_uid), state recovery semantics, and whether FUSE_INIT re-negotiation should be required.
- **fuse: fuse-over-io-uring** — series adding `FUSE_URING_COMMS`; key discussion was about which request types (notifications, interrupts) could not yet be safely routed through the ring and had to remain on the traditional path, establishing the hybrid model that shipped in 6.14.
