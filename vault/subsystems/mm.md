---
title: "mm"
category: subsystem
tags: [memory, mm, buddy-allocator, slub, vma, reclaim, numa, page-cache]
maintainer: "Andrew Morton <akpm@linux-foundation.org>"
mailing_list: linux-mm@kvack.org
source_path: mm/
researched: 2026-04-05
sources:
  - https://kernel-internals.org/mm/
  - https://kernel-internals.org/mm/life-of-malloc/
  - https://kernel-internals.org/mm/slab/
  - https://kernel-internals.org/mm/vmalloc/
  - https://kernel-internals.org/mm/numa/
  - https://docs.kernel.org/mm/index.html
  - https://docs.kernel.org/admin-guide/mm/concepts.html
  - https://lwn.net/Articles/856016/
  - https://lwn.net/Articles/901714/
  - https://lwn.net/Articles/924572/
  - https://lwn.net/Articles/893906/
  - https://lwn.net/Articles/997398/
---

# mm Subsystem

## Overview

The `mm` subsystem is Linux's memory management layer — the part of the kernel responsible for every interaction between software and physical RAM. It provides the illusion of private, unlimited address spaces to processes while sharing limited physical memory safely and efficiently across all workloads running on the system. Its scope spans from the earliest moments of boot (when RAM is barely understood) all the way to steady-state operation, balancing allocation speed, fragmentation avoidance, NUMA locality, and memory reclaim under pressure. The subsystem lives almost entirely in `mm/` and `include/linux/mm*.h`.

**Maintainer:** Andrew Morton (`akpm@linux-foundation.org`)
**Mailing list:** `linux-mm@kvack.org`
**Git trees:** `mm-unstable` (bleeding edge), `mm-stable` (headed for mainline), both hosted at `git.kernel.org/pub/scm/linux/kernel/git/akpm/`

---

## Architecture

The mm subsystem is best understood as a stack of layers, each solving a different level of the memory problem:

```
User process
    │  malloc() / mmap() / brk()
    ▼
┌─────────────────────────────────┐
│  Virtual Memory Areas (VMAs)    │  mm/mmap.c, mm/memory.c
│  Maple tree of address ranges   │  (per mm_struct, per process)
└──────────────┬──────────────────┘
               │  page fault
               ▼
┌─────────────────────────────────┐
│  Page Fault Handler             │  mm/memory.c → handle_pte_fault()
│  anonymous / file / swap        │
└──────────────┬──────────────────┘
               │  __alloc_pages()
               ▼
┌─────────────────────────────────┐
│  Per-CPU Page Allocator (PCP)   │  mm/page_alloc.c
│  Local fast path, batch refill  │
└──────────────┬──────────────────┘
               │  zone lock, slow path
               ▼
┌─────────────────────────────────┐
│  Buddy Allocator                │  mm/page_alloc.c
│  Zone free lists, power-of-2    │
└──────────────┬──────────────────┘
               │  reclaim / compaction
               ▼
┌─────────────────────────────────┐
│  Page Reclaim & Compaction      │  mm/vmscan.c, mm/compaction.c
│  kswapd, direct reclaim, LRU   │
└─────────────────────────────────┘

Parallel stack for kernel-internal allocations:
  kmalloc / kmem_cache_alloc → SLUB (mm/slub.c) → Buddy
  vmalloc                    → mm/vmalloc.c      → Buddy (non-contiguous)
```

The design principle is **demand paging with lazy allocation**: virtual addresses are handed out immediately and cheaply (just a VMA record), while physical pages are allocated only on first access via page faults. This makes `fork()` cheap (copy-on-write), `malloc()` cheap (no physical work yet), and overcommit possible (most reserved memory is never touched).

---

## Core Components

### 1. Memblock — Early Boot Allocator (`mm/memblock.c`)

Before the buddy allocator is initialized, `memblock` provides a simple region-based allocator. It tracks two lists — available RAM regions and reserved regions — and is used from the point firmware hands control to the kernel until `mem_init()` hands off to the buddy system. After that point, memblock data is freed.

### 2. Zones and Nodes — Physical Memory Topology (`include/linux/mmzone.h`)

Physical memory is organized hierarchically:
- **`pglist_data`** (one per NUMA node) — top-level node descriptor holding per-node statistics and zone lists
- **`struct zone`** — a contiguous range within a node: `ZONE_DMA`, `ZONE_DMA32`, `ZONE_NORMAL`, `ZONE_HIGHMEM` (32-bit only), `ZONE_MOVABLE`
- Each zone holds buddy free-area lists and per-CPU pagesets (PCP)

On NUMA systems the allocator consults distance matrices (from ACPI SRAT/SLIT tables) to prefer local-node pages and fall back to progressively more distant nodes.

### 3. Buddy Allocator — Physical Page Management (`mm/page_alloc.c`)

The buddy system maintains per-zone free lists for orders 0–`MAX_PAGE_ORDER` (0 = 4 KB, 10 = 4 MB on most arches). Allocations round up to the next power of two; freed blocks are merged with their "buddy" (the adjacent block of the same size) recursively upward. The system is NUMA-aware: `alloc_pages_node()` targets a specific node, while `__alloc_pages()` uses the NUMA fallback list.

**Migration types** within each order (UNMOVABLE, MOVABLE, RECLAIMABLE) allow compaction to relocate movable pages and assemble large contiguous free blocks without moving kernel data structures.

### 4. Per-CPU Page Allocator / PCP (`mm/page_alloc.c`)

A caching layer in front of the buddy allocator that gives each CPU a local freelist of pages per zone. Most order-0 (and order ≤ 3 since v4.9) allocations and frees are served from these lists without touching the global `zone->lock`. See the dedicated note: `[[per-cpu-page-allocator-pcp]]`.

### 5. SLUB Slab Allocator (`mm/slub.c`)

The kernel's byte-level allocator. It creates typed caches (`struct kmem_cache`) that carve buddy pages into fixed-size slots for specific object types (dentries, inodes, sk_buff, etc.), providing lockless fast-path allocation via per-CPU freelists using `cmpxchg`. SLUB replaced the original SLAB allocator as the default in v2.6.23 and is now the only general-purpose slab implementation (SLAB removed v6.8, SLOB removed v6.4).

**Security features:** randomized freelist ordering, XORed freelist pointers, optional `init_on_alloc`/`init_on_free` zeroing, KFENCE (production-safe memory error detector).

### 6. vmalloc — Virtually-Contiguous Allocator (`mm/vmalloc.c`)

When kmalloc cannot satisfy a request (too large or physical contiguity unavailable), `vmalloc()` maps non-contiguous physical pages into a contiguous virtual range in the kernel's vmalloc address space. Uses the buddy allocator for physical pages and manipulates kernel page tables directly. Accesses are slightly slower (extra TLB pressure) but allow very large allocations regardless of physical fragmentation. Tracks free vmalloc ranges in an RB-tree; guard pages detect overflows.

### 7. Virtual Memory Areas and Address Space (`mm/mmap.c`, `mm/memory.c`)

Each process's virtual address space is described by `struct mm_struct`, which holds:
- A **maple tree** of `struct vm_area_struct` (VMA) records (since v6.1; previously an augmented red-black tree + linked list)
- Page table root pointer (`pgd`)
- Memory statistics, locks, and limits

A VMA represents one contiguous range of virtual addresses with uniform permissions and backing (anonymous, file, device). The VMA's `vm_ops` function pointers dispatch fault handling to the appropriate back-end (anonymous memory, page cache, hugetlb, etc.).

**Locking:** The historical `mmap_lock` (an rwsem) protects VMA modifications and was a significant scalability bottleneck. **Per-VMA locks** (introduced v6.4–v6.6) allow concurrent fault handling on different VMAs without the mmap_lock read side, using an seqlock-like scheme per VMA. This reduced TCP zerocopy CPU cycles by ~0.5%+ and dropped mmap_lock usage to under 0.1% of cycles on busy systems.

### 8. Page Fault Handler (`mm/memory.c`)

`handle_pte_fault()` is the entry point for all page faults in the kernel. It dispatches to:
- `do_anonymous_page()` — first access to anonymous (heap/stack) pages; allocates from PCP/buddy, installs PTE
- `do_read_fault()` / `do_cow_fault()` — file-backed pages; reads from the page cache or COW-copies
- `do_swap_page()` — restores swapped-out pages from secondary storage
- `do_huge_pmd_anonymous_page()` — THP fast path for large anonymous allocations

### 9. Page Cache (`mm/filemap.c`, `mm/readahead.c`)

The unified buffer/page cache stores recently-read file data so subsequent reads are served from RAM. Indexed by `struct address_space` (one per inode) using an XArray of `struct folio` (formerly raw `struct page`). Writeback is handled by `pdflush`/`writeback` threads via `mm/page-writeback.c`.

### 10. Page Reclaim — kswapd and Direct Reclaim (`mm/vmscan.c`)

When free pages fall below zone watermarks, reclaim fires:
- **kswapd**: per-node daemon that reclaims asynchronously in the background, scanning LRU lists (active/inactive anon + file)
- **Direct reclaim**: triggered synchronously in the allocation slow path when kswapd hasn't kept up
- **LRU management**: pages are on one of four LRU lists; accessed bits are scanned periodically; clean file pages are dropped, dirty pages written back, anonymous pages swapped out

Reclaim can also call `drain_all_pages()` to surface pages held in PCP caches.

### 11. Memory Compaction (`mm/compaction.c`)

Migrates movable pages within a zone to pack them into one end, freeing large physically-contiguous blocks for high-order allocations and THP. Run by `kcompactd` daemons (one per node) or triggered synchronously by the allocator slow path.

### 12. Huge Pages — HugeTLB and THP

- **HugeTLB** (`mm/hugetlb.c`): Explicitly pre-allocated huge pages (2 MB / 1 GB on x86-64) exposed via `hugetlbfs`. Zero TLB fragmentation; applications opt in via `mmap(MAP_HUGETLB)` or `shmget(SHM_HUGETLB)`.
- **Transparent Huge Pages / THP** (`mm/huge_memory.c`): Automatically promotes naturally-aligned anonymous regions to 2 MB PMD-level mappings. Khugepaged scans for promotion opportunities; `split_huge_page()` reverts on partial frees. THP for file-backed mappings arrived in v6.8.

### 13. Swap (`mm/swap.c`, `mm/swapfile.c`)

Provides virtual memory beyond physical RAM by evicting anonymous pages to block devices or files. `add_to_swap()` writes a page to a swap slot; `do_swap_page()` reads it back on fault. Swap tokens, cgroups swap accounting, and ZSWAP (compressed swap cache) extend the basic mechanism.

### 14. Out-of-Memory Killer (`mm/oom_kill.c`)

Last resort when the system cannot reclaim enough memory. Scores all processes using RSS, swap usage, scheduling priority, and oom_score_adj, then sends `SIGKILL` to the highest-scoring process. Cgroups can confine OOM kills to the offending cgroup.

### 15. NUMA Balancing (`mm/numa_balancing.c`, `mm/mempolicy.c`)

Automatic NUMA page placement (since v3.8) periodically unmaps pages to generate NUMA hint faults, records which node accessed each page, and migrates misplaced pages closer to their CPU. Memory policies (`set_mempolicy()`, `mbind()`, `MPOL_BIND/PREFERRED/INTERLEAVE`) allow explicit per-process or per-region control.

### 16. Memory Cgroups (`mm/memcontrol.c`)

Tracks and limits memory usage per cgroup hierarchy. Provides soft limits (reclaim pressure), hard limits (OOM within cgroup), memory.stat accounting, and per-cgroup LRU isolation. The modern `cgroup v2` interface exposes `memory.high`, `memory.max`, and `memory.swap.max` controls.

### 17. DAMON — Data Access Monitoring (`mm/damon/`)

A framework (introduced v5.15) for sampling actual memory access patterns at the page level. Feeds into proactive reclaim (DAMOS: DAMON-based Operation Schemes), allowing the kernel to pre-emptively evict cold pages before memory pressure escalates. Exposed via debugfs and Netlink.

### 18. KSM — Kernel Samepage Merging (`mm/ksm.c`)

Scans anonymous pages for identical content and merges them into a single copy-on-write page, reducing memory pressure in VM-dense environments. Configurable via `/sys/kernel/mm/ksm/`. Most effective where many VMs run identical OS images.

---

## Key Data Structures

| Structure | Location | Purpose |
|-----------|----------|---------|
| `struct mm_struct` | `include/linux/mm_types.h` | Process address space: pgd pointer, maple tree of VMAs, statistics |
| `struct vm_area_struct` | `include/linux/mm_types.h` | One contiguous VMA: start/end, permissions, vm_ops, backing |
| `struct page` | `include/linux/mm_types.h` | Per-physical-page metadata; being replaced by `struct folio` |
| `struct folio` | `include/linux/mm_types.h` | Multi-page-aware successor to `struct page`; knows its own order |
| `struct pglist_data` | `include/linux/mmzone.h` | Per-NUMA-node descriptor: zones, kswapd thread, reclaim stats |
| `struct zone` | `include/linux/mmzone.h` | Per-zone free areas, watermarks, per-CPU pagesets |
| `struct free_area` | `include/linux/mmzone.h` | One buddy order level: free lists per migratetype |
| `struct per_cpu_pages` | `include/linux/mmzone.h` | PCP freelist: lock, count, high, batch, lists[NR_PCP_LISTS] |
| `struct kmem_cache` | `include/linux/slub_def.h` | SLUB cache descriptor: object size, per-CPU and per-node state |
| `struct address_space` | `include/linux/fs.h` | Page cache state for an inode: XArray of folios, writeback ops |
| `struct anon_vma` | `include/linux/rmap.h` | Reverse-map structure connecting anonymous pages to their VMAs |
| `struct mem_cgroup` | `mm/memcontrol.c` | Per-cgroup memory accounting and limit enforcement |

---

## Key Interfaces

### Allocation (kernel internal)

| Function | Description |
|----------|-------------|
| `alloc_pages(gfp, order)` | Allocate 2^order physically-contiguous pages |
| `__get_free_page(gfp)` | Allocate one page, return kernel virtual address |
| `kmalloc(size, gfp)` | Byte-level allocation, physically contiguous (SLUB) |
| `kzalloc(size, gfp)` | kmalloc + zero-fill |
| `vmalloc(size)` | Large allocation, virtually contiguous only |
| `kvmalloc(size, gfp)` | Try kmalloc first, fall back to vmalloc |
| `kmem_cache_alloc(cache, gfp)` | Type-safe SLUB object allocation |

### Page Table / Fault

| Function | File | Description |
|----------|------|-------------|
| `handle_pte_fault()` | `mm/memory.c` | Core page fault dispatcher |
| `do_anonymous_page()` | `mm/memory.c` | First access to anonymous page |
| `do_cow_fault()` | `mm/memory.c` | Copy-on-write fault |
| `do_swap_page()` | `mm/memory.c` | Restore a swapped-out page |

### VMA Management

| Function | File | Description |
|----------|------|-------------|
| `mmap_region()` | `mm/mmap.c` | Create a new VMA |
| `find_vma()` | `mm/mmap.c` | Look up VMA covering an address (maple tree lookup) |
| `do_vmi_align_munmap()` | `mm/mmap.c` | Remove a VMA range |
| `lock_vma_under_rcu()` | `mm/memory.c` | Acquire per-VMA read lock (RCU, no mmap_lock) |

### Reclaim

| Function | File | Description |
|----------|------|-------------|
| `kswapd()` | `mm/vmscan.c` | Main reclaim daemon loop |
| `try_to_free_pages()` | `mm/vmscan.c` | Direct reclaim entry point |
| `shrink_lruvec()` | `mm/vmscan.c` | Scan and reclaim one LRU list set |

---

## Configuration (Kconfig)

Key Kconfig symbols affecting mm behaviour:

| Symbol | Effect |
|--------|--------|
| `CONFIG_SLUB` | Enable SLUB (default since v2.6.23) |
| `CONFIG_SLUB_DEBUG` | Enable SLUB red-zoning, poisoning, and tracking |
| `CONFIG_TRANSPARENT_HUGEPAGE` | Enable THP (`always` / `madvise` runtime modes) |
| `CONFIG_NUMA` | Enable multi-node NUMA support |
| `CONFIG_MEMORY_HOTPLUG` | Allow RAM add/remove at runtime |
| `CONFIG_KSM` | Enable Kernel Samepage Merging |
| `CONFIG_ZSWAP` | Compressed in-memory swap cache |
| `CONFIG_DAMON` | Data Access Monitoring framework |
| `CONFIG_HUGETLB_PAGE` | HugeTLB support |
| `CONFIG_COMPACTION` | Memory compaction (required for THP) |
| `CONFIG_PCP_BATCH_SCALE_MAX` | Cap PCP batch scaling for latency-sensitive embedded builds |
| `CONFIG_MEMCG` | Memory cgroup accounting |

---

## Recent Development Activity

### `struct folio` (v5.17+, Matthew Wilcox)
The long-running effort to replace raw `struct page` with `struct folio` — a self-describing wrapper that knows its own compound order. Eliminates an entire class of bugs where functions assumed order-0 pages but received compound pages silently. The transition is ongoing across the entire subsystem; most core paths in the page cache, reclaim, and slab now use folios.
- LWN: [Memory folios](https://lwn.net/Articles/856016/), [Clarifying memory management with page folios](https://lwn.net/Articles/849538/)

### Maple Tree for VMA management (v6.1, Liam Howlett / Oracle)
Replaced the augmented red-black tree + doubly-linked list of VMAs in `mm_struct` with a B-tree variant (maple tree) optimized for range queries and RCU reads. The new structure enables lockless VMA lookups, eliminates the VMA iterator cache (no longer needed), and is a prerequisite for per-VMA locking.
- LWN: [Introducing the Maple Tree](https://lwn.net/Articles/901714/)

### Per-VMA locking (v6.4–v6.6, Suren Baghdasaryan / Google)
Added an seqlock per `vm_area_struct` so page fault handlers can take a VMA read lock independently of `mmap_lock`. Eliminates `mmap_read_lock` from the common page-fault path entirely. Extended to cover swap faults and userfaultfd in v6.6. Measured as 0.5%+ TCP zerocopy CPU cycle reduction; mmap_lock usage dropped below 0.1% on busy systems.
- LWN: [Per-VMA locks](https://lwn.net/Articles/924572/), [VMA lock docs](https://lwn.net/Articles/997398/)

### SLOB removal (v6.4) and SLAB removal (v6.8)
The minimal embedded allocator (SLOB) was removed in v6.4 as SLUB had become efficient enough even for small systems. The original SLAB allocator was deprecated in v6.5 and removed in v6.8, leaving SLUB as the sole general-purpose slab implementation and dramatically simplifying the allocator codebase.

### THP for file-backed mappings (v6.8+)
Transparent Huge Pages were historically limited to anonymous memory. v6.8 extended THP promotion to file-backed mappings (page cache folios), reducing TLB pressure for large working-set applications like databases and JVMs.

### laptop_mode removal (v6.14, 2026)
The `laptop_mode` sysctl (delaying writeback to spin disks down) was removed after being superseded by modern storage management. The removal was discussed in the context of always allowing writeback during memcg reclaim.

### PCP high auto-tuning (v6.6, Ying Huang / Intel)
Dynamic `pcp->high` watermark adjustment per-CPU per-zone, replacing the static fraction computation. Delivered 5% kernel-build speedup and 7% netperf improvement on 224-CPU Sapphire Rapids systems.

---

## LKML Threads

| Message ID | Subject |
|-----------|---------|
| `20241114205402.859737-1-lorenzo.stoakes@oracle.com` | [PATCH v3] docs/mm: add VMA locks documentation (Lorenzo Stoakes, Oracle) |
| `20260403194526.477775-3-hannes@cmpxchg.org` | [RFC 2/2] mm: page_alloc: per-cpu pageblock buddy allocator (Johannes Weiner, Meta) |
| `20260314152536.100531-1-xaum.io@gmail.com` | [PATCH] Docs/mm: document Swap |
| `20231016053002.756205-4-ying.huang@intel.com` | [PATCH -V3 0/9] mm: PCP high auto-tuning (Ying Huang, Intel) |
| `20251216185201.GH905277@cmpxchg.org` | retiring laptop_mode discussion (Johannes Weiner) |

---

## Further Reading

1. [kernel-internals.org/mm/](https://kernel-internals.org/mm/) — Design rationale for each mm component; explains *why* decisions were made, not just mechanics
2. [kernel-internals.org/mm/life-of-malloc/](https://kernel-internals.org/mm/life-of-malloc/) — End-to-end trace of `malloc()` from glibc through page fault to physical page
3. [kernel-internals.org/mm/slab/](https://kernel-internals.org/mm/slab/) — SLAB vs SLUB vs SLOB history, SLUB design, security features
4. [docs.kernel.org/mm/index.html](https://docs.kernel.org/mm/index.html) — Official kernel mm documentation index
5. [docs.kernel.org/admin-guide/mm/concepts.html](https://docs.kernel.org/admin-guide/mm/concepts.html) — Accessible concepts overview: zones, reclaim, swap, huge pages, NUMA, OOM
6. [LWN — Memory folios](https://lwn.net/Articles/856016/) — struct folio motivation and design
7. [LWN — Introducing the Maple Tree](https://lwn.net/Articles/901714/) — VMA data structure replacement rationale
8. [LWN — Per-VMA locks](https://lwn.net/Articles/924572/) — mmap_lock scalability fix design
9. [LWN — The ongoing search for mmap_lock scalability](https://lwn.net/Articles/893906/) — Historical context on mmap_sem contention problems
10. [linux-mm.org](https://linux-mm.org/) — Community wiki, links to major historical papers and patch series
11. [Understanding the Linux VM (Gorman)](https://www.kernel.org/doc/gorman/html/understand/) — Classic in-depth reference for mm internals (pre-folio era but still accurate for fundamentals)
