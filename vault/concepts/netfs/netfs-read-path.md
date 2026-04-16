---
title: "netfs Read Path"
category: concept
tags: [netfs, readahead, io, cache, network-filesystem]
subsystem: netfs
kernel_version: "5.13"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html
  - https://lwn.net/Articles/894589/
  - https://lwn.net/Articles/955944/
---

# netfs Read Path

## Purpose

Reading data from a network filesystem is more complex than reading from a local filesystem because the data may reside in multiple places (local cache, remote server, or nowhere — for sparse regions), each with different size constraints and latency profiles. Every read must be decomposed into parallel sub-operations, the results stitched together correctly, and errors from one source (e.g., stale cache entry) silently recovered by falling back to another. Without a shared library to own this complexity, each network filesystem (AFS, CIFS, Ceph, NFS, 9P) would have to reimplement the same logic with subtle differences and bugs. The netfs read path provides a single, correct implementation of readahead, demand reads, and DIO reads that all network filesystems can share.

## Mental Model

The read path acts like a **parallel data assembler** for a jigsaw puzzle. The VM tells netfs "I need the picture from byte 0 to byte 8 MB." netfs looks at which pieces are already in the cache and which need to be fetched from the server, hands each piece to the right worker (cache layer or RPC engine), collects them as they finish, and slides them into the puzzle in order — unlocking each completed section so the caller can start using it without waiting for all the pieces to arrive.

## How It Works

### Entry from the VM

The VFS calls the read path through two `address_space_operations` hooks:

- `netfs_readahead(rac)` — speculative prefetch; the VM has predicted that the process will need this range soon. The `readahead_control` struct describes the range the VM wants filled.
- `netfs_read_folio(file, folio)` — on-demand single-folio read; triggered by a page fault or an explicit `read()` that found an empty folio in the page cache.

Both functions allocate a `netfs_io_request` with the appropriate `origin` field (`NETFS_READAHEAD` or `NETFS_READ_FOLIO`) and enter the same subrequest loop.

### Window expansion

Before entering the subrequest loop, netfs optionally calls the filesystem's `expand_readahead()` callback. This allows filesystems to grow the read window beyond what the VM requested, for alignment or efficiency reasons:

- **Ceph** may round up to a 2 MB RADOS object boundary, so the next cache access is guaranteed to be a hit.
- **9P** may round up to a server-negotiated msize boundary to ensure full RPC utilisation.

Expansion never shrinks the window — it can only add bytes at the end.

### Subrequest generation — cache vs. server decision

Netfs walks the request range folio-by-folio. For each folio, it queries the fscache cookie (if active) via `netfs_cache_ops.prepare_read()`. This returns one of four directives:

- `NETFS_FILL_WITH_ZEROES` — this range is a hole in a sparse file; zero-fill without an RPC or cache read.
- `NETFS_READ_FROM_CACHE` — this range is cached; read from CacheFiles.
- `NETFS_DOWNLOAD_FROM_SERVER` — cache miss; fetch from the server.
- `NETFS_INVALID_READ` — the cache entry exists but is incoherent; treat as a miss.

Contiguous folios returning the same directive are coalesced into a single subrequest to minimise the number of RPCs and cache operations. The coalescing loop also applies the filesystem's `prepare_read()` callback, which caps the subrequest at the filesystem's maximum RPC size. When the cap is reached, the current subrequest is closed and a new one started for the remainder.

### Dispatch

For `NETFS_DOWNLOAD_FROM_SERVER` subrequests, netfs calls the filesystem's `issue_read(sreq)`. The filesystem starts its asynchronous RPC (e.g., an AFS `FetchData` RPC or a CIFS `READ` SMB2 request) and returns immediately. It will call `netfs_read_subreq_terminated()` when the RPC completes.

For `NETFS_READ_FROM_CACHE` subrequests, netfs invokes `netfs_cache_ops.read()` directly on the fscache cookie, which dispatches the read to CacheFiles. CacheFiles issues an async DIO read against the local backing store and calls `netfs_read_subreq_terminated()` on completion.

For `NETFS_FILL_WITH_ZEROES`, netfs zero-fills the folio range inline and marks the subrequest complete immediately.

All subrequests within the single read stream are in-flight simultaneously once issued — there is no artificial serialisation.

### Result collection and folio unlocking

A single shared work item (the "collector") waits for subrequest completions. When a filesystem or cache calls `netfs_read_subreq_terminated()`, it sets a completion flag and wakes the collector. The collector processes completions in request-order, not completion-order — it unlocks folios only when all bytes up to a given offset have been confirmed delivered.

For large reads, `netfs_read_subreq_progress()` provides an interim progress signal. When a filesystem has transferred partial data (e.g., data for the first 512 KB of a 4 MB subrequest has arrived), it can call this function to notify the collector, which immediately unlocks the folios that are complete. This pipeline means a sequential reader can begin consuming early data while the tail of the read is still in flight.

When a subrequest's data ends before `len` bytes (the file has ended), the filesystem sets `NETFS_SREQ_HIT_EOF`. Netfs zero-fills the remainder of the folio and marks all subsequent folios in the request as filled-with-zeros rather than issuing more RPCs.

### Cache-miss escalation and retry

If a `NETFS_READ_FROM_CACHE` subrequest fails (e.g., the CacheFiles entry is corrupted or the cache cookie has been invalidated), netfs does not return an error. Instead, it retiles the failed subrequest as `NETFS_DOWNLOAD_FROM_SERVER` and re-prepares it (potentially with different size constraints). The filesystem's `issue_read()` runs as if the cache never existed.

If a server subrequest fails with a retryable error (e.g., `EAGAIN`, connection reset), netfs waits for all sibling subrequests to finish, then calls the filesystem's `retry_request()` callback. The filesystem may re-acquire state (e.g., refresh a Kerberos ticket, reopen a connection) before netfs re-issues the failed subrequests.

### DIO read path

When `netfs_file_read_iter()` detects that the file is in unbuffered mode (`NETFS_ICTX_UNBUFFERED`) or the user requested O_DIRECT, it uses the DIO path:

1. `get_user_pages()` pins the user-space destination buffer.
2. An `iov_iter` is built over the pinned pages.
3. A `netfs_io_request` with `origin = NETFS_DIO_READ` is built against the user-space iterator rather than the page cache.
4. Subrequests are generated and issued exactly as in the buffered path.
5. On completion, pages are unpinned and the byte count returned to the caller.

The DIO path bypasses all folio locking and page cache interaction, relying on server-side ordering for coherency.

### Post-read writeback to cache

When a `NETFS_DOWNLOAD_FROM_SERVER` subrequest completes successfully and an fscache cookie is active, netfs marks the newly-filled folios with `NETFS_FOLIO_COPY_TO_CACHE`. These folios are written back to the local cache during the next `netfs_writepages()` pass (or immediately if writethrough mode is active). This is the mechanism by which a cold file warms the cache after its first network fetch.

## Key Data Structures

**`struct netfs_io_request`** (`include/linux/netfs.h`) — read request container.
- `origin` — `NETFS_READAHEAD` / `NETFS_READ_FOLIO` / `NETFS_DIO_READ`
- `io_streams[0]` — the single read stream

**`struct netfs_io_subrequest`** (`include/linux/netfs.h`) — one cache or RPC read operation.
- `start / len` — file range
- `io_iter` — points at the target folios
- `transferred` — bytes received
- `error` — 0 on success, negative errno on failure

**`struct netfs_cache_ops`** (`include/linux/netfs.h`) — cache-side callback table.
- `prepare_read()` — returns cache directive (hit/miss/zero/invalid)
- `read()` — dispatches cache read; calls `netfs_read_subreq_terminated()` on completion

## Key Functions / Entry Points

**`netfs_readahead(rac)`** (`fs/netfs/`) — `aops->readahead` entry point; builds request from readahead_control.

**`netfs_read_folio(file, folio)`** (`fs/netfs/`) — `aops->read_folio` entry point; single-folio demand read.

**`netfs_read_subreq_terminated(sreq, error, was_async)`** (`fs/netfs/`) — called by filesystem/cache on subrequest completion; wakes the collector.

**`netfs_read_subreq_progress(sreq, was_async)`** (`fs/netfs/`) — called for partial completion; enables early folio unlock.

**`expand_readahead(rreq)`** (filesystem callback) — optionally widens the readahead window for alignment.

**`prepare_read(sreq, expand)`** (filesystem callback) — caps subrequest size to the filesystem's RPC limit.

**`issue_read(sreq)`** (filesystem callback) — dispatches RPC; *must* call `netfs_read_subreq_terminated()` on completion.

## Important Flags & Config Options

- `NETFS_ICTX_UNBUFFERED` — forces DIO path; page cache not used
- `NETFS_SREQ_HIT_EOF` — subrequest flag: EOF encountered; netfs zero-fills remainder
- `NETFS_SREQ_MADE_PROGRESS` — subrequest flag: `transferred > 0`
- `NETFS_SREQ_BOUNDARY` — subrequest flag: boundary for cache/RPC alignment
- `NETFS_FOLIO_COPY_TO_CACHE` — folio flag: data fetched from server; schedule copy to local cache

## Interactions with Other Subsystems

- **↑ VFS**: `netfs_readahead()` and `netfs_read_folio()` are registered in `address_space_operations`; VFS calls them without knowing about the underlying implementation.
- **→ Filesystem RPC layer**: `issue_read()` callback dispatches to the filesystem's network protocol (RxRPC, SMB2, RADOS, 9P msize).
- **→ [[fscache]]**: cache directive queries via `netfs_cache_ops.prepare_read()`; cache reads via `netfs_cache_ops.read()`; post-read cache fill via `netfs_writepages()`.
- **← [[mm]]**: folio allocation (for the page cache), `get_user_pages()` (for DIO), and XArray traversal (for readahead window walking) are all mm facilities.

## Design Decisions & Tradeoffs

**Automatic cache-miss escalation**: Early designs required filesystems to handle cache errors explicitly. The current design hides cache failures from the filesystem entirely — netfs promotes a failed cache subrequest to a server fetch without calling any filesystem callback. This simplifies filesystem implementation at the cost of slightly delayed error surfacing (the error becomes visible only after the fallback fetch also fails).

**Coalescing contiguous same-directive folios**: Coalescing reduces RPC count dramatically for large sequential reads. The alternative (one subrequest per folio) would generate hundreds of RPCs for a 1 MB read with 4 KB folios. The tradeoff is that a single RPC failure causes a larger retry unit, but the retry machinery handles this correctly.

**Pipelining via `netfs_read_subreq_progress()`**: This is optional — filesystems can call only `netfs_read_subreq_terminated()`. The progress function exists for high-latency protocols (e.g., AFS over a WAN) where waiting for an entire 4 MB RPC before unlocking any folios would cause visible latency spikes.

## How It Has Evolved

- **v5.13**: Initial read path with readahead and read_folio support; read from cache or server.
- **v6.0**: Ceph and 9P migrated to use the shared read path, removing their own implementations.
- **v6.3**: DIO read path added; `netfs_file_read_iter()` introduced to auto-select buffered vs. DIO.
- **v6.5**: AFS fully migrated; approximately 3,000 lines of AFS read code deleted.
- **v6.13**: Per-subrequest collector work items replaced by a single work item; sequential-read latency reduced significantly.

## Further Reading

1. [Network Filesystem Services Library — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html)
2. [The netfslib helper library — LWN.net](https://lwn.net/Articles/894589/)
3. [netfs, afs, 9p: Delegate high-level I/O to netfslib — LWN.net](https://lwn.net/Articles/955944/)

## LKML Highlights

- **AFS/9P I/O delegation** (`20231212` thread, Dec 2023, `lwn.net/Articles/955944/`): The series that completed AFS and 9P migration; thread includes discussion of how the callback interface was simplified compared to the previous per-filesystem implementations and the ~800-line reduction in AFS alone.
