---
title: "Maple Tree — Explained"
category: explained
original: "[[maple-tree]]"
subsystem: mm
tags: [explained, mm, data-structures, rcu, vma]
converted: 2026-09-25
---

# The maple tree, explained

> Plain-language companion to [[maple-tree|the technical note]]. Same facts, fewer identifiers.

## The problem

A process's address space is a set of non-overlapping ranges called VMAs ("this range is the heap", "this range maps libc"...). Until 6.1 the kernel tracked them three ways at once:
- a balanced binary tree (red-black tree) to find the VMA at an address
- a sorted linked list to walk them in order
- a small per-thread cache of recent lookups

All three had to be updated together on every `mmap` and `munmap`, under the process's one big memory lock. Binary trees handle ranges and "find me a free gap" awkwardly. And none of the three could be read safely without that lock, so every page fault in a multi-threaded program queued behind it.

## The idea in one paragraph

Replace all three with one structure: a **B-tree built for ranges** that can be read without any lock. Think of **a library card catalogue for ranges**. Each drawer (a 256-byte node, about four cache lines) holds a sorted row of dividers and, between them, what lives in that span. Finding an address means opening two or three drawers, not chasing a dozen pointers. When a librarian changes a drawer, they build a fresh copy and swap it in, so anyone still reading the old drawer sees a consistent, if slightly stale, catalogue. Written by Liam Howlett and Matthew Wilcox (Oracle), it's now a general-purpose kernel structure used well beyond memory management.

## Step by step

### Step 1: Wide nodes
Every node is exactly 256 bytes. The main kind holds 16 slots separated by 15 **pivots**. Each pivot is the *upper* end of its slot's range; the lower end is implied by the previous pivot, so each range costs one number instead of two. The node's type is stored in spare low bits of the pointer to it, so no space inside the node is spent on that.

### Step 2: Gap-tracking nodes
A second node kind has 10 slots and also records, for each child, **the largest empty span beneath it**. That lets the tree answer "find me a free hole of N bytes below address X" by skipping any child whose biggest gap is too small, without walking every VMA. That's how new `mmap` regions get placed. (The price: 10 slots instead of 16.)

### Step 3: Looking something up
A reader keeps a small cursor recording where it is and what range it found. Under RCU (the kernel's lock-free reading scheme), it starts at the root, scans a node's pivots (a tight loop over a cache line or two) to pick the right slot, and goes down. The tree is shallow, so that's a few node reads. For walking in order, the cursor continues from where it is rather than restarting at the root, which is what replaced the old linked list.

### Step 4: Writing, without disturbing readers
This is the key step. Writers hold a lock. A write "store this range → this entry" may overwrite part of a range, split one range into three, or cover many ranges. When lock-free readers are allowed, the tree **never edits a node in place**: it builds a new node, publishes it by updating the parent's pointer, and frees the old node only after every reader that might see it has finished (an RCU grace period). Readers see either the old node or the new one, never a half-edited one. If a node fills up, it splits and pushes a divider up; underfull nodes are rebalanced with a neighbour; a write covering several leaves rebuilds that part of the tree.

When no readers exist yet (for example setting up a freshly forked process), the tree can edit in place for speed.

### Step 5: Allocate before you commit
One write can need several new nodes, and some callers can't fail or sleep partway through. So they **preallocate**: compute the worst case for the planned change, allocate those nodes first, then do the write, which can no longer fail. Other callers allocate as they go, dropping the lock to sleep if needed. The heavy node allocation is part of why the slab allocator gained per-CPU "sheaves" in 2025, with maple nodes as the first user.

### Step 6: Failure
If allocation fails in a non-preallocated write, the cursor records the error and the tree is left unchanged. A lock-free reader racing with a writer can see an entry that was just removed, so users must re-check under their own locks. Per-VMA locks do this with a sequence counter on each VMA.

### Step 7: The payoff: page faults without the big lock
Each process's VMAs live in a maple tree with gap tracking and lock-free reading, protected for writes by the process's memory lock. Since 6.4, a page fault looks up its VMA in the tree using only RCU, then locks just that one VMA. Most faults never touch the process-wide lock at all. That was the long-term goal the maple tree was built for.

## The picture

```text
                     root [ 0x4000 | 0x9000 | ... ]            (256-byte node)
                        /          |          \
   [ ..|0x1fff|0x3fff ]   [ 0x5fff|0x8fff ]   [ ... ]          leaves: ranges → VMAs
         │      │            │      │
       code    heap        mmap    stack...

 gap-tracking internal nodes also store "largest hole below each child"
   → skip children whose gap is too small when placing a new mmap

 write:  copy node → modify copy → swap parent pointer → free old after RCU grace period
         readers mid-walk still see the old, consistent node
```

## Tradeoffs

- **What it gives you:** one structure instead of three, shallow cache-friendly lookups, built-in gap search, and lock-free reads that made per-VMA locking possible.
- **What it costs / requires:** a large, intricate implementation (several thousand lines); every change allocates new nodes, so write-heavy workloads cost somewhat more than with the old tree.
- **Where it bites:** converting every VMA walker in the kernel produced a stream of regressions in 6.1–6.3. Early benchmarks were mixed, some faster and some slower, with kernel builds roughly neutral; its real value came with per-VMA locks. The maintainer discourages new users from using an outside lock for the tree, as the VMA code does.

## How it got here

- **2020–2021:** the 70-patch RFC; review questioned its size and the mixed numbers, answered with a large user-space test suite.
- **6.1 (Dec 2022):** merged; the VMA red-black tree, list and cache removed.
- **6.2–6.4:** regression fixes and a cleaner VMA iterator; per-VMA locks built on lock-free lookups (Suren Baghdasaryan); a register-cache user.
- **6.5–6.6:** interrupt descriptors and tmpfs directory offsets move to maple trees.
- **2024 (LSFMM):** roadmap for dense nodes, tags, 64-bit indices on 32-bit machines, and eventually replacing the XArray's implementation.
- **2025–2026:** slab sheaves for node allocation; new users including ublk's shared-memory buffer lookup.

## Related

- Technical version: [[maple-tree]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[virtual-memory-areas]]: the VMAs stored in it
- [[page-fault-handler-explained|page-fault-handler]]: the fast, lock-free VMA lookup
- [[rcu-read-copy-update|RCU]]: what makes lock-free reading safe
- [[xarray]], [[slub-slab-allocator-explained|slub-slab-allocator]], [[ublk-zero-copy-explained|ublk zero-copy]]
