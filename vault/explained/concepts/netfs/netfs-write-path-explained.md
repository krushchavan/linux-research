---
title: "netfs Write Path — Explained"
category: explained
original: "[[netfs-write-path]]"
subsystem: netfs
tags: [explained, netfs, writeback, fscache, direct-io]
converted: 2026-09-25
---

# The netfs write path, explained

> Plain-language companion to [[netfs-write-path|the technical note]]. Same facts, fewer identifiers.

## The problem

Writing through a network filesystem raises problems local filesystems don't have. The same data may need to reach two places at once, the remote server and a local disk cache, each with its own size limits and alignment. The local cache's resources mustn't be thrown away between the moment data is dirtied and the moment it's written back. And failures need careful handling: sometimes the right response is to refresh an authentication token and try again straight away, sometimes to wait for the next writeback round.

## The idea in one paragraph

Run writeback as a **two-lane dispatch system**. Lane 0 carries data to the server; lane 1 carries data to the local cache. Each lane chops the work into its own sizes and runs at its own pace. A page travels in one lane or both, depending on whether it's new data the server needs or data that only needs refreshing in the cache. netfs does the dispatching, tracks what each lane has delivered, and **pins** the cache's resources so they can't vanish while work is in flight.

## Step by step

### Step 1: A buffered write from a program
A `write` call enters netfs, which takes the buffered-write lock (writers exclude each other, though not readers) and walks the range page by page: lock the page, copy the program's data in, mark it dirty. It then lets the filesystem update the modification time or version number, and returns the byte count. The write looks finished to the program, but the data only reaches the server later, at writeback.

### Step 2: Pin the cache
When a page is dirtied while a cache is active, netfs marks the inode as **pinning** the cache. Without this, memory pressure could tear down the cache's backing storage between dirtying the page and writing it back. At writeback the pin is handed over to the writeback machinery, and released afterwards, either when the filesystem writes the inode's metadata or directly if there's no metadata to write.

### Step 3: Writeback sorts the pages
This is the key step. When the kernel starts writeback, netfs walks the file's dirty pages and routes each one:
- pages dirtied by program writes go to the **server lane**
- pages carrying a **copy-to-cache** marker (data fetched from the server whose cached copy is out of date) go to the **cache lane** only

It creates a writeback request, lets the filesystem switch on the server lane (and take resources such as dirty-byte accounting), and switches on the cache lane if a cache is active.

### Step 4: Each lane cuts its own pieces
The server lane asks the filesystem how big each write may be, then issues it. The cache lane asks the cache the same and issues cache writes. Piece boundaries in the two lanes needn't match, which is what makes running both at once practical. When every piece in both lanes has finished, the pages' dirty flags are cleared.

Each piece is prepared (with a flag saying whether netfs may split off the remainder), issued, and completed when the filesystem calls netfs's completion function, which can double as the completion routine for the filesystem's own asynchronous I/O.

### Step 5: When writes fail
- **Server write fails:** the pages are marked not up to date and re-dirtied, to be retried at the next writeback. If the filesystem's retry hook says it has recovered (say, a fresh token), netfs re-prepares and reissues the failed pieces immediately.
- **Cache write fails:** netfs asks the filesystem to invalidate the cache entry, so no stale copy is left. The cache refills on the next read.

### Step 6: Direct writes
For direct I/O, or files that bypass the cache, netfs pins the program's buffer, builds the request against it, issues pieces the same way, then unpins and returns. The page cache and local cache aren't involved at all; the server's own concurrency control provides ordering.

### Step 7: Write-through and single objects
- **Write-through mode:** after copying into the page cache, netfs immediately writes the affected pages back before returning, trading latency on every write for durability.
- **Single read-only objects** (a cached executable, say): writeback is one cache write for the whole file, never to the server.

## The picture

```text
 write(): copy into pages → mark dirty → pin cache (if active) → return

 writeback:
   dirty pages ─┬─ program-written ──────▶ lane 0: server  [ call ][ call ][ call ]
                └─ "copy to cache" only ─▶ lane 1: cache   [blk][blk][blk][blk][blk]
                      both lanes run at once; boundaries independent
   all done → clear dirty flags → release cache pin
   server failure → re-dirty (or retry now)     cache failure → invalidate cache entry
```

## Tradeoffs

- **What it gives you:** server and cache written in one pass, each in its own best sizes; cache resources protected during writeback; retries without filesystem-specific plumbing.
- **What it costs / requires:** more complex bookkeeping for two lanes and for pinning; filesystems must release the pin at the right moment.
- **Where it bites:** a buffered write "succeeds" before the server has the data. Errors show up later at writeback (or never reach the program) unless write-through is used.

## How it got here

- **5.19:** early write-helper infrastructure and a shared buffered-write routine. The design debate compared a one-shot writeback with the two-lane model, and the two-lane model won.
- **6.3:** the full write path with two lanes and the copy-to-cache marker.
- **6.7:** AFS and SMB/CIFS move over, removing about 2,000 lines from SMB/CIFS alone.
- **6.9:** cache copies go through the standard writeback path, retiring fscache's separate pinning flag.
- **6.13:** write-through mode and single-object writeback.

## Related

- Technical version: [[netfs-write-path]]
- [[netfs-explained|netfs subsystem]], [[netfs-io-request-model-explained|Request model]], [[netfs-read-path-explained|Read path]], [[netfs-operations-table-explained|Operations table]], [[netfs-inode-context-explained|Inode context]]
- [[fscache-explained|fscache]], [[writeback-infrastructure-explained|Writeback]], [[page-cache-explained|Page cache]]
