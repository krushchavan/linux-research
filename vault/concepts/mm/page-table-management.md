---
title: "Page Table Management"
category: concept
tags: [mm, page-tables, virtual-memory, tlb, paging, mmu]
subsystem: mm
kernel_version: "2.6.11 (four-level); 4.14 (five-level)"
researched: 2026-04-10
status: complete
explained: "[[page-table-management-explained]]"
sources:
  - https://kernel-internals.org/mm/page-tables/
  - https://docs.kernel.org/mm/page_tables.html
  - https://docs.kernel.org/mm/split_page_table_lock.html
  - https://kernel-internals.org/mm/tlb-optimization/
  - https://lwn.net/Articles/717293/
  - https://lwn.net/Articles/106177/
  - https://lwn.net/Articles/753267/
  - https://lwn.net/Articles/568076/
  - https://www.kernel.org/doc/gorman/html/understand/understand006.html
  - https://static.lwn.net/kerneldoc/mm/page_tables.html
---

# Page Table Management

> 📘 Plain-language version: [[page-table-management-explained]]

## Purpose

Page tables are the data structure that the hardware MMU consults to translate every virtual address into a physical address. The kernel must build, maintain, populate, and tear down these structures for every process and for the kernel itself. Without correct page tables a process cannot access its own memory at all; without efficient management of them, every fault, fork, exec, and munmap becomes prohibitively expensive.

## Mental Model

Think of virtual-to-physical translation as a multi-level lookup in a set of nested arrays. Each array is exactly one page (4 KiB) large; each entry in the array either points to another array one level down, or — at the leaf — encodes the physical page frame number plus permission bits. The CPU hardware (MMU) walks these arrays autonomously during normal operation, caching results in the TLB. The kernel's job is to keep the arrays accurate and to tell the hardware when it has changed something the cache might hold.

A five-level hierarchy on x86-64 with 57-bit virtual addresses works like an index into 5 nested arrays, each 9 bits wide, followed by a 12-bit byte offset within the 4 KiB page.

## How It Works

### Hierarchy and Virtual Address Decomposition

Linux supports a generic five-level page table hierarchy. From top to bottom:

| Level | Abbreviation | Index bits (x86-64, LA57) | Region mapped per entry |
|-------|-------------|--------------------------|-------------------------|
| Page Global Directory | PGD | 9 (bits 56–48) | 128 PB / 512 entries |
| Page Level-4 Directory | P4D | 9 (bits 47–39) | 512 GB |
| Page Upper Directory | PUD | 9 (bits 38–30) | 1 GB |
| Page Middle Directory | PMD | 9 (bits 29–21) | 2 MB |
| Page Table Entry | PTE | 9 (bits 20–12) | 4 KB (one page) |

The bottom 12 bits are the byte offset within the physical page. An x86-64 CPU in four-level mode (48-bit VAs, `CONFIG_X86_5LEVEL=n`) simply does not index the P4D; the kernel folds that level away at compile time so the abstraction has zero runtime cost.

**Folding** is the mechanism by which unused levels vanish. When an architecture declares a level "folded," the corresponding `*_offset()` macro becomes a trivial identity function and the entry type aliases to the level above it. Architectures with three-level tables (e.g., ARM64 with 4 KB pages, 39-bit VA) fold both P4D and PUD. Two-level architectures (some embedded targets) additionally fold PMD. The result: generic kernel code walks all five levels, but the compiler optimizes the folded levels into nothing.

### Kernel vs. Process Page Tables

Each process owns a top-level PGD, allocated with `pgd_alloc()` and stored in `mm_struct→pgd`. The lower levels (P4D, PUD, PMD, PTE tables) are allocated on demand as the process maps memory. The kernel's own mappings live in `swapper_pg_dir` (or `init_top_pgt` on x86-64), which is the reference kernel-half PGD that is replicated into every new process PGD (on architectures without separate kernel page tables).

### The PTE Entry Format (x86-64)

A 64-bit PTE encodes:
- **Bits 51–12**: Physical Frame Number (PFN) — the physical page being mapped.
- **Bit 0 (P)**: Present — the entry is valid; if clear, the MMU will fault on access.
- **Bit 1 (W)**: Writable — allows stores to the page.
- **Bit 2 (U)**: User-accessible — if clear, user-space CPL-3 code faults on access.
- **Bit 5 (A)**: Accessed — hardware sets this on any read; the kernel uses it for reclaim decisions.
- **Bit 6 (D)**: Dirty — hardware sets this on any write; cleared by reclaim before page-out.
- **Bit 7 (PS)**: Page Size — at PMD or PUD level signals a 2 MB or 1 GB huge page leaf.
- **Bit 63 (XD/NX)**: Execute Disable — prevents code execution from this page.

Higher levels (PMD, PUD, P4D, PGD) carry a pointer to the next-level table in their upper bits. When `PS=1` is set in a PMD or PUD entry, that level becomes the leaf, and the entry encodes a 2 MB or 1 GB frame directly.

### Page Table Walk: Fault-Driven Allocation

The most important walk is the one that populates a missing translation during a page fault. The architecture-specific fault handler (`do_page_fault()` on x86) invokes `handle_mm_fault()` in `mm/memory.c`, which calls `__handle_mm_fault()`. That function drives a descending walk:

```
pgd = pgd_offset(mm, address)        # index into mm->pgd
p4d = p4d_alloc(mm, pgd, address)    # allocate P4D table if pgd entry is empty
pud = pud_alloc(mm, p4d, address)    # allocate PUD table if p4d entry is empty
pmd = pmd_alloc(mm, pud, address)    # allocate PMD table if pud entry is empty
```

At each level, `*_alloc()` checks whether the entry already points to a table; if not, it allocates a new zeroed page, installs it with an atomic compare-and-swap (protecting against concurrent faults on another CPU), and returns the pointer. Because the CAS is atomic, two racing CPUs may both allocate a table but only one wins; the loser frees its page and uses the winner's.

After descending to PMD level, the code checks for a huge-page opportunity. If the VMA is huge-page eligible and a 2 MB contiguous physical range is available, it installs the huge-page PMD leaf directly (`do_huge_pmd_anonymous_page()`), entirely bypassing PTE-level allocation. Otherwise it falls through to `handle_pte_fault()`.

`handle_pte_fault()` classifies the fault:
- **Anonymous demand-fault** (PTE absent, no swap entry): `do_anonymous_page()` allocates a fresh zero-filled page, maps it, and installs the PTE.
- **File-backed demand-fault** (PTE absent, mapping present): `do_read_fault()` reads from the page cache or invokes the VMA's `fault()` callback.
- **Copy-on-write**: `do_cow_fault()` allocates a new private page, copies the shared content, and replaces the PTE with the new mapping.
- **Write-protect fault on shared mapping**: `do_shared_fault()` marks the file page dirty and upgrades the PTE to writable.

### Locking Model

Page table locking uses a two-tier approach to balance correctness against scalability.

The **coarse lock** is `mm->page_table_lock`, a spinlock in `struct mm_struct`. It was historically used for all page table access but is now restricted to protecting PGD, P4D, and PUD level modifications (i.e., installing or removing an entire mid-level table pointer). Any code path that modifies upper-level entries must hold this lock.

The **fine-grained split lock** addresses the scalability bottleneck that a single `mm->page_table_lock` creates for multi-threaded processes. When `CONFIG_SPLIT_PTLOCK_CPUS` (default 4) ≤ `NR_CPUS`, each PTE table and PMD table gets its own per-page spinlock embedded in `struct page → ptl` (sharing storage with `page→private`). The canonical way to take a PTE table lock is:

```c
pte = pte_offset_map_lock(mm, pmd, address, &ptl);
/* manipulate pte */
pte_unmap_unlock(pte, ptl);
```

`pte_offset_map_lock()` maps the PTE page (necessary on 32-bit HIGHMEM systems where page tables may not be permanently mapped), then acquires `ptl`. On 64-bit kernels where page tables are always in LOWMEM, the map operation is a no-op and only the lock matters. PMD split locking uses `pmd_lock(pmd)` and requires `CONFIG_ARCH_ENABLE_SPLIT_PMD_PTLOCK`.

The lock hierarchy is strict: a CPU holding a PTE lock must not attempt to acquire the coarse `page_table_lock`, and must release PTE locks before modifying the PMD that contains them.

### TLB Management

When a PTE or mid-level entry changes — whether set, cleared, or upgraded — the hardware TLB may still hold a cached copy of the old translation. The kernel must invalidate those cached entries (a "TLB shootdown") before any CPU can observe the new state.

For single-page invalidations: `flush_tlb_page(vma, address)` → on x86, `INVLPG` locally plus an IPI to each remote CPU that last ran this `mm`.

For large unmaps (e.g., `munmap()` of a region), re-flushing page by page would be catastrophic. Instead the kernel uses **`struct mmu_gather`** in `mm/mmu_gather.c`:

1. `tlb_gather_mmu(tlb, mm)` initialises the accumulator with the address range being unmapped.
2. The page-table zap walk (via `zap_pte_range()`, `zap_pmd_range()`, etc.) clears entries and adds freed pages to the gather structure, but does *not* flush the TLB yet.
3. `tlb_finish_mmu(tlb)` performs one batched `flush_tlb_mm_range()` IPI and then releases all deferred pages.

This transforms O(N) IPI round trips into O(1) regardless of how many pages were unmapped.

**Lazy TLB mode**: when the kernel schedules a kernel thread, `enter_lazy_tlb()` marks that CPU as not needing TLB flush IPIs (because kernel threads never touch userspace page tables). The kernel skips sending IPIs to lazy CPUs unless the page tables themselves are about to be freed. This eliminates cross-CPU interrupts when a CPU is busy with kernel work.

**PCID / ASID caching**: on x86 CPUs supporting Process-Context IDentifiers (`CR4.PCIDE`), context switches preserve TLB entries tagged with the old address space ID rather than flushing everything. This eliminates the cold-TLB cost of switching between processes.

### Page Table Walk API

Beyond fault-driven walks, the kernel exposes a generic walk API in `mm/pagewalk.c`. A caller populates `struct mm_walk_ops` with callbacks:

```c
struct mm_walk_ops {
    int (*pgd_entry)(pgd_t *pgd, unsigned long addr, ...);
    int (*pmd_entry)(pmd_t *pmd, unsigned long addr, ...);
    int (*pte_entry)(pte_t *pte, unsigned long addr, ...);
    int (*pte_hole)(unsigned long addr, unsigned long next, ...);
    /* ... */
};
```

Then calls `walk_page_range(mm, start, end, &ops, private)`. The walker handles huge pages gracefully: a huge PMD entry triggers `pmd_entry` rather than recursing into non-existent PTE tables. This API is used by `/proc/pid/smaps` generation, NUMA balancing, KSM, and many other subsystems that need to examine or modify page table state without reimplementing the hierarchy traversal.

## Key Data Structures

**`struct mm_struct`** (`include/linux/mm_types.h`) — the per-process memory descriptor.
- `pgd_t *pgd` — top-level page table pointer, physical address stored in CR3 on x86.
- `spinlock_t page_table_lock` — coarse lock for PGD/P4D/PUD modifications.
- `struct rw_semaphore mmap_lock` — reader–writer lock protecting the VMA tree; page table walks (which read VMAs to classify faults) take the read side.

**`pgd_t`, `p4d_t`, `pud_t`, `pmd_t`, `pte_t`** — strongly-typed wrappers around `unsigned long` (or `u64`), defined per-architecture in `arch/*/include/asm/pgtable-types.h`. The type system prevents accidentally passing a PGD entry where a PTE is expected.

**`struct mmu_gather`** (`include/asm-generic/tlb.h`) — accumulates freed pages and the address range being unmapped so that a single batched TLB flush and page-free can be performed at the end of a large unmap operation.
- `struct mmu_gather_batch *active` — linked list of page batches awaiting freeing.
- `unsigned long start, end` — range to flush.
- `unsigned fullmm : 1` — if set, `flush_tlb_mm()` instead of range flush.

**`struct mm_walk`** (`include/linux/pagewalk.h`) — walker state passed to `walk_page_range()`.
- `const struct mm_walk_ops *ops` — caller's callbacks.
- `struct mm_struct *mm` — address space being walked.
- `void *private` — caller-provided data threaded through all callbacks.

## Key Functions / Entry Points

**`handle_mm_fault()`** (`mm/memory.c`) — the architecture-independent page fault entry point. Called by arch fault handlers with the faulting VMA, address, and flags. Returns a bitmask of `VM_FAULT_*` flags.

**`__handle_mm_fault()`** (`mm/memory.c`) — walks PGD→P4D→PUD→PMD, allocating levels on demand, then dispatches to huge-page or PTE-level fault handlers.

**`handle_pte_fault()`** (`mm/memory.c`) — classifies PTE-level faults into anonymous, file-backed, COW, or write-protect cases.

**`pgd_offset(mm, addr)`** (`arch/*/include/asm/pgtable.h`) — computes the PGD entry address for `addr` in `mm`; the first step of every page table walk.

**`pte_offset_map_lock(mm, pmd, addr, ptlp)`** (`include/linux/pgtable.h`) — maps the PTE table containing `addr` and acquires its split spinlock. Returns pointer to the PTE; `*ptlp` receives the held lock pointer. Must be paired with `pte_unmap_unlock()`.

**`pmd_alloc(mm, pud, addr)`** / **`pte_alloc(mm, pmd)`** — allocate the next-level table if the parent entry is empty, using `__pmd_alloc()` / `__pte_alloc()` which hold `page_table_lock` during the install.

**`walk_page_range(mm, start, end, ops, private)`** (`mm/pagewalk.c`) — generic page-table walker that invokes caller callbacks at each present level, handling huge pages and holes correctly.

**`tlb_gather_mmu(tlb, mm)`** / **`tlb_finish_mmu(tlb)`** (`mm/mmu_gather.c`) — bracket a large unmap operation for batched TLB shootdown.

**`flush_tlb_page(vma, addr)`** / **`flush_tlb_range(vma, start, end)`** — architecture hooks that perform local invalidation plus cross-CPU IPI.

**`pgd_alloc(mm)`** / **`pgd_free(mm, pgd)`** — allocate/free a top-level PGD page. On x86-64 with PTI, `pgd_alloc()` allocates an order-1 compound page to hold both the kernel-mode and user-mode PGD side-by-side.

## Important Flags & Config Options

**`CONFIG_X86_5LEVEL`** — enables five-level (LA57) page tables on x86-64, extending VA to 57 bits and PA to 52 bits. Requires CPU support (`CPUID.7.0:ECX[LA57]`). Off by default; applications must opt in to the expanded VA via `MAP_FIXED` hint above 128 TB.

**`CONFIG_SPLIT_PTLOCK_CPUS`** (default 4) — threshold for enabling per-table spinlocks. On any SMP kernel (NR_CPUS ≥ 4) split PTL is active, dramatically reducing lock contention in multi-threaded fault workloads.

**`CONFIG_ARCH_ENABLE_SPLIT_PMD_PTLOCK`** — architecture opt-in for per-PMD split locks (on top of per-PTE split locks). Requires `pagetable_pmd_ctor()` to be called at PMD allocation.

**`CONFIG_PAGE_TABLE_ISOLATION`** (PTI / KPTI) — Meltdown mitigation that maintains separate page table sets for userspace and kernel mode, switching CR3 on every kernel entry/exit. Adds ~1% overhead. Enabled by default on x86 when CPU is affected.

**`tlb_single_page_flush_ceiling`** (sysctl-like, tunable) — default 33. Controls when the kernel switches from individual `INVLPG` instructions to a full TLB flush; increasing it favors range flushes on CPUs where INVLPG is slow.

**`PTRS_PER_PGD / PTRS_PER_PUD / PTRS_PER_PMD / PTRS_PER_PTE`** — compile-time constants (512 on x86-64 for all levels) that define how many entries each table holds.

## Interactions with Other Subsystems

- **↑ Userspace**: `mmap()`, `mprotect()`, `munmap()`, `brk()` all manipulate VMAs, which the kernel translates into page table state lazily (demand-fault) or eagerly (via `remap_pfn_range()` for device mappings). `mincore()` and `/proc/pid/smaps` use `walk_page_range()` to inspect state.
- **→ [[Reverse Mapping (rmap)]]**: rmap uses the page table walk infrastructure inversely — given a physical page, it finds the PTE(s) that reference it, so it can unmap the page before reclaim or migration.
- **→ [[Page Fault Handler]]**: the fault handler is the primary consumer of the fault-path walk (`__handle_mm_fault()`). Page table management provides the infrastructure; the fault handler provides the policy.
- **→ [[Transparent Huge Pages]]**: THP decides whether to install 2 MB PMD leaves instead of PTEs, and performs "collapse" operations that swap 512 individual PTEs for a single huge PMD entry, requiring coordinated TLB shootdown.
- **→ [[Virtual Memory Areas]]**: VMAs describe the *intent* of a mapping (permissions, backing store); page tables are the *implementation*. The fault handler consults the VMA to determine what kind of page to install.
- **← mm/swap**: the swap path reads PTEs to determine which pages are swapped out (PTE not present, swap entry encoded in the entry value), then marks them present again after reading from disk.
- **← KSM**: Kernel Same-page Merging walks PTEs via `walk_page_range()` to find candidate anonymous pages, then replaces writable PTEs with read-only shared mappings.
- **← NUMA balancing**: the NUMA balancer periodically marks PTEs as `_PAGE_PROTNONE` (accessible but provoking a fault) to detect which pages are accessed from which NUMA node, then migrates cold pages closer to their accessor.

## Design Decisions & Tradeoffs

**Radix-tree structure over inverted page table**: Linux chose a forward-mapped, per-process radix tree rather than an inverted page table (one entry per physical frame, as used by some RISC architectures). The radix tree is wasteful for sparse address spaces (an empty 57-bit VA space costs nothing, but a deep mapping requires one 4 KiB page per level), but it is hardware-native on x86 and ARM64 and maps exactly to what the MMU walks, eliminating software-hardware translation layers.

**Generic multi-level abstraction with folding**: The five-level generic abstraction allows one codebase to target architectures from 2-level embedded systems to 5-level server x86-64. The cost is compile-time complexity and occasional confusion when reading folded level code. The benefit is that adding a new level (as happened with P4D in 4.11) required touching only the generic mm code and one architecture, not every driver and subsystem that walks page tables.

**Demand paging**: Page table entries are installed lazily (on fault) rather than eagerly at `mmap()` time. This trades minor fault overhead on first access for dramatically lower startup cost and lower memory use — a 100 GB `mmap()` costs almost nothing if only 10 MB is ever touched.

**Copy-on-Write on fork**: `fork()` does not copy page tables deeply. Instead it marks all private writable PTEs read-only in both parent and child, then allocates new pages on the first write fault. This makes `fork()` nearly O(1) in terms of memory allocation, at the cost of COW faults on subsequent writes.

**Split page table locks**: The original single `mm->page_table_lock` was a severe bottleneck for multi-threaded processes (e.g., a web server with hundreds of threads taking page faults simultaneously). Per-table spinlocks stored in `struct page → ptl` allow independent CPUs to fault into different VMAs without serializing. The cost is additional complexity in every path that acquires a PTE lock.

## How It Has Evolved

**1991 (Linux 0.01)**: Two-level page table (PGD + PTE) hard-coded for i386, 32-bit VAs.

**1999 (2.2 PAE)**: Physical Address Extension on x86 introduced three-level paging to reach 64 GB physical memory despite 32-bit VAs.

**2005 (2.6.11)**: Four-level page tables merged for x86-64, enabling 48-bit VAs (128 TB) and 46-bit PA (64 TB). The PMD and PUD levels were introduced in generic code with compile-time folding for 32-bit architectures.

**2012 (3.7)**: split page table lock for PTE tables, replacing the single `mm->page_table_lock` for leaf-level access. PMD split lock followed in 2013.

**2017 (4.11)**: P4D level added to generic code in preparation for five-level x86-64. All architectures not needing it fold P4D away.

**2017 (4.14)**: Five-level page tables enabled on x86-64 (`CONFIG_X86_5LEVEL`), extending VAs to 57 bits (128 PiB) and PAs to 52 bits (4 PiB). Also enables 512 GB huge pages at PUD level.

**2018 (4.15)**: Page Table Isolation (PTI/KPTI) merged as the Meltdown mitigation, doubling CR3 switches at every kernel entry and adding a shadow user-visible PGD per process.

**2020 (5.8)**: `pte_offset_map()` and `pte_unmap()` added explicit warnings on 64-bit to prepare for future removal of the HIGHMEM kmap path, simplifying the locking model.

**2022 (5.18)**: `struct folio` replacing `struct page` for large contiguous allocations began flowing into page table code; freeing of per-table `struct page` data structures changed accordingly.

## Further Reading

1. [Five-level page tables — LWN.net](https://lwn.net/Articles/717293/) — the design discussion before 4.11 merge.
2. [Four-level page tables — LWN.net](https://lwn.net/Articles/106177/) — original justification for adding PUD in 2.6.11.
3. [Page Tables — kernel.org documentation](https://docs.kernel.org/mm/page_tables.html) — current canonical reference.
4. [Split page table lock — kernel.org](https://docs.kernel.org/mm/split_page_table_lock.html) — how per-table locks work and what architectures must implement.
5. [Reworking page-table traversal — LWN.net](https://lwn.net/Articles/753267/) — 2018 proposal to unify the walk machinery (partial implementation followed).
6. [Split PMD locks — LWN.net](https://lwn.net/Articles/568076/) — rationale for extending split locks to PMD level.
7. [TLB optimization — kernel-internals.org](https://kernel-internals.org/mm/tlb-optimization/) — mmu_gather, lazy TLB, PCID in depth.
8. [Understanding the Linux Virtual Memory Manager (Gorman)](https://www.kernel.org/doc/gorman/html/understand/understand006.html) — classic reference, slightly dated but still accurate for fundamentals.

## LKML Highlights

- **P4D level introduction** (`[PATCH 00/14] x86: 5-level paging enabling for v4.11, Part 2`, Kirill Shutemov, 2017) — the patchset that inserted P4D generically and provided folding for all non-5-level architectures. Notable debate: whether to use a "4D" or "p4d" naming convention and how to keep arch-specific code minimal.
- **Split PMD lock** (`[PATCH 0/5] Split PMD lock`, Kirill Shutemov, 2013) — extended per-table locking from PTE to PMD. The key debate was whether the complexity was worth the scalability gain; accepted after benchmarks showed significant contention reduction on `mmap`/`munmap`-heavy workloads. Thread at `20131220111739.GC11781@shutemov.name`.
- **Reworking page-table traversal** (`[RFC 0/6] mm: uniform page table traversal`, Kirill Shutemov, 2018) — proposal to eliminate duplicated zap/walk code across levels by introducing a `struct pt_ptr`. Skepticism about the "flag day" required to convert all architectures stalled it; the individual `mm_walk_ops` API was refined as an alternative.
