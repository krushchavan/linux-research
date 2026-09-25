---
title: "Page Reclaim"
category: concept
tags: [mm, reclaim, lru, kswapd, mglru, memory-pressure]
subsystem: mm
kernel_version: "2.6+"
researched: 2026-04-05
status: complete
explained: "[[page-reclaim-explained]]"
sources:
  - https://kernel-internals.org/site-index/
  - https://docs.kernel.org/mm/multigen_lru.html
  - https://www.kernel.org/doc/gorman/html/understand/understand013.html
  - https://www.kernel.org/doc/html/v5.19/vm/balance.html
  - https://www.kernel.org/doc/html/latest/admin-guide/mm/concepts.html
  - https://biriukov.dev/docs/page-cache/4-page-cache-eviction-and-page-reclaim/
  - https://lwn.net/Articles/921644/
---

# Page Reclaim

> 📘 Plain-language version: [[page-reclaim-explained]]

## Purpose

Page reclaim is the process by which the kernel frees physical memory pages — held as page cache, anonymous mappings, or kernel slab caches — so they can satisfy new allocation requests. Without it, a system that accumulates page cache faster than it frees it would stall every allocator; with it, the kernel can keep "virtual memory" vastly exceeding physical RAM without the allocator seeing a shortage.

## Mental Model

Think of physical RAM as a hotel with three alarm levels: *low* (start cleaning empty rooms), *very low* (assign a cleaner right now), and *critical* (pull the fire alarm — nothing checks in until rooms are free). kswapd is the background cleaning crew that runs between *low* and *high*; direct reclaim is the guest being forced to wait while a room is hastily vacated; the OOM killer is the fire alarm that evicts the biggest occupant.

## How It Works

### Watermarks and the two paths

Every `struct zone` carries three watermarks — `WMARK_HIGH`, `WMARK_LOW`, and `WMARK_MIN` — set at boot from `vm.min_free_kbytes` and scaled to zone size. The allocator checks them on every call to `zone_watermark_ok()` in `mm/page_alloc.c`.

When `alloc_pages()` succeeds at the fast path, nothing happens. When the fast path fails and free pages in the zone sit below `WMARK_LOW`, the allocator sets `__GFP_KSWAPD_RECLAIM` on the flags and calls `wakeup_kswapd()`. This queues the kswapd thread without blocking — the allocator then enters the slow path and retries with progressively relaxed allocation flags (`ALLOC_HARDER`, `ALLOC_NO_WATERMARKS`, etc.) while kswapd works in parallel.

If free pages have already fallen to `WMARK_MIN`, the slow path calls `try_to_free_pages()` directly on the current process context. This is **direct reclaim**: the allocating thread does reclaim work itself, synchronously, stalling until enough pages are freed. Direct reclaim is expensive — it adds latency to what looked like a routine `kmalloc` — so the watermarks are tuned so kswapd drains enough headroom to make direct reclaim rare.

### kswapd: background reclaim

One kswapd thread runs per NUMA node (`kswapd%d`). It sleeps in `kswapd()` (`mm/vmscan.c`), woken by `wakeup_kswapd()`. On wakeup it calls `balance_pgdat()`, which iterates the node's zones from the highest to the lowest and, for each zone below `WMARK_HIGH`, calls `kswapd_shrink_node()` → `shrink_node()` → `shrink_lruvec()`. The loop continues until all zones are above `WMARK_HIGH` or until a configurable number of passes has been tried, at which point kswapd goes back to sleep.

Because kswapd does not block the allocating process, it is considered *asynchronous reclaim*. It runs at a normal kernel thread priority and can be delayed by competing work, which is why the watermark gap between `WMARK_LOW` and `WMARK_MIN` must be large enough to absorb allocation bursts before direct reclaim kicks in.

### LRU lists and the classic two-list algorithm

The traditional reclaim engine tracks all reclaimable pages in four per-`lruvec` LRU lists (stored in `struct lruvec`, in `mm/vmscan.c`):

- `LRU_INACTIVE_ANON` — anonymous pages not recently used
- `LRU_ACTIVE_ANON` — anonymous pages recently accessed
- `LRU_INACTIVE_FILE` — file-backed pages not recently used
- `LRU_ACTIVE_FILE` — file-backed pages recently accessed

A fifth list, `LRU_UNEVICTABLE`, holds pages locked in memory (e.g. `mlock`'d).

Pages enter the inactive list when first faulted in. If they are accessed a second time while still inactive, the `PG_referenced` flag is set; if they are accessed *again* (or were referenced when scanned), they are promoted to the active list via `folio_activate()`. If a page sits at the tail of the inactive list and is scanned without `PG_referenced` being set, it is a reclaim candidate.

`shrink_lruvec()` calls `get_scan_count()` to decide how many pages to scan from each of the four lists, balancing anonymous versus file reclaim according to `vm.swappiness` (default 60: moderate preference for reclaiming file cache before swapping anonymous pages). Then it isolates pages from LRU into a local list and hands the list to `shrink_folio_list()`, which applies per-page logic:

- **Clean file-backed page**: unmap, remove from page cache, free immediately.
- **Dirty file-backed page**: call `folio_set_writeback()` and hand to the flusher thread; if `PG_writeback` was already set (page already being written), check congestion and potentially throttle.
- **Anonymous page**: add to swap cache, write to swap device, then unmap and free the now-swapped page.
- **Page with pending references** (`folio_referenced()` returns true): rotate back onto the active list rather than reclaiming.

After `shrink_folio_list()` returns, pages not freed are put back on the LRU, freed pages are returned to the buddy allocator via `free_unref_page_list()`.

### Workingset detection and refault distance

Evicting a page that is immediately needed again (a *refault*) is costly: it wakes up a disk I/O, stalls a process, and defeats the purpose of reclaim. To avoid this, the kernel stores a **shadow entry** in the address space's xarray at the slot a page occupied when it was evicted. The shadow encodes the `lruvec`'s eviction counter at eviction time.

When the page faults back in, the kernel looks up the shadow, computes the **refault distance** = (current eviction counter) − (recorded eviction counter), and compares it to the current active list size. If the distance is smaller — meaning the working set would have fit if the page had been kept — the page is immediately activated (placed on the active list) rather than the inactive list. This prevents thrashing: once the kernel observes a short refault distance, pages that belong together get protected together.

### Shrinkers: reclaiming slab caches

Not all kernel memory is mapped via LRU lists. Dentries, inodes, and other slab objects are tracked by the **shrinker** framework. Subsystems call `register_shrinker()` at init time, providing a `count_objects` callback (how much can be freed?) and a `scan_objects` callback (free up to N objects). Under memory pressure, `shrink_slab()` iterates all registered shrinkers and invokes them in order of most-objects-to-free first. The VFS registers `super_cache_shrink()` for dentries and inodes; network subsystems register socket buffer pools; the slab allocator registers per-cache shrinkers for SLAB_RECLAIM_ACCOUNT caches.

### MGLRU: the multi-generational LRU (Linux 6.1+)

The classic two-list LRU has a fundamental problem: it only distinguishes *active* from *inactive*. A page that was hot six minutes ago looks the same as one that was hot six seconds ago — both sit at the head of the active list. Under memory pressure the kernel must scan the entire active list to find cold pages, burning CPU proportional to active list size.

**Multi-Gen LRU (MGLRU)**, merged in Linux 6.1, replaces the four LRU lists with a small array of generations. Each `lruvec` contains a `struct lru_gen_folio` that holds:

```c
struct lru_gen_folio {
    unsigned long max_seq;           /* youngest generation */
    unsigned long min_seq[ANON_AND_FILE]; /* oldest gen per type */
    struct list_head folios[MAX_NR_GENS][ANON_AND_FILE][MAX_NR_ZONES];
    long nr_pages[MAX_NR_GENS][ANON_AND_FILE][MAX_NR_ZONES];
    /* bloom filters, refault statistics ... */
};
```

Each folio's generation number is packed into `folio->flags`. There are typically 4 generations (`MAX_NR_GENS`). The two halves of the design are:

**Aging** — finds and promotes hot pages. When `max_seq - min_seq` approaches `MIN_NR_GENS` (i.e. the generation window is about to collapse), the aging path increments `max_seq` and walks all process page tables (`walk_page_range()`) looking for young PTEs. Any folio whose PTE was accessed since the last walk gets moved to the current `max_seq` generation. Bloom filters on PMD addresses avoid re-scanning the same regions twice. This is far cheaper than the classic LRU: instead of taking the LRU lock on every `folio_mark_accessed()`, PTE bits are checked in bulk during aging passes.

**Eviction** — consumes old generations. The eviction path picks the oldest generation (`min_seq`) of whichever type (anon/file) should be evicted next (governed by swappiness and refault rates), isolates its folios, and runs them through `shrink_folio_list()` exactly as in the classic path. When a generation's list drains completely, `min_seq` is incremented.

MGLRU also introduces a **PID controller** that uses per-generation refault rates to continuously adjust the split between anon and file eviction, replacing the fixed-threshold `get_scan_count()` heuristic.

Measured results: ~40% reduction in kswapd CPU usage, 85% fewer low-memory kills on Android, 18% reduction in rendering latency.

## Key Data Structures

**`struct scan_control`** (`mm/vmscan.c`) — passed through the entire reclaim call stack, carries reclaim parameters and accounting:
- `nr_to_reclaim` — target page count for this reclaim call
- `priority` — current reclaim aggressiveness (6 = scan 1/64, 0 = scan all)
- `may_swap` — whether anonymous pages may be swapped out
- `gfp_mask` — GFP flags of the triggering allocation
- `reclaimed` — pages actually freed so far

**`struct lruvec`** (`include/linux/mmzone.h`) — per-memcg per-node LRU state; contains the five `struct list_head lru[]` arrays (classic) and the embedded `struct lru_gen_folio` (MGLRU), plus per-list page counts and zone statistics.

**`struct lru_gen_folio`** (`include/linux/mm_types.h`) — MGLRU core; holds the `folios[][]` generation arrays, `max_seq`/`min_seq`, bloom filters, and refault statistics.

**`struct shrinker`** (`include/linux/shrinker.h`) — interface for slab cache reclaim; fields `count_objects` and `scan_objects` are function pointers; `seeks` weights the shrinker's priority.

## Key Functions / Entry Points

**`try_to_free_pages()`** (`mm/vmscan.c`) — direct reclaim entry point; called from the allocator slow path; wraps `do_try_to_free_pages()` which iterates priorities 12→0 calling `shrink_zones()`.

**`kswapd()`** (`mm/vmscan.c`) — background reclaim thread body; sleeps on `pgdat->kswapd_wait`, wakes on `wakeup_kswapd()`, calls `balance_pgdat()`.

**`balance_pgdat()`** (`mm/vmscan.c`) — top-level node reclaim; iterates zones, adjusts reclaim order, calls `kswapd_shrink_node()` until watermarks are satisfied.

**`shrink_lruvec()`** (`mm/vmscan.c`) — reclaims pages from one `lruvec`; calls `get_scan_count()` to size scans, then `shrink_list()` for each LRU.

**`shrink_folio_list()`** (`mm/vmscan.c`) — per-folio reclaim decisions; returns counts of reclaimed, rotated, and congested pages; dispatches dirty pages to writeback.

**`get_scan_count()`** (`mm/vmscan.c`) — decides the anon/file split using swappiness, refault data, and current LRU sizes.

**`wakeup_kswapd()`** (`mm/vmscan.c`) — non-blocking kswapd wake; called from the allocator fast-path failure with `__GFP_KSWAPD_RECLAIM`.

**`shrink_slab()`** (`mm/vmscan.c`) — iterates registered shrinkers and calls their `scan_objects` under memory pressure.

**`lru_gen_age_node()`** (`mm/vmscan.c`) — MGLRU aging pass; walks page tables, updates generation numbers, increments `max_seq`.

## Important Flags & Config Options

| Knob | Location | Effect |
|------|----------|--------|
| `vm.swappiness` | sysctl | 0–200; controls anon vs file reclaim bias; default 60 |
| `vm.min_free_kbytes` | sysctl | sets WMARK_MIN; increase for latency-sensitive workloads |
| `vm.watermark_scale_factor` | sysctl | gap between WMARK_MIN and WMARK_HIGH; default 10 (= 0.1%) |
| `vm.watermark_boost_factor` | sysctl | temporary WMARK_HIGH boost after large-page fragmentation |
| `CONFIG_LRU_GEN` | Kconfig | enables MGLRU (default on since 6.1) |
| `CONFIG_LRU_GEN_ENABLED` | Kconfig | MGLRU on by default (can still be disabled at boot) |
| `vm.lru_gen_min_ttl` | sysctl | MGLRU working-set protection window in ms (default 0) |
| `/sys/kernel/mm/lru_gen/enabled` | sysfs | runtime enable/disable of MGLRU and its sub-features |
| `GFP_NOWAIT` / `~__GFP_DIRECT_RECLAIM` | GFP flags | allocation may wake kswapd but will not block for reclaim |
| `__GFP_NORETRY` | GFP flag | don't retry after reclaim; accept failure |

## Interactions with Other Subsystems

- **↑ Userspace**: `mmap`, `malloc`, and read/write calls all funnel through `alloc_pages()`; `madvise(MADV_FREE)` and `madvise(MADV_DONTNEED)` hint pages as cheap to reclaim; `/proc/meminfo` and `/proc/vmstat` expose reclaim counters.
- **→ [[Block Layer]]**: dirty page writeback during reclaim issues I/O via the flusher threads (`wb_writeback_work`) and the block layer's request queue; reclaim throttles itself when the block device is congested.
- **→ [[Swap]]**: anonymous pages evicted by reclaim are moved to the [[Swap]] subsystem (written to swap space, tracked in `swapper_space`).
- **→ [[Page Cache]]**: file-backed reclaim unlinks folios from the [[Page Cache]] xarray; shadow entries are left in place for refault tracking.
- **→ [[VFS]] / Slab**: the shrinker path calls into VFS `super_cache_shrink()` to release dentries and inodes held in slab caches.
- **← [[Buddy Allocator]]**: freed pages are returned to the buddy allocator free lists; the buddy allocator is what triggers kswapd wakeups and direct reclaim when watermarks are breached.
- **← [[Memory Cgroups (memcg)]]**: cgroup v2 memory limits trigger per-cgroup reclaim through the same `shrink_lruvec()` path; each cgroup has its own `lruvec`.

## Design Decisions & Tradeoffs

**Two-list LRU over strict LRU**: A true LRU requires touching every page on every access to maintain order — O(1) with a hash but expensive in cache pressure. The two-list (active/inactive) approximation amortizes ordering costs: most accesses only set a flag; only promotion crosses a list boundary. This is essentially a 2Q approximation and performs well in practice despite being theoretically impure.

**kswapd vs. pure direct reclaim**: Early kernels did only direct reclaim; kswapd was introduced to push reclaim off the hot path and avoid stalling interactive tasks. The tradeoff: background reclaim consumes CPU regardless of demand; on very RAM-constrained systems kswapd can become a runaway loop ("kswapd eating 100% CPU" — the classic OOM-adjacent symptom).

**Zone reclaim to node reclaim (4.8)**: Before 4.8, reclaim was per-zone, which caused NUMA systems to swap unnecessarily when lower zones were full but upper zones had free memory. Moving to per-node reclaim (`shrink_node()` instead of per-zone functions) fixed cross-zone thrashing at the cost of some implementation complexity.

**vm.swappiness = 0 does not mean no swap**: Since 3.5, swappiness=0 means "avoid swap unless absolutely necessary," not "never swap." The `get_scan_count()` function uses it as a weight, not a hard gate. swappiness=200 inverts the preference (prefer swapping anonymous over evicting file cache).

**MGLRU over classic LRU**: The classic LRU's `refill_inactive()` had to scan the entire active list to demote cold pages — O(active list size) per reclaim cycle. MGLRU's aging pass is an incremental PTE walk that completes in bounded time regardless of active list size. The cost is more complex data structures and per-generation accounting overhead, which is negligible compared to the scan savings under heavy workloads.

## How It Has Evolved

- **2.4**: Single global active/inactive LRU list; `kswapd` introduced for background reclaim.
- **2.6.0**: Per-zone LRU lists; pagevec batching for reduced spinlock contention; `zone→pressure` decaying average replaces simple priority.
- **2.6.28** (2008): Workingset detection shadow entries added for refault-distance-based activation protection.
- **4.8** (2016): LRU reclaim moved from per-zone to per-node (`shrink_node()`), fixing NUMA cross-zone thrashing.
- **5.9** (2020): `folio` type begins replacing `struct page` in reclaim code; compound pages handled uniformly.
- **5.15** (2021): Reclaim throttling via `reclaim_throttle()` replaces `congestion_wait()`, which was removed as it was unreliable with modern block drivers.
- **6.1** (2022): MGLRU merged as the default LRU implementation, replacing the classic two-list algorithm for most configurations.
- **6.8** (2024): `PG_dropbehind` flag added to allow sequential-I/O pages to be freed immediately after writeback without LRU scanning.

## Further Reading

1. [Multi-Gen LRU — kernel.org docs](https://docs.kernel.org/mm/multigen_lru.html)
2. [Invoking kswapd — LWN.net](https://lwn.net/Articles/921644/)
3. [Proactively reclaiming idle memory — LWN.net](https://lwn.net/Articles/787611/)
4. [Reduce system disruption due to kswapd — LWN.net](https://lwn.net/Articles/543220/)
5. [Memory balancing — kernel.org docs](https://www.kernel.org/doc/html/v5.19/vm/balance.html)
6. [Page Cache eviction and reclaim — Viacheslav Biriukov](https://biriukov.dev/docs/page-cache/4-page-cache-eviction-and-page-reclaim/)
7. [Chapter 10: Page Frame Reclamation — Gorman's "Understanding the Linux VM"](https://www.kernel.org/doc/gorman/html/understand/understand013.html)
8. [Move LRU page reclaim from zones to nodes — LWN.net](https://lwn.net/Articles/694121/)

## LKML Highlights

- **MGLRU merge** — `20220104202227.2903605-1-yuzhao@google.com`: The 14-patch series merging MGLRU; the debate centred on whether the complexity was justified by the benchmarks and whether the PID controller feedback loop was stable under adversarial workloads.
- **Zone→node reclaim** — `20160606135415.GA31383@techsingularity.net`: Mel Gorman's patch moving reclaim from zones to nodes; discussion revealed how per-zone watermarks caused excessive anonymous swapping on NUMA even when upper zones had plenty of free pages.
- **Remove congestion_wait** — `20210125181122.GC3285@techsingularity.net`: Replaced the unreliable `congestion_wait()` throttle with `reclaim_throttle()`; the thread explained why block-layer congestion signals had become meaningless with NVMe and fast storage.
