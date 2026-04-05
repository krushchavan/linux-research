---
title: "Page Cache"
category: concept
tags: [memory, mm, page-cache, file-io, readahead, writeback, folio]
subsystem: mm
kernel_version: "1.0+"
researched: 2026-04-05
status: complete
sources:
  - https://kernel-internals.org/mm/page-cache/
  - https://lwn.net/Articles/888715/
  - https://lwn.net/Articles/878016/
  - https://lwn.net/Articles/750540/
  - https://lwn.net/Articles/715948/
  - https://static.lwn.net/kerneldoc/core-api/xarray.html
---

# Page Cache

## Purpose

Every file I/O goes through the page cache. When userspace calls `read()`, the kernel copies data from cached pages in RAM rather than hitting storage again. When `write()` returns, the data is in a dirty cached page — the actual device write happens in the background. The page cache is the reason "recently used files feel instant": it exploits the enormous gap between RAM latency (~100 ns) and NVMe latency (~100 µs), let alone spinning disk (~10 ms). Without the page cache, every `read()` would wait for device I/O.

The page cache also underpins `mmap()`: a file-backed VMA's pages *are* page cache pages. Reading from an mmap'd region faults in the same pages that a `read()` syscall would populate, and both accesses benefit from the same cached data.

## Mental Model

The page cache is a giant associative array, keyed by `(inode, page_offset)`. Every file open on the system shares this one cache. When process A reads page 5 of `/lib/libc.so` and process B later reads the same page, it's the same physical page in RAM, mapped into both processes' address spaces read-only. A dirty page is a page that has been modified in RAM but not yet flushed to the backing device — like a whiteboard with unsaved notes. Writeback threads periodically photograph the whiteboard (flush dirty pages to disk) and mark those pages clean again.

## How It Works

**The `address_space`.** Every file in the kernel is represented by a `struct inode`. Attached to the inode is a `struct address_space`, which is the page cache for that file. Its core field is `i_pages` — an `XArray` (a tree-based array abstraction) indexed by page offset within the file. Looking up whether page offset 17 of `/etc/passwd` is in cache is an XArray lookup: fast, RCU-safe for readers, and lock-free for cache hits.

The `address_space` also holds `a_ops` — a `struct address_space_operations` function table. This is the file system's callback interface: when the page cache needs to read a page from disk, it calls `a_ops->readpage()`; when it wants to write a dirty page back, it calls `a_ops->writepage()`. The page cache itself is filesystem-agnostic; ext4, btrfs, XFS, and tmpfs all plug in their own `a_ops`.

**Reading a file — the cache hit path.** A `read()` syscall reaches `filemap_read()` (`mm/filemap.c`). For each page-aligned chunk of the requested range, `filemap_get_pages()` does an XArray lookup (`xa_find()` / `find_get_pages_contig()`). If the folio is present and up-to-date (`folio_test_uptodate()`), it's pinned with `folio_get()`, and `copy_page_to_iter()` copies the data to the user buffer. No I/O, no lock beyond the brief XArray RCU read.

**Reading a file — the cache miss path.** If the XArray lookup misses, `filemap_read()` calls `filemap_get_read_batch()` which triggers `page_cache_sync_readahead()`. Rather than reading just the requested page, the kernel reads ahead — it allocates a window of pages (starting at the current position, with size determined by `file_ra_state.size`), calls `a_ops->readahead()` which submits the block I/O, and then waits for the *requested* page to become up-to-date before returning. The extra pages beyond the requested one are brought in speculatively and left in cache.

**Readahead and sequential detection.** The readahead engine (`mm/readahead.c`) tracks access patterns in `struct file_ra_state` per open file description. The key state is `ra->start` and `ra->size` (the current window) and `ra->async_size` (the "trigger zone" at the tail of the window). When the kernel fetches a readahead window, it marks the first page of the async zone with `PG_readahead`. When *that* page is subsequently accessed (meaning the application consumed the pages before it), `filemap_fault()` or `filemap_read()` calls `page_cache_async_readahead()` to issue the *next* window — this time asynchronously, before the application reaches it. Each successful hit doubles the window, up to `ra_pages` (128 KB default, tunable via `/sys/block/*/queue/read_ahead_kb`). A random access pattern (large gaps between offsets, or `posix_fadvise(POSIX_FADV_RANDOM)`) suppresses readahead.

**Writing — the dirty page path.** `write()` reaches `generic_perform_write()` → `a_ops->write_begin()` which allocates or finds the target folio in the page cache, locks it, and returns a writable pointer. The caller copies data in, then calls `a_ops->write_end()`, which marks the folio dirty (`folio_mark_dirty()`) and unlocks it. The syscall returns to userspace immediately — the data is in RAM but not yet on disk. This is the source of the "write returns instantly" behaviour, and also the reason power loss before writeback can lose data.

Dirty pages accumulate until one of several triggers fires:
- **Background threshold**: when dirty pages exceed `vm.dirty_background_ratio` (default 10% of RAM), `wakeup_flusher_threads()` wakes a `kworker/flush-*` thread.
- **Hard limit**: when dirty pages exceed `vm.dirty_ratio` (default 20%), writers are throttled — `balance_dirty_pages()` makes the writing process sleep until writeback catches up.
- **Age**: pages dirty for more than `dirty_expire_centisecs` (default 3000 = 30 s) are flushed on the next flush cycle.
- **Explicit**: `sync()`, `fsync()`, `msync()` flush specific or all dirty pages immediately.

Writeback calls `a_ops->writepage()` (or `writepages()` for batched I/O), which submits `struct bio` requests through the block layer and marks pages `PG_writeback`. Once I/O completes, the block layer calls `end_page_writeback()`, clearing `PG_writeback` and `PG_dirty`, leaving the page clean.

**Folios (v5.16+).** Historically, the page cache stored one `struct page` per 4 KB unit. Large compound pages (e.g. 2 MB huge pages in the page cache) were stored as `2^N` identical entries in the XArray — redundant and prone to bugs during operations like `msync()` that iterated page-by-page. Matthew Wilcox introduced `struct folio` (merged in v5.16) as the type-safe unit of the page cache: a folio is a physically contiguous group of one or more pages, stored as a *single* multi-index XArray entry spanning its full range. A 2 MB huge page in the page cache is now one folio occupying indices 0–511 of a 4 KB-indexed XArray, not 512 separate entries. The folio API (`folio_get`, `folio_put`, `folio_lock`, `folio_test_dirty`, etc.) replaces the old `page`-based equivalents throughout `mm/filemap.c` and `mm/page-writeback.c`.

**Truncation and invalidation.** When a file is truncated (`truncate_inode_pages()`) or unmapped, the page cache must discard pages for the truncated range. `invalidate_mapping_pages()` walks the XArray range, tries to lock each folio, and if there are no external references, removes it from the XArray, unmaps it from any PTEs that referenced it, and frees it. Pages under writeback cannot be immediately freed — they are marked for truncation and freed when writeback completes.

**`O_DIRECT` — bypassing the cache.** Applications that maintain their own caches (databases like PostgreSQL, RocksDB) can open files with `O_DIRECT` to bypass the page cache entirely. I/O goes through `direct_IO()` in `a_ops`, which submits `bio`s directly. No folio is allocated; no dirty tracking; no double-buffering. The cost: no readahead, no write coalescing, and the caller must use aligned buffers.

## Key Data Structures

**`struct address_space`** (`include/linux/fs.h`) — the page cache for one inode.
- `host` — the owning `struct inode`
- `i_pages` — `struct xarray`; the cache itself, indexed by page offset in units of `PAGE_SIZE`
- `nrpages` — count of resident (non-folio-batch) pages; used by reclaim to score this inode
- `writeback_index` — next page to write back; used to cycle through dirty pages
- `a_ops` — `struct address_space_operations *`; filesystem callbacks
- `flags` — `AS_EIO` (I/O error), `AS_ENOSPC`, `AS_UNEVICTABLE`

**`struct address_space_operations`** (`include/linux/fs.h`) — filesystem callbacks.
- `readpage` / `readahead` — fill one page / a batch from storage
- `writepage` / `writepages` — flush one dirty page / a batch to storage
- `write_begin` / `write_end` — called around a write; handle folio locking and dirtying
- `direct_IO` — O_DIRECT path
- `invalidate_folio` — filesystem-specific teardown when a folio is evicted

**`struct file_ra_state`** (`include/linux/fs.h`) — readahead state per open file description.
- `start` — first page of the current readahead window
- `size` — size of the current window (in pages); doubles on sequential hits
- `async_size` — number of pages at the tail of the window marked for async trigger
- `ra_pages` — per-device maximum readahead size

**`struct folio`** (`include/linux/mm_types.h`) — the page cache's currency (v5.16+).
- Embeds a `struct page` at offset 0 (union-compatible)
- `flags` — `PG_dirty`, `PG_writeback`, `PG_uptodate`, `PG_locked`, `PG_readahead`, etc.
- `mapping` — points back to the `address_space` that owns it
- `index` — page offset within `mapping` of the first page of this folio
- `_folio_nr_pages` — number of constituent pages (1 for normal; >1 for large folio)

## Key Functions / Entry Points

**`filemap_read(kiocb, iter, already_read)`** (`mm/filemap.c`) — entry point for `read()` on cached files; drives the hit/miss/readahead loop.

**`filemap_fault(vmf)`** (`mm/filemap.c`) — entry point for file-backed page faults; finds or loads the folio and returns it to the fault handler.

**`page_cache_sync_readahead(mapping, ra, file, index, req_count)`** (`mm/readahead.c`) — synchronous readahead triggered on a cache miss.

**`page_cache_async_readahead(mapping, ra, file, folio, index, req_count)`** (`mm/readahead.c`) — asynchronous readahead triggered when `PG_readahead` page is accessed.

**`folio_mark_dirty(folio)`** (`mm/page-writeback.c`) — mark a folio as modified; sets `PG_dirty` and adds it to the dirty accounting.

**`balance_dirty_pages_ratelimited(mapping)`** (`mm/page-writeback.c`) — called by writers after marking a page dirty; throttles if dirty pages exceed `dirty_ratio`.

**`writeback_sb_inodes()`** (`fs/fs-writeback.c`) — core writeback loop; iterates dirty inodes and calls `do_writepages()` → `a_ops->writepages()`.

**`truncate_inode_pages_range(mapping, lstart, lend)`** (`mm/truncate.c`) — remove a range of pages from the cache; called on file truncation or unlink.

**`add_to_page_cache_lru(folio, mapping, index, gfp)`** (`mm/filemap.c`) — insert a newly allocated folio into the XArray and the LRU list.

## Important Flags & Config Options

| Flag / Sysctl | Meaning |
|--------------|---------|
| `PG_dirty` | Folio has been modified; needs writeback |
| `PG_writeback` | Folio is under active writeback I/O |
| `PG_uptodate` | Folio content is valid (read I/O completed) |
| `PG_locked` | Folio is locked for exclusive access (e.g. read I/O in progress) |
| `PG_readahead` | This page is the async readahead trigger |
| `vm.dirty_ratio` | Max % of RAM as dirty pages before writers block (default 20) |
| `vm.dirty_background_ratio` | % of RAM at which background writeback starts (default 10) |
| `vm.dirty_expire_centisecs` | Age (in centiseconds) at which dirty pages must be written (default 3000) |
| `vm.dirty_writeback_centisecs` | How often flusher threads wake to check (default 500) |
| `O_DIRECT` | Bypass page cache for this file descriptor |
| `POSIX_FADV_RANDOM` | Disable readahead for this file descriptor |
| `POSIX_FADV_WILLNEED` | Pre-populate cache for a range (readahead hint) |

## Interactions with Other Subsystems

- **↑ VFS / filesystem drivers**: Every filesystem provides `address_space_operations`; the page cache calls back into the filesystem for I/O but manages caching itself.
- **→ [[page-fault-handler]]**: `filemap_fault()` is the `vm_ops->fault()` handler for file-backed VMAs; it populates the page cache on demand.
- **← [[virtual-memory-areas]]**: `vm_file` in a VMA points to the file whose `address_space` backs that mapping; the VMA and the page cache share the same physical pages.
- **→ [[page-reclaim]]**: Reclaim's LRU lists contain page cache folios; under memory pressure, clean cache pages are evicted cheaply (they can be reloaded from disk), while dirty ones must be written back first.
- **→ Block layer / I/O**: `a_ops->readahead()` and `writepages()` submit `struct bio` requests; the page cache waits on `folio_wait_locked()` for I/O completion.
- **← memcg**: Page cache pages can be charged to a memory cgroup; `mem_cgroup_charge()` tracks file-backed memory usage per cgroup.

## Design Decisions & Tradeoffs

**Unified cache for all files.** A single shared cache means process A's read warms the cache for process B reading the same file. The tradeoff is that one large sequential scan (e.g. `grep` over a huge log) can evict hot data for other processes. The MGLRU reclaim policy (v6.1) mitigates this by better separating recently-accessed from older pages.

**Write-behind (asynchronous writeback).** `write()` returns immediately after placing data in a dirty page, rather than waiting for disk acknowledgement. This dramatically improves write throughput and latency for applications — `cp` finishes "instantly" for files that fit in RAM. The cost is that power loss between `write()` and writeback loses data. Applications requiring durability must call `fsync()`.

**XArray over radix tree (v4.20).** The radix tree (used from v2.6) required a spinlock for all modifications and was awkward to extend. The XArray (Matthew Wilcox, v4.20) provides a cleaner API, lock-less RCU reads for cache lookups, and native support for multi-index entries (used by large folios). The migration was purely internal — userspace semantics unchanged.

**Folios over struct page (v5.16).** The old API used `struct page *` for both single pages and compound pages, leading to subtle bugs when code assumed one page per cache slot. `struct folio` is a distinct type that cannot be confused with a raw `struct page`; the compiler catches misuse. Large folios (>4 KB in the page cache) reduce per-page overhead for huge-page-backed files and can reduce TLB pressure.

## How It Has Evolved

| Version | Change | Driver |
|---------|--------|--------|
| Linux 1.0 | Basic page cache + buffer cache (separate) | File I/O performance |
| v2.4 (2001) | Unified page cache (buffer cache merged in) | Eliminate double caching of file data |
| v2.6 | Radix tree replaces linked-list indexing | O(log n) lookup for large files |
| v4.20 (2018) | XArray replaces radix tree | Cleaner API, RCU-safe lookups, lock reduction |
| v5.16 (2022) | `struct folio` introduced | Type safety; huge-page page cache; eliminate 2^N duplicate entries |
| v6.1 (2022) | MGLRU; improved eviction of page cache vs. anon | Better workload isolation under reclaim |
| v6.8 (2024) | Large folio read/write paths | Reduce overhead per I/O for large sequential reads |

## Further Reading

1. [LWN — Readahead: the documentation I wanted to read](https://lwn.net/Articles/888715/) — comprehensive readahead mechanism walkthrough; `file_ra_state`, `PG_readahead`, sequential detection
2. [LWN — Convert page cache to XArray](https://lwn.net/Articles/750540/) — rationale for the radix → XArray migration
3. [LWN — Folios for 5.17](https://lwn.net/Articles/878016/) — introduction of `struct folio` and the multi-index XArray entry
4. [LWN — Introducing the XArray](https://lwn.net/Articles/715948/) — the XArray data structure itself; design goals and API

## LKML Highlights

- **XArray merge (Matthew Wilcox, v4.20, 2018)** — the cover letter explicitly argues that a cleaner API reduces the risk of locking errors; it documents the key insight that page cache lookups need only RCU, not a spinlock, which the radix tree's API obscured but XArray makes explicit.

- **struct folio introduction (Matthew Wilcox, v5.16, 2022)** — a multi-year campaign spanning dozens of patch series; Wilcox's motivation (stated across many LKML threads) was that the compound-page API had no way to enforce which `struct page *` arguments referred to a whole compound page vs. a tail page, leading to subtle bugs. The folio type makes this a compile-time distinction.
