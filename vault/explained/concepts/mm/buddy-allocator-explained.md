---
title: "Buddy Allocator — Explained"
category: explained
original: "[[buddy-allocator]]"
subsystem: mm
tags: [explained, mm, page-allocator, fragmentation]
converted: 2026-09-25
---

# The buddy allocator, explained

> Plain-language companion to [[buddy-allocator|the technical note]]. Same facts, fewer identifiers.

## The problem

Somebody has to own all of physical RAM and answer one question, fast: "give me N contiguous physical pages". Many callers need contiguity: devices doing DMA, huge pages, kernel structures. And when pages are freed, small free pieces must be recombined into large ones, or memory slowly crumbles into fragments that can't satisfy big requests even though plenty is free in total.

Every other allocator in the kernel (the slab allocator, vmalloc, the page cache) ultimately gets its pages from here, so it has to be quick and predictable.

## The idea in one paragraph

Hand out memory only in **power-of-two blocks** (1, 2, 4, ... 1024 pages). Picture parking lots in a strict hierarchy: one lot of 1024 spaces, two of 512, four of 256, and so on. To get 16 spaces, take the smallest free lot that fits, splitting a bigger lot in half repeatedly if needed. When you leave, check whether the lot you were split from, your **buddy**, is also free; if so, merge back into the bigger lot, and repeat. The buddy's address is found with **a single XOR**, no searching, so deciding whether to merge is instant.

## Step by step

### Step 1: Organise memory into zones and orders
RAM is split into **zones** per NUMA node (DMA, DMA32, NORMAL, MOVABLE), for devices and uses with different addressing limits. Within each zone, blocks are grouped by **order**: order 0 is one 4 KB page, order 10 is 1024 pages (4 MB). Each order has its own free list.

### Step 2: Allocate
Look at the free list for the requested order. If there's a block, take it. If not, go up one order, split that block into two buddies, put one on the lower list and use the other. Keep going up until something is found or every order is empty.

### Step 3: Free and merge
Put the freed block back on its list. Compute its buddy's address by flipping one bit (XOR with the block size). If the buddy is free too, take both off the list, merge them into a block of the next order, and check *that* block's buddy. Stop when a buddy is busy or the top order is reached.

This is the key step. The XOR trick makes each merge decision constant-time, which keeps freeing cheap and lets memory heal back into large blocks on its own.

### Step 4: Keep movable and unmovable apart
Each order's free list is further split by **migration type**:
- **unmovable:** kernel structures that can never be relocated
- **movable:** user pages, which compaction can move elsewhere
- **reclaimable:** page-cache data that can be dropped
- plus reserved types for emergency atomic allocations, for large contiguous device regions (CMA), and for pages being migrated

Without this, one unmovable kernel page landing in the middle of a region could block it from ever merging into a large block. Grouping by type confines that damage, and compaction can always shift movable pages out of the way to open up a contiguous run.

### Step 5: Watermarks decide when to get help
Each zone has thresholds. Falling below **low** wakes the background reclaimer (kswapd). Falling below **min** makes the allocating process reclaim memory itself before continuing. Below *min* there's a small reserve only for allocations that can't sleep (interrupt context), so those can always succeed.

### Step 6: The slow path
If the quick path fails, the allocator wakes background reclaim, tries **compaction** to defragment, reclaims directly, and as a last resort invokes the OOM killer.

### Step 7: What it deliberately doesn't track
The buddy allocator only knows free versus allocated. It doesn't track *who* holds a page; each page's own reference count does that. Keeping those jobs apart keeps the hot path simple: allocate, return, forget.

## The picture

```text
 order 3 (8 pages):  [ A: 8 free ]
                        │ need 2 pages → split
 order 2 (4 pages):  [ A1 ][ A2 ]         A2 stays free on order-2 list
                       │ split
 order 1 (2 pages):  [a][b]               b stays free; a is handed out
 
 later, free a:
   buddy of a = a XOR size  →  b  free? yes → merge → A1
   buddy of A1 = A2          free? yes → merge → A (order 3)

 each order's list is split by type: unmovable │ movable │ reclaimable │ reserves
```

## Tradeoffs

- **What it gives you:** constant-time buddy lookup, logarithmic merging, predictable latency, and physically contiguous blocks when needed.
- **What it costs / requires:** internal waste from rounding up to a power of two. The note's example: a 3-page request takes a 4-page block, wasting 25%. Kernel design consistently picks bounded latency over perfect use of space.
- **Where it bites:** high-order (big) allocations can still fail on a fragmented system even with lots of free memory in total; that's what migration types, compaction and CMA exist to fight. Grouping by type occasionally forces one type to "steal" from another's lists.

## How it got here

- **Linux 1.0:** a basic buddy allocator with one zone.
- **2002–2003:** per-CPU page lists to relieve zone-lock contention; NUMA-aware per-node zones.
- **2.6.24 (2008):** migration types, in preparation for compaction and huge pages.
- **2.6.35 (2010):** memory compaction, because huge-page and high-order allocations were failing on fragmented systems.
- **3.5 (2012):** CMA integration for drivers needing large contiguous buffers.
- **5.13–6.6:** larger orders for bigger huge pages, and self-tuning per-CPU lists for 200+ CPU machines.
- **2026 (RFC):** Johannes Weiner proposed merging the per-CPU and buddy layers into a per-CPU pageblock allocator.

## Related

- Technical version: [[buddy-allocator]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[per-cpu-page-allocator-pcp]]: the lock-free layer in front of it
- [[memory-compaction-explained|memory-compaction]]: how fragmentation gets undone
- [[page-reclaim-explained|page-reclaim]], [[oom-killer-explained|oom-killer]]: what the slow path calls
- [[slub-slab-allocator]], [[vmalloc]], [[page-cache-explained|page-cache]]: its main customers
- [[dma-mapping-api-explained|DMA mapping API]]: why contiguous memory matters
