---
title: "The bio Layer (struct bio and bio submission)"
category: concept
tags: [block, bio, bvec, storage, stacking, io-path]
subsystem: block
kernel_version: "2.5.1"
researched: 2026-09-25
status: complete
sources:
  - https://kernel-internals.org/block/
  - https://kernel-internals.org/block/bio-request/
  - https://kernel-internals.org/block/life-of-block-io/
  - https://www.kernel.org/doc/html/latest/block/biovecs.html
  - https://www.kernel.org/doc/html/latest/block/writeback_cache_control.html
  - https://lwn.net/Articles/736534/
  - https://lwn.net/Articles/26404/
  - https://lwn.net/Articles/776535/
  - https://lwn.net/Articles/868070/
  - https://lwn.net/Articles/945987/
  - https://lwn.net/Articles/973565/
  - https://patchwork.kernel.org/project/linux-block/patch/1459914212-9330-1-git-send-email-ming.lei@canonical.com/
---

# The bio Layer (struct bio and bio submission)

## Purpose

Everything above the block layer (filesystems, the page cache's writeback path, swap, direct I/O, [[device-mapper]] and md) needs one uniform way to say "move these bytes of memory to or from these sectors of that device, and tell me when it's done." That unit is `struct bio`. The *bio layer* is the thin upper half of the block layer. It accepts bios, validates and accounts them, splits them to fit device limits, and hands them on to either a bio-based driver or [[blk-mq]], the lower *request layer*. It also prevents stacked virtual devices from recursing without limit. Without it, every filesystem would have to understand every device's size, alignment and segment limits, and every stacked driver would risk stack overflow and memory deadlock.

## Mental Model

A bio is a **shipping manifest**. It lists pickup locations (a scatter-gather list of memory segments, the `bio_vec` array), a single destination address range (a starting sector plus a length), what to do (read, write, discard, flush…), and a return address (`bi_end_io`). The manifest itself is never rewritten once it's handed off. Instead, each handler carries a separate *progress card* (`bvec_iter`) saying how much is left. Because of that, one manifest can be cut into pieces (split) or photocopied (cloned) cheaply: each piece just gets its own progress card that points into the same list.

## How It Works

**Building a bio.** A submitter allocates a bio with `bio_alloc(bdev, nr_vecs, opf, gfp)` (the 5.18+ signature that binds the device and operation at allocation time), or `bio_alloc_bioset()` for a specific pool. Every bio comes from a `struct bio_set`. That is a slab cache plus a *mempool* of reserved bios and bvec arrays, so a bio needed for memory-reclaim writeback can always be allocated, eventually, even when the system is out of memory. Stacking drivers create their own `bio_set` with `bioset_init()` so they don't drain the global `fs_bio_set` that the layer above them depends on. Small bios keep their `bio_vec`s *inline* after the struct; larger ones get a separately allocated vector from size-classed bvec slabs (up to `BIO_MAX_VECS` = 256).

The submitter then sets `bio->bi_iter.bi_sector`, `bi_end_io` and `bi_private`, and adds memory with `bio_add_page()` or, increasingly, `bio_add_folio()`. Each addition appends a `struct bio_vec { bv_page, bv_len, bv_offset }`. Since 5.1 a single bvec may cover *multiple physically contiguous pages* ("multi-page bvecs", Ming Lei). This matters for [[folio]]s and huge pages: a 2 MiB folio can be one bvec instead of 512. `bio_add_page()` merges into the previous bvec when the new page is physically adjacent, and it refuses (returns less than the requested length) when the bio is full, telling the caller to submit and start a new one. For direct I/O, `bio_iov_iter_get_pages()` pins user pages (see [[get-user-pages-and-pinning]]) and fills the bvec table straight from an `iov_iter`.

**The immutable biovec rule.** Once submitted, the `bi_io_vec` array is never modified by anyone below. All mutable position state lives in `struct bvec_iter bi_iter`: `bi_sector` (current start sector), `bi_size` (bytes remaining), `bi_idx` (current bvec index) and `bi_bvec_done` (bytes consumed within that bvec). Kent Overstreet made this change in 3.13. Before then, drivers advanced through a bio by incrementing `bi_idx` and adjusting `bv_offset`/`bv_len` in place, which made sharing a vector between bios impossible and splitting fiddly. Now `bio_advance()` just moves the iterator, and `bio_for_each_segment(bvec, bio, iter)` synthesises single-page `bio_vec`s *by value* from the iterator. `bio_for_each_bvec()` yields the full multi-page segments, which is useful for building scatterlists.

**Submission.** The caller calls `submit_bio(bio)`. It does accounting (per-task read/write byte counts, `PSI` memstall hints for reads of workingset pages) and calls `submit_bio_noacct()`. That performs generic checks: is the bio past the end of the device (`bio_check_eod()`), should a partition-relative sector be remapped to the whole disk (`blk_partition_remap()`), is the operation supported (discard, write-zeroes, zone append, secure erase), and does the device have a volatile write cache. If there's no cache, `REQ_PREFLUSH` and `REQ_FUA` are stripped, and an empty flush completes immediately. Then come cgroup hooks: `blk_cgroup_bio_start()` and the `blk-throttle` check, which may hold the bio back to enforce io.max limits (see [[io-controller]]). Submission is **asynchronous**: `submit_bio()` returns without waiting. A caller that needs to wait uses `submit_bio_wait()`, which is just a completion plus an `bi_end_io` that signals it.

**Recursion avoidance: `current->bio_list`.** Stacked devices (dm on md on NVMe, for example) take a bio, remap or clone it, and submit new bios to the device below. If each level called straight down, a deep stack could overflow the kernel stack. `submit_bio_noacct()` avoids this with a per-task *on-stack* list. The first, outermost call sets `current->bio_list` and loops (`__submit_bio_noacct()`). Any nested submission from inside a driver's `->submit_bio` just *appends* to that list and returns. The outer loop then pops and dispatches bios iteratively, so stack depth stays constant regardless of stack height.

That flattening introduced a subtle deadlock. A driver might split a bio, submit the first half (which is only *queued* on `current->bio_list`) and then block allocating a bio for the second half from a mempool whose entries are all sitting, unsubmitted, on that same list. The first fix (3.18-era, Kent Overstreet) gave every `bio_set` a *rescuer* workqueue. When the allocator would block, `punt_bios_to_rescuer()` moves that bioset's queued bios to the rescuer thread. That produced dozens of mostly idle kernel threads per machine. NeilBrown's 4.11 rework fixed the ordering instead. Each iteration of the outer loop splits `bio_list` into two lists: bios for *lower* devices (produced by the current driver) and bios for the *same* level. Lower ones are processed first. Combined with the rule that a splitting driver submits the remainder with `submit_bio_noacct()` and handles only the front part itself, forward progress is guaranteed depth-first. Rescuers became opt-in (`BIOSET_NEED_RESCUER`) for the few drivers that still need them.

**Two kinds of destination.** `__submit_bio()` looks at the disk. If `disk->fops->submit_bio` is set, the device is **bio-based**: dm, md, brd, zram, drbd, pmem and nvme-multipath receive the raw bio and do whatever they like with it. Otherwise it's **request-based**, and the bio goes to `blk_mq_submit_bio()`, where it is merged into, or becomes, a `struct request` (see [[blk-mq]]). Before any of that, `bio_queue_enter()` takes a reference on the queue's `q_usage_counter`. That's how queue *freeze* blocks new bios during limit or scheduler changes. With `REQ_NOWAIT` the bio fails with `BLK_STS_AGAIN` instead of sleeping.

**Splitting to device limits.** Filesystems build bios as large as they like ("arbitrary-size bios", 4.3, Ming Lei and Kent Overstreet). Fitting them to hardware is the block layer's job. Before a bio becomes a request, `bio_split_to_limits()` (called `blk_queue_split()` before 6.0) checks it against the device's `queue_limits`: `max_sectors`, `max_segments`, `max_segment_size`, `seg_boundary_mask`, `virt_boundary_mask` (NVMe PRP rules), and alignment for discard, write-zeroes or atomic writes. If the bio exceeds any of them, `bio_split()` creates a new bio for the front part, which *shares the same bvec array* with its own `bvec_iter` (possible only because of immutable biovecs). `bio_chain(split, bio)` makes the split a child of the original, and the remainder is resubmitted through `submit_bio_noacct()`. The split bios come from the queue's own `bio_split` bio_set, so splitting can't deadlock on the submitter's pool.

**Chaining and completion.** A chained parent holds an atomic `__bi_remaining` count and the `BIO_CHAIN` flag. Each child's completion calls `bio_endio()` on the parent. The parent's `bi_end_io` runs only when the count reaches zero, so the filesystem sees exactly one completion however many pieces the device needed. The first error seen is propagated into the parent's `bi_status`. Clones (`bio_alloc_clone()`) work the same way and are used heavily by dm: the clone points at the original's bvecs and gets its own iterator and device. When the driver finishes, it sets `bi_status` (a `blk_status_t` such as `BLK_STS_OK`, `BLK_STS_IOERR` or `BLK_STS_AGAIN`) and calls `bio_endio()`. That handles chain accounting, trace events and cgroup accounting, then invokes `bi_end_io`, often in hard or soft IRQ context. For page-cache I/O the callback (for example iomap's read or write completion) marks folios uptodate or ends writeback. `bio_put()` drops the last reference and returns the bio to its `bio_set`.

**Fast path allocation: the per-CPU bio cache.** At millions of IOPS per core, slab allocation of bios showed up in profiles. Since 5.15 a `bio_set` created with `BIOSET_PERCPU_CACHE` keeps a lockless per-CPU free list of bios. Callers that set `REQ_ALLOC_CACHE` (io_uring and polled direct I/O, where completion and freeing happen in task context rather than IRQ) take bios from it without touching the slab. Jens Axboe measured about a 10% throughput improvement, above 3.5M IOPS per core.

**Plugging.** Submitters that issue many bios in a burst wrap them in `blk_start_plug()` / `blk_finish_plug()`. With a plug active, bios headed for blk-mq devices accumulate as requests on the per-task plug list instead of going to the device one at a time. They are flushed together at `blk_finish_plug()` or automatically when the task sleeps, so a task can never deadlock on I/O it is still holding. The mechanics live in blk-mq, but plugging is set up at bio submission time by filesystems, writeback, readahead and io_uring.

**Failure paths.** Bios can fail before they reach a driver: `bio_io_error()` for past-end-of-device, `BLK_STS_NOTSUPP` for unsupported operations, and `BLK_STS_AGAIN` for `REQ_NOWAIT` when the queue is frozen or out of tags. Drivers fail them with a status. Because `bi_status` is a small enum rather than an errno (4.13, Christoph Hellwig), status codes are translated with `blk_status_to_errno()` only at the top, and transport-specific errors like `BLK_STS_TARGET`, `BLK_STS_NEXUS` and `BLK_STS_MEDIUM` can drive multipath retry decisions. `bio_integrity` payloads (T10 PI / [[dm-integrity]] tags) ride in `bi_integrity` and are verified at completion when the device supports protection information.

## Key Data Structures

**`struct bio`** (`include/linux/blk_types.h`) — one I/O to one contiguous sector range.
- `bi_next` — link when queued on a list or inside a `struct request`
- `bi_bdev` — target `block_device` (partition); `bi_bdev->bd_disk` gives the `gendisk`
- `bi_opf` — `REQ_OP_*` in the low bits plus `REQ_*` flags (`REQ_SYNC`, `REQ_META`, `REQ_PREFLUSH`, `REQ_FUA`, `REQ_NOWAIT`, `REQ_POLLED`, `REQ_ALLOC_CACHE`…)
- `bi_flags` — internal state (`BIO_CHAIN`, `BIO_CLONED`, `BIO_BOUNCED`, `BIO_REMAPPED`…)
- `bi_status` — `blk_status_t` completion status
- `bi_iter` — `struct bvec_iter`, all mutable progress
- `__bi_remaining` — outstanding chained children
- `bi_end_io`, `bi_private` — completion callback and its cookie
- `bi_blkg`, `bi_issue`, `bi_ioprio`, `bi_write_hint` — cgroup, latency and priority metadata
- `bi_integrity`, `bi_crypt_context` — PI metadata and inline-encryption context (`CONFIG_BLK_INLINE_ENCRYPTION`)
- `bi_vcnt`, `bi_max_vecs`, `bi_io_vec` — the bvec table (don't trust `bi_vcnt` in drivers)
- `__bi_cnt` — reference count; `bi_pool` — owning `bio_set`
- `bi_inline_vecs[]` — trailing inline bvecs for small bios

**`struct bio_vec`** (`include/linux/bvec.h`) — `bv_page`, `bv_len`, `bv_offset`; may span several contiguous pages.

**`struct bvec_iter`** — `bi_sector`, `bi_size`, `bi_idx`, `bi_bvec_done`.

**`struct bio_set`** (`include/linux/bio.h`) — `bio_slab`, `bio_pool` and `bvec_pool` mempools, `front_pad` (lets drivers such as dm embed per-bio data *before* the bio), per-CPU `cache`, and the `rescue_list`/`rescue_work` rescuer.

## Key Functions / Entry Points

**`bio_alloc()` / `bio_alloc_bioset()` / `bio_alloc_clone()`** (`block/bio.c`) — allocate from a bio_set (mempool-backed).
**`bio_add_page()` / `bio_add_folio()` / `bio_iov_iter_get_pages()`** — attach memory.
**`submit_bio()` → `submit_bio_noacct()` → `__submit_bio_noacct()` → `__submit_bio()`** (`block/blk-core.c`) — accounting, checks, recursion flattening, dispatch to `->submit_bio` or `blk_mq_submit_bio()`.
**`submit_bio_wait()`** — synchronous wrapper.
**`bio_split_to_limits()` / `bio_split()` / `bio_chain()`** (`block/blk-merge.c`, `block/bio.c`) — fit bios to `queue_limits`.
**`bio_endio()`** — complete a bio, walking chained parents.
**`bio_advance()` / `bio_for_each_segment()` / `bio_for_each_bvec()`** — iterator helpers.
**`bio_queue_enter()`** — queue-usage reference; honours freeze and `REQ_NOWAIT`.

## Important Flags & Config Options

- **`REQ_OP_*`** — `READ`, `WRITE`, `FLUSH`, `DISCARD`, `SECURE_ERASE`, `WRITE_ZEROES`, `ZONE_APPEND`, `ZONE_RESET`, and others.
- **`REQ_PREFLUSH` / `REQ_FUA`** — durability ordering. They are stripped automatically on devices without a volatile write cache.
- **`REQ_NOWAIT`** — fail with `BLK_STS_AGAIN` instead of blocking. Used by io_uring and `RWF_NOWAIT`.
- **`REQ_POLLED` / `REQ_ALLOC_CACHE`** — polled I/O and per-CPU bio cache eligibility.
- **`BIOSET_NEED_BVECS`, `BIOSET_NEED_RESCUER`, `BIOSET_PERCPU_CACHE`** — `bioset_init()` flags.
- **Queue limits** (`/sys/block/<dev>/queue/`): `max_sectors_kb`, `max_hw_sectors_kb`, `max_segments`, `max_segment_size`, `logical_block_size`, `discard_max_bytes`, `atomic_write_*`. These decide when bios are split.
- **`CONFIG_BLK_DEV_INTEGRITY`**, **`CONFIG_BLK_INLINE_ENCRYPTION`**, **`CONFIG_BLK_DEV_THROTTLING`**, **`CONFIG_BLK_CGROUP`** — optional per-bio features.
- Tracepoints: `block_bio_queue`, `block_split`, `block_bio_remap`, `block_bio_complete` (see blktrace and bpftrace `biosnoop`).

## Interactions with Other Subsystems

- **↑ Userspace**: indirectly through read/write/O_DIRECT, [[io-uring-internals]] (`REQ_NOWAIT`, polled I/O, bio cache), and `blktrace`.
- **← [[page-cache]] / [[writeback-infrastructure]] / [[iomap]]**: readahead and writeback build folio-sized bios. iomap's `->end_io` callbacks finish folio state.
- **← [[swap]]**: swap-out and swap-in submit bios directly (`swap_writepage()` → `__swap_writepage()`).
- **← [[device-mapper]] / md**: bio-based `->submit_bio` implementations that clone, remap, split and fan out bios. They rely on `current->bio_list`, `front_pad` and private `bio_set`s.
- **→ [[blk-mq]]**: request-based devices receive bios via `blk_mq_submit_bio()`, which merges them into requests.
- **→ [[io-scheduler]]**: bio merges are first attempted against scheduler-held requests.
- **→ [[io-controller]] (blk-cgroup)**: each bio carries a `bi_blkg`, and throttling/iocost/iolatency act at bio submission.
- **→ [[folio]] / [[get-user-pages-and-pinning]]**: bvecs reference folio pages, and direct I/O pins user pages for the bio's lifetime.

## Design Decisions & Tradeoffs

- **bio replaced buffer_head as the I/O unit (2.5).** The 2.4 block layer queued one `buffer_head` per block, typically 512 B–4 KiB. Jens Axboe's bio (2.5.1) describes a whole scatter-gather transfer, so one large I/O is one object. `buffer_head` survives only as a page-cache block-mapping helper for legacy filesystems.
- **Immutable biovecs.** Freezing the vector and moving state into a small iterator made splitting and cloning O(1) and allowed vector sharing. The cost was a large, tree-wide conversion in 3.13–3.14, and `bi_vcnt`/`bi_idx` became untrustworthy for drivers.
- **Split late, not early.** The pre-4.3 design made filesystems ask `merge_bvec_fn` "may I add this page?" for every page, which was costly and tricky for stacked drivers. Arbitrary-size bios with a single split point near the device removed `merge_bvec_fn` entirely. The cost is extra split allocations when upper layers build bios larger than the device can take.
- **Iterative, depth-first stacking.** `current->bio_list` bounds stack usage. The price was a class of mempool ordering deadlocks, first patched with rescuer threads and then solved properly by level-sorted processing (4.11).
- **Mempools everywhere.** Reserved bios guarantee progress under memory pressure. This is essential because writeback is how memory gets freed. Each stacking layer must own its own pool, or layers can starve each other.
- **Bio-based vs request-based.** Keeping a bio-based entry point lets remapping drivers (dm, md) and memory-backed devices (brd, zram, pmem) skip request allocation, merging and scheduling. The tradeoff is that they lose blk-mq's tag-based back-pressure and must provide their own.

## How It Has Evolved

- **2.5.1 (2001–2002)** — `struct bio` introduced by Jens Axboe, replacing buffer_head-based request queuing.
- **2.6.39** — per-task on-stack plugging replaces per-queue plugging.
- **3.13–3.14** — immutable biovecs and `bvec_iter` (Kent Overstreet). `bio_split()` works on arbitrary bios.
- **4.3** — arbitrary-size bios. `blk_queue_split()` in the core, `merge_bvec_fn` removed.
- **4.11** — NeilBrown's depth-sorted `bio_list` processing. Rescuer threads made optional.
- **4.13** — `blk_status_t` replaces errno in `bi_error` → `bi_status`.
- **4.14** — bios address a `gendisk` plus partition, later (5.12) `bi_bdev`.
- **5.1** — multi-page bvecs (Ming Lei).
- **5.15** — per-CPU bio allocation cache.
- **5.18** — `bio_alloc()` takes bdev and opf. `bio_alloc_clone()`.
- **6.0** — `blk_queue_split()` → `bio_split_to_limits()`. Splitting moved fully into blk-mq and bio-based drivers opt in.
- **6.x** — folio-native APIs (`bio_add_folio()`, `bio_for_each_folio_all()`), large block size (bs > PAGE_SIZE) support, atomic writes (6.11), bounce-buffer removal work, and exploration of physical-range (`phyr`) bvecs to decouple I/O from `struct page`.

## Further Reading

1. [A block layer introduction part 1: the bio layer — LWN (2017)](https://lwn.net/Articles/736534/)
2. [Driver porting: the BIO structure — LWN (2003)](https://lwn.net/Articles/26404/)
3. [block: support multi-page bvec — LWN (2019)](https://lwn.net/Articles/776535/)
4. [More IOPS with BIO caching — LWN (2021)](https://lwn.net/Articles/868070/)
5. [Moving the kernel to large block sizes — LWN (2023)](https://lwn.net/Articles/945987/)
6. [The state of the page in 2024 — LWN](https://lwn.net/Articles/973565/)
7. [Immutable biovecs and biovec iterators — kernel.org](https://www.kernel.org/doc/html/latest/block/biovecs.html)
8. [Explicit volatile write back cache control — kernel.org](https://www.kernel.org/doc/html/latest/block/writeback_cache_control.html)
9. [kernel-internals.org — bio and request structures](https://kernel-internals.org/block/bio-request/)

## LKML Highlights

> The LKML search tool was unreachable (TLS certificate error) during this run. The highlights below come from LWN and patchwork coverage.

- **"block: make sure big bio is splitted into at most 256 bvecs" (Ming Lei, 2016)** — after arbitrary-size bios landed, cloning paths (`bio_clone()`) could no longer handle huge bios. The fix capped splits at `BIO_MAX_PAGES` bvecs, an early sign that "split late" still needed guard rails.
- **"v4.9: 28 bioset threads on small notebook, 36 threads on cellphone" (2017, dm-devel/linux-block)** — complaints about per-bioset rescuer threads motivated NeilBrown's depth-sorted `generic_make_request()` rework, which made rescuers opt-in.
- **"block: support multi-page bvec" V13 (Ming Lei, Jan 2019)** — a years-long series (first posted as 60 patches in 2016) that split iteration into single-page `bio_for_each_segment()` and multi-page `bio_for_each_bvec()` so existing drivers kept working while splitting and scatterlist mapping got cheaper.
