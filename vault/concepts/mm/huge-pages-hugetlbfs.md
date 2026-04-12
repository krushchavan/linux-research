---
title: "Huge Pages and hugetlbfs"
category: concept
tags: [mm, huge-pages, hugetlbfs, tlb, memory-management]
subsystem: mm
kernel_version: "2.5.46"
researched: 2026-04-11
status: complete
sources:
  - https://www.kernel.org/doc/html/v4.18/vm/hugetlbfs_reserv.html
  - https://www.kernel.org/doc/html/latest/admin-guide/mm/hugetlbpage.html
  - https://lwn.net/Articles/374424/
  - https://lwn.net/Articles/375096/
  - https://lwn.net/Articles/974491/
  - https://linuxgazette.net/155/krishnakumar.html
---

# Huge Pages and hugetlbfs

## Purpose

The TLB is a small, fixed-size cache of virtual-to-physical address translations. On a system using 4 KB pages, a 1 GB working set requires 262,144 TLB entries — far more than any processor can hold. Huge pages (2 MB on x86, up to 1 GB) collapse that coverage so that a single TLB entry spans a full 2 MB or 1 GB, reducing misses and translation overhead dramatically. `hugetlbfs` is the kernel's original (2002) explicit mechanism for granting user space access to these pre-reserved, physically contiguous huge pages, before [[transparent-huge-pages]] existed.

## Mental Model

Think of the huge-page pool as a hotel block reservation. Before an application checks in (calls `mmap`), the kernel guarantees the rooms by "block-reserving" them from the global pool. Unlike regular pages — which are allocated lazily and may fail under memory pressure — a reserved huge page is locked away for the requester regardless of what happens later. The application faults in each reserved page when it first touches the memory, but it can never be told "no room at the inn" at that point: the reservation made at mapping time is the contract.

## How It Works

### TLB pressure and the motivation for large pages

Every memory reference on a page-walking CPU starts in the TLB. A miss forces a hardware page-table walk costing 10–100 cycles. With 4 KB pages the "TLB reach" of a processor with 64 entries is just 256 KB; with 2 MB pages the same 64 entries cover 128 MB. For workloads with large resident sets — databases, HPC, AI inference, VMs — this reduction in miss rate produces measurable throughput gains: 2–7% for typical database workloads, 1–45% for scientific HPC.

### The global pool and `struct hstate`

The kernel maintains one `struct hstate` per supported huge-page size. On x86 that is typically two: one for 2 MB and one for 1 GB pages. Each `hstate` tracks the global pool for its size:

```c
struct hstate {
    struct mutex resize_lock;       /* serialises pool resizing */
    int next_nid_to_alloc;          /* NUMA round-robin hint */
    int next_nid_to_free;
    unsigned int order;             /* log2 of pages-per-huge-page */
    unsigned int demote_order;      /* order to demote to */
    unsigned long mask;             /* ~((1 << order) - 1) */
    unsigned long max_huge_pages;   /* pool cap (nr_hugepages sysctl) */
    unsigned long nr_huge_pages;    /* current total in pool */
    unsigned long free_huge_pages;  /* currently unallocated */
    unsigned long resv_huge_pages;  /* reserved but not yet faulted */
    unsigned long surplus_huge_pages; /* above cap, created on demand */
    unsigned long nr_overcommit_huge_pages; /* overcommit limit */
    struct list_head hugepage_activelist;
    struct list_head hugepage_freelists[MAX_NUMNODES]; /* per-NUMA free lists */
    unsigned int nr_huge_pages_node[MAX_NUMNODES];
    unsigned int free_huge_pages_node[MAX_NUMNODES];
    unsigned int surplus_huge_pages_node[MAX_NUMNODES];
    char name[HSTATE_NAME_LEN];
};
```

At boot, `hugetlb_init()` is called, which walks the `hstates` array, allocates the requested number of physically contiguous compound pages of the appropriate order, and enqueues each via `enqueue_huge_page()` onto the `hugepage_freelists[nid]` for its home NUMA node. The kernel can also allocate surplus pages at runtime (up to `nr_overcommit_huge_pages`) if the pool is exhausted and memory is available; these show up as `HugePages_Surp` in `/proc/meminfo` and are freed when returned to the pool.

The available count for allocation is `free_huge_pages - resv_huge_pages`. This distinction is critical: a reserved page counts as "in use" from the pool's perspective, even though the physical page has not yet been handed to any process.

### Accessing huge pages: the hugetlbfs filesystem

Applications reach the pool through a RAM-based pseudo-filesystem, hugetlbfs, mounted with:

```bash
mount -t hugetlbfs -o pagesize=2M,size=4G none /mnt/huge
```

Every file on this filesystem is backed by huge pages. An application calls `mmap()` on an opened file to establish a mapping; the `vm_operations_struct` for hugetlbfs maps page faults to `hugetlb_fault()`. Alternatively, since 2.6.32, `mmap(MAP_ANONYMOUS|MAP_HUGETLB)` creates an anonymous huge-page mapping without touching the filesystem at all. The oldest interface — `shmget(SHM_HUGETLB)` — creates huge-page-backed SysV shared memory, though it is limited to the default page size and cannot select alternate sizes.

The hugetlbfs mount carries an optional `struct hugepage_subpool`:

```c
struct hugepage_subpool {
    spinlock_t lock;
    long count;             /* number of mappings using this pool */
    long max_hpages;        /* -1 means unlimited */
    long used_hpages;
    struct hstate *hstate;
    long min_hpages;        /* pages reserved at mount time */
    long rsv_hpages;        /* current reserved from global pool */
};
```

The subpool acts as a second layer of accounting between the global `hstate` pool and individual file mappings. If `min_size=` was given at mount, the subpool calls `hugetlb_acct_memory()` at mount time to pre-reserve that many pages from the global pool, guaranteeing a floor of availability for all mappings under this mount.

### Reservation maps: the per-mapping guarantee

The critical correctness property is that no process should be able to `mmap()` a huge-page region and then receive SIGBUS at first access because the pool ran out. The kernel achieves this with a **reservation map** (`struct resv_map`) created at `mmap()` time.

```c
struct resv_map {
    struct kref refs;
    spinlock_t lock;
    struct list_head regions;       /* list of struct file_region */
    long adds_in_progress;
    struct list_head region_cache;  /* pre-allocated nodes */
    long region_cache_count;
};

struct file_region {
    struct list_head link;
    long from;              /* start index (in huge pages) */
    long to;                /* end index (exclusive) */
};
```

The semantics of the reservation map differ between private and shared mappings:

- **Private (`MAP_PRIVATE`)**: The map hangs off `vma->vm_private_data`. An *absence* of a region in the map for a given huge-page index means a reservation *does* exist there; a *present* region means the page has been faulted in and the reservation consumed.
- **Shared**: The map hangs off `inode->i_mapping->private_data`. Here a *present* region means a reservation exists or existed.

This inversion for private mappings is intentional: for a fresh private mapping the map starts empty — every page index implicitly has a reservation — and entries are added only when reservations are consumed, avoiding the need to pre-fill an entire range.

### The two-phase modification algorithm

Changes to a reservation map follow a strict two-phase protocol to avoid allocation failures inside critical code paths:

1. **`region_chg(resv_map, from, to)`** — examines the map under a lock, counts how many pages in `[from, to)` are not yet reserved, allocates any `struct file_region` nodes that will be needed, and returns the count. Global pool accounting can be checked at this point. This phase *may* sleep and allocate.

2. **`region_add(resv_map, from, to)`** or **`region_abort(resv_map, from, to)`** — takes the pre-allocated nodes and splices them in (or discards them if the global check failed). This phase must not fail.

Separating "figure out what's needed and allocate" from "do the actual update" ensures that once the global pool has been debited, the reservation map update will always succeed, maintaining consistency between `resv_huge_pages` and what the maps promise.

### Fault path: `hugetlb_fault()`

When a process touches huge-page memory for the first time, the hardware page-table walk finds no entry and raises a page fault. The mm fault dispatcher checks `vma->vm_flags & VM_HUGETLB` and calls `hugetlb_fault()`.

Inside `hugetlb_fault()`:

1. **`huge_pte_alloc()`** walks or allocates the page-table path down to the PTE level for the huge page. For 2 MB pages on x86, this means a PMD entry; for 1 GB pages, a PUD entry.

2. **`vma_needs_reservation()`** consults the reservation map for the faulting address. It returns 0 if a reservation exists (the caller can consume it without modifying `resv_huge_pages`) or 1 if no reservation exists (an unaccounted-for allocation, possible under `nr_overcommit_hugepages`).

3. **`alloc_huge_page()`** dequeues a page from the appropriate NUMA node's `hugepage_freelists`. If the pool is empty but surplus is allowed, it tries to allocate a fresh compound page. On success it sets `_PAGE_PSE` (x86: "page size extension") in the PTE, mapping the PMD or PUD entry directly to the physical huge page.

4. If the allocation consumed a reservation, **`SetPagePrivate(page)`** marks the page so that when it is freed, the reservation counter is correctly restored (via `restore_reserve_on_error()` on error paths).

5. **`huge_pmd_share()`** may be called for shared mappings: if another VMA has already installed a PMD for the same file offset, the current VMA can share that PMD entry entirely, avoiding the cost of building a duplicate sub-table. This *PMD sharing* (available on x86, arm64, riscv) means multiple processes can share not just the physical page but the page-table structure itself, saving memory for large shared mappings.

### COW and the reservation owner

For private (`MAP_PRIVATE`) huge-page mappings, the VMA is marked with `HPAGE_RESV_OWNER` to record which task holds the reservation. When a child process inherits such a mapping after `fork()`, it becomes a non-owner. If the child triggers a write fault (copy-on-write) and the pool has no free page to give it, the kernel sends it SIGBUS — the non-owner's fault is not covered by the reservation. The parent (owner), however, will always succeed: the reservation was made on its behalf. The `HPAGE_RESV_UNMAPPED` flag records the case where a non-owner's mapping was unmapped to satisfy a parent write, allowing the parent to detect this and handle it correctly.

## Key Data Structures

**`struct hstate`** (`include/linux/hugetlb.h`) — per-page-size pool descriptor. One exists for each supported huge page size (e.g., 2 MB, 1 GB on x86).
- `hugepage_freelists[MAX_NUMNODES]` — NUMA-local free lists for fast allocation
- `free_huge_pages` / `resv_huge_pages` — tracks available vs. reserved pages; allocatable = `free - resv`
- `order` — compound page order; 2 MB = order 9 on x86 (512 × 4 KB)

**`struct resv_map`** (`include/linux/hugetlb.h`) — per-VMA or per-inode reservation map. Encodes which huge-page slots have been reserved.
- `regions` — linked list of `struct file_region` intervals

**`struct file_region`** (`mm/hugetlb.c`) — an interval `[from, to)` in huge-page index space that marks a reserved or consumed range.

**`struct hugepage_subpool`** (`include/linux/hugetlb.h`) — optional per-mount pool layer. Provides a floor (`min_hpages`) and ceiling (`max_hpages`) on top of the global `hstate`.

## Key Functions / Entry Points

**`hugetlb_init()`** (`mm/hugetlb.c`) — called at boot; allocates initial pool pages per `hstate` and enqueues them onto NUMA node free lists.

**`hugetlb_reserve_pages()`** (`mm/hugetlb.c`) — called from `mmap()` path; invokes `region_chg()` then increments `resv_huge_pages` and, if a subpool exists, debits it. Establishes the reservation contract.

**`hugetlb_fault()`** (`mm/hugetlb.c`) — page-fault handler for `VM_HUGETLB` VMAs. Calls `alloc_huge_page()`, installs the PTE, and optionally invokes `huge_pmd_share()`.

**`alloc_huge_page()`** (`mm/hugetlb.c`) — dequeues a free page from the pool, respecting reservations and surplus limits.

**`vma_needs_reservation()`** (`mm/hugetlb.c`) — consults the resv_map to determine whether faulting address has an extant reservation.

**`region_chg()` / `region_add()` / `region_abort()`** (`mm/hugetlb.c`) — two-phase reservation map update primitives ensuring allocation happens before commitment.

**`huge_pmd_share()`** (`mm/hugetlb.c`) — establishes PMD-level page-table sharing between processes that map the same file-backed huge page.

**`restore_reserve_on_error()`** (`mm/hugetlb.c`) — restores a reservation map entry if a page was allocated but could not be installed (error recovery).

## Important Flags & Config Options

**`CONFIG_HUGETLBFS`** — enables the hugetlbfs pseudo-filesystem. **`CONFIG_HUGETLB_PAGE`** is auto-selected by it.

**`/proc/sys/vm/nr_hugepages`** — sets or reads the *persistent* pool size (pages that will not be freed under pressure). Writes trigger immediate allocation attempts.

**`/proc/sys/vm/nr_hugepages_mempolicy`** — like `nr_hugepages` but allocates respecting the task's NUMA memory policy; use with `numactl` for NUMA-aware pre-allocation.

**`/proc/sys/vm/nr_overcommit_hugepages`** — maximum number of surplus pages the kernel may allocate on demand beyond the persistent pool. These are freed when returned.

**`/proc/meminfo`** fields:
- `HugePages_Total` — persistent pool size
- `HugePages_Free` — pool pages not yet given to any mapping
- `HugePages_Rsvd` — reserved but not yet faulted (= `resv_huge_pages`)
- `HugePages_Surp` — surplus pages above `nr_hugepages`

**`/sys/kernel/mm/hugepages/hugepages-<size>kB/`** — per-size sysfs controls: `nr_hugepages`, `free_hugepages`, `surplus_hugepages`, `demote` (split larger pages to smaller), `demote_size`.

**`MAP_HUGETLB`** — mmap flag for anonymous huge-page mappings; combine with `MAP_HUGE_2MB` or `MAP_HUGE_1GB` to select size.

**`SHM_HUGETLB`** — shmget flag to create SysV shared memory backed by huge pages (default size only).

**Boot parameters**: `hugepagesz=<size> hugepages=<count>` pairs; `default_hugepagesz=<size>`; `hugepage_alloc_threads=<N>` (default: 25% of CPUs).

## Interactions with Other Subsystems

- **↑ Userspace**: accesses huge pages via `mmap()` on hugetlbfs files, `mmap(MAP_HUGETLB)`, or `shmget(SHM_HUGETLB)`. Explicit application opt-in is required; no transparency.
- **→ [[page-table-management]]**: hugetlbfs installs PMD-level (2 MB) or PUD-level (1 GB) PTEs directly; bypasses the normal PTE-level page table path entirely. PMD sharing further coalesces page-table memory across processes.
- **→ [[numa-memory-policy]]**: pool allocation distributes across NUMA nodes using `nr_huge_pages_mempolicy`; NUMA-local free lists in `hstate` ensure low-latency allocation from the local node.
- **← [[memory-compaction]]**: huge pages require physically contiguous memory of the appropriate order. If the pool cannot be filled at runtime due to fragmentation, compaction may be triggered to coalesce free pages.
- **← [[transparent-huge-pages]]**: THP is the modern alternative for most workloads; hugetlbfs coexists and is preferred when guaranteed reservation, 1 GB pages, or page-table sharing is needed.
- **← [[memory-cgroup]]**: memcg can account hugetlb usage through `hugetlb.<size>.limit_in_bytes` and `hugetlb.<size>.usage_in_bytes` controllers (requires `CONFIG_CGROUP_HUGETLB`).

## Design Decisions & Tradeoffs

**Reservation at mmap time, not fault time.** The original pre-2.6.18 implementation faulted (and thus allocated) huge pages at `mmap()` time, which was expensive on NUMA systems because allocation happened before any thread had touched the data, placing pages on potentially wrong nodes. The current design defers the physical allocation to first touch while still making the *reservation* at map time, preserving the guarantee without incurring the NUMA placement cost early.

**No swap support.** Swapping huge pages would require splitting them into 4 KB pages (since the swap subsystem only understands base-page granularity), breaking the physical contiguity requirement. The kernel simply marks huge pages non-swappable. This forces administrators to size the pool conservatively — those pages are permanently locked away from other uses.

**Pool-based over demand-allocation.** The persistent pool model trades flexibility for predictability. Pages allocated at boot when memory is unfragmented are far more likely to be physically contiguous at the required order than pages allocated later under load. The overcommit knob provides an escape valve when transient demand exceeds the persistent pool.

**PMD sharing for shared mappings.** For large shared-memory databases (Oracle, DB2) where many processes map the same data, sharing PMD page-table entries can reduce page-table memory significantly and improves TLB shootdown efficiency (fewer entries to flush on munmap). The downside is complex locking and special-case code in the page-table walker — the 2024 unification effort targets reducing these special cases.

**Explicit opt-in vs. THP transparency.** hugetlbfs requires application-level changes (different allocation calls, filesystem mounts). This is a deliberate guarantee mechanism: the application is in full control and can reason about memory layout. THP is transparent but probabilistic — the kernel tries to use large pages but may silently fall back to small pages. Safety-critical or latency-sensitive workloads prefer the determinism of hugetlbfs.

## How It Has Evolved

**2.5.46 (2002)**: hugetlbfs introduced; initial huge page pool and `shmget(SHM_HUGETLB)`.

**2.6.0 (2003)**: Stabilized for production; early adoption in database server workloads (Oracle, DB2).

**Pre-2.6.18**: Physical pages allocated at `mmap()` time — expensive on NUMA.

**2.6.18**: Changed to fault-on-first-touch with reservations only for shared mappings.

**2.6.29**: Reservations extended to private mappings as well; both shared and private mappings receive the no-SIGBUS guarantee.

**2.6.32**: `MAP_HUGETLB` added for anonymous huge-page mappings without requiring a hugetlbfs mount.

**3.x era**: Per-size sysfs controls, multiple huge page sizes on the same system, NUMA-per-node control via `/sys/devices/system/node/`.

**Recent (6.x)**: `demote` interface to split 1 GB pages into 2 MB pages without freeing them back to the OS. Ongoing large-folio / folio unification work aiming to collapse the ~11 `if (hugetlbfs)` special cases throughout the MM subsystem into a small common set of paths.

## Further Reading

1. [Huge pages part 1: Introduction — LWN.net (2010)](https://lwn.net/Articles/374424/)
2. [Huge pages part 2: Interfaces — LWN.net (2010)](https://lwn.net/Articles/375096/)
3. [Toward the unification of hugetlbfs — LWN.net (2023)](https://lwn.net/Articles/974491/)
4. [Hugetlbfs Reservation — kernel.org documentation](https://www.kernel.org/doc/html/v4.18/vm/hugetlbfs_reserv.html)
5. [HugeTLB Pages admin guide — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/mm/hugetlbpage.html)
6. [HugeTLB - Large Page Support in the Linux Kernel — Linux Gazette](https://linuxgazette.net/155/krishnakumar.html)

## LKML Highlights

**Reservation for private mappings (2.6.29 era)**: The thread debated whether private hugetlb mappings should get the same SIGBUS-free guarantee as shared ones. The outcome extended the two-phase reservation protocol to private VMAs, trading slightly higher `mmap()` overhead for correctness. Search lore.kernel.org for "hugetlb private mapping reservation".

**Toward hugetlbfs unification**: A 2023 RFC series proposed reducing the ~11 `if (hugetlb)` scatter sites throughout MM to 2–3 by leveraging large-folio infrastructure. The discussion revealed how much complexity has accumulated from 20 years of special-casing. See [LWN.net/Articles/974491/](https://lwn.net/Articles/974491/) for the design debate.

**High-granularity mapping (2022)**: An RFC series proposed sub-huge-page mapping granularity for hugetlbfs — mapping only part of a huge page — to reduce memory waste when applications have non-huge-page-aligned working sets. Search lore.kernel.org for "hugetlb high-granularity mapping".
