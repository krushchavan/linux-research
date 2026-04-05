---
title: "Transparent Huge Pages"
category: concept
tags: [mm, thp, huge-pages, khugepaged, compaction, tlb]
subsystem: mm
kernel_version: "2.6.38"
researched: 2026-04-05
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/mm/transhuge.html
  - https://lwn.net/Articles/423584/
  - https://lwn.net/Articles/619738/
  - https://lwn.net/Articles/906511/
  - https://lwn.net/Articles/1032199/
  - https://lwn.net/Articles/974826/
  - https://docs.kernel.org/admin-guide/mm/transhuge.html
---

# Transparent Huge Pages

## Purpose

Transparent Huge Pages (THP) reduces TLB pressure and page-fault overhead by silently backing large anonymous memory regions with 2 MB compound pages (or smaller power-of-2 sizes with multi-size THP) rather than thousands of 4 KB base pages. Fewer TLB entries means fewer TLB misses on hot code paths; fewer faults means less time spent in the fault handler during bulk allocations. The "transparent" part means applications need not call `mmap(MAP_HUGETLB)` or use `libhugetlbfs` — the kernel promotes eligible regions automatically.

## Mental Model

A normal anonymous mapping uses one PTE per 4 KB page: 512 PTEs to cover 2 MB, consuming 512 TLB slots. A THP-backed mapping uses a single PMD entry to cover the same 2 MB: one TLB slot, one page fault. When the application walks that region linearly, it hits the TLB every time instead of missing it every 4 KB. The downside is that one unused page in a 2 MB THP "wastes" 2044 KB of RAM — splitting and promoting pages under pressure is the mechanism that manages this tension.

## How It Works

### Fault-time allocation

The normal page fault path for anonymous memory ends in `do_anonymous_page()`. With THP enabled, the kernel first checks whether the faulting address is PMD-aligned, the VMA is large enough to accommodate a huge page, and the global THP policy (`/sys/kernel/mm/transparent_hugepage/enabled`) permits it. If all checks pass, `do_huge_pmd_anonymous_page()` in `mm/huge_memory.c` is attempted:

1. `alloc_hugepage_vma()` requests a 2 MB order-9 compound folio from the buddy allocator with `__GFP_COMP | __GFP_MOVABLE`. If `defrag` is set to `always` or `defer+madvise`, it may also trigger synchronous memory compaction.
2. On success, `prep_huge_page()` initialises the compound page: the first page is the **head**, the remaining 511 are **tail** pages. The head's `compound_order` is set to 9; each tail's `_refcount` is initialised to 0 (only the head's `_refcount` is authoritative).
3. A single PMD entry is installed via `set_pmd_at()`, pointing directly at the head page. The CPU's page walker interprets this as a huge page because the `_PAGE_PSE` bit (Present Size Extension) is set.
4. On failure, the fault falls back to `do_anonymous_page()` and allocates a base 4 KB page — the application sees no difference.

### Huge zero page

On a **read** fault into an anonymous zero region, instead of allocating a fresh compound page, the kernel may install a read-only PMD entry pointing at the **huge zero page** — a globally shared, pre-faulted 2 MB zero-filled compound page. This defers physical allocation until the process writes. The huge zero page is enabled via `/sys/kernel/mm/transparent_hugepage/use_zero_page`.

### khugepaged: background collapse

Fault-time allocation only captures regions that fault in at PMD alignment. Regions that grow from small faults and later become large are handled by **khugepaged**, a kernel thread that runs on a configurable schedule (`scan_sleep_millisecs`). Its main loop calls `khugepaged_scan_mm_slot()` which iterates registered VMAs and looks for runs of `HPAGE_PMD_NR` (512) consecutive base pages that could be collapsed.

For each candidate region, `collapse_huge_page()`:
1. Takes `mmap_write_lock()` and the anon_vma lock in write mode (this serialises against concurrent faults and remap operations).
2. Allocates a fresh order-9 folio.
3. Copies all 512 base pages into the huge page with `copy_user_highpage()`.
4. Replaces the 512 PTE entries with a single PMD via `__collapse_huge_page_swapin()` / `pmdp_collapse_flush()`.
5. Frees the original base pages.

khugepaged can tolerate some holes: `max_ptes_none` allows up to N unmapped PTEs (they become zero pages in the huge page); `max_ptes_swap` allows up to N swap entries (khugepaged swaps them in first). Both trade memory efficiency for collapse success rate.

VMAs are registered with khugepaged via `khugepaged_enter()` when a VMA is created that meets the size threshold; they are deregistered on unmap.

### Explicit collapse: madvise(MADV_COLLAPSE)

Since 5.18, a process can call `madvise(addr, len, MADV_COLLAPSE)` to synchronously collapse a region into THP regardless of the global policy. This calls `madvise_collapse()` → `collapse_huge_page()` directly in the caller's context. Useful for JIT compilers and runtimes that know exactly when a hot region becomes stable.

### Splitting: split_huge_page and split_huge_pmd

THP pages must sometimes be split back into base pages:
- **Reclaim**: [[Page Reclaim]] cannot swap a 2 MB compound page as a unit if only a few pages are hot; `split_huge_page()` is called first. (Since 4.13, THP swap without splitting is supported for the common single-user case.)
- **mprotect / munmap on a sub-range**: can't change protection for part of a PMD-mapped region without splitting the PMD.
- **GUP pin**: `get_user_pages()` on a sub-range splits the PMD (`split_huge_pmd()`) to install PTE-level entries for the pinned pages.

`split_huge_page()` in `mm/huge_memory.c`:
1. Checks `page_count(head)` — if any page is pinned, split fails and returns `-EBUSY`.
2. Allocates 511 new `struct page` entries (reusing tail page structs in newer kernels via `split_large_folio()`).
3. Fills each tail with the head's `_mapcount`, address space, and index.
4. Converts each PMD pointing at the head into 512 PTEs via `split_huge_pmd_address()`.
5. Frees the compound page header overhead; the 512 base pages remain in place.

`split_huge_pmd()` does only one process's mapping, leaving the compound page intact for other processes — a much cheaper operation added in 4.5.

### Deferred split queue

After 5.18, THP pages that are partially unmapped (some sub-pages freed but the compound page still alive) are placed on a **deferred split queue** rather than split immediately. A shrinker (`deferred_split_shrinker`) is registered; under memory pressure it pulls entries from the queue and calls `split_huge_page()` on them, recovering the zero-filled sub-pages. A background scanner runs every second and categorises up to 256 THP pages by utilisation (0–25%, 25–50%, 50–75%, 75–100%); pages in the 0–50% bucket are enqueued. This avoids wasteful preemptive splitting at the cost of a small memory overhead until pressure arrives.

### Multi-size THP (mTHP, Linux 6.8+)

PMD-size (2 MB) THP is all-or-nothing: if an order-9 allocation fails, the kernel falls back to 4 KB. Multi-size THP introduces intermediate sizes — any power-of-2 between 16 KB and 1 MB — as **large folios** backed by order 2–8 compound pages. Each size has its own sysfs control under `/sys/kernel/mm/transparent_hugepage/hugepages-<size>kB/enabled`. The allocation strategy is greedy-descending: attempt the largest available size and fall back until a 4 KB base page succeeds. mTHP reduces page-fault overhead and TLB pressure even when 2 MB pages are unavailable, with Ampere Altra benchmarks showing ~20% throughput improvement in Memcached at 64 KB order.

### File THP and shmem THP

Anonymous THP was the original (2.6.38) implementation. File-backed THP for tmpfs/shmem was added later (policy via `huge=` mount option or `/sys/kernel/mm/transparent_hugepage/shmem_enabled`). Page-cache THP for regular files on ext4/xfs/etc. is an ongoing effort — "transparent huge pages in the page cache" — controlled per-inode via `fadvise(FADV_COLLAPSE)` or per-mount configuration, and is not yet universally available for all filesystems.

## Key Data Structures

**Compound page / large folio** — a 2 MB THP is a 512-page compound folio. The head folio's `_refcount` counts total references; `_mapcount` on the head counts PMD-level mappings; a per-tail `_mapcount` field (repurposed from `mapping`) stores the PMD map count for split tracking. `folio_order()` returns 9 for a standard THP.

**`pmd_t` with `_PAGE_PSE`** — when the PMD entry has the PSE bit set and `_PAGE_PRESENT`, the hardware treats it as a 2 MB mapping. `pmd_trans_huge()` tests for this state. Code that walks page tables must check `pmd_trans_huge()` before dereferencing a PMD as a page table pointer, otherwise it would follow the huge page's physical address as a table — a guaranteed crash.

**`struct khugepaged_scan`** — embedded in each `mm_struct`; tracks the cursor position for the next khugepaged scan pass over that process's VMAs.

**Deferred split queue** — a per-`lruvec` linked list of partially-unmapped THP folios; head stored in `lruvec->deferred_split_queue`.

## Key Functions / Entry Points

**`do_huge_pmd_anonymous_page()`** (`mm/huge_memory.c`) — fault-time THP allocation; called from `__handle_mm_fault()` when PMD is none and THP is eligible.

**`khugepaged_enter()`** (`mm/khugepaged.c`) — registers a VMA for background collapse consideration; called on VMA creation.

**`collapse_huge_page()`** (`mm/khugepaged.c`) — core collapse logic; copies 512 base pages into one order-9 folio and replaces their PTEs with a PMD.

**`split_huge_page()`** (`mm/huge_memory.c`) — splits a compound folio into base pages; may fail on pinned pages.

**`split_huge_pmd()`** (`mm/huge_memory.c`) — splits one process's PMD mapping into 512 PTEs without splitting the underlying compound page.

**`pmd_trans_huge()`** / **`pmd_trans_unstable()`** (`include/asm-generic/pgtable.h`) — predicates used by page-table walkers to detect huge PMDs; the unstable variant also checks for migration entries.

**`madvise_collapse()`** (`mm/madvise.c`) — synchronous user-driven collapse; calls `collapse_huge_page()` in the calling process's context.

## Important Flags & Config Options

| Knob | Location | Effect |
|------|----------|--------|
| `enabled` | `/sys/kernel/mm/transparent_hugepage/enabled` | `always` / `madvise` / `never` system-wide THP policy |
| `defrag` | `/sys/kernel/mm/transparent_hugepage/defrag` | `always` / `defer` / `defer+madvise` / `madvise` / `never` — controls compaction aggressiveness |
| `use_zero_page` | `/sys/kernel/mm/transparent_hugepage/use_zero_page` | enable/disable huge zero page on read faults |
| `khugepaged/pages_to_scan` | sysfs | pages khugepaged scans per pass |
| `khugepaged/scan_sleep_millisecs` | sysfs | interval between khugepaged passes |
| `khugepaged/max_ptes_none` | sysfs | unmapped PTEs tolerated during collapse |
| `khugepaged/max_ptes_swap` | sysfs | swap entries tolerated during collapse |
| `hugepages-<N>kB/enabled` | sysfs (per-size) | mTHP per-size policy (`always`/`madvise`/`never`/`inherit`) |
| `shmem_enabled` | sysfs | THP policy for tmpfs/shmem (`always`/`within_size`/`advise`/`never`/`deny`/`force`) |
| `CONFIG_TRANSPARENT_HUGEPAGE` | Kconfig | compile-in THP support |
| `CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS` / `_MADVISE` | Kconfig | default policy at boot |
| `transparent_hugepage=` | kernel cmdline | override Kconfig default at boot |

## Interactions with Other Subsystems

- **↑ Userspace**: `madvise(MADV_HUGEPAGE)` opts a range into THP; `madvise(MADV_NOHUGEPAGE)` opts it out; `madvise(MADV_COLLAPSE)` forces synchronous collapse; `prctl(PR_SET_THP_DISABLE)` disables THP process-wide; `prctl(PR_THP_DISABLE_EXCEPT_ADVISED)` inverts: off globally, on for advised regions.
- **→ [[Buddy Allocator]]**: THP fault-time allocation requests order-9 physically contiguous pages; these are scarce under fragmentation, driving the need for compaction.
- **→ [[Memory Compaction]]**: the `defrag` sysctl controls whether THP faults or khugepaged trigger synchronous or deferred compaction via `try_to_compact_pages()`.
- **← [[Page Reclaim]]**: reclaim calls `split_huge_page()` before swapping anonymous THP (unless `SWP_THP_ENABLED` is set); the deferred split shrinker runs under memory pressure to recover partially-used THP.
- **→ [[Swap]]**: since 4.13, a single-user THP can be swapped as a unit using order-9 swap cluster allocation; on swap-in, a single folio fault restores the whole 2 MB.
- **→ [[Page Fault Handler]]**: `__handle_mm_fault()` branches to `do_huge_pmd_anonymous_page()` when appropriate; all THP creation flows through the fault handler.

## Design Decisions & Tradeoffs

**Anonymous-only initially**: The 2.6.38 implementation restricted THP to anonymous mappings because file-backed pages are shared across processes and inodes — the address_space lookup, writeback, and truncation paths all needed updating to handle compound folios. Anonymous pages are private and self-contained, making the compound page model straightforward. File THP came years later as each subsystem was audited.

**PMD size only (initially)**: The 2 MB PMD size matched the hardware huge page size on x86 — no special support needed in the page-table walker. Smaller sizes required either sub-PMD compound pages (the mTHP approach) or a new page-table level. mTHP arrived in 6.8 after the folio infrastructure made per-order compound pages manageable.

**Deferred split vs eager split**: Eager split on every munmap sub-region is O(1) but thrashes the buddy allocator. Deferred split batches recovery to memory-pressure events, reducing fragmentation churn. The tradeoff is a small persistent overhead for partially-unused THP.

**THP swap without splitting**: Splitting before swap-out was the safe first implementation. Adding THP swap required extending the swap cluster allocator to reserve 512 contiguous slots and updating the swap-in fault path to re-assemble the compound page. The win is significant: one I/O instead of 512, and one fault on re-access.

**`always` vs `madvise` default**: Setting `enabled=always` can hurt workloads with many small short-lived allocations (Redis, some databases) because khugepaged spends CPU collapsing pages that are immediately freed. `madvise` is safer and lets latency-sensitive applications opt out. Many distributions now default to `madvise`.

## How It Has Evolved

- **2.6.38 (2011)**: Initial THP for anonymous memory; khugepaged; 2 MB only; `always`/`madvise`/`never` policy.
- **3.8 (2013)**: shmem/tmpfs THP support.
- **4.5 (2016)**: `split_huge_pmd()` — per-process PMD split without global compound page split.
- **4.13 (2017)**: THP swap without splitting for single-user pages; order-9 swap cluster allocation.
- **5.4 (2019)**: File THP for page cache (ext4 read-only, experimental).
- **5.18 (2022)**: `madvise(MADV_COLLAPSE)` for synchronous user-driven collapse.
- **5.18 (2022)**: Deferred split shrinker with utilisation-bucket scanning replaces older partial unmap handling.
- **6.1 (2022)**: `PR_THP_DISABLE_EXCEPT_ADVISED` prctl for inverted per-process policy.
- **6.8 (2024)**: Multi-size THP (mTHP) merged; per-size sysfs knobs; intermediate order support for anonymous memory.

## Further Reading

1. [Transparent huge pages in 2.6.38 — LWN.net](https://lwn.net/Articles/423584/)
2. [Transparent Hugepage Support — kernel.org docs](https://www.kernel.org/doc/html/latest/admin-guide/mm/transhuge.html)
3. [The transparent huge page shrinker — LWN.net](https://lwn.net/Articles/906511/)
4. [Transparent huge page reference counting — LWN.net](https://lwn.net/Articles/619738/)
5. [Two talks on multi-size THP performance — LWN.net](https://lwn.net/Articles/974826/)
6. [Improving control over transparent huge page use — LWN.net](https://lwn.net/Articles/1032199/)
7. [Transparent huge pages in the page cache — LWN.net](https://lwn.net/Articles/686690/)

## LKML Highlights

- **Initial THP merge** — `1285975428-2574-1-git-send-email-aarcange@redhat.com` (Andrea Arcangeli, 2010): The original RFC; reviewers debated whether khugepaged should be a thread or a workqueue item, and whether `always` mode would be safe for latency-sensitive workloads like databases.
- **THP swap** — `20170522062031.1905-1-ying.huang@intel.com` (Ying Huang, 2017): Enabling swap of whole THP without splitting; the review surfaced a subtle race in `add_to_swap_cache()` when inserting compound folios into the swap cache xarray, resolved by folio-level locking.
- **mTHP** — `20231207161211.2374093-1-ryan.roberts@arm.com` (Ryan Roberts, 2023): Multi-size THP RFC; debate centred on whether sub-PMD huge pages were worth the page-table walker complexity and whether the allocation fallback strategy (greedy-descending) would cause fragmentation under sustained load.
