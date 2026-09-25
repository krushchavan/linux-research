---
title: "Writeback Infrastructure"
category: concept
tags: [fs, vfs, writeback, dirty-pages, bdi, flusher, throttling]
subsystem: fs
kernel_version: "2.4+"
researched: 2026-04-05
status: complete
explained: "[[writeback-infrastructure-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://lwn.net/Articles/326552/
  - https://lwn.net/Articles/682582/
  - https://lwn.net/Articles/648292/
  - https://lwn.net/Articles/405076/
  - https://lwn.net/Articles/572911/
---

# Writeback Infrastructure

> 📘 Plain-language version: [[writeback-infrastructure-explained]]

## Purpose

Writeback is the process of flushing dirty pages and dirty inodes from RAM back to persistent storage. Without it, every `write(2)` call would block on disk I/O. Writeback decouples the write syscall from the physical I/O by buffering writes in the page cache and draining them asynchronously, while providing mechanisms to bound memory usage (dirty throttling), enforce persistence deadlines (periodic flush), and guarantee durability on `fsync`.

## Mental Model

The kernel runs a write-behind cache: processes write into DRAM and immediately return. Separately, flusher kernel threads drain the dirty pages to disk at rates calibrated to the storage device's bandwidth. If processes dirty pages faster than storage can absorb them, `balance_dirty_pages()` makes the writers sleep briefly — a back-pressure mechanism that matches input to output rate. `fsync` bypasses the asynchrony and forces a synchronous flush of everything dirty for a specific file.

## How It Works

### Marking pages and inodes dirty

When a process writes to a file, `generic_perform_write()` eventually calls `dirty_folio()` (the address space's `a_ops->dirty_folio` callback, or `filemap_dirty_folio()` by default). This sets `PG_dirty` on the folio and calls `__mark_inode_dirty(inode, I_DIRTY_PAGES)`, which:

1. Sets `I_DIRTY_PAGES` in `inode->i_state`.
2. If the inode was clean, moves it from `bdi_writeback.b_clean_inodes` to `bdi_writeback.b_dirty` (the dirty inode list).
3. Records `inode->dirtied_when = jiffies` — the time of first dirtying, used by the expiry logic.

Metadata-only dirtiness (changing `i_mtime`, `i_size`) sets `I_DIRTY_SYNC` or `I_DIRTY_DATASYNC`. The `a_ops->dirty_folio` callback may also update filesystem-private state (e.g. ext4 journaling).

### backing_dev_info and bdi_writeback

Every block device (and some virtual devices like sockets, pipes) has a `struct backing_dev_info` (`bdi`) registered in `bdi_list`. The BDI tracks the device's capabilities and holds one or more `struct bdi_writeback` (`wb`) instances.

```c
struct bdi_writeback {
    struct backing_dev_info *bdi;      /* owning BDI */
    struct list_head b_dirty;          /* dirty inodes (not yet under I/O) */
    struct list_head b_io;             /* inodes being written now */
    struct list_head b_more_io;        /* inodes deferred for later this cycle */
    struct list_head b_dirty_time;     /* inodes dirty only in timestamp (lazytime) */
    unsigned long    last_old_flush;   /* time of last periodic flush */
    struct delayed_work dwork;         /* periodic flush work */
    struct delayed_work bw_dwork;      /* bandwidth estimation work */
    struct task_struct *task;          /* the wb kernel thread */
    /* … cgwb fields … */
    struct fprop_local_percpu completions; /* bandwidth tracking */
    unsigned long    dirty_ratelimit;  /* current estimated clean rate */
    unsigned long    balanced_dirty_ratelimit; /* target rate */
};
```

Each `bdi_writeback` owns a kernel thread (`bdi/<device>/0` visible in `ps`) that drives all writeback for that device (or cgroup+device pair in cgwb mode).

### Flusher threads: wb_writeback()

The flusher thread runs in a `delayed_work` loop. It wakes at two occasions:

1. **Periodic**: every `dirty_writeback_interval` (default 5 seconds) to flush inodes older than `dirty_expire_interval` (default 30 seconds). An inode whose first dirty time is more than 30 seconds ago must be written back even if the system has plenty of dirty budget left.

2. **On-demand**: when `wakeup_flusher_threads()` or `wb_start_writeback()` is called — by `sync(2)`, `fsync(2)`, or dirty throttling pressure.

The thread calls `wb_do_writeback(wb)` → `wb_writeback(wb, work)`. The work struct (`struct wb_writeback_work`) specifies the scope: a specific superblock or all, a page count target or unlimited, a sync mode (`WB_SYNC_NONE` for background, `WB_SYNC_ALL` for sync/fsync), and a range.

`wb_writeback()` iterates `wb->b_io` (inodes ready for I/O). For each inode it builds a `struct writeback_control`:

```c
struct writeback_control {
    long              nr_to_write;       /* remaining pages budget */
    long              pages_skipped;     /* pages skipped (locked, etc.) */
    loff_t            range_start;       /* byte range to write (for fsync) */
    loff_t            range_end;
    enum writeback_sync_modes sync_mode; /* WB_SYNC_NONE or WB_SYNC_ALL */
    unsigned          for_kupdate:1;     /* periodic flush? */
    unsigned          for_background:1; /* background writeout? */
    unsigned          for_reclaim:1;    /* invoked from memory reclaim? */
    unsigned          range_cyclic:1;   /* use address_space->writeback_index */
    unsigned          no_cgroup_owner:1;
    struct bdi_writeback *wb;
    struct inode     *inode;
};
```

`writepages()` (or `write_cache_pages()` if the filesystem uses the generic helper) selects dirty folios in `inode->i_mapping` using the `PG_dirty` tag in the XArray, calls `a_ops->writepage(folio, wbc)` for each, and sets `PG_writeback` to mark them in-flight. The block layer queues the I/O; when it completes, `end_page_writeback()` clears `PG_writeback` and wakes anyone waiting on the folio.

### Inode writeback: write_inode and clear_inode

After `writepages()` flushes the data, `writeback_single_inode()` calls `sb->s_op->write_inode(inode, wbc)` to persist the inode metadata (size, timestamps, block map). When writeback completes and the inode has no remaining dirty pages or dirty metadata, `__mark_inode_dirty` transitions it back to `b_clean_inodes` (or the LRU if its refcount is zero).

### Dirty throttling: balance_dirty_pages()

Every process that dirties pages calls `balance_dirty_pages_ratelimited()` from `__filemap_dirty_folio()`. Periodically (every ~32 dirtied pages), it calls `balance_dirty_pages(wb, ...)` which compares the current dirty page count against two thresholds:

| Threshold | Sysctl | Default | Meaning |
|-----------|--------|---------|---------|
| **background** | `dirty_background_ratio` | 10% of available RAM | Flusher wakes up and starts background writeback |
| **foreground** | `dirty_ratio` | 20% of available RAM | Processes are throttled |

Between the background and foreground thresholds, the throttling uses a **proportional** algorithm (introduced in 2.6.37). Rather than blocking until below the background threshold (which caused bursty write patterns), it computes a pause time proportional to how far above the background threshold the system is. Pause is capped at 200 ms; if the computed pause is below 10 ms, the per-process `nr_dirtied_pause` limit grows (allow more dirtying); if above 100 ms, it halves. This keeps writers in the 10–100 ms pause zone, ensuring steady forward progress.

Above the foreground threshold (`dirty_ratio`), writers block unconditionally in `balance_dirty_pages()` until dirty pages drop below the foreground threshold.

Absolute limits (in pages) can be set via `dirty_background_bytes` and `dirty_bytes` which override the ratio-based thresholds.

### The USB-stick stall problem

The global dirty threshold was computed as a fraction of total RAM, regardless of the speed of any individual storage device. On a system with a fast SSD and a slow USB stick, writing to the USB stick could accumulate millions of dirty pages (bounded only by the global 20% threshold) and then block all writers for seconds while the slow device drains. The per-BDI dirty limit (introduced in 2.6.31) added per-device quotas sized proportional to the device's measured bandwidth, preventing any one slow device from monopolising the global dirty budget.

### Synchronous writeback: fsync path

`fsync(2)` calls `vfs_fsync_range()` → `f_op->fsync()` (e.g. `ext4_sync_file()`). The filesystem typically:
1. Calls `filemap_write_and_wait_range(inode->i_mapping, start, end)` to write and wait for all dirty pages in the range.
2. Calls `sync_inode_metadata(inode, 1)` to flush the inode's metadata.
3. Issues a `blkdev_issue_flush()` if `O_SYNC` / `O_DSYNC` semantics require it.

Error reporting uses `errseq_t`: when a writeback I/O error occurs, `mapping_set_error(mapping, error)` encodes the error in `mapping->wb_err` via `errseq_set()`. Each open `struct file` has its own `f_wb_err` cursor; `file_check_and_advance_wb_err(file)` during `fsync` delivers the error exactly once per file description, satisfying POSIX "errors are reported to the process that called fsync".

### Cgroup-aware writeback (cgwb)

Before cgwb (4.2), cgroup I/O control was ineffective for buffered writes: the memory controller tracked dirty page ownership, but the block I/O controller saw only anonymous writeback I/O from the flusher thread, not associated with any cgroup. This made per-cgroup I/O limits useless for `write(2)`.

Cgwb assigns each `(bdi, blkcg)` pair its own `struct bdi_writeback` instance. The flusher thread for each `wb` runs with the correct blkcg context, so the block I/O controller sees the cgroup that originated the writes. The dirty throttling (`balance_dirty_pages`) enforces limits at two levels: the global `wb_domain` (system-wide `dirty_ratio`) and the per-cgroup `wb_domain` (cgroup's blkio limit), using the more restrictive of the two.

Inode ownership to a cgroup is determined lazily: `inode_cgwb_move_to_attached()` runs the Boyer-Moore majority vote algorithm over a sliding window of recent I/O operations on the inode. If one cgroup accounts for the majority of recent writes, the inode migrates to that cgroup's `bdi_writeback`. This avoids per-folio tracking complexity while converging quickly for typical workloads (one writer per file).

## Key Data Structures

**`struct backing_dev_info`** (`include/linux/backing-dev.h`) — per-block-device metadata: `wb` (the default writeback instance), `wb_list` (all cgwb instances), per-BDI dirty limits, bandwidth statistics.

**`struct bdi_writeback`** (`include/linux/backing-dev-defs.h`) — the writeback engine for one device (or one cgroup+device pair): dirty/IO/deferred inode lists, flusher thread, dirty rate estimator.

**`struct writeback_control`** (`include/linux/writeback.h`) — per-writeback-operation parameters: page count budget, byte range, sync mode, caller context flags.

**`struct wb_writeback_work`** (`fs/fs-writeback.c`) — one unit of writeback work queued to a `bdi_writeback`: scope (sb, all), count, sync mode, reason.

## Key Functions / Entry Points

**`__mark_inode_dirty(inode, flags)`** (`fs/fs-writeback.c`) — marks inode dirty with given flags; moves to `wb->b_dirty` if previously clean; records `dirtied_when`.

**`balance_dirty_pages_ratelimited(mapping)`** (`mm/page-writeback.c`) — called after every page dirtied; throttles writer if dirty threshold exceeded.

**`balance_dirty_pages(wb, task_ratelimit)`** (`mm/page-writeback.c`) — computes and applies pause time; triggers `wakeup_flusher_threads()` if background threshold crossed.

**`wb_writeback(wb, work)`** (`fs/fs-writeback.c`) — core writeback loop: iterates dirty inodes, calls `writeback_single_inode()`.

**`writeback_single_inode(inode, wbc)`** (`fs/fs-writeback.c`) — flushes one inode: calls `a_ops->writepages()`, then `s_op->write_inode()`.

**`filemap_write_and_wait_range(mapping, start, end)`** (`mm/filemap.c`) — writes all dirty pages in range then waits for `PG_writeback` to clear; used by `fsync`.

**`mapping_set_error(mapping, error)`** (`include/linux/pagemap.h`) — records I/O error in `mapping->wb_err` via `errseq_t`.

**`file_check_and_advance_wb_err(file)`** (`include/linux/fs.h`) — checks for new errors since last `fsync` for this file descriptor; delivers error once.

## Important Flags & Config Options

| Knob | Default | Meaning |
|------|---------|---------|
| `vm.dirty_background_ratio` | 10 | % of available RAM; background flush threshold |
| `vm.dirty_ratio` | 20 | % of available RAM; foreground throttle threshold |
| `vm.dirty_background_bytes` | 0 | absolute background threshold (overrides ratio) |
| `vm.dirty_bytes` | 0 | absolute foreground threshold (overrides ratio) |
| `vm.dirty_writeback_centisecs` | 500 | flusher wake interval (5 s) |
| `vm.dirty_expire_centisecs` | 3000 | age at which dirty data must be flushed (30 s) |
| `I_DIRTY_SYNC` | — | inode flag: mtime/ctime changed |
| `I_DIRTY_DATASYNC` | — | inode flag: i_size or block map changed |
| `I_DIRTY_PAGES` | — | inode flag: data pages are dirty |
| `I_DIRTY_TIME` | — | inode flag: only timestamps dirty (lazytime) |
| `PG_dirty` | — | folio flag: data not yet written to storage |
| `PG_writeback` | — | folio flag: I/O in flight |
| `WB_SYNC_ALL` | — | wbc mode: wait for completion of each page |
| `WB_SYNC_NONE` | — | wbc mode: background, skip locked pages |

## Interactions with Other Subsystems

- **↑ Userspace**: `write(2)` dirties pages; `fsync(2)` / `sync(2)` force synchronous writeback; `posix_fadvise(POSIX_FADV_DONTNEED)` can trigger writeback of a range.
- **→ [[Address Space]]**: dirty folios are tracked in `inode->i_mapping`'s XArray with the `PG_dirty` tag; `a_ops->writepages()` is the filesystem hook for bulk writes.
- **→ [[Inode Cache]]**: dirty inodes are moved between `wb->b_dirty`, `b_io`, `b_more_io` lists; `I_DIRTY_*` flags guard against premature LRU eviction.
- **← [[Page Reclaim]]**: `shrink_folio_list()` calls `pageout()` which invokes `a_ops->writepage()` for `for_reclaim=1` writeback when memory is tight; dirty pages cannot be reclaimed until written.
- **→ Block Layer**: `wb_writeback()` ultimately issues `submit_bio()` calls; per-BDI dirty limits interact with the block layer's request queue depth.
- **← cgroupfs**: `bdi_writeback` per-cgroup instances attach to blkio cgroups; `wb_domain` enforces per-cgroup dirty limits.

## Design Decisions & Tradeoffs

**Per-BDI flusher threads (2.6.32) vs. global pdflush**: The old pdflush pool used a fixed number of global threads that could be tied up on slow devices, starving fast devices of writeback bandwidth. Per-BDI threads eliminate this interference: a USB stick's flusher thread blocking on slow I/O cannot delay an SSD's writeback. The cost is more kernel threads (one per device), justified by the 25%+ throughput improvement on multi-disk systems.

**Proportional throttling vs. cliff throttling**: The original `balance_dirty_pages()` would let writers run freely until the global dirty threshold, then block all of them simultaneously — a "cliff" that caused I/O avalanches. The proportional algorithm (Wu Fengguang, 2.6.37) introduces a gradual slope: writers are slowed proportionally as they approach the threshold, spreading the I/O load smoothly. This eliminates the latency spikes observed in database and streaming workloads.

**Lazy inode cgwb migration (Boyer-Moore)**: Tracking which cgroup owns each folio would require per-folio metadata — expensive in memory. Instead, cgwb tracks ownership at the inode level and migrates lazily. A per-folio approach would use 8+ bytes per page (4 GB RAM = 1M pages = 8 MB overhead) and add per-dirty-page overhead to the critical write path.

**errseq_t for per-fd error delivery**: Before errseq_t (4.13), `fsync()` errors could be missed (race with another writer clearing the error) or reported multiple times (every `fsync()` after the error). The seqcount-based errseq_t ensures each open file description sees each error exactly once, regardless of how many other fds are open on the same inode.

## How It Has Evolved

- **2.4**: Global `bdflush` daemon and `kupdate` flushed all dirty pages; single global dirty threshold.
- **2.6.0**: `pdflush` replaced `bdflush`; pool of 2–8 threads; still global per-device-group.
- **2.6.32** (2009): Per-BDI flusher threads (Jens Axboe); pdflush removed; per-BDI dirty limits.
- **2.6.37** (2011): Proportional dirty throttling (Wu Fengguang); replaced cliff-throttle with gradual slope.
- **3.2** (2012): Per-process `nr_dirtied_pause` limits; pause time bounded 10–100 ms.
- **4.2** (2015): Cgroup-aware writeback / cgwb (Tejun Heo); per-cgroup `bdi_writeback`; Boyer-Moore inode migration.
- **4.13** (2017): `errseq_t` per-fd error tracking; `f_wb_err` in `struct file`; fixes long-standing `fsync` error delivery races.
- **5.8** (2020): `lazytime` mount option formalised: timestamps-only dirtiness uses `I_DIRTY_TIME`, not `I_DIRTY_SYNC`, avoiding frequent inode writeback for access-heavy workloads.

## Further Reading

1. [Flushing out pdflush — LWN.net](https://lwn.net/Articles/326552/)
2. [Toward less-annoying background writeback — LWN.net](https://lwn.net/Articles/682582/)
3. [Writeback and control groups — LWN.net](https://lwn.net/Articles/648292/)
4. [Dynamic writeback throttling — LWN.net](https://lwn.net/Articles/405076/)
5. [The pernicious USB-stick stall problem — LWN.net](https://lwn.net/Articles/572911/)

## LKML Highlights

- **Per-BDI flusher threads** — Jens Axboe (2009, 18-version series): The central design debate was whether to keep a shared thread pool with per-device queuing, or go to fully per-BDI threads. Per-BDI won because the shared-pool approach still allowed a slow device to exhaust threads and stall others.
- **Proportional dirty throttling** — Wu Fengguang (2011): A multi-year effort replacing the cliff-throttle with the smooth-slope algorithm. The hardest part was estimating device bandwidth correctly without I/O benchmarks — the solution was an online exponential moving average of recent completion rates.
- **Cgroup-aware writeback** — Tejun Heo (2015): The key insight was that the per-cgroup `bdi_writeback` was an entirely additive change — the default `wb` remained for non-cgroup paths — making the plumbing tractable without a rewrite. Reviewers praised the Boyer-Moore ownership approach as elegant given the constraint of not wanting per-folio cgroup tracking.
