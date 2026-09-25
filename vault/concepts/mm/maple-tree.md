---
title: "Maple Tree"
category: concept
tags: [mm, maple-tree, b-tree, rcu, vma, data-structures]
subsystem: mm
kernel_version: "6.1"
researched: 2026-09-25
status: complete
explained: "[[maple-tree-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/core-api/maple_tree.html
  - https://lwn.net/Articles/845507/
  - https://lwn.net/Articles/901714/
  - https://lwn.net/Articles/839781/
  - https://lwn.net/Articles/924572/
  - https://lwn.net/Articles/974860/
  - https://lwn.net/Articles/787629/
---

# Maple Tree

> 📘 Plain-language version: [[maple-tree-explained]]

## Purpose

Each process's address space is a set of non-overlapping ranges: its virtual memory areas (VMAs). Until 6.1 the kernel tracked them three ways at once: an rbtree for lookup by address, a sorted doubly-linked list for iteration, and a per-thread `vmacache` for recent hits. All three had to be updated under `mmap_lock` on every mmap/munmap, rbtrees handle ranges and gap searches poorly, and none of the three could be read safely without the lock. The maple tree, by Liam Howlett and Matthew Wilcox (Oracle), is an RCU-safe B-tree specialised for ranges. It replaced all three with one structure that can be searched without locks, laying the groundwork for per-VMA locking. It is now a general-purpose kernel range store used well beyond mm.

## Mental Model

A maple tree is **a library card catalogue for ranges**. Each drawer (a 256-byte node, about four cache lines) holds a sorted row of dividers (*pivots*) and, between them, what lives in that span (*slots*). To find an address you open the root drawer, pick the span it falls into, and follow it down two or three drawers to the answer, touching a handful of cache lines instead of chasing a dozen rbtree pointers. When a librarian changes a drawer, they build a fresh copy and swap it into place, so anyone reading the old drawer (an RCU reader) still sees a consistent, if slightly stale, catalogue.

## How It Works

**The shape of the tree.** A `struct maple_tree` has a root pointer (`ma_root`), flags (`ma_flags`) and a spinlock (`ma_lock`), or an external lock if `MT_FLAGS_LOCK_EXTERN` is set. Every node is a `struct maple_node`, exactly 256 bytes and allocated from a dedicated slab cache. The node type is encoded in the low bits of the pointer that references it, so no space is wasted in the node itself. The main types are:
- **`maple_range_64`**: 16 slots and 15 pivots, used for leaves and ordinary internal nodes. Pivot *i* is the inclusive upper bound of slot *i*, and the lower bound is implied by the previous pivot, so each range costs one `unsigned long` rather than two.
- **`maple_arange_64`**: an "allocation range" internal node with 10 slots, 9 pivots and a **gap array** recording the largest empty span beneath each child. It's used when the tree is created with `MT_FLAGS_ALLOC_RANGE`, which is how the VMA tree answers "find me a free hole of N bytes below address X" without walking every VMA.
- **`maple_dense`**: one slot per index, for densely packed small keys.

Leaf entries are arbitrary pointers. Values with the bottom bits `10` below 4096 are reserved for internal markers, and `xa_mk_value()` wraps integers, as in the [[xarray]].

**Lookup (fast path).** A reader declares its position with a *maple state*, `MA_STATE(mas, &tree, index, last)`, which tracks the current node, offset and the range bounds found. Under `rcu_read_lock()` (or the tree lock), `mas_walk()` or the simpler `mtree_load()` descends from the root. At each node it scans pivots, a tight loop over one or two cache lines, to find the slot covering the index, and it records the enclosing `[min, max]` as it goes. The tree is shallow, so a lookup is a few node reads. For iteration, `mas_find()`, `mas_next()` and `mas_prev()` continue from the saved state rather than restarting at the root, which is what replaced the VMA linked list. The mm wrapper for this is `struct vma_iterator` with `for_each_vma()` and `vma_find()`.

**Gap search.** `mas_empty_area()` and `mas_empty_area_rev()` descend through `maple_arange_64` nodes, skipping any child whose recorded gap is too small. `vm_unmapped_area()` uses the reverse variant to place new mmaps top-down, which used to need an augmented rbtree with its own gap bookkeeping.

**Stores (write path).** Writers must hold the tree's lock: the internal spinlock via `mtree_store_range()`/`mtree_insert()`/`mtree_erase()`, or, for the VMA tree, `mmap_lock` held for writing plus the advanced `mas_store*()` calls. A store of `[index, last] → entry` may overwrite part of one range, split a range into three, or span many existing ranges. The advanced API classifies the operation and picks a strategy:
- **In-place / append**: the new range fits in the existing leaf's free slots, and when RCU mode is off (single-threaded setup) the node is modified directly.
- **Node replacement**: in RCU mode (`MT_FLAGS_USE_RCU`), a changed node is built afresh, published by updating the parent's slot, and the old node is freed after a grace period (`ma_free_rcu()`). Readers therefore always see either the old or the new node, never a half-edited one.
- **Split / rebalance / spanning store**: if the result doesn't fit, nodes are split and pivots pushed up. If a store spans several leaves, the affected subtree is rebuilt, historically via a temporary on-stack `maple_big_node`. Underfull nodes are rebalanced with siblings.

**Preallocation.** A store can need several new nodes, and some callers (VMA modification under locks, reclaim-adjacent paths) cannot fail or sleep midway. `mas_preallocate()` computes the worst case for the planned write and allocates nodes *before* the lock-sensitive part. `mas_store_prealloc()` then cannot fail. `mas_store_gfp()` allocates on demand with a GFP mask, dropping and retaking the lock if it has to sleep. The heavy churn of node allocation is part of why the slab allocator gained percpu "sheaves" (2025), with maple nodes as their first user.

**Failure path.** If allocation fails in a non-preallocated store, the maple state is left in an error state (`mas_is_err()`), with `-ENOMEM` recoverable via `mas_nomem()`, and the tree unchanged. Readers that race with a writer in RCU mode may see an entry that has just been removed. Users like the VMA code must revalidate under their own locks (per-VMA locks do this with a sequence count on the VMA).

**How the VMA code uses it.** `mm_struct->mm_mt` is created with `MT_FLAGS_ALLOC_RANGE | MT_FLAGS_LOCK_EXTERN | MT_FLAGS_USE_RCU`, with `mmap_lock` as the external lock. `find_vma()` became a maple-tree walk. mmap, munmap, mprotect and split/merge became a handful of `vma_iter_*` stores with preallocation (`vma_iter_prealloc()`). Since 6.4 the page-fault handler calls `lock_vma_under_rcu()`: it looks up the VMA in the maple tree under RCU only, then takes that VMA's own lock, so most faults never touch `mmap_lock`. This was the long-term payoff the maple tree was built for.

## Key Data Structures

**`struct maple_tree`** (`include/linux/maple_tree.h`) — `ma_root`, `ma_flags`, `ma_lock` (or `ma_external_lock`).

**`struct ma_state`** — the cursor for the advanced API.
- `tree`, `node`, `offset` — where we are
- `index`, `last` — the requested range; after a walk, the found range
- `min`, `max` — bounds of the current node
- `alloc` — preallocated nodes
- `status` — `ma_start`, `ma_active`, `ma_none`, `ma_pause`, `ma_error`…

**`struct maple_range_64` / `struct maple_arange_64`** — node layouts: `pivot[]`, `slot[]`, parent pointer (encoding the parent's slot and type), and in arange nodes `gap[]`.

## Key Functions / Entry Points

**`mtree_load()` / `mtree_store_range()` / `mtree_insert_range()` / `mtree_erase()`** (`lib/maple_tree.c`) — normal API with internal locking.
**`mtree_alloc_range()` / `mtree_alloc_rrange()`** — allocate a free range (ID-style use).
**`mt_find()`, `mt_for_each()`** — search and iterate.
**`mas_walk()`, `mas_find()`, `mas_next()`, `mas_prev()`** — advanced navigation.
**`mas_store()`, `mas_store_gfp()`, `mas_preallocate()` + `mas_store_prealloc()`** — advanced writes.
**`mas_empty_area()` / `mas_empty_area_rev()`** — gap search.
**`vma_find()`, `for_each_vma()`, `vma_iter_store_gfp()`** (`mm/vma.h`, `include/linux/mm.h`) — the mm wrappers.

## Important Flags & Config Options

- `MT_FLAGS_ALLOC_RANGE` — use `arange` nodes with gap tracking.
- `MT_FLAGS_USE_RCU` — copy-on-write node replacement for lockless readers. It can be toggled with `mt_set_in_rcu()`/`mt_clear_in_rcu()`, e.g. during fork, when the new mm has no readers yet.
- `MT_FLAGS_LOCK_EXTERN` + `mt_set_external_lock()` — protect the tree with the caller's lock (the VMA tree uses `mmap_lock`). The maintainer discourages this for new users.
- `CONFIG_DEBUG_MAPLE_TREE` — validation (`mt_validate()`), dump helpers.
- `CONFIG_TEST_MAPLE_TREE` / `tools/testing/radix-tree` userspace harness — the extensive test suite that accompanied the merge.

## Interactions with Other Subsystems

- **↑ Userspace**: indirect. mmap/munmap/mprotect latency, `/proc/<pid>/maps` iteration.
- **← [[virtual-memory-areas]]**: VMA lookup, iteration and gap search are maple-tree operations.
- **← [[page-fault-handler]]**: per-VMA locking uses a lockless RCU walk (`lock_vma_under_rcu()`).
- **→ [[rcu-read-copy-update]]**: node replacement and deferred freeing rely on RCU grace periods.
- **→ [[slub-slab-allocator]]**: `maple_node_cache`; percpu sheaves were motivated by maple-node allocation patterns.
- **Other users**: sparse IRQ descriptors, regmap caches (`regcache-maple`), tmpfs/libfs stable directory offsets (`simple_offset`), [[ublk-zero-copy]] shared-memory PFN lookup, and DRM GPU VA management.
- **↔ [[xarray]]**: sibling structure by the same authors; the maple tree aims to eventually offer the XArray API with better range handling.

## Design Decisions & Tradeoffs

- **B-tree over rbtree.** Wide 256-byte nodes cut tree height and cache misses, and implied lower bounds halve per-range storage. The cost is more complex writes (splits, rebalances, spanning stores) and a large, intricate implementation (`lib/maple_tree.c` is several thousand lines).
- **Copy-on-write for RCU.** Replacing whole nodes instead of editing them lets readers go lock-free, but every modification allocates. That drove preallocation APIs and slab work, and it makes write-heavy workloads somewhat more expensive than the old rbtree.
- **Gap tracking built in.** Folding the free-area search into internal nodes removed the augmented rbtree, but the reduced fan-out of `arange` nodes (10 vs 16) is the price.
- **One structure for three.** Removing the linked list and vmacache simplified the invariants (no three-way consistency), at the cost of touching nearly every VMA walker in the kernel during the conversion. That produced a stream of regressions in the 6.1–6.3 cycle.
- **Mixed early performance.** The initial RFC showed some microbenchmarks slower and others faster, with kernel builds roughly neutral. Its value was enabling lockless VMA lookup, which paid off with per-VMA locks.

## How It Has Evolved

- **Dec 2020–2021** — RFC "Introducing the Maple Tree" (70 patches); iterated through 2022.
- **6.1 (Dec 2022)** — merged; VMA rbtree, linked list and `vmacache` removed.
- **6.2–6.3** — regression fixes, `vma_iterator` API cleanup.
- **6.4** — per-VMA locks built on RCU maple-tree lookup; regmap maple cache.
- **6.5–6.6** — sparse IRQs and libfs/tmpfs directory offsets move to maple trees; `mas_preallocate()` precision improvements.
- **2024 (LSFMM)** — roadmap: dense nodes, removing big nodes, marks/tags, 64-bit indices on 32-bit, and eventually replacing the XArray implementation.
- **2025–2026** — slab sheaves for node allocation; new users including ublk's shared-memory buffer lookup.

## Further Reading

1. [Introducing maple trees — LWN (2021)](https://lwn.net/Articles/845507/)
2. [The next steps for the maple tree — LWN (2024)](https://lwn.net/Articles/974860/)
3. [Per-VMA locks — LWN (2023)](https://lwn.net/Articles/924572/)
4. [How to get rid of mmap_sem — LWN (2019)](https://lwn.net/Articles/787629/)
5. [Maple Tree — kernel.org core-api docs](https://www.kernel.org/doc/html/latest/core-api/maple_tree.html)
6. [Introducing the Maple Tree (v-series posting) — LWN](https://lwn.net/Articles/901714/)

## LKML Highlights

> The LKML search tool was unreachable during this run; message-ids are from LWN's mirrors.

- **`<20210112161240.2024684-1-Liam.Howlett@Oracle.com>`** — "[PATCH v2 00/70] RFC mm: Introducing the Maple Tree". It proposed replacing rbtree + list + vmacache in one go. Review questioned the size of the change and the mixed benchmarks, and the answer was a large userspace test suite.
- **Per-VMA locks (Suren Baghdasaryan, 2023)** — builds page-fault handling on lockless maple-tree lookups, the payoff that justified the maple tree's complexity.
- **LSFMM 2024 maple tree session (Liam Howlett)** — laid out the XArray-convergence plan and warned new users away from external locking.
