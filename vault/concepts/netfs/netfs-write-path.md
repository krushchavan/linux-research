---
title: "netfs Write Path"
category: concept
tags: [netfs, writeback, write, fscache, network-filesystem]
subsystem: netfs
kernel_version: "5.19"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html
  - https://lwn.net/Articles/971770/
  - https://lwn.net/Articles/886577/
  - https://lwn.net/Articles/979171/
---

# netfs Write Path

## Purpose

Writing data through a network filesystem involves challenges absent from local filesystems: data may need to go simultaneously to a remote server and a local cache, each with independent size limits and alignment constraints; writeback must ensure that the local cache cookie is not discarded mid-flight; and write failures may require nuanced retry behaviour (e.g., refreshing an auth token before retrying). The netfs write path centralises this complexity, providing shared implementations of buffered writes, DIO writes, and writeback (including mixed server+cache writeback) that network filesystems consume by implementing a small set of callbacks.

## Mental Model

Think of the write path as a **two-lane dispatch system**. One lane (stream 0) carries data to the remote server; the other (stream 1) carries data to the local disk cache. Both lanes run independently with their own chunking and pacing. A given folio may travel one lane, the other, or both — depending on whether it was read from the cache and only needs to be written back there, or whether it is new data that must go to the server. netfs manages the dispatch, tracks which folios have been delivered in which lane, and pins the cache resources needed for writeback so they cannot be discarded while work is in flight.

## How It Works

### Buffered write entry from userspace

A userspace `write()` syscall enters netfs via `netfs_file_write_iter()`. This function:

1. Acquires the class-2 write lock via `netfs_start_io_write()` to serialise with other buffered writers.
2. Calls `netfs_perform_write()`, which iterates over the write range folio-by-folio.
3. For each folio, locks it, copies userspace data in via `copy_folio_from_iter()`, and marks it dirty with `netfs_dirty_folio()`.
4. If an active fscache cookie is present, `netfs_dirty_folio()` also marks the folio for cache copy by setting `NETFS_FOLIO_COPY_TO_CACHE` in `folio->private`.
5. Calls `netfs_request_ops.post_modify()` so the filesystem can update mtime or version numbers.
6. Returns the byte count to the caller.

At this point the data is in the page cache, the folios are dirty, and the write appears complete from the userspace perspective. Actual persistence happens during writeback.

### Resource pinning at dirty time

When `netfs_dirty_folio()` runs and an fscache cookie is active, netfs sets `I_PINNING_NETFS_WB` on the inode. This flag pins the fscache cookie — preventing fscache from discarding the cookie's backing storage — until writeback completes. Without this pin, a memory-pressure eviction could tear down the cache cookie between the point where the folio is dirtied (cache copy needed) and the point where the writeback actually delivers the data to the cache.

The pin is transferred to `writeback_control->unpinned_netfs_wb` at the start of writeback. When writeback finishes, the filesystem calls `netfs_unpin_writeback()` inside `->write_inode()` to release the pin. If no `write_inode()` is needed (e.g., no inode metadata changed), `netfs_clear_inode_writeback()` releases the pin directly.

### Writeback entry — `netfs_writepages()`

The VM triggers writeback via `address_space_operations.writepages`, mapped to `netfs_writepages()`. This function:

1. Calls `writeback_iter()` to walk the dirty folios in the mapping's XArray.
2. For each folio, inspects `folio->private` to determine its destination:
   - No `NETFS_FOLIO_COPY_TO_CACHE` marker → dirty from userspace write → goes to server (and possibly cache).
   - `NETFS_FOLIO_COPY_TO_CACHE` marker → previously fetched from server, cached copy outdated → goes to cache only.
3. Allocates a `netfs_io_request` with `origin = NETFS_WRITEBACK`.
4. Calls `begin_writeback(rreq)` — the filesystem enables stream 0 (server-destined writes) and acquires any write-side resources.
5. If fscache is active, enables stream 1 (cache-destined writes).

Dirty folios without the cache-copy marker are assigned to stream 0; folios with the marker are assigned to stream 1. Each stream tiles its subrequests independently:

- Stream 0 calls `prepare_write()` to learn the maximum server RPC size, then `issue_write()` to dispatch the RPC.
- Stream 1 calls the cache's `prepare_write_subreq()` and `issue_write()` to dispatch the cache write.

The two streams operate concurrently. When all subrequests in both streams complete, netfs clears the dirty bits on the processed folios.

### Subrequest lifecycle for writes

A write subrequest follows the same lifecycle as a read subrequest but in reverse:

1. **Preparation** (`prepare_write(sreq, len, fully_written, may_split)`): filesystem negotiates the maximum subrequest size. The `may_split` flag indicates whether netfs is allowed to create additional subrequests for the remainder; if false, the filesystem must accept the entire remaining length.
2. **Issue** (`issue_write(sreq)`): filesystem dispatches the RPC and returns immediately.
3. **Completion**: filesystem calls `netfs_write_subreq_terminated(sreq, error, was_async)`. netfs updates accounting, unlocks the subrequest, and wakes the collector.

`netfs_write_subreq_terminated()` is designed to be usable directly as a `kiocb` completion handler for filesystems that use async I/O internally.

### Failure handling and retry

If a server write subrequest fails, netfs marks the affected folios as `!uptodate` and re-queues them as dirty. The writeback will retry on the next writeback cycle. If the failure is retryable within the same writeback pass (e.g., the filesystem's `retry_request()` callback indicates resources have been re-acquired), netfs immediately re-prepares and re-issues the failed subrequests.

If a cache write subrequest fails, netfs calls `invalidate_cache(rreq)` to remove the stale cache entry. The folio remains dirty and will be written to the server on the next writeback pass; the cache entry will be re-populated on the next read.

### DIO write path

When `netfs_file_write_iter()` detects unbuffered mode or O_DIRECT:

1. User pages are pinned via `get_user_pages()`.
2. A `netfs_io_request` with `origin = NETFS_DIO_WRITE` is built against the pinned user buffer.
3. Subrequests are generated (same prepare/issue lifecycle) and dispatched.
4. On completion, pages are unpinned and the byte count returned.

DIO writes bypass the page cache entirely and do not interact with the cache layer. Ordering is provided by the server's own concurrency control.

### Writethrough mode

When `NETFS_ICTX_WRITETHROUGH` is set on the inode, `netfs_file_write_iter()` does not defer writeback to the VM's periodic flush. Instead, it writes data into the page cache *and* immediately dispatches an `NETFS_WRITEBACK_SINGLE` writeback pass on the affected folios before returning to the caller. This ensures durability at the cost of per-write RPC latency.

### Single-blob writeback

For read-only monolithic objects (`NETFS_ICTX_SINGLE_NO_UPLOAD`), `netfs_writeback_single()` issues a single cache write for the entire file without splitting into subrequests. This is appropriate for cached executables or read-only data blobs where the entire content is always fetched and stored atomically.

## Key Data Structures

**`struct netfs_io_request`** (`include/linux/netfs.h`) — write request container.
- `origin` — `NETFS_WRITEBACK`, `NETFS_DIO_WRITE`, `NETFS_WRITEBACK_SINGLE`
- `io_streams[0]` — server-destined stream (stream 0)
- `io_streams[1]` — cache-destined stream (stream 1)

**`struct netfs_io_subrequest`** (`include/linux/netfs.h`) — one RPC or cache write operation.
- `stream_nr` — 0 = server, 1 = cache

**`writeback_control`** (`include/linux/writeback.h`) — VM writeback control struct.
- `unpinned_netfs_wb` — set by netfs when releasing the inode pin during writeback

## Key Functions / Entry Points

**`netfs_file_write_iter(iocb, from)`** (`fs/netfs/`) — `file_operations.write_iter` entry; auto-selects buffered, writethrough, or DIO based on inode flags and `iocb->ki_flags`.

**`netfs_perform_write(iocb, iter, group)`** (`fs/netfs/`) — pre-locked buffered write; called by filesystems that manage locking themselves.

**`netfs_writepages(mapping, wbc)`** (`fs/netfs/`) — `aops->writepages` entry; walks dirty folios, builds multi-stream request.

**`netfs_dirty_folio(mapping, folio)`** (`fs/netfs/`) — `aops->dirty_folio` entry; marks folio dirty and pins fscache cookie if active.

**`netfs_invalidate_folio(folio, offset, length)`** (`fs/netfs/`) — `aops->invalidate_folio`; clears `NETFS_FOLIO_COPY_TO_CACHE` on partial truncation.

**`netfs_release_folio(folio, gfp)`** (`fs/netfs/`) — `aops->release_folio`; declines release if folio is pending cache copy.

**`netfs_unpin_writeback(inode, wbc)`** (`fs/netfs/`) — releases the fscache cookie pin after writeback completes; called from `->write_inode()`.

**`netfs_clear_inode_writeback(inode, cookie)`** (`fs/netfs/`) — releases the pin when no `write_inode()` is needed.

**`begin_writeback(rreq)`** (filesystem callback) — filesystem enables stream 0; acquires write-side resources.

**`prepare_write(sreq, len, fully_written, may_split)`** (filesystem callback) — negotiates subrequest size.

**`issue_write(sreq)`** (filesystem callback) — dispatches RPC; must call `netfs_write_subreq_terminated()` on completion.

**`invalidate_cache(rreq)`** (filesystem callback) — cache write failed; filesystem removes stale cache entry.

## Important Flags & Config Options

- `NETFS_ICTX_WRITETHROUGH` — synchronous write-through; no deferred writeback
- `NETFS_ICTX_UNBUFFERED` — DIO mode; no page cache involvement
- `NETFS_ICTX_SINGLE_NO_UPLOAD` — single-blob; server writes disabled, cache-only
- `NETFS_FOLIO_COPY_TO_CACHE` — folio flag: route this folio to cache only during writeback
- `I_PINNING_NETFS_WB` — inode state flag: fscache cookie pinned for pending writeback

## Interactions with Other Subsystems

- **↑ VFS**: `netfs_writepages()` and `netfs_dirty_folio()` registered in `address_space_operations`; `netfs_file_write_iter()` in `file_operations`.
- **→ Filesystem RPC layer**: `issue_write()` drives the filesystem's async RPC engine.
- **→ [[fscache]]**: `netfs_dirty_folio()` calls `fscache_dirty_folio()`; cache writeback calls `fscache_write_to_cache()`; pin management uses `fscache_unpin_writeback()`.
- **← [[mm]]**: dirty folio tracking via XArray; writeback control (`struct writeback_control`); folio locking from page cache.

## Design Decisions & Tradeoffs

**Two-stream model for writeback**: An alternative would have been to run a separate writeback pass for cache (after server writeback completes). The two-stream model instead runs both destinations concurrently, halving writeback latency for cache-hit folios at the cost of more complex stream management. The streams tile independently, so their subrequest sizes need not align — this was the key insight that made the two-stream approach practical.

**`NETFS_FOLIO_COPY_TO_CACHE` flag → stream routing**: Early versions used a bespoke "copy to cache" pass after server writeback. Moving the routing decision to folio tagging at dirty time allowed the two streams to be driven from a single `writepages()` walk, eliminating the extra pass and the associated overhead of re-walking the entire dirty range.

**Writeback via `->writepages()` for cache (Linux 6.9)**: Before 6.9, cache-destined data was written via a separate mechanism that bypassed `->writepages()`. Moving it into the standard `writepages()` path eliminated the `I_PINNING_FSCACHE_WB` flag (replaced by `I_PINNING_NETFS_WB`) and unified the two writeback mechanisms into one.

## How It Has Evolved

- **v5.19**: Initial write helper infrastructure; `netfs_perform_write()` introduced.
- **v6.3**: Full write path with two-stream model; `NETFS_FOLIO_COPY_TO_CACHE` mechanism.
- **v6.7**: AFS and CIFS migrate to netfs write path; ~2,000 lines removed from CIFS.
- **v6.9**: Cache writeback moved to `->writepages()` path; `I_PINNING_FSCACHE_WB` retired.
- **v6.13**: Writethrough mode added; single-blob writeback API for read-only objects.

## Further Reading

1. [netfs: Prep for write helpers — LWN.net](https://lwn.net/Articles/886577/)
2. [netfs, afs, 9p, cifs: Rework netfs to use ->writepages() to copy to cache — LWN.net](https://lwn.net/Articles/971770/)
3. [netfs, cifs: Miscellaneous fixes and read/write improvements — LWN.net](https://lwn.net/Articles/979171/)
4. [Network Filesystem Services Library — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html)

## LKML Highlights

- **`->writepages()` for cache copies** (`lwn.net/Articles/971770/`, 2024): The patch series that moved cache-destined writeback into the standard writepages path; the thread discusses how this simplified folio flag accounting and allowed the `I_PINNING_FSCACHE_WB` flag to be retired.
- **Write helper prep** (`lwn.net/Articles/886577/`, 2022): The early write path infrastructure patches; the thread shows the original design debate between a one-shot writeback approach vs. the two-stream model that was ultimately adopted.
