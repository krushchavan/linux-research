---
title: "Folio"
category: concept
tags: [mm, folio, page-cache, compound-pages, thp, memory-management]
subsystem: mm
kernel_version: "5.16"
researched: 2026-04-16
status: complete
explained: "[[folio-explained]]"
sources:
  - https://kernel-internals.org/mm/folio/
  - https://lwn.net/Articles/849538/
  - https://lwn.net/Articles/856016/
  - https://lwn.net/Articles/893512/
  - https://lwn.net/Articles/937239/
  - https://lwn.net/Articles/1015320/
  - https://lwn.net/Articles/954094/
  - https://www.kernel.org/doc/html/latest/core-api/mm-api.html
  - https://github.com/torvalds/linux/blob/master/include/linux/mm_types.h
---

# Folio

> 📘 Plain-language version: [[folio-explained]]

## Purpose

A `struct folio` is a physically contiguous, power-of-two-aligned group of pages with one invariant: a folio pointer is **always** a pointer to the head — there are no tail folios. Before folios, the kernel used *compound pages* (a head page followed by tail pages), but nothing in the type system prevented a function from receiving a tail page and silently doing the wrong thing. Folios exist to enforce that guarantee in the compiler so that thousands of defensive `compound_head()` calls scattered across filesystems, network stacks, and memory managers can be replaced by a single clean type.

## Mental Model

Think of the old compound page as a receipt whose pages might be handed to you out of order — you had to keep checking "am I holding page 1?" before doing anything meaningful. A folio is the same receipt, stapled at the corner, and the rule is simple: you always hold the first page. No checking required. If you have a `struct folio *`, you have the whole unit, and you own the right to ask how many pages it spans.

## How It Works

### The Compound-Page Problem

Before 5.16, large memory units were expressed as *compound pages*: a head `struct page` followed by N−1 tail `struct page` entries. When code received a `struct page *` it had to ask, constantly: is this a head or a tail? The pattern `page = compound_head(page)` appeared in thousands of call sites. Two bugs lurk here. First, if a caller forgets the call and operates on a tail page, it silently reads garbage fields — `page->mapping`, `page->index`, and the reference count all live only in the head. Second, the C type system cannot distinguish "a pointer that must be a head" from "a pointer that might be a tail"; both are `struct page *`.

Matthew Wilcox quantified the hidden cost: almost every `PageFoo()` flag test contains an implicit `compound_head()` dereference inside the macro. The compiler cannot cache it across multiple tests. On hot paths like `page_cache_get()`, the load appeared tens of millions of times per second on production systems.

### The Folio Guarantee

`struct folio` is defined in `include/linux/mm_types.h`. In its simplest form it is:

```c
struct folio {
    /* private: don't use directly, use folio_page() */
    union {
        struct {
            unsigned long flags;
            ...
        };
        struct page page;
    };
};
```

The critical design decision is that `struct folio` *overlays* `struct page` at offset zero. A `struct folio *` cast to `struct page *` always points to the head. The kernel enforces this with a compile-time `static_assert` that `offsetof(struct folio, page) == 0`. This layout compatibility means the conversion can proceed incrementally: a function that receives a `struct folio *` can safely cast it to `struct page *` when calling legacy code, and vice versa for code that has already been converted.

The type system now enforces the head-page guarantee. Any function whose parameter is `struct folio *` is — by definition — operating on an entire, possibly multi-page unit. A function still using `struct page *` is either unconverted legacy code or intentionally working with a single base page.

### Conversion: page_folio() and folio_page()

Two functions bridge the old and new worlds. `page_folio(page)` converts *any* `struct page *` — head or tail — into its owning folio, using the same `_compound_head()` logic that was previously scattered everywhere, but doing it exactly once at the boundary:

```c
static inline struct folio *page_folio(struct page *page)
{
    unsigned long head = READ_ONCE(page->compound_head);
    if (unlikely(head & 1))
        return (struct folio *)(head - 1);
    return (struct folio *)page;
}
```

In the common case (order-0 pages), the branch is not taken and `page_folio` is a no-op cast. For compound pages, it follows the `compound_head` link once. Converted call sites call `page_folio()` at the function entry point and then use folio-native APIs throughout, meaning the `_compound_head()` overhead is paid exactly once instead of inside every flag macro.

`folio_page(folio, n)` goes the other direction: it does simple pointer arithmetic to retrieve the nth constituent `struct page` within a folio, needed when legacy interfaces require a `struct page *`:

```c
static inline struct page *folio_page(const struct folio *folio, size_t n)
{
    return &folio->page + n;
}
```

### Size and Order

Every folio carries its allocation order in a flag field in the head page. The key accessors are:

- `folio_order(folio)` — allocation order (0 = single 4 KB page; N = 2^N pages)
- `folio_nr_pages(folio)` — total base pages in the folio
- `folio_size(folio)` — byte size (= `folio_nr_pages() << PAGE_SHIFT`)
- `folio_shift(folio)` — log₂ of byte size

An order-0 folio is a single 4 KB page — the common case for anything not using readahead or anonymous large folios. An order-9 folio on a 4 KB–page system is 2 MB, matching a PMD-mapped THP region.

### Reference Counting

Reference counting happens exclusively at the folio level. Tail pages have no independent reference counts — they do not exist as folio types, only as raw `struct page` entries accessible via `folio_page()`.

Two primary acquisition functions exist:

- `folio_get(folio)` — increments the reference count. **Requires a pre-existing reference.** Calling this on a folio with a zero count is a use-after-free bug.
- `folio_try_get(folio)` — speculatively increments using an atomic CAS; returns false if the count has already reached zero. Use this when you discovered the folio pointer from a data structure but haven't yet secured ownership — e.g., while walking the page cache under RCU.

The corresponding releases are `folio_put()` (decrements; frees when count reaches zero) and the page-compatible `put_folio()`. The distinction between get/try-get mirrors the same distinction for refcounting any reference-counted kernel object: never call `folio_get()` speculatively because the window between "saw this folio in a structure" and "incremented the count" can race with reclaim dropping the count to zero.

### Page Cache Integration

The page cache stores folios rather than pages in its XArray. Modern lookups return `struct folio *` via `filemap_grab_folio()` or `__filemap_get_folio()`. When a readahead window is satisfied, the readahead code (`mm/readahead.c`) may allocate large folios (order > 0) to reduce the number of cache entries and subsequent page faults. Drivers iterate readahead folios with `readahead_folio()` inside their `->readahead` address-space operation.

Filesystems that have converted their address-space operations expose `->read_folio` and `->readahead` in terms of `struct folio *`; those that haven't yet are bridged by shim functions in `mm/folio-compat.c` that accept the legacy `struct page *` and call through to the folio-native path.

### LRU and Reclaim

LRU management treats a folio as a single eviction unit. A 512-page (2 MB) folio occupies one LRU list entry, not 512. This was Wilcox's "insane" observation: on workloads with many large pages, LRU list lengths dropped by a factor of 1000, making list traversal in `shrink_lru_list()` far cheaper. The tradeoff is that reclaim cannot partially evict a folio — all 512 pages are either resident or gone. Partial reclaim, if needed, requires first *splitting* the folio.

### Writeback

Dirty state is tracked at the folio level. When a single byte in a 2 MB folio is dirtied, the entire folio is written back. This is a deliberate tradeoff: fewer writeback operations (each covers 2 MB instead of 4 KB) reduce I/O queue depth and syscall overhead, and on copy-on-write filesystems the whole-unit write is often necessary anyway. On simple append workloads, `generic_perform_write()` with large folios can double write throughput by eliminating per-base-page overhead in the write path.

### Large Folios for Anonymous Memory (mTHP)

Separate from page-cache large folios, multi-size THP (mTHP) extends the large-folio idea to anonymous memory. When a process faults in anonymous memory, the kernel attempts to allocate and map a larger folio (default: 64 KB on arm64) instead of a single 4 KB page. If the larger allocation fails due to fragmentation or alignment constraints, it falls back to base pages gracefully. The performance benefit is twofold: fewer page faults (one fault covers 16 × 4 KB pages) and, on arm64, the contiguous PTE hardware bit allows a 64 KB folio to occupy a single TLB entry. Benchmarks show ~5% reduction in kernel compilation time from this alone.

## Key Data Structures

**`struct folio`** (`include/linux/mm_types.h`) — represents one physically contiguous unit of memory, guaranteed to be the head. Overlays `struct page` at offset 0.
- `flags` — the same `page->flags` field, accessible directly; includes PG_locked, PG_dirty, PG_writeback, PG_uptodate, PG_referenced, PG_lru, and folio-order bits
- `_refcount` (via `page._refcount`) — atomic reference count; 0 means no live references
- `_mapcount` (via `page._mapcount`) — number of page-table entries pointing into this folio
- `mapping` (via `page.mapping`) — pointer to the owning `struct address_space`; low bits encode mapping type
- `index` (via `page.index`) — offset within the mapping (in pages), used to key the XArray slot

**`struct address_space`** (`include/linux/fs.h`) — the page cache for an inode or swap device; contains the XArray of `struct folio *` entries. Not a folio struct itself, but the primary container.

## Key Functions / Entry Points

**`page_folio(page)`** (`include/linux/mm.h`) — converts any `struct page *` (head or tail) to its owning folio; the universal entry point for legacy code entering converted call sites.

**`folio_page(folio, n)`** (`include/linux/mm.h`) — retrieves the nth constituent `struct page *` from a folio; used to call legacy APIs that require raw `struct page *`.

**`folio_get(folio)`** (`include/linux/mm.h`) — increments refcount; caller must already hold a reference.

**`folio_try_get(folio)`** (`include/linux/mm.h`) — speculatively increments refcount using CAS; returns false if already at zero; safe to call while discovering folios under RCU.

**`folio_put(folio)`** (`include/linux/mm.h`) — decrements refcount; frees folio when it reaches zero.

**`filemap_grab_folio(mapping, index)`** (`mm/filemap.c`) — looks up or creates a folio in the page cache at the given index; returns a locked folio with elevated refcount.

**`readahead_folio(rac)`** (`include/linux/pagemap.h`) — returns the next folio from a readahead control structure; called by `->readahead` implementations in drivers and filesystems.

**`folio_lock(folio)` / `folio_unlock(folio)`** (`include/linux/pagemap.h`) — acquires/releases the per-folio lock (PG_locked bit); serialises page-cache I/O against concurrent readers and writers.

**`folio_mark_dirty(folio)`** (`include/linux/pagemap.h`) — sets PG_dirty on the folio and adds it to the writeback dirty list; does not trigger immediate writeback.

**`folio_nr_pages(folio)`** (`include/linux/mm.h`) — returns the number of base pages in the folio; the fast path checks the order field in `folio->flags`.

## Important Flags & Config Options

**`CONFIG_TRANSPARENT_HUGEPAGE`** — enables THP; large folios in the page cache and anonymous large folios both build on the compound-page infrastructure this provides.

**`CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS` / `CONFIG_TRANSPARENT_HUGEPAGE_MADVISE`** — controls THP promotion policy; "always" allows large anonymous folios on all eligible mappings; "madvise" restricts them to regions marked with `MADV_HUGEPAGE`.

**`FLEXIBLE_THP` / `multi-size THP` Kconfig** (6.6+) — enables mTHP for anonymous memory with sizes below 2 MB (e.g., 16 KB, 64 KB). Defaults to disabled pending completion of compaction, mlocking, and madvise support.

**`/sys/kernel/mm/transparent_hugepage/hpage_pmd_size`** — reports the default large-folio size (usually 2 MB); read-only.

**`/sys/kernel/mm/transparent_hugepage/hugepages-<size>kB/enabled`** (6.6+) — per-size control for mTHP; valid values are `always`, `inherit`, `madvise`, `never`.

**PG_large folio bit** (in `page->flags`) — distinguishes multi-page folios from base-page folios; set by the allocator when order > 0.

## Interactions with Other Subsystems

- **↑ Userspace**: userspace `read()`, `write()`, `mmap()`, `madvise(MADV_HUGEPAGE)` all influence folio allocation size and placement, but users never directly observe `struct folio`
- **→ [[page-cache]]**: folios *are* the page cache; the XArray stores `struct folio *` entries; all lookup, insertion, and invalidation operates on folios
- **→ [[transparent-huge-pages]]**: THP's compound-page allocation is the underlying mechanism behind large folios; `folio_order()` is essentially the THP order exposed through a clean type
- **→ [[page-reclaim]]**: the LRU lists hold folio pointers; `shrink_folio_list()` evicts whole folios; the inability to partially evict a large folio creates pressure to split it before reclaim
- **→ [[rmap-reverse-mapping]]**: rmap walks all PTEs pointing into a folio to unmap it during reclaim or migration; large folios mean one rmap entry can cover multiple pages
- **→ [[memory-cgroup]]**: memcg charges are tracked per folio; large folios simplify charge accounting by reducing the number of charge operations
- **← Filesystems (VFS)**: filesystems implementing `->read_folio`, `->readahead`, `->writepages`, and `->write_begin`/`->write_end` receive `struct folio *`; unconverted filesystems use shims in `mm/folio-compat.c`
- **← Block layer**: block I/O submitters receive folio-backed bio pages; the block layer remains page-centric internally but the mapping from folio to bvec is handled by the iomap layer

## Design Decisions & Tradeoffs

**Overlay vs. separate struct**: Rather than creating a fully independent `struct folio` in one shot, Wilcox chose to overlay it with `struct page` at offset zero. This allowed incremental conversion without flag-day rewrites — converted callers use `struct folio *`, unconverted callers use `struct page *`, and the cast between them is always correct. The long-term goal (post-2025) is to separate them entirely and shrink `struct page` to a single `u64`, recovering ~1.6% of system RAM currently consumed by page metadata.

**Write amplification**: Tracking dirty state at folio granularity means a single-byte write to a 2 MB folio writes back 2 MB. The tradeoff was accepted because: (1) most real workloads write large regions, (2) COW filesystems require whole-unit writes anyway, (3) the reduction in writeback queue depth and per-page overhead outweighs the amplification in typical benchmarks.

**Reclaim granularity**: Folio splitting (`folio_split()`, `split_folio()`) was added specifically to handle the case where reclaim needs to evict part of a large folio. Splitting is expensive (requires unmapping all PTEs, rebuilding rmap entries) but rare — it only happens when memory pressure forces partial eviction, which large-folio workloads deliberately avoid.

**No tail folios**: The decision to forbid tail folios entirely (vs. allowing them with a flag) is what makes the type guarantee hard. Any code that tries to create a tail-folio pointer will fail a compile-time assertion. This strictness was deliberate: Wilcox's analysis found that 80% of folio-related bugs in the pre-5.16 codebase came from functions that received tail pages and forgot to chase the compound head pointer.

## How It Has Evolved

**5.16 (Jan 2022)**: Initial folio type introduced; ~5 KB of text removed from the kernel. Page cache lookups return `struct folio *`; `folio_get`/`folio_put`/`folio_lock`/`folio_unlock` APIs land. Netfs and iomap subsystems convert to folio-native paths.

**5.17–5.18**: Block layer, XFS, writeback, slab, and most `address_space` operations converted. Large folios (order > 0) enabled in the readahead path.

**6.0–6.5**: Broad filesystem conversion (btrfs, ext4, f2fs, tmpfs). `folio_split()` added for partial reclaim. mTHP patchwork begins.

**6.6 (Nov 2023)**: Multi-size THP for anonymous memory (`FLEXIBLE_THP`) merges as an opt-in feature; per-size sysfs controls added. `mapping_set_folio_order_range()` lets filesystems advertise preferred folio sizes.

**6.7–6.9**: mTHP default-enables for order-0 anonymous folios on most architectures; arm64 contiguous-PTE optimization lands. LRU list reductions of 1000× observed in production.

**2025 direction**: Separating `struct folio` from `struct page` structurally; shrinking `struct page` toward a `u64` descriptor; completing the buffer-head → folio transition; adding `zpdesc` for zswap-backed pages.

## Further Reading

1. [Clarifying memory management with page folios — LWN.net](https://lwn.net/Articles/849538/) — Wilcox's original rationale; the clearest explanation of the type-system problem
2. [Memory folios — LWN.net](https://lwn.net/Articles/856016/) — patch series coverage; performance numbers and scope of the conversion
3. [A memory-folio update — LWN.net](https://lwn.net/Articles/893512/) — post-5.16 status; large-folio writeback semantics and lock-ordering issues
4. [Large folios for anonymous memory — LWN.net](https://lwn.net/Articles/937239/) — mTHP design; arm64 contiguous PTE; benchmarks
5. [Multi-size THP for anonymous memory — LWN.net](https://lwn.net/Articles/954094/) — mTHP kernel acceptance; per-size sysfs controls
6. [The state of the page in 2025 — LWN.net](https://lwn.net/Articles/1015320/) — Wilcox's 2025 roadmap; zpdesc; folio independence goal
7. [Matthew Wilcox's folio talk at LPC 2022 (PDF)](https://www.infradead.org/~willy/linux/2022-06_LCNA_Folios.pdf) — design rationale from the author; covers overlay approach and long-term goals

## LKML Highlights

**[PATCH v5 00/27] Memory Folios** (`20210322184744.GU1719932@casper.infradead.org`) — the cover letter for the merge-candidate series; Wilcox lays out the type-system argument in detail and answers reviewer questions about the overlay design vs. a clean-break approach.

**[PATCH v9 00/10] Multi-size THP for anonymous memory** (`20231214160251.3574571-1-ryan.roberts@arm.com`) — Ryan Roberts' mTHP series; the thread debates default-on policy, FLEXIBLE_THP Kconfig placement, and the interaction with `madvise(MADV_NOHUGEPAGE)` for mixed-size workloads.
