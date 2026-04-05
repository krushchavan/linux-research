---
title: "Memory Compaction"
category: concept
tags: [mm, compaction, fragmentation, huge-pages, migration, kcompactd]
subsystem: mm
kernel_version: "2.6.35"
researched: 2026-04-05
status: complete
sources:
  - https://lwn.net/Articles/368869/
  - https://lwn.net/Articles/817905/
  - https://www.pingcap.com/blog/linux-kernel-vs-memory-fragmentation-2/
  - https://www.pingcap.com/blog/linux-kernel-vs-memory-fragmentation-1/
---

# Memory Compaction

## Purpose

As a Linux system runs, free pages become scattered throughout physical memory — pages allocated and freed at different times leave gaps of varying sizes. This **external fragmentation** means that even when total free memory is ample, a request for a contiguous 2 MiB block (for a transparent huge page or a DMA buffer) may fail. Memory compaction solves this by **migrating movable pages** from lower in a zone toward higher addresses, consolidating free pages into large contiguous runs at the zone's base where higher-order allocations can be satisfied.

## Mental Model

Imagine a bookshelf where books (allocated pages) and empty slots (free pages) are interleaved randomly. Compaction is like sliding all the books to one end, leaving a continuous empty stretch at the other end. The kernel uses two pointers — one scanning from the bottom looking for movable books, one scanning from the top looking for empty slots — and swaps books into the empty slots until the two pointers meet in the middle.

## How It Works

### Migration types — the foundation of compactability

Pages in the buddy allocator are grouped by **migration type** within `pageblock_nr_pages`-sized blocks (typically 512 pages = 2 MiB on 4 KiB pages):

| Migration type | Meaning | Examples |
|---|---|---|
| `MIGRATE_UNMOVABLE` | Cannot be migrated or reclaimed | Kernel code/data, kmalloc with `GFP_KERNEL` (most) |
| `MIGRATE_MOVABLE` | Can be relocated by updating page table mappings | Anonymous pages, file-backed pages with `migration_entry` support |
| `MIGRATE_RECLAIMABLE` | Can be freed and re-read from backing store | Page cache, slab caches with `SLAB_RECLAIM_ACCOUNT` |
| `MIGRATE_CMA` | Contiguous Memory Allocator reserved range | DMA-contiguous allocations |

The key invariant: unmovable allocations should come from unmovable pageblocks, keeping movable pageblocks free for compaction. `get_page_from_freelist()` enforces this by trying to allocate from a matching migration-type block.

### The two-scanner algorithm in `compact_zone()`

`compact_zone()` (`mm/compaction.c`) operates within a single zone and runs two cursors:

**Migration scanner** (bottom → top): starts at `cc->migrate_pfn` (initially the zone start, cached across runs) and scans `pageblock_nr_pages`-sized blocks. For each block whose migration type is `MIGRATE_MOVABLE` or `MIGRATE_CMA`, it calls `isolate_migratepages_block()` to lock and remove pages from their LRU lists onto a local `migratepages` list.

**Free scanner** (top → bottom): starts at `cc->free_pfn` (initially the zone end) and scans blocks for free pages. `isolate_freepages_block()` removes free pages from the buddy allocator into a `freepages` list. These become the migration targets.

Once the free scanner has accumulated enough pages to cover the migration scanner's batch, `migrate_pages()` is called:
1. For each page on `migratepages`, call the page's `migratepage()` callback (or `move_to_new_page()` for generic pages).
2. Copy the page's content to the target free page.
3. Update all page table entries that point to the old page to point to the new page via `remove_migration_ptes()` (using reverse mapping).
4. Free the old page back to the buddy allocator at its original location (which is now in the compacted region).

The two scanners advance until they meet. When `cc->migrate_pfn >= cc->free_pfn`, the zone is compacted as much as possible.

### Fragmentation index

Before triggering compaction, the allocator computes a **fragmentation index** for the requested order:

```
fragindex = 1000 - (free_pages * 1000 / (free_blocks_suitable * 2^order))
```

A fragindex near 1000 means fragmentation is the bottleneck (plenty of free pages, few large blocks). A fragindex near 0 means there genuinely isn't enough free memory. Compaction is only useful when fragindex is high — triggering it when memory is simply scarce wastes CPU.

### Trigger paths

**Reactive compaction** (on-demand): triggered by `__alloc_pages_slowpath()` when a higher-order allocation fails. The allocator calls `try_to_compact_pages()` before resorting to OOM. This is synchronous and runs in the allocation context.

**kcompactd** (background): each NUMA node has a `kcompactd/N` kernel thread (woken by `wakeup_kcompactd()`). It runs after each allocation failure that would have benefited from compaction, doing enough work to allow a single allocation of the needed order.

**Proactive compaction** (5.9+): `kcompactd` now also runs proactively based on a **fragmentation score** — a node-level measure (0–100) of external fragmentation across all orders. Controlled by `vm.compaction_proactiveness` (default 20). When the score exceeds the proactiveness threshold, `kcompactd` continuously compacts until the score falls below `proactiveness/2`. This amortises compaction cost across idle periods, reducing huge-page allocation latency by 70–80× in benchmarks.

**Manual** (`/proc/sys/vm/compact_memory`): writing any value triggers a full compaction of all zones on all NUMA nodes.

### Page migration mechanics

The actual page copy in `migrate_pages()` handles special cases:

- **Anonymous pages**: content is copied; all PTEs pointing to the old page are updated atomically using the rmap (reverse map).
- **File-backed pages**: the page cache's `xa_lock` is held while the page pointer in the XArray is swapped to the new page; any mapped PTEs are updated.
- **Huge pages**: compound pages migrate atomically as a unit; all sub-page PTEs are updated together.
- **Non-migratable pages**: if a page cannot be migrated (e.g. it has a pin from `get_user_pages_fast()`), it is put back on the LRU and the scanner advances past its block.

### Interaction with THP

Transparent huge pages ([[transparent-huge-pages]]) rely heavily on compaction. When `khugepaged` wants to collapse a 2 MiB region into a huge page, it calls `compact_zone_order()` first if the region isn't already physically contiguous. Without compaction, THP promotion rates on long-running systems drop dramatically because small allocations fragment memory over time.

## Key Data Structures

**`compact_control`** (`mm/compaction.c`) — per-compaction-run control state.
- `migrate_pfn` / `free_pfn` — current scanner positions; cached between partial runs
- `migratepages` / `freepages` — lists of isolated pages
- `order` — the target allocation order driving this compaction (or `-1` for full-zone)
- `mode` — `MIGRATE_SYNC`, `MIGRATE_ASYNC`, or `MIGRATE_SYNC_LIGHT`

**`zone.compact_cached_migrate_pfn` / `compact_cached_free_pfn`** — per-zone cached scanner positions; avoids re-scanning already-compacted regions on the next run.

**`zone.compact_considered` / `compact_defer_shift`** — compaction deferral state: if compaction succeeded last time but the allocation still failed (genuinely low memory), compaction is exponentially deferred to avoid wasting CPU.

## Key Functions / Entry Points

**`compact_zone(zone, cc)`** (`mm/compaction.c`) — the core algorithm; drives both scanners, calls `migrate_pages()`.

**`try_to_compact_pages(gfp_mask, order, alloc_flags, ac)`** (`mm/compaction.c`) — called from `__alloc_pages_slowpath()`; iterates zones and calls `compact_zone()`.

**`kcompactd()`** (`mm/compaction.c`) — background thread; woken on allocation failure, runs proactive compaction loop.

**`isolate_migratepages_block()`** / **`isolate_freepages_block()`** — scanner helpers that lock pages and pull them off LRU / buddy lists.

**`migrate_pages(from, get_new_page, put_new_page, ...)`** (`mm/migrate.c`) — generic page migration engine used by compaction, NUMA balancing, and CMA.

## Important Flags & Config Options

| Sysctl / Config | Default | Effect |
|---|---|---|
| `vm.compaction_proactiveness` | 20 | Proactive compaction aggressiveness (0 = off, 100 = max) |
| `vm.compact_memory` | write-only | Trigger manual full compaction |
| `vm.extfrag_threshold` | 500 | Fragmentation index threshold for triggering compaction |
| `CONFIG_COMPACTION` | y | Enables memory compaction; required for THP |
| `CONFIG_MIGRATION` | y | Enables page migration (prerequisite for compaction) |

## Interactions with Other Subsystems

- **→ [[transparent-huge-pages]]**: compaction is the primary mechanism for creating contiguous 2 MiB regions that `khugepaged` needs.
- **→ Buddy allocator**: compaction returns isolated pages to the buddy at new locations; after compaction the buddy has larger contiguous free blocks.
- **→ Rmap (reverse mapping)**: `migrate_pages()` uses the rmap to find all PTEs pointing to a migrating page and update them atomically.
- **→ CMA (Contiguous Memory Allocator)**: CMA uses migration to evacuate `MIGRATE_MOVABLE` pages from reserved CMA regions when a DMA contiguous allocation is needed.
- **← [[page-reclaim]]**: compaction and reclaim are complementary; `__alloc_pages_slowpath()` may try both in sequence. Reclaim reduces total pages under memory pressure; compaction consolidates remaining free pages.

## Design Decisions & Tradeoffs

**Two-scanner design**: scanning from both ends simultaneously minimises the distance pages must travel — pages from near the bottom move to free slots near the top. An alternative (single pass) would require moving pages much further, increasing copy cost.

**Migration type grouping**: isolating movable and unmovable allocations into separate pageblocks is the key invariant that makes compaction tractable. Without it, every pageblock would contain at least one unmovable page, and compaction would make no progress.

**Asynchronous vs synchronous mode**: allocation-triggered compaction can run `MIGRATE_ASYNC` (skips locked pages) for low latency or `MIGRATE_SYNC` (waits for locks) for thoroughness. kcompactd uses async to avoid blocking other processes; direct reclaim contexts may use sync when allocation is critical.

**Compaction deferral**: if compaction succeeds but the allocation still fails (low memory, not fragmentation), compaction is deferred exponentially to avoid burning CPU on a problem it can't solve.

## How It Has Evolved

- **2.6.35 (2010)**: Initial memory compaction merged (Mel Gorman's patch series).
- **3.6 (2012)**: kcompactd background thread introduced.
- **3.10 (2013)**: Compaction scanner position caching (avoids re-scanning).
- **4.6 (2016)**: Compaction deferral improved.
- **5.9 (2020)**: Proactive compaction (`compaction_proactiveness`) merged.

## Further Reading

1. **LWN — "Memory compaction"** (2010): https://lwn.net/Articles/368869/ — Original design and two-scanner algorithm.
2. **LWN — "Proactive compaction for the kernel"** (2021): https://lwn.net/Articles/817905/ — Proactive mode design and benchmarks.
3. **PingCAP — "Linux Kernel vs. Memory Fragmentation (Part I & II)"**: https://www.pingcap.com/blog/linux-kernel-vs-memory-fragmentation-1/ — Deep-dive with migration type internals.
