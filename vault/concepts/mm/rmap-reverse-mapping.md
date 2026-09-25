---
title: "Reverse Mapping (rmap)"
category: concept
tags: [mm, rmap, anonymous-memory, page-reclaim, vma]
subsystem: mm
kernel_version: "2.5.27 (initial); 2.6.7 (objrmap/anon_vma); 2.6.34 (anon_vma_chain)"
researched: 2026-04-10
status: complete
explained: "[[rmap-reverse-mapping-explained]]"
sources:
  - https://lwn.net/Articles/383162/
  - https://lwn.net/Articles/75198/
  - https://lwn.net/Articles/23732/
  - https://lwn.net/Articles/77106/
  - https://lwn.net/Articles/85908/
  - https://github.com/torvalds/linux/blob/master/include/linux/rmap.h
  - https://github.com/torvalds/linux/blob/master/mm/rmap.c
  - https://android.googlesource.com/kernel/common/+/bcmdhd-3.10/mm/rmap.c
  - https://docs.kernel.org/mm/process_addrs.html
---

# Reverse Mapping (rmap)

> 📘 Plain-language version: [[rmap-reverse-mapping-explained]]

## Purpose

Reverse mapping answers the question: *given a physical page, which page table entries (PTEs) reference it?* The kernel needs this answer whenever it wants to reclaim a page (swap it out), migrate it to a different NUMA node, or perform copy-on-write accounting. Without rmap, the only way to find all PTEs for a page would be to scan every process's entire page table — O(processes × address-space-size) and completely impractical.

## Mental Model

Think of rmap as an index on a many-to-many relationship. A physical page can appear at many virtual addresses (via fork, shared mappings, or KSM). Each virtual address lives in a VMA, and each VMA belongs to a process. rmap maintains a lightweight side table that lets the kernel jump directly from a `struct page` (or `struct folio`) to the set of VMAs that contain it, without scanning anything.

## How It Works

### The Two Worlds: File-Backed vs. Anonymous

The kernel maintains rmap differently depending on whether a page is file-backed or anonymous, because file-backed pages already have a natural organizing structure — the `address_space` — while anonymous pages (heap, stack, private mappings post-COW) have no backing object at all.

**File-backed rmap** is the simpler case. The `struct address_space` embedded in every inode carries an `i_mmap` field, which is an interval tree of every `vm_area_struct` that maps into this file. The tree is keyed by file offset (pgoff). To reverse-map a file page: lock `i_mmap_rwsem`, look up the page's pgoff in the interval tree, and you immediately have the set of VMAs. No per-page overhead; the cost scales with the number of VMAs, not the number of pages.

A `MAP_PRIVATE` file mapping that has been dirtied (making the page anonymous via COW) can end up in *both* trees simultaneously: still in `i_mmap` because the VMA was originally file-backed, and also linked through the `anon_vma` chain for the COW copy. `rmap_walk_file()` handles the former; `rmap_walk_anon()` handles the latter.

**Anonymous rmap** is the harder problem and the one that drove years of kernel design work.

### Setting Up Anonymous rmap: anon_vma_prepare

When a process first faults an anonymous page into a VMA, the kernel calls `anon_vma_prepare()`. This function checks whether the VMA already has an `anon_vma` pointer (set by a previous fault or fork). If not, it allocates a fresh `struct anon_vma`, creates an `anon_vma_chain` linking this VMA to the new `anon_vma`, and stores the `anon_vma` pointer in `vma->anon_vma`. An important optimization: if an adjacent VMA in the same process already has an `anon_vma` with no children, `anon_vma_prepare` reuses it, avoiding a needless allocation.

Once the VMA has an `anon_vma`, the page fault handler calls `page_add_anon_rmap()` (or the folio-aware `folio_add_anon_rmap_pte()`). This sets the page's `mapping` field to point to the `anon_vma` with bit 0 set — the set bit distinguishes anonymous from file mappings, where `mapping` points to an `address_space` with bit 0 clear. The page's `index` field records the virtual page frame number (VPN) within the VMA, enabling the interval-tree lookup later.

### Fork and the anon_vma_chain

`fork()` is where rmap complexity concentrates. When a process forks, the child receives COW copies of all anonymous VMAs. At this point, neither parent nor child has actually made a private copy of most pages — the physical pages are still shared. Yet if the kernel later needs to reclaim one of those shared pages, it must be able to find *both* the parent's PTE and the child's PTE.

`anon_vma_fork()` handles this. For each anonymous VMA cloned into the child, it:
1. Allocates a new `anon_vma` for the child VMA.
2. Allocates an `anon_vma_chain` linking the child's VMA to its own new `anon_vma`.
3. Allocates another `anon_vma_chain` linking the child's VMA *back* to the parent's `anon_vma` as well.

This means a page that originated in the parent still points to the parent's `anon_vma`, but the interval tree rooted at the parent's `anon_vma` now contains entries for both the parent VMA and all child VMAs in the overlapping address range. The `root` pointer in every `anon_vma` walks up to the oldest ancestor in the hierarchy, ensuring the hierarchy is anchored to an object that will outlive all descendant processes.

### The Interval Tree Lookup

The core of the lookup uses a **red-black interval tree**. Each `anon_vma_chain` is a node in the `anon_vma->rb_root` interval tree, keyed by the VMA's `[vm_pgoff, vm_pgoff + vma_pages)` range. When the kernel needs to reverse-map a page:

1. Retrieve the page's `anon_vma` from `page->mapping` (masking off bit 0).
2. Lock the `anon_vma->rwsem` for reading.
3. Use `anon_vma_interval_tree_foreach(avc, &anon_vma->rb_root, pgoff, pgoff)` to iterate over all `anon_vma_chain` entries whose interval contains the page's pgoff.
4. Each matched `anon_vma_chain` gives a `vma` pointer. Check `vma->vm_start + (pgoff - vma->vm_pgoff) * PAGE_SIZE` to get the virtual address, then look up the PTE in that VMA's page tables.

This is O(log N + k) where N is the number of VMAs in the tree and k is the number of matches — a huge improvement over the old O(N) linear scan.

### Walking the rmap: folio_referenced and try_to_unmap

The two primary callers of rmap are `folio_referenced()` (called from `mm/vmscan.c` during page reclaim) and `try_to_unmap()` (called when a page must be completely unmapped before being reclaimed or migrated).

Both dispatch through `rmap_walk()`, passing a `struct rmap_walk_control` that describes the callback to run on each matching VMA. For anonymous pages, `rmap_walk_anon()` does the interval-tree traversal. For file pages, `rmap_walk_file()` iterates over `address_space->i_mmap`.

**`folio_referenced()`**: For each PTE found, it checks the PTE's Accessed/Young bit. If set, the bit is cleared and a reference count incremented. The total reference count is returned to vmscan, which uses it to decide how "hot" the page is. A page with many recent references is placed back on the active list; one with no references advances toward reclaim.

**`try_to_unmap()`**: For each PTE found, it calls `try_to_unmap_one()`, which:
1. Flushes the TLB for that address.
2. Clears the PTE (making it a swap entry or zeroing it).
3. Decrements the page's `_mapcount`. When `_mapcount` reaches -1, the page has no remaining mappings and can be freed or written to swap.

`struct rmap_walk_control` has an `invalid_vma` callback to skip VMAs that are locked or otherwise inaccessible, and a `done` callback to stop early once a goal (e.g. all PTEs cleared) is reached.

### The Scalability Crisis and anon_vma_chain Fix

The original `anon_vma` design (2.6.7) had all forked VMAs share the *same* parent `anon_vma`. This worked well for small fork trees but collapsed under load: a workload with 1,000 child processes each having a VMA with 1,000 anonymous pages resulted in 1,000,000 pages all in the same `anon_vma`. Reclaiming any one of them required scanning all 1,000,000 entries while holding the `anon_vma` lock — catastrophic serialization under memory pressure.

Rik van Riel's 2010 fix (merged ~2.6.34) introduced `anon_vma_chain` as a separate glue structure, giving each VMA its own `anon_vma` while still maintaining parent-child linkage. Crucially, each `anon_vma_chain` in the interval tree knows its exact pgoff range, so the tree lookup immediately filters to only VMAs that could possibly contain the target page. The O(N) scan became O(log N + k).

A subtle follow-on bug discovered during review: if a parent maps a page, both parent and child share it, then the child unmaps it and exits, the page could end up referencing the (now-freed) child's `anon_vma`. The fix is to always prefer the highest-ancestor `anon_vma` when linking a page — the `root` pointer guarantees the target structure outlives all descendants.

## Key Data Structures

**`struct anon_vma`** (`include/linux/rmap.h`) — anchor for a set of VMAs that share anonymous pages.
- `root` — `struct anon_vma *`; points to the oldest ancestor in the process hierarchy; used to pick a stable target when linking pages
- `rwsem` — `struct rw_semaphore`; protects the interval tree and list traversal
- `refcount` — `atomic_t`; drops to zero only when both the VMA and all pages linked to this anon_vma are gone
- `num_children` — `unsigned long`; count of child anon_vmas (i.e. forked descendants)
- `num_active_vmas` — `unsigned long`; count of VMAs currently pointing to this anon_vma
- `parent` — `struct anon_vma *`; direct parent in the fork hierarchy
- `rb_root` — `struct rb_root_cached`; root of the interval tree of `anon_vma_chain` nodes

**`struct anon_vma_chain`** (`include/linux/rmap.h`) — one-to-many glue between a VMA and the anon_vmas it participates in.
- `vma` — `struct vm_area_struct *`; the VMA this entry represents
- `anon_vma` — `struct anon_vma *`; the anon_vma this entry links into
- `rb` — `struct rb_node`; node in `anon_vma->rb_root` interval tree, keyed by pgoff range
- `same_vma` — `struct list_head`; node on `vma->anon_vma_chain` list, allowing a VMA to track all anon_vmas it is linked into

**`struct rmap_walk_control`** (`include/linux/rmap.h`) — parameterises an rmap walk.
- `rmap_one` — callback invoked on each (folio, vma, address, flags) tuple; returns `true` to continue, `false` to stop
- `done` — optional early-exit predicate called after each VMA
- `anon_lock` — function to acquire the anon_vma lock (allows callers to customise locking strategy)
- `invalid_vma` — predicate to skip uninteresting VMAs

**`struct vm_area_struct`** (rmap-relevant fields):
- `anon_vma` — `struct anon_vma *`; non-NULL for anonymous or COW VMAs
- `anon_vma_chain` — `struct list_head`; list of all `anon_vma_chain` entries linking this VMA into various anon_vmas

**`struct address_space`** (rmap-relevant fields):
- `i_mmap` — `struct rb_root_cached`; interval tree of VMAs mapping this file, keyed by file offset; used for file-backed rmap
- `i_mmap_rwsem` — `struct rw_semaphore`; protects `i_mmap`

## Key Functions / Entry Points

**`anon_vma_prepare()`** (`mm/rmap.c`) — called on first anonymous fault in a VMA; allocates an `anon_vma` (or reuses a neighbour's), creates the initial `anon_vma_chain` linking the VMA in, stores pointer in `vma->anon_vma`.

**`anon_vma_fork()`** (`mm/rmap.c`) — called by `dup_mmap()` during `fork()`; creates a child `anon_vma` and two `anon_vma_chain` entries: one for the child's own anon_vma, one linking back to the parent's, so the parent's interval tree covers the child's VMA range.

**`folio_add_anon_rmap_pte()`** (`mm/rmap.c`) — called after installing a PTE for an anonymous page; sets `folio->mapping` to the anon_vma (with bit 0 set), records pgoff in `folio->index`, increments `_mapcount`.

**`folio_add_file_rmap_pte()`** (`mm/rmap.c`) — file-backed equivalent; increments `_mapcount` only (the `i_mmap` tree already handles reverse lookup).

**`folio_referenced()`** (`mm/rmap.c`) — called by vmscan's `shrink_active_list()`; walks all PTEs via `rmap_walk()`, clears Accessed bits, returns access count to inform LRU placement.

**`try_to_unmap()`** (`mm/rmap.c`) — called by reclaim/migration before a page can be freed; walks all PTEs, clears each one (installing a swap entry if needed), returns `SWAP_SUCCESS` when `_mapcount` reaches -1.

**`try_to_migrate()`** (`mm/rmap.c`) — variant used by page migration (`migrate_pages()`); similar to `try_to_unmap` but installs migration PTEs rather than swap entries, allowing the page to be moved while remaining accessible to faulting processes.

**`rmap_walk()`** (`mm/rmap.c`) — generic dispatcher; inspects `folio->mapping` bit 0 to choose `rmap_walk_anon()` or `rmap_walk_file()`.

**`rmap_walk_anon()`** (`mm/rmap.c`) — locks `anon_vma->rwsem`, iterates `anon_vma_interval_tree_foreach()` over the rb_root, invokes `rwc->rmap_one` on each matching VMA.

**`rmap_walk_file()`** (`mm/rmap.c`) — locks `address_space->i_mmap_rwsem`, iterates `vma_interval_tree_foreach()` over `i_mmap`, invokes `rwc->rmap_one` on each matching VMA.

## Important Flags & Config Options

**`CONFIG_MMU`** — rmap is only compiled when an MMU is present; nommu builds skip all of `mm/rmap.c`.

**`TTU_*` flags** (Try To Unmap flags, `include/linux/rmap.h`):
- `TTU_SPLIT_HUGE_PMD` — split a THP PMD into PTEs before unmapping, required when the caller cannot handle compound pages
- `TTU_IGNORE_MLOCK` — bypass `VM_LOCKED` VMAs (used by OOM killer)
- `TTU_BATCH_FLUSH` — collect TLB flushes and batch them rather than flushing per-PTE (significant performance gain on large mappings)
- `TTU_RMAP_LOCKED` — caller already holds the anon_vma lock; skip re-acquisition
- `TTU_ZERO_FOLIO` — added recently; for folios that are all-zero, allow clearing the PTE without installing a swap entry

**`/proc/sys/vm/`** — no dedicated sysctl for rmap tuning, but `swappiness` and `page-cluster` indirectly control how aggressively vmscan calls `try_to_unmap`.

## Interactions with Other Subsystems

- **↑ Userspace**: `mmap()`, `brk()`, and `fork()` syscalls trigger `anon_vma_prepare()` and `anon_vma_fork()`; userspace never calls rmap directly.
- **→ [[page-reclaim]]**: vmscan calls `folio_referenced()` and `try_to_unmap()` on every candidate page; rmap is the critical path for all reclaim decisions.
- **→ [[memory-compaction]]**: compaction uses `try_to_migrate()` to temporarily unmap pages before moving them to contiguous physical frames.
- **→ [[transparent-huge-pages]]**: THP walks rmap on compound folios; `TTU_SPLIT_HUGE_PMD` is used when a PMD-mapped huge page must be unmapped but the caller needs PTE granularity.
- **← [[page-fault-handler]]**: installs PTEs and calls `folio_add_anon_rmap_pte()` to register the new mapping.
- **← KSM** (`mm/ksm.c`): uses `rmap_walk()` to find all copies of a page being merged, then updates PTEs to point at the shared KSM page.
- **← [[swap]]**: swapout uses `try_to_unmap()` to strip all PTEs before writing the page to swap device; swapin re-establishes the mapping via `folio_add_anon_rmap_pte()`.

## Design Decisions & Tradeoffs

**Per-page chains vs. object-based rmap**: The very first rmap implementation (2.5.27, Andrea Arcangeli) stored a singly-linked list of PTEs directly in each `struct page`. This was O(1) for unmap but consumed enormous amounts of lowmem on 32-bit systems. The shift to object-based rmap (objrmap, 2.6.7) traded per-page overhead for per-VMA overhead — one VMA covers thousands of pages, so the amortized cost is far lower, at the price of making the lookup O(k) where k = number of matching VMAs.

**Why separate anon and file paths?** File-backed pages already have `address_space` as a natural anchor; adding a second rmap mechanism would be redundant. Anonymous pages have no backing object, making `anon_vma` necessary. The asymmetry is load-bearing: file pages use a simpler, cheaper path.

**The `mapping` field bit-encoding**: Using bit 0 to distinguish anon vs. file and bit 1 for KSM is an intentional space optimization — every `struct page` (now `struct folio`) already has a `mapping` pointer, and pointer alignment guarantees the low bits are free. The alternative (a separate `page_type` field) was rejected to avoid bloating the already-tight page descriptor.

**Interval trees vs. linked lists**: Before ~4.5, both `anon_vma` and `i_mmap` used sorted linked lists. Interval trees reduce lookup from O(N) to O(log N + k) at the cost of more complex insertion/deletion. The change was driven by workloads with thousands of VMAs (Java applications, containers).

**Lock ordering**: `anon_vma->rwsem` is always acquired before `vma->vm_mm->mmap_lock` (read). Violating this ordering causes deadlocks; this constraint is enforced by comments and lockdep annotations throughout `mm/rmap.c`.

## How It Has Evolved

**2.5.27 (2002)**: First rmap — per-page linked list of PTE addresses. Functional but memory-expensive. Enabled anonymous page swapping without scanning all page tables.

**2.6.0–2.6.6**: Various attempts to shrink rmap overhead (pte_chain, objrmap proposals). Memory pressure on 32-bit systems with lots of RAM made the original design untenable.

**2.6.7 (2004)**: Major redesign. File pages got object-based rmap via `i_mmap`. Anonymous pages got `anon_vma` (Linus's design). Per-page PTE chains eliminated. Memory usage dropped dramatically.

**~2.6.34 (2010)**: Rik van Riel's `anon_vma_chain` fix. Introduced per-VMA `anon_vma` structs chained together, replacing the shared-parent single-`anon_vma` model. Solved O(N) scanning in fork-heavy workloads. Required careful hierarchy reasoning to avoid dangling references (root pointer convention).

**~4.5 (2016)**: Interval trees replace linked lists in both `anon_vma->rb_root` and `address_space->i_mmap`. Lookup complexity improved to O(log N + k).

**5.x–6.x (folio era)**: `struct page`-based APIs (`page_referenced`, `try_to_unmap`, `page_add_anon_rmap`) progressively replaced with folio-aware variants (`folio_referenced`, `try_to_unmap` operating on folios, `folio_add_anon_rmap_pte/pmd/pud`). This supports large folios spanning multiple physical pages with a single mapcount and rmap entry, avoiding per-page overhead for THP.

## Further Reading

1. [The case of the overly anonymous anon_vma — LWN (2010)](https://lwn.net/Articles/383162/) — best explanation of the scalability crisis and the anon_vma_chain fix
2. [Virtual Memory II: the return of objrmap — LWN (2004)](https://lwn.net/Articles/75198/) — background on the 2.6.7 redesign
3. [The object-based reverse-mapping VM — LWN (2003)](https://lwn.net/Articles/23732/) — earliest public discussion of objrmap approach
4. [Reverse mapping anonymous pages - again — LWN (2004)](https://lwn.net/Articles/77106/) — anon_vma RFC discussion
5. [`include/linux/rmap.h`](https://github.com/torvalds/linux/blob/master/include/linux/rmap.h) — authoritative struct definitions and TTU flags
6. [`mm/rmap.c`](https://github.com/torvalds/linux/blob/master/mm/rmap.c) — full implementation; function headers are well-commented

## LKML Highlights

- **anon_vma_chain scalability fix (2010)**: Rik van Riel's series fixing the O(N) fork-storm problem; Linus's follow-on fix for the dangling-anon_vma hierarchy bug. Message-ID thread: `https://lwn.net/Articles/383171/` — the back-and-forth on how to pick the "correct" anon_vma when linking a page reveals deep subtlety in the hierarchy model.
- **objrmap introduction (2004)**: Discussion at `https://lwn.net/Articles/85908/` on the status of object-based rmap; shows the competing anonmm (Hugh Dickins) vs. anon_vma (Linus) approaches and why anon_vma won on simplicity grounds.
