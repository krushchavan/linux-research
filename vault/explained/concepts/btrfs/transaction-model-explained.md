---
title: "Btrfs Transaction Model — Explained"
category: explained
original: "[[transaction-model]]"
subsystem: btrfs
tags: [explained, btrfs, transactions, copy-on-write, fsync]
converted: 2026-09-25
---

# The btrfs transaction model, explained

> Plain-language companion to [[transaction-model|the technical note]]. Same facts, fewer identifiers.

## The problem

Filesystem operations touch many pieces of metadata at once: a new file updates an inode, a directory, extent records, checksums. If the power fails halfway, the filesystem must not be left with some of those changes applied and others not.

ext4 and XFS solve this with a journal: write what you're about to do to a log, then do it, and replay the log after a crash. Btrfs takes a different route, and it also has to make `fsync` fast, since a full commit of everything is expensive.

## The idea in one paragraph

Think of a transaction as **a staging area**. During it, every metadata change is written to *freshly allocated* blocks; the previous version is never overwritten. At commit, a new superblock is written pointing at the new root of the tree of trees. Once that write lands, the new state is live and the old blocks can be freed. If the machine crashes before then, the old superblock still points at the old, fully consistent state. No write-ahead journal is needed for crash consistency. For quick `fsync`, a small **log tree** records just the one file's changes without committing everything.

## Step by step

### Step 1: A transaction's life
Each transaction has an ID that only ever increases (the "generation" stamped into every tree block) and moves through fixed stages: running (writers can join), preparing to commit (new writers go to the next transaction), committing (waiting for data, then the heavy work), unblocked (the next transaction can take writers while this one finishes), superblock written, and completed.

### Step 2: Join with a handle, and reserve first
No code changes btrfs metadata without first getting a **handle** on the current transaction. Starting one says how many tree changes it might make, and the space for them is **reserved up front**. If the space isn't there, the caller waits or gets "no space" *before* writing anything. Running out of space halfway through a transaction would leave metadata half-written. Some handles join without reserving, for operations that reserved elsewhere.

### Step 3: Changes are copy-on-write
Inside a transaction, every tree change copies the affected block to a new location, updates the parent to point at the copy (copying the parent too, up to the root), and notes a **delayed reference** change: one more user for the new block, one fewer for the old. Updating the extent tree immediately for every copied block would cause cascading churn, so these changes are batched in memory and applied at commit.

### Step 4: Commit
Commits happen on `sync`, every 30 seconds by default, or on request:
1. **wait for file data:** all data writes started in this transaction must finish first, so new metadata never points at data that isn't on disk
2. **create pending snapshots:** snapshot requests made during the transaction happen now
3. **apply delayed references:** update the extent tree for every block allocated or freed. Usually the slowest step.
4. **write all dirty metadata** and wait for it
5. **write the new superblock** (to up to three fixed locations), ordered with barriers so it lands only after all metadata is safe

This is the key step: the superblock write is the point of no return. Before it, the old state stands; after it, the new one does.

6. **clean up:** blocks whose reference count reached zero are handed back as free space

### Step 5: The log tree: fast fsync
A full commit must pause all writers and flush all dirty metadata, which is far too much for one `fsync`. Instead:
1. the file's changed metadata (inode, directory entries, extent records) is copied into a per-subvolume **log tree**
2. its data is written to disk
3. the log tree is flushed, and a small log superblock updated

If the machine crashes before the next full commit, the log is **replayed** at mount into the main trees. After a successful full commit, the log is thrown away. The cost of `fsync` is then proportional to that one file's metadata, not to everything dirty. One wrinkle: if the file's directory was changed concurrently, pending directory updates may have to be committed too, so the log has a consistent directory view.

### Step 6: Abort
If anything fails during commit (an I/O error writing metadata, running out of memory while applying references), the transaction is **aborted**: the handle and the filesystem are marked failed and the filesystem goes read-only. Btrfs has no undo log, so there's no partial rollback; the old committed state on disk is still safe, but recovery means remounting or running the checker.

## The picture

```text
 generation 41 on disk:  superblock ──▶ root tree A ──▶ trees...   (consistent)

 transaction 42:  every change copies blocks to NEW locations
                  delayed ref changes pile up in memory
 commit:  wait for data → snapshots → apply refs → write metadata → barrier
          → write superblock (gen 42) ──▶ root tree A'
          crash before this write? gen 41 still intact

 fsync(file): copy file's metadata to log tree → write data → flush log
              crash → replay log at mount;  next full commit → discard log
```

## Tradeoffs

- **What it gives you:** crash consistency without a journal (the old state is always intact), atomic snapshots, and `fsync` that doesn't stall everyone.
- **What it costs / requires:** write amplification (each change copies a chain of 3–5 blocks up to the root on a large filesystem), delayed references held in memory until commit, and reservations that temporarily hold more space than ends up used.
- **Where it bites:** commits can cause latency spikes, mostly from applying delayed references. Any metadata I/O error makes the filesystem read-only until it's remounted or checked; there's no online recovery.

## How it got here

- **2.6.29 (2009):** btrfs merged with its copy-on-write transaction model.
- **2.6.37 (2011):** the log tree for fast `fsync`, chosen over a traditional journal because it doesn't serialise all writers (Chris Mason); it cut `fsync` latency sharply for workloads writing many small files.
- **3.3 (2012):** per-inode metadata reservations replaced a single global pool that caused priority inversions (Josef Bacik).
- **3.7 (2012):** a tree-modification log (separate from the log tree), for consistent back-reference lookups during balance and scrub.
- **4.x–5.x:** better batching and ordering of delayed references to reduce commit spikes; free space tree and discard work.

## Related

- Technical version: [[transaction-model]]
- [[btrfs-explained|Btrfs]]: the subsystem overview
- [[multiple-b-trees-explained|Btrfs B-trees]]: what gets copied on write
- [[space-accounting-and-block-groups-explained|Space accounting]]: why reservations come first
- [[subvolumes-and-snapshots-explained|Subvolumes and snapshots]]: created during commit
- [[checksumming-and-data-integrity-explained|Checksumming]]: checksums commit with their data
- [[dm-integrity-journal-explained|dm-integrity's journal]]: the journaling approach, for contrast
