---
title: "Btrfs Subvolumes and Snapshots — Explained"
category: explained
original: "[[subvolumes-and-snapshots]]"
subsystem: btrfs
tags: [explained, btrfs, subvolumes, snapshots, copy-on-write]
converted: 2026-09-25
---

# Btrfs subvolumes and snapshots, explained

> Plain-language companion to [[subvolumes-and-snapshots|the technical note]]. Same facts, fewer identifiers.

## The problem

People want to take point-in-time copies of a filesystem (before an upgrade, for backups, for rollback) without waiting for gigabytes to be copied and without doubling the space used. They also want to split one disk into several independent trees that can be mounted, copied, deleted or replicated separately, without the rigidity of fixed-size partitions.

## The idea in one paragraph

A **subvolume** is an independent filesystem tree living inside one btrfs volume; a **snapshot** is simply a new subvolume that starts out sharing every block with another one. Picture a library building with many rooms: all rooms share the walls, plumbing and wiring (the allocator and copy-on-write machinery). A snapshot is a photocopy of a room's **index card**: two cards pointing at the same shelves. When books are added or moved in one room, new copies of just those shelves are made and only that room's card is updated. Over time each room diverges, still sharing every shelf nobody has touched.

## Step by step

### Step 1: Each subvolume is its own B-tree
Every subvolume has its own filesystem tree (IDs 256 and up; lower IDs are internal trees). The **root tree** acts as a directory of subvolumes: one entry per subvolume records, above all, the disk address of that tree's root block, plus its generation, flags (such as read-only), a reference count, and a marker for when it was last snapshotted.

Each subvolume numbers its inodes independently, with 256 always its top directory. Because a hard link means sharing one inode, and an inode lives in exactly one tree, **hard links can't cross subvolumes**.

### Step 2: Creating a subvolume
Creating a subvolume takes a new tree ID, builds an empty tree with a single leaf, adds its entry in the root tree, creates its top directory, and adds a directory entry in the parent so it appears as a folder. All of this happens in one transaction, so it's atomic.

### Step 3: Creating a snapshot for almost nothing
This is the key step. Taking a snapshot:
1. reads the source subvolume's root-tree entry
2. copies it into a new entry with a new ID. Both entries now point at the **same root block**.
3. records that the shared blocks now have more users. This isn't done by walking the whole tree; the reference-count updates are deferred and batched at commit.
4. notes the current generation as the source's "last snapshot"

The cost doesn't depend on the subvolume's size. No data is copied.

### Step 4: Diverging through copy-on-write
Until something is written, reads from either side walk the same blocks. The first write to a block in one subvolume copies that block, points its parent at the copy (copying the parent too, up to the root), and updates *that* subvolume's root address. The other subvolume still points at the old blocks. Anything never rewritten stays shared.

### Step 5: Read-only snapshots
A snapshot can be made read-only; writes then fail. Read-only snapshots are required as sources for send/receive, because walking a tree that's being changed would produce an inconsistent stream.

### Step 6: Deleting is the slow part
Deleting a subvolume or snapshot means walking its whole tree, dropping a reference on every data extent and tree block, and freeing those that reach zero. The subvolume disappears from view immediately, but the physical cleanup runs in the background across many transactions, saving its progress so it can resume.

There's a catch: freeing blocks means writing new metadata. A completely full filesystem may not be able to delete a snapshot until some space is freed another way.

### Step 7: Nested subvolumes aren't included
A subvolume can contain other subvolumes. A snapshot stops at those boundaries: nested subvolumes appear as empty directories in the snapshot. Snapshotting a whole hierarchy transactionally could be arbitrarily deep, so tools like snapper snapshot each subvolume separately.

### Step 8: Mounting
Any subvolume can be mounted as the root of a filesystem by name or ID; otherwise the volume's default subvolume is used. They share one superblock but each has its own tree.

## The picture

```text
 root tree:  subvol 256 "@"      → root block R
             snapshot 257 "@snap" → root block R   (same block, refs bumped lazily)

 write in 256:   R ─copy─▶ R'   (and the changed leaf and its ancestors)
             subvol 256 → R'      snapshot 257 → R (unchanged)
             untouched subtrees still shared by both

 delete 257: vanishes at once; background walk drops refs and frees unshared blocks
```

## Tradeoffs

- **What it gives you:** instant, space-free snapshots, independently mountable trees, cheap rollbacks, and the base for incremental replication with send/receive.
- **What it costs / requires:** deleting is as expensive as walking the whole tree; snapshots and subvolumes are the same kind of object, so there's no cheaper snapshot-only deletion path. Deferred reference counting makes creation fast but leaves the extent records settling until commit.
- **Where it bites:** a full disk can't delete its way out of trouble; many snapshots slow down space reclamation and accounting (see qgroups); nested subvolumes silently aren't in the parent's snapshot; hard links can't cross subvolumes.

## How it got here

- **2.6.29 (2009):** subvolumes and snapshots were core features of btrfs from its first merge, in Chris Mason's "snapshots are subvolumes" design.
- **2.6.37:** a newer snapshot interface with proper flags, including read-only.
- **3.6 (2012):** send/receive for replicating snapshots.
- **5.7 (2020):** snapshot-aware defragmentation removed as too complex and prone to surprising slowdowns.
- **2012–2014 and 6.x:** work on reserving space so snapshot deletion can always make progress, plus free-space tree and discard improvements.

## Related

- Technical version: [[subvolumes-and-snapshots]]
- [[btrfs-explained|Btrfs]]: the subsystem overview
- [[multiple-b-trees-explained|Btrfs B-trees]]: subvolumes *are* B-trees in this family
- [[send-receive-protocol-explained|Send/receive]]: replicating read-only snapshots
- [[qgroups-explained|Qgroups]]: accounting shared versus exclusive space
- [[transaction-model]], [[space-accounting-and-block-groups-explained|Space accounting]]
- [[checksumming-and-data-integrity-explained|Checksumming]], [[mount-namespace|Mount namespaces]]
