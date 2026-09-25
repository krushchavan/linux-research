---
title: "netfs Inode Context — Explained"
category: explained
original: "[[netfs-inode-context]]"
subsystem: netfs
tags: [explained, netfs, inode, locking, fscache]
converted: 2026-09-25
---

# The netfs inode context, explained

> Plain-language companion to [[netfs-inode-context|the technical note]]. Same facts, fewer identifiers.

## The problem

For [[netfs-explained|netfs]] to handle a network file's I/O, it needs some state for every file: which filesystem callbacks to use, the file's local-cache handle, the size the *server* believes the file has, and flags that change how I/O is done. It needs this state on every read and write, so fetching it must be cheap.

There's a concurrency problem too. A network file can be changed by other clients the kernel knows nothing about, and reads, buffered writes, direct I/O and truncates each need different amounts of isolation. One big lock would be safe but slow; no lock would be fast but unsafe.

## The idea in one paragraph

Make a **netfs-aware inode supertype**. The regular VFS inode sits at the very start, so all existing kernel code works unchanged, and netfs's extra fields sit right after it. Each filesystem puts this combined record at the start of its own inode structure. From any inode pointer, netfs can step to its own fields with simple pointer arithmetic, knowing nothing about the rest of the filesystem's private data. On top of that, netfs sorts I/O into **locking classes** that exclude each other only where they must.

## Step by step

### Step 1: Embed it first
A network filesystem's inode structure (for example AFS's) begins with the netfs record, which itself begins with the VFS inode. So the address of the VFS inode inside it is a valid inode pointer, and netfs's accessor can walk back from any inode to the surrounding netfs record.

### Step 2: Initialise at allocation
When the filesystem allocates an inode, it calls a netfs initialiser that zeroes the netfs fields and records the filesystem's **operations table**, the one thing it must supply.

### Step 3: The cache handle
The record holds the file's local-cache handle ([[fscache-cookie-subsystem-explained|cookie]]), or nothing if caching is off. At open, the filesystem marks the cookie in use so it isn't discarded under memory pressure. At close, it hands over updated validity data and the size, and lets the cookie go. netfs passes this handle to the cache on cache reads, and tags dirty pages with it.

### Step 4: The server's size
This is the key step for correctness. The record keeps the **server's file size** separately from the local one. They can legitimately differ: the kernel may have cached data past the server's current end (the file was truncated on the server without telling this client), or the server may know about data this client hasn't fetched (another client extended the file). netfs uses the server size to decide whether a gap in a read is a real hole or data not yet downloaded. Filesystems can supply a hook to update both sizes together. Keeping it separate also lets netfs cope when the server shrinks a file mid-read, without corrupting the local size.

### Step 5: Policy flags
- **unbuffered:** all I/O bypasses the page cache, for filesystems that guarantee coherency on the server side; netfs picks the direct path automatically
- **write-through:** a buffered write returns only after data reaches server and cache; slower, but durable without waiting for background writeback
- **single object, no upload:** the file is a read-only blob (such as a cached executable); reads use one call with no splitting, and writeback updates only the local cache, never the server

### Step 6: Four locking classes
1. **Buffered reads:** fully concurrent, with no locking beyond each page's own lock.
2. **Buffered writes:** exclude each other with a per-inode write lock, but run alongside reads.
3. **Direct I/O:** fully concurrent. It skips the page cache, so there's no page contention, and the server's own locking provides ordering.
4. **Major operations** (truncate, fallocate, attribute changes): exclusive, using the inode's main lock and shutting out all other I/O.

Memory mappings are a special fifth case: concurrent with everything, but acting as a shared buffer that can trigger direct I/O back into the same file. netfs provides enter and leave functions for the first three classes; major operations manage the main lock themselves.

## The picture

```text
 filesystem's inode (e.g. AFS)
 ┌───────────────────────────────────────────────────────────────┐
 │ netfs record                                                   │
 │ ┌──────────────┬─────────┬──────────────┬─────────────┬───────┐ │
 │ │ VFS inode    │ ops     │ cache cookie │ server size │ flags │ │ + filesystem-
 │ └──────────────┴─────────┴──────────────┴─────────────┴───────┘ │   private fields
 └───────────────────────────────────────────────────────────────┘
   any inode pointer ──(step back)──▶ netfs record

 locking:  reads ∥ reads     writes ⟂ writes (∥ reads)     direct ∥ direct
           truncate/fallocate ⟂ everything
```

## Tradeoffs

- **What it gives you:** hot per-file state right next to the inode (no extra pointer to follow on every I/O), a correct view of server-side size, and as much concurrency as each kind of I/O allows.
- **What it costs / requires:** every filesystem adopting netfs must change its inode allocation, a one-time migration; four classes are more to reason about than one lock.
- **Where it bites:** the local and server sizes can disagree, and code that assumes the local size is the truth for a network file will get it wrong.

## How it got here

- **5.13:** the record introduced with the inode, operations table, cache handle and flags.
- **5.19:** the server-size field added.
- **6.7:** pinning the cache during writeback became netfs's job rather than fscache's.
- **6.9:** the single-object flag and API for read-only cached objects.

## Related

- Technical version: [[netfs-inode-context]]
- [[netfs-explained|netfs subsystem]], [[netfs-io-request-model|Request model]], [[netfs-read-path|Read path]], [[netfs-write-path|Write path]], [[netfs-operations-table|Operations table]]
- [[fscache-explained|fscache]], [[fscache-cookie-subsystem-explained|Cookies]], [[netfs-helper-library-explained|netfs helper library]]
- [[vfs-locking-model-explained|VFS locking model]], [[page-cache-explained|Page cache]]
