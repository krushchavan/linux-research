---
title: "netfs Helper Library — Explained"
category: explained
original: "[[netfs-helper-library]]"
subsystem: fscache
tags: [explained, fscache, netfs, network-filesystems]
converted: 2026-09-25
---

# The netfs helper library, explained

> Plain-language companion to [[netfs-helper-library|the technical note]]. Same facts, fewer identifiers.

## The problem

Every network filesystem has to hook into the page cache the same way: read single pages, do readahead, prepare and finish buffered writes, and support direct I/O. With a local cache in the picture it gets harder. One read may be partly cached and partly not, so it has to be split between the cache and the network. And a write may need to go to *two* places, the server and the cache, each with its own preferred chunk size.

Each filesystem used to implement all of this itself, and each got it wrong in its own way.

## The idea in one paragraph

Put the plumbing in one shared library and let each filesystem supply only "send this read to the server" and "send this write to the server". The library acts like an **air traffic controller**: a read or write arrives as one flight plan, gets broken into legs (some served by the local cache, some by network calls), all legs are dispatched in parallel, and the landings are stitched back together, with pages released to the program as soon as their own leg lands.

## Step by step

### Step 1: Three levels of work
- A **request** is one operation the program sees, such as a readahead of pages 0–127 or a 1 MB write. It holds the file, the byte range and the overall error state.
- A **stream** is a run of pieces going to one destination. A read has one stream; a buffered write to both server and cache has two.
- A **subrequest** is one piece: a single network call or a single cache I/O, with an offset, a length and a completion flag.

### Step 2: Per-file glue
Each filesystem embeds a small library record inside its inode, right next to the regular inode. It holds the filesystem's table of hooks, the file's cache [[fscache-cookie-subsystem-explained|cookie]] (if cached), the point beyond which the file reads as zeros, and mode flags. Because the regular inode sits first, the library can find its record from any inode at zero cost, with no extra context passed around. The price is that every inode pays for these fields even when caching is off, a small fixed cost judged worth the simplicity.

The filesystem's hooks are few: set up a new request, issue a read to the network, prepare a write, issue a write, and clean up when done.

### Step 3: Reading
1. Create a request for the range.
2. Ask [[fscache-explained|fscache]] whether caching is active for this file. If it is, check which byte ranges are already cached and split the range into cached and uncached segments. If not, caching is silently skipped.
3. Cached segments become cache subrequests (served by [[cachefiles-backend-explained|CacheFiles]] with direct I/O); uncached ones become network subrequests handed to the filesystem.
4. Both kinds run at once.

### Step 4: Unlock as each piece lands
This is the key step. When any subrequest completes, the pages it covers are marked valid and unlocked immediately; the program can read them without waiting for the rest. So cache hits reach the program straight away even while slower network calls are still in flight. The alternative, unlocking everything only when the whole request finishes, would let one slow piece stall the program.

### Step 5: Filling the cache behind the scenes
For ranges fetched from the network because they weren't cached, the library schedules a background write into the cache. The program isn't kept waiting for it.

### Step 6: Writing to two destinations
For a buffered write, the library locks the pages, lets the filesystem prepare, then builds two streams, one for the server and one for the cache, and cuts the range up **separately** for each. The server might want 256 KB network calls while the cache wants chunks matching the local filesystem's block size. All pieces are issued in parallel, each stream tracks its own progress, and a failure in one doesn't immediately abort the other. Pages that should only be copied into the cache, not sent to the server, carry a marker so writeback routes them correctly. While a page is dirty, the library pins the cache resources it will need, and releases them when writeback completes.

A single stream fanning out to both destinations would have been less code, but independent streams let each destination use its best I/O size.

### Step 7: Retrying failures
If a network subrequest fails (a network error or an overloaded server), the library can cut the failed range up again and retry, possibly with different sizes or a different server if the filesystem supports it. This helps SMB setups with multiple connections.

### Step 8: Direct I/O
Direct I/O skips the page-based path and goes straight to the raw I/O helpers.

## The picture

```text
 readahead pages 0–127
        │
   request ──▶ fscache: what's cached?  0–63 yes · 64–127 no
        │
   ├── cache subrequest 0–63  ──▶ CacheFiles (direct I/O) ──▶ unlock 0–63 ✓
   └── network subrequest 64–127 ─▶ filesystem's "issue read" ─▶ unlock 64–127 ✓
                                            └──▶ background write into cache

 buffered write 1 MB:
   server stream: 256K | 256K | 256K | 256K   (network calls)
   cache stream:  pieces aligned to local block size
```

## Tradeoffs

- **What it gives you:** one correct implementation of the tricky page-cache and cache-routing logic, parallel cache and network I/O, pages released as soon as they're ready, and retries.
- **What it costs / requires:** filesystems must adopt the library's structure and embed its per-inode record; independent streams mean more code than a simple fan-out.
- **Where it bites:** every inode carries the library's fields even with caching off, and filesystems not yet converted (NFS still uses its own engine) don't benefit.

## How it got here

- **5.12 (2021):** introduced with basic readpage and readahead helpers.
- **5.17 (2022):** integrated with the rewritten fscache, gained an iterator for zero-copy cache I/O, and added write helpers.
- **6.x (ongoing):** internal types renamed and generalised, the stream model introduced (one request, several streams), a queue-based collection path to cut per-piece overhead, and erofs integration under way.

## Related

- Technical version: [[netfs-helper-library]]
- [[fscache-explained|fscache subsystem]], [[fscache-cookie-subsystem-explained|Cookie subsystem]], [[cachefiles-backend-explained|CacheFiles backend]]
- [[network-filesystems-overview-explained|Network filesystems overview]]
- [[vfs-explained|VFS]], [[page-cache-explained|Page cache]], [[folio-explained|Folios]], [[mm-explained|Memory management]]
