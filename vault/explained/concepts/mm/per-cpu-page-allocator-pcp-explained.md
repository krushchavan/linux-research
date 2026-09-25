---
title: "Per-CPU Page Allocator (PCP) — Explained"
category: explained
original: "[[per-cpu-page-allocator-pcp]]"
subsystem: mm
tags: [explained, mm, page-allocator, per-cpu, scalability]
converted: 2026-09-25
---

# The per-CPU page allocator, explained

> Plain-language companion to [[per-cpu-page-allocator-pcp|the technical note]]. Same facts, fewer identifiers.

## The problem

The kernel allocates and frees single 4 KB pages constantly; it's the most common allocation there is. The buddy allocator that owns all free memory protects each memory zone with one lock. If every CPU took that lock for every page, a many-core machine would spend a large share of its time waiting on it. On a 224-CPU machine, contention on that one lock reached 13.5% before the latest tuning.

## The idea in one paragraph

Give **each CPU its own small stash of free pages** per zone. Most allocations and frees then touch only the CPU's own stash, with a cheap local lock. Only when the stash runs empty does the CPU go to the shared zone lock, and then it takes a whole **batch** at once; when the stash overflows, it returns a batch at once. One lock acquisition is spread over many operations. The cost is a little memory sitting idle in stashes that other CPUs can't use.

## Step by step

### Step 1: Allocate from the local stash
Requests for small blocks (single pages up to 8 pages, order 0–3) go to the per-CPU stash. The right list is picked by size and movability type, and a page is popped off under only the per-CPU lock (interrupts stay enabled since 6.5). No zone lock.

### Step 2: Refill in bulk
If the list is empty, the CPU takes the zone lock **once**, pulls a whole batch of pages from the buddy allocator into its stash, and releases the lock. The next allocations from that batch need no zone lock at all.

### Step 3: Free to the local stash, drain in bulk
Freeing a page puts it back on this CPU's stash. If the stash has grown beyond its **high** watermark, the CPU takes the zone lock once and returns a batch to the buddy allocator.

### Step 4: Tune the watermark automatically (6.6)
This is the key recent improvement. The high watermark used to be fixed. Since 6.6 (Ying Huang, Intel) it moves between a minimum and a maximum based on how much the CPU is actually allocating: it decays toward the minimum when idle and shrinks when the zone runs short of memory. On 224-CPU Sapphire Rapids machines this cut zone-lock contention from 13.5% to under 1%, gave a 5% faster kernel build, 7% better netperf SCTP, and a 96% improvement in an lmbench local-socket test.

The batch size grows with zone size, but is capped by a build-time limit (6.6) to bound worst-case latency. That cap exposed a 40% slowdown on a single-core Renesas board with no L2 cache and 1 GB of RAM, so a boot parameter was added to override it.

### Step 5: Lists by size and type
Since 4.9 the stash has a separate list for each small size (orders 0–3) and each movability type (unmovable, movable, reclaimable): 12 lists by default, plus optional slots for huge pages. The high-order lists were added mainly because the slab allocator's repeated multi-page requests were causing zone-lock storms.

### Step 6: Keep the stash near its CPU
Each CPU's stash bookkeeping is allocated on the NUMA node closest to that CPU (2005), so the frequently run management code works on local memory. That change alone gave over 25% throughput gains on a NUMA benchmark.

### Step 7: Drain stashes when memory is needed
Under memory pressure, pages hidden in stashes must be returned so reclaim and compaction can use them. Draining another CPU's stash used to mean interrupting it and waiting for it to do the work itself, which could be delayed indefinitely on CPUs running real-time work or with the scheduler tick off. Since 5.19, each CPU has two stash structures: a CPU wanting to drain another atomically swaps the target's pointer to the empty spare, waits for an RCU grace period, then empties the old one without disturbing the target. The price is one extra pointer lookup on the hot path, a 1–3% regression on some microbenchmarks. When a CPU goes offline, its stash is drained first so no pages are stranded.

### Step 8: A single-CPU locking bug (2026)
Letting interrupts stay enabled while holding the stash lock (2023) broke kernels built for a single CPU. There, a "try to take the lock" call always succeeds, because on one CPU the lock is a no-op. A timer interrupt that tried the same lock during a drain therefore got in and corrupted the stash. Vlastimil Babka fixed it by disabling interrupts around the lock on such builds.

## The picture

```text
            CPU 0 stash                 CPU 1 stash
        [p][p][p][p] (≤ high)       [p][p] (≤ high)
          ▲ pop / push                ▲
          │ local lock only           │
   empty? │ refill a batch    too full? drain a batch
          ▼                           ▼
   ┌───────────── zone lock (taken once per batch) ─────────────┐
   │                    buddy allocator                          │
   └─────────────────────────────────────────────────────────────┘

 memory pressure: swap target's stash pointer to its empty spare
                  → wait RCU grace period → drain the old one remotely
```

## Tradeoffs

- **What it gives you:** most page allocations and frees without touching a shared lock, which is essential for scaling to hundreds of CPUs.
- **What it costs / requires:** free pages parked in per-CPU stashes, unusable by other CPUs until drained; tuning of batch and watermark sizes.
- **Where it bites:** pages freed on a different CPU from where they were allocated (common with allocator purge threads, and when big processes exit) still cause bursts of zone-lock traffic. Batch-size limits that suit big servers can hurt tiny embedded systems.

## How it got here

- **2.6 era:** per-CPU page lists introduced; 2005 moved their bookkeeping onto each CPU's local NUMA node.
- **2006:** separate "hot" and "cold" lists merged into one, with cache-cold pages added at the tail (Christoph Lameter).
- **4.9 (2016):** lists for orders 1–3 as well as single pages (Mel Gorman).
- **5.19 (2022):** remote draining without interrupting the target CPU.
- **6.6 (2023):** self-tuning watermarks and a cap on batch scaling.
- **2026:** the single-CPU locking fix, and an RFC (Johannes Weiner, Meta) in which each CPU would claim whole 2 MB pageblocks and split them locally, with frees routed back to the owning CPU, showing a 3–4% system-time reduction on 32-way machines.

## Related

- Technical version: [[per-cpu-page-allocator-pcp]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[buddy-allocator-explained|Buddy allocator]]: the layer behind the stashes
- [[slub-slab-allocator]]: the main consumer of multi-page requests
- [[page-reclaim-explained|Page reclaim]], [[memory-compaction-explained|Memory compaction]]: why stashes get drained
- [[per-cpu-variables|Per-CPU variables]], [[rcu-read-copy-update|RCU]]
