---
title: "Dentry Cache (dcache) — Explained"
category: explained
original: "[[dentry-cache]]"
subsystem: fs
tags: [explained, fs, dcache, rcu, shrinker]
converted: 2026-09-25
---

# The dentry cache (dcache), explained

> Plain-language companion to [[dentry-cache|the technical note]]. Same facts, fewer identifiers.

## The problem

Every `open` or `stat` of a path like `/usr/lib/libc.so` has to resolve each component: find "usr" in the root, "lib" in "usr", and so on. Asking the filesystem each time would be slow, and it happens constantly for the same popular paths.

A cache of names solves that, but brings its own problems. It has to be fast when hundreds of CPUs are looking things up at once, it must shrink when memory is needed, and in a world of containers it must be possible to reclaim one cgroup's (or one filesystem's) entries without disturbing everyone else's.

## The idea in one paragraph

The dcache is **the kernel's L1 cache for the filesystem namespace**. A big hash table is its tag array, mapping (parent directory, name) to a dentry; per-filesystem LRU lists are its replacement policy; and a memory **shrinker** is its eviction mechanism. It fills up as paths are resolved, grows into available memory, and gives memory back when reclaim asks. Lookups on warm paths take no locks and write nothing, which is what lets it scale.

## Step by step

### Step 1: A global hash table
At boot the kernel allocates one big hash table sized to the machine's RAM (about 256k buckets on a 4 GB system, millions on a 256 GB server; a boot parameter can override it). A dentry is placed by hashing its parent and its name (filesystems can supply their own hashing, for example for case-insensitive names). Each bucket is protected by a single bit inside the bucket's list pointer, giving fine-grained locking with no extra lock objects.

### Step 2: Unused entries go on per-filesystem LRU lists
When the last reference to a dentry is dropped, it isn't freed; it goes onto its filesystem's **LRU list** of unused entries. If it's used again, it comes off. Because each filesystem (superblock) has its own list, unmounting can drain just that filesystem's entries without scanning the whole cache.

These lists are split per NUMA node (so entries stay on local lists and shrinking avoids cross-node traffic) and, since 3.16, per memory cgroup: each dentry is tagged with its cgroup when allocated. That was done once in the generic list code, so the dcache (and inode cache, and any other cache using it) got per-cgroup reclaim for free.

### Step 3: The shrinker gives memory back
The dcache registers a shrinker with two jobs:
- **count:** how many unused dentries could be freed (scaled by a tunable; see step 6)
- **scan:** take a batch off the LRU and kill each one still unused: remove it from its parent and the hash table, let the filesystem release anything attached, drop its reference on the inode, and free it

The shrinker is cgroup-aware. When one container hits its memory limit, only that container's dentries are reclaimed. This is what makes containers with tight limits behave.

### Step 4: Cheap allocation
All dentries come from one slab cache, counted as reclaimable memory. Most names are short enough to be stored inside the dentry itself, so there's no second allocation and the object size is fixed.

### Step 5: From one global lock to lock-free lookups
This is the key scalability story.
- **2.4:** one global lock protected the hash table, the LRU and every dentry field. Fine on two cores; on 32 cores it serialised every path lookup in the system.
- **2.6.0:** split into a per-dentry lock, per-bucket locks, and a global sequence counter for renames (lookups retry if a rename happened during their scan instead of blocking).
- **2.6.38 (2011):** **RCU-walk** (Nick Piggin). Dentries are only ever freed after an RCU grace period, so a pointer seen inside an RCU read section stays valid memory for the rest of that section, even if the dentry is being removed. Lookups read the name, parent and inode with no lock at all, then check a per-dentry sequence counter; if it changed (rename, eviction), they retry. Warm-path lookups write nothing to shared cache lines. Benchmarks on 48-core machines showing near-linear scaling convinced Linus to merge the roughly 30-patch series.
- **later:** a combined lock-and-count, updated with one atomic compare-and-swap, so taking a reference usually doesn't take the lock at all.

### Step 6: Tuning and watching
A tunable (default 100) sets how aggressively dentries and inodes are reclaimed relative to the page cache: above 100 favours dropping names, below 100 keeps them warm. A debug knob drops all unused dentries and inodes at once. Counters show total and unused dentries and, since 6.6, how many are negative (records of names that don't exist), which can pile up.

### Step 7: Coupled with the inode cache
Killing a dentry drops its reference on the inode. If that was the last one, the inode goes onto the inode cache's LRU and may be evicted in turn, so name and inode reclaim move together.

## The picture

```text
 lookup "lib" under /usr:
   hash(parent=/usr, "lib") ──▶ bucket ──▶ dentry "lib" (RCU, no lock)
                                             check sequence counter → ok
 unused dentries:
   filesystem A LRU: [node0: cgroup X | cgroup Y] [node1: ...]
   filesystem B LRU: ...
 memory pressure in cgroup X ──▶ shrinker ──▶ free X's unused dentries only
                                   └─▶ drop inode refs ──▶ inode cache may evict too
```

## Tradeoffs

- **What it gives you:** near-free repeated lookups, lock-free scaling across many cores, targeted reclaim per filesystem and per cgroup, and self-sizing to available memory.
- **What it costs / requires:** memory for every distinct path component seen; delayed return of freed memory because of RCU (negligible). One global hash table means names from all filesystems share buckets, which keeps the hot path simple at the cost of occasional collisions.
- **Where it bites:** under memory pressure, dropped dentries mean lookups go back to the filesystem, causing latency spikes. Negative dentries can accumulate in large numbers. On systems with thousands of cgroups, calling every shrinker even when it had nothing to free became a real overhead until a 2020 bitmap optimisation skipped empty ones.

## How it got here

- **2.4:** one global lock and one global LRU.
- **2.6.0:** per-dentry locks, a rename sequence counter, batched LRU handling.
- **2.6.38 (2011):** RCU-walk and per-bucket bit locks; the global lock eliminated.
- **3.x:** the combined lock-and-count; per-NUMA LRU lists (3.12); per-cgroup LRU and a cgroup-aware shrinker (3.16, Glauber Costa and Vladimir Davydov).
- **5.9 (2020):** skipping shrinkers with empty lists (Yang Shi).
- **6.6 (2023):** a negative-dentry counter.

## Related

- Technical version: [[dentry-cache]]
- [[fs-explained|Filesystem subsystem (VFS)]]: the overview
- [[dentry-explained|dentry]]: the individual entries
- [[core-in-memory-structures-explained|Core VFS objects]]
- [[inode-cache-explained|inode-cache]], [[path-lookup-explained|path-lookup]]
- [[page-reclaim-explained|Page reclaim]], [[memory-cgroup-explained|Memory cgroups]], [[rcu-read-copy-update-explained|RCU]]
