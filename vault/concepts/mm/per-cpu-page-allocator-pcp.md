---
title: "Per-CPU Page Allocator (PCP)"
category: concept
tags: [memory, page-allocator, per-cpu, buddy-allocator, scalability, zone]
subsystem: mm
kernel_version: "2.6"
researched: 2026-04-04
sources:
  - https://kernel-internals.org/mm/page-allocator/
  - https://lwn.net/Articles/173215/
  - https://lwn.net/Articles/707495/
  - https://lwn.net/Articles/129687/
  - https://lwn.net/Articles/884448/
  - https://lwn.net/Articles/945579/
  - https://lore.kernel.org/all/20260403194526.477775-3-hannes@cmpxchg.org/
  - https://lore.kernel.org/linux-mm/20231016053002.756205-4-ying.huang@intel.com/T/
  - https://lore.kernel.org/all/20241126095138.1832464-1-claudiu.beznea.uj@bp.renesas.com/
  - https://www.kernel.org/doc/gorman/html/understand/understand009.html
  - https://syst3mfailure.io/linux-page-allocator/
---

# Per-CPU Page Allocator (PCP)

> 📘 Plain-language version: [[per-cpu-page-allocator-pcp-explained]]

## Summary

The Per-CPU Page Allocator (PCP) is a per-CPU caching layer that sits between callers of `alloc_pages()` and the global zone buddy allocator. Each CPU keeps a small local list of free pages per memory zone so that routine single-page allocations and frees can be satisfied with only a cheap local spinlock rather than the globally-contended `zone->lock`. When the local list runs dry it refills in bulk from the buddy allocator under the zone lock; when it overflows it drains in bulk back — amortizing lock cost across many operations. The mechanism is foundational to memory allocator scalability on multi-core and NUMA systems, and has been incrementally extended since Linux 2.6 to cover high-order pages, dynamic watermark tuning, and remote draining.

## Design Rationale

Before PCP, every call to `alloc_pages(order=0)` — the most common allocation in the kernel — had to acquire the zone-level spinlock. On SMP systems this serialized all allocation and free activity across every CPU in the zone, making the zone lock a hard scalability ceiling. The insight behind PCP is simple: most CPUs allocate and free pages in short-lived bursts. By giving each CPU its own local cache and only going to the zone lock in batches, the amortized lock cost per allocation collapses to near zero under most workloads.

The design trades a small amount of idle memory (pages sitting in local lists unused by other CPUs) for a large reduction in lock pressure. The `batch` and `high` parameters are the knobs that balance these concerns.

## How It Works

### Allocation Path

1. `__alloc_pages()` routes order ≤ `PAGE_ALLOC_COSTLY_ORDER` (3) requests through **`rmqueue_pcplist()`**.
2. `rmqueue_pcplist()` maps `(migratetype, order)` → list index via `order_to_pindex()` and checks `pcp->lists[idx]` for the current CPU — holding only `pcp->lock` (a per-CPU spinlock, IRQs enabled since v6.5).
3. If the list is non-empty, a page is popped and returned immediately. No zone lock acquired.
4. If empty, **`rmqueue_bulk()`** acquires `zone->lock` once and fetches `pcp->batch` pages, placing them in the appropriate PCP list. All subsequent allocations from that batch are lock-free.

### Free Path

1. `free_unref_page()` places the freed page onto the correct `pcp->lists[]` entry under `pcp->lock`.
2. If `pcp->count > pcp->high`, **`free_pcppages_bulk()`** acquires `zone->lock` once and drains a batch of pages back to the buddy allocator's free lists.

### Batch and Watermark Parameters

| Field | Purpose |
|-------|---------|
| `batch` | Number of pages moved per zone-lock acquisition during refill or drain. Proportional to zone size; bounded by `CONFIG_PCP_BATCH_SCALE_MAX`. |
| `high` | Watermark above which the list is considered overfull and is drained. Dynamically auto-tuned since v6.6 (see Notable Patches). |
| `high_min` | Minimum allowed value for `high` (auto-tuning lower bound). |
| `high_max` | Maximum allowed value for `high` (auto-tuning upper bound; equals value of `percpu_pagelist_high_fraction` sysctl). |

The `batch` computation scales with zone size but was capped by `CONFIG_PCP_BATCH_SCALE_MAX` in v6.6 (commit `52166607ecc9`) to bound worst-case allocation latency on small embedded systems.

### List Layout (`NR_PCP_LISTS`)

Since v4.9 the `lists[]` array covers both migration types and page orders:

```
index = (MIGRATE_PCPTYPES × order) + migratetype
NR_PCP_LISTS = MIGRATE_PCPTYPES × (PAGE_ALLOC_COSTLY_ORDER + 1)
             + NR_PCP_THP          ← extra slot for THP on supported configs
```

This means orders 0–3 each get a list per migrate type (UNMOVABLE, MOVABLE, RECLAIMABLE), giving 12 lists by default plus optional THP slots.

### NUMA Awareness

Pagesets were originally embedded in `struct zone` by value (`per_cpu_pageset pageset[NR_CPUS]`). The 2005 "Pageset Localization" patch changed this to a pointer array and allocated each CPU's pageset on the NUMA node nearest to that CPU via `kmalloc_node()`. This ensures the control structure itself has local NUMA affinity, cutting latency for the batch management code that runs frequently on the local CPU.

### Remote Draining (v5.19+)

Prior to v5.19, draining a remote CPU's PCP list (needed under memory pressure) required sending an IPI and waiting for the target CPU to drain itself via a workqueue entry — which could be delayed indefinitely on tickless or RT CPUs. The 2022 "remote PCP draining" patch introduced a double-buffering scheme:

1. Each CPU maintains two `per_cpu_pages` structures (pointed to by a per-CPU pointer).
2. A raiding CPU atomically flips the target CPU's pointer to the empty backup set.
3. After an RCU grace period, the raider safely empties the old list without touching the target CPU at all.

Cost: one extra pointer dereference in the allocation hot path (measured at 1–3% regression on some microbenchmarks).

### CPU Offline Draining

When a CPU goes offline, `drain_cpu_pages()` is called from the CPU hotplug notifier before the CPU struct is torn down, flushing all PCP pages back to the zone buddy allocator so no pages are stranded.

### SMP=n Locking Fix (2026)

Commit `574907741599` ("leave IRQs enabled for per-cpu page allocations") introduced a subtle bug on `SMP=n` kernels: `drain_pages_zone()` holds `spin_lock(&pcp->lock)` and can receive a timer interrupt that calls `spin_trylock()` on the same lock. On SMP kernels the trylock fails gracefully; on `SMP=n` the spinlock implementation assumes trylock always succeeds (it's a no-op), causing PCP structure corruption. Fixed by Vlastimil Babka (commit `038a102535eb`) by wrapping `spin_lock()` calls on `pcp->lock` with `spin_lock_irqsave()` on `SMP=n` builds.

## Key Data Structures

| Structure | Location | Purpose |
|-----------|----------|---------|
| `per_cpu_pages` | `include/linux/mmzone.h` | Core PCP state per CPU per zone: lock, count, high, high_min, high_max, batch, lists[] |
| `per_cpu_pageset` | `include/linux/mmzone.h` | Wraps `per_cpu_pages`; adds NUMA statistics counters |
| `zone.per_cpu_pageset` | `include/linux/mmzone.h` | Per-zone pointer to the per-CPU pageset for each CPU |
| `pageblock_data` | `include/linux/mmzone.h` (RFC 2026) | Replaces packed pageblock_flags bitmap; adds owner-CPU field for upcoming pageblock-level PCP |

### `struct per_cpu_pages` (current mainline)

```c
struct per_cpu_pages {
    spinlock_t lock;          /* Protects lists; IRQ-safe on SMP=n */
    int count;                /* Total pages in lists */
    int high;                 /* Current high watermark (auto-tuned) */
    int high_min;             /* Auto-tuning lower bound */
    int high_max;             /* Auto-tuning upper bound */
    int batch;                /* Bulk refill/drain size */
    short free_factor;        /* Heuristic for fast-free path */
    short expire;             /* Countdown for reclaim eligibility */
    struct list_head lists[NR_PCP_LISTS]; /* Freelist per [order][migratetype] */
} ____cacheline_aligned_in_smp;
```

## Key Functions / Entry Points

| Function | File | Description |
|----------|------|-------------|
| `rmqueue_pcplist()` | `mm/page_alloc.c` | Fast-path PCP allocation; selects list and calls `__rmqueue_pcplist()` |
| `__rmqueue_pcplist()` | `mm/page_alloc.c` | Pops page from list; triggers `rmqueue_bulk()` refill if empty |
| `rmqueue_bulk()` | `mm/page_alloc.c` | Holds zone lock once; refills PCP with `batch` pages from buddy |
| `free_unref_page()` | `mm/page_alloc.c` | Single-page free entry point; routes to PCP list |
| `free_unref_page_list()` | `mm/page_alloc.c` | Bulk-free a linked list of pages to PCP |
| `free_pcppages_bulk()` | `mm/page_alloc.c` | Drains excess PCP pages to buddy under zone lock |
| `drain_cpu_pages()` | `mm/page_alloc.c` | Drains a single CPU's PCP (CPU hotplug, memory pressure) |
| `drain_all_pages()` | `mm/page_alloc.c` | IPI or remote-drain of all CPUs' PCP lists |
| `order_to_pindex()` | `mm/page_alloc.c` | Maps `(order, migratetype)` → `lists[]` index |
| `decay_pcp_high()` | `mm/page_alloc.c` | Called periodically to decay `pcp->high` toward `high_min` when idle |

## Interactions with Other Subsystems

- **Zone buddy allocator** (`mm/page_alloc.c`) — PCP is the first-level cache in front of the buddy system. All refills and drains go through the buddy layer under `zone->lock`.
- **SLUB / SLAB** (`mm/slub.c`) — The dominant consumer of PCP pages. The 2016 high-order PCP extension was motivated primarily by SLUB's repeated high-order allocations causing zone-lock storms.
- **vmstat** (`mm/vmstat.c`) — Tracks `NR_FREE_PAGES`, `PGALLOC_*`, `PGFREE`, and per-zone PCP counters. The `vmstat_update` worker requeues periodically; a 2026 patch spread the requeue interval across CPUs to avoid thundering-herd lock spikes.
- **Memory reclaim / kswapd** (`mm/vmscan.c`) — Under memory pressure, reclaim calls `drain_all_pages()` to surface pages hidden in PCP lists. The auto-tuning patch also hooks into reclaim: `pcp->high` is decreased when the zone's free pages fall below the low watermark.
- **CPU hotplug** (`kernel/cpu.c`) — CPU offline notifiers drain the departing CPU's PCP before the CPU struct is freed; remote-drain logic handles the offline transition safely.
- **Memory compaction** (`mm/compaction.c`) — `kcompactd` calls `drain_all_pages()` to recover PCP-cached pages for compaction; the SMP=n locking bug was discovered via this path.
- **NUMA balancing** — Pagesets are allocated on the NUMA-local node per CPU, so PCP management code operates on local memory. Free pages drain back to the zone's buddy, maintaining NUMA locality.
- **Transparent Huge Pages (THP)** — Recent kernels reserve `NR_PCP_THP` extra slots in `NR_PCP_LISTS` to allow THP-order caching on supported architectures.

## Notable Patches & Changes

1. **Hot/cold page unification — single PCP lists** (2006, Christoph Lameter)
   The original PCP used two separate lists: a "hot" list (pages likely still in CPU cache) and a "cold" list (cache-cold pages). This caused two bugs: cold pages were skipped when the hot list was needed but empty, and hot-list spills did not replenish the cold list. The patch merged both into a single list with cold pages appended to the tail (`list_add_tail`) and hot pages prepended (`list_add`), solving both problems without losing the cold-preference semantics.
   - LWN: https://lwn.net/Articles/173215/

2. **Pageset localization for NUMA** (2005, Christoph Lameter, "Pageset Localization V2")
   Changed `struct zone` from embedding `per_cpu_pageset pageset[NR_CPUS]` by value to a pointer array dynamically allocated via `kmalloc_node()` on each CPU's nearest NUMA node. Delivered 25%+ AIM7 throughput gains in the 100–600 task range on NUMA hardware.
   - LWN: https://lwn.net/Articles/129687/

3. **High-order per-CPU page allocator** (v4.9, Mel Gorman, 2016)
   Extended `lists[]` from `MIGRATE_PCPTYPES` to `NR_PCP_LISTS` entries, adding per-CPU caches for orders 1–3. Introduced `order_to_pindex()` / `pindex_to_order()` helper functions and extended `buffered_rmqueue()` to serve orders beyond 0. Reduced zone-lock contention for SLUB-driven high-order allocations by 1–9.5% on netperf/multi-socket workloads.
   - LWN: https://lwn.net/Articles/707495/

4. **Remote per-CPU page list draining** (v5.19, Nicolas Saenz Julienne / Mel Gorman, 2022)
   Replaced IPI-based drain requests with an RCU double-buffer scheme: a raiding CPU atomically swaps the target CPU's `per_cpu_pages` pointer to an empty backup, waits for an RCU grace period, then safely drains the old lists. Eliminates indefinite drain delays on tickless and RT CPUs. Cost: ~1–3% regression on some allocation microbenchmarks due to an extra pointer dereference.
   - LWN: https://lwn.net/Articles/884448/

5. **PCP high auto-tuning** (v6.6, Ying Huang / Intel, 2023)
   Added `high_min`, `high_max`, and `flags` fields to `per_cpu_pages`. The allocator now continuously adjusts `pcp->high` between these bounds based on observed allocation demand. `decay_pcp_high()` shrinks the watermark toward `high_min` during idle periods; reclaim pressure shrinks it when the zone is short on pages. Delivered 5% kernel-build speedup, 7% netperf SCTP improvement, and 96% lmbench UNIX-socket improvement on 224-CPU Sapphire Rapids systems by collapsing zone-lock contention from 13.5% to under 1%.
   - LWN: https://lwn.net/Articles/945579/
   - LKML: `20231016053002.756205-4-ying.huang@intel.com`

6. **Restrict PCP batch scale factor** (v6.6, commit `52166607ecc9`)
   Introduced `CONFIG_PCP_BATCH_SCALE_MAX` to cap the exponential batch scaling and bound worst-case allocation latency. Exposed a 40% bonnie++ regression on single-core Renesas RZ/G3S (no L2 cache, 1 GB RAM). A follow-on patch added the `pcp_batch_scale_max=` kernel parameter to allow per-system override at boot.
   - LKML: `20241126095138.1832464-1-claudiu.beznea.uj@bp.renesas.com`

7. **SMP=n PCP locking fix** (2026, Vlastimil Babka / SUSE, commit `038a102535eb`)
   A 2023 patch ("leave IRQs enabled for per-cpu page allocations", `574907741599`) allowed `pcp->lock` to be held with IRQs enabled. On `SMP=n` kernels, `spin_trylock()` is a no-op that always "succeeds" — so when a timer interrupt fires during a `spin_lock(&pcp->lock)` section and tries `spin_trylock()` on the same lock, the UP implementation double-enters the lock, corrupting the PCP structure. Fixed by using `spin_lock_irqsave()` wrappers for all `pcp->lock` acquisitions when `SMP=n`.
   - Reported by: kernel test robot; analyzed by Matthew Wilcox.
   - LKML: `20260105-fix-pcp-up-v1-1-5579662d2071@suse.cz`

8. **Per-CPU pageblock buddy allocator (RFC)** (2026, Johannes Weiner / Meta)
   Proposes a fundamental redesign: instead of caching individual pages, each CPU claims entire pageblocks (e.g., 2 MB on x86-64) from the buddy allocator and splits them locally outside the zone lock. Pages are tagged with their owner CPU (`PagePCPBuddy`), so frees route back to the owning CPU's PCP regardless of which CPU frees — eliminating the affinity-violation lock storms caused by jemalloc/tcmalloc purger threads and bulk process exits. Four-phase refill: (0) recover owned fragments, (1) claim whole pageblocks, (2) grab sub-block chunks without migratetype stealing, (3) traditional `__rmqueue()` fallback. Demonstrated 3–4% `%sys` reduction on 32-way machines for kernel builds; degrades gracefully to current behavior on small or memory-pressured machines.
   - LKML: `20260403194526.477775-3-hannes@cmpxchg.org`
   - Reviewed by: Rik van Riel, Zi Yan (NVIDIA)

## Further Reading

1. [kernel-internals.org — Page Allocator](https://kernel-internals.org/mm/page-allocator/) — Design rationale for PCP and buddy allocator, explaining *why* each architectural choice was made
2. [LWN — High-order per-CPU page allocator](https://lwn.net/Articles/707495/) — Best single-article overview of `NR_PCP_LISTS`, the index mapping scheme, and SLUB motivation
3. [LWN — PCP high auto-tuning](https://lwn.net/Articles/945579/) — Covers the v6.6 dynamic watermark system with performance numbers on large NUMA machines
4. [LWN — Remote per-CPU page list draining](https://lwn.net/Articles/884448/) — Explains the RCU double-buffer drain scheme and RT/tickless motivation
5. [LWN — Single PCP lists](https://lwn.net/Articles/173215/) — Historical context on hot/cold list unification
6. [LWN — Pageset Localization V2](https://lwn.net/Articles/129687/) — NUMA-aware pageset placement; explains `kmalloc_node()` allocation of PCP structures
7. [Understanding the Linux VM — Chapter 6](https://www.kernel.org/doc/gorman/html/understand/understand009.html) — Classic reference covering the early low/high watermark pageset design
8. [syst3mfailure.io — Linux page allocator](https://syst3mfailure.io/linux-page-allocator/) — Modern walkthrough of `per_cpu_pages` fields and `NR_PCP_LISTS` indexing

## LKML Threads

| Message ID | Subject / Notes |
|------------|----------------|
| `20260403194526.477775-3-hannes@cmpxchg.org` | [RFC 2/2] mm: page_alloc: per-cpu pageblock buddy allocator — Johannes Weiner (Meta), Apr 2026; proposes pageblock-level ownership |
| `20260403194526.477775-2-hannes@cmpxchg.org` | [RFC 1/2] mm: page_alloc: replace pageblock_flags bitmap with struct pageblock_data — prerequisite for pageblock ownership |
| `20260105-fix-pcp-up-v1-1-5579662d2071@suse.cz` | mm/page_alloc: prevent pcp corruption with SMP=n — Vlastimil Babka; fixes trylock nesting on UP builds |
| `20241126095138.1832464-1-claudiu.beznea.uj@bp.renesas.com` | [RFC PATCH] mm: page_alloc: Add kernel parameter to select maximum PCP batch scale number — Claudiu Beznea (Renesas), regression on single-core SoC |
| `20231025234818.A6EBAC433CA@smtp.kernel.org` | [merged mm-stable] mm-pcp-reduce-lock-contention-for-draining-high-order-pages |
| `20231025234815.73D05C433C7@smtp.kernel.org` | [merged mm-stable] mm-pcp-avoid-to-drain-pcp-when-process-exit |
| `20231016053002.756205-4-ying.huang@intel.com` | [PATCH -V3 0/9] mm: PCP high auto-tuning — Ying Huang (Intel); dynamic high_min/high_max framework |
