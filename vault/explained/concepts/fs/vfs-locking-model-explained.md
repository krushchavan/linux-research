---
title: "VFS Locking Model — Explained"
category: explained
original: "[[vfs-locking-model]]"
subsystem: fs
tags: [explained, fs, locking, rename, rcu-walk]
converted: 2026-09-25
---

# The VFS locking model, explained

> Plain-language companion to [[vfs-locking-model|the technical note]]. Same facts, fewer identifiers.

## The problem

Hundreds of threads can be looking up, creating, deleting and renaming files at the same moment. Without a strict discipline, a rename running alongside a lookup could leave dangling pointers, and two renames could corrupt the directory tree or deadlock each other. At the same time, lookups are by far the most common operation and must not be slowed down by locks meant for rare changes.

Rename is the hardest case: it changes two directories at once, can move whole subtrees, and could create a cycle (a directory inside itself) if done carelessly.

## The idea in one paragraph

Picture a city of filing cabinets (inodes) linked by a labelled index (dentries). Most workers only *read* the index; they get lock-free access and just check afterwards that the rows they read weren't relabelled. Workers who *change* a cabinet's contents take an exclusive lock on that cabinet. Moving a folder between cabinets is hard: you must lock both, always **ancestor first**, so two concurrent moves can't deadlock. And a single per-filesystem **rename binder** keeps the tree's shape frozen while the lock order is worked out.

## Step by step

### Step 1: The six locks
- **Per-inode read/write semaphore:** the main serialiser for directory changes. Exclusive for create, mkdir, unlink, rmdir and rename (and, if a filesystem opts in, for writes to regular files); shared for lookups that add a new entry to the cache.
- **Per-inode spinlock:** protects fields that change while an inode is cached: state, reference count, link count, writeback list membership. Never held while sleeping.
- **Per-dentry spinlock:** packed together with the reference count; protects the entry's flags, parent and name against rename during slow-mode lookups.
- **Per-dentry sequence counter:** bumped whenever the entry's parent, name or inode changes, so lock-free readers can detect it.
- **Global rename sequence counter:** bumped on every rename; a failed hash-table search checks it and retries, so an entry mid-rename isn't mistaken for "doesn't exist".
- **Per-filesystem rename mutex:** taken for any rename between two different directories, freezing other such renames on that filesystem.

### Step 2: Lookups: fast and optimistic
This is the key design. Path lookup first runs in **RCU-walk**: under an RCU read lock, it reads each entry's parent and inode without touching any reference count or lock, taking a snapshot of the sequence counter before and checking it after. If the whole path is cached and nothing changes, the lookup writes nothing to shared memory, so no cache lines bounce between CPUs.

It falls back to **ref-walk** if a component isn't cached, a sequence check fails, a network filesystem needs to revalidate an entry (which might sleep), or anything else can't run safely without locks. The fallback starts over: it takes reference counts on each entry, briefly takes entry spinlocks, uses the rename counter for hash searches, and takes the directory's semaphore in *shared* mode when asking the filesystem to look a name up.

### Step 3: Changing a directory
Create, unlink, mkdir and friends follow one template: lock the **parent** directory exclusively, call the filesystem, unlock. Unlink and rmdir also lock the victim exclusively so nothing is modifying it as it's detached. Filesystems run under these locks and only add their own internal locks (for journals or extent trees).

### Step 4: Rename within one directory
Lock that directory exclusively. If the two files involved also need locking, take them in increasing memory-address order, so two renames involving the same pair can't deadlock.

### Step 5: Rename across directories
1. take the filesystem's **rename mutex**, freezing the tree's shape against other cross-directory renames
2. work out which parent is an ancestor of the other; lock the **ancestor first**. If neither is, use memory-address order as a tie-break
3. lock the second parent
4. if a directory is being moved, lock it too (its `..` entry changes)
5. if an existing target is being replaced, lock that victim
6. call the filesystem's rename
7. release everything in reverse, then the rename mutex

Why no deadlock: every lock has a fixed rank (the rename mutex lowest, then directories ancestor-first, then non-directories by address), and threads only ever take locks in increasing rank. A deadlock would need someone to hold a higher-ranked lock while waiting for a lower one, which never happens. The rename mutex keeps the ranks valid while they're being computed.

### Step 6: The one-parent rule
The whole scheme assumes each directory has exactly one parent entry, which is why hard links to directories are forbidden. In 2013, Dave Jones's Trinity fuzzer hit a deadlock because `/proc` showed several entries for the same directory inode. The locking model was right; `/proc` was fixed to always use fresh inodes.

### Step 7: Truncation versus page loading
When a filesystem truncates a file or punches a hole, pages must not be re-read from disk after the data has been discarded. A per-file **invalidate lock** (formalised in 5.15) handles this: reads and write preparation take it shared, truncate and hole-punch take it exclusively, wait for in-flight page work, then drop the range safely.

### Step 8: What needs no lock
Checking permissions, reading attributes and listing extended attributes don't change the directory structure, so VFS takes no locks for them (filesystems may take internal ones).

## The picture

```text
 LOOKUP (common):  RCU-walk, no locks, check sequence counters
                   └─ problem? → ref-walk: refs + short spinlocks + dir lock (shared)

 CREATE / UNLINK:  [parent dir: exclusive] → filesystem → unlock

 RENAME /a/x → /b/y (different dirs):
   [filesystem rename mutex]
     → lock ancestor dir first, then the other (address order if unrelated)
     → lock moved dir / replaced victim
     → filesystem rename
   release in reverse
```

## Tradeoffs

- **What it gives you:** lookups that scale across cores, parallel changes in different directories, and deadlock-free renames with a proof by lock ranking.
- **What it costs / requires:** an intricate lock table that every filesystem callback must respect (documented per method in the kernel's locking docs); a coarse per-filesystem mutex for cross-directory renames.
- **Where it bites:** creates in a single busy directory still serialise on its exclusive lock, which hurts NFS and distributed filesystems; work on parallel directory creates is ongoing. Anything that breaks the one-parent invariant can deadlock the system.

## How it got here

- **Before 2.6.38:** ref-walk only; hot directories saw heavy contention on multi-core machines.
- **2.6.38 (2011):** RCU-walk (Nick Piggin), adding per-entry and global rename sequence counters, layered on top of the existing locks rather than replacing them.
- **3.11 (2013):** the `/proc` fix after the Trinity deadlock, cementing "no directory hard links".
- **4.7 (2016):** the per-inode mutex became a read/write semaphore (Al Viro), allowing parallel lookups in one directory, with a mechanism so two threads missing the same name don't both create entries.
- **5.15:** the invalidate lock for truncation versus page loading.
- **6.x (ongoing):** proposals for parallel creates in one directory (Neil Brown, Christian Brauner).

## Related

- Technical version: [[vfs-locking-model]]
- [[path-lookup-explained|Path lookup]]: RCU-walk and ref-walk in detail
- [[dentry-explained|Dentries]], [[dentry-cache-explained|Dentry cache]]
- [[page-cache-explained|Page cache]], [[address-space-explained|Address space]]: the invalidate lock
- [[locking-explained|locking]], [[rwsem-reader-writer-semaphore|Read/write semaphores]], [[seqlocks-and-memory-barriers|Sequence locks]]
- [[fs-explained|Filesystem subsystem (VFS)]]
