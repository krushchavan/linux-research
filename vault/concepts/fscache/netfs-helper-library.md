---
title: "netfs Helper Library"
category: concept
tags: [netfs, fscache, caching, network-filesystem, readahead, io]
subsystem: fscache
kernel_version: "5.12"
researched: 2026-04-15
status: complete
explained: "[[netfs-helper-library-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html
  - https://www.kernel.org/doc/html/latest/filesystems/caching/netfs-api.html
  - https://lwn.net/Articles/837939/
  - https://lwn.net/Articles/877058/
---

# netfs Helper Library

> 📘 Plain-language version: [[netfs-helper-library-explained]]

## Purpose

Network filesystems share a large block of identical plumbing: they must implement `readpage`, `readahead`, `write_begin`/`write_end`, and direct I/O correctly while simultaneously routing data to and from a local cache. Getting this right—especially the interleaving of cache hits with RPC misses, and the dual-destination write path—is error-prone and was reimplemented (incorrectly, in varying ways) by each filesystem. The netfs helper library (`fs/netfs/`) absorbs this boilerplate, leaving each filesystem responsible only for issuing transport-specific RPCs.

## Mental Model

Think of netfslib as an **air traffic controller** for I/O. A read arrives as one flight plan (a `netfs_request`). The controller breaks it into individual flight legs (subrequests)—some handled by CacheFiles, some by RPCs—dispatches them in parallel, and stitches the landings together. The filesystem is just one type of carrier; the controller manages the sequencing.

## How It Works

### The Three-Object Hierarchy

All I/O inside netfslib is organised around three nested objects:

A **request** (`struct netfs_request`) covers one complete user-visible operation—a `readahead` call covering pages 0–127, or a `write_iter` covering a 1 MB range. It holds the inode, byte range, aggregate error state, and a reference to the ongoing folio work.

Within a request, one or more **streams** (`struct netfs_stream`) carry subrequests headed for the same destination. A buffered read has a single stream. A buffered write targeting both a server and a local cache has *two* simultaneous streams—a server stream and a cache stream—each independently tiled to match its destination's preferred I/O size.

Each stream contains a sequence of non-overlapping **subrequests** (`struct netfs_subrequest`). A subrequest is the unit of work: one RPC call or one CacheFiles DIO operation. It carries an offset, length, and a completion flag. When a subrequest finishes, netfslib marks the covered folios uptodate (on reads) or removes the cache-write marker (on writes), unlocking them progressively rather than waiting for the full request.

### Read Path

When the VFS calls `netfs_readahead()` or `netfs_read_folio()`, the library:

1. Acquires a `netfs_request` from a slab, sets up the range.
2. Calls `fscache_begin_read_operation()` to check whether the cookie is active. If caching is available, the library queries the cache's content map (tracking which byte ranges have been cached) to split the range into cached and uncached segments.
3. Allocates subrequests: cached regions get cache subrequests dispatched to CacheFiles via async DIO; uncached regions get RPC subrequests dispatched by calling `->issue_read()` on the filesystem's `netfs_request_ops`.
4. Both subrequest types run concurrently. As each completes, `netfs_subreq_terminated()` is called, which marks covered folios uptodate and unlocks them. The application can read the unlocked folios immediately, not waiting for the rest.
5. For RPC-filled regions that were cache misses, the library transparently schedules a background write to the cache via `netfs_write_to_cache()`. This write runs asynchronously and does not block the application.

### Write Path

`netfs_perform_write()` handles buffered writes. After locking folios and calling the filesystem's `->begin_write()` callback, the library:

1. Creates a request with two streams: a server stream and a cache stream.
2. Tiles the range across both streams independently. The server stream might break a 1 MB write into 256 KB RPC chunks; the cache stream might break it into 4 KB or 1 MB DIO chunks matching the local filesystem's block size.
3. Issues all subrequests in parallel. Each stream manages its own progress independently; a failure in one does not immediately abort the other.
4. Marks folios that should be written to the cache with `NETFS_FOLIO_COPY_TO_CACHE`. During writeback, these folios go only to the cache stream; the server stream handles separate dirty folios in the normal way.

### Per-Inode Context: `struct netfs_inode`

Filesystems embed a `struct netfs_inode` inside their inode wrapper struct (alongside the VFS `struct inode`). This is the glue between VFS and netfslib:

```c
struct netfs_inode {
    struct inode        inode;      /* VFS inode — must be first */
    const struct netfs_request_ops *ops;  /* filesystem callbacks */
    struct fscache_cookie *cache;   /* NULL if uncached */
    loff_t              zero_point; /* bytes beyond this read as zero */
    unsigned long       flags;      /* NETFS_ICTX_* */
};
```

Because `inode` is first, `container_of(inode, struct netfs_inode, inode)` costs nothing—it's a cast. This lets netfslib locate the ops table and cache cookie from any VFS inode pointer without the filesystem passing explicit context.

The `ops` table (`struct netfs_request_ops`) contains:
- `->init_request()` — set up filesystem-specific fields in a new request
- `->issue_read()` — dispatch one RPC subrequest to the network
- `->begin_write()` — prepare for a write (lock resources, check quota, etc.)
- `->issue_write()` — dispatch one RPC subrequest to write data
- `->done()` — called when the request completes, for filesystem cleanup

### Integration with fscache

The library integrates tightly with the [[fscache-cookie-subsystem]]:

- Before any read I/O, it calls `fscache_begin_read_operation()` to acquire a reference on the cache resources. If the cookie is inactive, caching is silently skipped.
- After RPC reads complete, it calls `fscache_write_to_cache()` to fill missed ranges in the background.
- For writes, it calls `fscache_dirty_folio()` to pin cache resources while a folio is dirty, and `fscache_unpin_writeback()` when writeback completes.
- Direct I/O bypasses the library's folio-based path and goes straight to `fscache_begin_read_operation()` / raw I/O helpers.

### Intelligent Retry

If an RPC subrequest fails (network error, server overload), netfslib can re-tile and retry the failed range. The retry path may use different subrequest sizes or a different server if the filesystem supports it. This is particularly useful for CIFS multi-channel scenarios.

## Key Data Structures

**`struct netfs_request`** (`include/linux/netfs.h`) — one user-visible I/O operation.
- `inode` — target inode
- `start` / `len` — byte range of the operation
- `origin` — `NETFS_READAHEAD`, `NETFS_READ_FOR_WRITE`, `NETFS_DIO_READ`, `NETFS_WRITE_TO_SERVER`, etc.
- `streams[]` — array of stream objects (server, cache)
- `error` — aggregate error code; set by first failing subrequest

**`struct netfs_subrequest`** (`include/linux/netfs.h`) — one RPC or cache I/O operation.
- `rreq` — back-pointer to parent request
- `start` / `len` — byte range this subrequest covers
- `transferred` — bytes completed so far (for partial completions)
- `error` — subrequest-level error
- `flags` — `NETFS_SREQ_CLEAR_TAIL`, `NETFS_SREQ_COPY_TO_CACHE`, `NETFS_SREQ_FAILED`

**`struct netfs_inode`** (`include/linux/netfs.h`) — per-inode library state.
- `inode` — VFS inode (must be first)
- `ops` — filesystem callback table
- `cache` — `fscache_cookie` or NULL
- `zero_point` — end of data; reads beyond here return zeros without RPCs
- `flags` — `NETFS_ICTX_ODIRECT`, `NETFS_ICTX_WRITETHROUGH`, `NETFS_ICTX_UNBUFFERED`

## Key Functions / Entry Points

**`netfs_readahead()`** (`fs/netfs/read_helper.c`) — assigned to `address_space_operations.readahead`; creates a request and issues cache + RPC subrequests in parallel.

**`netfs_read_folio()`** (`fs/netfs/read_helper.c`) — assigned to `address_space_operations.read_folio`; handles single-folio synchronous reads.

**`netfs_perform_write()`** (`fs/netfs/write_helper.c`) — handles buffered `write_iter` with dual-stream server + cache path.

**`netfs_subreq_terminated()`** (`fs/netfs/read_helper.c`) — called by filesystem or cache backend when a subrequest completes; unlocks covered folios and schedules background cache fill if appropriate.

**`netfs_write_to_cache()`** (`fs/netfs/write_helper.c`) — schedules background write of an RPC-filled range into the cache; called after successful RPC reads on cache-miss paths.

## Important Flags & Config Options

- `CONFIG_NETFS_SUPPORT` — the netfs helper library module; auto-selected by filesystems that use it
- `NETFS_ICTX_WRITETHROUGH` — per-inode: force synchronous cache writeback (set on `O_SYNC` opens)
- `NETFS_ICTX_ODIRECT` — per-inode: O_DIRECT mode; bypasses the folio path
- `NETFS_FOLIO_COPY_TO_CACHE` — folio private data marker: this folio should be written only to the cache during writeback, not to the network
- `/sys/module/netfs/parameters/debug` — bitmask for runtime debug tracing of request decomposition, subrequest dispatch, and cache interaction

## Interactions with Other Subsystems

- **← [[vfs]]**: VFS calls `readahead`, `read_folio`, `write_iter` ops which are assigned to netfslib entry points; the library calls `folio_lock()`, `folio_mark_uptodate()`, `folio_unlock()` on the page cache
- **→ [[fscache-cookie-subsystem]]**: netfslib calls `fscache_begin_read_operation()`, `fscache_write_to_cache()`, `fscache_dirty_folio()` for cache integration
- **→ [[cachefiles-backend]]**: at runtime, netfslib's cache subrequests are serviced by CacheFiles through the fscache I/O path
- **← [[network-filesystems]]**: NFS, AFS, Ceph, CIFS embed `netfs_inode` and provide `netfs_request_ops` callbacks; the library calls their `->issue_read()` / `->issue_write()` for each subrequest
- **→ [[mm]]**: netfslib manipulates folios through the standard folio API; the dual-stream write path interacts with writeback via `folio_mark_dirty()` and `NETFS_FOLIO_COPY_TO_CACHE` markers

## Design Decisions & Tradeoffs

**Embedding `netfs_inode` vs. a pointer**: Embedding means the library can reach its state with a zero-cost `container_of()` cast. The downside is that every inode in a netfslib filesystem pays for the `netfs_inode` fields even when caching is disabled—a small, fixed memory cost that was deemed acceptable given the simplification.

**Dual-stream writes with independent tiling**: The alternative was a single stream that writes to both server and cache simultaneously (a "fan-out" at the folio level). Independent streams are more code but allow each destination to choose its own I/O granularity, which matters for performance when the server prefers large RPCs and the cache prefers page-aligned writes.

**Progressive folio unlock**: The alternative (unlock all folios only after the entire request completes) would reduce latency jitter but could stall applications waiting for a single slow subrequest. Progressive unlock means the fast path (cache hits) returns to the application immediately even if some RPCs are still in flight.

## How It Has Evolved

- **5.12 (2021)**: Introduced as `fs/netfs/` with basic `netfs_readpage()` / `netfs_readahead()` helpers; `struct netfs_read_request` / `struct netfs_read_subrequest`.
- **5.17 (2022)**: Integrated with the rewritten fscache; `ITER_XARRAY` iterator added for zero-copy cache I/O; write helpers added.
- **6.x (ongoing)**: Renamed internal types to `netfs_request` / `netfs_subrequest`; stream model introduced (one request → multiple streams); folio_queue-based collection path to reduce per-subrequest work-item overhead; erofs integration ongoing.

## Further Reading

1. [Network Filesystem Services Library (kernel.org)](https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html) — authoritative reference
2. [fscache: Modernisation (LWN, 2020)](https://lwn.net/Articles/837939/) — covers the netfs helper introduction alongside the fscache rewrite
3. [Network Filesystem Caching API (kernel.org)](https://www.kernel.org/doc/html/latest/filesystems/caching/netfs-api.html) — detailed fscache integration API
