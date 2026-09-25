---
title: "Reverse Mapping (rmap) — Explained"
category: explained
original: "[[rmap-reverse-mapping]]"
subsystem: mm
tags: [explained, mm, rmap, reclaim, migration]
converted: 2026-09-25
---

# Reverse mapping (rmap), explained

> Plain-language companion to [[rmap-reverse-mapping|the technical note]]. Same facts, fewer identifiers.

## The problem

Page tables answer "which physical page does this virtual address point to?". But the kernel often needs the opposite question: **"given this physical page, which page-table entries point to it?"**

It needs that answer to swap a page out (every mapping must be removed first), to move a page to another NUMA node or during compaction (every mapping must be repointed), and to judge how recently a page was used (by checking the "accessed" bit in every mapping). One page can be mapped in many places: shared after `fork`, in shared file mappings, or merged by KSM. Without an index, the only way to find them would be to scan every process's entire page tables, which is hopeless.

## The idea in one paragraph

Keep a lightweight side index from a page to **the memory regions (VMAs) that could contain it**, not to individual page-table entries. From a region and the page's offset, the virtual address follows by arithmetic, and from there the page-table entry. File pages already have a natural anchor: each file keeps a tree of every region mapping it. Anonymous memory (heap, stack, private copies) has no file, so the kernel invents an anchor object for it, and the hard part is keeping that anchor correct and efficient across `fork`.

## Step by step

### Step 1: File pages: use the file's own tree
Each file's address space keeps an **interval tree** of every region mapping it, sorted by file offset. To reverse-map a file page: lock that tree, look up the page's offset, and you have the regions. There's no per-page cost; it scales with the number of regions.

### Step 2: Anonymous pages: create an anchor
The first time a region faults in anonymous memory, the kernel gives it an **anonymous anchor** object (or reuses a neighbouring region's, if that neighbour has no children, saving an allocation). A small link object ties the region to the anchor. When a page is mapped there, the page records the anchor (with the lowest bit of the pointer set, to mark "anonymous") and its offset within the region.

A private file mapping that has been written to can be in both worlds at once: still in the file's tree, and also linked through an anonymous anchor for its private copies.

### Step 3: fork makes it hard
After `fork`, parent and child share most pages until one of them writes. If the kernel wants to reclaim one of those shared pages, it must find *both* processes' mappings. So for every anonymous region copied into the child, the kernel:
1. gives the child's region its own new anchor
2. links the child's region to that anchor
3. **also** links the child's region to the *parent's* anchor

A page that started in the parent still points at the parent's anchor, and that anchor's tree now includes the child's region too. Every anchor also points to its oldest ancestor (the **root**), which outlives all descendants.

### Step 4: Look up by interval
Each anchor keeps an interval tree of its links, keyed by the range of page offsets each region covers. To reverse-map an anonymous page: find its anchor, lock it for reading, and walk only the links whose range contains the page's offset. For each, compute the virtual address and look up the page-table entry. Cost grows with log(number of regions) plus the number of matches.

### Step 5: The two main users
- **"How hot is this page?"** (used by reclaim): for each mapping, check and clear the accessed bit, and count how many were set. Many recent references keep the page active; none moves it toward eviction.
- **"Remove every mapping"** (before swapping or freeing): for each mapping, flush that address from the TLB, clear the entry (or replace it with a swap entry), and decrement the page's mapping count. When the count shows no mappings left, the page can be freed or written to swap. Migration uses a variant that installs temporary "migration" entries instead, so processes that touch the page wait for the move rather than fault it back from swap.

Both go through one generic walker that picks the file or anonymous path from the pointer's low bit, with callbacks to skip uninteresting regions or stop early. Options let callers split a huge-page mapping first, ignore memory locking (the OOM killer does this), batch TLB flushes, or clear all-zero pages without writing them to swap.

### Step 6: The 2010 scalability fix
This is the key design lesson. Originally, every region created by forking shared the *same* parent anchor. With 1,000 children each holding 1,000 anonymous pages, one anchor covered a million pages, and reclaiming any one of them meant scanning all of them under the anchor's lock. Rik van Riel's fix (around 2.6.34) introduced the separate link objects and per-region anchors described above, turning a linear scan into a tree lookup. A subtle follow-on bug (a page could be left pointing at a child's freed anchor) was fixed by always linking pages to the ancestor side, guaranteed by the root pointer.

## The picture

```text
 FILE PAGE                            ANONYMOUS PAGE (after fork)
 page ─▶ file's tree of regions       page ─▶ parent's anchor (root)
           │                                   │ interval tree of links:
      regions in A, B, C                        ├─ parent region [0..99]
           │                                    └─ child region  [0..99]
      address = region start +                           │
        (page offset − region offset)           child's own anchor ─▶ child-only pages
           │                                             
           ▼                                   for each matching region:
     page-table entry                          address → page-table entry
                                               → check accessed bit / clear / repoint
```

## Tradeoffs

- **What it gives you:** reclaim, migration, compaction, KSM and swap can all find a page's mappings quickly, with cost based on regions rather than pages.
- **What it costs / requires:** anchor and link objects for every anonymous region, more of them after each `fork`, and interval trees that are costlier to update than lists. A strict lock order must be followed (the anchor's lock before the process memory lock), or deadlocks result.
- **Where it bites:** fork-heavy workloads were the historic weak spot and still create large anchor hierarchies. Using the pointer's spare low bits to tag anonymous versus file (and KSM) pages saves space in every page descriptor but makes the encoding subtle.

## How it got here

- **2.5.27 (2002):** the first reverse map (Andrea Arcangeli) kept a list of mapping locations in every page. It worked but used huge amounts of low memory on 32-bit systems.
- **2.6.7 (2004):** redesigned around objects: files use their region tree, anonymous memory uses anchors (Linus Torvalds's design, chosen for simplicity over a competing approach by Hugh Dickins).
- **~2.6.34 (2010):** per-region anchors with link objects, fixing the fork scalability crisis.
- **~4.5 (2016):** interval trees replaced sorted lists for both paths.
- **5.x–6.x:** folio-based versions, so a large multi-page folio has a single mapping count and reverse-map entry.

## Related

- Technical version: [[rmap-reverse-mapping]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[page-reclaim-explained|Page reclaim]]: the biggest user
- [[memory-compaction-explained|Memory compaction]], [[transparent-huge-pages-explained|transparent-huge-pages]], [[swap-explained|swap]]
- [[address-space-explained|Address space]]: holds the file-side tree
- [[page-fault-handler-explained|Page fault handler]]: registers new mappings
- [[page-table-management-explained|Page table management]], [[virtual-memory-areas]]
