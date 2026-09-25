---
title: "Page Cache — Explained"
category: explained
original: "[[page-cache]]"
subsystem: mm
tags: [explained, mm, page-cache, readahead, writeback]
converted: 2026-09-25
---

# The page cache, explained

> Plain-language companion to [[page-cache|the technical note]]. Same facts, fewer identifiers.

## The problem

Storage is slow compared with RAM: roughly 100 ns for RAM, about 100 µs for an NVMe SSD, and about 10 ms for a spinning disk. If every `read()` went to the device and every `write()` waited for it, programs would crawl, and many programs reading the same files (shared libraries, config files) would each pay the full price.

At the same time, cached copies must stay correct: writes must eventually reach the disk, the cache must shrink when memory is needed, and a crash mustn't leave the system confused about what's on disk.

## The idea in one paragraph

Keep recently used file data in RAM, in **one shared cache** for the whole system, looked up by (file, page offset). Reads are served from RAM when possible; misses read ahead in anticipation of the next request. Writes land in RAM and are marked **dirty**, and `write()` returns at once; background threads later "photograph the whiteboard" by writing dirty pages to disk and marking them clean. The same cached pages back memory-mapped files, so `read()` and `mmap` see the same data.

## Step by step

### Step 1: One index per file
Each file (inode) has an **address space** object whose core is an index from page offset to cached data. Since 4.20 that index is an **XArray**, which allows lock-free lookups for readers. The address space also has a table of the filesystem's own functions for reading and writing pages. The cache itself doesn't care whether it's ext4, btrfs, XFS or tmpfs; each plugs in its own functions.

### Step 2: Reading, cache hit
For each page of the requested range, look it up in the index. If it's there and up to date, take a reference and copy it to the user's buffer. No I/O, and no locking beyond a brief lock-free read.

### Step 3: Reading, cache miss, with readahead
On a miss, the kernel doesn't read just one page. It allocates a **window** of pages starting at the current position, asks the filesystem to read them all in one go, and waits only for the page actually requested. The rest arrive speculatively and stay cached.

### Step 4: Detecting sequential reading
This is the key step for throughput. The readahead engine keeps per-open-file state: the current window and a "trigger zone" near its end. The first page of that zone is marked. When the program reaches the marked page, it has clearly been reading straight through, so the kernel starts fetching the *next* window **asynchronously**, before the program gets there. Each successful guess doubles the window, up to a per-device maximum (128 KB by default, tunable). Random access, or an explicit hint saying "random", turns readahead off.

### Step 5: Writing into the cache
A write asks the filesystem to prepare the target page (find or create it, lock it), copies the data in, then asks the filesystem to finish, which marks the page **dirty** and unlocks it. `write()` returns right away. That's why copying a file that fits in RAM "finishes instantly", and also why power loss before writeback can lose data.

### Step 6: When dirty pages get written
- **Background threshold:** when dirty pages exceed 10% of RAM (default), flusher threads wake.
- **Hard limit:** above 20% (default), writers are throttled, put to sleep until writeback catches up.
- **Age:** pages dirty for more than 30 seconds (default) are written on the next flush cycle; flushers wake every 5 seconds.
- **Explicit:** `sync`, `fsync` and `msync` write immediately.

Writeback asks the filesystem to write dirty pages (in batches when possible), marks them "under writeback", and clears the dirty and writeback marks when the I/O completes.

### Step 7: Folios instead of pages (5.16)
The cache used to store one entry per 4 KB page, so a 2 MB huge page appeared as 512 identical entries, which was redundant and bug-prone. Now the cache stores **folios**: one entry can span a whole contiguous multi-page block. A 2 MB folio is a single entry covering 512 slots. Folios are a separate type, so the compiler catches code that confuses a whole block with one page inside it.

### Step 8: Truncation
When a file is truncated, cached pages beyond the new end must go. The kernel walks that range, locks each folio, and if nobody else holds it, removes it from the index, unmaps it from any process mapping it, and frees it. Pages still being written back are marked and freed when the write completes.

### Step 9: Bypassing the cache
Databases that keep their own cache (PostgreSQL, RocksDB) can open files with **O_DIRECT**. I/O then goes straight to the device: no cached copy, no double buffering. The cost: no readahead, no merging of small writes, and buffers must be aligned.

## The picture

```text
 read(file, offset) ──▶ index lookup (lock-free)
                          │ hit                 │ miss
                          ▼                     ▼
                   copy from RAM        read a window of pages
                                        [req][ ][ ][⚑][ ][ ]   ⚑ = trigger page
                                        reaching ⚑ → fetch next window early (x2)

 write(file) ──▶ page into cache, mark dirty ──▶ return immediately
                                  │
        dirty > 10% RAM, or 30 s old, or fsync ──▶ flusher writes to disk ──▶ clean
        dirty > 20% RAM ──▶ writers are throttled

 mmap(file) ──▶ same cached pages mapped into the process
```

## Tradeoffs

- **What it gives you:** reads served from RAM, one process's read warming the cache for others, instant writes, write merging, and a single set of pages shared by `read()` and `mmap`.
- **What it costs / requires:** durability requires `fsync`; data written but not yet flushed is lost on power failure.
- **Where it bites:** one big sequential scan (for example `grep` over a huge log) can push out data other processes were using. The multi-generation LRU (6.1) reduces this by separating recently used pages from older ones better.

## How it got here

- **Linux 1.0:** a page cache plus a separate buffer cache.
- **2.4 (2001):** unified into one page cache, ending double caching of file data.
- **2.6:** a radix tree index for fast lookups in large files.
- **4.20 (2018):** the XArray replaces the radix tree (Matthew Wilcox), making clear that lookups need only lock-free reads.
- **5.16 (2022):** folios, after a multi-year campaign; **6.1:** multi-generation LRU; **6.8:** large-folio read and write paths.

## Related

- Technical version: [[page-cache]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[address-space-explained|Address space]]: the per-file object behind the cache
- [[folio-explained|Folios]]: the cache's unit
- [[page-reclaim-explained|page-reclaim]]: evicts clean pages, writes dirty ones first
- [[page-fault-handler-explained|page-fault-handler]], [[virtual-memory-areas-explained|virtual-memory-areas]]: how mapped files use the cache
- [[writeback-infrastructure]], [[memory-cgroup-explained|Memory cgroups]], [[xarray-explained|xarray]]
