---
title: "mm — Core Components"
category: subsystem
tags: [memory, mm, buddy-allocator, slub, vmalloc, vma, page-fault, reclaim, page-cache, pcp, folio]
maintainer: "Andrew Morton <akpm@linux-foundation.org>"
mailing_list: linux-mm@kvack.org
source_path: mm/
researched: 2026-04-05
status: complete
sources:
  - https://kernel-internals.org/mm/page-allocator/
  - https://kernel-internals.org/mm/slab/
  - https://kernel-internals.org/mm/slab-internals/
  - https://kernel-internals.org/mm/vmalloc/
  - https://kernel-internals.org/mm/mmap/
  - https://kernel-internals.org/mm/page-fault/
  - https://kernel-internals.org/mm/reclaim/
  - https://kernel-internals.org/mm/page-cache/
  - https://docs.kernel.org/mm/index.html
---

# mm — Core Components

A focused deep dive into the eight foundational subsystems that make up the Linux memory manager. These are the components that every other mm feature is built on top of. For a broader architectural overview see `[[mm]]`.

---

## Component Map

```
USER SPACE                   KERNEL INTERNAL
──────────────               ───────────────────────────────
malloc()                     kmalloc()      vmalloc()
  │                              │               │
  ▼                              ▼               ▼
[1] VMA / mmap              [3] SLUB       [4] vmalloc
    mm_struct                   │ cache miss     │ alloc_pages × N
    vm_area_struct              │               │
  │                              └──────┬────────┘
  │ page fault                         │
  ▼                                    ▼
[2] Page Fault Handler        [5] Per-CPU Pages (PCP)
    handle_pte_fault               hot page cache, order 0–3
      │                                │ miss
      │ alloc_zeroed_page             │
      ▼                                ▼
      └──────────────────► [6] Buddy Allocator
                                zone free lists, order 0–MAX_PAGE_ORDER
                                UNMOVABLE / MOVABLE / RECLAIMABLE
                                         │
                         ┌───────────────┴──────────────────┐
                         ▼                                  ▼
                 [7] Page Cache                  [8] Page Reclaim
                     filemap.c                      vmscan.c
                     XArray of folios               kswapd / direct reclaim
                     readahead                       LRU / MGLRU
```

---

## [1] VMA and Process Address Space (`mm/mmap.c`)

### What it does

Every process's virtual address space is described by `struct mm_struct`, which holds a **maple tree** of `struct vm_area_struct` (VMA) records. A VMA represents one contiguous virtual region with uniform protections and backing (anonymous, file, device).

### Key data structures

| Structure | Location | Role |
|-----------|----------|------|
| `struct mm_struct` | `include/linux/mm_types.h` | Per-process address space root: pgd pointer, VMA tree, stats |
| `struct vm_area_struct` | `include/linux/mm_types.h` | One VMA: `vm_start`, `vm_end`, `vm_flags`, `vm_ops`, `vm_file` |
| `struct maple_tree` | `include/linux/maple_tree.h` | B-tree (v6.1+) storing VMAs, indexed by address range |

### Maple tree (v6.1)

Before v6.1, VMAs were stored in an augmented red-black tree + doubly-linked list — two structures kept in sync. The maple tree replaced both with a single B-tree variant offering:

- **Better cache locality** — internal nodes pack multiple entries, reducing pointer-chasing
- **RCU-safe lookups** — readers can walk the tree without locks using `mt_find()` under RCU
- **Simpler code** — no separate linked list to maintain alongside the tree

### Per-VMA locking (v6.4)

The historical `mmap_lock` (an rwsem on `mm_struct`) serialized all VMA reads and writes. On busy multi-threaded workloads this became a bottleneck: all page faults across all VMAs queued behind a single rwsem.

Per-VMA locks add an `seqlock`-like mechanism directly on `vm_area_struct`. The common page-fault path now:
1. Tries `lock_vma_under_rcu()` — acquires the VMA's read side without `mmap_lock`
2. Validates the VMA is still valid and covers the fault address
3. Handles the fault under VMA lock alone

Result: concurrent page faults on *different* VMAs proceed in parallel. `mmap_lock` usage dropped below 0.1% of CPU cycles on busy systems; TCP zerocopy saw ~0.5% CPU reduction.

### mmap / munmap lifecycle

```
mmap(NULL, size, PROT_RW, MAP_ANON|MAP_PRIVATE, -1, 0)
  └─► do_mmap()
        └─► mmap_region()
              ├── find_free_area()          // scan maple tree for gap
              ├── vma_alloc_folio()         // allocate new VMA
              ├── vma_merge() if possible   // merge with adjacent VMAs
              └── insert into maple tree
  → returns virtual address; NO physical pages yet
```

Physical pages are allocated lazily on first access via page faults (see Component 2).

---

## [2] Page Fault Handler (`mm/memory.c`)

### Entry and dispatch

```
CPU raises #PF exception
  └─► exc_page_fault()              // arch/x86/mm/fault.c
        └─► do_user_addr_fault()
              ├── find VMA (maple tree or per-VMA lock RCU)
              ├── check permissions
              └─► handle_mm_fault()
                    └─► handle_pte_fault()   // THE decision point
```

`handle_pte_fault()` inspects the current PTE state and routes to one of:

| PTE state | Handler | Action |
|-----------|---------|--------|
| No PTE, anonymous VMA | `do_anonymous_page()` | Allocate zeroed page, install PTE |
| No PTE, file-backed VMA | `do_fault()` → `do_read_fault()` | Demand-load from page cache |
| Write to read-only PTE | `do_wp_page()` | COW: copy or reuse page |
| PTE present but swapped | `do_swap_page()` | Restore from swap device |
| Huge PMD | `do_huge_pmd_anonymous_page()` | THP fast path |

### Anonymous page allocation (`do_anonymous_page`)

Read faults on anonymous (heap/stack) pages return the **shared zero page** — a single read-only physical page mapped into many processes. No allocation occurs. Only a write triggers actual allocation:

```c
// Simplified do_anonymous_page (write path):
page = alloc_zeroed_user_highpage_movable(vma, addr);  // from PCP/buddy
entry = mk_pte(page, vma->vm_page_prot);
set_pte_at(mm, addr, pte, entry);
```

### Copy-on-write (`do_wp_page`)

When a process writes to a shared (or post-fork) page, the kernel checks the page reference count:
- **`page_count == 1`** (process is sole owner): flip the PTE to writable in-place — `wp_page_reuse()`, no copy
- **`page_count > 1`** (shared): `wp_page_copy()` — allocate new page, copy content, update PTE, drop reference on old page

---

## [3] SLUB Slab Allocator (`mm/slub.c`)

### Why not raw pages?

Kernel objects are tiny compared to 4 KB pages. A `struct dentry` (~200 bytes) would waste 95% of a page. SLUB carves pages into typed caches of fixed-size objects, eliminating this waste.

### Architecture

```
kmalloc(192, GFP_KERNEL)
  └─► kmalloc-192 cache (pre-created power-of-2 size class)
        └─► Per-CPU slab (struct kmem_cache_cpu)
              ├── freelist pointer (XOR-hardened)
              └─► cmpxchg fast path (lockless!)
                    │ miss (slab exhausted)
                    ▼
              Per-node partial list (struct kmem_cache_node)
                    │ empty
                    ▼
              __alloc_pages() → new slab page from buddy
```

### Per-CPU lockless fast path

Each CPU holds a pointer to a "current" slab page. The freelist is a singly-linked list of free objects within that page. Allocation is a single `cmpxchg`:

```c
// Simplified fast path:
void *object = this_cpu_read(s->cpu_slab->freelist);
if (likely(object && cmpxchg(&cpu_slab->freelist, object, next_free)))
    return object;
// else: slow path
```

The `tid` (transaction ID) field prevents ABA races when interrupted between reading the freelist and the cmpxchg.

### Size classes and kvmalloc

`kmalloc()` uses pre-created power-of-2 caches: 8, 16, 32, 64, 96, 128, 192, 256, 512, 1024, 2048, 4096, 8192 bytes. A 100-byte request uses `kmalloc-128`, wasting 28 bytes.

`kvmalloc(size, gfp)` tries `kmalloc()` first; if that fails (too large or fragmentation), falls back to `vmalloc()`. Useful when size varies widely.

### Security hardening

| Feature | Kconfig | Effect |
|---------|---------|--------|
| Freelist pointer XOR | `CONFIG_SLAB_FREELIST_HARDENED` | Corrupting freelist requires knowing a secret cookie |
| Freelist randomization | `CONFIG_SLAB_FREELIST_RANDOM` | Initial freelist order randomized per slab |
| Poisoning | `CONFIG_SLUB_DEBUG` | Write magic bytes to freed objects; detect use-after-free |
| Red zones | `CONFIG_SLUB_DEBUG` | Guard bytes detect buffer overflows at object boundaries |
| KFENCE | `CONFIG_KFENCE` | Sampling-based detector safe for production; catches UAF/OOB |
| init_on_alloc/free | `init_on_alloc=1` | Zero memory on alloc or free (security/leak prevention) |

### History

- v2.6.22 (2007): SLUB introduced, replaced SLAB as default
- v6.4: SLOB (minimal embedded allocator) removed
- v6.8: Original SLAB removed — SLUB is now the only implementation

---

## [4] vmalloc — Virtually-Contiguous Allocator (`mm/vmalloc.c`)

### When to use

| Allocator | Contiguity | Size limit | Performance | Use case |
|-----------|-----------|------------|-------------|----------|
| `kmalloc` | Physical + virtual | ~8 MB practical | Fastest | Kernel objects, DMA |
| `vmalloc` | Virtual only | Very large | Slower | Module loading, large buffers |
| `kvmalloc` | Either | Large | Adaptive | When size is uncertain |

### How it works

```
vmalloc(size)
  ├── Find free range in kernel vmalloc space (RB-tree of vmap_area)
  ├── alloc_pages(GFP_KERNEL) × ceil(size/PAGE_SIZE)  // non-contiguous!
  ├── map_kernel_range() — install PTEs into kernel page tables
  └── return virtual address of first page
```

Physical pages can be scattered across all of RAM; only their virtual addresses are contiguous. Extra TLB entries are required (one per page vs. one per large allocation for kmalloc), adding minor overhead on access.

### Key data structures

| Structure | Role |
|-----------|------|
| `struct vmap_area` | Tracks one vmalloc region: `[va_start, va_end)`, linked into RB-tree |
| `struct vm_struct` | Metadata for a vmalloc allocation: pages array, size, flags |
| `vmap_area_root` | Global RB-tree of all vmalloc regions (O(log n) lookup) |

The RB-tree was introduced in v2.6.28, replacing an O(n) linked-list that became slow with thousands of loadable modules.

### Guard pages

Each vmalloc region ends with an unmapped guard page. A buffer overflow writes to the guard page, triggering an immediate `#PF` and kernel panic — silent corruption of adjacent allocations is prevented.

### Lazy TLB flushing (v2.6.28)

Freeing a vmalloc region requires TLB invalidation across all CPUs (expensive IPI). The kernel batches multiple `vfree()` calls and flushes all at once with a single IPI storm, amortizing the cost.

---

## [5] Per-CPU Page Allocator / PCP (`mm/page_alloc.c`)

### Purpose

A caching layer between the slow-path buddy allocator (which takes `zone->lock`) and the hot allocation paths (anonymous faults, slab cache misses). Each CPU maintains a local list of already-allocated pages per zone, serving most order-0 allocs and frees without any lock.

### Data structures

```c
struct per_cpu_pages {
    spinlock_t  lock;
    int         count;          // current pages in list
    int         high;           // drain threshold (auto-tuned v6.6)
    int         batch;          // refill/drain batch size
    struct list_head lists[NR_PCP_LISTS]; // per-order, per-migratetype
};
```

`NR_PCP_LISTS` covers orders 0 through `PAGE_ALLOC_COSTLY_ORDER` (typically 3) × 3 migrate types.

### Allocation fast path

```
__alloc_pages(gfp, order=0, zone)
  └─► get_page_from_freelist()
        └─► rmqueue()
              └─► rmqueue_pcplist()         // lock-free per-CPU list
                    │ list empty → refill from buddy (batch pages)
                    └── return page
```

### Drain on memory pressure

When kswapd or direct reclaim needs to surface pages, `drain_all_pages()` triggers per-CPU drains: each CPU flushes its PCP lists back to the buddy allocator's free areas.

### PCP high auto-tuning (v6.6, Ying Huang / Intel)

Previously, `pcp->high` was a static fraction of zone size. v6.6 made it dynamic: the kernel measures how often PCP lists are drained and tunes `high` to amortize drains while not holding too many pages off the buddy. Result: **5% kernel-build speedup**, **7% netperf improvement** on 224-CPU Sapphire Rapids.

---

## [6] Buddy Allocator — Physical Page Management (`mm/page_alloc.c`)

### Algorithm

Physical memory is divided into power-of-2 blocks called **orders** (order 0 = 1×4KB page, order 10 = 1024×4KB = 4MB). Each zone maintains a `free_area[MAX_PAGE_ORDER+1]` array of free lists.

**Allocation:** find the smallest available order ≥ requested order. If exact match, return it. Otherwise split the larger block into two "buddies" of half the size; put one on the lower free list, return the other. Recurse until the right order is obtained.

**Free:** when a block is freed, look up its "buddy" (the adjacent block of the same size at the complementary offset). If the buddy is also free, merge both into a higher-order block and repeat upward.

### Zone hierarchy

| Zone | Typical range (x86-64) | Purpose |
|------|------------------------|---------|
| `ZONE_DMA` | 0–16 MB | Legacy ISA DMA devices |
| `ZONE_DMA32` | 0–4 GB | 32-bit PCI DMA |
| `ZONE_NORMAL` | 4 GB+ | Normal kernel/user pages |
| `ZONE_MOVABLE` | Configured at boot | Hot-pluggable pages (memory tiering) |

NUMA systems have one `pglist_data` per node, each containing the applicable zones.

### Migration types

Each order's free list is further split by **migration type**, preventing fragmentation by grouping pages that can be moved together:

| Type | Who uses it | Can be migrated? |
|------|-------------|-----------------|
| `MIGRATE_UNMOVABLE` | Kernel allocations | No |
| `MIGRATE_MOVABLE` | User pages, file-backed | Yes (by compaction) |
| `MIGRATE_RECLAIMABLE` | Page cache, slab | Can be reclaimed |
| `MIGRATE_HIGHATOMIC` | Reserved for atomic allocs | No |
| `MIGRATE_CMA` | Contiguous Memory Allocator | Yes |
| `MIGRATE_ISOLATE` | Pages being migrated | Temporarily isolated |

Migration types enable **memory compaction**: movable pages can be relocated to one end of a zone, freeing large contiguous blocks for THP and high-order kernel allocations.

### GFP flags

GFP (Get Free Pages) flags are the "what can the allocator do?" knob:

| Flag | Meaning |
|------|---------|
| `GFP_KERNEL` | Can sleep, can call reclaim, normal kernel allocation |
| `GFP_ATOMIC` | Cannot sleep (interrupt/spinlock context), uses reserves |
| `GFP_NOWAIT` | No sleep, no reclaim — fail fast |
| `GFP_USER` | User-facing allocation |
| `GFP_DMA` / `GFP_DMA32` | Must come from DMA-accessible zone |
| `__GFP_ZERO` | Zero-fill the page(s) before returning |
| `__GFP_NOFAIL` | Must succeed; will retry indefinitely |
| `__GFP_MOVABLE` | Hint: use MOVABLE migratetype |

### Allocation slow path

When PCP and free lists at the requested order are exhausted:

```
__alloc_pages_slowpath()
  ├── wake kswapd (async reclaim)
  ├── try lower-order free lists + split
  ├── steal from different migratetype list
  ├── direct reclaim (synchronous)
  ├── memory compaction
  └── OOM kill if all else fails
```

---

## [7] Page Cache (`mm/filemap.c`, `mm/readahead.c`)

### Role

The page cache is the kernel's unified read/write buffer for all block-backed files. When a process reads a file, pages are fetched from disk into the page cache; subsequent reads serve the same physical pages from RAM. Writes update cached pages; writeback threads periodically flush dirty pages to disk.

### Data structures

```
struct address_space           // per inode
  └── struct xarray i_pages    // XArray of struct folio *
        └── struct folio       // one or more contiguous pages of file data
              ├── page[]       // the actual page(s)
              ├── flags        // dirty, writeback, uptodate, locked
              └── mapping      // back-pointer to address_space
```

The **XArray** (v4.20, Matthew Wilcox) replaced the radix tree. It provides the same O(log n) indexed access but with a simpler API and better cache behavior.

**`struct folio`** (v5.16+) replaced raw `struct page` for page-cache operations. A folio knows its own order (can represent multiple contiguous pages), enabling the kernel to handle large page-cache entries (e.g., 2 MB THP file mappings in v6.8) without treating them as N independent order-0 pages.

### Lookup and demand loading

```
read(fd, buf, len)
  └─► vfs_read() → generic_file_read_iter()
        └─► filemap_read()
              ├── find_get_folio() — check XArray for cached page
              │     hit  → copy to userspace directly
              │     miss → readahead + wait
              └─► page_cache_sync_readahead()
                    └─► aops->readpage() / readpages() — submit I/O
```

### Readahead

The kernel tracks sequential access patterns per file and prefetches additional pages ahead of the current read position. `mm/readahead.c` maintains a per-file readahead state (`file_ra_state`): when sequential access is detected, it issues readahead I/O for the next `ra->size` pages.

### Writeback

Dirty pages are written back by kernel threads (`writeback/N`) managed by `mm/page-writeback.c`. Writeback fires when:
- Dirty ratio (`vm.dirty_ratio`) of total RAM is dirty (synchronous throttling)
- Background ratio (`vm.dirty_background_ratio`) is reached (async writeback)
- A page has been dirty for longer than `vm.dirty_expire_centisecs`

---

## [8] Page Reclaim — kswapd and Direct Reclaim (`mm/vmscan.c`)

### Watermarks

Each zone maintains three watermarks derived from `vm.min_free_kbytes`:

```
free pages:  ████████ high | ██████ low | ████ min
                     ↑           ↑          ↑
                  healthy     kswapd      direct reclaim
                              wakes up    blocks alloc
```

### kswapd — background reclaim

One `kswapd` daemon per NUMA node. It wakes when free pages fall below the `low` watermark and reclaims until the `high` watermark is restored. Crucially, it runs asynchronously — allocating threads don't block.

### Direct reclaim — synchronous path

If kswapd hasn't kept up and an allocation fails watermark checks at the `min` level, the allocating process enters `try_to_free_pages()` and reclaims synchronously before retrying. This is the "direct reclaim" latency hit visible in perf profiles.

### LRU lists

The kernel tracks page "temperature" via LRU lists. Historically four lists per node:
- `LRU_INACTIVE_ANON`, `LRU_ACTIVE_ANON` — anonymous (heap/stack) pages
- `LRU_INACTIVE_FILE`, `LRU_ACTIVE_FILE` — file-backed pages

Pages enter the inactive list; accessing them twice promotes to active. Reclaim always drains the inactive list first.

### Multi-Gen LRU (MGLRU, v6.1, Yu Zhao / Google)

MGLRU replaced the two-list model with **generations** — time-banded buckets of pages. Each page carries a generation number assigned at fault time. The reclaim path always evicts the oldest generation.

Advantages:
- Finer age resolution than binary active/inactive
- Better resistance to streaming workloads that thrash the inactive list
- Configurable `min_ttl_ms` to protect hot pages from premature eviction

### What gets reclaimed

| Page type | Reclaim action |
|-----------|---------------|
| Clean file page | Drop immediately (re-readable from disk) |
| Dirty file page | Write back, then drop |
| Anonymous page (swap enabled) | Write to swap slot, then drop |
| Anonymous page (no swap) | Cannot reclaim; only OOM kill helps |
| Slab cache (dentry, inode) | Call registered `shrinker` callbacks |

### OOM killer (`mm/oom_kill.c`)

Last resort when all reclaim paths fail. Scores every process with an `oom_score` (0–1000) based on RSS, swap usage, and the user-configured `oom_score_adj` (-1000 to +1000). Sends `SIGKILL` to the highest scorer. Cgroup-aware: with `memory.oom.group`, kills the entire cgroup rather than a single process.

---

## Interaction Diagram — Allocation Flow

```
kmalloc(200)                alloc_pages(GFP_KERNEL, 0)
     │                               │
     ▼                               │
[SLUB] per-CPU fast path             │
     │ cache hit ──────────────────── │ ──► return object
     │ miss                           ▼
     └──────────────► [PCP] rmqueue_pcplist()
                           │ hit ──────────────► return page
                           │ miss
                           ▼
                      [Buddy] zone free_area[order]
                           │ hit ──────────────► split + return
                           │ miss
                           ▼
                      slow path: kswapd + reclaim + compaction
                           │ still fail
                           ▼
                        OOM kill
```

---

## Key Source Files

| File | Component | Key functions |
|------|-----------|---------------|
| `mm/page_alloc.c` | Buddy + PCP | `__alloc_pages()`, `rmqueue()`, `free_unref_page()` |
| `mm/slub.c` | SLUB | `kmem_cache_alloc()`, `slab_alloc_node()`, `__slab_free()` |
| `mm/vmalloc.c` | vmalloc | `vmalloc()`, `vmap()`, `__vmalloc_node()` |
| `mm/mmap.c` | VMA management | `mmap_region()`, `find_vma()`, `do_vmi_align_munmap()` |
| `mm/memory.c` | Page fault | `handle_pte_fault()`, `do_anonymous_page()`, `do_wp_page()` |
| `mm/filemap.c` | Page cache | `filemap_read()`, `add_to_page_cache_lru()` |
| `mm/vmscan.c` | Reclaim | `kswapd()`, `try_to_free_pages()`, `shrink_lruvec()` |
| `mm/compaction.c` | Compaction | `compact_zone()`, `kcompactd()` |
| `include/linux/mmzone.h` | Zone/node structs | `struct zone`, `struct pglist_data`, `struct free_area` |
| `include/linux/mm_types.h` | Core types | `struct mm_struct`, `struct vm_area_struct`, `struct folio` |

---

## Further Reading

1. [kernel-internals.org/mm/page-allocator/](https://kernel-internals.org/mm/page-allocator/) — Buddy system design, migration types, GFP flags
2. [kernel-internals.org/mm/slab/](https://kernel-internals.org/mm/slab/) — SLUB design, per-CPU slabs, size classes, kvmalloc
3. [kernel-internals.org/mm/slab-internals/](https://kernel-internals.org/mm/slab-internals/) — SLUB fast path internals, cmpxchg allocation
4. [kernel-internals.org/mm/vmalloc/](https://kernel-internals.org/mm/vmalloc/) — vmalloc design, RB-tree, guard pages, lazy TLB
5. [kernel-internals.org/mm/mmap/](https://kernel-internals.org/mm/mmap/) — Process address space, VMA maple tree, demand paging, COW
6. [kernel-internals.org/mm/page-fault/](https://kernel-internals.org/mm/page-fault/) — handle_pte_fault dispatch, anonymous/file/swap/COW paths
7. [kernel-internals.org/mm/reclaim/](https://kernel-internals.org/mm/reclaim/) — kswapd, LRU, MGLRU, direct reclaim, watermarks
8. [kernel-internals.org/mm/life-of-malloc/](https://kernel-internals.org/mm/life-of-malloc/) — End-to-end trace of malloc through all these layers
9. [docs.kernel.org/mm/index.html](https://docs.kernel.org/mm/index.html) — Official kernel mm documentation index
