---
title: "Buddy Allocator"
category: concept
tags: [memory, mm, physical-memory, allocation, fragmentation]
subsystem: mm
kernel_version: "1.0+"
researched: 2026-04-05
status: complete
sources:
  - https://kernel-internals.org/mm/page-allocator/
  - https://kernel-internals.org/mm/numa/
  - https://static.lwn.net/kerneldoc/core-api/memory-allocation.html
---

# Buddy Allocator

## Purpose

The buddy allocator is Linux's physical page bookkeeper. It owns all of RAM and answers one question: "give me N contiguous physical pages." Without it, there would be no authoritative record of which pages are free, no way to satisfy requests for physically-contiguous memory (required for DMA), and no mechanism to recombine freed pages into larger blocks. Every other mm allocator — SLUB, vmalloc, the page cache — ultimately draws from the buddy allocator.

## Mental Model

Imagine a fleet of parking lots laid out in a strict hierarchy: one lot of 1024 spaces, two of 512, four of 256, … down to 1024 individual spaces. When you need exactly 16 spaces, the attendant finds the smallest available lot that fits (or splits a larger one in half repeatedly until it does), hands you the keys, and notes the lot as occupied. When you leave, the attendant checks whether the *adjacent* lot of the same size is also free — if so, they merge the two into a larger lot. This recursive merging is the "buddy" relationship: two blocks are buddies if they were split from the same parent.

The key insight is that the buddy's address can be computed with a single XOR — no searching required — making merge decisions O(1).

## How It Works

Physical memory is divided into **zones** (DMA, DMA32, NORMAL, MOVABLE), and within each zone into **orders** 0–`MAX_PAGE_ORDER` (typically 10). Order 0 is a single 4 KB page; order 10 is 1024 pages (4 MB). Each order maintains a free list of available blocks.

**Allocation:** find the free list at the requested order. If it has a block, remove it and return it. If not, look at the next higher order, split that block into two buddies, put one on the lower-order free list, and return the other. Repeat upward until a block is found or all orders are exhausted.

**Free:** add the freed block back to its order's free list. Then check whether its buddy is also free (the buddy's address = freed_addr XOR (1 << order << PAGE_SHIFT)). If so, remove both from the free list, merge into a higher-order block, and repeat — walking upward until either the buddy is occupied or the maximum order is reached.

**Migration types** add a second dimension to each free list. At every order, there are separate lists for UNMOVABLE (kernel allocations), MOVABLE (user pages, compactable), RECLAIMABLE (page cache), HIGHATOMIC (reserved for atomic/interrupt allocations), CMA, and ISOLATE (pages being migrated). This grouping prevents a single immovable page from permanently fragmenting a region — movable pages can always be relocated by compaction to expose a contiguous free block.

**Watermarks** control when the allocator yields to reclaim: allocations below the `low` watermark wake kswapd; below `min` they enter direct reclaim. The HIGHATOMIC migration type draws from reserved pages below the min watermark to guarantee `GFP_ATOMIC` allocations can always succeed.

## Key Data Structures

**`struct zone`** (`include/linux/mmzone.h`) — one zone within one NUMA node.
- `free_area[MAX_PAGE_ORDER+1]` — per-order free lists, each split by migratetype
- `_watermark[NR_WMARK]` — min/low/high/promo thresholds in pages
- `pageset` — per-CPU page cache (PCP) for this zone
- `zone_pgdat` — pointer back to the owning `pglist_data` node
- `managed_pages` — total pages under buddy management in this zone

**`struct free_area`** (`include/linux/mmzone.h`) — one order level within a zone.
- `free_list[MIGRATE_TYPES]` — one linked list per migration type at this order
- `nr_free` — total free blocks at this order (across all migratetypes)

**`struct page`** / **`struct folio`** (`include/linux/mm_types.h`) — buddy uses the page's `lru` list linkage to chain free blocks, and `private` to store the order of a free compound page.

## Key Functions / Entry Points

**`__alloc_pages(gfp, order, preferred_nid, nodemask)`** (`mm/page_alloc.c`) — the single top-level allocator entry point; called by everything from `kmalloc` to `vmalloc` to `do_anonymous_page`. First tries `get_page_from_freelist()` (fast path); on failure invokes `__alloc_pages_slowpath()`.

**`get_page_from_freelist()`** (`mm/page_alloc.c`) — walks the zonelist checking watermarks; calls `rmqueue()` on the first zone that passes.

**`rmqueue()`** (`mm/page_alloc.c`) — the actual dequeue: tries PCP for order 0–3, otherwise `__rmqueue()` on the free lists; does migratetype fallback stealing if the preferred type's list is empty.

**`__rmqueue_smallest()`** (`mm/page_alloc.c`) — inner loop: searches free lists from requested order upward, splits blocks, and returns the page.

**`__free_pages(page, order)`** (`mm/page_alloc.c`) — free entry point; order-0 pages go to PCP, higher orders go directly to `__free_one_page()`.

**`__free_one_page()`** (`mm/page_alloc.c`) — the merge loop: finds the buddy, merges if free, repeats upward.

**`__alloc_pages_slowpath()`** (`mm/page_alloc.c`) — invoked when fast path fails; wakes kswapd, tries compaction, optionally enters direct reclaim, and finally calls `out_of_memory()`.

## Important Flags & Config Options

| Flag / Symbol | Effect |
|---------------|--------|
| `GFP_KERNEL` | Can sleep; triggers reclaim if needed; most common kernel allocation |
| `GFP_ATOMIC` | Cannot sleep; draws from HIGHATOMIC reserves; must always succeed |
| `GFP_DMA` / `GFP_DMA32` | Restrict allocation to DMA-accessible zones |
| `__GFP_ZERO` | Zero-fill the pages before returning |
| `__GFP_NOFAIL` | Retry indefinitely; never return NULL |
| `__GFP_RETRY_MAYFAIL` | Retry once after reclaim; give up if still failing (good for high-order) |
| `__GFP_MOVABLE` | Use MOVABLE migratetype; allows compaction to reclaim the page later |
| `CONFIG_COMPACTION` | Enable memory compaction via kcompactd and direct compaction |
| `CONFIG_CMA` | Reserve CMA regions for device contiguous-memory requests |
| `vm.min_free_kbytes` | Sets the min watermark; raising it increases the free-page buffer |
| `vm.compaction_proactiveness` | 0–100; controls proactive compaction rate by kcompactd |
| `/proc/sys/vm/compact_memory` | Write 1 to trigger a full system-wide compaction immediately |

## Interactions with Other Subsystems

- **↑ Userspace**: processes never call the buddy allocator directly; they reach it via page faults or `mmap()` through the VMA and fault handler layers.
- **← SLUB**: calls `alloc_pages()` to obtain a new slab page when the per-CPU cache and partial lists are exhausted.
- **← vmalloc**: calls `alloc_pages()` once per page in a vmalloc mapping; pages need not be physically contiguous.
- **← Page fault handler**: `do_anonymous_page()` calls `alloc_zeroed_user_highpage_movable()` → `alloc_pages()` for each first-write fault.
- **← Page cache**: `pagecache_get_page()` / `__page_cache_alloc()` calls `alloc_pages()` when a cache miss requires a new folio.
- **→ Page reclaim**: when free pages fall below watermarks, the allocator wakes kswapd and enters direct reclaim via `try_to_free_pages()`.
- **→ Compaction**: the slow path calls `try_to_compact_pages()` to defragment zones before declaring OOM.
- **↓ Hardware**: the allocator works in terms of PFNs (physical frame numbers) and relies on architecture-specific code to translate between PFNs and virtual addresses.

## Design Decisions & Tradeoffs

**Power-of-two block sizes.** This enables O(1) buddy identification via XOR and O(log n) coalescing, at the cost of internal fragmentation (worst case: a 3-page request wastes 25% of an order-2 block). The alternative — arbitrary-size free lists — eliminates internal fragmentation but requires O(n) search and makes the merge decision non-trivial. The Linux kernel consistently chooses bounded, predictable latency over optimal utilisation.

**Migration types over a single free list.** A single free list per order allows any free page to satisfy any request, but a single immovable page in the wrong position can permanently block large allocations. Migration types are a controlled form of segregation: they accept some waste (occasional cross-type stealing) in exchange for compactability.

**No reference counting in the buddy allocator.** The buddy allocator does not track *who* holds a page — that is the job of `_refcount` in `struct page`. The allocator only tracks free/allocated state. This separation keeps the hot allocation path simple: allocate, return, forget.

## How It Has Evolved

| Version | Change | Driver |
|---------|--------|--------|
| Linux 1.0 | Basic buddy allocator, single zone | Initial implementation |
| v2.5/2.6 (2002) | Per-CPU page lists (PCP) | Zone lock contention on SMP |
| v2.6 (2003) | NUMA awareness, per-node zones, zonelists | Multi-socket server support |
| v2.6.24 (2008) | Migration types added | Compaction prerequisites; THP planning |
| v2.6.35 (2010) | Memory compaction (`kcompactd`) | THP / high-order alloc failures on fragmented systems |
| v3.5 (2012) | CMA integration | Device drivers need large contiguous DMA buffers dynamically |
| v5.13 (2021) | Order increased to support larger THP | 1 GB huge pages and growing device memory needs |
| v6.6 (2023) | PCP high-water auto-tuning | Static batch sizes inefficient on 200+ CPU Sapphire Rapids |

## Further Reading

1. [kernel-internals.org/mm/page-allocator/](https://kernel-internals.org/mm/page-allocator/) — design rationale, migration types, watermarks, and evolution
2. [kernel-internals.org/mm/numa/](https://kernel-internals.org/mm/numa/) — how NUMA topology shapes the zonelist fallback and allocation path
3. [kernel.org — Memory Allocation Guide](https://static.lwn.net/kerneldoc/core-api/memory-allocation.html) — GFP flag reference; when to use which allocator
4. [LWN — Generating physically contiguous memory](https://lwn.net/Articles/779979/) — the difficulty of high-order allocations and compaction approaches
5. [LWN — A deep dive into CMA](https://lwn.net/Articles/486301/) — how CMA reserves interact with buddy migration types

## LKML Highlights

- **[RFC: per-CPU pageblock buddy allocator](https://lore.kernel.org/all/20260403194526.477775-3-hannes@cmpxchg.org/) (Johannes Weiner, Meta, Apr 2026)** — proposes merging the PCP and buddy layers into a per-CPU pageblock allocator, arguing the current boundary between them wastes lock roundtrips; shows how even the most fundamental allocator is still being reconsidered at scale.
