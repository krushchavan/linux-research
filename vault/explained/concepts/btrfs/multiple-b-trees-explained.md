---
title: "Btrfs Multiple B-Trees — Explained"
category: explained
original: "[[multiple-b-trees]]"
subsystem: btrfs
tags: [explained, btrfs, b-tree, copy-on-write, metadata]
converted: 2026-09-25
---

# Btrfs's family of B-trees, explained

> Plain-language companion to [[multiple-b-trees|the technical note]]. Same facts, fewer identifiers.

## The problem

A filesystem has many kinds of metadata: file sizes and permissions, directory entries, where each file's data lives, which disk space is used and by whom, how logical addresses map onto physical devices, data checksums, subvolume roots. Traditional filesystems use a different on-disk structure for each (inode tables, block bitmaps, directory blocks), each with its own code, its own caching and its own crash-safety logic.

Btrfs also wants cheap snapshots, checksums on everything, and crash consistency without a journal. Doing all of that separately for every structure would be enormous.

## The idea in one paragraph

Treat the filesystem as **a database built from copy-on-write B-trees**. Every piece of metadata, whatever it is, is an item stored under a three-part key (object, type, offset) in one of several trees. All trees use the same node format and the same code: the B-tree code doesn't care what items contain, only how to insert, find and delete keys. Specialisation comes from which tree an item is in and what its type means. And nothing is ever changed in place: a change writes new copies of the affected nodes up to the root, and one atomic superblock write makes it all visible at once.

## Step by step

### Step 1: One node format
Every node starts with the same header: checksum, filesystem ID, the node's own address, the transaction generation it was written in, which tree owns it, how many entries it holds, and its **level**: 0 for a leaf, higher for internal nodes.
- **Internal nodes** hold (key, child address, child generation) entries; a binary search picks the child to follow.
- **Leaves** hold items. Item descriptors grow from the front of the block and their variable-sized contents from the back, so items of any size pack without fragmentation.

### Step 2: One key format for everything
Every item is identified by (**object ID**, **type**, **offset**). The object ID is the most significant, so all items belonging to one object (say, one file) sit together. The type says what the item's contents mean. The offset refines it: a byte position on disk for extents, the first byte covered for checksums, a file offset for file extents. One search function finds any item in any tree.

### Step 3: Working with nodes in memory
Nodes are cached in memory, each with a reference count, a read/write lock and dirty/up-to-date flags. A search records the path it took, the node and slot at each level from root to leaf, so the caller can then modify or step along from there.

### Step 4: Copy-on-write changes
This is the key step. To modify a node, btrfs:
1. allocates a new block
2. copies the old node into it
3. applies the change to the copy
4. updates the parent to point at the copy, which means copying the parent too, and so on up to the root
5. frees the old block when the transaction commits

Every change therefore creates a short chain of new nodes, one per level. The new root's address goes into the root tree (or into the superblock, for the root tree itself). Committing is one atomic superblock write that switches everything over together.

### Step 5: The family of trees
- **Root tree:** a directory of all the other trees, mapping each tree's ID to the location of its root node. It also records subvolumes and how they relate to each other. The superblock points to it directly.
- **Extent tree:** every allocated range of the logical address space, with a reference count and **back-references** saying which tree node or which file uses it. Traditional filesystems only know "file → blocks"; btrfs also knows "block → who uses it".
- **Chunk tree (and device items):** maps logical address ranges onto physical devices and offsets, including the RAID layout. It's the I/O translation layer. It has a bootstrap problem (you need it to translate addresses, but it's stored at an address that needs translating), so the superblock carries a small built-in copy of the mappings needed to find it.
- **Filesystem trees, one per subvolume:** inodes (size, times, mode, link count), directory entries (name → inode, plus an index for stable `readdir` order), back-references from inode to directory, and file extents (either small data stored inline, or a pointer to a data extent).
- **Checksum tree:** per-4 KiB checksums for all data.
- **Free space tree:** where the free space is within each block group, so allocation doesn't need to scan the extent tree at mount.
- **Log tree:** temporary, per subvolume. `fsync` writes just the affected inodes and entries here so they survive a crash before the next full commit; it's replayed at mount and deleted after a successful commit.

### Step 6: Snapshots for almost nothing
Because nodes are never modified in place, a snapshot is just a new entry in the root tree pointing at the *same* root node, with reference counts raised. From then on, changes to either copy write new nodes and the two diverge.

### Step 7: Locking
Each node has a read/write lock. Writers lock from the root down and can release a parent early once it's clear the change won't split or merge that parent.

## The picture

```text
 superblock ──▶ root tree ──┬─▶ extent tree     (what's allocated, who uses it)
   (+ bootstrap              ├─▶ chunk tree      (logical → device, offset, RAID)
    chunk map)               ├─▶ fs tree: subvol 5   (inodes, dirs, file extents)
                             ├─▶ fs tree: snapshot   ──▶ shares nodes with subvol 5
                             ├─▶ checksum tree   (per-4 KiB checksums)
                             └─▶ free space tree

 every item keyed (object, type, offset), e.g. (257, INODE, 0), (257, EXTENT_DATA, 8192)

 modify leaf ──▶ copy leaf ─▶ copy parent ─▶ ... ─▶ new root ──▶ superblock write = commit
```

## Tradeoffs

- **What it gives you:** one well-tested code path for caching, checksumming, copy-on-write and replication of all metadata; cheap snapshots; crash consistency without a journal; and back-references that let device removal and scrub find every user of a block without scanning the whole filesystem.
- **What it costs / requires:** write amplification (a chain of new nodes per change), larger extent records and more writes to maintain back-references, and fragmentation over time, which balance addresses. A shared node format means no tree gets a specially tight layout.
- **Where it bites:** a single extent tree became a bottleneck on huge filesystems (hundreds of millions of extents), since all allocation went through its root. Separate trees help concurrency in general, which is why btrfs didn't use one giant tree.

## How it got here

- **2.6.29 (2009):** merged with the root, extent, chunk, filesystem and checksum trees.
- **3.2 (2012):** a smaller item format for metadata extents.
- **2013–2015:** the free space tree (Josef Bacik) replaced an older free-space cache stored as a special file, which had its own bootstrap problem.
- **5.x:** the free space tree became the default on new filesystems.
- **6.1 (2022):** "extent tree v2" with per-block-group extent trees for parallel allocation (Josef Bacik), after review about migration and feature compatibility.

## Related

- Technical version: [[multiple-b-trees]]
- [[btrfs-explained|Btrfs]]: the subsystem overview
- [[transaction-model-explained|transaction-model]]: how tree changes are committed together
- [[subvolumes-and-snapshots-explained|subvolumes-and-snapshots]]: separate filesystem trees sharing nodes
- [[raid-and-multi-device-support-explained|raid-and-multi-device-support]]: what the chunk tree maps to
- [[checksumming-and-data-integrity-explained|Checksumming and data integrity]]
- [[balance-and-device-management-explained|Balance and device management]]
- [[persistent-data-library-explained|Device mapper's persistent-data library]]: the same copy-on-write B-tree idea in the block layer
