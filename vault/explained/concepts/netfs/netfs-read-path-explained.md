---
title: "netfs Read Path — Explained"
category: explained
original: "[[netfs-read-path]]"
subsystem: netfs
tags: [explained, netfs, readahead, fscache, direct-io]
converted: 2026-09-25
---

# The netfs read path, explained

> Plain-language companion to [[netfs-read-path|the technical note]]. Same facts, fewer identifiers.

## The problem

Reading a network file is harder than reading a local one. The bytes you want may be in a local cache, on the remote server, or nowhere at all (a hole in a sparse file), and each source has its own size limits and latency. A single read has to be split into parallel pieces, reassembled in order, and protected against one source failing: if the cached copy turns out to be bad, the read should quietly fetch from the server instead.

Every network filesystem (AFS, SMB, Ceph, 9P) used to write this logic separately, each with its own bugs.

## The idea in one paragraph

The read path is a **parallel jigsaw assembler**. The page cache says "I need bytes 0 to 8 MB". netfs checks which pieces are already cached and which must come from the server, hands each to the right worker (the cache or the filesystem's network code), and slots finished pieces into place in order. Each completed section is released straight away, so the caller can start using the picture before every piece has arrived.

## Step by step

### Step 1: Two ways in
The page cache calls the read path either for **readahead**, a guess that the program will soon want a range, or for a **single-page read**, triggered by a page fault or a `read` that found an empty page. Both create a request of the matching kind and run the same loop.

### Step 2: Widen the window
First, the filesystem may enlarge the window, only ever by adding bytes at the end. Ceph may round up to a 2 MB object boundary so the next cache access is a hit; 9P may round up to its negotiated message size so every network call is full.

### Step 3: Ask the cache, page by page
For each page in the range, netfs asks the local cache (if active) what to do:
- **fill with zeros:** a hole in a sparse file; no network or cache read needed
- **read from cache:** a hit
- **download from server:** a miss
- **invalid:** the cache has a copy but it's not trustworthy; treat as a miss

Runs of neighbouring pages with the same answer merge into one piece. The filesystem's size check caps each piece at its maximum call size, and the rest starts a new piece. Merging keeps call counts sane: one piece per 4 KB page would mean hundreds of calls for a 1 MB read.

### Step 4: Dispatch everything at once
- **Server pieces** go to the filesystem's "issue read" callback, which starts an asynchronous call (an AFS fetch, an SMB read) and returns immediately.
- **Cache pieces** go straight to the cache, which issues an asynchronous direct read against its local files.
- **Zero pieces** are filled on the spot and marked done.

Once issued, all pieces are in flight together, with no artificial ordering.

### Step 5: Release pages in order
This is the key step. A single collector waits for completions and releases pages **in file order**, not completion order: a page unlocks only once every byte before it is confirmed. For big pieces, the filesystem can report partial progress ("the first 512 KB of this 4 MB piece has arrived"), and the collector unlocks those pages immediately. That matters most on high-latency links, such as AFS over a wide-area network, where waiting for the whole 4 MB would show up as a stall.

If a piece reaches the end of the file early, it says so; netfs zero-fills the rest and marks later pages as zeros instead of making more calls.

### Step 6: Fall back and retry
If a cache piece fails (a corrupt cache file, or the cache handle was invalidated), netfs doesn't report an error. It re-labels the piece as a server download, re-prepares it and issues it; the filesystem sees an ordinary miss. If a server piece fails with a retryable error (try again, connection reset), netfs waits for the other pieces, calls the filesystem's retry hook so it can refresh a Kerberos ticket or reconnect, then reissues the failed pieces.

### Step 7: Direct reads
For direct I/O, or files set to bypass the cache, netfs pins the program's own buffer, builds the request against it instead of the page cache, generates and issues pieces the same way, then unpins and returns the byte count. No page locking is involved; ordering comes from the server.

### Step 8: Warming the cache
Pages fetched from the server while a cache is active are marked for copying into the cache. They're written there on the next writeback pass (or at once in write-through mode). That's how a cold file warms the cache after its first read.

## The picture

```text
 readahead 0–8 MB  →  widen to boundary
   page-by-page cache check:
   [cache hit ─────][server miss ──────────][hole][server miss ──]
        │                  │                  │          │
     cache read       issue read           zeros     issue read     (all in flight)
        └───────────── collector: release pages in file order ──────────┘
   cache piece fails → becomes a server piece
   server pieces done → mark pages "copy to cache" → next writeback warms the cache
```

## Tradeoffs

- **What it gives you:** one correct read implementation for every network filesystem, parallel cache and network reads, early release of pages, and invisible fallback from a bad cache.
- **What it costs / requires:** merged pieces make the retry unit bigger when one fails; ordered release means one slow early piece can hold back pages after it.
- **Where it bites:** because cache errors are hidden, a problem surfaces only after the server fallback also fails, which can make cache trouble hard to spot.

## How it got here

- **5.13:** the first read path, with readahead and single-page reads from cache or server.
- **6.0:** Ceph and 9P move onto it, dropping their own code.
- **6.3:** direct reads, and one read entry point that picks buffered or direct automatically.
- **6.5:** AFS fully migrated, deleting about 3,000 lines of AFS read code.
- **6.13:** the single collector, significantly cutting sequential-read latency.

## Related

- Technical version: [[netfs-read-path]]
- [[netfs-explained|netfs subsystem]], [[netfs-io-request-model-explained|Request model]], [[netfs-operations-table-explained|Operations table]], [[netfs-inode-context-explained|Inode context]], [[netfs-write-path|Write path]]
- [[fscache-explained|fscache]], [[cachefiles-backend-explained|CacheFiles]], [[page-cache-explained|Page cache]], [[get-user-pages-and-pinning-explained|Pinning user pages]]
