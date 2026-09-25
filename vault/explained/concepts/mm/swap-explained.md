---
title: "Swap — Explained"
category: explained
original: "[[swap]]"
subsystem: mm
tags: [explained, mm, swap, zswap, zram]
converted: 2026-09-25
---

# Swap, explained

> Plain-language companion to [[swap|the technical note]]. Same facts, fewer identifiers.

## The problem

File data in RAM can always be dropped and re-read from its file. **Anonymous** memory (heaps, stacks, private copies) has no file behind it. Without somewhere else to put it, it can never be reclaimed: once anonymous memory adds up to more than physical RAM, the OOM killer must start killing.

Swap gives anonymous pages a place to go. The difficulties are keeping track of where each page went, avoiding races when several processes share a swapped page or touch it mid-transfer, and making it fast enough to be useful, which led to compressing pages in RAM before (or instead of) writing them out.

## The idea in one paragraph

Swap is **a cold-storage annex next to RAM**. When the apartment fills up, rarely used boxes (anonymous pages) are moved to the annex (a swap partition or file), and the page-table entry is replaced by a note saying where the box went. Touching that address later brings the box back. A **swap cache** keeps boxes that are in transit findable, so nobody fetches the same box twice. **zswap** adds a compressed vestibule in RAM, where many boxes are squeezed and never reach the annex; **zram** makes the annex itself out of compressed RAM.

## Step by step

### Step 1: Activate swap areas
A swap area is a partition or a regular file, turned on with `swapon`. The kernel checks its header and records its size. Up to 32 areas can be active. Higher-priority areas are used first; areas with equal priority are used in rotation, spreading the load.

### Step 2: Slots and swap entries
Each area is divided into page-sized **slots**. A slot is identified by a **swap entry**: which area, and which slot within it, packed into one number. Two bits of that number are reserved so a swap entry stored in a page-table entry can never be mistaken for a valid mapping by the hardware (the "present" bit is always clear).

Each slot has a **reference count**: how many page-table entries point at it. Zero means free. Special values mark slots in use permanently or damaged. Slots are allocated in clusters of 256 consecutive slots, so related pages end up next to each other, which helps readahead on spinning disks and makes scanning for free slots cheaper.

### Step 3: The swap cache
Pages heading to or from swap pass through the **swap cache**, which reuses the page-cache machinery with swap entries as keys. It solves two races:
- a page is being written out and another process faults on it before the write completes: it must find the page in flight, not start a second I/O
- after `fork`, parent and child share a swap entry; if the parent faults it back in first, the page stays findable so the child doesn't re-read it from disk

### Step 4: Swapping out
Reclaim picks an anonymous page and:
1. allocates a slot (getting a swap entry)
2. puts the page in the swap cache under that entry and marks it dirty
3. writeback writes it to the swap device
4. every page-table entry mapping the page is replaced with the swap entry. The CPU now sees "not present"; any access will fault.
5. once only the swap cache holds the page, its memory is freed and it leaves the cache

### Step 5: Swapping in
Touching a swapped-out address faults, and the swap-in handler takes over:
- **swap cache hit:** the page is still in memory (being written, or brought in by another thread). Map it, drop one slot reference, done. No I/O.
- **miss:** allocate a page, put it in the swap cache, read it from the device (with readahead of nearby slots, 8 pages by default), wait, then map it.

On fast devices, a page with only one mapping can skip the swap cache entirely on swap-in, since nobody else can be racing for it. That saves inserting and removing a cache entry.

### Step 6: zswap: compress before writing
This is the key performance step on most systems. **zswap** (3.11) intercepts pages on their way to the swap device, compresses them (LZ4, zstd and so on), and keeps them in a memory pool instead. On swap-in, it intercepts again and decompresses, with no disk access. When the pool fills (by default up to 20% of RAM), it writes its least recently used entries to the real swap device. Most swap I/O simply disappears; only pages that stay cold long enough reach the disk. Benchmarks showed 53% shorter runtimes and 76% less I/O than plain swap.

### Step 7: zram: a compressed RAM disk as swap
**zram** (3.14) creates a block device made of compressed RAM, which is then used as an ordinary swap device. The swap code doesn't know about compression. zswap needs a real swap device behind it; zram needs no disk at all, which makes it the choice for Chromebooks and Android phones. For servers with NVMe, zswap is almost always better, since it overflows gracefully to fast storage without pre-committing RAM to a device.

### Step 8: Turning swap off
Deactivating an area with `swapoff` must bring every page in it back into memory, walking every process's page tables to find the entries. It's slow.

## The picture

```text
 RAM full ─▶ reclaim picks anonymous page
               │ allocate slot (area 1, slot 4711) → swap cache
               ▼
        ┌───── zswap enabled? ─────┐
        yes                         no
  compress into RAM pool       write to swap device
  (pool full → oldest           
   entries written to device)
               │
 page-table entry := "swapped: area 1, slot 4711"  → page freed

 later access ─▶ fault ─▶ swap cache hit? map it
                          zswap hit?      decompress
                          else            read from device (+ readahead)
```

## Tradeoffs

- **What it gives you:** workloads can briefly exceed physical RAM without being killed; with zswap, much of the cost is a compression rather than disk I/O.
- **What it costs / requires:** swapped pages are slow to bring back (a disk read, or at least a decompression); compressed pools and zram consume RAM themselves.
- **Where it bites:** under heavy swapping, latency spikes as pages are refaulted, and `swapoff` can take a long time. Reusing the page cache for swap is elegant but means some fast paths must cope with a swap entry where a file offset would normally be. The swap-entry bit layout is effectively fixed, because every architecture's page-table code depends on it.

## How it got here

- **0.12 (1992):** one swap partition, no clustering.
- **2.4:** swap files as efficient as partitions. **2.6:** up to 32 areas and a stable swap-entry format.
- **3.11 (2013):** zswap, merged as staging (Seth Jennings). **3.14 (2014):** zram into mainline.
- **4.13 (2017):** huge pages swapped without first splitting them (Ying Huang).
- **5.8–6.0:** the fast swap-in path for fast devices; per-cgroup zswap limits; non-blocking zswap writeback.
- **~6.15 (in progress):** a "swap table" (Kairui Song) replaces the per-device swap-cache index with a simple per-cluster array, cutting lookups to an array access and shrinking per-slot bookkeeping from about 11 bytes to 8. A broader swap rework was debated at LSF/MM 2025.

## Related

- Technical version: [[swap]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[page-reclaim-explained|Page reclaim]]: decides what gets swapped
- [[page-fault-handler-explained|Page fault handler]]: swap-in starts here
- [[page-cache-explained|Page cache]]: the machinery the swap cache reuses
- [[memory-cgroup-explained|Memory cgroups]]: per-group swap limits
- [[block-explained|Block layer]]
