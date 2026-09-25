---
title: "Address Space (struct address_space)"
category: concept
tags: [mm, page-cache, address-space, writeback, vfs, xarray]
subsystem: mm
kernel_version: "2.4+"
researched: 2026-04-05
status: complete
explained: "[[address-space-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://www.kernel.org/doc/html/latest/core-api/mm-api.html
  - https://docs.kernel.org/filesystems/locking.html
  - https://lwn.net/Articles/250461/
  - https://notes.eddyerburgh.me/operating-systems/linux/the-page-cache-and-page-writeback
---

# Address Space (struct address_space)

> 📘 Plain-language version: [[address-space-explained]]

## Purpose

`struct address_space` is the kernel's per-object page cache manager. Every inode that participates in the page cache owns one, embedded as `inode->i_data`; block devices, pipes, and swap space also use address spaces. It is the central hub through which pages are looked up by file offset, dirtied, written back, invalidated, and migrated — providing a uniform interface so the VM, VFS, and writeback subsystems can treat all cached objects the same way regardless of their backing store.

## Mental Model

Think of `address_space` as a software MMU for a single file. Just as the hardware MMU translates virtual page numbers to physical frames, an address space translates file-page indices to cached folios. The `a_ops` function table is the "ISA" of that software MMU — each filesystem implements its own read/write/invalidate instructions while the VM calls them through a stable interface.

## How It Works

### Structure layout and the xarray

The struct (defined in `include/linux/fs.h`) holds every piece of state the VM needs to manage one object's page cache:

```c
struct address_space {
    struct inode           *host;          /* owner: inode or NULL */
    struct xarray           i_pages;       /* cached folios, keyed by page index */
    struct rw_semaphore     invalidate_lock;
    gfp_t                   gfp_mask;      /* allocation flags for new pages */
    atomic_t                i_mmap_writable; /* count of writable MAP_SHARED VMAs */
    struct rb_root_cached   i_mmap;        /* tree of all VMAs mapping this file */
    unsigned long           nrpages;       /* total cached pages */
    pgoff_t                 writeback_index; /* where next writeback pass starts */
    const struct address_space_operations *a_ops;
    unsigned long           flags;         /* AS_EIO, AS_ENOSPC, error flags */
    errseq_t                wb_err;        /* sticky write-error sequence number */
    spinlock_t              i_private_lock;
    struct list_head        i_private_list;
    void                   *i_private_data;
};
```

The heart is `i_pages`, an XArray (replacing the old radix tree in 4.20). It maps `pgoff_t` indices — file offsets measured in pages — to one of three value types:
- **Folio pointer**: a cached, in-memory copy of that file region.
- **Shadow entry**: a workingset shadow left after eviction, encoding the eviction time for refault-distance detection.
- **DAX entry**: a direct-access mapping into persistent memory (PMEM), bypassing the page cache.

The XArray provides O(1) lockless lookup via RCU for the common case and a slot-locked path for insertion and deletion. `xa_load(&mapping->i_pages, index)` is the fundamental lookup; `xa_store()` is the fundamental insert.

### The page->mapping pointer and anonymous pages

Every `struct page` (or `struct folio`) has a `mapping` field. For file-backed pages, `folio->mapping` points directly to the owning `address_space`. For **anonymous pages**, the same field is repurposed: it points to an `anon_vma` with bit 0 (`PAGE_MAPPING_ANON`) set to distinguish it. The helper `folio_mapping()` decodes this: if the low bit is set, it extracts the `anon_vma`; otherwise it returns the `address_space`. Two special cases:
- **Swap cache pages**: `folio->mapping` points to `swapper_space` — a globally shared `address_space` with `swap_aops` — and `folio->index` stores the `swp_entry_t`.
- **KSM pages**: `folio->mapping` is `PAGE_MAPPING_KSM` (value 3).

This encoding means `folio->mapping` is never a plain NULL for a live page, making it a reliable type tag with no extra memory cost.

### Read path: fault → read_folio → readahead

When a process reads from a file (via `read()` or a page fault on an `mmap`'d region), `filemap_fault()` / `filemap_read()` calls `__filemap_get_folio()` to look up the target index in `i_pages`. On a **cache hit**, the folio is returned with its reference count bumped; the caller copies data out of it and drops the reference.

On a **cache miss**, the kernel allocates a new folio, inserts it into `i_pages` via `filemap_add_folio()` (which takes the XArray lock), marks it `PG_locked`, and calls `a_ops->read_folio(file, folio)`. The filesystem reads the data from disk (usually via `submit_bio()`), marks the folio `PG_uptodate`, and unlocks it. Concurrently, `page_cache_ra_unbounded()` may have already issued readahead for surrounding pages using `a_ops->readahead()`, filling multiple folios with a single I/O batch.

### Write path: write_begin / write_end / dirty_folio

Generic file writes go through `generic_perform_write()`:

1. `a_ops->write_begin(file, mapping, pos, len, &folio, &fsdata)` — the filesystem ensures the target folio is in the page cache, locked, and ready for modification. For block-based filesystems this may involve reading the existing block so partial writes preserve unmodified bytes.
2. The caller copies user data into the folio.
3. `a_ops->write_end(file, mapping, pos, len, copied, folio, fsdata)` — the filesystem updates `i_size` if needed, calls `folio_mark_dirty()` (which calls `a_ops->dirty_folio()` if the filesystem provides it, otherwise uses `filemap_dirty_folio()`), unlocks the folio, and returns bytes consumed.

`dirty_folio()` sets `PG_dirty` on the folio and sets the `PAGECACHE_TAG_DIRTY` XArray tag, making the folio discoverable by writeback without a full scan of all pages.

### Writeback: writepages and wb_err

The writeback subsystem (`fs/fs-writeback.c`) wakes periodically and iterates all dirty inodes. For each, it calls `a_ops->writepages(mapping, &wbc)` where `wbc` is a `struct writeback_control` carrying constraints (how many pages, from where, deadline). The filesystem walks dirty pages via `writeback_iter()` (which uses `PAGECACHE_TAG_DIRTY` to find only dirty folios), calls `a_ops->writepage()` or issues batched I/O, and decrements `wbc.nr_to_write` as pages are submitted. Writeback starts at `mapping->writeback_index` and wraps around, giving roughly round-robin coverage of the dirty set.

Write errors are recorded with `mapping_set_error(mapping, error)`, which sets the appropriate bit in `mapping->flags` (AS_EIO, AS_ENOSPC) and advances the `wb_err` errseq. Each open file description carries its own errseq cursor; `file_check_and_advance_wb_err()` in `fsync()` advances the cursor and returns the error once — ensuring every fd that was open during an error sees it exactly once.

### Invalidation and the invalidate_lock

Truncating or punching holes in a file requires removing pages from `i_pages` and updating the filesystem's block map atomically. The `invalidate_lock` (an rwsem embedded in `address_space`) enforces this:
- **Writers** (truncate, hole-punch): take `invalidate_lock` exclusively, then remove pages from `i_pages`, then update the block map.
- **Readers** (page faults, reads): take `invalidate_lock` shared. This blocks faults from mapping pages that are about to be removed, preventing the window where a page is in the cache but points to a freed block.

`invalidate_inode_pages2_range()` purges all pages in a range; `truncate_inode_pages_range()` also handles partial-page truncation and calls `a_ops->invalidate_folio()` for folios with private data (buffer heads, etc.) and `a_ops->launder_folio()` for dirty folios that must be written back before removal.

### The i_mmap reverse-mapping tree

`i_mmap` is an interval tree (`struct rb_root_cached`) of all VMAs that map this file. It enables **reverse mapping** (rmap): given a folio in the page cache, `rmap_walk_file()` traverses `i_mmap` to find every VMA and PTE that references it. This is used by reclaim (`try_to_unmap()`), migration, and writeback. The `i_mmap_rwsem` protects `i_mmap`; `i_mmap_writable` counts VMAs with write permission, gating certain copy-on-write decisions.

## Key Data Structures

**`struct address_space_operations`** (`include/linux/fs.h`) — the vtable; key callbacks:

| Callback | Called with | Purpose |
|----------|-------------|---------|
| `read_folio(file, folio)` | folio locked | fill one folio from backing store |
| `readahead(rac)` | folios locked | fill a batch of folios for readahead |
| `writepages(mapping, wbc)` | — | write dirty pages; honours wbc constraints |
| `dirty_folio(mapping, folio)` | folio may be locked | mark folio dirty; set XArray DIRTY tag |
| `write_begin(file, mapping, pos, len, &folio, &fsdata)` | — | prepare folio for write; must return locked |
| `write_end(file, mapping, pos, len, copied, folio, fsdata)` | folio locked | finalise write; update i_size; mark dirty |
| `invalidate_folio(folio, offset, length)` | folio locked | remove private data on truncation/hole punch |
| `release_folio(folio, gfp)` | folio locked | try to release private data; return true if done |
| `free_folio(folio)` | folio not locked | final cleanup after freeing |
| `migrate_folio(mapping, dst, src, mode)` | both locked | copy private data during migration |
| `bmap(mapping, block)` | — | logical→physical block mapping (swap/FIBMAP) |
| `direct_IO(iocb, iter)` | — | O_DIRECT path bypassing page cache |
| `launder_folio(folio)` | folio locked | write back dirty folio before freeing |
| `filemap_fault(vmf)` | — | handle page fault in mmap'd region |
| `swap_activate/deactivate/rw` | varies | swap file operations |

**`errseq_t wb_err`** — a sequence-number-encoded sticky error. Advances on every write error; each `file` carries its own read cursor so errors are delivered to every open fd exactly once.

## Key Functions / Entry Points

**`__filemap_get_folio()`** (`mm/filemap.c`) — core page cache lookup; checks `i_pages` XArray, allocates on miss with `FGP_CREAT`, waits for locked pages with `FGP_WAITPAGE`.

**`filemap_fault()`** (`mm/filemap.c`) — page-fault entry for mmap'd files; calls `__filemap_get_folio()`, issues readahead, installs PTE.

**`filemap_read()`** (`mm/filemap.c`) — read(2) entry; assembles pages from cache, copies to user, triggers readahead.

**`generic_perform_write()`** (`mm/filemap.c`) — write(2) loop; calls `write_begin`/`write_end` per chunk.

**`filemap_fdatawrite_range()`** / **`filemap_fdatawait_range()`** (`mm/filemap.c`) — synchronous writeback and wait-for-completion; used by `fsync()` and `O_SYNC` writes.

**`invalidate_inode_pages2_range()`** (`mm/truncate.c`) — removes pages from `i_pages`, unmaps PTEs; called on truncate and by direct I/O paths before issuing bypass reads.

**`mapping_set_error()`** (`include/linux/pagemap.h`) — records a write error in `wb_err` and `flags`.

**`folio_mapping()`** (`include/linux/mm.h`) — decodes `folio->mapping`; handles anon, swap, KSM, and file-backed cases.

## Important Flags & Config Options

| Flag / Knob | Location | Effect |
|-------------|----------|--------|
| `AS_EIO` | `mapping->flags` | sticky I/O error flag; checked by `mapping_error()` |
| `AS_ENOSPC` | `mapping->flags` | sticky ENOSPC error |
| `AS_UNEVICTABLE` | `mapping->flags` | all pages in this mapping are unevictable |
| `AS_NO_WRITEBACK_TAGS` | `mapping->flags` | disable dirty/writeback XArray tags (used by DAX) |
| `PAGECACHE_TAG_DIRTY` | XArray tag | set by `dirty_folio`; consumed by `writepages` |
| `PAGECACHE_TAG_WRITEBACK` | XArray tag | set on I/O submit; cleared on completion |
| `PAGECACHE_TAG_TOWRITE` | XArray tag | marks pages for current writeback pass |
| `mapping->gfp_mask` | address_space field | GFP flags used when allocating new cache pages |

## Interactions with Other Subsystems

- **↑ Userspace**: `read(2)`, `write(2)`, `mmap(2)`, `fsync(2)`, and `fallocate(2)` all funnel through address space operations.
- **→ [[Page Cache]]**: `address_space` *is* the page cache for its owner — the XArray (`i_pages`) is the cache store; all lookup, insert, and eviction operates on it.
- **→ [[Page Reclaim]]**: reclaim calls `try_to_unmap()` (uses `i_mmap` rmap tree) and then `a_ops->release_folio()` / removes the folio from `i_pages` to free it.
- **→ [[VFS]]**: each VFS inode embeds one `address_space` as `i_data`; the VFS file operations (`read_iter`, `write_iter`, `mmap`) delegate to `filemap_read()`, `generic_perform_write()`, and `filemap_fault()` for normal files.
- **→ [[Block Layer]]**: `read_folio` and `writepages` ultimately submit BIOs to the block layer; the `get_block_t` callback (or iomap) translates file offsets to device sectors.
- **← [[Writeback]]**: the writeback worker threads call `a_ops->writepages()` periodically and on explicit sync; `wb_err` channels error notification back to userspace.
- **← [[Memory Compaction]] / [[Transparent Huge Pages]]**: migration and THP collapse call `a_ops->migrate_folio()` to move private data alongside the page.

## Design Decisions & Tradeoffs

**Unified interface for all cached objects**: Using a single `address_space` + `a_ops` vtable for files, block devices, swap, and anonymous memory means all VM code (reclaim, compaction, writeback) is written once against this interface. The cost is that `a_ops` has grown to ~20 callbacks, many of which most filesystems never implement, leaving the table sparse.

**XArray over radix tree (4.20)**: The radix tree required callers to manage the tree lock manually and handle multiorder entries awkwardly. XArray provides a cleaner API with integrated locking, RCU-safe lockless lookup, and first-class multi-order support needed for THP and large folios. The migration was transparent to users of `find_get_page()` and `add_to_page_cache_lru()`.

**errseq for write error delivery**: Before errseq, write errors set a per-inode flag that was cleared on the first `fsync()` — so a second fd that had also written dirty data might never see the error. The `errseq_t` + per-fd cursor model ensures every file description that was open during a write error observes it independently. This was driven by POSIX requirements and real complaints from database systems.

**invalidate_lock instead of i_rwsem**: Originally, truncation was serialised against reads using `i_rwsem`. Replacing it with a dedicated `invalidate_lock` allows concurrent reads while still serialising against hole-punch and truncate, reducing contention on heavily-read files.

**i_mmap as interval tree**: Reverse mapping for file pages requires finding all VMAs that overlap a given page. An interval tree (sorted by `vm_pgoff` + length) supports this in O(log n + k) rather than O(n) over all VMAs, which matters for files mapped by hundreds of processes (shared libraries, databases).

## How It Has Evolved

- **2.4**: `address_space` introduced alongside the page cache; `page_tree` was a radix tree; `a_ops` had basic `readpage`/`writepage`.
- **2.6.10** (2004): `writeback_control` struct introduced; writeback direction and deadline made explicit.
- **4.17** (2018): `errseq_t` write-error sequencing added, replacing per-inode sticky flags.
- **4.20** (2018–2019): Radix tree replaced by XArray (`i_pages`); lockless lookup via RCU generalised.
- **5.2** (2019): `invalidate_lock` separated from `i_rwsem` for finer-grained invalidation serialisation.
- **5.16** (2022): `struct folio` begins replacing `struct page` throughout `a_ops`; `read_folio` replaces `readpage`, `dirty_folio` replaces `set_page_dirty`.
- **6.0+** (ongoing): Large folio (multi-page compound folio) support extended through `a_ops`; `readahead` upgraded to handle order > 0 folios; `migrate_folio` handles compound folios for THP migration.

## Further Reading

1. [The Address Space Object — kernel.org VFS docs](https://www.kernel.org/doc/html/latest/filesystems/vfs.html)
2. [Locking rules for address_space_operations — kernel.org](https://docs.kernel.org/filesystems/locking.html)
3. [Memory Management APIs — kernel.org](https://www.kernel.org/doc/html/latest/core-api/mm-api.html)
4. [page->mapping clarification — LWN.net](https://lwn.net/Articles/250461/)
5. [The page cache and page writeback — CS Notes (Eddy Erburgh)](https://notes.eddyerburgh.me/operating-systems/linux/the-page-cache-and-page-writeback)

## LKML Highlights

- **XArray introduction** — `20170802003021.11397-1-willy@infradead.org` (Matthew Wilcox, 2017): The XArray RFC; debate focused on whether replacing a well-understood radix tree with a new abstraction was justified; reviewers asked for benchmarks showing reduced lock contention in the page cache lookup fast path.
- **invalidate_lock separation** — `20200903100016.1286-1-jack@suse.cz` (Jan Kara, 2020): Moving from i_rwsem to a dedicated invalidate_lock; the thread revealed that several filesystems had subtle races between concurrent reads and hole-punch operations because i_rwsem was not always held in the right mode.
- **errseq write-error** — `20170704185909.1799-1-jlayton@kernel.org` (Jeff Layton, 2017): The errseq patch series; long discussion about POSIX compliance and whether databases were genuinely affected by the lost-error problem with the old sticky-bit approach.
