---
title: "netfs Operations Table"
category: concept
tags: [netfs, callbacks, interface, network-filesystem, request-ops]
subsystem: netfs
kernel_version: "5.13"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html
  - https://lwn.net/Articles/894589/
  - https://lwn.net/Articles/955944/
---

# netfs Operations Table

## Purpose

`struct netfs_request_ops` is the contract between netfs and a network filesystem. It defines a table of callbacks that netfs invokes at precisely the right moments in the I/O lifecycle — when a request is initialised, when a subrequest needs sizing, when an RPC should be dispatched, when a failure should be retried, and when state should be cleaned up. By implementing this table, a filesystem obtains complete buffered I/O, readahead, DIO, writeback, and local caching support from netfs without writing any of that logic itself. The operations table is deliberately minimal: only `issue_read` and `issue_write` are required; all other callbacks have either safe defaults or are skipped when absent.

## Mental Model

Think of `netfs_request_ops` as a **hotel concierge desk** where netfs is the hotel and the filesystem is the guest. The hotel handles check-in, room allocation, cleaning, and billing (folio lifecycle, subrequest splitting, result collection, retry logic). The guest only needs to answer three questions: "What is your maximum room size?" (prepare), "Are you ready to check in?" (issue), and "Do you need help after checkout?" (done/free). All other logistics are the hotel's problem.

## How It Works

### Callback invocation sequence for a read

When `netfs_readahead()` runs, it invokes operations table callbacks in this order:

1. **`init_request(rreq, file)`** — called immediately after the request is allocated; filesystem stores authentication state or connection references in `rreq->netfs_priv`.
2. **`expand_readahead(rreq)`** — optional; filesystem widens the read window for alignment.
3. **`prepare_read(sreq, expand)`** — called once per subrequest before dispatch; filesystem caps the subrequest length to its RPC maximum.
4. **`issue_read(sreq)`** — filesystem fires the async RPC; returns immediately.
5. **`done(rreq)`** — called after all folios are unlocked and data is visible; filesystem performs post-read cleanup.
6. **`free_request(rreq)`** / **`free_subrequest(sreq)`** — release private data in `netfs_priv` and subrequest-private state.

For the retry path, if a subrequest fails, netfs additionally calls:
- **`retry_request(rreq, stream)`** — before re-issuing failed subrequests; filesystem may refresh tokens or reopen connections.
- **`prepare_read(sreq, expand)`** — again, with possibly different constraints after retry.
- **`issue_read(sreq)`** — again, on the retiled/re-prepared subrequest.

### Callback invocation sequence for a write

For writeback:

1. **`init_request(rreq, file)`** — as above.
2. **`begin_writeback(rreq)`** — filesystem enables stream 0 (server-destined writes) and acquires write-side resources (e.g., dirty-byte accounting, space reservation).
3. **`prepare_write(sreq, len, fully_written, may_split)`** — per subrequest; negotiates maximum write size.
4. **`issue_write(sreq)`** — filesystem dispatches write RPC to server or cache.
5. **`invalidate_cache(rreq)`** (on cache write failure) — filesystem removes the stale cache entry.
6. **`update_i_size(inode, new_size)`** — if the write extended the file; filesystem updates size atomically.
7. **`post_modify(inode)`** — after page cache modification; filesystem updates mtime or version counter.
8. **`retry_request(rreq, stream)`** — on failure; as for reads.

### Mandatory vs. optional callbacks

Only two callbacks are mandatory:

| Callback | Mandatory | Default if absent |
|---|---|---|
| `issue_read` | Yes (read-capable filesystems) | n/a |
| `issue_write` | Yes (write-capable filesystems) | n/a |
| `init_request` | No | noop |
| `free_request` | No | noop |
| `free_subrequest` | No | noop |
| `expand_readahead` | No | no expansion |
| `prepare_read` | No | no size cap |
| `done` | No | noop |
| `begin_writeback` | No | stream 0 not enabled |
| `prepare_write` | No | no size cap |
| `invalidate_cache` | No | noop |
| `update_i_size` | No | `i_size_write()` |
| `post_modify` | No | noop |
| `retry_request` | No | hard failure |

A read-only filesystem (e.g., a read-only Ceph volume) needs only `issue_read`. A full read-write filesystem needs at minimum `issue_read` and `issue_write`.

### The `issue_read()` contract

`issue_read(sreq)` is the most critical callback. Its contract:

1. The filesystem receives a `netfs_io_subrequest *` with `start`, `len`, and `io_iter` filled in. The `io_iter` points directly at the page cache folios that should receive the data.
2. The filesystem initiates an asynchronous RPC (or a synchronous one wrapped in a workqueue). It may store filesystem-private state in the subrequest.
3. When the RPC completes (in any context — interrupt, workqueue, or synchronous), the filesystem calls `netfs_read_subreq_terminated(sreq, error, was_async)`:
   - `error = 0` and `sreq->transferred = bytes_read` on success.
   - `error = -ERRNO` on failure (netfs handles retry).
4. The filesystem must not access `sreq` after calling `netfs_read_subreq_terminated()` — netfs may free it immediately.

For partial completion (data arrives in chunks), the filesystem calls `netfs_read_subreq_progress(sreq, was_async)` with updated `sreq->transferred` before calling the termination function.

### The `prepare_write()` contract

`prepare_write(sreq, len, fully_written, may_split)` is called before each server-destined write subrequest:

- `len` is the amount netfs would like to write in this subrequest.
- The filesystem adjusts `sreq->len` downward to its maximum (e.g., the SMB2 MaxWriteSize negotiated at session setup).
- If `may_split`, netfs will create additional subrequests for the remainder. If `!may_split`, the filesystem must accept the entire `len` or return an error.
- `fully_written` is set if `len` covers the entire remaining dirty range; the filesystem can use this to avoid a final partial-write RPC by padding to its preferred size.

### Retry callback semantics

`retry_request(rreq, stream)` is called with a pointer to the stream that had failures, not to individual subrequests. The filesystem inspects the stream's failed subrequests via `stream->subreqs` and decides whether to:

- Refresh credentials and allow netfs to retry as-is.
- Signal permanent failure by setting an error on the request.
- Change the request's strategy (e.g., switch from a cached path to a direct path).

After `retry_request()` returns, netfs calls `prepare_read()` / `prepare_write()` again on each failed subrequest, potentially with new constraints, before re-issuing. This allows the filesystem to update the maximum RPC size (e.g., after renegotiating with the server).

## Key Data Structures

**`struct netfs_request_ops`** (`include/linux/netfs.h`) — callback table; one static instance per filesystem.
- `issue_read` — function pointer: `void (*)(struct netfs_io_subrequest *)`
- `issue_write` — function pointer: `void (*)(struct netfs_io_subrequest *)`
- `prepare_read` — function pointer: `int (*)(struct netfs_io_subrequest *, loff_t)`
- `prepare_write` — function pointer: `int (*)(struct netfs_io_subrequest *, size_t, bool, bool)`
- `begin_writeback` — function pointer: `void (*)(struct netfs_io_request *)`
- `retry_request` — function pointer: `void (*)(struct netfs_io_request *, struct netfs_io_stream *)`
- `init_request`, `free_request`, `free_subrequest`, `expand_readahead`, `done`, `invalidate_cache`, `update_i_size`, `post_modify` — remaining optional callbacks

## Key Functions / Entry Points

**`netfs_read_subreq_terminated(sreq, error, was_async)`** (`fs/netfs/`) — filesystem calls this when an `issue_read()` RPC completes; core result-collection entry point.

**`netfs_write_subreq_terminated(sreq, error, was_async)`** (`fs/netfs/`) — filesystem calls this when an `issue_write()` RPC completes; usable as a `kiocb` completion handler.

**`netfs_read_subreq_progress(sreq, was_async)`** (`fs/netfs/`) — filesystem calls for interim read progress; enables early folio unlock.

**`netfs_prepare_write_failed(sreq)`** (`fs/netfs/`) — called when `prepare_write()` fails synchronously; notifies netfs without going through the async completion path.

## Important Flags & Config Options

No Kconfig options govern the operations table directly. The callbacks a filesystem implements determine the feature set netfs activates:
- No `begin_writeback` → stream 0 not enabled → no server writes (read-only filesystem)
- No `retry_request` → failures are permanent within one writeback pass
- No `invalidate_cache` → cache write failures silently ignored (data may be stale)

## Interactions with Other Subsystems

- **← netfs core**: netfs calls ops table callbacks at fixed points in the I/O lifecycle; the filesystem never calls into netfs except through completion functions.
- **→ Filesystem RPC layer**: `issue_read()` and `issue_write()` are the bridge from netfs to the filesystem's own RPC engine (RxRPC for AFS, libsmb for CIFS, libceph for Ceph).
- **→ [[fscache]]**: `netfs_cache_ops` is a parallel callback table used by the fscache layer; it mirrors `netfs_request_ops` but with cache-specific semantics.

## Design Decisions & Tradeoffs

**Minimal mandatory interface**: Only `issue_read` / `issue_write` are mandatory. This was deliberate — the operations table was designed to be adoptable incrementally. A filesystem can start with read-only support (`issue_read` only), add write support later (`issue_write`, `begin_writeback`, `prepare_write`), and further optimise with retry and size-negotiation callbacks without any rework at each step.

**Single callback for all subrequest types**: Early designs had separate callbacks for cache-hit vs. server-fetch subrequests. The final design uses a single `issue_read()` for all server-destined reads; cache reads are dispatched by netfs internally through `netfs_cache_ops`, never surfaced to the filesystem. This simplifies the filesystem's callback implementation at the cost of slightly less flexibility (the filesystem cannot intercept a cache hit for its own accounting).

**Termination function vs. callback**: Completion is signalled by the filesystem calling `netfs_read_subreq_terminated()` rather than by netfs polling or registering a callback with the filesystem. This inversion (the filesystem calls netfs, not the other way around on completion) decouples netfs from the filesystem's RPC engine event loop and allows any completion context (interrupt, workqueue, or sync).

## How It Has Evolved

- **v5.13**: Initial ops table with `issue_read`, `prepare_read`, `expand_readahead`, `done`, `init_request`, `free_request`.
- **v6.3**: Write callbacks added: `begin_writeback`, `prepare_write`, `issue_write`, `free_subrequest`.
- **v6.5**: `retry_request` and `invalidate_cache` added; retry loop formalised.
- **v6.7**: `update_i_size` and `post_modify` added for finer-grained filesystem control over metadata updates.
- **v6.13**: `prepare_write` signature extended with `fully_written` and `may_split` parameters for better size negotiation in partial-write scenarios.

## Further Reading

1. [Network Filesystem Services Library — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html)
2. [netfs, afs, cifs: Delegate high-level I/O to netfslib — LWN.net](https://lwn.net/Articles/951936/)
3. [The netfslib helper library — LWN.net](https://lwn.net/Articles/894589/)
