---
title: "Dentry"
category: concept
tags: [fs, vfs, dcache, dentry, pathname-lookup, rcu]
subsystem: fs
kernel_version: "2.4+"
researched: 2026-04-05
status: complete
explained: "[[dentry-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://www.kernel.org/doc/html/v5.0/filesystems/path-lookup.html
  - https://lwn.net/Articles/419811/
  - https://lwn.net/Articles/814535/
  - https://lwn.net/Articles/649115/
  - https://lwn.net/Articles/890025/
---

# Dentry

> 📘 Plain-language version: [[dentry-explained]]

## Purpose

A **dentry** (directory entry) is the kernel's in-memory representation of a single pathname component. It bridges names to inodes: given the string `"lib"` inside the directory `/usr`, the VFS needs a fast way to answer "which inode does `lib` refer to?" without calling into the filesystem every time. Dentries are the answer — an in-memory cache of name→inode associations, never written to disk, that make pathname resolution cheap.

## Mental Model

Imagine pathname resolution as walking a chain of doors. Each dentry is one door: it knows its own name, which room it leads to (the inode), and which corridor it's in (the parent dentry). The dcache is a giant hash table of all open doors; RCU-walk is the ability to sprint through multiple doors without stopping to touch any of them — only pausing at the final destination.

## How It Works

### Struct dentry layout

The dentry is defined in `include/linux/dcache.h`:

```c
struct dentry {
    unsigned int        d_flags;     /* DCACHE_* flags, protected by d_lock */
    seqcount_spinlock_t d_seq;       /* seqlock for RCU-walk validation */
    struct lockref      d_lockref;   /* spinlock + refcount, atomically updated */
    struct qstr         d_name;      /* hash, len, and name string pointer */
    struct inode       *d_inode;     /* associated inode, NULL for negative dentries */
    unsigned char       d_iname[DNAME_INLINE_LEN]; /* inline storage for short names */
    struct dentry      *d_parent;    /* parent directory */
    struct hlist_node   d_hash;      /* hash table entry (parent+name hash) */
    struct list_head    d_child;     /* link in parent->d_subdirs list */
    struct list_head    d_subdirs;   /* head of list of child dentries */
    union {
        struct list_head  d_lru;     /* LRU list (when unused) */
        wait_queue_head_t *d_wait;   /* in-lookup wait queue */
    };
    struct hlist_node   d_alias;     /* link in inode->i_dentry alias list */
    struct dentry_operations *d_op;  /* filesystem dentry ops vtable */
    struct super_block  *d_sb;       /* root of dentry tree */
    unsigned long       d_time;      /* used by d_revalidate (e.g. NFS) */
    void               *d_fsdata;    /* filesystem-private data */
};
```

Short names (≤ `DNAME_INLINE_LEN`, typically 36 bytes) are stored inline in `d_iname`; longer names are heap-allocated and `d_name.name` points to them. This avoids a memory allocation for the overwhelming majority of directory entries.

`d_lockref` packs a spinlock and a reference count into 8 bytes, allowing `lockref_get()` to increment the refcount atomically on architectures that support it without acquiring the spinlock at all — a key optimisation on the hot lookup path.

### The dcache hash table

All dentries are hashed into a global `dentry_hashtable`, keyed by `(parent_dentry_pointer, name_hash)`. The name hash is computed by `full_name_hash()` (or by `d_op->d_hash()` for filesystems that override it, e.g. case-insensitive filesystems). Collision chains are simple hlist_node linked lists protected by the global `d_lock` per chain slot.

When a filesystem's `inode->i_op->lookup()` creates a new dentry, it calls `d_add(dentry, inode)` which chains the dentry into the hash table and associates the inode. From that point forward, any path walk reaching the same parent+name can find the dentry without calling into the filesystem.

### Positive and negative dentries

A dentry whose `d_inode` is non-NULL is **positive** — it caches a real file/directory. A dentry with `d_inode == NULL` is **negative** — it caches the fact that a name does not exist. Negative dentries are created when `lookup()` finds nothing; they make subsequent `stat()` or `open()` calls for the same nonexistent name O(1) rather than O(disk latency). The `DCACHE_NEGATIVE` flag is not a separate bit — `d_inode == NULL` *is* the definition of negative.

Negative dentries can become a memory problem. Because there is no limit to the names that don't exist, workloads that stat-miss many paths (shell `$PATH` resolution, dynamic linker probing, `make` dependency checks — a full kernel build generates ~53 million failed lookups) can accumulate large numbers of negative dentries. The kernel shrinker evicts them under memory pressure, but the debate about per-directory limits has not reached mainline consensus as of 6.x.

### The dentry LRU

Dentries with zero references (no in-progress path walk or open file holds them) are placed on a per-NUMA-node LRU list via `d_lru`. The dentry cache shrinker (`dcache_shrinker`) walks this LRU under memory pressure and calls `d_prune_aliases()` / `__dentry_kill()` on candidates. A dentry is "referenced" (given a longer lease) when it is touched during a lookup; `DCACHE_REFERENCED` is set and cleared when it cycles through the LRU, giving a second-chance clock approximation.

The dentry's `d_op->d_delete()` callback is called when the last reference is dropped before LRU insertion; if it returns true the dentry is immediately killed rather than cached. This is how filesystems opt out of caching (e.g. when state on the server has definitively changed).

### RCU-walk: lockless pathname lookup

The two lookup modes are:

**REF-walk** (traditional): each dentry traversed has its refcount incremented (`dget()`), the child is found, and the parent's refcount is decremented (`dput()`). Safe but generates heavy cacheline traffic on `d_lockref` for every component of every lookup on a busy system.

**RCU-walk** (since 2.6.38): the lookup runs inside `rcu_read_lock()` without touching any refcounts. Instead, after reading each dentry's `d_inode` or `d_parent`, the code validates `d_seq` with `read_seqcount_retry()`. If the sequence number changed (meaning a rename or eviction happened under us), the walk restarts — either retrying RCU or falling back to REF-walk with `LOOKUP_RCU` cleared.

The walk starts RCU, proceeds through all non-terminal path components using `__d_lookup_rcu()`, and at the final component either commits with `unlazy_walk()` (acquires a real reference) or abandons to REF-walk. Because intermediate components never take refcounts, hundreds of concurrent lookups through `/usr/lib/x86_64-linux-gnu/` can proceed without any shared cacheline modification.

The `rename_lock` seqlock (a coarser-grained lock) detects concurrent renames during hash-chain scans in `d_lookup()`. If the seqcount changed during a failed lookup, the scan is retried rather than reporting a miss — preventing false-negative results from mid-rename hash updates.

### The filesystem lookup path

When the VFS needs to resolve a component it doesn't find in the dcache, it calls `lookup_slow()`:

1. `inode_lock_shared(dir)` — takes the directory inode's `i_rwsem` in shared mode.
2. `__d_lookup()` — rechecks the dcache (may have been filled by a racing lookup).
3. If still missing: allocates a new dentry with `d_alloc()`, calls `dir->i_op->lookup(dir, dentry, flags)`.
4. The filesystem either calls `d_add(dentry, inode)` (positive result), leaves `d_inode NULL` (negative result), or returns an error.
5. Releases `i_rwsem`.

`DCACHE_PAR_LOOKUP` enables parallel lookups: multiple threads racing for the same component can share the cost of the single slow-path I/O using an in-dentry wait queue (`d_wait`).

### dentry_operations vtable

Filesystems that need to customise dentry behaviour implement some or all of:

| Callback | RCU-safe? | Purpose |
|----------|-----------|---------|
| `d_revalidate(dentry, flags)` | must handle `LOOKUP_RCU` | confirm cached dentry is still valid (NFS, CIFS) |
| `d_weak_revalidate(dentry, flags)` | yes | lighter check for jumped dentries (/, .., symlinks) |
| `d_hash(dentry, qstr)` | yes | custom hash (case-insensitive filesystems) |
| `d_compare(dentry, len, str, qstr)` | yes | custom name comparison |
| `d_delete(dentry)` | no | true = kill on last put rather than LRU |
| `d_init(dentry)` | — | initialise fs-private state at allocation |
| `d_release(dentry)` | — | free fs-private state before deallocation |
| `d_iput(dentry, inode)` | — | called before inode dissociation |
| `d_dname(dentry, buf, buflen)` | — | generate path on-demand (procfs, sockfs, pipefs) |
| `d_automount(path)` | — | trigger automount on traversal |
| `d_manage(path, rcu_walk)` | must handle rcu | manage traversal across mountpoints |
| `d_real(dentry, type)` | — | return underlying dentry (overlay, union fs) |

Callbacks marked "must handle `LOOKUP_RCU`" must either succeed without taking locks or return `-ECHILD` to force fallback to REF-walk.

## Key Data Structures

**`struct qstr`** (`include/linux/dcache.h`) — stores a name as `(hash, len, name_ptr)`. The hash is precomputed and stored so hash table lookups need not rehash. Inline comparison uses `len` before `memcmp`.

**`struct lockref`** (`include/linux/lockref.h`) — fused spinlock + refcount; `lockref_get()` can be implemented as a single cmpxchg on supporting architectures, making the common "inc refcount if positive" operation lock-free.

**`dentry_hashtable`** (`fs/dcache.c`) — global `struct hlist_bl_head[]` array; size is a power of two set at boot from RAM size; each slot is a bit-locked hlist for per-slot locking.

## Key Functions / Entry Points

**`d_lookup(parent, name)`** (`fs/dcache.c`) — REF-walk hash table search; uses `rename_lock` to detect renames; returns dentry with refcount bumped or NULL.

**`__d_lookup_rcu(parent, name, seqp)`** (`fs/dcache.c`) — RCU-walk hash search; returns dentry + sequence number without taking any lock; caller must validate with `read_seqcount_retry()`.

**`d_alloc(parent, name)`** (`fs/dcache.c`) — allocates and initialises a new dentry; does not insert into hash.

**`d_add(dentry, inode)`** (`fs/dcache.c`) — associates inode and inserts into hash; equivalent to `d_instantiate` + `d_rehash`.

**`d_instantiate(dentry, inode)`** (`fs/dcache.c`) — associates inode with dentry; adds dentry to `inode->i_dentry` alias list.

**`d_drop(dentry)`** (`fs/dcache.c`) — removes dentry from hash table without freeing; makes it invisible to future lookups.

**`dput(dentry)`** (`fs/dcache.c`) — decrements refcount; when it reaches zero, calls `d_delete()` and either LRU-queues or immediately kills the dentry.

**`d_path(path, buf, buflen)`** (`fs/d_path.c`) — reconstructs the full pathname by walking `d_parent` links to the root; used by `/proc/<pid>/maps`, `getcwd()`, audit.

**`d_prune_aliases(inode)`** (`fs/dcache.c`) — removes all dentries in `inode->i_dentry` from the hash; called on inode eviction.

## Important Flags & Config Options

| Flag | Meaning |
|------|---------|
| `DCACHE_OP_HASH` | filesystem provides `d_hash` |
| `DCACHE_OP_COMPARE` | filesystem provides `d_compare` |
| `DCACHE_OP_REVALIDATE` | `d_revalidate` must be called on RCU-walk |
| `DCACHE_REFERENCED` | touched recently; second-chance LRU protection |
| `DCACHE_MOUNTED` | a filesystem is mounted on this dentry |
| `DCACHE_NEED_AUTOMOUNT` | triggers `d_automount()` on traverse |
| `DCACHE_MANAGE_TRANSIT` | triggers `d_manage()` on traverse |
| `DCACHE_DISCONNECTED` | dentry not reachable from its superblock root |
| `DCACHE_PAR_LOOKUP` | parallel in-progress lookup; waiters sleep on `d_wait` |
| `DCACHE_DONTCACHE` | do not cache this dentry; kill immediately on last put |

No Kconfig controls the dcache directly. `sysctl vm.vfs_cache_pressure` (default 100) biases the shrinker toward reclaiming dcache/icache more aggressively (>100) or more conservatively (<100) relative to pagecache.

## Interactions with Other Subsystems

- **↑ Userspace**: every syscall that takes a pathname (`open`, `stat`, `mkdir`, `rename`, …) drives pathname lookup through the dcache.
- **→ [[Dentry Cache]]**: the dcache *is* the collection of all live dentries; `dentry_hashtable` and the per-node LRU lists are the dcache's implementation.
- **→ [[Inode]]**: each positive dentry holds a reference to an inode; `d_inode` is the pointer; `inode->i_dentry` is the reverse alias list for multi-hard-link inodes.
- **→ [[Path Lookup]]**: `link_path_walk()` / `walk_component()` are the consumers of dentry lookup; they drive RCU-walk and REF-walk and call `d_revalidate`.
- **→ [[Mount Namespace]]**: `DCACHE_MOUNTED` dentries trigger `follow_mount()` which traverses the `vfsmount` tree; dentry and mount are kept separate so one dentry can be overmounted multiple times in different namespaces.
- **← [[Page Reclaim]]**: the `dcache_shrinker` is called under memory pressure; it walks the LRU and kills unused dentries, releasing their slab memory.
- **← [[VFS]]**: the VFS core (`fs/namei.c`, `fs/dcache.c`) owns dentry lifecycle; individual filesystems interact only through `lookup()`, `d_add()`, and the `d_op` vtable.

## Design Decisions & Tradeoffs

**Global hash table vs per-directory lists**: A global hash keyed on `(parent, name)` allows any path component to be found in O(1) without first resolving the parent's inode. Per-directory lists would require holding the parent locked during traversal and offer no asymptotic improvement. The cost is a large, cache-unfriendly hash table that can fragment under extreme dentry counts.

**Inline name storage**: Storing short names directly in the dentry struct avoids a kmalloc per entry, saving ~64 bytes of allocation overhead for the ~90% of names shorter than `DNAME_INLINE_LEN`. The tradeoff is a larger dentry struct that may not fit on a single cache line.

**RCU-walk as an optimisation, not a replacement**: REF-walk remains the ground truth; RCU-walk is best-effort. The fallback to REF-walk on any ambiguity means correctness is never compromised. The seqlock approach adds one counter read + barrier per component compared to a lockless pure-RCU scheme, but the simplicity of "restart on conflict" eliminates a large class of subtle race conditions.

**Negative dentry caching**: Caching negative results trades memory for CPU. The alternative — calling into the filesystem on every failed stat — would make commands like `ls` in large `$PATH` environments unacceptably slow. The open question is where to draw the line; current kernels rely on `vm.vfs_cache_pressure` and the shrinker rather than hard caps.

**`lockref` cmpxchg optimisation**: Replacing `spin_lock; refcount++; spin_unlock` with a single 64-bit cmpxchg on the fused lockref means acquiring a dentry reference on a cached, uncontended path is a single atomic instruction. This is measurable: on a 96-core system doing path lookups, the old scheme produced massive `d_lock` contention; lockref eliminated it.

## How It Has Evolved

- **2.4**: Original dcache; global `dcache_lock` spinlock protected all hash operations; per-dentry refcounts; no RCU.
- **2.6.0**: Per-dentry `d_lock` replaced the global lock for most operations; `rename_lock` seqlock added for hash traversal safety.
- **2.6.36** (2010): `lockref` prototype; per-CPU LRU batching.
- **2.6.38** (2011): RCU-walk merged; `__d_lookup_rcu` and `d_seq` seqcount per dentry; major scalability improvement on multi-core.
- **3.3** (2012): `lockref` fused spinlock+refcount; cmpxchg fast path on x86_64.
- **3.11** (2013): Parallel lookup (`DCACHE_PAR_LOOKUP`); multiple threads can share one slow-path lookup result.
- **4.2** (2015): Symlink resolution rewritten; `d_inode` RCU safety hardened.
- **5.x** (ongoing): `DCACHE_DONTCACHE` flag for filesystems that want zero caching; ongoing negative-dentry debates without mainline cap.

## Further Reading

1. [Overview of the Linux VFS — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/vfs.html)
2. [Introduction to pathname lookup — kernel.org](https://www.kernel.org/doc/html/v5.0/filesystems/path-lookup.html)
3. [Dcache scalability and RCU-walk — LWN.net](https://lwn.net/Articles/419811/)
4. [Dentry negativity — LWN.net](https://lwn.net/Articles/814535/)
5. [Negative dentries, 20 years later — LWN.net](https://lwn.net/Articles/890025/)
6. [Pathname lookup in Linux — LWN.net](https://lwn.net/Articles/649115/)

## LKML Highlights

- **RCU-walk merge** — Nick Piggin's dcache scalability series (2010–2011); the thread is one of the most involved in VFS history, running for months; the core debate was whether `d_seq` per dentry was acceptable overhead versus the cacheline savings from eliminating refcount bumps on intermediate components.
- **Negative dentry cap proposal** — `20200312145203.6874-1-longman@redhat.com` (Waiman Long, 2020): The `dentry-dir-max` sysctl RFC; Matthew Wilcox's "blame the sysadmin" objection and the ensuing debate about whether memory cgroups were the right tool shaped the outcome — no hard cap was merged.
- **lockref** — `20130517105545.GA14490@infradead.org` (Linus Torvalds, 2013): Linus proposed the fused lockref after profiling showed `d_lockref` was the dominant contention point in post-RCU-walk lookup profiles; the cmpxchg path was added immediately.
