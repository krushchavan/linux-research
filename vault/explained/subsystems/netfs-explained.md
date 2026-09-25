---
title: "netfs Subsystem — Explained"
category: explained
original: "[[netfs]]"
subsystem: netfs
tags: [explained, netfs, network-filesystems, fscache, page-cache]
converted: 2026-09-25
---

# The netfs library, explained

> Plain-language companion to [[netfs|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Every network filesystem (AFS, SMB/CIFS, Ceph, 9P, NFS) has to do the same heavy lifting between the kernel's memory management and its own network calls: buffered reads, readahead, writeback, direct I/O, retries, and optionally keeping a copy on local disk. The memory side thinks in pages and address spaces; the network side thinks in wire operations with their own size limits. Bridging the two correctly is hard, and each filesystem used to do it separately, duplicating thousands of lines and breaking whenever the memory-management interfaces changed.

## The big picture

netfs is a **general-purpose I/O contractor** between the memory side and a filesystem's network engine. The filesystem registers a table of callbacks ("here's how to send a read", "here's how big one can be"), and netfs does everything else: slicing requests, interleaving cache hits with network fetches, collecting results, releasing pages as data lands, and retrying failures. The filesystem only ever sees individual network calls.

```text
   page cache / VFS  (readahead, read page, write back dirty pages…)
            │
        netfs entry points
            │
        request ──▶ stream(s) ──▶ subrequests
                      │                 │
                      │         ┌───────┴────────┐
                      │     filesystem's       local cache
                      │     "issue read/write"  (fscache → CacheFiles)
                      │         │
                      │     network (AFS RxRPC, SMB, Ceph…)
     results flow back up: collect → unlock pages → retry failures
```

Merged in 5.13 by David Howells, it has since absorbed AFS, Ceph, 9P and CIFS. NFS still has its own engine.

## The pieces

### Requests, streams and subrequests
The core of netfs is a three-level model. One **request** covers one operation from the memory side ("read this 4 MB range"). It holds one or more **streams**, each a sequence of pieces heading to one destination: a read uses one; a write can use two, one to the server and one to the local cache. Each stream is cut into **subrequests**, single network calls or cache operations, each sized for its destination.

Streams don't have to line up. Pages that only need copying into the cache appear only in the cache stream, which avoids a separate writeback pass just for the cache. When pieces finish, pages are released progressively, and failed pieces are retried after giving the filesystem a chance to adjust (for example, to get a fresh token). See [[netfs-io-request-model-explained|the request model]].

### Per-file context
Each file gets a small netfs record embedded next to the regular inode in the filesystem's own inode structure, so netfs can find it at no cost. It holds the callback table, the local-cache handle (if any), the **server's idea of the file size** (which can briefly differ from the local one during concurrent changes), and policy flags: bypass the page cache, write through synchronously, or treat the file as a single read-only blob.

netfs also sorts I/O into locking classes so it doesn't over-serialise:
- buffered reads run fully concurrently
- buffered writes exclude each other but not reads
- direct I/O runs concurrently, with the server providing ordering
- truncate and fallocate are exclusive
- memory mappings are a fifth, special case

See [[netfs-inode-context-explained|the inode context]].

### The read path
Readahead, single-page reads and direct reads share one loop. The filesystem may first widen the window (Ceph can round up to a 2 MB stripe). Then, for each stretch of the file, netfs asks the local cache what to do: fill with zeros (a hole), read from the cache, download from the server, or treat the cached copy as invalid. Neighbouring pages with the same answer merge into one subrequest to save calls.

Downloads go through the filesystem's size check and "issue read" callback; cache reads go straight to the cache. As progress arrives, finished pages unlock, so early data is usable while later calls are still in flight. Direct reads skip the page cache, pinning the user's buffer and reading into it. See [[netfs-read-path|the read path]].

### The write path
Writeback walks the dirty pages and sorts them: cache-only copies go to the cache stream; ordinary dirty pages go to the server (and to the cache as well, if one is active). Each stream is cut to its own destination's limits. A failed server write re-dirties the pages for another try; a failed cache write makes the filesystem invalidate its cache entry.

A subtle part is **pinning**: while pages are dirty, the file's cache handle mustn't be torn down. netfs marks the inode when pages are dirtied and releases the pin once writeback has finished. See [[netfs-write-path|the write path]].

### The operations table
This is the contract. A filesystem provides one table of callbacks: set up and free requests, widen readahead, size and issue reads, begin writeback, size and issue writes, retry, invalidate the cache, and update the size or modification time. Only "issue read" and "issue write" are required; netfs supplies defaults for the rest, and which callbacks exist decides which features are active. See [[netfs-operations-table-explained|the operations table]].

## A request's journey

A buffered read of a file never read before, on a filesystem with a local cache:

1. **Readahead asks.** The page cache calls netfs, which creates a request for the range.
2. **Widen.** The filesystem rounds the window to a boundary that suits its network calls.
3. **Ask the cache.** Every stretch comes back "download from the server", since the file is cold.
4. **Size and issue.** netfs asks the filesystem how big one call may be (say 4 MB for SMB) and issues the calls; the filesystem sends them asynchronously.
5. **Unlock as data arrives.** This is the key step. As each call reports progress, the pages it has filled are released, so the program can read the start of the file while the rest is still downloading.
6. **Finish and cache.** When calls complete, the data stays in the page cache and is written to the local cache, so the next read is a cache hit.

If a cache read had failed instead (say the cached copy turned out stale), netfs would quietly turn it into a server download. The cache is an optimisation, not a source of truth, so the filesystem never sees the error.

## Tradeoffs

- **What it gives you:** one shared, tested implementation of the hardest I/O plumbing; parallel cache and network traffic; early page release; automatic retries and cache fallback; about 8,000 lines of duplicated code removed.
- **What it costs / requires:** filesystems must restructure around the callback table and embed netfs's per-file record; the request/stream/subrequest machinery is intricate.
- **Where it bites:** performance regressions can appear when a new filesystem is brought on board. Moving SMB over exposed a per-subrequest overhead that hurt sequential reads until the collector was redesigned.

## How it got here

- **5.13 (2021):** initial merge, with read helpers extracted from AFS.
- **5.19–6.0:** groundwork for write helpers and copy-to-cache writeback; roughly 8,000 lines removed across AFS, Ceph and 9P.
- **6.3–6.5:** AFS and 9P hand all high-level I/O to netfs, with a unified buffered-write path.
- **6.7:** SMB/CIFS begins moving over; writeback pinning moves from fscache into netfs. **6.9:** cache copies go through the standard writeback path.
- **6.13:** one collector for all completions instead of one work item per subrequest, fixing sequential-read slowdowns.
- **2026 (in progress):** a new buffer model built from chains of page-vector segments, unifying buffered and direct I/O and letting a whole call's data go to the network in one send. Client-side encryption and possible NFS adoption are discussed but not implemented.

## Related

- Technical version: [[netfs]]
- [[netfs-io-request-model-explained|Request model]], [[netfs-inode-context-explained|Inode context]], [[netfs-read-path|Read path]], [[netfs-write-path|Write path]], [[netfs-operations-table-explained|Operations table]]
- [[netfs-helper-library-explained|netfs helper library (fscache view)]], [[fscache-explained|fscache]], [[cachefiles-backend-explained|CacheFiles]]
- [[network-filesystems-overview-explained|Network filesystems overview]], [[page-cache-explained|Page cache]], [[folio-explained|Folios]], [[writeback-infrastructure-explained|Writeback]]
