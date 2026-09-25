---
title: "netfs I/O Request Model — Explained"
category: explained
original: "[[netfs-io-request-model]]"
subsystem: netfs
tags: [explained, netfs, io-requests, retries]
converted: 2026-09-25
---

# The netfs I/O request model, explained

> Plain-language companion to [[netfs-io-request-model|the technical note]]. Same facts, fewer identifiers.

## The problem

A single read from the page cache, say 8 MB, may have to be served partly from a local cache and partly over the network, with each network call capped at the server's size limit and each cache operation aligned to the cache's own block size. All the pieces should run in parallel, and the results have to be stitched back into one correct answer. Writes are worse: the same dirty data may need to go to two places with two different size limits.

Without a shared structure for this, every network filesystem would invent its own splitting, retrying and reassembly, and get it subtly wrong.

## The idea in one paragraph

Run each I/O like a **construction project**. The **request** is the general contractor: it owns the overall scope and schedule. **Streams** are the subcontractors for each trade (the server, the local cache), working in parallel on their own schedules without knowing about each other. **Subrequests** are individual work orders, each going to exactly one subcontractor with its own completion status. The contractor collects completions, checks the result, and reissues failed work orders, and the client (the page cache) never sees the internal coordination.

## Step by step

### Step 1: Open a request
When readahead, a single-page read, direct I/O or writeback starts, netfs takes a request from a reserved pool. It records which file, the byte range, what kind of operation it is, and slots for streams. The filesystem's setup callback then runs, letting it attach its own per-request state, such as an authentication token or a connection reference. That state is released when the request is torn down.

### Step 2: Choose streams
A stream is one destination:
- **Reads** always have exactly one stream, which carries a mix of cache hits and server fetches.
- **Writes** can have two, running in parallel: stream 0 to the server (switched on by the filesystem when writeback begins) and stream 1 to the local cache (switched on when a cache handle is active).

This is the key design choice. The two write destinations have different size limits (a server might take 4 MB per call while the cache works in 256 KB chunks), so each stream cuts the same dirty range into its own pieces, and their boundaries don't need to match. Pages that only need copying to the cache appear only in stream 1.

### Step 3: Cut subrequests
A subrequest is the smallest unit: one network call or one cache operation. It holds its slice of the range, a buffer description pointing straight at the target pages (or pinned user pages for direct I/O) that the filesystem can hand to its network code as-is, a count of bytes moved so far, which stream it belongs to, and an error status.

Before issuing each one, netfs asks the filesystem (or the cache) how big it may be, caps it at that, and starts a new subrequest for the remainder.

### Step 4: Dispatch in parallel
Subrequests are prepared and issued one after another within a stream, but once issued they all run concurrently, across both streams too. A big read can have many pieces in flight at once.

### Step 5: Collect results in one place
Since 6.13, one shared collector handles all completions. Each finishing subrequest marks itself done and wakes the collector, which processes completions in order and releases pages whose data has fully arrived, so the program can start on early pages while later ones are still coming. Earlier, each subrequest queued its own work item, and on large sequential reads many completed at almost the same moment, causing a stampede of wakeups.

### Step 6: Retry quietly
If a subrequest fails, netfs doesn't report it straight away. It waits for the siblings to finish, then:
1. calls the filesystem's retry hook so it can refresh resources (a Kerberos ticket, a connection)
2. prepares and reissues only the failed pieces, possibly with different sizes
3. turns a failed cache read into a server fetch automatically

Once a filesystem can issue reads, it never has to handle cache failures or resizing itself.

## The picture

```text
 request (file, range, kind)
 ├─ stream 0 → server:  [ 4 MB ][ 4 MB ][ 2 MB ]          ← sized by the filesystem
 └─ stream 1 → cache:   [256K][256K][256K][256K]…          ← sized by the cache
          all pieces in flight at once
                  │ completions
            single collector ──▶ release finished pages in order
                  │ any failures?
            retry hook → reissue failed pieces (cache miss → server fetch)
```

## Tradeoffs

- **What it gives you:** the page cache's view, the network's view and the cache's view of I/O kept separate; parallelism; early page release; retries and cache fallback without filesystem involvement.
- **What it costs / requires:** three levels of bookkeeping; errors surface only after all pieces of a request have finished.
- **Where it bites:** the choice of collector design matters a lot for performance. The per-piece design was fine until SMB's large sequential reads exposed its cost.

## How it got here

- **5.13:** requests and subrequests only (no streams), and reads only.
- **6.3:** streams introduced to support writes going to two destinations.
- **6.7:** writeback pinning brought under the request model, retiring fscache's own mechanism.
- **6.13:** the single collector, fixing sequential-read performance for SMB and AFS.
- **2026:** a new buffer model built from chains of page-vector segments, shared by buffered and direct I/O.

## Related

- Technical version: [[netfs-io-request-model]]
- [[netfs-explained|netfs subsystem]], [[netfs-inode-context-explained|Inode context]], [[netfs-read-path|Read path]], [[netfs-write-path|Write path]], [[netfs-operations-table|Operations table]]
- [[fscache-explained|fscache]], [[netfs-helper-library-explained|netfs helper library]], [[page-cache-explained|Page cache]]
