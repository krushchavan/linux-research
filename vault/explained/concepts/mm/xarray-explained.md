---
title: "XArray — Explained"
category: explained
original: "[[xarray]]"
subsystem: mm
tags: [explained, mm, data-structures, rcu, page-cache]
converted: 2026-09-25
---

# The XArray, explained

> Plain-language companion to [[xarray|the technical note]]. Same facts, fewer identifiers.

## The problem

The kernel's radix tree was a good data structure with a hard-to-use interface. Callers had to do their own locking (some forgot, some over-locked), had to reserve memory in per-CPU pools before inserting under a lock, and had to deal with internals leaking through the API. Several subsystems gave up and wrote their own alternatives, including a separate ID allocator.

The structure underneath was fine. What was needed was a safer, simpler way to use it.

## The idea in one paragraph

Keep the proven 64-way radix tree, and **replace the interface**. The XArray behaves like a huge, sparse array of pointers indexed by an integer: you can jump straight to any index like a hash table, walk entries in order like an array (gaps cost nothing), and it grows by itself. It has its **locking built in**: readers use RCU automatically, writers take an embedded spinlock automatically, and memory for new nodes is handled for you. A second, "advanced" interface with a cursor exists for experts like the page cache, who need several operations under one lock.

## Step by step

### Step 1: What a slot can hold
Each slot holds one pointer-sized value, and the lowest bits say what it is:
- **a pointer:** normal kernel pointers are aligned, so their low bits are zero
- **a small integer ("value entry"):** marked by the lowest bit; the rest holds the number
- **an internal entry**, used only by the XArray itself: *siblings* (this slot is part of a multi-slot range; see the real entry over there), *retry* (a change is in progress, start again), and *zero* (reserved, but looks empty to normal readers)

Because of this encoding, error pointers can't be stored; callers must handle errors before storing.

### Step 2: How it grows
The top-level object has a lock and a head pointer. The head starts empty, becomes a direct pointer when there's a single entry at index 0, and becomes a pointer to a tree node once there's more. Each node has 64 slots and records how many index bits it covers below it: 0 for a leaf, 6 one level up, 12 above that, and so on. At most about 10–11 levels cover all 64-bit indices.

### Step 3: Reading without locks
A lookup takes the RCU read lock automatically, then walks down six bits at a time from the top. Writers publish new nodes in a way that readers always see either the old tree or the new one, never something half-built. The pointer returned is only valid while the caller keeps the object alive.

### Step 4: Writing, with memory handled for you
A store takes the embedded lock, walks to the slot, and stores. If it needs a new node, it first tries a quick allocation that can't sleep. If that fails, it **drops the lock, allocates normally (possibly sleeping), retakes the lock and retries**. That's slightly slower in the rare failure case, but it removed the old "reserve memory before locking" dance and a whole class of bugs with it. Emptied nodes are freed after an RCU grace period.

### Step 5: The advanced cursor
The page cache constantly does several operations in a row. It uses a small **cursor** kept on the stack that remembers where in the tree it is: which node, which slot, which index. Moving to the next index just steps to the next slot (carrying up to the parent when needed) instead of walking down from the root again. Reading 128 consecutive pages of a file therefore avoids thousands of root-to-leaf walks. The cursor also collects errors and "restart" conditions, and lets the caller allocate a node *outside* the lock and then use it inside.

### Step 6: Marks: find tagged entries fast
Each node has **three mark bitmaps**, one bit per slot, and a set bit propagates up to the root. "Find the next marked entry" scans the current node's bitmap and only climbs when the rest of the node is unmarked. The page cache uses marks for "dirty", "under writeback" and "to write", so writeback can enumerate just the dirty pages of a file without looking at clean ones.

### Step 7: Multi-slot entries for huge pages
An aligned, power-of-two range of indices can share one entry: the real entry lives in the lowest slot and the others hold siblings pointing to it. Any lookup in the range finds it, and setting a mark covers all of it. A 2 MB huge page covering 512 page-cache slots needs one real entry, not 512.

### Step 8: ID allocation mode
Created in "allocation" mode, the XArray can atomically find the lowest unused index in a range and store an entry there. This replaced the older ID allocator; process IDs and many other ID spaces now use it.

## The picture

```text
 struct: [ lock | head ] ──▶ node (covers 64 × 64^k indices)
                               slots[0..63]   marks: dirty ▢■▢▢  writeback ▢▢▢▢  towrite ...
                                    │
                                    ▼
                               leaf node: slot 5 → page
                                          slot 6 → value 42
                                          slots 8..15 → sibling → slot 8 (one big entry)

 normal API:  load (RCU inside) · store (lock inside, allocate + retry) · erase · iterate
 advanced:    cursor remembers position → next/find without re-walking from the root
```

## Tradeoffs

- **What it gives you:** locking you can't forget, no memory-reservation ritual, lock-free reads, fast ordered and marked iteration, compact huge-page entries, and built-in ID allocation. The simple interface covers about 80% of users.
- **What it costs / requires:** callers who already hold their own lock must use the more complex advanced interface; drop-and-retry allocation is a little slower in the rare case it's needed.
- **Where it bites:** entries can't be error pointers. There was debate over whether two interface tiers added too much complexity; Matthew Wilcox's defence was that the page cache genuinely needs cursor semantics.

## How it got here

- **4.20 (Dec 2018):** merged (Matthew Wilcox), with the old radix-tree interface kept as a thin layer on top; the page cache was converted as the flagship (a 62-patch series; two bugs in it and one in DAX were found and fixed within a release).
- **5.x:** roughly 50–60 in-tree users converted by their own maintainers; the old ID allocator deprecated; process IDs moved over (needing a small extension for wrap-around).
- **5.6+:** the page cache's index field became an embedded XArray.
- **6.x:** continued cleanup, plus incremental splitting of huge-page entries without holding the lock throughout.

## Related

- Technical version: [[xarray]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[radix-tree-explained|Radix tree]]: the structure underneath and the API it replaced
- [[page-cache-explained|Page cache]], [[address-space-explained|Address space]]: its biggest user
- [[maple-tree-explained|Maple tree]]: its range-oriented sibling
- [[rcu-read-copy-update|RCU]], [[slub-slab-allocator-explained|SLUB]], [[page-reclaim-explained|Page reclaim]]
