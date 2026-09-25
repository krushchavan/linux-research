---
title: "Btrfs COW B-tree Engine — Explained"
category: explained
original: "[[cow-b-tree-engine]]"
subsystem: btrfs
tags: [explained, btrfs, b-tree, cow, snapshots]
converted: 2026-09-25
---

# The btrfs COW B-tree engine, explained

> Plain-language companion to [[cow-b-tree-engine|the technical note]]. Same facts, fewer identifiers.

## The problem

Btrfs stores *everything* (inodes, directories, file extent maps, checksums, free space, the device map) in B-trees, and it never overwrites a live tree block. That gives crash safety without a journal and makes snapshots nearly free, but only if the B-tree algorithms are built for copy-on-write. Textbook B+-trees link leaves to their neighbours and rebalance from the bottom up, so under copy-on-write one small change would force rewriting large parts of the tree. The engine is the single, generic piece of code that searches, inserts, deletes and splits in every btrfs tree while respecting copy-on-write and sharing blocks between snapshots. (The block layout, keys and the family of trees are covered in [[multiple-b-trees-explained|the multiple B-trees note]].)

## The idea in one paragraph

Think of **a family of shared documents where you may photocopy but never erase**. To change a sentence, you photocopy that page and edit the copy, then photocopy the table of contents that pointed to the old page and fix the pointer, and so on up to the cover sheet. Nothing anyone else holds changes. A snapshot is a second cover sheet pointing at the same pages, and each page records **how many trees point to it**, so it's thrown away only when nobody does. Because you photocopy on the way *down*, splitting any nearly full page before you reach the bottom, you never have to climb back up to fix things afterwards.

## Step by step

### Step 1: The design's roots
The design comes from Ohad Rodeh's IBM research on "B-trees, shadowing, and clones" (2006–2008), adopted by Chris Mason for btrfs in 2007. Its key moves: **no links between leaves**, so copying one leaf doesn't force copying its neighbour; **split and merge top-down, in advance**, so an operation touches each level once, on the way down; and **reference-counted blocks**, so many trees can share subtrees.

### Step 2: Every operation starts with a search
The caller asks for a key and says what it will do: insert this many bytes, delete, or only read, and whether it will modify the tree. The search walks down from the root, binary-searching each block, and fills in a **path**: for every level, which block was visited, which slot, and which locks are held.

### Step 3: Copy on the way down
This is the key step. If the caller will modify the tree, each block on the path is copied **before** descending into it, but only if needed. A block **already created in this transaction**, not yet written to disk and not marked for relocation is invisible to anything outside the transaction, so it can be edited in place. That's why a transaction making thousands of changes copies each block at most once. Otherwise the engine allocates a new block, copies the contents, stamps the new address, transaction number and owner into its header, points the parent at the copy (along with the expected transaction number) and releases the old block. For the root, the tree's root pointer switches instead. By the time the search reaches the leaf, the whole path is private to this transaction.

### Step 4: Make room in advance
While descending for an insert, any nearly full internal node is split **now**, while its parent (already copied and locked) can take the new pointer. At the leaf, if the item won't fit, the engine first tries pushing items to the left or right neighbour, and only then splits. For deletions, nodes getting sparse are rebalanced or merged on the way down. Since restructuring happens top-down, no change ever needs to travel back *up* after the leaf is modified, which is what makes copy-on-write and fine-grained locking workable.

### Step 5: Edit the leaf
With the path ready, the caller inserts items (keys at the front of the leaf, data packed at the back), deletes them, or edits data in place. If a leaf's first key changes, the separator keys in the (already copied) parents are updated. Dirty blocks are written at transaction commit.

### Step 6: Walking without leaf links
Since leaves aren't chained, moving to the next leaf means climbing the path to the first ancestor with a slot further right, then descending to the leftmost leaf below it. Directory listings and extent scans do this repeatedly.

### Step 7: Sharing and reference counts
Every tree block is recorded as an extent with a **reference count** and **back references** saying who points at it. Taking a snapshot copies only the root node and adds a reference to each child; everything else is shared. The subtle moment is copying a **shared** block:
- If another tree still uses the block, the new private copy needs its own reference to every child it points to, so those children's counts go up. This is Rodeh's lazy scheme: counts are bumped only when a shared parent is actually copied, not at snapshot time.
- If the block's owning tree copies it while it's shared, the children get **full back references**, recorded by the parent block's address rather than the tree's id, so all referrers can still be found after the owner has moved on.
- The old block then loses one reference; at zero it becomes free space after the commit.

Applying these updates to the extent tree immediately would mean editing the extent tree (itself a copy-on-write B-tree) inside every copy, recursively. Instead they're queued as **delayed references** and applied in batches, mostly at commit, where many increments and decrements on the same extent cancel out.

### Step 8: Deleting a snapshot
Deleting a subvolume walks its tree top-down. A block referenced only by this tree is freed along with its subtree. A shared block just loses one reference, and the walk doesn't descend into it, because another tree still owns everything below. The cost is proportional to what the snapshot *doesn't* share.

### Step 9: Locking and failures
Each block has a reader/writer lock. Searches use **lock coupling**: lock the child, release the parent, keeping upper levels locked only while a split or key fix-up might still need them. Read-only work can search the **commit root**, the tree as of the last commit, without any locks, which is how scrub and send avoid getting in writers' way. Every block read checks its checksum, its own address and that its transaction number matches what the parent expected, catching lost or misdirected writes. If an operation fails partway (out of metadata space, an I/O error), the transaction aborts, the filesystem goes read-only, and the disk stays at the last commit, because nothing live was overwritten.

## The picture

```text
 change one item in leaf L:
   root R ─copy→ R'      (skip if already copied this transaction)
     node N ─copy→ N'    split now if nearly full
       leaf L ─copy→ L'  edit item
   parents point to the copies; old R, N, L lose a reference

 snapshot S shares R's children:   R  ─┐
                                   S  ─┴─▶ N (refcount 2)
 copying shared N → N' adds refs to N's children (lazy counting)
 reference updates queued as delayed refs → applied in batches at commit
```

## Tradeoffs

- **What it gives you:** atomic commits and crash safety without a journal; snapshots that cost almost nothing to create; one engine behind every tree; lock-free reads of the committed tree.
- **What it costs / requires:** **write amplification**: changing one item copies the whole path from leaf to root, and metadata fragments over time. Lazy, delayed reference counting keeps snapshots cheap but makes accounting complex and loads work onto commit.
- **Where it bites:** copying at most once per transaction only works while a block hasn't been written. If background writeback flushes a block its transaction is still changing, it must be copied again. A 2026 patch series targeted this "COW amplification". Sharing one design across very different trees, such as the busy extent tree and per-subvolume trees, is what drives the proposed "extent tree v2" rework.

## How it got here

- **2006–2008:** Ohad Rodeh's research on copy-on-write B-trees and clones.
- **2007:** Chris Mason starts btrfs on this design.
- **2.6.29 (2009):** btrfs merged with the generic engine, shared reference-counted blocks and delayed references.
- **~2.6.31:** back references reworked (Yan Zheng), adding full back references for shared blocks.
- **Later:** lock-free commit-root searches, relocation trees for balance, many locking refinements; in 5.x, block locks became reader/writer semaphores (Josef Bacik).
- **6.x / 2026:** fixes for COW amplification; extent tree v2 proposed to cut contention and reference-count overhead.

## Related

- Technical version: [[cow-b-tree-engine]]
- [[btrfs-explained|Btrfs]], [[multiple-b-trees-explained|Multiple B-trees]], [[transaction-model-explained|Transaction model]], [[subvolumes-and-snapshots-explained|Subvolumes and snapshots]], [[space-accounting-and-block-groups-explained|Space accounting]], [[checksumming-and-data-integrity-explained|Checksumming]], [[balance-and-device-management-explained|Balance]]
