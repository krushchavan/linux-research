---
title: "Memory Management (mm) — Explained"
category: explained
original: "[[mm]]"
subsystem: mm
tags: [explained, mm, memory, virtual-memory, reclaim]
converted: 2026-09-25
---

# Memory management (mm), explained

> Plain-language companion to [[mm|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Every program wants lots of memory, all its own, at convenient addresses. The machine has a fixed amount of RAM, shared by everyone. The memory-management subsystem ("mm") sits between those two facts and has to solve three interlocked problems at once:

1. give each process the illusion of a private, practically unlimited address space
2. share the finite physical memory safely among all those illusions
3. produce free memory fast enough that allocations almost never have to wait for a disk write

It is maintained by Andrew Morton on the linux-mm mailing list and lives almost entirely in the kernel's `mm/` directory.

## The big picture

Think of RAM as **a parking garage with a fixed number of spaces**. mm is the garage management system. It gives each driver a map showing an unlimited lot (virtual address space), but only assigns a real space the moment the driver actually tries to park (a page fault on first use). When the garage fills up, an attendant quietly moves cold cars to an overflow lot (swap) or drops cars that can be fetched again (cached file data). The guiding principle: **promising space is free; handing out real space is put off until unavoidable.**

```text
 USER SPACE      malloc / mmap / brk / read
                        │ reserve a range (no RAM yet)       │ file read
                        ▼                                    ▼
 PER PROCESS     address-space map (VMAs) ──first touch──▶ page fault handler
                                                               │ need a page
 KERNEL          small objects (SLUB)    big virtual buffers (vmalloc)
 ALLOCATORS             │                         │
                        ▼                         ▼
 PHYSICAL        per-CPU page cache ◀──refill── buddy allocator (all free RAM)
                        ▲                         ▲   │ running low
                        │                         │   ▼
                 page cache (file data) ◀──evict── reclaim (kswapd, LRU) ──▶ swap
```

Every allocation path ends at the **buddy allocator**, the single source of physical pages. The per-CPU layer above it removes contention; slab and vmalloc serve the kernel's own needs; the page cache and reclaim keep the garage from ever completely filling.

## The pieces

### The buddy allocator: who owns physical RAM

The only authority on which physical pages are free. See [[buddy-allocator-explained|buddy-allocator]].

1. Memory is handed out in power-of-two blocks called **orders** (order 0 = 4 KB up to order 10 = 4 MB), inside **zones** per NUMA node (DMA, DMA32, NORMAL, MOVABLE). Each zone has a free list per order.
2. **Allocate:** take a block of the right order. If there's none, split a bigger block in half repeatedly, putting the spare halves on the lower lists.
3. **Free:** put the block back and check its **buddy**, the neighbouring block it was split from, found with a single XOR on the page number. If the buddy is also free, merge them and repeat upward.
4. **Fighting fragmentation:** every page is tagged by how movable it is: unmovable kernel structures, movable user pages, or reclaimable cache (plus a few reserved kinds). Keeping these apart means one unmovable kernel page can't permanently block a region from merging into large blocks.
5. **Watermarks:** three thresholds per zone (min, low, high). Below *low*, background reclaim starts; below *min*, the allocating process must help; above *high*, all is well. A small reserve below *min* is kept for allocations from interrupt context, which can't wait.

If the fast path fails, the allocator wakes background reclaim, tries compaction, and finally reclaims directly.

### The per-CPU page cache: avoiding the lock

The buddy allocator's zone lock would choke on a machine with many CPUs. See [[per-cpu-page-allocator-pcp]].

1. Each CPU keeps its own small stock of free pages per zone. Small allocations (the vast majority) pop one with no shared lock.
2. When the stock runs out, it's refilled with a batch under the zone lock, once. When it grows too big, the excess goes back in one batch.
3. Since 6.6 the "too big" threshold tunes itself by watching how often drains happen. On a 224-CPU Sapphire Rapids machine that gave a 5% faster kernel build and 7% better netperf.
4. Under memory pressure, every CPU can be told to hand its stock back so reclaim can see it.

### SLUB: allocating bytes, not pages

The kernel constantly needs objects of tens or hundreds of bytes. Using a whole 4 KB page for a 192-byte object wastes 95% of it. See [[slub-slab-allocator]].

1. Each object type gets a **cache** that carves pages into equal-sized slots.
2. Each CPU has a current page of free slots. Allocating is one atomic swap of a "next free" pointer: no lock.
3. When that runs out, it takes a partially used page from a per-node list, or a fresh page from the buddy allocator.
4. General allocations are routed to power-of-two size caches (8 bytes up to 8 KB); a 100-byte request uses the 128-byte cache.
5. A helper tries this first and falls back to vmalloc for big requests.

SLUB replaced the older SLAB in 2007 not mainly for speed but for simplicity, which made hardening easier: scrambled free-list pointers, randomised slot order, guard bytes, poisoning, and a low-overhead sampling bug detector safe for production. SLOB was removed in 6.4 and SLAB in 6.8.

### vmalloc: big buffers from scattered pages

Physically contiguous memory gets hard to find beyond a few pages once RAM is fragmented. See [[vmalloc]].

1. The kernel reserves a large virtual address region for this.
2. A request finds a free virtual range (a balanced-tree search), allocates pages one at a time from anywhere in RAM, and maps them in so they *look* contiguous.
3. Freeing requires invalidating other CPUs' address caches (TLBs), which is expensive, so freed ranges are collected and invalidated together in batches.
4. Each area ends with an unmapped **guard page**, so an overflow faults immediately instead of corrupting a neighbour.

Used for loaded modules, large driver buffers and device register mappings, but avoided in hot paths because it adds address-translation pressure.

### Virtual memory areas: each process's map

Each process needs its own layout of stack, heap, code, mapped files and libraries, with different permissions. See [[virtual-memory-areas]].

1. A process's memory descriptor holds a tree of **VMAs**, each saying "this address range exists, with these permissions, backed by this file (or nothing), handled by these fault functions".
2. `mmap` finds a gap and records a VMA. **No physical memory is touched.** `munmap` splits or removes VMAs and clears their mappings.
3. Since 6.1, the tree is a **maple tree**, replacing an older pair of structures (a tree plus a list) that had to be kept in sync. It supports lock-free reads.
4. A single per-process read/write lock long protected all VMA changes, and multi-threaded programs with many page faults queued behind it. **Per-VMA locks** (6.4) let a fault lock only its own VMA, so faults on different VMAs run in parallel. The big lock is still needed for structural changes.

### The page fault handler: redeeming promises

Every VMA is a promise; the fault handler is where it's redeemed. See [[page-fault-handler]].

When the CPU hits an address with no valid mapping, it raises a fault. The handler finds the VMA (trying the per-VMA lock first), checks permissions, and decides:
- **First read of anonymous memory:** map the shared **zero page**, one read-only page of zeros shared by everyone. No allocation.
- **First write of anonymous memory:** allocate a fresh zeroed page and map it writable.
- **File-backed memory:** get the page from the page cache, reading from disk on a miss.
- **Write to a read-only shared page (copy-on-write):** if this is the only mapping, make it writable in place; otherwise copy the page first.
- **Swapped-out page:** read it back from swap into a new page.
- **Huge mapping:** allocate a 2 MB page in one go.

Then the faulting instruction resumes as if nothing happened.

### The page cache: file data in RAM

Storage is thousands of times slower than RAM. See [[page-cache]].

1. Each file has a mapping from file offset to cached **folios** (a folio is one or more contiguous pages treated as a unit).
2. A read looks up the offset. A hit copies straight from RAM. A miss allocates a folio, inserts it, reads from disk, then copies.
3. **Readahead** notices sequential reading and fetches ahead, adjusting its window depending on whether its guesses paid off.
4. Writes go into the cache and mark folios **dirty**. Background writeback flushes them; writers are throttled if too much is dirty.

Folios replaced individual page descriptors as the page-cache unit in 5.16. A 2 MB file chunk is now one folio instead of 512 pages, so cache operations no longer loop over 512 pages, and code can no longer quietly assume every page is 4 KB.

### Page reclaim: manufacturing free pages

Free pages have to be actively produced. See [[page-reclaim]].

1. When a zone falls below its *low* watermark, a per-node background thread (**kswapd**) wakes and reclaims until it's back above *high*.
2. It scans for cold pages and decides:
   - **clean file data:** drop it; it can be re-read
   - **dirty file data:** start writeback and try again later
   - **anonymous memory, with swap:** write it to swap and free the page
   - **anonymous memory, no swap:** can't be reclaimed at all
   - **kernel caches:** ask registered "shrinkers" (dentry cache, inode cache...) to release objects
3. If kswapd can't keep up and an allocation drops below *min*, the allocating process reclaims itself (**direct reclaim**), and waits.
4. **Multi-generation LRU** (6.1): the old two-list (active/inactive) scheme let one large sequential file read push a process's own hot pages toward eviction. The new scheme sorts pages into age generations, ages them periodically, and always evicts the oldest, giving much better eviction choices under streaming workloads.
5. **OOM killer:** if nothing works, the kernel scores processes by memory use, adjusted by a per-process setting from -1000 (never kill) to +1000 (kill first), and kills the top one. A cgroup can ask for its whole group to be killed together.

### Swap: extending memory onto storage

Anonymous memory has no file to fall back on, so without swap it would pin RAM forever. See [[swap]].

1. **Out:** reclaim picks an anonymous folio, allocates a swap slot, writes it out, and replaces the mapping with a **swap entry** that records where it went. The page is freed.
2. **In:** touching that address faults; the handler reads the data back into a new page and restores the mapping.
3. A **swap cache** bridges the two, so a page being written out or already read back isn't transferred twice.
4. Several swap devices can have priorities; equal priorities are striped.
5. **zswap** (3.11) adds a compressed in-memory tier first, so compressible data often never reaches the disk.

### Transparent huge pages: fewer, bigger mappings

A 1 GB heap in 4 KB pages needs 262,144 address-translation entries, and the CPU's translation cache (TLB) can't hold them. See [[transparent-huge-pages]].

1. **At fault time:** try to allocate an aligned 2 MB block and map it with one entry. If fragmentation prevents it, fall back to 4 KB.
2. **In the background:** a daemon (khugepaged) finds runs of 512 small pages that could be combined, copies them into one 2 MB page and swaps it in.
3. Partial unmaps or copy-on-write on part of a huge page split it back into small pages.
4. Since 6.8, file-backed mappings can use 2 MB page-cache folios too, helping databases and JVMs that map big files.

## A request's journey

A program calls `malloc(100)` and writes to it:

1. **Reserve.** The C library's cache misses, so it asks the kernel for more memory. The kernel records a new VMA. No RAM is used.
2. **Return.** The program gets a virtual address.
3. **First write faults.** The CPU finds no mapping and raises a page fault.
4. **Find the VMA.** The handler finds the anonymous VMA and sees this is a first write.
5. **Get a page.** It asks the per-CPU stock for a zeroed page. On a miss, the buddy allocator supplies one, and if memory is short, reclaim may run first.
6. **Map and resume.** The handler writes the mapping and the write instruction completes.

Had the program *read* first, it would have got the shared zero page with no allocation at all. Later, under memory pressure, kswapd might swap this page out, and the next access would fault it back in.

## Tradeoffs

- **What it gives you:** instant `malloc`, cheap `fork` (copy-on-write), memory overcommit, almost all RAM usable as cache, and automatic swapping and huge pages.
- **What it costs / requires:** a page fault on first touch; power-of-two blocks waste up to 50% on oddly sized requests; direct reclaim adds latency when background reclaim falls behind.
- **Where it bites:** fragmentation can make large contiguous allocations fail even with plenty of free memory (which is why movability tags and compaction exist). Overcommit means memory can run out *later*, at fault time, which is when the OOM killer steps in. The folio conversion has been a years-long migration.

## How it got here

- **2002:** per-CPU page lists, because many-CPU machines saturated the zone lock.
- **2007–2010:** SLUB becomes the default (2.6.22); movability tags (2.6.24); memory compaction (2.6.35) for huge-page and high-order failures.
- **4.20–5.16:** a new array structure (XArray) for the page cache; folios begin replacing page descriptors.
- **6.1 (2022):** multi-generation LRU and the maple tree.
- **6.4–6.8 (2023–2024):** per-VMA locks, SLOB and then SLAB removed, self-tuning per-CPU lists, file-backed huge pages.
- **Ongoing:** the long tail of folio conversion, multi-size huge pages for anonymous memory, a swap rework debated at LSF/MM 2025, CXL memory tiers, wider per-VMA lock coverage, and a 2026 proposal (Johannes Weiner) to merge the per-CPU and buddy layers.

## Related

- Technical version: [[mm]]
- [[buddy-allocator-explained|buddy-allocator]], [[per-cpu-page-allocator-pcp]], [[slub-slab-allocator]], [[vmalloc]]
- [[virtual-memory-areas]], [[maple-tree-explained|maple-tree]], [[page-fault-handler]], [[page-table-management]]
- [[page-cache]], [[folio-explained|folio]], [[page-reclaim]], [[swap]], [[oom-killer]]
- [[transparent-huge-pages]], [[huge-pages-hugetlbfs-explained|huge-pages-hugetlbfs]], [[memory-compaction-explained|memory-compaction]]
- [[memory-cgroup-explained|memory-cgroup]], [[numa-memory-policy-explained|numa-memory-policy]], [[psi-pressure-stall-information]]
- [[vfs|VFS]], [[block-explained|Block layer]]
