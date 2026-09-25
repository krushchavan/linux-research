---
title: "dm-io: Device Mapper Low-Level I/O Helper"
category: concept
tags: [device-mapper, block, io, async, metadata]
subsystem: device-mapper
kernel_version: "2.6.0"
researched: 2026-04-18
status: complete
explained: "[[dm-io-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-io.html
  - https://lwn.net/Articles/87711/
---

# dm-io: Device Mapper Low-Level I/O Helper

> 📘 Plain-language version: [[dm-io-explained]]

## Overview

`dm-io` (`drivers/md/dm-io.c`) provides synchronous and asynchronous I/O services for device-mapper targets that need to perform their own block I/O — typically for reading or writing metadata. Without dm-io, each target (mirror, snapshot, raid) would implement its own I/O plumbing, duplicating error handling, memory management, and completion callbacks.

## How It Works

The entry point for a target is `dm_io_client_create(num_pages)`. This allocates a `dm_io_client` — a thin wrapper around a mempool pre-populated with `num_pages` pages. The pre-allocation is critical: when a target needs to read its metadata, it must make progress even under global memory pressure. By reserving pages at creation time, dm-io guarantees forward progress independent of the page allocator.

All I/O is described by two structures. An `io_region` names a device, a starting sector, and a sector count:

```c
struct io_region {
    struct block_device *bdev;
    sector_t sector;
    sector_t count;
};
```

A `dm_io_request` bundles the operation direction, a buffer descriptor (the memory side of the I/O), and an optional completion callback:

```c
struct dm_io_request {
    int         bi_op;           /* REQ_OP_READ or REQ_OP_WRITE */
    int         bi_op_flags;     /* e.g. REQ_SYNC, REQ_FUA */
    struct dm_io_notify notify;  /* .fn = NULL for synchronous */
    struct dm_io_client *client;
    union {
        struct dm_io_page_list pl;  /* scatter-gather page list */
        struct dm_io_bvec      bv;  /* pre-assembled bvec array */
        struct dm_io_vma       vm;  /* vmalloc'd buffer */
    } mem;
    int mem_type;                /* DM_IO_PAGE_LIST / DM_IO_BIO_VEC / DM_IO_VMA */
};
```

### Three Memory Buffer Modes

**Page-list** (`DM_IO_PAGE_LIST`) — a linked list of `struct page *` with a byte offset into the first page. This is the most flexible mode and used when the target allocates pages directly from the client's pool.

**Bio-vector** (`DM_IO_BIO_VEC`) — an existing `bvec_array` from a bio. Useful when a target has already received a bio from above and wants to redirect different sectors of it to different physical devices (e.g. mirroring writes to two devices).

**Virtual memory** (`DM_IO_VMA`) — a pointer to `vmalloc`'d memory. For large metadata reads (e.g. loading a snapshot exception table into memory), this avoids allocating and chaining many individual pages.

### Synchronous vs Asynchronous

For synchronous I/O, set `notify.fn = NULL` and call `dm_io()`. It blocks until all regions complete and returns an error bitmask.

For asynchronous I/O, set `notify.fn` to a callback of type `io_notify_fn(unsigned long error, void *context)`. The call returns immediately; the callback fires when all I/O completes.

The error parameter is a **bitmask**, not a scalar. Bit *i* represents failure of the *i*-th `io_region`. This is essential when writing to multiple regions (e.g. mirroring): a single write call can report which specific destinations failed independently.

### Write to Multiple Regions

dm-io supports writing the same data to up to `DM_IO_MAX_REGIONS` destinations in a single call. The mirror target uses this: rather than submitting separate bios for each mirror leg, it calls dm-io once with an array of regions. The error bitmask in the completion callback identifies which legs succeeded, so the mirror can degrade gracefully.

## Key Functions

- `dm_io_client_create(num_pages)` — allocate a client with a private page pool; returns `struct dm_io_client *`
- `dm_io_client_destroy(client)` — release the page pool and the client
- `dm_io(request, num_regions, regions, error_bits)` — submit I/O; blocks if `notify.fn` is NULL, else returns immediately

## Interactions

- **[[kcopyd]]**: kcopyd uses dm-io internally for the read and write phases of each copy job
- **[[target-framework]]**: targets obtain a `dm_io_client` in their constructor and use it for metadata I/O throughout their lifetime
- **[[block]]**: dm-io constructs bios and submits them via `submit_bio()` to the target's backing devices
