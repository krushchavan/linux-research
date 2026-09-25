---
title: "Huge Pages and hugetlbfs — Explained"
category: explained
original: "[[huge-pages-hugetlbfs]]"
subsystem: mm
tags: [explained, mm, huge-pages, tlb, reservations]
converted: 2026-09-25
---

# Huge pages and hugetlbfs, explained

> Plain-language companion to [[huge-pages-hugetlbfs|the technical note]]. Same facts, fewer identifiers.

## The problem

Every memory access starts with an address translation, and the CPU caches recent translations in a small **TLB**. A miss costs a page-table walk of 10 to 100 cycles. With 4 KB pages, a 64-entry TLB covers just 256 KB; a 1 GB working set needs 262,144 translations. Big databases, HPC jobs, AI inference and virtual machines spend real time missing the TLB.

**Huge pages** fix that: one translation covers 2 MB (or 1 GB on x86), so the same 64 entries cover 128 MB. Typical gains are 2–7% for databases and 1–45% for scientific HPC.

But a huge page must be a physically contiguous, aligned block, which gets hard to find once memory is fragmented. An application that maps huge-page memory needs a guarantee that the pages will actually be there when it touches them, not a crash halfway through.

## The idea in one paragraph

Keep a **pool** of huge pages set aside in advance (ideally at boot, while memory is unfragmented) and make applications opt in explicitly through a special filesystem, **hugetlbfs**, or a mapping flag. Think of a hotel block booking: when the application maps the memory, the kernel *reserves* rooms from the pool on its behalf. The physical page is only handed over on first touch, but because it was reserved at mapping time, the application can never be told "no room" at that point. hugetlbfs (2002) predates transparent huge pages and remains the choice when you need guarantees, 1 GB pages, or shared page tables.

## Step by step

### Step 1: One pool per huge page size
The kernel keeps one pool per supported size (on x86, typically 2 MB and 1 GB). Each tracks total pages, free pages, **reserved** pages, and **surplus** pages, with free lists per NUMA node. What can actually be handed out is *free minus reserved*: a reserved page counts as used even before anyone touches it.

### Step 2: Fill the pool
At boot the kernel allocates the requested number of contiguous huge pages and puts each on its node's free list. The pool size can be changed at runtime, and optionally the kernel may create **surplus** pages on demand, up to a limit, which are released when returned. Filling at boot matters: that's when large contiguous blocks are easiest to find.

### Step 3: Give applications access
Three ways in:
- mount **hugetlbfs** and `mmap` a file on it; every file there is backed by huge pages
- map anonymous memory with a "huge TLB" flag (since 2.6.32), no mount needed, choosing 2 MB or 1 GB
- System V shared memory with a huge-page flag (the oldest interface, default size only)

A mount can also carry its own **sub-pool**, with a minimum reserved from the global pool when it's mounted and an optional maximum.

### Step 4: Reserve at mapping time
This is the key step. When `mmap` is called, the kernel records a **reservation map** for the mapping and debits the pool. From then on, first touch will always find a page.

Updates happen in two phases so they can't fail halfway:
1. **Check and prepare:** count how many pages in the range aren't reserved yet, and allocate the bookkeeping entries needed. This phase may sleep; the pool can be checked here.
2. **Commit or abort:** splice the prepared entries in (or discard them). This phase must never fail.

Once the pool has been debited, the map update is guaranteed to succeed, so the pool's reserved count and the maps always agree.

For private mappings, the map is kept inverted: an empty map means "every page is reserved", and entries are added only as reservations are used up. That avoids filling in a huge range up front.

### Step 5: First touch
Touching the memory faults. The huge-page fault handler:
1. builds the page-table path down to the level where one entry covers 2 MB or 1 GB
2. checks the reservation map
3. takes a page from the pool (or makes a surplus page if allowed) and installs a single large mapping
4. marks the page so that, if it's freed, the reservation is restored correctly

For shared file mappings, if another process already built the page-table level for this part of the file, the new process can **share that page-table page** outright (on x86, arm64, RISC-V). Processes then share not only the data but the translation structures, saving memory for big shared-memory databases.

### Step 6: fork and copy-on-write
For private mappings, the process that made the reservation is its **owner**. After `fork`, the child is not. If the child writes (copy-on-write) and the pool is empty, the child gets SIGBUS, because its write wasn't covered. The owner always succeeds, since the reservation was made for it.

## The picture

```text
 boot: pool of 2 MB pages  [■][■][■][■][■][■]  (per-NUMA-node free lists)

 mmap 3 huge pages ──▶ reservation map: pages 0–2 reserved
                       pool: free 6, reserved 3 → available 3
 first touch page 0 ──▶ fault → take page from pool → one 2 MB mapping
                       reserved 2, free 5

 shared file mapping in process B ──▶ reuse A's page-table page (shared)

 fork: child writes, pool empty ──▶ child: SIGBUS   owner: always succeeds
```

## Tradeoffs

- **What it gives you:** far fewer TLB misses, deterministic availability (no surprise failure on first touch), 1 GB pages, and shared page tables for big shared mappings.
- **What it costs / requires:** explicit opt-in by the application, and pool pages are locked away from everything else. They're never swapped, because swap only works on 4 KB pages and would have to break them up, so the pool must be sized conservatively.
- **Where it bites:** the kernel has grown about 11 special cases for hugetlbfs scattered through memory management, and page-table sharing needs complex locking. A 2023 effort aims to fold these into the large-folio machinery. Transparent huge pages are easier for most workloads but only best-effort.

## How it got here

- **2.5.46 (2002):** hugetlbfs, the pool, and huge-page shared memory; used by Oracle and DB2 from 2.6.0.
- **Before 2.6.18:** pages were allocated at `mmap` time, which on NUMA machines placed them before any thread touched them, often on the wrong node.
- **2.6.18:** allocation moved to first touch, with reservations for shared mappings.
- **2.6.29:** reservations extended to private mappings, giving both the no-SIGBUS guarantee.
- **2.6.32:** anonymous huge-page mappings without a mount. **3.x:** per-size controls and several sizes at once.
- **6.x:** splitting ("demoting") 1 GB pages into 2 MB ones in place; unification with folios under way. A 2022 RFC proposed mapping parts of a huge page to reduce waste.

## Related

- Technical version: [[huge-pages-hugetlbfs]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[transparent-huge-pages]]: the automatic, best-effort alternative
- [[folio-explained|Folios]]: the large-page machinery hugetlbfs is being unified with
- [[page-table-management]], [[numa-memory-policy-explained|numa-memory-policy]], [[memory-compaction-explained|memory-compaction]], [[memory-cgroup-explained|memory-cgroup]]
