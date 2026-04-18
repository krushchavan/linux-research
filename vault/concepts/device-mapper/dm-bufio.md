---
title: "dm-bufio: Device Mapper Buffer Cache"
category: concept
tags: [device-mapper, block, cache, metadata, integrity]
subsystem: device-mapper
kernel_version: "4.6"
researched: 2026-04-18
status: complete
sources:
  - https://people.redhat.com/mpatocka/patches/kernel/new-snapshots/r22/dm-bufio.patch
  - https://docs.kernel.org/admin-guide/device-mapper/dm-integrity.html
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/index.html
---

# dm-bufio: Device Mapper Buffer Cache

## Overview

`dm-bufio` (`drivers/md/dm-bufio.c`) is a simple, private buffer cache for device-mapper targets that need to read and write metadata on block devices but cannot use the kernel's standard page cache. The page cache is tied to `address_space` objects owned by inodes; device-mapper metadata blocks have no inode. dm-bufio fills this gap by providing block-granularity caching with LRU eviction and writeback, independent of the VFS.

## How It Works

A target creates a `dm_bufio_client` by calling `dm_bufio_client_create(bdev, block_size, reserved_buffers, ...)`. The `block_size` is the unit of I/O (must be a power of two, at least 512 bytes, at most one page); `reserved_buffers` is how many buffers to pre-allocate in a mempool so the client can always make progress even under memory pressure.

### Reading Metadata

`dm_bufio_read(client, block)` returns a `struct dm_buffer *`. On a cache hit, the call returns immediately with the pinned buffer. On a miss, dm-bufio submits a synchronous read via the block layer and blocks until it completes. The returned buffer is reference-counted and pinned until the caller calls `dm_bufio_release(buf)`.

`dm_bufio_new(client, block)` is the counterpart for blocks the caller is about to overwrite: it allocates a buffer without reading from disk (skipping the I/O), suitable for fresh allocations where the old content is irrelevant.

The buffer's data is accessible via `dm_bufio_get_block_data(buf)`, which returns a `void *` into the buffer's memory.

### Marking Dirty and Writing Back

After modifying a buffer's data, the caller calls `dm_bufio_mark_buffer_dirty(buf)` to move it onto the dirty list. dm-bufio's internal writeback thread flushes dirty buffers periodically (similar to the page cache's background writeback). For forced synchronous flushes (e.g. before a snapshot checkpoint), the caller uses `dm_bufio_write_dirty_buffers(client)`.

### Eviction

The cache uses a two-list LRU: recently accessed buffers sit in a hot list; less-recently-used buffers migrate to a cold list and are candidates for eviction. When `dm_bufio_release()` drops a buffer's pin to zero and the cache is full, the cold list's tail is evicted. Dirty buffers cannot be evicted until writeback completes.

### Why Not the Page Cache?

The page cache requires an `address_space` belonging to an inode. dm-integrity's checksum journal is stored interleaved with data on the same block device, with no filesystem and no inode to attach to. dm-bufio's independence from the VFS is the design point: its buffers are not subject to memory pressure from filesystem activity, and their lifecycle is fully controlled by the target.

## Key Data Structures

**`dm_bufio_client`** (`drivers/md/dm-bufio.c`):
- `bdev` — the metadata block device
- `block_size` — buffer granularity in bytes
- `cache_size` — current number of cached buffers
- `reserved_buffers` — number guaranteed available (mempool)
- `clean_buffers`, `dirty_buffers` — LRU lists

**`dm_buffer`** (opaque to callers):
- `data` — pointer to the cached block content
- `block` — block number on device
- `dirty` — writeback pending flag
- Reference count for pinning

## Key Functions

- `dm_bufio_client_create(bdev, block_size, reserved, ...)` — allocate a client
- `dm_bufio_client_destroy(client)` — flush dirty buffers and free
- `dm_bufio_read(client, block)` — read or return cached buffer (pinned)
- `dm_bufio_new(client, block)` — allocate fresh buffer without reading
- `dm_bufio_get_block_data(buf)` → `void *` — access buffer memory
- `dm_bufio_mark_buffer_dirty(buf)` — schedule writeback
- `dm_bufio_release(buf)` — unpin buffer
- `dm_bufio_write_dirty_buffers(client)` — synchronous flush of all dirty buffers

## Config & Flags

- `CONFIG_DM_BUFIO` — selected by dm-integrity, dm-verity, and any other target that uses dm-bufio

## Interactions

- **[[dm-integrity]]**: the primary user; caches its on-disk checksum journal using dm-bufio
- **[[persistent-data-library]]**: uses its own block manager layer (not dm-bufio) — the two are parallel buffer caching solutions for different workloads
- **[[block]]**: dm-bufio submits bios to the underlying block device for cache misses and writeback
