---
title: "Dentry — Explained"
category: explained
original: "[[dentry]]"
subsystem: fs
tags: [explained, fs, dentry, path-lookup, rcu]
converted: 2026-09-25
---

# Dentries, explained

> Plain-language companion to [[dentry|the technical note]]. Same facts, fewer identifiers.

## The problem

To open `/usr/lib/libc.so`, the kernel has to answer "which file is called `lib` inside `/usr`?", then "which is `libc.so` inside that?". Asking the filesystem every time (possibly reading a directory from disk) would make path-heavy workloads crawl. Even remembering that a name *doesn't* exist matters: shells searching `$PATH`, the dynamic linker probing library directories and `make` checking dependencies all look up huge numbers of missing names (a full kernel build does about 53 million failed lookups).

## The idea in one paragraph

A **dentry** is the in-memory answer to one such question: one path component, linked to its parent directory's dentry and to the inode it names. Dentries are never written to disk; they're pure cache. Think of path resolution as walking through a chain of doors: each dentry is one door, knowing its name, where it leads (the inode) and which corridor it's in (its parent). With RCU-walk, the kernel can sprint through many doors without touching any of them, stopping only at the destination.

## Step by step

### Step 1: What a dentry holds
Its name (with a precomputed hash and length), a pointer to its parent, the inode it names, links to its children, flags, a combined lock and reference count, a sequence counter for lock-free lookups, an optional table of filesystem-specific operations, and room for filesystem-private data. Short names (up to about 36 bytes, roughly 90% of them) are stored inside the dentry itself, saving an allocation.

### Step 2: Positive and negative
If it points to an inode, it's **positive**: it caches a real file. If it doesn't, it's **negative**: it caches the fact that the name doesn't exist, so repeated failed lookups are instant instead of going to disk. Negative dentries can pile up without limit, since there are infinitely many missing names. The shrinker reclaims them under memory pressure, but a hard per-directory cap (proposed in 2020 by Waiman Long) was never merged after debate over whether memory cgroups were the right tool.

### Step 3: Found by (parent, name)
All dentries live in one global hash table keyed by (parent dentry, name hash), so any component can be found without first touching its parent's inode. Filesystems can supply their own hashing and comparison, for example for case-insensitive names.

### Step 4: Missing from the cache: ask the filesystem
On a miss, the kernel takes the directory's lock in shared mode, checks the cache again (another thread may have just filled it), and if it's still missing allocates a dentry and calls the directory's lookup. The filesystem attaches an inode (positive), leaves it empty (negative), or returns an error. If several threads race for the same missing name, they share one slow lookup: the others wait on the in-progress dentry.

### Step 5: Two ways to walk
This is the key design.
- **Ref-walk**, the traditional way, takes a reference on each dentry along the path and drops the previous one. It's safe but, on a busy system, every component of every lookup bounces the reference-count cache line between CPUs.
- **RCU-walk** (2.6.38) takes *no* references. It reads each dentry under RCU and checks its sequence counter afterwards; if the counter changed (a rename or eviction happened), it retries, or falls back to ref-walk. Only at the final component does it take a real reference. Hundreds of concurrent lookups through the same directory then modify no shared memory at all.

A separate global rename sequence counter protects hash-table scans: if a rename happened during a failed search, the search is retried, so a mid-rename update can't produce a false "not found". Filesystem callbacks that can't work without locks during RCU-walk return a code that forces the ref-walk fallback. Ref-walk remains the ground truth; RCU-walk is a best-effort fast path.

### Step 6: A cheap reference
The lock and the reference count are packed into 8 bytes and updated together with one atomic compare-and-swap. Taking a reference on a cached, uncontended dentry is a single atomic instruction, with no lock. Linus Torvalds proposed this in 2013 after profiles showed the dentry lock had become the main contention point after RCU-walk.

### Step 7: Aging and eviction
When the last reference goes, the filesystem may ask for the dentry to be killed immediately (for example if the server's state has definitely changed, or it simply doesn't want caching); otherwise it goes onto an LRU list. A "recently referenced" flag gives it a second chance as the shrinker sweeps. Under memory pressure, unused dentries are removed from the hash and freed.

### Step 8: Filesystem hooks
Filesystems can customise dentries: **revalidate** a cached name (network filesystems like NFS must check it's still true on the server), custom hash and comparison, "don't cache", set up and release private data, generate a name on demand (for pseudo-filesystems), trigger an **automount** when crossed, manage crossing into a mount, or return the real underlying dentry (for overlay filesystems).

### Step 9: Mounts and paths
A dentry with something mounted on it tells the lookup to cross into that mount; dentries and mounts are kept separate so one directory can be mounted over differently in different namespaces. Walking parent links back to the root rebuilds a full path, which is how `getcwd`, `/proc/<pid>/maps` and auditing produce path names.

## The picture

```text
 "/usr/lib/libc.so"

  [ / ] ──▶ [ usr ] ──▶ [ lib ] ──▶ [ libc.so ] ──▶ inode 4711
   RCU      RCU         RCU         final: take a real reference
   (read, check sequence counter, no writes)

  [ lib ] ──▶ [ libfoo.so ] ──▶ (no inode)   ← negative dentry: "doesn't exist"

  hash(parent, name) → bucket → dentry
  changed underneath? → retry, or fall back to ref-walk
```

## Tradeoffs

- **What it gives you:** constant-time name lookups, cached "not found" answers, and lookups that scale across many cores without shared writes.
- **What it costs / requires:** memory for every name seen (including missing ones); a large, cache-unfriendly global hash table; a slightly bigger dentry to hold short names inline.
- **Where it bites:** negative dentries can accumulate enormously with no hard cap. Network filesystems must revalidate cached names, which costs round trips. The retry-on-conflict approach is simple and safe but means some lookups do their work twice.

## How it got here

- **2.4:** the original dentry cache, with one global lock and plain reference counts.
- **2.6.0:** per-dentry locks and the rename sequence counter.
- **2.6.38 (2011):** RCU-walk, from Nick Piggin's long-running scalability series, after debate over the cost of a sequence counter per dentry versus the savings.
- **3.x:** the fused lock-and-count with a compare-and-swap fast path, and parallel lookups sharing one slow-path result.
- **4.2 (2015):** symlink resolution rewritten.
- **5.x:** a "don't cache" flag, and continuing debate on negative dentries.

## Related

- Technical version: [[dentry]]
- [[dentry-cache-explained|Dentry cache]]: how all dentries are stored and reclaimed
- [[core-in-memory-structures-explained|Core VFS objects]]
- [[fs-explained|Filesystem subsystem (VFS)]]
- [[path-lookup]], [[inode]], [[mount-namespace-explained|mount-namespace]]
- [[page-reclaim-explained|Page reclaim]], [[rcu-read-copy-update|RCU]], [[seqlocks-and-memory-barriers|Sequence locks]]
