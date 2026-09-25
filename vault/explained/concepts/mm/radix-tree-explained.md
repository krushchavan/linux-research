---
title: "Radix Tree — Explained"
category: explained
original: "[[radix-tree]]"
subsystem: mm
tags: [explained, mm, data-structures, page-cache, rcu]
converted: 2026-09-25
---

# The radix tree, explained

> Plain-language companion to [[radix-tree|the technical note]]. Same facts, fewer identifiers.

## The problem

The page cache has to answer "which page holds offset N of this file?" constantly, and fast. Early kernels used a hash table, which suffered collision storms on workloads with many files and couldn't do the other thing the kernel needs: walk *consecutive* offsets in order, for readahead or to collect all the dirty pages of a file for writeback.

The index also had to cope with enormous but sparse files, allow lookups without locks, and later handle huge pages that cover hundreds of offsets at once.

## The idea in one paragraph

Use a **radix tree**, a trie keyed by the integer offset. It works like an **address decoder**: each level of the tree takes the next chunk of bits of the key (6 bits in the classic version, so 64 slots per node), just as hardware peels off address bits to pick a bank, a row, a column. Three levels cover 2^18 offsets. Nodes exist only where something is stored, so a sparse file with a few cached pages costs only the few nodes needed to reach them. Each node also carries **tag** bits summarising its descendants, so "find all dirty pages" skips clean branches entirely.

## Step by step

### Step 1: Look up
The tree's root records the current height. A lookup takes the top 6-bit chunk of the key, uses it to pick one of 64 slots in the root node, follows that pointer, takes the next chunk, and so on down to the bottom, where the slot holds the stored item. An empty slot anywhere means "not present".

### Step 2: Look up without locks
This is the key performance step. Nodes are only ever freed after an RCU grace period, so a lookup can walk the tree holding just an RCU read lock, no spinlock. It may briefly see a node that was just removed, but never freed memory. The page cache's read path depends on this (since 2.6.18).

### Step 3: Tags summarise the subtree
Each node has a small bitmap per tag: bit *i* set means "something below slot *i* has this tag". So "does anything in this file have tag X?" is one check at the root, and "give me the tagged entries" only visits branches with the bit set, costing time proportional to the number found, not to the file size. The page cache uses two tags: **dirty** and **under writeback**. Writeback uses the dirty tag to collect dirty pages in order without touching clean ones.

### Step 4: Insert, with memory reserved in advance
Inserting may need new nodes, but callers usually hold a spinlock, where sleeping to allocate isn't allowed, and emergency allocations can fail when memory is tight. So callers first **preload**: before taking the lock, they reserve enough nodes for a worst-case path in a per-CPU stash. The insert then takes nodes from the stash and never blocks; leftovers are returned afterwards. If the key is bigger than the tree can currently hold, a new root is added on top and the height grows.

### Step 5: Delete and prune
Deleting clears the slot and its tag bits, lowers each ancestor's count of used slots, and frees any node that becomes empty, again only after an RCU grace period, so lock-free readers stay safe.

### Step 6: Huge pages: one entry, many offsets
A huge page covers many consecutive offsets (512 for 2 MB). Storing 512 identical pointers would be wasteful. Since around 4.8–4.14 (Matthew Wilcox), a **multi-order** entry is stored once at its aligned position, and the other slots in its range hold **sibling markers** pointing back to it. Lookups follow siblings automatically, so any offset inside the huge page finds it.

### Step 7: Caller-provided locking
The tree has no lock of its own. Its main users (the page cache) already hold a lock for other reasons, and a second one would double the locking cost on the hottest path.

## The picture

```text
 key (file page offset) = 0b 000011 000101 101001
                               │      │      │
 root node  [0 .. 63] ── slot 3 ──▶ node [0 .. 63] ── slot 5 ──▶ node ── slot 41 ──▶ page
                 tags: dirty ■ (something below slot 3 is dirty)

 missing branches = no nodes at all (sparse files are cheap)
 huge page at offsets 512..1023: stored once, other slots → "see sibling"
```

## Tradeoffs

- **What it gives you:** fast, lock-free lookups by integer offset, ordered range walks, cheap "find all dirty" queries, and compact storage for sparse files and huge pages.
- **What it costs / requires:** keys must be unsigned integers (fine for file offsets; other key types use other structures); callers must do their own locking and the preload dance.
- **Where it bites:** only two tags were supported. The DAX (direct persistent-memory) path wanted a third, one of the reasons the API was replaced by the XArray, which has three "marks" and handles locking and multi-order entries more cleanly.

## How it got here

- **2.5 era:** introduced (Nick Piggin) to replace the page cache's hash table, fixing collision storms and enabling ordered lookups.
- **2.6.18 (2006):** lookups made safe under RCU, removing the lock from the page cache's read path.
- **4.8–4.14 (2016–2017):** multi-order entries for huge pages and DAX (Matthew Wilcox), the most invasive change to the structure.
- **4.20 (2018):** the XArray merged; the radix-tree interface became a thin compatibility layer over it, and the page cache moved to the XArray API in 5.1.
- **5.15 onward:** in-tree users have largely migrated; the compatibility layer remains mainly for out-of-tree code.

## Related

- Technical version: [[radix-tree]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[xarray]]: its successor
- [[page-cache-explained|Page cache]], [[address-space-explained|Address space]]: its main user
- [[page-reclaim-explained|Page reclaim]], [[transparent-huge-pages]]
- [[rcu-read-copy-update|RCU]], [[block-explained|Block layer]]
