---
title: "Page Reclaim — Explained"
category: explained
original: "[[page-reclaim]]"
subsystem: mm
tags: [explained, mm, reclaim, kswapd, lru, mglru]
converted: 2026-09-25
---

# Page reclaim, explained

> Plain-language companion to [[page-reclaim|the technical note]]. Same facts, fewer identifiers.

## The problem

Linux uses almost all free RAM as cache: file data, process memory, kernel objects. That's efficient, but it means free pages don't just pile up. When a program needs memory, something has to *make* free pages by throwing out or writing out what's there.

Two things make this hard. First, **timing**: if freeing only starts when an allocation is already waiting, that allocation stalls. Second, **choice**: evicting the wrong page (one that's needed again a moment later) costs a disk read and a stalled process, and repeated wrong choices turn into thrashing.

## The idea in one paragraph

Picture a hotel with three alarm levels. At **low**, a background cleaning crew (**kswapd**) starts clearing rooms nobody is using. At **min**, a guest who wants a room must wait while one is hastily cleared (**direct reclaim**). If even that fails, the fire alarm goes off and the biggest occupant is evicted (the OOM killer). To decide which rooms to clear, the kernel tracks roughly how recently each page was used and throws out the coldest, remembering what it evicted so it can notice when it's evicting things that come straight back.

## Step by step

### Step 1: Watermarks
Every memory zone has three thresholds: **high**, **low** and **min**, set at boot from a tunable minimum and scaled to the zone's size. The allocator checks them on every allocation.

### Step 2: Wake the background crew
If an allocation fails its quick path and free memory is below **low**, the allocator wakes kswapd, without waiting for it, and keeps trying with gradually relaxed rules while kswapd works in parallel.

### Step 3: Or reclaim yourself
If free memory has already fallen to **min**, the allocating thread calls reclaim itself, synchronously, and waits until enough is freed. This **direct reclaim** turns what looked like a routine allocation into a stall, so the gap between *low* and *min* is tuned to be big enough that kswapd usually keeps up.

### Step 4: kswapd's loop
There's one kswapd thread per NUMA node. When woken, it goes through the node's zones and reclaims from each one that's below **high**, until all are above it or it has made a set number of passes; then it sleeps again. It runs as a normal kernel thread and can be delayed by other work.

### Step 5: Track what's hot (classic LRU)
Reclaimable pages sit on lists: inactive and active anonymous memory, inactive and active file data, plus an unevictable list for memory locked in RAM. New pages start inactive. A page accessed again while inactive is flagged; accessed again (or found flagged when scanned), it's promoted to active. A page reaching the tail of the inactive list without being referenced is a candidate for eviction. This approximates true LRU cheaply: most accesses only set a flag.

### Step 6: Decide how much of each kind to scan
The kernel balances reclaiming file cache against swapping out anonymous memory using **swappiness** (0–200, default 60, a moderate preference for dropping file cache first). Swappiness 0 doesn't mean "never swap", only "avoid it unless necessary"; 200 prefers swapping over dropping file cache.

### Step 7: Handle each candidate
For each page pulled off the list:
- **clean file page:** unmap it, remove it from the page cache, free it immediately
- **dirty file page:** start writeback and try again later; if it's already being written, check for congestion and possibly throttle
- **anonymous page:** write it to swap, then unmap and free it
- **recently referenced:** move it back to the active list instead

Pages not freed go back on the lists; freed pages go back to the page allocator.

### Step 8: Notice mistakes (refault distance)
This is the key step against thrashing. When a file page is evicted, a small **shadow entry** is left in its slot in the page cache, recording an eviction counter at that moment. If the page is faulted back in, the kernel computes the **refault distance**: how many evictions happened in between. If that's smaller than the active list, the page would have stayed cached had there been a little more room: it's part of the working set. It's then placed straight on the active list, so pages that belong together get protected together.

### Step 9: Shrinkers for kernel caches
Kernel objects like dentries and inodes aren't on these lists. Subsystems register **shrinkers**: one callback saying how much they could free, another to free up to N objects. Under pressure, the kernel calls them, biggest first. The filesystem layer's shrinker frees dentries and inodes; networking and slab caches register their own.

### Step 10: Multi-generation LRU (6.1)
The classic scheme only knows "active" and "inactive": a page hot six minutes ago looks the same as one hot six seconds ago, and finding cold pages means scanning the whole active list. The **multi-generation LRU** (MGLRU) replaces that with a few **generations** (typically four):
- **Aging:** when the generations are about to collapse, start a new youngest generation and walk the processes' page tables looking for pages accessed since the last walk. Those move to the newest generation. Filters avoid rescanning regions twice. Checking access bits in bulk is far cheaper than taking a lock on every access.
- **Eviction:** take the oldest generation of whichever type (anonymous or file) should go next, and process it as in step 7. When it's empty, the oldest generation number moves up.
- A feedback controller uses per-generation refault rates to keep adjusting the anonymous/file balance.

Measured results: about 40% less kswapd CPU time, 85% fewer low-memory kills on Android, and 18% lower rendering latency.

## The picture

```text
 free memory
   high ─────────────────  kswapd stops
   low  ─────────────────  allocator wakes kswapd (background)
   min  ─────────────────  allocating thread reclaims itself (stall)
   0    ─────────────────  reclaim fails → OOM killer

 CLASSIC:  new → [inactive] ──referenced──▶ [active]
                      │ tail, unreferenced
                      ▼
            clean file → free │ dirty file → write back │ anon → swap │ busy → rotate

 MGLRU:   gen 4 (newest) ◀── aging walks page tables, promotes accessed pages
          gen 3
          gen 2
          gen 1 (oldest) ──▶ eviction

 evicted page leaves a shadow: comes back soon? → straight to active (working set)
```

## Tradeoffs

- **What it gives you:** nearly all RAM usable as cache, free pages manufactured in the background, and eviction choices that learn from refaults.
- **What it costs / requires:** background CPU time for kswapd whether or not anyone is waiting; MGLRU adds more complex bookkeeping, small next to the scanning it saves.
- **Where it bites:** when kswapd can't keep up, allocations stall in direct reclaim, which shows up as unexplained latency. On very memory-starved systems kswapd can spin at 100% CPU, a classic sign of trouble just before OOM.

## How it got here

- **2.4:** one global active/inactive list; kswapd introduced to move reclaim off the allocation path.
- **2.6.0:** per-zone lists and batching to reduce lock contention.
- **2.6.28 (2008):** shadow entries for refault-distance detection.
- **4.8 (2016):** reclaim moved from per-zone to per-node (Mel Gorman), fixing NUMA systems that swapped needlessly while other zones had free memory.
- **5.9–5.15:** folios in reclaim; an unreliable "wait for disk congestion" throttle replaced, because fast NVMe devices made congestion signals meaningless.
- **6.1 (2022):** multi-generation LRU becomes the default (Yu Zhao), after debate about its complexity and the stability of its feedback loop. **6.8:** pages from sequential I/O can be dropped right after writeback without scanning.

## Related

- Technical version: [[page-reclaim]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[buddy-allocator-explained|Buddy allocator]]: sets the watermarks and receives freed pages
- [[page-cache-explained|Page cache]], [[swap]]: where evicted pages come from and go
- [[oom-killer-explained|OOM killer]]: the last resort
- [[memory-cgroup-explained|Memory cgroups]]: per-group reclaim on the same machinery
- [[psi-pressure-stall-information-explained|psi-pressure-stall-information]], [[block-explained|Block layer]], [[vfs|VFS]]
