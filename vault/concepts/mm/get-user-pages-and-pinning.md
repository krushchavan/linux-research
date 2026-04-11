---
title: "get_user_pages and Memory Pinning"
category: concept
tags: [mm, gup, pinning, dma, rdma, foll-pin]
subsystem: mm
kernel_version: "2.6 (get_user_pages); 5.6 (pin_user_pages/FOLL_PIN)"
researched: 2026-04-11
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/core-api/pin_user_pages.html
  - https://lwn.net/Articles/807108/
  - https://lwn.net/Articles/753027/
  - https://lwn.net/Articles/787636/
  - https://lwn.net/Articles/895439/
  - https://lwn.net/Articles/930667/
  - https://github.com/torvalds/linux/blob/master/mm/gup.c
  - https://github.com/torvalds/linux/blob/master/Documentation/core-api/pin_user_pages.rst
---

# get_user_pages and Memory Pinning

## Purpose

When kernel code — a DMA engine, an RDMA driver, a Direct I/O path — needs to work directly on the contents of user-space pages, it must guarantee those pages stay resident in RAM and cannot be moved, reclaimed, or swapped while the hardware holds a physical address to them. `get_user_pages()` (GUP) and the newer `pin_user_pages()` family provide that guarantee by faulting pages in if necessary and then holding an elevated reference that prevents the page allocator from reclaiming them.

## Mental Model

Think of a page as a hotel room and its reference count as the number of key cards handed out. Normal processes (user-space mappings) each hold one key card. GUP is the front-desk service that hands a *different kind* of key card — a DMA card — directly to the hardware. Without a way to tell DMA cards apart from ordinary ones, the hotel cannot safely renovate a room that a guest thinks is empty but that actually has hardware sitting inside it. `FOLL_PIN` and `GUP_PIN_COUNTING_BIAS` exist to make DMA cards visually distinct.

## How It Works

### Entry points and the two paths

The public API splits along two dimensions: who is calling (the current process vs. a remote mm) and how fast the operation must be.

**`get_user_pages_fast()` / `pin_user_pages_fast()`** are the hot path. They disable interrupts and walk the page tables optimistically, reading PTEs with `ptep_get_lockless()`, without holding `mmap_lock`. Interrupts-off guarantees that no page table freeing TLB shootdown can race with the walk (the CPU's own pagetable walker uses the same trick). If the fast walk encounters anything non-trivial — a PROT_NONE mapping, a swap entry, a huge-page split in progress — it aborts and hands off to the slow path. Benchmarks show the lockless fast path reduces `__down_read` / `__up_read` overhead from ~2.8 % of cycles to ~0.05 %, a roughly 10 % overall speedup for DIO-heavy workloads.

**The slow path** calls `__get_user_pages()` (in `mm/gup.c`) with `mmap_lock` held for reading. This is the path that can actually fault a page in: it calls `faultin_page()` → `handle_mm_fault()` → the arch page-fault handler if the PTE is absent. After faulting, it loops back and re-checks the PTE. This retry loop is important because a fault may install a page in the page table but another thread could immediately unmap it; the loop detects that and either retries or returns a short count.

Both paths ultimately call `try_grab_folio()` (formerly `try_grab_page()`), which is where the reference counting actually diverges based on the flag.

### FOLL_GET vs FOLL_PIN: the core distinction

`FOLL_GET` — used internally by the old `get_user_pages()` callers — increments `page->_refcount` by exactly 1. A page with `_refcount == 2` could mean one user mapping plus one GUP reference, or it could mean two anonymous COW sharers plus nothing at all. There is no way to tell.

`FOLL_PIN` — used by `pin_user_pages*()` — takes a very different approach depending on folio size:

- **Single-page (order-0) folios**: `_refcount` is incremented by `GUP_PIN_COUNTING_BIAS` (= 1024). Any page whose `_refcount` is ≥ 1024 is considered DMA-pinned. Only 11 bits remain for additional ordinary references, but that is far more than any process will ever hold simultaneously for one page.
- **Large folios** (compound pages, huge pages): the bias scheme would overflow with only a handful of pins, so the kernel instead maintains a dedicated `folio->_pincount` field. `try_grab_folio()` increments `_pincount` directly and leaves `_refcount` untouched for this purpose.

The practical rule is simple: if the caller intends to let hardware *read or write the page's data* (DIO buffer, RDMA MR, vDPA descriptor ring), use `FOLL_PIN`. If the caller only needs the `struct page` pointer alive long enough to inspect metadata, `FOLL_GET` suffices.

`FOLL_PIN` and `FOLL_GET` are mutually exclusive within a single GUP call; multiple threads can independently pin the same page with either flag simultaneously.

### FOLL_LONGTERM: the RDMA tier

`FOLL_LONGTERM` is a stricter overlay on top of `FOLL_PIN`. It signals that the pin may last minutes or hours — an RDMA memory region that persists for the life of a connection, for example. The additional constraints are:

1. DAX pages (persistent-memory pages that live outside the normal page allocator) cannot be longterm-pinned, because there is no reliable way to notify the filesystem that layout changes are impossible.
2. The kernel may need to migrate the page to a non-moveable zone before granting the pin, to avoid blocking the balloon driver or memory-hotplug from ever reclaiming that physical frame.

Callers use `FOLL_PIN | FOLL_LONGTERM` explicitly; all the `pin_user_pages*()` wrappers accept it as an additive flag at call sites (unlike bare `FOLL_PIN`, which is internal).

### Releasing pins

Every `pin_user_pages*()` call must be balanced by `unpin_user_page()` or `unpin_user_pages()`. These decrement by `GUP_PIN_COUNTING_BIAS` (or `_pincount`) and then call `put_page()` to drop the structural reference. `folio_maybe_dma_pinned()` lets filesystem code ask "is this folio currently DMA-pinned?" before proceeding with operations like writeback or truncation that cannot safely race with hardware writes.

### The zero page special case

The global zero page (`ZERO_PAGE(0)`) is read-only by definition. When GUP is asked to pin it with write intent the kernel handles it via COW. Without write intent, zero pages are "pretend-pinned": they are returned to the caller without incrementing the refcount at all, because the zero page cannot be reclaimed or moved regardless.

### COW pages and the PG_anon_exclusive fix

The original GUP design had a subtle security hole (CVE-2020-29374). Suppose a process calls `vmsplice()` on a COW page. GUP bumps `_refcount` to 2. The kernel now sees `mapcount == 1, refcount == 2` and decides no one else could be mapping it — so it allows a write without copying. But the GUP caller still holds a reference to the old physical page, which now has new data written to it from behind the GUP caller's back.

The fix introduced `PG_anon_exclusive` (PAE): an anonymous page is marked exclusive when exactly one process maps it in a writable VMA. The invariant is:

- Only PAE pages may be pinned for content access.
- A writable anonymous page must always be PAE.
- If a read-only anonymous page that is not PAE needs to be pinned, GUP first triggers a "copy-on-read" unsharing to create a fresh exclusive copy, then pins it.

This makes the COW race impossible: pinning a page promotes it to exclusive, and a COW fault on an exclusive page always produces a fresh copy rather than silently sharing the pinned original.

## Key Data Structures

**`struct folio`** (`include/linux/mm_types.h`) — the unit of reference counting since Linux 5.16; a page or compound page seen as a single entity.
- `_refcount` — structural reference count; GUP bumps by `GUP_PIN_COUNTING_BIAS` for small folios
- `_pincount` — dedicated DMA pin counter for large (order > 1) folios; avoids overflow of the bias scheme
- `flags` — includes `PG_anon_exclusive` (bit `PG_mapcount_reserve`) to track exclusivity for COW safety

**`struct page`** (`include/linux/mm_types.h`) — one physical page frame; for order-0 pages the folio *is* the page.
- `_refcount` — same as folio for single pages; the field the bias is encoded into

## Key Functions / Entry Points

**`pin_user_pages()`** (`mm/gup.c`) — primary slow-path entry for callers that want content access; sets `FOLL_PIN`; called by RDMA, vhost, io_uring, etc.

**`pin_user_pages_fast()`** (`mm/gup.c`) — lockless fast-path entry; interrupts-off PTE walk; falls back to `pin_user_pages()` on failure.

**`pin_user_pages_remote()`** (`mm/gup.c`) — like `pin_user_pages()` but for pinning pages in a *different* process's mm; holds `mmap_lock` for that mm.

**`unpin_user_page()` / `unpin_user_pages()`** (`mm/gup.c`) — decrements pin count and drops structural reference; must be called once per page per successful pin call.

**`get_user_pages()`** (`mm/gup.c`) — legacy entry point; sets `FOLL_GET`; appropriate only when the caller manipulates page metadata, not hardware-accessible data.

**`get_user_pages_fast()`** (`mm/gup.c`) — lockless fast path for `FOLL_GET`; same interrupt-off PTE walk as the pin variant.

**`try_grab_folio()`** (`mm/gup.c`) — internal; given a folio and flags, performs the actual reference-count increment (bias or pincount); called from both fast and slow paths.

**`folio_maybe_dma_pinned()`** (`include/linux/mm.h`) — returns true if the folio appears to be DMA-pinned; used by filesystems to gate writeback and truncation.

**`__get_user_pages()`** (`mm/gup.c`) — slow-path core; holds mmap_lock, loops over the requested range, calls `faultin_page()` for missing PTEs, calls `try_grab_folio()` after each successful lookup.

## Important Flags & Config Options

| Flag | Value | Meaning |
|---|---|---|
| `FOLL_GET` | 0x01 | Increment refcount by 1 (metadata reference) |
| `FOLL_WRITE` | 0x02 | Fault in with write intent; needed for writable DMA buffers |
| `FOLL_PIN` | 0x40000 | Increment by `GUP_PIN_COUNTING_BIAS`; internal to gup; do not set at call sites |
| `FOLL_LONGTERM` | 0x10000 | Allowed at call sites; requires FOLL_PIN; bars DAX pages; may trigger zone migration |
| `FOLL_FORCE` | 0x10 | Bypass VMA permissions; used by ptrace; dangerous in DMA context |
| `FOLL_NOFAULT` | 0x80 | Do not fault in missing pages; return a short count instead |

**`GUP_PIN_COUNTING_BIAS`** (= 1024, `mm/gup.c`) — the sentinel value added to `_refcount` for small-folio pins. Changing it would break the `folio_maybe_dma_pinned()` check.

**`/proc/vmstat/nr_foll_pin_acquired`** — monotonically increasing count of logical pins taken; compare with `nr_foll_pin_released` to detect pin leaks.

**`CONFIG_DEBUG_VM`** — enables additional assertions in the GUP slow path checking PTE consistency.

## Interactions with Other Subsystems

- **↑ Userspace**: user-space calls DIO (`pread`/`pwrite` with `O_DIRECT`), `vmsplice`, or issues RDMA operations via `ibv_reg_mr`; the kernel paths below those syscalls call into GUP.
- **→ Page allocator / folio**: GUP increments refcounts that prevent the allocator from ever reclaiming the page; the allocator trusts these counts absolutely.
- **→ [[page-table-management]]**: fast GUP reads PTEs without locking; slow GUP holds mmap_lock to serialize with `mmap`/`munmap`/`mprotect`.
- **→ [[page-fault-handler]]**: slow GUP calls `faultin_page()` → `handle_mm_fault()` to bring absent pages into RAM before pinning.
- **→ [[rmap-reverse-mapping]]**: rmap is consulted to locate all mappings of a page when GUP needs to unshare a COW page before pinning.
- **← RDMA / DMA engines**: the primary consumers of `FOLL_PIN`; hold pins for the lifetime of a memory region or I/O operation.
- **← [[address-space]] / writeback**: filesystems call `folio_maybe_dma_pinned()` to block writeback or truncation while hardware holds a pin.
- **← io_uring**: uses `pin_user_pages()` for fixed buffer registration (`IORING_REGISTER_BUFFERS`).
- **← [[transparent-huge-pages]]**: huge-page splits must check `folio_maybe_dma_pinned()`; cannot split a longterm-pinned huge page.

## Design Decisions & Tradeoffs

**Overloading refcount rather than adding a new field.** `struct page` is notoriously size-constrained (every extra byte multiplies across millions of pages). The `GUP_PIN_COUNTING_BIAS` trick recycles the existing `_refcount` field. The accepted quirk: any page that legitimately acquires 1024+ ordinary references will be falsely reported as pinned. In practice this cannot happen; no process can hold that many independent references to a single page.

**Large-folio pincount field.** For compound pages, the bias scheme breaks down: a 2 MB huge page contains 512 base pages, so only ~2 pins fit before overflow. The solution is the dedicated `folio->_pincount` field introduced as folios became first-class citizens. This also enables exact pin counts rather than approximate bias-based detection.

**`FOLL_PIN` is internal.** Call sites must not set `FOLL_PIN` directly; they call `pin_user_pages*()`. This design allows the kernel to change the implementation (e.g., the folio pincount addition) without auditing every driver.

**`FOLL_LONGTERM` is allowed at call sites.** Unlike `FOLL_PIN`, `FOLL_LONGTERM` is user-visible because the number of wrappers required to hide it would be impractical.

**No lease mechanism (yet).** Several proposals to introduce leases (a contract between the filesystem and the pinner that allows truncation to force a SIGBUS) were debated at LSFMM 2019. The community could not agree on SIGBUS vs. EBUSY semantics; neither approach was merged, and the race between GUP longterm pins and DAX truncation remains an open architectural problem as of 2023.

**Blocking FOLL_LONGTERM writes to file-backed pages.** Lorenzo Stoakes proposed (2023) refusing write-intent longterm GUP on file-backed pages entirely, since the filesystem cannot prevent a DMA write after it has made the page read-only for writeback. David Hildenbrand considered even this a band-aid. Ted Ts'o documented an ext4 crash caused by the race. No consensus was reached on merging even the partial fix.

## How It Has Evolved

**Pre-5.0 — the original GUP.** `get_user_pages()` existed since early kernel history. It had no concept of DMA vs. metadata references. Long-term RDMA pins silently broke writeback and DAX truncation.

**~4.0–5.0 — lockless fast path.** `get_user_pages_fast()` introduced a lockless interrupt-off PTE walk that avoided `mmap_lock` entirely on the common case, providing ~10 % performance improvement for DIO.

**5.6 (2020) — pin_user_pages / FOLL_PIN.** John Hubbard's patchset introduced the `pin_user_pages*()` API, `FOLL_PIN`, and `GUP_PIN_COUNTING_BIAS`. Three hundred+ call sites across drivers were audited and converted where appropriate.

**5.14 (2021) — folio foundation.** The `struct folio` abstraction began landing; the `folio->_pincount` field for large folios was added as huge pages became a serious use case.

**5.17 (2022) — PG_anon_exclusive.** David Hildenbrand introduced `PG_anon_exclusive` to fix the COW-pinning race (CVE-2020-29374 class). GUP now enforces exclusivity before granting a `FOLL_PIN` on anonymous pages.

**6.x ongoing — file-backed longterm GUP.** The problem of write-intent GUP on file-backed pages during writeback remained unresolved as of kernel 6.3; proposals to block it with `FOLL_LONGTERM` were discussed but not merged.

## Further Reading

1. [Explicit pinning of user-space pages — LWN 2020](https://lwn.net/Articles/807108/) — the original announcement of `pin_user_pages` and the design rationale.
2. [The trouble with get_user_pages() — LWN 2018](https://lwn.net/Articles/753027/) — the LSFMM session that catalysed the problem recognition.
3. [get_user_pages(), pinned pages, and DAX — LWN 2019](https://lwn.net/Articles/787636/) — the lease debate and DAX complications.
4. [get_user_pages() and COW, 2022 edition — LWN 2022](https://lwn.net/Articles/895439/) — PG_anon_exclusive and the COW security fix.
5. [The ongoing trouble with get_user_pages() — LWN 2023](https://lwn.net/Articles/930667/) — file-backed page write hazard and the unresolved debate.
6. [kernel.org: pin_user_pages() documentation](https://www.kernel.org/doc/html/latest/core-api/pin_user_pages.html) — canonical reference for flags, use cases, and diagnostic counters.
7. `mm/gup.c` — the implementation; `try_grab_folio()` is the central function for understanding reference counting.

## LKML Highlights

- **`20250305174511.186748725@linuxfoundation.org`** (Greg Kroah-Hartman, 2025) — stable backport: "mm: Don't pin ZERO_PAGE in pin_user_pages()"; confirms that zero-page special-casing in GUP was a correctness issue, not just an optimisation.
- **`20240812181238.1882310-1-yang@os.amperecomputing.com`** (Yang Shi, 2024) — "mm: gup: stop abusing try_grab_folio"; the refactoring that cleaned up `try_grab_folio()` semantics after the folio pincount addition, revealing that the old code had been mixing FOLL_GET and FOLL_PIN counting paths incorrectly.
