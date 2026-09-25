---
title: "Dentry Cache (dcache)"
category: concept
tags: [fs, vfs, dcache, dentry, shrinker, scalability]
subsystem: fs
kernel_version: "2.4+"
researched: 2026-04-05
status: complete
explained: "[[dentry-cache-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://lwn.net/Articles/419811/
  - https://lwn.net/Articles/628829/
  - https://lwn.net/Articles/89170/
---

# Dentry Cache (dcache)

> 📘 Plain-language version: [[dentry-cache-explained]]

## Purpose

The dentry cache (dcache) is the kernel-wide infrastructure that stores and manages all live [[Dentry|dentries]] — the in-memory name→inode associations that make pathname lookup fast. Without it, every `open()` or `stat()` would call into the filesystem for each path component; with it, repeated traversal of warm paths costs only a hash table lookup and a handful of cacheline reads. The dcache is elastic: it grows to consume available memory and shrinks under pressure via the kernel's shrinker mechanism.

## Mental Model

Think of the dcache as the kernel's L1 cache for filesystem namespace. The hash table is its tag array (maps name+parent → dentry), the LRU list is its replacement policy, and the shrinker is its eviction mechanism. Just as a CPU cache fills opportunistically and evicts on pressure, the dcache accumulates dentries as paths are resolved and releases them when the memory reclaimer needs the pages back.

## How It Works

### The hash table: dentry_hashtable

At boot, `dcache_init()` in `fs/dcache.c` calls `alloc_large_system_hash("Dentry cache", ...)` to allocate the global `dentry_hashtable` — a power-of-two array of `struct hlist_bl_head` buckets. The size scales with RAM: on a 4 GB system the table holds ~256k buckets; on a 256 GB server it can reach millions. The `dhash_entries=` kernel parameter overrides the automatic sizing.

Each bucket is a bit-locked hash list (`hlist_bl_head`). The bit lock (using the lowest bit of the list pointer) replaces the old per-bucket spinlock, giving fine-grained locking without per-bucket lock allocation. A dentry is hashed by `(parent dentry pointer, name hash)` — computed by `full_name_hash()` or by `d_op->d_hash()` for filesystems that override it. `__d_lookup()` takes the bucket bit-lock during search; `__d_lookup_rcu()` scans the chain under RCU without any lock.

### Per-superblock and per-NUMA LRU lists

Every superblock owns a `struct list_lru s_dentry_lru` — a per-NUMA-node, per-memcg LRU list of unused dentries (those with `d_lockref.count == 0`). When `dput()` drops the last reference on a dentry it calls `dentry_lru_add()` to enqueue it. When a dentry is referenced again (`dget()`), `dentry_lru_del()` removes it. This per-superblock design means that unmounting a filesystem (`shrink_dcache_for_umount()`) can drain *only* that filesystem's dentries without touching others — an important correctness property.

The `list_lru` structure is NUMA-aware: insertions are directed to the local node's sub-list, and the shrinker walks each node's list independently to avoid cross-node cacheline traffic. As of 3.12, `list_lru` is also memcg-aware: dentries are tagged with their memory cgroup at allocation time and sorted into per-memcg sub-lists automatically, enabling per-cgroup dcache reclaim without any dentry-specific code.

### The dcache shrinker

`dcache_shrinker` is registered with the kernel's shrinker framework at boot. It implements two callbacks:

- **`count_objects()`** — returns the total number of reclaimable (LRU-queued) dentries for the target superblock (or all superblocks if invoked globally), weighted by `vm.vfs_cache_pressure`.
- **`scan_objects()`** — calls `prune_dcache_sb(sb, sc)`, which dequeues entries from the LRU in batches, takes each dentry's `d_lock`, and calls `__dentry_kill()` on those still unreferenced. `__dentry_kill()` removes the dentry from its parent's `d_subdirs` list, removes it from the hash table, calls `d_op->d_release()`, drops the inode reference (`iput()`), and frees the dentry back to the `dentry` slab cache.

The shrinker is `SHRINKER_MEMCG_AWARE`: under per-cgroup memory pressure, `shrink_control->memcg` identifies which cgroup's dentries to target, and `prune_dcache_sb` walks only that cgroup's `list_lru` sub-list. This is what makes containers with tight memory limits work correctly — their filesystem caches can be reclaimed without touching other cgroups.

`vm.vfs_cache_pressure` (default 100) scales the shrinker's aggressiveness relative to page cache reclaim. A value above 100 causes the shrinker to reclaim dentries more eagerly; below 100, it prefers to keep the dcache warm at the expense of page cache.

### The dentry slab cache

All dentry allocations go through a single SLAB/SLUB cache named `dentry` (called `dentry_cache` in older kernels). It is created in `dcache_init()` with `SLAB_RECLAIM_ACCOUNT` set, which registers it with the slab allocator's accounting so that its memory appears in `/proc/meminfo` under `Slab` and `SReclaimable`. The slab cache also participates in the shrinker pathway: `kmem_cache_shrink()` compacts partially-filled slabs after `prune_dcache_sb()` has freed objects.

Because most dentries have short names (≤ `DNAME_INLINE_LEN` bytes), the name is stored inline in the dentry struct itself — no second allocation. The slab object size is therefore fixed and known at compile time, making the allocator very efficient.

### Locking evolution: from global lock to RCU

**Original (2.4)**: A single global `dcache_lock` spinlock protected all hash table operations, all LRU modifications, and all per-dentry field updates. On a 2-core Pentium III this was acceptable; on a 32-core Nehalem it serialised every pathname lookup in the system.

**2.6 decomposition**: The global lock was split into:
- `d_lock` (per-dentry spinlock) — protects `d_flags`, `d_name`, `d_inode`, and the `d_lockref` count.
- Per-bucket bit locks on `hlist_bl_head` — protect hash chain traversal during insert/remove.
- `rename_lock` (seqlock) — detects concurrent renames during hash chain scans; callers retry on seqcount mismatch rather than blocking.
- `dcache_lru_lock` (later folded into per-superblock `list_lru` locks).

**RCU-walk (2.6.38)**: Nick Piggin's dcache scalability series eliminated refcount bumps on intermediate path components entirely. The core insight was that dentry structures are freed via RCU (`call_rcu()`), so any dentry pointer that was valid at the start of an `rcu_read_lock()` section remains valid (its memory is not reused) for the duration of that section, even if the dentry is logically deleted. Lookup code can therefore read `d_inode`, `d_parent`, and `d_name` without a lock, then validate with `read_seqcount_retry(&d->d_seq)`. If the seqcount changed (rename, eviction), restart. The result: zero cacheline writes on the hot lookup path for cached paths.

**lockref (3.3)**: The `d_lockref` field fuses the `d_lock` spinlock and the reference count into a single 64-bit word. On architectures with a 64-bit cmpxchg, `lockref_get()` atomically increments the refcount without acquiring the spinlock at all, provided the spinlock is not already held. This gives the common `dget()` case lock-free semantics.

### Monitoring

| Source | Metric |
|--------|--------|
| `/proc/meminfo` | `Slab`, `SReclaimable` — includes dcache slab |
| `/proc/slabinfo` | `dentry` line: active objects, total objects, slab size |
| `/proc/sys/fs/dentry-state` | `nr_dentry`, `nr_unused`, `age_limit`, `want_pages`, `nr_negative` (6.6+) |
| `slabtop` | real-time slab usage, dentry usually near top |
| `perf stat` | `cache-misses` on `d_lookup` path under lookup-heavy workloads |

## Key Data Structures

**`dentry_hashtable`** (`fs/dcache.c`) — global `struct hlist_bl_head[]`; sized at boot; each bucket is a bit-locked hlist of dentries with the same `(parent, name)` hash.

**`struct list_lru`** (`include/linux/list_lru.h`) — per-NUMA-node, per-memcg LRU list; embedded in each `struct super_block` as `s_dentry_lru`; provides `list_lru_add()`, `list_lru_del()`, `list_lru_walk()`.

**`dcache_shrinker`** (`fs/dcache.c`) — `struct shrinker` registered with `SHRINKER_MEMCG_AWARE`; callbacks call `prune_dcache_sb()`.

**`dentry` slab cache** — SLUB cache for `struct dentry`; `SLAB_RECLAIM_ACCOUNT | SLAB_PANIC`; inline name storage for short names.

## Key Functions / Entry Points

**`dcache_init()`** (`fs/dcache.c`) — called from `vfs_caches_init()` at boot; allocates the hash table, creates the slab cache, registers the shrinker.

**`d_lookup(parent, name)`** (`fs/dcache.c`) — REF-walk hash lookup; returns dentry with refcount bumped or NULL.

**`__d_lookup_rcu(parent, name, seqp)`** (`fs/dcache.c`) — RCU-walk variant; no refcount or lock; returns dentry + seqcount for caller to validate.

**`prune_dcache_sb(sb, sc)`** (`fs/dcache.c`) — shrinker scan callback; dequeues up to `sc->nr_to_scan` dentries from `sb->s_dentry_lru` and kills them.

**`shrink_dcache_sb(sb)`** (`fs/dcache.c`) — unconditionally drains all unreferenced dentries from a superblock; called during unmount.

**`d_alloc(parent, name)`** / **`d_alloc_anon(sb)`** (`fs/dcache.c`) — allocate a dentry from slab; `d_alloc_anon` for disconnected dentries (e.g. NFS file handles).

**`__dentry_kill(dentry)`** (`fs/dcache.c`) — final teardown: unhash, remove from parent, call `d_release`, drop inode reference, free to slab.

## Important Flags & Config Options

| Knob | Effect |
|------|--------|
| `vm.vfs_cache_pressure` | sysctl; default 100; scale factor for dcache reclaim vs page cache reclaim |
| `dhash_entries=N` | kernel cmdline; override automatic dentry_hashtable size |
| `vm.drop_caches=2` | drop all unused dentries and inodes immediately (test/debug tool) |
| `SHRINKER_MEMCG_AWARE` | flag on dcache_shrinker; enables per-cgroup targeted reclaim |
| `/proc/sys/fs/dentry-state` | read-only; `nr_dentry nr_unused age_limit want_pages nr_negative dummy` |

## Interactions with Other Subsystems

- **→ [[Dentry]]**: the dcache is the system-level manager of all `struct dentry` objects; individual dentries are unaware of the cache infrastructure beyond their `d_lru` and `d_hash` list links.
- **← [[Page Reclaim]]**: `shrink_slab()` invokes `dcache_shrinker` under global memory pressure; `vm.vfs_cache_pressure` governs relative priority.
- **← [[Memory Cgroups (memcg)]]**: per-cgroup memory limits trigger per-cgroup `dcache_shrinker` invocations via `shrink_control->memcg`; `list_lru` tracks which dentries belong to each cgroup.
- **→ [[VFS]]**: `vfs_caches_init()` calls `dcache_init()` as part of VFS bootstrap; every VFS operation that does pathname resolution uses `d_lookup` or `__d_lookup_rcu`.
- **→ [[Inode Cache]]**: dentry eviction always triggers `iput()` on the associated inode; if that drops the last inode reference, the inode goes onto the inode LRU and may be evicted too, making dcache and icache reclaim coupled.
- **→ Superblock**: each superblock contributes its own `s_dentry_lru` to the global shrinker; `shrink_dcache_for_umount()` fully drains one superblock's LRU without affecting others.

## Design Decisions & Tradeoffs

**Global hash table vs per-superblock hash**: A global table means that any path component from any filesystem competes for the same buckets. Per-superblock tables would reduce cross-filesystem collisions but complicate the lookup path (which filesystem is this component from? — not always known before the lookup). The global table simplifies the hot path at the cost of occasional cross-filesystem collisions.

**Per-superblock LRU, global hash**: The split design (global hash for O(1) lookup, per-superblock LRU for targeted eviction) allows `umount` and `drop_caches` to drain one filesystem without scanning the entire hash table. This was a deliberate design choice after early `umount` implementations had to scan the whole dcache.

**RCU-based freeing**: Dentries are freed via `call_rcu()` rather than `kfree()` immediately. This ensures that any thread in the middle of an RCU-walk that holds a pointer to the dentry can finish safely — the memory is not repurposed until after all current RCU read-side critical sections end. The cost is a slight delay in slab memory return, which is negligible.

**`list_lru` memcg awareness as a transparent layer**: Making `list_lru` memcg-aware at the infrastructure level (rather than in dcache code) means dcache gets per-cgroup shrinker support for free, without any dentry-specific accounting. The same design benefits icache and any future in-kernel caches that use `list_lru`.

## How It Has Evolved

- **2.4**: Global `dcache_lock` spinlock; single global LRU list; no NUMA awareness.
- **2.6.0**: Per-dentry `d_lock`; `rename_lock` seqlock for hash traversal; LRU moved to per-CPU batched structures.
- **2.6.38** (2011): RCU-walk; per-bucket bit locks; `d_seq` seqcount per dentry; `dcache_lock` eliminated entirely.
- **3.3** (2013): `lockref` fused spinlock+refcount; cmpxchg fast path for `dget()`.
- **3.12** (2013): `list_lru` made per-NUMA-node; dcache LRU migrated to `list_lru`.
- **3.16** (2014): `list_lru` made per-memcg; `dcache_shrinker` marked `SHRINKER_MEMCG_AWARE`; per-cgroup dcache reclaim becomes possible.
- **5.9** (2020): Shrinker bitmap optimisation (`shrinker_maps`) avoids calling shrinkers with empty LRUs.
- **6.6** (2023): `/proc/sys/fs/dentry-state` gains `nr_negative` field for monitoring negative dentry accumulation.

## Further Reading

1. [Dcache scalability and RCU-walk — LWN.net](https://lwn.net/Articles/419811/)
2. [Per-memcg slab shrinkers — LWN.net](https://lwn.net/Articles/628829/)
3. [Overview of the Linux VFS — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/vfs.html)
4. [Scaling dcache with RCU — Linux Journal / ACM](https://dl.acm.org/doi/fullHtml/10.5555/959336.959339)

## LKML Highlights

- **RCU-walk dcache series** — Nick Piggin (2010–2011): The full series ran to ~30 patches and replaced the global `dcache_lock` with RCU-walk plus per-dentry seqlocks; the performance data on 48-core systems showing near-linear scaling with core count was what ultimately convinced Linus to merge it.
- **list_lru per-memcg** — `20140404185252.GA14925@redhat.com` (Glauber Costa / Vladimir Davydov, 2014): Making `list_lru` memcg-aware; the debate was whether the per-memcg overhead (extra list heads per cgroup) was worth it for containers — the answer was clearly yes given the container use case.
- **shrinker_maps optimisation** — `20200211165334.GA17569@linux.vnet.ibm.com` (Yang Shi, 2020): Bitmap to skip shrinkers with empty LRUs; motivated by profiling showing that on systems with thousands of cgroups, iterating all shrinkers even when most had nothing to reclaim was a significant overhead.
