---
title: "Btrfs COW B-tree Engine"
category: concept
tags: [btrfs, b-tree, cow, snapshots, reference-counting]
subsystem: btrfs
kernel_version: "2.6.29"
researched: 2026-09-25
status: complete
sources:
  - https://btrfs.readthedocs.io/en/latest/dev/dev-btrfs-design.html
  - https://btrfs.readthedocs.io/en/latest/dev/dev-btrees.html
  - https://lwn.net/Articles/342892/
  - https://dl.acm.org/doi/10.1145/1326542.1326544
  - https://dl.acm.org/doi/10.1145/2501620.2501623
  - https://ratatoskr.run/linux-btrfs/2026/02/7625736/t
  - https://github.com/btrfs/btrfs-todo/issues/25
---

# Btrfs COW B-tree Engine

## Purpose

Btrfs keeps *everything* (inodes, directories, file extent maps, checksums, free-space records, the chunk map) in B-trees, and it never overwrites a live tree block in place. That gives crash consistency without a journal and makes snapshots nearly free, but only if the B-tree algorithms themselves are designed for copy-on-write. Classic B+-trees chain leaves together and rebalance bottom-up, which under copy-on-write would force rewriting large parts of the tree for every change. The COW B-tree engine (`fs/btrfs/ctree.c`) is the single, generic piece of code that searches, inserts into, deletes from and splits every btrfs tree while respecting copy-on-write and sharing blocks between snapshots. This note covers the engine's algorithms; the on-disk node layout, key format and the family of trees are covered in [[multiple-b-trees]].

## Mental Model

Think of the tree as a **family of shared documents where you're only allowed to photocopy, never erase**. To change a sentence on one page, you photocopy that page and edit the copy, then photocopy the table of contents that pointed to the old page and fix the pointer, and so on up to the cover sheet. Nothing anyone else is holding changes. A snapshot is simply a second cover sheet pointing at the same pages; each page carries a **count of how many trees point to it**, so the system knows a page may be thrown away only when nobody points at it any more. And because you photocopy on the way *down*, splitting any page that's nearly full before you reach the bottom, you never have to walk back up to fix things afterwards.

## How It Works

**Origins.** The design comes from Ohad Rodeh's IBM research on "B-trees, shadowing, and clones" (2006–2008), which Chris Mason adopted for btrfs in 2007. Rodeh's key moves were: **no leaf chaining** (leaves don't point to their siblings, so a COW of one leaf doesn't force a COW of its neighbour), **top-down proactive splitting and merging** (so an operation touches each level once, on the way down), and **reference-counted blocks** so that many trees (clones, i.e. snapshots) can share subtrees and a shadowed block's children are counted lazily.

**Every operation starts with a search.** Callers ask the engine to find a key with `btrfs_search_slot(trans, root, key, path, ins_len, cow)`. The `struct btrfs_path` it fills records, for every level from the root down to a leaf, which tree block (`extent_buffer`) was visited and which slot within it, plus which levels are locked. `ins_len` tells the engine what the caller is about to do: a positive value means "I will insert this many bytes", a negative one means "I will delete", zero means "read only". `cow` says whether the caller will modify the tree. A read-only search walks down comparing keys with a binary search in each node (`btrfs_bin_search()`), taking read locks, and returns the slot where the key is or would be.

**COW on the way down.** When `cow` is set, the search copies each block on the path **before** descending into it. `btrfs_cow_block()` first asks `should_cow_block()` whether this block needs copying at all. A block that was **already created in the current transaction** (its header generation equals the running transaction id), hasn't been written to disk yet (no `BTRFS_HEADER_FLAG_WRITTEN`), and isn't marked for relocation can simply be modified in place, because nothing outside this transaction can see it. That's what keeps a transaction that makes thousands of changes from copying the same blocks thousands of times: each block is COWed at most once per transaction. Otherwise `__btrfs_cow_block()` allocates a new tree block, copies the contents, stamps the new `bytenr`, generation and owner into the header, updates the parent's pointer (key pointer `blockptr` and expected `generation`) to the copy, and releases the old block. If the block was the root, the root pointer in `struct btrfs_root` is switched instead. Because this happens top-down, by the time the search reaches the leaf, the whole path from the root is already private to this transaction and can be modified freely.

**Split and merge before you need to.** On the way down, the search also makes room. If the caller will insert (`ins_len > 0`) and an internal node is nearly full, `split_node()` splits it now, while its parent (already COWed and locked) can take the new pointer. At the leaf, if the item won't fit, `split_leaf()` first tries pushing items into the left or right neighbour (`push_leaf_left()` / `push_leaf_right()`), and only then splits. For deletions (`ins_len < 0`), nodes that are becoming sparse are rebalanced or merged with neighbours (`balance_level()`) during the descent. This is Rodeh's "proactive" discipline: because splits and merges happen top-down, no change ever has to propagate *back up* the tree after the leaf is modified, which is what makes copy-on-write and fine-grained locking tractable.

**Modifying the leaf.** With the path prepared, the caller uses `btrfs_insert_empty_items()` / `btrfs_insert_item()` to add items (keys go into the item array at the front of the leaf, data into the data area at the back), `btrfs_del_items()` to remove them, or edits item data in place through the path. If the first key in a leaf changes, `fixup_low_keys()` updates the separator keys in the (already COWed) parents. Dirty blocks are tracked by the transaction and written at commit; see [[transaction-model]].

**Walking without leaf links.** Since leaves aren't chained, iteration uses the path: `btrfs_next_leaf()` climbs up the path to the first ancestor with a slot to the right, then descends to the leftmost leaf of that subtree. Range scans such as reading a directory or a file's extent items do this repeatedly.

**Sharing and reference counting.** Every tree block is an extent recorded in the extent tree with a **reference count** and **back references** saying who points to it. Taking a snapshot copies only the subvolume's root node (`btrfs_copy_root()`) and adds a reference for each child it points to; the rest of the tree is shared. The interesting moment is when a *shared* block is COWed. `update_ref_for_cow()` handles it:
- If the block is still referenced by another tree, the new private copy needs its own references to all the children it points to, so `btrfs_inc_ref()` adds one for each child (this is Rodeh's lazy scheme: children's counts are only bumped when a shared parent is actually shadowed, not at snapshot time).
- If the block's owner tree is COWing it while it's shared, the children get **full back references** (keyed by the parent block's address rather than by root id, flagged `BTRFS_BLOCK_FLAG_FULL_BACKREF`), which makes it possible to find all referrers later even though the owning tree has moved on.
- Finally the old block's own reference is dropped (`btrfs_free_tree_block()`); if that was the last one, it becomes free space after the transaction commits.

Doing these extent-tree updates immediately would mean modifying the extent tree (itself a COW B-tree) inside every COW, recursively. Instead they are queued as **delayed references** and applied in batches, mostly during transaction commit, where many increments and decrements on the same extent cancel out.

**Deleting a snapshot.** Dropping a subvolume (`btrfs_drop_snapshot()`) walks its tree top-down. A block with a reference count of one belongs only to this tree and can be freed together with its subtree; a shared block just loses one reference and the walk doesn't descend into it, because another tree still owns everything below. This makes deleting a snapshot cost proportional to what it doesn't share.

**Locking.** Each extent buffer has a reader/writer lock (a rw_semaphore since the lock rework by Josef Bacik). Searches use **lock coupling**: take the child's lock, then release the parent's, keeping upper levels locked only when a split or key fix-up might still need them (`path->keep_locks`, `path->lowest_level`). Read-only searches can use the **commit root**, the tree as of the last committed transaction, without taking locks at all (`path->search_commit_root`, `skip_locking`), which is how background work like scrub and send avoids contending with writers.

**Failure paths.** Every tree block read verifies its checksum, its header `bytenr`, and that its generation matches what the parent pointer expected; a mismatch (a lost or misdirected write) turns into an I/O error or triggers repair from a mirror. If a COW or insert fails partway (out of metadata space, an I/O error), the transaction is **aborted**, the filesystem goes read-only, and the on-disk state stays at the last committed transaction, because nothing live was ever overwritten.

## Key Data Structures

**`struct btrfs_path`** (`fs/btrfs/ctree.h`) — the cursor for one tree operation.
- `nodes[BTRFS_MAX_LEVEL]` — extent buffer at each level from leaf (0) to root
- `slots[BTRFS_MAX_LEVEL]` — slot index at each level
- `locks[]` — which lock type is held at each level
- `keep_locks`, `lowest_level`, `search_commit_root`, `skip_locking` — control locking and where the search stops

**`struct extent_buffer`** (`fs/btrfs/extent_io.h`) — in-memory handle for one tree block: `start` (bytenr), `len`, backing folios, reference count, the tree `lock`, and flags (dirty, uptodate, written).

**`struct btrfs_header`** — per-block header: checksum, fsid, `bytenr`, `flags` (including `WRITTEN` and `RELOC`), `generation`, `owner`, `nritems`, `level`. Detailed in [[multiple-b-trees]].

**`struct btrfs_key_ptr`** — internal-node entry: `key`, child `blockptr`, and the child's expected `generation`.

**Delayed ref head / node** (`fs/btrfs/delayed-ref.h`) — queued reference count changes per extent, merged and applied in batches.

## Key Functions / Entry Points

**`btrfs_search_slot()`** (`fs/btrfs/ctree.c`) — find a key, optionally COWing, splitting or balancing on the way down.
**`btrfs_cow_block()` / `should_cow_block()` / `__btrfs_cow_block()`** — decide whether a block needs a copy this transaction, and make it.
**`update_ref_for_cow()`** — adjust reference counts and back references when a shared block is copied.
**`split_node()` / `split_leaf()` / `push_leaf_left()` / `push_leaf_right()` / `balance_level()`** — proactive restructuring.
**`btrfs_insert_empty_items()`, `btrfs_del_items()`** — leaf item insertion and removal.
**`btrfs_next_leaf()`** — iteration without leaf links.
**`btrfs_copy_root()`** — snapshot creation at the tree level.
**`btrfs_drop_snapshot()`** — refcount-guided subtree deletion.
**`btrfs_inc_ref()` / `btrfs_dec_ref()` / `btrfs_free_tree_block()`** — reference bookkeeping via delayed refs.

## Important Flags & Config Options

- `BTRFS_HEADER_FLAG_WRITTEN` — block already written to disk this transaction; must be COWed again before modification.
- `BTRFS_HEADER_FLAG_RELOC` — block belongs to a relocation tree (used by balance).
- `BTRFS_BLOCK_FLAG_FULL_BACKREF` — children of this block are referenced by parent bytenr rather than root id.
- Node size (`mkfs.btrfs -n`, default 16 KiB) — bigger nodes mean shallower trees and fewer COWs per path, but more data copied per COW and more lock contention.
- `CONFIG_BTRFS_DEBUG`, `CONFIG_BTRFS_ASSERT` — extra tree checks during development.

## Interactions with Other Subsystems

- **↑ Userspace**: every file operation on btrfs becomes tree searches and item edits; `btrfs subvolume snapshot` becomes `btrfs_copy_root()`; `btrfs subvolume delete` becomes `btrfs_drop_snapshot()`.
- **→ [[transaction-model]]**: COW decisions depend on the running transaction id; dirty blocks and delayed refs are flushed at commit.
- **→ [[space-accounting-and-block-groups]]**: every COW allocates a new metadata block, so metadata space must be reserved before an operation starts.
- **→ [[checksumming-and-data-integrity]]**: every block carries a checksum and expected generation verified on read.
- **← [[subvolumes-and-snapshots]]**: snapshots are cheap because the engine shares blocks by reference count.
- **← [[balance-and-device-management]]**: relocation COWs blocks into new locations using relocation trees.
- **→ [[page-cache]]**: extent buffers are backed by folios in the btree inode's page cache.

## Design Decisions & Tradeoffs

- **COW instead of journaling.** Never overwriting live blocks makes every commit atomic and snapshots free, at the price of **write amplification**: changing one item COWs the whole path from leaf to root (the "wandering tree" cost), and metadata tends to fragment over time.
- **No leaf chaining.** Makes each leaf COW local; the cost is that scans must climb back up the path to find the next leaf.
- **Top-down proactive split/merge.** Lets an operation finish in one downward pass, simplifying COW and locking, but sometimes splits nodes that didn't strictly need it.
- **Once-per-transaction COW.** `should_cow_block()` amortises copies across a transaction; the flip side is that background writeback of a still-changing block (setting `WRITTEN`) forces another copy. A 2026 patch series targeted exactly this "COW amplification".
- **Lazy, delayed reference counting.** Keeps snapshot creation O(1) and batches extent-tree updates, but makes accounting complex (delayed-ref throttling, qgroup interactions) and puts a lot of work into commit.
- **One generic engine for every tree.** All trees share the same code, so improvements apply everywhere; the cost is that very different workloads (the hot extent tree vs. per-subvolume fs trees) contend on the same design, which motivates the proposed "extent tree v2" rework.

## How It Has Evolved

- **2006–2008** — Ohad Rodeh's "B-trees, shadowing, and clones" research (USENIX / ACM TOS).
- **2007** — Chris Mason starts btrfs on this design.
- **2.6.29 (2009)** — btrfs merged; generic COW B-tree engine with reference-counted sharing and delayed references.
- **~2.6.31** — back-reference format reworked (Yan Zheng), introducing full back references for shared blocks.
- **Later 2.6.x–3.x** — commit-root searches without locking, relocation trees for balance, many locking refinements.
- **5.x** — extent buffer tree locks converted to rw_semaphores (Josef Bacik), replacing the custom spinning/blocking lock.
- **6.x / 2026** — work on COW amplification from background writeback; "extent tree v2" proposed to reduce contention and reference-count overhead.

## Further Reading

1. [Btrfs design — btrfs documentation](https://btrfs.readthedocs.io/en/latest/dev/dev-btrfs-design.html)
2. [A short history of btrfs — LWN (Valerie Aurora, 2009)](https://lwn.net/Articles/342892/)
3. [B-trees, shadowing, and clones — Ohad Rodeh, ACM TOS](https://dl.acm.org/doi/10.1145/1326542.1326544)
4. [BTRFS: The Linux B-Tree Filesystem — Rodeh, Bacik, Mason, ACM TOS 2013](https://dl.acm.org/doi/10.1145/2501620.2501623)
5. [Btrfs B-trees — btrfs developer docs](https://btrfs.readthedocs.io/en/latest/dev/dev-btrees.html)
6. [Extent tree v2 proposal — btrfs-todo #25](https://github.com/btrfs/btrfs-todo/issues/25)

## LKML Highlights

> lore.kernel.org was unreachable (TLS certificate error) during this session; summarised from other archives.

- **"btrfs: fix COW amplification…" (linux-btrfs, 2026)** — showed that background writeback setting `WRITTEN` on a buffer still being modified by its own transaction forced needless re-COWs, and proposed re-dirtying such buffers instead of copying them.
- **Extent tree v2 (Josef Bacik, btrfs-todo)** — argued the single global extent tree and its reference counting are a scalability bottleneck, proposing per-block-group trees and dropping some back references.
