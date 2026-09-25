---
title: "kcopyd: Device Mapper Asynchronous Copy Engine"
category: concept
tags: [device-mapper, block, kcopyd, copy, async, mirror, snapshot]
subsystem: device-mapper
kernel_version: "2.6.0"
researched: 2026-04-18
status: complete
explained: "[[kcopyd-explained]]"
sources:
  - https://lwn.net/Articles/87712/
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/index.html
---

# kcopyd: Device Mapper Asynchronous Copy Engine

> 📘 Plain-language version: [[kcopyd-explained]]

## Overview

`kcopyd` (`drivers/md/dm-kcopyd.c`) is a background block-copy service for device-mapper targets. When the mirror target resyncs legs after a failure, when snapshot creation pre-fills COW exceptions, or when thin provisioning zeroes newly allocated blocks, the work happens through kcopyd. It isolates these bulk copy operations from the user I/O path, running them asynchronously on a kernel workqueue.

## How It Works

A target calls `dm_kcopyd_client_create()` to create a `kcopyd_client`. This pre-allocates a pool of pages dedicated to the client's copy operations, independent of the global page allocator. The pre-allocation ensures that copy jobs can always make progress even when the system is under severe memory pressure — critical for mirror resync, which must complete to restore redundancy.

### Submitting a Copy Job

The main API call is `dm_kcopyd_copy(client, src, num_dests, dests, flags, fn, context)`:
- `src` — `dm_io_region` describing the source (one block device, one sector range)
- `dests` / `num_dests` — up to `KCOPYD_MAX_REGIONS` (currently 8) destinations
- `fn` — callback invoked when all destinations complete
- `flags` — `KCOPYD_IGNORE_ERROR` (continue despite individual write failures)

### Three-Phase Execution

Every copy job moves through three phases, managed by three internal job lists on the workqueue:

1. **Pages phase** — the job waits in `pages_jobs` until enough pages are available from the client pool. `kcopyd_get_pages()` pulls pages; if the pool is temporarily exhausted, the job stays queued here until other jobs return their pages.

2. **I/O phase** — once pages are allocated, the job moves to `io_jobs`. It issues an async read from the source via `dm_io()`. On read completion, the callback immediately fans out async writes to all destination regions simultaneously — the same page memory is written to all destinations.

3. **Complete phase** — after all writes finish, the job lands in `complete_jobs`. The workqueue thread processes completions in FIFO order, invokes the caller's callback, and releases the pages back to the pool.

### Large Transfer Splitting

Transfers larger than `SUB_JOB_SIZE` (128 sectors by default) are split by `run_pages_job()` into sub-jobs. Each sub-job carries a slice of pages and runs through the three-phase pipeline independently. `segment_complete()` tracks how many sub-jobs remain; it fires the top-level callback only when all segments complete and aggregates per-segment errors into a combined bitmask. The pipeline design means kcopyd keeps the storage bus saturated with multiple in-flight sub-jobs, rather than serialising reads and writes across the full transfer.

### Zero Fill

`dm_kcopyd_zero()` is a variant that writes zeros to a set of destination regions without a source read. Thin provisioning calls this to zero-fill newly allocated data blocks before returning them to the application (matching the POSIX requirement that newly allocated space read as zeros).

## Key Data Structures

**`kcopyd_client`** (`drivers/md/dm-kcopyd.c`):
- `pages` — pre-allocated page pool
- `lock` — spinlock protecting the page list
- `job_pool` — slab pool for `kcopyd_job` structs

**`kcopyd_job`** (internal):
- `source` — `dm_io_region` to read from
- `dests[KCOPYD_MAX_REGIONS]`, `num_dests` — write targets
- `pages` — page list slice allocated for this job
- `read_err` — error from the source read
- `write_err` — bitmask of per-destination write errors
- `fn`, `context` — caller's completion callback

## Key Functions

- `dm_kcopyd_client_create(kc_params)` — allocate client; `kc_params` sets page pool size
- `dm_kcopyd_client_destroy(kc)` — wait for in-flight jobs, release resources
- `dm_kcopyd_copy(kc, src, num_dests, dests, flags, fn, context)` — submit a copy
- `dm_kcopyd_zero(kc, num_dests, dests, flags, fn, context)` — submit a zero fill

## Config & Flags

- `CONFIG_DM_KCOPYD` — selected automatically by mirror, snapshot, thin, and cache targets
- `KCOPYD_IGNORE_ERROR` — do not abort on write failure to one destination; the error is still reported in the bitmask so the caller (mirror) can degrade gracefully

## Interactions

- **[[dm-io]]**: kcopyd uses dm-io for the actual read and write I/O operations
- **[[target-framework]]**: mirror, snapshot-merge, thin, and cache targets all create kcopyd clients in their constructors
