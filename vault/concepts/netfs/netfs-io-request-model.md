---
title: "netfs I/O Request Model"
category: concept
tags: [netfs, io, subrequest, stream, network-filesystem]
subsystem: netfs
kernel_version: "5.13"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html
  - https://lwn.net/Articles/894589/
  - https://lwn.net/Articles/951936/
---

# netfs I/O Request Model

## Purpose

Network filesystem I/O is intrinsically multi-source and multi-constraint: a single 8 MB read from the VM might require mixing cache hits with RPCs, each capped at a different maximum size, dispatched in parallel, and assembled into a coherent result. Without a structured model, each filesystem would implement its own ad-hoc request splitting, retry logic, and result stitching. The netfs I/O request model provides a three-level hierarchy — request → stream → subrequest — that decouples the VM's view of I/O from the filesystem's RPC view and the cache's block-aligned view, letting netfs handle the coordination on behalf of all network filesystems.

## Mental Model

Think of it like a **construction project with a general contractor (the request), subcontractors for each trade (streams), and individual work orders (subrequests)**. The general contractor owns the overall scope and schedule. Electrical and plumbing subcontractors work in parallel on their own materials and timelines without knowing about each other. Each work order goes to exactly one subcontractor and has its own completion status. The general contractor collects all completions, verifies the outcome, and issues punch-list retries when something fails — without the client (the VM) ever seeing the internal coordination.

## How It Works

### Request allocation

When the VM calls `netfs_readahead()` or `netfs_read_folio()`, netfs allocates a `netfs_io_request` from a mempool. The request captures the file identity (`inode`, `mapping`), the overall file range (`start`, `len`), the origin type (`NETFS_READAHEAD`, `NETFS_READ_FOLIO`, `NETFS_DIO_READ`, `NETFS_WRITEBACK`, etc.), and an embedded array of `netfs_io_stream` slots.

The filesystem's `init_request()` callback runs at this point, giving the filesystem a chance to attach per-request private state — for example, acquiring an authentication token or incrementing a reference count on a connection. Any data stored in `rreq->netfs_priv` is released by `free_request()` when the request is torn down.

### Streams

A `netfs_io_stream` is a logical I/O destination: either the remote server or the local cache. For reads, there is always exactly one stream (`io_streams[0]`), which receives a mix of cache-hit and server-miss subrequests. For writes, up to two streams run in parallel:

- **Stream 0** — server-destined writes; enabled by the filesystem's `begin_writeback()` callback
- **Stream 1** — cache-destined writes; enabled when an active fscache cookie is present

The two-stream write model exists because cache-destined and server-destined writes have independently negotiated sizes (a server might cap at 4 MB while the cache works in 256 KB chunks) and independent subrequest boundaries. A folio marked `NETFS_FOLIO_COPY_TO_CACHE` appears only in stream 1; an unmarked dirty folio appears in stream 0. Each stream tiles its subrequests independently across the dirty range — the subrequest boundaries of stream 0 and stream 1 need not align.

### Subrequests

A `netfs_io_subrequest` is the atomic unit of I/O — one RPC or one cache operation. It carries:

- **`start` / `len`**: the slice of the parent request's range it covers
- **`io_iter`**: a kernel `iov_iter` pointing directly at the target folios (or pinned user pages for DIO), so the filesystem can pass it straight to its RPC layer
- **`transferred`**: bytes moved so far, enabling partial-completion accounting
- **`stream_nr`**: which stream (`0` = server, `1` = cache) owns this subrequest
- **`error`**: completion status; 0 = success

Before issuing a subrequest, netfs calls the filesystem's (or cache's) `prepare_read()` / `prepare_write()` callback to learn the maximum length for this subrequest — each filesystem has its own RPC size limit, and the cache has its own block size. Netfs then caps the subrequest at that limit and creates another subrequest for the remainder.

### Parallel dispatch and result collection

Subrequests within a stream are issued sequentially (preparation then issue), but subrequests across streams run in parallel. Because cache reads and server reads within a single stream can also run concurrently (once issued, they all fly in parallel), a large read may have many in-flight subrequests simultaneously.

Results are collected by a single shared work item (since Linux 6.13) rather than one work item per subrequest. As each subrequest calls its termination function (`netfs_read_subreq_terminated()` or `netfs_write_subreq_terminated()`), it sets a completion flag and wakes the collector. The collector processes completed subrequests in order, calling `netfs_read_subreq_progress()` to unlock folios whose data has fully arrived. This pipelining means the calling process can begin reading early folios while later subrequests are still in flight.

### Retry loop

If any subrequest fails, netfs does not immediately surface the error. It waits for all sibling subrequests to finish, then enters a retry loop:

1. Calls the filesystem's `retry_request()` callback, giving the filesystem a chance to re-acquire resources (e.g., refresh a Kerberos ticket, re-establish a connection)
2. Re-prepares and re-issues only the failed subrequests, potentially with different size constraints
3. If a cache-read subrequest fails, netfs automatically retiles it as a server-fetch subrequest — the filesystem never has to handle cache-miss fallback explicitly

This retry transparency is a key design goal: once the filesystem provides `issue_read()`, it does not need to worry about transient cache failures or RPC size renegotiation.

## Key Data Structures

**`struct netfs_io_request`** (`include/linux/netfs.h`) — owns an entire logical I/O operation from the VM's perspective.
- `origin` — type discriminator: readahead, read_folio, DIO, writeback, etc.
- `inode / mapping` — file references
- `io_streams[]` — array of up to 2 `netfs_io_stream` structs
- `start / len` — file position and total extent of this request
- `netfs_priv / netfs_priv2` — opaque filesystem-private data slots
- `flags` — retry indicators, abort signals, DIO markers

**`struct netfs_io_stream`** (`include/linux/netfs.h`) — a logical destination (server or cache) with its own tiling of subrequests.
- `stream_nr` — 0 for server, 1 for cache
- `active` — whether this stream is in use for this request

**`struct netfs_io_subrequest`** (`include/linux/netfs.h`) — one RPC or cache operation.
- `rreq` — back-pointer to parent request
- `start / len` — slice of the parent range
- `transferred` — bytes completed so far
- `io_iter` — buffer iterator for this subrequest's data
- `stream_nr` — owning stream index
- `error` — completion status
- `flags` — `NETFS_SREQ_MADE_PROGRESS`, `NETFS_SREQ_HIT_EOF`, `NETFS_SREQ_BOUNDARY`

## Key Functions / Entry Points

**`netfs_readahead()`** (`fs/netfs/read_collect.c`) — VM readahead entry; allocates request, optionally expands window, walks range into subrequests.

**`netfs_read_folio()`** (`fs/netfs/`) — single-folio read; same request machinery, `origin = NETFS_READ_FOLIO`.

**`netfs_writepages()`** (`fs/netfs/`) — writeback entry; walks dirty folios, builds multi-stream request.

**`netfs_read_subreq_terminated()`** (`fs/netfs/`) — called by filesystem/cache on subrequest completion; wakes the result collector.

**`netfs_read_subreq_progress()`** (`fs/netfs/`) — interim progress notification; allows early folio unlock before full subrequest completion.

**`netfs_write_subreq_terminated()`** (`fs/netfs/`) — write-side completion; also usable directly as a `kiocb` completion handler.

## Important Flags & Config Options

- `CONFIG_NETFS_SUPPORT` (tristate) — enables the entire library; automatically selected by AFS, CIFS, Ceph, 9P
- `CONFIG_NETFS_STATS` — exports per-operation counters to `/proc/fs/fscache/stats`
- `CONFIG_NETFS_DEBUG` — runtime debug flags at `/sys/module/netfs/parameters/debug`
- `NETFS_SREQ_HIT_EOF` — subrequest flag: data ended before `len`; netfs zero-fills the remainder
- `NETFS_SREQ_BOUNDARY` — subrequest flag: this subrequest ends at a cache or RPC alignment boundary
- `NETFS_SREQ_MADE_PROGRESS` — set when `transferred > 0`; used by the collector to track forward progress

## Interactions with Other Subsystems

- **↑ VM/VFS**: `netfs_readahead()` / `netfs_read_folio()` / `netfs_writepages()` are called directly by the VFS via `address_space_operations`.
- **→ Filesystem RPC layer**: netfs invokes `issue_read()` / `issue_write()` from `netfs_request_ops`; the filesystem's RPC engine runs independently and calls back on completion.
- **→ [[fscache]]**: cache subrequests invoke `netfs_cache_ops.read()` / `netfs_cache_ops.issue_write()` on the fscache cookie; fscache dispatches to CacheFiles.
- **← [[mm]]**: Folios are allocated and managed by the page allocator / slab; netfs walks the page cache XArray to find and lock folios before building subrequests.

## Design Decisions & Tradeoffs

**Three levels vs. two** (request + subrequest, no stream): A flat model would work for reads, where there is only one destination. For writes with mixed server + cache destinations, a flat model would require the filesystem to manage two parallel RPC sequences with different alignment — defeating the purpose of the library. The stream level was added specifically to handle the two-write-destination case while keeping the filesystem interface simple.

**Single collector work item (Linux 6.13)**: Originally, each subrequest queued its own work item for result processing. This caused thundering-herd wakeups on large sequential reads (many subrequests completing near-simultaneously, all queuing work items). The single collector processes all completions from one work item, reducing scheduler churn significantly for the dominant sequential-read workload.

**Automatic cache-miss escalation**: When a cache subrequest fails, netfs silently promotes it to a server fetch rather than returning an error to the filesystem. This keeps cache involvement transparent — filesystems don't need cache-aware error handling, and transient cache failures don't propagate to user processes.

## How It Has Evolved

- **v5.13**: Initial model with request + subrequest (no stream abstraction); reads only.
- **v6.3**: Stream concept introduced to support multi-destination writes.
- **v6.7**: Writeback pinning unified under the request model; fscache's own pinning mechanism retired.
- **v6.13**: Per-subrequest work items replaced by single collector work item (performance fix for CIFS/AFS sequential reads).
- **2026**: `bvecq` redesign replaces `folio_queue` / `rolling_buffer` buffer model; unified `bio_vec` chain for both buffered and DIO paths.

## Further Reading

1. [The netfslib helper library — LWN.net](https://lwn.net/Articles/894589/)
2. [netfs, afs, cifs: Delegate high-level I/O to netfslib — LWN.net](https://lwn.net/Articles/951936/)
3. [Network Filesystem Services Library — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html)

## LKML Highlights

- **Single collector redesign** (`20241216204124.3752367-1-dhowells@redhat.com`, Dec 2024): 32-patch series fixing the per-subrequest work-item overhead; thread includes profiling data from CIFS benchmarks that quantify the latency reduction for sequential reads.
- **`bvecq` redesign** (`20260326104544.509518-1-dhowells@redhat.com`, March 2026): 26-patch series replacing `folio_queue` with segmented `bio_vec` chains; the discussion covers the motivation (unifying buffered and DIO buffer models) and the tradeoff of increased allocator complexity against zero-copy RPC dispatch.
