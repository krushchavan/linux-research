---
title: "Persistent Data Library — Explained"
category: explained
original: "[[persistent-data-library]]"
subsystem: device-mapper
tags: [explained, device-mapper, b-tree, copy-on-write, thin-provisioning]
converted: 2026-09-25
---

# The persistent-data library, explained

> Plain-language companion to [[persistent-data-library|the technical note]]. Same facts, fewer identifiers.

## The problem

Some device-mapper targets need rich metadata on disk. Thin provisioning must remember, for every virtual volume, which physical block holds each virtual block. Snapshots need to know which blocks are shared. A cache needs to track what's cached where.

That metadata must survive a power cut at any instant. A half-written map is worse than useless: it can point a volume's data at another volume's blocks. Before Linux 3.2, each target (snapshot, mirror) invented its own on-disk format and its own crash-safety logic, and each was buggy in its own way.

## The idea in one paragraph

One shared, transactional metadata stack for all targets, built on a simple rule: **never modify a committed block in place**. To change a block you make a copy (a *shadow*) and change the copy. Changes pile up as shadows until a commit writes them all out and then flips the superblock to point at the new state in one atomic write. A crash at any earlier moment leaves the old, consistent state intact. On top of that sit reference-counted space allocation and B-trees, which is everything thin provisioning, dm-cache and dm-era need.

## Step by step

### Step 1: Block manager: a locked cache of metadata blocks
At the bottom is a cache of fixed-size blocks on the metadata device, each with a read/write lock. Readers and writers of the same block never overlap, and two writers never hold one block at once. Most users don't touch this layer directly.

### Step 2: Transaction manager: the copy-on-write rule
You may write a block only if you allocated it fresh in the current transaction, or **shadowed** it: made a new copy to modify, leaving the original untouched. Shadowing drops the original's reference count, and the original is freed at commit if nothing else uses it. If you shadow a block you've already allocated or shadowed in this transaction, you get the same copy back, so nothing is allocated twice.

### Step 3: Commit: the one moment the disk state advances
A commit flushes every written block to storage, *then* atomically updates the metadata superblock to point at the new state. This is the key step. Since the superblock write is the only thing that makes new state "real", a crash anywhere before it leaves the disk at the previous commit. Half-finished shadow blocks are simply abandoned and their space reclaimed by the repair pass on the next open.

### Step 4: Space maps: who owns which block
Two allocators track blocks, and both keep **reference counts** rather than a simple used/free bit:
- **For data devices** (the blocks handed out to thin volumes): a simple flat structure where allocating means finding the next free block.
- **For the metadata device itself:** harder, because it has to track its own blocks inside the space it manages. It uses a B-tree internally, whose blocks are tracked by a simpler helper structure, with updates carefully ordered to stay crash-consistent.

Reference counts are what make snapshots cheap. Taking a snapshot bumps the count on blocks shared by the snapshot and the original. A write to either first shadows the block, and the count drops back to 1 once only one mapping holds it.

### Step 5: B-trees: the key-value store
The main container is a B+ tree with 64-bit keys and fixed-size values. Trees can nest: a value at one level can be the root of another tree.

Thin provisioning uses exactly two levels:
- **Outer tree:** thin volume ID → root of that volume's inner tree
- **Inner tree:** virtual block number → physical block number

Reading virtual block V of volume D means looking up D in the outer tree, then V in D's inner tree.

### Step 6: Every change makes a new root
Inserting, updating or deleting shadows the whole path from the root down to the changed leaf. So each commit produces a new root block. Old roots stay on disk until their reference counts drop to zero. That is how the full mapping stays crash-consistent at every level.

## The picture

```text
 before commit                          after commit
 superblock ──▶ root A                  superblock ──▶ root A'   (atomic flip)
                 │                                     │
            ┌────┴────┐                           ┌────┴────┐
          node B    node C                      node B    node C'  (shadow)
                      │                                     │
                    leaf D ── change ──▶ shadow ──▶       leaf D'  (shadow)

  crash before the flip → disk still says root A: old state, fully consistent
  after the flip        → A, C, D freed when their reference counts reach zero

 layers:  B-trees  ─▶  space maps (ref counts)  ─▶  transaction manager (COW, commit)
                                                   ─▶  block manager (cache + locks)
```

## Tradeoffs

- **What it gives you:** one well-tested crash-safe metadata model shared by thin provisioning, cache and era, so correctness fixes benefit all of them; and snapshot sharing for free through reference counts.
- **What it costs / requires:** every change rewrites a path of blocks up to the root, and the B-tree format is more complex than any single target strictly needs.
- **Where it bites:** changes are only durable at a commit. Anything since the last commit is lost in a crash (consistently, but lost), so targets must commit when the filesystem above asks for a flush.

## How it got here

- **Before 3.2:** each target had its own metadata format: snapshots their exception store, mirrors their log, each independently buggy.
- **3.2 (2012):** the persistent-data library arrived alongside thin provisioning.
- **Later:** dm-cache (3.9) and dm-era adopted it instead of writing their own.

## Related

- Technical version: [[persistent-data-library]]
- [[device-mapper-explained|Device mapper]]: the framework
- [[dm-bufio-explained|dm-bufio]]: the simpler, separate metadata cache used by dm-integrity
- [[target-framework]]: thin, cache and era build this stack in their constructors
- [[cow-b-tree-engine|Copy-on-write B-trees in btrfs]]: a similar idea in a filesystem
- [[block-explained|Block layer]]
