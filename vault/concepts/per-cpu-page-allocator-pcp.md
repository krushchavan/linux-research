---
title: "Per-CPU Page Allocator (PCP)"
category: concept
tags: [memory, page-allocator, per-cpu, buddy-allocator, scalability]
subsystem: mm
kernel_version: "2.6"
researched: 2026-04-04
sources:
  - https://lwn.net/Articles/173215/
  - https://lwn.net/Articles/707495/
  - https://lore.kernel.org/all/20260403194526.477775-3-hannes@cmpxchg.org/
  - https://lore.kernel.org/all/20241126095138.1832464-1-claudiu.beznea.uj@bp.renesas.com/
  - https://www.kernel.org/doc/gorman/html/understand/understand009.html
  - https://syst3mfailure.io/linux-page-allocator/
  - https://linux-mm.org/PageAllocation
---

# Per-CPU Page Allocator (PCP)

## Summary

The Per-CPU Page Allocator (PCP) is a caching layer that sits between callers of the page allocator and the global zone buddy allocator. Each CPU maintains a small local freelist of pages per zone, so that common order-0 (and, since 2016, small high-order) allocations and frees can be satisfied without acquiring the zone-wide spinlock. When a CPU's local list runs dry it refills in bulk from the buddy allocator; when it overflows it drains in bulk back to the buddy allocator — reducing total lock acquisitions and improving scalability on multicore systems.

## How It Works

### Allocation Path

1. `__alloc_pages()` routes order ≤ `PAGE_ALLOC_COSTLY_ORDER` (order 3) requests through `rmqueue_pcplist()`.
2. `rmqueue_pcplist()` computes the list index with `order_to_pindex(migratetype, order)` and checks the per-CPU `lists[]` entry for the running CPU.
3. If the list is non-empty, a page is popped off with no lock contention — just a local spinlock on `per_cpu_pages.lock`.
4. If the list is empty, `rmqueue_bulk()` acquires the zone's buddy lock once and refills the PCP list with `batch` pages. All subsequent allocations from that batch are lock-free.

### Free Path

1. `free_unref_page()` (order ≤ `PAGE_ALLOC_COSTLY_ORDER`) places the freed page onto the appropriate PCP list (by migratetype and order) under the local `pcp->lock`.
2. If `pcp->count` exceeds `pcp->high`, `free_pcppages_bulk()` acquires the zone lock once and drains a batch of pages back to the buddy allocator's free lists.

### Batch and High-Watermark Tuning

- **`batch`** — how many pages are moved in one zone-lock acquisition during refill or drain. Scaled by the zone size; tunable via `vm.percpu_pagelist_fraction` and the `CONFIG_PCP_BATCH_SCALE_MAX` compile option.
- **`high`** — the watermark at which the list is considered overfull and drained. Auto-tuned since kernel 6.6 (`mm: PCP high auto-tuning`) to track allocation pressure. Previously a fixed fraction of zone size.

### High-Order Extension (v4.9+)

Before v4.9 the PCP only cached order-0 pages. A 2016 patch (see Notable Patches) extended the `lists[]` array to cover all orders up to `PAGE_ALLOC_COSTLY_ORDER`, eliminating repeated zone-lock acquisitions for high-order pages used heavily by SLUB slab caches.

The list array is now indexed as:
```
index = (MIGRATE_PCPTYPES * order) + migratetype
NR_PCP_LISTS = MIGRATE_PCPTYPES * (PAGE_ALLOC_COSTLY_ORDER + 1)
             + NR_PCP_THP  [+ 1 for THP on supported configs]
```

### CPU Offline / Drain

When a CPU goes offline (`cpu_down()`), all pages in its PCP lists must be flushed back to the zone buddy allocator before the CPU is removed. `drain_cpu_pages()` is called from the CPU hotplug notifier chain. The 2023 "avoid drain on process exit" patch (Andrew Morton, mm-stable) eliminated an unnecessary drain that fired at process exit when the PCP was empty anyway.

## Key Data Structures

| Structure | Location | Purpose |
|-----------|----------|---------|
| `per_cpu_pages` | `include/linux/mmzone.h` | Core PCP state: lock, count, high, batch, lists[] |
| `per_cpu_pageset` | `include/linux/mmzone.h` | Wrapper; embeds `per_cpu_pages` and NUMA stat counters |
| `zone.per_cpu_pageset` | `include/linux/mmzone.h` | Per-zone pointer to per-CPU pageset array |
| `pageblock_data` | `include/linux/mmzone.h` (RFC, 2026) | Per-pageblock struct replacing packed bitmap; adds owner CPU field for the upcoming pageblock-level PCP |

### `struct per_cpu_pages` fields (current mainline)

```c
struct per_cpu_pages {
    spinlock_t lock;          /* Protects lists */
    int count;                /* Number of pages in lists */
    int high;                 /* High watermark: drain when exceeded */
    int batch;                /* Chunk size for refill/drain */
    short free_factor;        /* Fast free heuristic scale */
    short expire;             /* Pages near expiry for reclaim */
    struct list_head lists[NR_PCP_LISTS]; /* Freelists [order][migratetype] */
} ____cacheline_aligned_in_smp;
```

## Key Functions / Entry Points

| Function | File | Description |
|----------|------|-------------|
| `rmqueue_pcplist()` | `mm/page_alloc.c` | Fast-path PCP allocation; calls `__rmqueue_pcplist()` |
| `__rmqueue_pcplist()` | `mm/page_alloc.c` | Selects list, optionally refills via `rmqueue_bulk()` |
| `rmqueue_bulk()` | `mm/page_alloc.c` | Batch-refills PCP from buddy under zone lock |
| `free_unref_page()` | `mm/page_alloc.c` | Entry point for single-page free to PCP |
| `free_unref_page_list()` | `mm/page_alloc.c` | Bulk-free a list of pages to PCP |
| `free_pcppages_bulk()` | `mm/page_alloc.c` | Drains excess PCP pages to buddy under zone lock |
| `drain_cpu_pages()` | `mm/page_alloc.c` | Drains a specific CPU's PCP (hotplug, reclaim) |
| `drain_all_pages()` | `mm/page_alloc.c` | IPI-driven drain of all CPUs' PCP lists |
| `order_to_pindex()` | `mm/page_alloc.c` | Maps (order, migratetype) → lists[] index |

## Interactions with Other Subsystems

- **Zone buddy allocator** (`mm/page_alloc.c`, `mm/buddy.c`) — PCP is the primary client; all PCP refills and drains go through the buddy layer under `zone->lock`.
- **SLUB / SLAB** (`mm/slub.c`) — The major consumer of PCP pages. High-order PCP caching was introduced primarily to serve SLUB's per-slab high-order allocations without zone-lock storms.
- **vmstat** (`mm/vmstat.c`) — Tracks `NR_FREE_PAGES` and `vm_event_states` (PGALLOC, PGFREE, etc.); the `vmstat_update` worker periodically drains PCP counters to global stats. A 2026 patch spread the requeue interval to reduce thundering herd.
- **Memory reclaim** (`mm/vmscan.c`) — Kswapd and direct reclaim call `drain_all_pages()` when they need to reclaim pages pinned in PCP lists.
- **CPU hotplug** (`kernel/cpu.c`) — CPU offline notifiers call `drain_cpu_pages()` to flush the departing CPU's PCP before the CPU struct is torn down.
- **NUMA balancing** — PCP lists are per-zone, so on NUMA machines each CPU drains to its local zone's buddy, keeping allocations NUMA-local.
- **Transparent Huge Pages (THP)** — Recent kernels add an extra `NR_PCP_THP` slot in `NR_PCP_LISTS` to allow THP-order pages to be PCP-cached on supported architectures.

## Notable Patches & Changes

1. **Single PCP lists** (2006, Christoph Lameter)
   - Removed the separate hot/cold `pcp[2]` array; merged into one list with cold pages at the tail.
   - Fixed bug where cold pages were never replenished when hot allocation spilled.
   - LWN: https://lwn.net/Articles/173215/

2. **High-order per-CPU page allocator** (v4.9, Mel Gorman, 2016)
   - Extended `lists[]` from `MIGRATE_PCPTYPES` to `NR_PCP_LISTS` entries covering orders 0–3.
   - Reduced zone-lock contention for SLUB high-order allocations by 1–9% on netperf workloads.
   - LWN: https://lwn.net/Articles/707495/

3. **PCP high auto-tuning** (v6.6, Ying Huang, Intel, 2023)
   - `pcp->high` is now dynamically adjusted based on observed allocation demand rather than a fixed fraction of zone size.
   - LKML: `lore.kernel.org/linux-mm/20231016053002.756205-4-ying.huang@intel.com`

4. **Restrict PCP batch scale factor** (v6.6, commit `52166607ecc9`)
   - Introduced `CONFIG_PCP_BATCH_SCALE_MAX` to cap batch scaling and bound worst-case allocation latency.
   - Exposed a regression on single-core embedded SoCs (Renesas RZ/G3S), leading to a follow-on patch adding a `pcp_batch_scale_max=` kernel parameter.
   - LKML: `20241126095138.1832464-1-claudiu.beznea.uj@bp.renesas.com`

5. **Per-CPU pageblock buddy allocator (RFC)** (2026, Johannes Weiner / Meta)
   - Proposes extending PCP to claim entire pageblocks from the buddy allocator and split them locally.
   - Pages freed to the owning CPU's PCP regardless of which CPU frees them, eliminating affinity-violation lock storms from jemalloc/tcmalloc purge threads and bulk process exits.
   - Four-phase refill: (0) recover owned fragments, (1) claim whole pageblocks, (2) grab sub-block chunks, (3) traditional `__rmqueue()` fallback.
   - Demonstrated 3–4% reduction in `%sys` time on 32-way machines for kernel builds.
   - LKML: `20260403194526.477775-3-hannes@cmpxchg.org`

## Further Reading

1. [LWN — High-order per-CPU page allocator](https://lwn.net/Articles/707495/) — Best overview of the 2016 high-order extension and motivation
2. [LWN — Single PCP lists](https://lwn.net/Articles/173215/) — Historical context on hot/cold list unification
3. [Understanding the Linux Virtual Memory Manager — Chapter 6: Physical Page Allocation](https://www.kernel.org/doc/gorman/html/understand/understand009.html) — Classic reference; covers early pageset design with low/high watermarks
4. [A Quick Dive Into The Linux Kernel Page Allocator](https://syst3mfailure.io/linux-page-allocator/) — Modern walkthrough of `per_cpu_pages` fields, `NR_PCP_LISTS`, and allocation/free paths
5. [linux-mm.org — PageAllocation](https://linux-mm.org/PageAllocation) — Community wiki with links to major historical changes
6. [PCP high auto-tuning patch series](https://lore.kernel.org/linux-mm/20231016053002.756205-4-ying.huang@intel.com/T/) — LKML thread for v6.6 dynamic high-watermark tuning

## LKML Threads

| Message ID | Subject |
|-----------|---------|
| `20260403194526.477775-3-hannes@cmpxchg.org` | [RFC 2/2] mm: page_alloc: per-cpu pageblock buddy allocator (Johannes Weiner, Meta, Apr 2026) |
| `20260403194526.477775-2-hannes@cmpxchg.org` | [RFC 1/2] mm: page_alloc: replace pageblock_flags bitmap with struct pageblock_data |
| `20241126095138.1832464-1-claudiu.beznea.uj@bp.renesas.com` | [RFC PATCH] mm: page_alloc: Add kernel parameter to select maximum PCP batch scale number |
| `20231025234818.A6EBAC433CA@smtp.kernel.org` | [merged mm-stable] mm-pcp-reduce-lock-contention-for-draining-high-order-pages |
| `20231025234815.73D05C433C7@smtp.kernel.org` | [merged mm-stable] mm-pcp-avoid-to-drain-pcp-when-process-exit |
