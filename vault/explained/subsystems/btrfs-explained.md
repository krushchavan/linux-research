---
title: "Btrfs — Explained"
category: explained
original: "[[btrfs]]"
subsystem: btrfs
tags: [explained, btrfs, filesystem, cow, snapshots]
converted: 2026-09-25
---

# Btrfs, explained

> Plain-language companion to [[btrfs|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

A filesystem has to survive crashes. If the power fails halfway through updating a file's metadata, the disk mustn't be left in a half-updated, inconsistent state. Traditional filesystems handle this with a *journal*: write down what you're about to do, then do it in place.

But in-place updates have other limits. You can't cheaply take a snapshot of the whole filesystem, because the old version is overwritten as you go. You can't tell when the disk silently returns the wrong bytes (bitrot, firmware bugs), because nothing records what the right bytes were. And spreading data across several disks with mirroring usually needs a separate layer underneath.

Btrfs, merged in 2.6.29 (2009) and now the default on Fedora and openSUSE, tackles all of these with one idea.

## The big picture

**Btrfs never overwrites anything in place.** Every piece of information on disk, including the filesystem's own bookkeeping, lives in *copy-on-write B-trees*. To change a block, btrfs writes a new copy somewhere else, then updates the parent to point at the copy (which means writing a new copy of the parent too), all the way up to the top. Finally it atomically switches one master pointer, in the superblock, to the new top.

A crash at any moment leaves the old, complete, consistent tree untouched. And a snapshot is nearly free: it's a second pointer to the same tree.

Btrfs has several specialised trees rather than one, all hung off a *root tree* that the superblock points to.

```text
                     SUPERBLOCK  (copies at 64 KiB, 64 MiB, 256 GiB)
                          │
                          ▼
                     ROOT TREE  ── "directory of all the trees"
      ┌────────┬──────────┼───────────┬───────────┬───────────────┐
      ▼        ▼          ▼           ▼           ▼               ▼
   EXTENT   CHECKSUM    CHUNK       DEVICE    FILE TREE      (free space,
   tree     tree        tree        tree      per subvolume   block group,
  who owns  checksum   logical ─▶  physical ─▶ files, dirs,   RAID stripe
  each      of every   physical    logical     extents        trees)
  block     data block  map        map
```

Every read and write goes through the chunk tree to turn a logical address into a place on a real device. Every data and metadata block has a checksum.

## The pieces

### The copy-on-write B-tree engine
See [[cow-b-tree-engine]].

Everything is stored in B+ trees. Inner nodes hold keys and pointers to children; leaves hold keys and variable-sized items packed together. Every item is found by a three-part key: which object (an inode number, a tree ID…), what type of item (inode, directory entry, file extent…), and an offset whose meaning depends on the type.

To modify a node:
1. Allocate a new block and copy the node into it.
2. Make the change in the copy.
3. Point the parent at the copy, which means copying the parent too, recursively up to the root.
4. At commit, record the new root. The old block's reference count drops, and when it reaches zero the space is free.

This gives atomic, crash-consistent updates without a journal.

### Transactions
See [[transaction-model-explained|transaction-model]].

Changes are grouped into transactions, each with an increasing *generation* number.
1. Many writers can join the same open transaction.
2. Every node they rewrite is stamped with the transaction's generation. Dirty nodes wait in memory.
3. At commit, batched reference-count updates are applied, all dirty nodes are written, new roots are recorded, and the superblock is written to all its copies.
4. Once the new superblock is safely on disk, blocks only the old version used can be freed.

Every parent-to-child pointer also records the generation it expects the child to have. If a read finds a mismatch, btrfs knows a write went to the wrong place, catching "phantom writes" without re-checking every parent.

### The trees
See [[multiple-b-trees-explained|multiple-b-trees]].

Different kinds of metadata get their own trees so they can grow and be managed independently:
- **Root tree:** the directory of all other trees. Every lookup starts here.
- **Extent tree:** every allocated range, its size, its reference count, and *back-references* recording who owns it. That's what lets repair tools find which file a corrupt block belongs to.
- **Chunk tree:** logical addresses to physical device locations, including the RAID layout. Kept in special system areas so it can be found early at mount.
- **Device tree:** the reverse map, physical to logical, used when scrubbing, rebalancing or removing a device.
- **Checksum tree:** a checksum for every 4 KiB data block.
- **File trees:** one per subvolume, holding inodes, directory entries, file extents and extended attributes.
- **Newer trees:** a free-space tree (4.9) replacing an in-memory cache, a block-group tree (6.1) that speeds up mounting large filesystems, and a RAID stripe tree (6.7).

### Subvolumes and snapshots
See [[subvolumes-and-snapshots-explained|subvolumes-and-snapshots]].

A **subvolume** is an independently mountable filesystem inside the volume, with its own file tree. It looks like a directory in its parent.

A **snapshot** is created by adding a new entry to the root tree that points at the *same* top block as the source. Nothing is copied, so it takes constant time. From then on, any write to either side copies only the affected nodes, and unchanged blocks stay shared with a reference count above one.

Because the extent tree knows who references each block, the quota system can report two numbers per subvolume: *referenced* (everything it uses, shared or not) and *exclusive* (what deleting it would actually free).

**Send/receive** compares two read-only snapshots by walking both trees side by side and emits a stream of changes. Replaying that stream elsewhere gives efficient incremental backups.

### RAID and multiple devices
See [[raid-and-multi-device-support-explained|raid-and-multi-device-support]].

Btrfs does RAID itself, at the level of large allocation chunks, with separate choices for data and metadata:
- **single** (one copy), **DUP** (two copies on the same device), **RAID0** (striped, no redundancy)
- **RAID1** (two devices), **RAID1C3/C4** (three or four copies, 5.5+), **RAID10**
- **RAID5/6** (parity): **known bugs, not recommended for production** as of 2026.

A common setup is RAID1 for metadata and RAID0 or RAID1 for data. **Scrub** reads everything, checks it against the checksums, and repairs bad copies from good mirrors. **Balance** redistributes chunks to add or remove devices, or convert between profiles, while mounted.

### Checksums and data integrity
See [[checksumming-and-data-integrity-explained|checksumming-and-data-integrity]].

1. On every write, each 4 KiB block gets a checksum stored in the checksum tree. Every tree node carries its own checksum in its header.
2. On every read, the checksum is verified.
3. On a mismatch with only one copy, you get an I/O error instead of silently wrong data. With a mirror, btrfs reads the other copy and, if that's good, rewrites the bad one.

The algorithm is chosen when the filesystem is created: CRC32c by default (hardware-accelerated), or xxhash, SHA-256 or BLAKE2 (5.5+).

### In-memory structures
See [[core-in-memory-structures]].

One per-mount object ties everything together: pointers to all the trees, the cache of subvolume roots, the block groups, the batched reference updates, and background threads for committing and cleanup. Each open file has a btrfs-specific inode that knows its subvolume, its key, its pending I/O, a cache of its extents, and flags like "compress" or "no checksums".

## A request's journey

Writing 64 KiB to a file:

1. **The write arrives.** The application writes; the VFS asks btrfs to prepare page-cache pages.
2. **Reserve space.** Btrfs joins a transaction and reserves room for the new extent.
3. **Copy into memory.** The data is copied into the page cache and marked dirty. The application returns.
4. **Writeback starts later.** When the kernel's writeback machinery flushes the file, btrfs allocates a *new* location on disk. It never overwrites the old data.
5. **Checksum.** Each 4 KiB block's checksum is computed and recorded in the checksum tree.
6. **Submit I/O.** The chunk tree turns the logical location into device locations (two, if mirrored), and the data goes to the block layer.
7. **Update metadata by copy-on-write.** The file's extent item in its subvolume tree is updated, copying nodes up to the root.
8. **Commit.** The transaction writes all dirty nodes, then the superblock. Only now does the new version become *the* filesystem.

## Tradeoffs

- **What it gives you:** crash consistency without a journal, instant snapshots, checksums on all data (not only metadata), built-in RAID, online self-healing, transparent compression (zlib, LZO, ZSTD) and incremental send/receive.
- **What it costs / requires:** every change touches several trees (file tree, extent tree, checksum tree), so even small operations do more work than on ext4 or XFS. Copy-on-write fragments files over time; large extents and defragmentation mitigate it. Checksums add I/O (about 25 MB of checksums per 100 GB of data). Reference-count updates are batched to amortise cost, but under heavy load the batch grows and commits take longer.
- **Where it bites:** RAID5/6, whose parity updates are hard to make crash-safe without a journal, remains unsafe. And long-lived snapshots of busy subvolumes hold onto old blocks, which can use a lot of extra space.

## How it got here

- **2.6.29 (2009):** merged with copy-on-write trees, checksums, subvolumes and snapshots; multi-device RAID 0/1/10 soon after.
- **3.5–3.14 (2012–2014):** RAID5/6 (with known limits), send/receive, and online scrub and balance.
- **4.9 (2016):** the free-space tree.
- **5.5–5.15 (2020–2021):** three- and four-copy mirroring, new checksum algorithms, zoned-device support, and reading/writing compressed data without decompressing it.
- **6.1–6.2 (2022–2023):** the block-group tree speeds up mounting; RAID5 parity updates get checksum verification (RAID6 still needs work).
- **6.7–6.9 (2024):** the RAID stripe tree (RAID on zoned devices, groundwork for fixing RAID5/6), *simple quotas* as a lighter replacement for the fragile quota-group system, and experimental block sizes larger than the page size.

## Related

- Technical version: [[btrfs]]
- [[cow-b-tree-engine|Copy-on-write B-trees]], [[transaction-model-explained|transactions]], [[multiple-b-trees-explained|the trees]]
- [[subvolumes-and-snapshots-explained|Subvolumes and snapshots]], [[send-receive-protocol-explained|send/receive]], [[qgroups-explained|quota groups]]
- [[raid-and-multi-device-support-explained|RAID]], [[balance-and-device-management-explained|balance]], [[checksumming-and-data-integrity-explained|checksums]]
- [[space-accounting-and-block-groups-explained|Space accounting]], [[core-in-memory-structures|in-memory structures]]
- [[fs-explained|Filesystems]], [[vfs|VFS]], [[block-explained|block layer]]
