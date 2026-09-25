---
title: "Memory Compaction — Explained"
category: explained
original: "[[memory-compaction]]"
subsystem: mm
tags: [explained, mm, fragmentation, compaction, migration]
converted: 2026-09-25
---

# Memory compaction, explained

> Plain-language companion to [[memory-compaction|the technical note]]. Same facts, fewer identifiers.

## The problem

As a system runs, pages are allocated and freed at different times, and free memory ends up scattered in small holes all over RAM. This is **external fragmentation**. The machine can have gigabytes free in total and still be unable to find one contiguous 2 MB block for a huge page or a DMA buffer.

Freeing more memory doesn't help, because the problem isn't *how much* is free but *where* it is. What's needed is a way to move pages that are in use so the free space joins up.

## The idea in one paragraph

Picture a bookshelf with books and empty slots mixed at random. Compaction **slides the books to one end**, leaving a continuous empty stretch at the other. It uses two cursors: one scanning up from the bottom looking for books that can be moved, one scanning down from the top looking for empty slots. It moves books into the empty slots until the cursors meet. For memory, "moving a book" means copying a page's contents and repointing every mapping at the new copy. Only pages that *can* be moved are touched, which is why the allocator keeps movable and unmovable pages apart in the first place.

## Step by step

### Step 1: Keep movable pages together
Memory is divided into **pageblocks** (typically 512 pages = 2 MB), and each is tagged by what kind of allocation it serves:
- **unmovable:** kernel code and most kernel data
- **movable:** user pages, which can be relocated by updating page tables
- **reclaimable:** page cache and some caches, which can be dropped and re-read
- **CMA:** ranges reserved for large contiguous device allocations

The allocator tries to put each kind of allocation in a matching block. This is the foundation: if every block had one unmovable page in it, compaction could never free a whole block.

### Step 2: Decide whether compaction can help
Before compacting, the kernel computes a **fragmentation index** for the size it wants. Near 1000 means "plenty of free pages, just not in big enough blocks": fragmentation is the problem and compaction will help. Near 0 means there simply isn't enough free memory, and compacting would waste CPU.

### Step 3: Two scanners
Within one zone:
- the **migration scanner** walks up from the bottom, block by block. In movable (or CMA) blocks, it takes in-use pages off their LRU lists and collects them for moving.
- the **free scanner** walks down from the top, pulling free pages out of the allocator to serve as destinations.

Starting from opposite ends keeps the distance pages have to move short.

### Step 4: Move the pages
This is the key step. For each collected page, the kernel:
1. copies its contents to a destination page
2. uses **reverse mapping** to find every page-table entry pointing at the old page and repoints them all at the new one
3. frees the old page, which now sits in the region being cleared at the bottom

Special cases: for file pages, the page cache's index entry is swapped under a lock; huge pages move as one unit; a page that can't move (for example because a device has it pinned) is put back and its block is skipped.

### Step 5: Stop when the cursors meet
When the migration cursor passes the free cursor, the zone is as compacted as it can get. Cursor positions are remembered between runs so already-compacted regions aren't rescanned.

### Step 6: When compaction runs
- **On demand:** when a large allocation fails, the allocator's slow path tries compaction before reclaim or OOM.
- **In the background:** a per-node thread (kcompactd) is woken after such failures and does enough to satisfy one allocation of the needed size.
- **Proactively (5.9+):** kcompactd watches a per-node **fragmentation score** (0–100). When it rises above a tunable threshold (default 20), it compacts until the score drops to half that. Doing the work in idle time cut huge-page allocation latency by 70–80× in benchmarks.
- **Manually:** writing to a control file compacts everything.

### Step 7: Fast or thorough, and knowing when to give up
Compaction can run **asynchronously** (skip pages that are locked, for low latency; the background thread does this) or **synchronously** (wait for locks, for thoroughness when the allocation really matters). If compaction succeeds but the allocation still fails, the real problem is low memory, so further compaction attempts are deferred exponentially.

## The picture

```text
 zone before:   [U][m][ ][m][ ][ ][m][ ][U][m][ ][m]
                 ▲ migration scanner ──▶      ◀── free scanner ▲
                   (finds movable m)            (finds free slots)

 move each m into a free slot near the top, repoint its mappings (reverse map)

 zone after:    [U][ ][ ][ ][ ][ ][ ][ ][U][m][m][m][m][m]
                     └── contiguous free run ──┘
 (U = unmovable, stays put; this is why unmovable pages are kept in their own blocks)
```

## Tradeoffs

- **What it gives you:** large contiguous blocks on long-running, fragmented systems, which huge pages and contiguous device buffers depend on. Without it, huge-page success rates drop sharply over time.
- **What it costs / requires:** CPU time to copy pages and update mappings; brief unavailability of pages being moved; a working page-migration mechanism.
- **Where it bites:** pinned pages can't be moved and block their region. Compacting when memory is simply scarce wastes effort, which is why the fragmentation index and deferral exist. Proactive compaction spends CPU in the background whether or not a big allocation ever comes.

## How it got here

- **2.6.35 (2010):** memory compaction merged (Mel Gorman).
- **3.6 (2012):** the background compaction thread.
- **3.10 (2013):** remembering scanner positions between runs.
- **4.6 (2016):** better deferral.
- **5.9 (2020):** proactive compaction.

## Related

- Technical version: [[memory-compaction]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[buddy-allocator-explained|Buddy allocator]]: where the free blocks end up, and the movability tags
- [[transparent-huge-pages]], [[huge-pages-hugetlbfs-explained|hugetlbfs]]: the main customers
- [[rmap-reverse-mapping]]: how mappings are repointed
- [[page-reclaim-explained|page-reclaim]]: the complementary slow-path step
- [[get-user-pages-and-pinning-explained|Page pinning]]: why some pages can't move
