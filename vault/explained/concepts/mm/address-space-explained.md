---
title: "Address Space (struct address_space) — Explained"
category: explained
original: "[[address-space]]"
subsystem: mm
tags: [explained, mm, page-cache, vfs, writeback]
converted: 2026-09-25
---

# The address space object, explained

> Plain-language companion to [[address-space|the technical note]]. Same facts, fewer identifiers.

## The problem

Every cached file needs the same set of jobs done: find the cached copy of "page 42 of this file", read it from disk if it's missing, mark it dirty when it's written, write it back later, throw pages away on truncate, and find everyone who has it mapped. Block devices, pipes and swap need much the same.

The memory manager, the filesystem layer and the writeback machinery all need to do these things, while every filesystem stores its data differently. Without a common interface, each would need special code for every filesystem.

## The idea in one paragraph

Give every cached object (usually a file's inode) one **address space** object: effectively **a software MMU for a single file**. Where the hardware MMU translates virtual page numbers to physical memory, an address space translates "page N of this file" to the cached copy in RAM. It also carries a table of functions, the file system's own "instruction set" for reading, writing and invalidating, so the memory manager can call any filesystem through one stable interface.

## Step by step

### Step 1: The cache index
At the heart is an index from file page number to what's cached there, an **XArray** (since 4.20, replacing an older radix tree). Each slot holds one of:
- a **folio**: the in-memory copy of that part of the file
- a **shadow entry**: a small marker left behind after eviction, recording *when* the page was evicted, so a quick re-read can be recognised as a "refault" (useful to reclaim)
- a **direct-access entry**: for persistent memory, where the page cache is bypassed entirely

Lookups are lock-free in the common case; insertions and deletions take a lock.

### Step 2: How a page knows its owner
Every page records who owns it in one pointer. For file pages it points at the address space. For anonymous memory the same pointer is reused to point at anonymous-memory bookkeeping, with its lowest bit set as a marker. Swap-cache pages point at a single shared "swap" address space; KSM (merged duplicate) pages use another special value. So the pointer is never empty for a live page and doubles as a type tag at no extra memory cost.

### Step 3: Reading
A `read()` or a fault on a mapped file looks up the page index. **Hit:** take a reference, copy the data out, drop the reference. **Miss:** allocate a folio, insert it (locked), and call the filesystem's "read this folio" function. The filesystem issues the disk read, marks the folio up to date and unlocks it. Readahead may already have fetched neighbouring pages in one batch.

### Step 4: Writing
A generic write goes chunk by chunk:
1. **Prepare:** the filesystem makes sure the right folio is cached and locked. For block filesystems it may first read the existing block, so a partial write keeps the bytes it doesn't change.
2. **Copy** the user's data into the folio.
3. **Finish:** the filesystem updates the file size if needed, marks the folio dirty and unlocks it.

Marking dirty also sets a **"dirty" tag** in the index. That's the key to efficient writeback: dirty folios can be found without scanning every page.

### Step 5: Writeback, and errors that reach everyone
Writeback threads periodically walk dirty files and ask each filesystem to write its dirty pages, within limits (how many, from where, by when). They follow the dirty tags, and start each pass where the last one stopped, so coverage rotates.

If a write fails, the error is recorded as a sticky **error sequence number**. Each open file keeps its own cursor into that sequence, so `fsync` on *every* file descriptor that was open during the error reports it exactly once. The old scheme cleared a flag at the first `fsync`, so a second descriptor could miss the error entirely. Databases complained, and this was the fix (4.17).

### Step 6: Invalidation without races
Truncating or punching a hole must remove pages from the cache *and* update the filesystem's block map together. An **invalidate lock** makes that safe: truncate and hole-punch take it exclusively; reads and page faults take it shared. That stops a fault from mapping a page whose disk block is about to be freed. Pages with private filesystem data get a chance to drop it, and dirty ones are written first if needed.

This lock was split out from the file's main lock (Jan Kara), so ordinary reads no longer contend with each other just to be safe against truncation. The review found several filesystems had subtle read-versus-hole-punch races.

### Step 7: Who has this file mapped?
The address space keeps an **interval tree** of every memory mapping (VMA) of the file, sorted by file offset. Given a cached page, the kernel can find every process mapping it quickly: needed for reclaim (unmap before freeing), migration and writeback. With files mapped by hundreds of processes (shared libraries, databases), a tree search beats scanning every mapping.

## The picture

```text
                  ┌──────────── address space (one per file) ────────────┐
 read / fault ──▶ │ index: page 0 → folio                                │
                  │        page 1 → shadow (evicted at time T)           │
                  │        page 2 → folio [dirty tag]                    │
                  │ filesystem function table: read, prepare/finish      │
                  │   write, write back dirty, invalidate, migrate...    │
                  │ error sequence (each open file has its own cursor)   │
                  │ invalidate lock (truncate exclusive, reads shared)   │
                  │ interval tree of all mappings of this file           │
                  └──────────────────────────────────────────────────────┘
       writeback ──▶ follow dirty tags ──▶ filesystem writes ──▶ block layer
       reclaim   ──▶ find mappings via tree ──▶ unmap ──▶ drop from index
```

## Tradeoffs

- **What it gives you:** one interface through which reclaim, compaction, writeback and the filesystem layer handle every kind of cached object; lock-free lookups; errors that reach every writer.
- **What it costs / requires:** the function table has grown to about 20 operations, many of which most filesystems never implement.
- **Where it bites:** filesystems must follow the locking rules for each operation exactly; getting the invalidate lock wrong reopens the truncate-versus-fault race.

## How it got here

- **2.4:** introduced with the page cache, indexed by a radix tree with basic read and write operations.
- **2.6.10 (2004):** explicit writeback control (how much, by when).
- **4.17 (2018):** error sequence numbers for write errors (Jeff Layton), after long debate about POSIX and whether databases were really affected.
- **4.20 (2018–2019):** the XArray replaces the radix tree (Matthew Wilcox), with reviewers asking for evidence of reduced lock contention.
- **5.2:** the invalidate lock split out. **5.16:** folios begin replacing individual pages throughout the interface. **6.0+:** large multi-page folios supported through readahead and migration.

## Related

- Technical version: [[address-space]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[page-cache-explained|page-cache]]: what this object implements
- [[folio-explained|folio]]: the unit it caches
- [[page-reclaim-explained|page-reclaim]], [[rmap-reverse-mapping-explained|rmap-reverse-mapping]], [[writeback-infrastructure]]
- [[memory-compaction-explained|memory-compaction]], [[transparent-huge-pages-explained|transparent-huge-pages]], [[xarray]]
- [[vfs|VFS]], [[block-explained|Block layer]]
