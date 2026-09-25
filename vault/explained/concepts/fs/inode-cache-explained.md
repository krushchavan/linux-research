---
title: "Inode Cache (icache) — Explained"
category: explained
original: "[[inode-cache]]"
subsystem: fs
tags: [explained, fs, icache, inode, shrinker]
converted: 2026-09-25
---

# The inode cache (icache), explained

> Plain-language companion to [[inode-cache|the technical note]]. Same facts, fewer identifiers.

## The problem

Every `stat`, `open` and directory walk needs a file's metadata: owner, permissions, size, where its blocks are. Reading the on-disk inode every time would mean synchronous disk I/O for data that's used again and again.

Caching inodes in memory raises its own questions. Two threads opening the same uncached file mustn't both read it from disk and corrupt the in-memory copy. Unused inodes should stay around for reuse, but be freed when memory is needed, except dirty ones, which must be written first. And the cache must not become a lock bottleneck on many-core machines.

## The idea in one paragraph

The inode cache is **the kernel's RAM for file metadata**. A hash table is its index: given (filesystem, inode number), find the live inode instantly. An LRU list is its waiting room: inodes nobody is using wait there, still findable, until they're either needed again or evicted. A memory shrinker is its garbage collector, draining the waiting room when RAM is short. A simple "being filled in" flag makes sure each inode is read from disk only once.

## Step by step

### Step 1: Look up by (filesystem, number)
At boot the kernel allocates a hash table sized to RAM, with a lock per bucket. An inode is found by hashing its filesystem and inode number. Filesystems where the number alone isn't unique (such as NFS with 64-bit file handles) supply their own comparison and setup callbacks.

### Step 2: The "new" protocol: read each inode once
This is the key correctness step. On a miss, the kernel allocates a fresh inode, marks it **new**, puts it in the hash table, and hands it locked to the filesystem, which reads the on-disk inode and fills it in. Only then is the "new" mark cleared and any waiters woken. A second thread looking for the same inode meanwhile finds it in the hash, sees "new", and waits, then uses the filled-in copy. No duplicate I/O, no half-filled inode.

An inode's state also records whether it's dirty (timestamps only, metadata needed before data, or timestamp-only in lazytime mode), being written back, recently referenced, or on its way to being freed.

### Step 3: Reference counting
While anyone holds a reference (an open file via its name, an active dentry, a lookup in progress), the inode is active: hashed, not on the LRU, not evictable. When the last reference is dropped:
- **the file still has names (links):** it might be opened again, so it goes onto its filesystem's LRU list and stays in the hash table. Reopening it later is a cheap hit.
- **the file has been deleted (no links left):** it's evicted immediately.

### Step 4: Eviction
Under memory pressure the shrinker takes inodes from the LRU, checks each is still unused and not dirty, and evicts it:
1. mark it as being freed (so lookups skip it)
2. remove it from the hash table and the filesystem's list
3. let the filesystem clean up: drop the inode's cached pages, release private metadata, do any last writes
4. mark it clear and free it, delayed until an RCU grace period if lock-free readers might still hold a pointer

### Step 5: Dirty inodes wait for writeback
The shrinker skips dirty inodes; writeback has to clean them first. This caused a historic problem: under heavy XFS workloads with millions of cached inodes, the shrinker could use up all the clean ones in seconds, then stall because the dirty ones needed I/O. Since 5.4, reclaim doesn't block, and it signals back so background reclaim eases off and gives writeback time, instead of spinning.

### Step 6: One allocation per inode
Filesystems allocate a larger structure of their own with the generic inode embedded inside it, from their own slab cache. One allocation instead of two, the private data sits next to the inode in memory, and the filesystem can get from the inode to its private structure by pointer arithmetic. All these caches count as reclaimable memory.

### Step 7: Per-filesystem, per-NUMA, per-cgroup LRUs
Like the dentry cache, each filesystem's inode LRU is split per NUMA node and per memory cgroup, so reclaim can target one container's inodes. Unmounting evicts all of one filesystem's inodes via a full list it keeps.

## The picture

```text
 lookup (fs, ino)
   hash bucket ──▶ found, active? → ref++
                ──▶ found, on LRU? → ref++, take off LRU (cheap reuse)
                ──▶ found, "new"? → wait until filled
                ──▶ missing → allocate, mark new, hash it, filesystem reads disk, clear new

 last ref dropped:   still linked → LRU (still hashed)
                     deleted      → evict now
 memory pressure: shrinker → LRU → skip dirty → evict clean → free (after RCU)
```

## Tradeoffs

- **What it gives you:** metadata without disk I/O for anything recently used, cheap reopening, no duplicate reads, and targeted reclaim per filesystem and cgroup.
- **What it costs / requires:** each filesystem must provide allocate and destroy functions for its embedded structure; memory for cached inodes.
- **Where it bites:** dirty inodes can't be reclaimed until written back, so huge metadata-heavy workloads could stall reclaim (fixed in 5.4 with non-blocking reclaim and feedback). Because dropping a dentry drops its inode reference, dentry and inode reclaim cascade together.

## How it got here

- **2.4:** one global inode lock for everything.
- **2.6.x:** separate in-use and unused lists, and a basic shrinker.
- **2.6.37 (2010):** Dave Chinner's 17-patch series split the global lock into per-bucket and per-inode locks, added per-CPU counters and lazy LRU updates, cutting lock traffic "by an order of magnitude" on an 8-way machine.
- **3.12–3.16 (2013–2014):** NUMA-aware, then cgroup-aware LRU lists (shared work with the dentry cache).
- **5.4 (2019):** non-blocking inode reclaim (Dave Chinner), done generically rather than as an XFS-specific hack.
- **5.9 (2020):** skipping shrinkers with empty lists.

## Related

- Technical version: [[inode-cache]]
- [[inode-explained|inode]]: the object being cached
- [[dentry-cache-explained|Dentry cache]]: its partner; dentries hold inode references
- [[core-in-memory-structures-explained|Core VFS objects]], [[fs-explained|Filesystem subsystem (VFS)]]
- [[address-space-explained|Address space]], [[writeback-infrastructure-explained|writeback-infrastructure]]
- [[page-reclaim-explained|Page reclaim]], [[memory-cgroup-explained|Memory cgroups]]
