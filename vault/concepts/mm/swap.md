---
title: "Swap"
category: concept
tags: [mm, swap, zswap, zram, anonymous-memory, page-reclaim]
subsystem: mm
kernel_version: "2.4+"
researched: 2026-04-05
status: complete
sources:
  - https://kernel-internals.org/mm/swap/
  - https://www.kernel.org/doc/gorman/html/understand/understand014.html
  - https://www.kernel.org/doc/html/latest/mm/swap-table.html
  - https://lwn.net/Articles/537422/
  - https://lwn.net/Articles/1016136/
  - https://lwn.net/Articles/1059201/
  - https://lwn.net/Articles/1064478/
---

# Swap

## Purpose

Swap extends a system's effective memory beyond physical RAM by moving anonymous pages — those with no on-disk backing other than swap space — to persistent storage under memory pressure. Without swap, the OOM killer would fire as soon as anonymous allocations collectively exceed physical RAM; with it, the kernel can tolerate workloads whose working sets temporarily exceed installed memory, at the cost of latency when swapped pages are refaulted.

## Mental Model

Think of swap as a cold-storage annex next to RAM. When the apartment (RAM) fills up, infrequently used boxes (anonymous pages) get moved to the annex (swap device). Retrieving them is slow, but the apartment stays usable. zswap adds a compressed vestibule between RAM and the annex: many boxes are squeezed before they reach cold storage, and some never make it there at all.

## How It Works

### Swap areas and struct swap_info_struct

A swap area is either a dedicated partition or a regular file. Both are activated with `swapon(2)`, which calls `do_swapon()` in `mm/swapfile.c`. The kernel scans the first page (the swap header) to verify the magic signature, records the total page count, and allocates the structures describing the area.

Each active swap area is represented by a `struct swap_info_struct` (defined in `include/linux/swap.h`):

```c
struct swap_info_struct {
    unsigned long   flags;          /* SWP_USED, SWP_WRITEOK, ... */
    signed short    prio;           /* priority: higher = preferred */
    struct file    *swap_file;      /* file or block device */
    unsigned char  *swap_map;       /* reference count per slot */
    unsigned int    max;            /* total slot count */
    unsigned int    pages;          /* usable (non-bad) slots */
    unsigned int    cluster_next;   /* next cluster to allocate */
    unsigned int    cluster_nr;     /* slots left in current cluster */
    spinlock_t      lock;
    /* ... */
};
```

Up to `MAX_SWAPFILES` (32) areas can be active simultaneously. The global `swap_info[]` array holds pointers to them; `nr_swapfiles` tracks how many are in use. When multiple areas are configured, `get_swap_page()` selects among them by priority: higher-priority areas are exhausted first; equal-priority areas are striped round-robin.

### Swap slots and swp_entry_t

Swap space is divided into page-sized **slots**. Each slot's location is encoded in a `swp_entry_t`, which is an unsigned long split into two bitfields:

- **Bits 1–6**: type — index into `swap_info[]` (identifies the swap area)
- **Bits 8–31+**: offset — slot number within that area's `swap_map`

Bits 0 and 7 are reserved so that a `swp_entry_t` stored in a PTE cannot be confused with a valid physical address or a null pointer. The macros `SWP_TYPE()`, `SWP_OFFSET()`, and `SWP_ENTRY()` handle encode/decode.

`swap_map` is a flat array of `unsigned char` (or `unsigned short` in some paths), one entry per slot, holding a **reference count** — the number of page-table entries pointing at that slot. A count of zero means the slot is free. `SWAP_MAP_MAX` marks a slot as permanently in use (shared COW pages can push refcounts arbitrarily high). `SWAP_MAP_BAD` marks a damaged sector discovered during I/O.

Slot allocation happens in `scan_swap_map()`, which walks `swap_map` starting from `cluster_next`, grouping allocations into clusters of `SWAPFILE_CLUSTER` (256) consecutive slots to keep related pages physically adjacent on disk and improve readahead effectiveness.

### The swap cache

Before a page reaches the swap device it passes through the **swap cache**: a conceptual layer built directly on the page cache infrastructure. The swap cache uses `swapper_space` as the `address_space` and stores pages keyed by their `swp_entry_t` (packed into the `folio->index` field, which normally holds a file offset).

The swap cache exists to solve two races:
1. **Write-before-read race**: if a page is being written to swap and a second process faults on the same address before the write completes, the second process must find the in-flight page rather than issuing a duplicate I/O.
2. **Fork-then-fault race**: after `fork()`, both parent and child share a `swp_entry_t` pointing at the same slot. If the parent faults the page back in before the child does, the page stays in the swap cache (still keyed by the old `swp_entry_t`) so the child can find it without re-reading disk.

`add_to_swap_cache()` inserts a folio into the swap cache; `lookup_swap_cache()` finds it; `delete_from_swap_cache()` removes it once the swap entry can be freed.

### Swap-out path

[[Page Reclaim]] identifies anonymous pages as reclaim candidates and calls `add_to_swap()`, which:
1. Calls `get_swap_page()` to allocate a slot, obtaining a `swp_entry_t`.
2. Calls `add_to_swap_cache()` to place the folio in the swap cache under that entry.
3. Marks the folio dirty so the page-cache writeback mechanism will flush it.

The flusher thread eventually calls `swap_writepage()`, which writes the folio's data to the swap device via `submit_bio()`. Once the write completes, reclaim calls `try_to_unmap()` to remove all PTEs pointing to the physical page, replacing each PTE with the encoded `swp_entry_t`. The CPU's MMU now sees the PTE as "not present" — any access will fault. With all PTEs removed and the folio's `_refcount` back to 1 (only the swap cache holds it), the page frame is released to the buddy allocator and the folio is removed from the swap cache by `__delete_from_swap_cache()`.

At this point the slot's `swap_map` entry reflects the number of PTEs that encoded the `swp_entry_t` (one per process that mapped it); each call to `swap_duplicate()` during COW fork increments this count.

### Swap-in path (do_swap_page)

When a process accesses a page whose PTE contains a `swp_entry_t`, the hardware raises a page fault. The fault handler dispatches to `do_swap_page()` in `mm/memory.c`:

1. **Swap cache hit**: `lookup_swap_cache()` finds the folio already in memory (it was faulted in by another thread, or hasn't been written out yet). The PTE is updated to the folio's physical address, `swap_free()` decrements `swap_map`, and the fault returns. No I/O.

2. **Swap cache miss**: `read_swap_cache_async()` allocates a new folio, inserts it into the swap cache, and submits a read via `swap_readpage()`. The calling process sleeps waiting for I/O completion. Once the read completes, `finish_swap_writeback()` marks the folio uptodate, the PTE is installed, and the folio is eventually removed from the swap cache when all references are gone.

SSD-backed swap areas can set `SWP_SYNCHRONOUS_IO` to bypass the swap cache for single-user pages and do synchronous I/O directly, eliminating the cache insertion overhead when there is no sharing.

### zswap: compressed in-memory swap cache

**zswap** (merged 3.11) is a write-behind compressed cache that sits between reclaim and the swap device. When reclaim calls `swap_writepage()`, zswap intercepts the call via the **frontswap** hooks, compresses the folio using a kernel crypto algorithm (lz4, zstd, etc.), and stores the compressed data in a zsmalloc pool rather than writing to disk.

The compressed entry is tracked in a `struct zswap_entry` and indexed in a per-swap-device red-black tree (or, in newer kernels, an XArray) keyed by swap offset. When `do_swap_page()` calls `swap_readpage()`, zswap intercepts again, decompresses from the pool, and satisfies the fault without touching the disk.

When the zswap pool fills, it **writes back** the least-recently-used compressed entries to the actual swap device, freeing pool space. This two-stage design means most swap I/O simply disappears; only pages that stay cold long enough reach the device. Benchmarks show 53% runtime reduction and 76% I/O reduction versus raw swap.

zswap is configured via `/sys/module/zswap/parameters/` (enabled, max_pool_percent, compressor, zpool) and via `CONFIG_ZSWAP`.

### zram: compressed block device

**zram** (merged 3.14) takes a different approach: it creates a `/dev/zramN` block device backed entirely by compressed RAM. This device is then used as a swap destination (`mkswap /dev/zram0; swapon /dev/zram0`). The kernel's swap machinery treats zram like any other block device — it has no knowledge of compression.

The key difference from zswap is architectural:
- **zswap** intercepts at the swap layer and still needs a real backing device for writeback.
- **zram** *is* the backing device; no physical disk is needed.

zram is preferred for embedded systems with no persistent storage (Chromebooks, Android phones). zswap is preferred for general-purpose desktops and servers where a real swap partition exists, because it avoids pre-committing RAM to the block device.

### Swap table (in progress, ~6.15)

Historically, the swap cache was implemented with an XArray per swap device. The emerging **swap table** design (Kairui Song) replaces this with a per-cluster array of pointers — one pointer per slot within a `SWAPFILE_CLUSTER`-sized cluster. Each entry is the same width as a PTE.

The per-cluster layout exploits the observation that swap cache lookups almost always have the cluster already in hand (they originate from the hot reclaim or fault path). A simple array dereference with RCU protection replaces a tree traversal, improving cache locality and reducing lock contention. The swap table also consolidates the reference count and cache state into fewer bytes per slot (8 bytes versus the current ~11 bytes when counting all related state).

## Key Data Structures

**`struct swap_info_struct`** (`include/linux/swap.h`) — one per active swap area; anchors the slot map, cluster state, device file pointer, and priority.

**`swp_entry_t`** (`include/linux/swapops.h`) — encoded unsigned long identifying one swap slot; used as the PTE value when a page is evicted and as the key into the swap cache.

**`swap_map`** (field of `swap_info_struct`) — `unsigned char[]` array, one byte per slot, storing the reference count; zero = free, `SWAP_MAP_BAD` = damaged.

**`struct zswap_entry`** (`mm/zswap.c`) — compressed representation of one swapped page: node in per-device tree, reference count, swap offset, and a zsmalloc `handle` pointing to the compressed data.

**`swapper_space`** (`mm/swap_state.c`) — the `address_space` used as the backing object for all swap cache folios; its `a_ops` (`swap_aops`) provide the `writepage` and `readpage` methods that dispatch to the swap device.

## Key Functions / Entry Points

**`get_swap_page()`** (`mm/swapfile.c`) — allocates one slot from the highest-priority area with free space; calls `scan_swap_map()` for cluster-aware allocation.

**`add_to_swap()`** (`mm/swap_state.c`) — called by reclaim to enter a folio into the swap pipeline; allocates a slot and inserts into the swap cache.

**`add_to_swap_cache()`** (`mm/swap_state.c`) — inserts a folio into `swapper_space` keyed by `swp_entry_t`.

**`lookup_swap_cache()`** (`mm/swap_state.c`) — fast path for swap-in; returns folio if already in memory, NULL on miss.

**`do_swap_page()`** (`mm/memory.c`) — fault handler entry for not-present PTEs containing a `swp_entry_t`; orchestrates cache lookup, I/O, PTE installation.

**`swap_writepage()`** (`mm/page_io.c`) — writes one folio to swap; intercepted by zswap if enabled, otherwise dispatches to block I/O.

**`swap_readpage()`** (`mm/page_io.c`) — reads one folio from swap; intercepted by zswap on a cache hit.

**`swap_free()`** (`mm/swapfile.c`) — decrements `swap_map[offset]`; frees the slot when count reaches zero.

**`try_to_unuse()`** (`mm/swapfile.c`) — walks all page tables to reclaim swap entries when a swap area is deactivated via `swapoff`; expensive O(n) operation over all mm structs.

## Important Flags & Config Options

| Knob | Location | Effect |
|------|----------|--------|
| `vm.swappiness` | sysctl | 0–200; bias toward file eviction (low) vs anon swap-out (high); default 60 |
| `vm.page-cluster` | sysctl | log₂ of pages read ahead on swap-in; default 3 (= 8 pages) |
| `CONFIG_ZSWAP` | Kconfig | enables zswap compressed swap cache |
| `zswap.enabled` | module param / sysfs | runtime enable/disable of zswap |
| `zswap.max_pool_percent` | sysfs | max % of total RAM for compressed pool; default 20 |
| `zswap.compressor` | sysfs | compression algorithm (lz4, zstd, lzo, …) |
| `CONFIG_ZRAM` | Kconfig | enables zram compressed block device |
| `SWP_SYNCHRONOUS_IO` | swap_info flag | skip swap cache for single-PTE anonymous pages on fast devices |
| `/proc/swaps` | procfs | list active swap areas, sizes, and usage |
| `swapon -p <prio>` | userspace | set priority of a swap area at activation time |

## Interactions with Other Subsystems

- **↑ Userspace**: `swapon(2)` / `swapoff(2)` activate and deactivate areas; `madvise(MADV_PAGEOUT)` hints pages for immediate swap-out; `/proc/meminfo` exposes `SwapTotal`, `SwapFree`, `SwapCached`.
- **← [[Page Reclaim]]**: reclaim identifies anonymous folios for eviction and calls `add_to_swap()`; the swap subsystem is purely reactive — it does not initiate eviction.
- **→ [[Block Layer]]**: `swap_writepage()` and `swap_readpage()` submit BIOs directly to the block device, bypassing the filesystem and VFS layers.
- **→ [[Page Cache]]**: the swap cache is implemented on top of `swapper_space`, reusing all page cache infrastructure (folios, xarray, writeback state machine).
- **← [[Page Fault Handler]]**: `do_swap_page()` is invoked from the architecture-specific fault handler when a not-present PTE encodes a `swp_entry_t`.
- **→ [[Memory Cgroups (memcg)]]**: cgroup v2 `memory.swap.max` limits per-cgroup swap consumption; per-memcg swap counters are tracked in `struct mem_cgroup`.

## Design Decisions & Tradeoffs

**Swap cache as page cache layer**: Reusing the page cache for swap storage was an elegant design choice — the same writeback state machine, the same folio lifecycle, and the same LRU integration work for both file-backed and swap-backed pages. The cost is that the page cache's `address_space` abstraction must handle the case where `folio->index` is a `swp_entry_t` rather than a file offset, complicating some fast paths.

**Cluster allocation**: Grouping slot allocation into 256-page clusters keeps related pages adjacent on spinning disk (good for sequential readahead) and reduces `swap_map` scan cost. On SSDs the clustering benefit is minimal, but the scan-cost reduction still matters.

**swp_entry_t bit layout**: Reserving bits 0 and 7 ensures a `swp_entry_t` stored in a PTE can be distinguished from a valid physical PTE by hardware page walkers that check `_PAGE_PRESENT` (bit 0). This was a deliberate ABI constraint — changing it would require all architectures to update their PTE-handling assembly.

**zswap vs zram**: zswap intercepts at the logical swap layer, preserving the real swap device as overflow; zram *is* the device. zswap cannot operate without a backing device; zram needs no disk. For servers with NVMe, zswap is almost always better (the pool evicts gracefully to fast storage); for Android where no persistent swap exists, zram is the only option.

**SWP_SYNCHRONOUS_IO fast path**: Anonymous pages with only one PTE (no sharing) can skip the swap cache entirely during swap-in, because there is no race to win — no other process can be faulting the same slot simultaneously. This avoids a radix-tree insert + delete pair at the cost of a flag check.

## How It Has Evolved

- **0.12 (1992)**: Original swap implementation — single swap partition, no clustering.
- **2.4**: Swap files achieve partition-equivalent efficiency via `swap_extent` mapping.
- **2.6**: Per-zone LRU integration; swap areas increase to 32; `swp_entry_t` encoding stabilised.
- **3.11 (2013)**: zswap merged as a staging driver; frontswap hooks provide the interception point.
- **3.14 (2014)**: zram promoted from staging to mainline.
- **4.13 (2017)**: Transparent Huge Page swap — THP pages can be swapped without splitting into base pages first.
- **5.8 (2020)**: `SWP_SYNCHRONOUS_IO` fast path for NVMe/fast-device swap-in bypasses swap cache.
- **5.18 (2022)**: zswap gains per-cgroup accounting and `memory.zswap.max` knob.
- **6.0 (2022)**: zswap writeback to backing device made non-blocking; pool size no longer a hard wall.
- **~6.15 (in progress)**: Swap table per-cluster design replacing XArray-backed swap cache, reducing overhead and lock contention.

## Further Reading

1. [The zswap compressed swap cache — LWN.net](https://lwn.net/Articles/537422/)
2. [Three ways to rework the swap subsystem — LWN.net](https://lwn.net/Articles/1016136/)
3. [Modernizing swapping: virtual swap spaces — LWN.net](https://lwn.net/Articles/1059201/)
4. [Debunking zswap and zram myths — LWN.net](https://lwn.net/Articles/1064478/)
5. [Chapter 11: Swap Management — Gorman's "Understanding the Linux VM"](https://www.kernel.org/doc/gorman/html/understand/understand014.html)
6. [Swap Table — kernel.org docs](https://www.kernel.org/doc/html/latest/mm/swap-table.html)

## LKML Highlights

- **zswap merge** — `20130923172024.GA13451@dragon.maxrebo.com` (Seth Jennings): The original zswap submission; debate centred on whether the frontswap hooks were a stable enough interface and whether a staging merge was appropriate given the complex interaction with swap writeback ordering.
- **THP swap** — `20170522062031.1905-1-ying.huang@intel.com`: Ying Huang's series enabling huge-page swap without splitting; the discussion exposed a subtle race in `add_to_swap_cache()` when inserting compound folios into the swap cache xarray.
- **Swap table phase I** — `20240926064148.1346789-1-ryncsn@gmail.com` (Kairui Song): First phase of the swap table redesign; reviewers questioned whether the per-cluster locking granularity was finer enough and whether the RCU lookup path was safe under all reclaim orderings.
