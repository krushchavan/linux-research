---
title: "FUSE Request Queue"
category: concept
tags: [fuse, filesystems, ipc, queuing, userspace]
subsystem: fuse
kernel_version: "2.6.14"
researched: 2026-04-09
status: complete
explained: "[[fuse-request-queue-explained]]"
sources:
  - https://www.kernel.org/doc/html/v6.0/filesystems/fuse.html
  - https://github.com/torvalds/linux/blob/master/fs/fuse/fuse_i.h
  - https://github.com/torvalds/linux/blob/master/fs/fuse/dev.c
  - https://john-millikin.com/the-fuse-protocol
  - https://billauer.se/blog/2020/02/fuse-cuse-signal-race-condition/
  - https://lwn.net/Articles/997400/
  - https://georgesims21.github.io/posts/fuse/
  - https://lore.kernel.org/all/20250122215528.1270478-1-joannelkoong@gmail.com/
---

# FUSE Request Queue

> 📘 Plain-language version: [[fuse-request-queue-explained]]

## Purpose

The FUSE request queue is the kernel-side buffering and dispatch mechanism that decouples a VFS operation from the userspace daemon that will service it. Without it, every filesystem call would require the kernel to synchronously context-switch into a specific daemon thread and back — instead, the queue lets multiple kernel threads post requests concurrently, lets one or more daemon threads drain them asynchronously, and provides the synchronization points that allow the kernel side to sleep safely until the daemon replies.

## Mental Model

Think of `/dev/fuse` as a restaurant's order window. Kernel threads are waiters who drop paper tickets (requests) onto the pending rail. The daemon is the kitchen — it reads tickets off the rail, cooks, and slides finished plates back through the window. The request queue is the rail itself plus the shelf where in-progress orders sit until the kitchen calls "order up." Interrupts are rush tickets that jump to the front. FORGET slips are cleanup orders that get batched so they don't clog the rail.

## How It Works

### Allocating and initialising a request

Every FUSE operation begins with `fuse_get_req()` allocating a `struct fuse_req` from a slab cache. The structure is initialised by `fuse_request_init()`, which sets up its `list` and `intr_entry` list heads, its `waitq`, and its `refcount`. The key bookkeeping field is `flags`, a bitmask of `fuse_req_flag` values that tracks the request's exact position in its lifecycle. After allocation `FR_PENDING` is set, indicating the request has not yet left the kernel.

Each request is assigned a unique 64-bit ID drawn from `fiq->reqctr`, an atomic counter on the connection's `struct fuse_iqueue`. This ID is written into the `fuse_in_header` that the daemon will read, and it is the key used to match the daemon's reply back to the waiting kernel thread.

### The input queue (`fuse_iqueue`)

The `struct fuse_iqueue` (`fiq`) is embedded in `struct fuse_conn` and represents everything still waiting to reach the daemon. It contains three separate lists, each serving a different priority tier:

- **`fiq->interrupts`** — the highest-priority list. When a kernel thread receives a signal while blocked on a FUSE request that is already in-flight, it enqueues a tiny `FUSE_INTERRUPT` message here so the daemon can cancel the original operation. The daemon reads from this list before anything else.
- **`fiq->pending`** — the main queue of foreground (synchronous) requests. Metadata operations (`lookup`, `getattr`, `mkdir`, …) land here because they block the calling process.
- **Forget/background** — handled through `fiq->forget_list_head` for batched FORGET notifications, and through a background tracking mechanism under `fc->bg_lock` for async I/O that does not block the caller.

All three share a single `fiq->waitq` on which daemon threads sleep when no work is available.

When `queue_request()` is called, it appends the new `fuse_req` to the tail of `fiq->pending`, then calls `wake_up_locked(&fiq->waitq)` to wake exactly one sleeping daemon thread. The dispatch respects priority: `fuse_dev_do_read()` checks `fiq->interrupts` first, then the forget list (subject to throttling), then `fiq->pending`, then background requests.

### Throttling FORGET requests

FORGET is a one-way notification — it carries no reply — and many can arrive in a burst when the VFS evicts inodes. Left unthrottled they would starve foreground operations. The kernel batches them via `fiq->forget_list_head`/`forget_list_tail` and enforces a ratio: for every batch of 8 non-forget requests that the daemon reads, the kernel releases up to 16 FORGET notifications. The `fiq->forget_batch` counter tracks how many non-forgets remain before the next forget flush.

### Transferring a request to the daemon (`fuse_dev_do_read`)

When the daemon calls `read()` on `/dev/fuse`, the call reaches `fuse_dev_do_read()`. If no request is ready, the thread blocks on `fiq->waitq` with:

```c
wait_event_interruptible_exclusive_locked(fiq->waitq,
    !fiq->connected || request_pending(fiq));
```

Once woken, the function:

1. Dequeues the highest-priority pending request.
2. Clears `FR_PENDING` from its flags.
3. Serialises the `fuse_in_header` (opcode, unique ID, node ID, uid, gid, pid) followed by operation-specific payload into the daemon's read buffer using `fuse_copy_one()` — which handles multi-segment `iov` arrays and calls `get_user_pages()` for any page-backed payload.
4. Sets `FR_SENT` on the request, marking it as in-flight.
5. Moves the request to `fpq->processing` — a per-device hash table — so it can be looked up by unique ID when the reply arrives.

The `struct fuse_dev` (`fud`) is the per-open-fd object: each open of `/dev/fuse` gets its own `fud` with its own `struct fuse_pqueue`. Multiple daemon worker threads can open `/dev/fuse` (or clone it via `FUSE_DEV_IOC_CLONE`) to drain the shared `fiq->pending` in parallel, while each maintains its own independent processing queue. The connection abort logic must therefore walk every `fud`'s `fpq` to drain all in-flight requests.

### The processing queue (`fuse_pqueue`)

`struct fuse_pqueue` (`fpq`) tracks requests that have been handed to the daemon but not yet answered. Its `processing` field is a hash table with `FUSE_PQ_HASH_SIZE` (256) buckets, keyed by `req->in.h.unique & (FUSE_PQ_HASH_SIZE - 1)`. The hash avoids linear scans when matching replies on busy connections.

A second list, `fpq->io`, holds requests that are actively being copied — either the headers are being read out or the response is being written back — and for which `FR_LOCKED` is set. This flag delays connection abort: `fuse_abort_conn()` must wait for `FR_LOCKED` to clear before freeing a request, to avoid a use-after-free during the copy.

### Matching and completing a reply (`fuse_dev_do_write`)

When the daemon writes a reply to `/dev/fuse`, `fuse_dev_do_write()` reads the `fuse_out_header` (length, error code, unique ID) and then looks up `req` in `fpq->processing` by unique ID. If found it:

1. Removes the request from `fpq->processing`.
2. Copies the reply payload from the daemon's write buffer into the locations pointed to by `req->args` (kernel buffers or page lists).
3. Sets `FR_FINISHED`.
4. Calls `fuse_request_end()`, which wakes `req->waitq` — the kernel thread that submitted the foreground request and has been sleeping since step 3 of the read path.

For background (asynchronous) requests, `fuse_request_end()` invokes the registered callback (`req->args->end`) instead of waking a waiter.

### Interrupt handling and the dual-flag race

Signal delivery while a request is in-flight creates a classic TOCTOU race: the interrupt handler wants to queue a `FUSE_INTERRUPT` only after the original request has been sent to the daemon (otherwise there is nothing to cancel). But `FR_SENT` and `FR_INTERRUPTED` are set by two different paths racing on two different CPUs.

The kernel resolves this with a deliberate double-check idiom:

- **`request_wait_answer()`** (the sleeping kernel thread): sets `FR_INTERRUPTED`, *then* checks `FR_SENT`.
- **`fuse_dev_do_read()`** (the daemon read path): sets `FR_SENT`, *then* checks `FR_INTERRUPTED`.

Because each side sets its own flag before reading the other, at least one of the two checks will see the flag set by the other side, regardless of scheduling order. If the interrupt wins the race (`FR_INTERRUPTED` is set before `FR_SENT`), `fuse_dev_do_read()` sees it and calls `queue_interrupt()` after sending the request. If the read wins, `request_wait_answer()` sees `FR_SENT` and calls `queue_interrupt()` from the signal handler path. The `queue_interrupt()` function is idempotent — it checks `fuse_check_interrupt()` to avoid duplicates. The daemon, on receiving `FUSE_INTERRUPT`, replies with `-EINTR` or `-EAGAIN`; `-EAGAIN` instructs the kernel to requeue the interrupt.

### Background requests and flow control

Operations like `read()` and `write()` on files are submitted as background requests via `fuse_simple_background()`. These skip `fiq->pending` entirely and are tracked under `fc->bg_lock`. Two limits gate admission:

- `fc->max_background` — when the number of outstanding background requests reaches this ceiling, new submissions block until the count drops. Default 12, configurable via `FUSE_INIT` reply.
- `fc->congestion_threshold` — when crossed (default ~75% of `max_background`), the kernel calls `set_bdi_congested()` to signal writeback pressure. This prevents the page-writeback subsystem from queuing unlimited dirty pages against a slow daemon.

### Request timeout (kernel 6.14+)

Starting in kernel 6.14, each `fuse_req` records `create_time` (in `jiffies`) at allocation. A per-connection delayed workqueue job, `fuse_check_timeout()`, fires every `FUSE_TIMEOUT_TIMER_FREQ` (15) seconds. It iterates `fpq->processing` across all open `fud` instances and checks whether any request's age exceeds the negotiated `req_timeout`. If so, it calls `fuse_abort_conn()`, terminating the entire connection — there is intentionally no per-request timeout that only kills one request, because a stuck daemon cannot be trusted to handle future requests either.

Two sysctls (`/proc/sys/fs/fuse/default_request_timeout` and `max_request_timeout`) allow system-wide defaults and caps to be set independently of the per-mount value the daemon negotiates via `FUSE_INIT`. The io_uring path requires iterating `fuse_req_queue`/`fuse_req_bg_queue` in addition to the `fpq->processing` hash, since io_uring entries do not go through the same per-device `fud` structure.

### Resend on daemon reconnect

A daemon recovery mechanism (introduced in 6.1, still evolving) allows a crashed daemon to reconnect to an existing `fuse_conn` without unmounting. Requests in `fpq->processing` that were owned by the old daemon are moved back to `fiq->pending` with their unique IDs tagged `FUSE_UNIQUE_RESEND`, so the new daemon can distinguish "retry of a previously sent request" from a fresh one.

## Key Data Structures

**`struct fuse_iqueue`** (`fs/fuse/fuse_i.h`) — the input side of the queue; one per `fuse_conn`.
- `connected` — mirrors `fc->connected`; gates queue operations
- `lock` — spinlock protecting all list fields
- `waitq` — daemon `read()` threads sleep here
- `reqctr` — monotonically increasing counter; next unique request ID
- `pending` — list of `fuse_req` waiting to be read by the daemon
- `interrupts` — higher-priority list of `FUSE_INTERRUPT` notifications
- `forget_list_head`/`tail` — linked list of batched FORGET notifications
- `forget_batch` — countdown until next forget flush
- `fasync` — async-I/O notification structure (for `O_ASYNC` on `/dev/fuse`)
- `ops` — pluggable `fuse_iqueue_ops`; virtiofs and CUSE override `enqueue` to redirect to their own transport

**`struct fuse_pqueue`** (`fs/fuse/fuse_i.h`) — the processing side; one per `fuse_dev`.
- `connected` — per-device connected flag
- `lock` — spinlock
- `processing` — pointer to `FUSE_PQ_HASH_SIZE`-element array of list heads; requests hashed by `unique & 0xff`
- `io` — list of requests currently being copied (`FR_LOCKED` set)

**`struct fuse_req`** (`fs/fuse/fuse_i.h`) — one per outstanding filesystem operation.
- `list` — membership in `pending`, `processing[n]`, or `io`
- `intr_entry` — membership in `fiq->interrupts`
- `args` — pointer to `struct fuse_args`; describes in/out buffers
- `count` — refcount; released by `fuse_put_request()`
- `flags` — bitmask of `fuse_req_flag` (see table below)
- `in.h` — `fuse_in_header`; `h.unique` is the match key for replies
- `out.h` — `fuse_out_header`; `h.error` carries the daemon's result
- `waitq` — the submitting kernel thread sleeps here while `!FR_FINISHED`
- `fm` — owning `fuse_mount`
- `create_time` — jiffies at allocation; used by timeout watchdog

**`fuse_req_flag` bitmask values:**

| Flag | Meaning |
|---|---|
| `FR_PENDING` | On `fiq->pending`; not yet read by daemon |
| `FR_SENT` | Daemon has read it; now on `fpq->processing` |
| `FR_FINISHED` | Reply received or request aborted |
| `FR_INTERRUPTED` | Signal received while waiting |
| `FR_LOCKED` | Copy in progress; delay abort |
| `FR_BACKGROUND` | Async; no kernel thread sleeping on `req->waitq` |
| `FR_WAITING` | Counted in `fc->num_waiting` |
| `FR_FORCE` | Ignore `connected` check; used for FUSE_INIT |
| `FR_ABORTED` | Abort was requested |
| `FR_ISREPLY` | Request expects a reply (not FORGET) |
| `FR_ASYNC` | Completion via callback, not wakeup |
| `FR_URING` | Routed through the io_uring path |

## Key Functions / Entry Points

**`fuse_get_req()`** (`fs/fuse/dev.c`) — allocates and initialises a `fuse_req`; checks `fc->connected` and `fc->blocked`; increments `fc->num_waiting`.

**`queue_request()`** (`fs/fuse/dev.c`) — appends `req` to `fiq->pending`, assigns unique ID from `fiq->reqctr`, calls `fiq->ops->wake_pending_and_forget()` (default: `wake_up_locked(&fiq->waitq)`).

**`fuse_dev_do_read()`** (`fs/fuse/dev.c`) — daemon read path; blocks on `fiq->waitq`; dequeues highest-priority request; copies to userspace via `fuse_copy_one()`; sets `FR_SENT`; moves to `fpq->processing`.

**`fuse_dev_do_write()`** (`fs/fuse/dev.c`) — daemon write path; reads `fuse_out_header`; looks up request in `fpq->processing[unique & mask]`; copies reply payload; calls `fuse_request_end()`.

**`fuse_request_end()`** (`fs/fuse/dev.c`) — sets `FR_FINISHED`; wakes `req->waitq` for foreground requests; invokes `args->end` callback for background requests; decrements `fc->num_waiting`.

**`queue_interrupt()`** (`fs/fuse/dev.c`) — idempotently adds an interrupt notification to `fiq->interrupts`; wakes `fiq->waitq`.

**`fuse_abort_conn()`** (`fs/fuse/dev.c`) — sets `fc->connected = 0`; walks all `fpq->processing` hash buckets across all open `fud` instances; wakes all `req->waitq` with error; called on daemon exit, sysfs abort, forced unmount, or timeout.

**`fuse_check_timeout()`** (`fs/fuse/dev.c`) — delayed workqueue handler; iterates `fpq->processing` across all `fud` instances; calls `fuse_abort_conn()` if any request age exceeds `fc->timeout.req_timeout`.

**`fuse_simple_request()`** (`fs/fuse/dev.c`) — convenience wrapper for foreground operations: `queue_request()` → sleeps on `req->waitq` → returns error or 0.

**`fuse_simple_background()`** (`fs/fuse/dev.c`) — convenience wrapper for async operations: queues under `fc->bg_lock`, wakes when below `max_background`.

## Important Flags & Config Options

| Symbol | Location | Effect |
|---|---|---|
| `max_background` | `fc->max_background` / `/proc/sys/fs/fuse/max_background` | Hard cap on concurrent background requests; new submissions block at this ceiling |
| `congestion_threshold` | `fc->congestion_threshold` / `/proc/sys/fs/fuse/congestion_threshold` | BDI congestion is signalled above this count; slows writeback to the daemon |
| `default_request_timeout` | `/proc/sys/fs/fuse/default_request_timeout` | System-wide default timeout (seconds) if the daemon did not negotiate one; 0 = disabled |
| `max_request_timeout` | `/proc/sys/fs/fuse/max_request_timeout` | System-wide ceiling on any per-mount timeout; 0 = no ceiling |
| `FUSE_TIMEOUT_TIMER_FREQ` | `fs/fuse/dev.c` (compile-time) | Frequency (15 s) of the timeout watchdog workqueue job |
| `FUSE_PQ_HASH_BITS` | `fs/fuse/fuse_i.h` | Log₂ of processing queue hash table size (8 → 256 buckets) |
| `CONFIG_FUSE_FS` | Kconfig | Compile FUSE kernel module |

## Interactions with Other Subsystems

- **↑ Userspace**: daemon reads requests from `/dev/fuse` (or io_uring CQEs in 6.14+) and writes replies; request and reply headers carry uid/gid/pid translated via `fc->user_ns` and `fc->pid_ns`.
- **→ VFS**: every FUSE inode operation eventually calls `fuse_simple_request()` or `fuse_simple_background()`; the request queue is the handoff point from VFS callchain to daemon.
- **→ Writeback/BDI**: `fc->congestion_threshold` gates calls to `set_bdi_congested()`; writeback honours this signal to slow dirty-page accumulation.
- **→ io_uring**: in 6.14+, `FR_URING` requests bypass `fiq->pending` entirely and are enqueued onto ring slots via `fuse_uring_queue_fuse_req()`; interrupt and FORGET notifications still use the traditional path.
- **← Signal handling**: `request_wait_answer()` handles fatal/non-fatal signals by either pulling the request off `fiq->pending` (pre-send) or posting to `fiq->interrupts` (post-send); the dual-flag protocol prevents race conditions.
- **← CUSE**: uses the same `fuse_iqueue` and `fuse_pqueue` machinery; overrides `fiq->ops` to handle CUSE-specific device semantics.
- **← virtiofs**: guest kernel enqueues requests to a `virtio_fs_vq` virtqueue via a custom `fuse_iqueue_ops`; the `fuse_req` lifecycle and flag set are identical.

## Design Decisions & Tradeoffs

**Priority tiers inside a single queue.** Rather than separate queues for interrupts, forgets, and normal requests, FUSE uses a single `fiq->waitq` and a priority-ordered drain in `fuse_dev_do_read()`. This simplifies the sleeping/waking logic at the cost of requiring every dequeue to test multiple list heads. The alternative — separate file descriptors per priority — would complicate daemon implementation significantly.

**Per-device processing queue with a hash table.** Making `fpq` per `fuse_dev` rather than per `fuse_conn` lets multiple daemon threads drain `fiq->pending` concurrently (each thread's read moves its request into its own `fpq`), avoiding a global lock on the reply path. The 256-bucket hash is a pragmatic balance: large enough to avoid collisions under moderate concurrency, small enough that `fuse_abort_conn()` can walk all buckets in reasonable time. On 96-core systems with per-core io_uring queues the 256 × 96 = 24,576 list heads to scan on timeout became a real concern (see LKML highlights).

**Dual-flag interrupt protocol.** Setting `FR_INTERRUPTED` and checking `FR_SENT` in one ordering, while setting `FR_SENT` and checking `FR_INTERRUPTED` in the reverse ordering, is an intentional lock-free protocol that avoids a mutex around the interrupt/send transition. The cost is subtlety: the code is non-obvious and well-known to confuse reviewers.

**Connection-level (not request-level) timeout.** Early timeout proposals aborted only the timed-out request and returned `-ETIMEDOUT` to the caller. Miklos Szeredi's design decision (v4 of the series) was to abort the entire connection instead: a daemon that fails to reply to one request within the budget cannot be trusted for any subsequent request. This is a blunt instrument but avoids complex partial-failure semantics.

**FORGET throttling ratio.** The 8:16 (non-forget : forget) ratio was chosen empirically to prevent forget storms from starving foreground operations while still draining the forget backlog promptly. The ratio is not tunable at runtime.

## How It Has Evolved

- **2.6.14 (2005)**: initial upstream merge; `fiq->pending`, `fiq->interrupts`, `fpq->processing` (linear list at the time), single daemon thread model.
- **2.6.29 (protocol 7.13)**: `max_background` and `congestion_threshold` added to `FUSE_INIT`, allowing the daemon to control its own admission limits.
- **3.x**: `fuse_pqueue.processing` converted from a single list to the 256-bucket hash table to avoid O(n) reply matching under load.
- **4.x**: `FUSE_DEV_IOC_CLONE` added, allowing daemon processes to open multiple worker `fud` instances against a single `fuse_conn` for parallel request draining.
- **5.4**: `fuse_iqueue_ops` made pluggable; virtiofs reuses the entire queue mechanism with a virtqueue back-end.
- **6.1**: `FUSE_DEV_IOC_ATTACH` proposed for server recovery; requests in `fpq->processing` can be requeued with `FUSE_UNIQUE_RESEND` so a reconnecting daemon can retry them.
- **6.14**: io_uring communication path merged; `FR_URING` flag added; `fuse_uring_queue_fuse_req()` bypasses `fiq->pending`; request timeout watchdog (`fuse_check_timeout()`) added; two new sysctls (`default_request_timeout`, `max_request_timeout`) introduced.

## Further Reading

1. [FUSE — The Linux Kernel documentation (v6.0)](https://www.kernel.org/doc/html/v6.0/filesystems/fuse.html) — canonical reference covering queue states and abort handling
2. [The FUSE Protocol](https://john-millikin.com/the-fuse-protocol) — wire-level format of request/reply headers
3. [FUSE and io_uring (LWN)](https://lwn.net/Articles/932079/) — design rationale for the io_uring communication path
4. [fuse: fuse-over-io-uring (LWN)](https://lwn.net/Articles/997400/) — the merged io_uring implementation
5. [fuse: add kernel-enforced request timeout (LWN)](https://lwn.net/Articles/998308/) — timeout watchdog design
6. [FUSE signal handling: the very gory details](https://billauer.se/blog/2020/02/fuse-cuse-signal-race-condition/) — exhaustive walkthrough of the interrupt race and dual-flag protocol
7. [`fs/fuse/fuse_i.h`](https://github.com/torvalds/linux/blob/master/fs/fuse/fuse_i.h) — `fuse_iqueue`, `fuse_pqueue`, `fuse_req`, and `fuse_req_flag` definitions
8. [`fs/fuse/dev.c`](https://github.com/torvalds/linux/blob/master/fs/fuse/dev.c) — `fuse_dev_do_read`, `fuse_dev_do_write`, `queue_request`, `fuse_abort_conn`

## LKML Highlights

- **fuse: add kernel-enforced request timeout option** (`20250122215528.1270478-1-joannelkoong@gmail.com`, Joanne Koong, 2025-01) — twelve-version series adding the timeout watchdog and two sysctls; the central design debate (v4) was whether to abort only the timed-out request or the entire connection — Miklos chose connection abort for correctness. A secondary debate concerned the io_uring path: `fuse_check_timeout()` iterates `fpq->processing` across all `fud` instances, but io_uring requests don't appear there; Bernd Schubert flagged that on 96-core systems this means 24,576 list-head scans, motivating per-queue per-core timeout work.
- **fuse: flush pending fuse events before aborting the connection** (`20251108004303.GX196362@frogsfrogsfrogs`, Darrick J. Wong, 2025-11) — proposes flushing the `fiq->pending` list in a defined order before pulling the abort trigger, ensuring the daemon gets a chance to observe all queued events before the connection closes; highlights the interaction between the abort path and the pending queue drain order.
