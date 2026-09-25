---
title: "dm-bufio — Explained"
category: explained
original: "[[dm-bufio]]"
subsystem: device-mapper
tags: [explained, device-mapper, buffer-cache, metadata]
converted: 2026-09-25
---

# dm-bufio, explained

> Plain-language companion to [[dm-bufio|the technical note]]. Same facts, fewer identifiers.

## The problem

Device-mapper targets often keep metadata on disk: checksums, journals, hash trees. Reading that metadata from disk on every I/O would be far too slow, so it needs to be cached in memory.

The kernel's normal cache for disk data, the page cache, is organised around files: every cached page belongs to some file's (inode's) mapping. Device-mapper metadata isn't a file. dm-integrity's checksum journal, for example, sits interleaved with data on the raw block device, with no filesystem and no inode to hang it on.

## The idea in one paragraph

Give device-mapper targets their own small, private block cache. dm-bufio caches fixed-size blocks of a device, keyed by block number, with its own least-recently-used eviction and background write-back, completely independent of the file-oriented page cache. The target controls the lifecycle of every buffer, and the cache doesn't compete with filesystem data for memory.

## Step by step

### Step 1: Create a client
A target creates a cache client for one block device, choosing a block size (a power of two, from 512 bytes up to one page) and a number of **reserved buffers**. The reserved buffers are set aside in advance, so the client can always make progress even when the system is short of memory. That matters because freeing memory may itself require writing to this device.

### Step 2: Read a block
Asking for a block returns a buffer. If it's cached, it comes back immediately. If not, dm-bufio reads it from disk and waits for the read to finish. Either way the buffer is **pinned**: it can't be evicted until the caller releases it.

### Step 3: Skip the read for blocks you'll overwrite
If the caller is about to overwrite a whole block anyway (say, a freshly allocated one), it can ask for a new buffer without reading the old contents from disk, saving an I/O.

### Step 4: Modify and mark dirty
The caller changes the buffer's data in memory and marks it dirty. A background writer flushes dirty buffers to disk periodically, much like the page cache's own write-back. When the target needs a guarantee, for example before a checkpoint, it can force a synchronous flush of everything dirty.

### Step 5: Release and evict
When a caller releases a buffer, its pin count drops. Recently used buffers live on a "hot" list and older ones drift to a "cold" list. When the cache is full, the oldest cold buffer is evicted. Dirty buffers can't be evicted until their write-back finishes.

### Step 6: Teardown
Destroying the client flushes any dirty buffers and frees everything.

## The picture

```text
  target (e.g. dm-integrity)
      │ read block N          │ modify, mark dirty       │ release
      ▼                       ▼                          ▼
  ┌──────────────────── dm-bufio client (one device) ────────────────┐
  │  hit? return pinned buffer        miss? read from disk, then pin │
  │  hot list ──▶ cold list ──▶ evict oldest clean when full         │
  │  dirty buffers ──▶ background write-back (or forced flush)       │
  │  reserved buffers: guaranteed progress under memory pressure     │
  └──────────────────────────────────────────────────────────────────┘
                              │ reads and writes
                              ▼
                        block device
```

## Tradeoffs

- **What it gives you:** block-level metadata caching with no file or inode needed, full control by the target, and isolation from filesystem memory pressure.
- **What it costs / requires:** a second buffer cache in the system alongside the page cache, with its own memory to manage. Block sizes are limited to one page.
- **Where it bites:** it isn't the only device-mapper metadata cache. The persistent-data library, used by thin provisioning, has its own separate block manager, so there are two parallel solutions for different workloads.

## How it got here

The source note doesn't give a version history for dm-bufio itself. Its main users are dm-integrity (merged in 4.6, 2016) and dm-verity, which pull it in automatically when built.

## Related

- Technical version: [[dm-bufio]]
- [[device-mapper-explained|Device mapper]]: the framework this serves
- [[dm-integrity-explained|dm-integrity]]: the main user
- [[persistent-data-library-explained|persistent-data-library]]: the parallel metadata cache for thin provisioning
- [[block-explained|Block layer]]: where cache misses and write-backs go
