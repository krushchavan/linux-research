---
title: "Radix Tree"
category: concept
tags: [mm, data-structures, page-cache, rcu, xarray]
subsystem: mm
kernel_version: "2.5"
researched: 2026-04-13
status: complete
sources:
  - https://lwn.net/Articles/175432/
  - https://lwn.net/Articles/684864/
  - https://lwn.net/Articles/745073/
  - https://lwn.net/Articles/757342/
  - https://lwn.net/Articles/755281/
  - https://docs.kernel.org/core-api/xarray.html
  - https://docs.kernel.org/core-api/generic-radix-tree.html
  - https://0xax.gitbooks.io/linux-insides/content/DataStructures/linux-datastructures-2.html
---

# Radix Tree

## Purpose

The radix tree is a compressed trie (prefix tree) that maps unsigned-long integer keys to pointer values. The kernel introduced it to give the page cache an O(log N) index that avoids hashing collisions and naturally supports range queries — you can walk contiguous page offsets in order, something a hash table cannot do. Without it, finding the `struct page` backing file offset 4096 of an inode would require a linear scan or a costly hash chain traversal.

## Mental Model

Think of a radix tree as an address decoder: each level of the tree consumes a fixed-width chunk of the key (6 bits per level in the classic implementation, giving 64 slots per node), just as a CPU address decoder peels off bits to select banks, rows, and columns. A 3-level tree can address 2^18 distinct keys (one page offset per entry). Nodes that have no children simply do not exist — sparse files with only a handful of dirty pages incur only the nodes actually needed to reach those pages.

## How It Works

### Lookup (the fast path)

Every tree is anchored by a `struct radix_tree_root`, which holds a `gfp_mask` (the allocator flags to use when growing the tree), the tree height in its `height` field, and `rnode` — a pointer to the root `radix_tree_node`. When `radix_tree_lookup(root, index)` is called, it reads the current height from the root and then descends level by level. At each level it extracts `RADIX_TREE_MAP_SHIFT` bits (6) from the index — starting with the most-significant chunk — and uses them as a slot index into the current node's `slots[RADIX_TREE_MAP_SIZE]` array. It follows the pointer in that slot to the next node, repeating until the bottom of the tree, where the slot holds the actual user pointer. If any slot is NULL the key is not present and NULL is returned immediately.

Because every internal pointer is dereferenced read-only and nodes are freed via RCU (`kfree_rcu`), this descent can be performed under `rcu_read_lock()` without taking any spin lock. The function `radix_tree_lookup()` is therefore safe to call from any context that can tolerate stale-by-one-grace-period results, which is exactly the contract the page-cache lookup path relies on.

### Tags

Every `radix_tree_node` carries a `tags[RADIX_TREE_MAX_TAGS][RADIX_TREE_TAG_LONGS]` bitmap alongside its `slots[]` array. Each tag is a per-slot bit: if the bit at position *i* in a node's tag bitmap is set, it means *at least one* descendant of `slots[i]` carries that tag. This propagation makes `radix_tree_tagged()` O(1) — you only need to test the root node's tag bitmap — and `radix_tree_gang_lookup_tag()` O(k) where k is the number of tagged entries found rather than the total tree size. The page cache exploits exactly two tags: `PAGECACHE_TAG_DIRTY` and `PAGECACHE_TAG_WRITEBACK`. The writeback code calls `radix_tree_gang_lookup_tag()` to collect dirty pages in order without scanning the entire file mapping.

### Insertion and the preload protocol

`radix_tree_insert(root, index, item)` may need to allocate new nodes if the index falls outside the current tree height or if intermediate nodes are absent. Because allocation can sleep (or fail under `GFP_ATOMIC`), the tree cannot simply call `kmalloc()` mid-descent under a spinlock. The solution is a *preload* protocol: callers invoke `radix_tree_preload(gfp_mask)` before taking their lock; this allocates up to `RADIX_TREE_MAX_PATH` nodes into a per-CPU cache (`radix_tree_preloads`). `radix_tree_insert()` then draws from this cache without blocking. After inserting, `radix_tree_preload_end()` re-enables preemption and the surplus pre-allocated nodes are returned to the slab.

If the new index requires a taller tree, the tree is grown before descending: the old root node becomes a child of a newly allocated root node, and `height` is incremented.

### Deletion

`radix_tree_delete(root, index)` descends to the leaf, NULLs the slot, clears tag bits, decrements `count` in each ancestor, and frees any node whose `count` drops to zero. Freed nodes are released with `kfree_rcu()` so concurrent RCU readers still holding a pointer into the just-removed subtree see consistent (if stale) data.

### Multi-order entries (huge-page support)

Starting with the THP work that landed around 4.8–4.14, the tree acquired multi-order insert: `__radix_tree_insert(root, index, order, item)` where `order` is log₂ of the span in index units. The entry is stored canonically at the natural alignment boundary, and the remaining slots in the same alignment range are filled with *sibling* markers — tagged internal pointers that point back to the canonical entry. `radix_tree_lookup()` transparently follows sibling markers so callers need no changes. This allows a single huge page to be found by any of its constituent 4 KiB offsets without storing 512 separate pointers.

## Key Data Structures

**`struct radix_tree_root`** (`include/linux/radix-tree.h`) — the tree anchor, embedded in `struct address_space` and other consumers.
- `height` — number of levels in the tree; grows on demand as large indices are inserted
- `gfp_mask` — allocator flags used when nodes must be allocated during insert
- `rnode` — pointer to the root `radix_tree_node`, or directly to a leaf if the tree is height-0

**`struct radix_tree_node`** (`lib/radix-tree.c`) — one internal node; 576 bytes with 64 slots.
- `slots[RADIX_TREE_MAP_SIZE]` — 64 child pointers (or leaf data pointers at the bottom level)
- `tags[RADIX_TREE_MAX_TAGS][RADIX_TREE_TAG_LONGS]` — per-slot tag bitmaps; two tags (dirty, writeback) in the page-cache usage
- `count` — number of non-NULL slots; when it reaches 0 the node is freed
- `parent` — pointer to the parent node, used during deletion to walk upward
- `path` — encodes both the height-from-bottom and the slot index within the parent

## Key Functions / Entry Points

**`radix_tree_lookup(root, index)`** (`lib/radix-tree.c`) — RCU-safe O(log N) lookup; called by `find_get_page()` on the page-cache read path.

**`radix_tree_insert(root, index, item)`** — inserts a new key; returns `-EEXIST` if already present, `-ENOMEM` if preload cache exhausted. Caller must hold the `address_space->tree_lock` spinlock or equivalent.

**`radix_tree_delete(root, index)`** — removes an entry and prunes empty nodes upward; frees nodes via `kfree_rcu()`.

**`radix_tree_gang_lookup(root, results[], first_index, max_items)`** — returns up to `max_items` entries with indices ≥ `first_index`, in ascending order. The readahead code uses this to collect a window of consecutive pages.

**`radix_tree_gang_lookup_tag(root, results[], first_index, max_items, tag)`** — same but filtered by tag; used by the writeback path to find dirty pages without touching clean ones.

**`radix_tree_tag_set/clear/get(root, index, tag)`** — set, clear, or test the tag for a single entry; propagates changes to ancestor tag bitmaps.

**`radix_tree_preload(gfp_mask)`** / **`radix_tree_preload_end()`** — pre-populate the per-CPU node pool before taking a lock that will be held during insert.

## Important Flags & Config Options

`RADIX_TREE_MAP_SHIFT` (compile-time, default 6) — bits consumed per level. Changing this trades node size (memory per node) against tree height (pointer-chasing depth). The default of 6 gives 64-way branching and a node that fits neatly in a cache line pair.

`RADIX_TREE_MAX_TAGS` (2 in the classic tree, 3 in XArray) — number of independent per-entry bits. Increasing this requires proportionally larger `tags[]` bitmaps in every node.

`GFP_ATOMIC` vs. `GFP_KERNEL` in `gfp_mask` — controls whether node allocation in `radix_tree_insert()` may sleep. Interrupt-context callers must use `GFP_ATOMIC` and pair insertion with `radix_tree_preload(GFP_ATOMIC)`.

## Interactions with Other Subsystems

- **↑ Userspace**: `read()`, `mmap()`, and `write()` system calls all funnel through the page cache, which uses the radix tree to check whether a requested file page is already in memory before issuing I/O.
- **→ [[mm -> page-reclaim|Page Reclaim (kswapd)]]**: `radix_tree_gang_lookup_tag(WRITEBACK)` lets reclaim scan for pages still under writeback so it can skip them or wait.
- **→ [[mm -> transparent-huge-pages|Transparent Huge Pages]]**: multi-order radix tree entries allow a single THP to be indexed at its natural 2 MiB alignment without storing 512 individual 4 KiB pointers.
- **← [[mm -> address-space|address_space]]**: every `struct address_space` embeds (or, post-5.1, contains an XArray replacing) `radix_tree_root` to track its in-memory pages.
- **← [[mm -> xarray|XArray]]**: in 4.20+ the radix tree headers become thin shims over XArray; `radix_tree_root` is `typedef`'d to `struct xarray`, `radix_tree_node` to `xa_node`.
- **→ [[subsystem: block|Block Layer]]**: the page cache sitting atop the block layer uses radix-tree gang lookups to gather pages for bio submission in address order, preserving elevator-friendly sequential I/O.

## Design Decisions & Tradeoffs

**Key-space is unsigned long, not arbitrary**: This was an explicit choice to serve the primary use case — file page offsets (`pgoff_t`) — without the complexity of arbitrary-key tries. Everything that needs to map non-integer keys (e.g., symbol tables) uses a different structure.

**No internal locking**: The tree itself holds no lock; callers own synchronization. This is intentional: most page-cache consumers already hold `address_space->i_pages.xa_lock` (formerly `tree_lock`). Embedding a second lock would double the lock overhead for the dominant usage pattern.

**RCU lookups without lock**: Allowing `radix_tree_lookup()` under `rcu_read_lock()` alone (no spinlock) was a deliberate performance win for the page-cache read fast path. The constraint is that lookups may transiently observe a node that has been logically removed but not yet freed — safe only because nodes are freed via `kfree_rcu()`.

**Preload instead of GFP_ATOMIC allocation**: Early implementations tried to allocate nodes during insert using `GFP_ATOMIC`. This was replaced with the preload protocol because `GFP_ATOMIC` allocations are expensive when memory is tight and fail silently. Preloading keeps the fast path allocation-free under the lock.

**Two tags, not more**: The original tree supported exactly two tags (dirty and writeback). Three tags were requested for the DAX path, which was one of the motivations for XArray's expanded mark system (three marks).

## How It Has Evolved

**2.5 era** — Nick Piggin introduced the radix tree to replace the hash-table-based page cache index. This fixed hash collision storms on workloads with many files and enabled ordered gang lookups.

**2.6.18 (2006)** — `radix_tree_lookup()` made RCU-safe (lock-free reads), eliminating the spinlock from the page-cache read fast path for already-cached pages.

**4.8–4.14 (2016–2017)** — Matthew Wilcox added multi-order support for THP and DAX, introducing sibling entries. This was the most invasive change to the tree structure.

**4.20 (2018)** — XArray merged. `radix_tree_root` and `radix_tree_node` became typedefs over XArray internals; the radix-tree API became a compatibility shim. New code was encouraged to use the XArray API directly. The page cache converted to native XArray in 5.1.

**5.15+ (2021–)** — The `struct radix_tree_root` typedef and most compatibility shims remain for out-of-tree code, but in-tree callers have largely migrated to XArray. The classic `lib/radix-tree.c` is now maintained primarily as the XArray's back-end, not as a standalone library.

## Further Reading

1. [Trees I: Radix trees — LWN (2006)](https://lwn.net/Articles/175432/) — foundational introduction by Jonathan Corbet
2. [The multi-order radix tree — LWN (2016)](https://lwn.net/Articles/684864/) — huge-page indexing motivation and design
3. [The XArray data structure — LWN (2018)](https://lwn.net/Articles/745073/) — why the API was replaced
4. [XArray and the mainline — LWN (2018)](https://lwn.net/Articles/757342/) — merge discussion and final API shape
5. [Generic radix trees — LWN (2018)](https://lwn.net/Articles/755281/) — the alternative genradix for fixed-size entries
6. [XArray kernel docs](https://docs.kernel.org/core-api/xarray.html) — current authoritative API reference
7. [Generic radix tree kernel docs](https://docs.kernel.org/core-api/generic-radix-tree.html) — genradix API
8. [Linux Insides: Radix Tree](https://0xax.gitbooks.io/linux-insides/content/DataStructures/linux-datastructures-2.html) — walkthrough of structures and init code

## LKML Highlights

> No specific LKML threads were fetched for this note. The LWN articles above capture the main design debates (multi-order support, XArray migration). See LWN article links for pointers to the originating patch series.
