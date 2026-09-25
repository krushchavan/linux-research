---
title: "Inode Cache (icache)"
category: concept
tags: [fs, vfs, inode, icache, shrinker, scalability]
subsystem: fs
kernel_version: "2.4+"
researched: 2026-04-05
status: complete
explained: "[[inode-cache-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://lwn.net/Articles/407560/
  - https://lwn.net/Articles/801851/
  - https://lwn.net/Articles/628829/
  - https://docs.huihoo.com/linux/kernel/2.6.26/filesystems/re35.html
---

# Inode Cache (icache)

> 📘 Plain-language version: [[inode-cache-explained]]

## Purpose

The inode cache (icache) keeps `struct inode` objects in memory so that repeated access to a file's metadata — ownership, permissions, size, block map — does not require reading the on-disk inode every time. Without it, every `stat()`, `open()`, or directory traversal would issue synchronous disk I/O for metadata that is frequently re-used. Like the [[Dentry Cache]], the icache is elastic: it grows as inodes are accessed and shrinks under memory pressure via the kernel shrinker.

## Mental Model

The inode cache is the kernel's metadata RAM. The hash table is the index: given a superblock pointer and inode number, it gives you the live `struct inode` in O(1). The LRU is the eviction queue: inodes whose reference count has dropped to zero wait here until either memory pressure evicts them or they are referenced again. The shrinker is the garbage collector: it drains the LRU when RAM is needed.

## How It Works

### inode_hashtable: the lookup index

At boot, `inode_init()` in `fs/inode.c` calls `alloc_large_system_hash("Inode-cache", ...)` to allocate the global `inode_hashtable` — a power-of-two array of `struct hlist_head` buckets, sized proportionally to RAM. Each bucket is protected by its own spinlock (`inode_hash_lock[]` per bucket, introduced in the 2.6.37 scalability series). Inodes are hashed by `(sb, i_ino)` — the tuple uniquely identifies an inode within one mounted filesystem.

`find_inode()` (called internally by `iget_locked()` and `iget5_locked()`) locks the target bucket, scans the hlist for a matching `(sb, i_ino)`, and returns it with `i_count` bumped if found. For filesystems where inode number alone is not unique (e.g. NFS with 64-bit filehandles), `iget5_locked()` accepts a caller-supplied `test()` callback that performs additional comparison; the `set()` callback initialises filesystem-private fields on a newly allocated inode before it is inserted.

### Inode states and the I_NEW protocol

Every inode carries a `i_state` bitmask (protected by `inode->i_lock`) that tracks its position in the lifecycle:

| Flag | Meaning |
|------|---------|
| `I_NEW` | Just allocated; filesystem is reading it from disk; waiters block on `inode_wait_for_cleanups()` |
| `I_DIRTY_SYNC` | i_mtime or i_ctime changed; must be written before next fsync |
| `I_DIRTY_DATASYNC` | Data bearing metadata changed (i_size, block map); must reach disk before data |
| `I_DIRTY_TIME` | Timestamp-only dirtiness (lazytime mode) |
| `I_SYNC` | Currently being written back by the writeback thread |
| `I_REFERENCED` | Touched recently; second-chance LRU protection |
| `I_FREEING` | Eviction in progress; `iget*` will skip this inode |
| `I_CLEAR` | Filesystem cleanup (`evict_inode`) complete; memory may be freed |
| `I_WILL_FREE` | `iput()` decided to evict but has not yet set `I_FREEING` |

When `iget_locked()` allocates a new inode (cache miss), it sets `I_NEW`, inserts the inode into the hash table, and returns it locked. The filesystem reads the on-disk inode and populates the struct. Only then does `unlock_new_inode()` clear `I_NEW` and wake any threads that called `wait_on_new_inode()` — preventing two threads from reading the same inode from disk simultaneously and racing on initialisation.

### Reference counting and the LRU

Every inode has a reference count `i_count` (atomic). As long as `i_count > 0`, the inode is **active**: it is in the hash table, *not* on the LRU, and cannot be evicted. References are held by:
- Open file descriptions (via `dentry → inode` pointer)
- Active dentries (`d_inode` reference)
- In-progress path lookups
- `igrab()` callers

When `iput()` drops the last reference (`i_count` → 0), the action depends on `i_nlink`:
- **`i_nlink > 0`** (normal file): the inode may still be needed (another process could open it). `iput()` adds it to the superblock's LRU list (`sb->s_inode_lru` via `list_lru`) and marks it `I_REFERENCED`. It stays in the hash table so that a future `iget*` can find it cheaply.
- **`i_nlink == 0`** (unlinked file): the inode must be evicted immediately. `iput()` calls `iput_final()` which sets `I_FREEING`, removes the inode from the hash, calls `evict_inode()`, and eventually `destroy_inode()`.

### The LRU and shrinker: icache_shrinker

The per-superblock `s_inode_lru` (a `struct list_lru`, NUMA-aware and memcg-aware since 3.12/3.16) holds all inodes with `i_count == 0` and `i_nlink > 0`. The `icache_shrinker` is registered globally; under memory pressure `shrink_slab()` invokes it.

`prune_icache_sb(sb, sc)` dequeues inodes from the LRU tail, takes each inode's `i_lock`, verifies it is still unreferenced (`i_count == 0`) and not dirty, and calls `evict()`:

1. Sets `I_FREEING` on `i_state`.
2. Removes from hash table (`__remove_inode_hash()`).
3. Removes from superblock's `sb->s_inodes` list.
4. Calls `sb->s_op->evict_inode(inode)` — the filesystem truncates the inode's page cache (`truncate_inode_pages_final()`), releases any private metadata, and performs any last writes.
5. Sets `I_CLEAR`.
6. Calls `destroy_inode()` → `sb->s_op->destroy_inode(inode)` (if provided) → `free_inode_nonrcu()` or `call_rcu(&inode->i_rcu, i_callback)`.

RCU-deferred freeing (`call_rcu`) is used when the filesystem may have RCU readers that hold a pointer to the inode struct (e.g. for lockless dentry-inode pointer reads); it ensures the memory is not reused until all existing RCU read sections complete.

Dirty inodes on the LRU are skipped: `prune_icache_sb` will not evict them directly; instead it falls back and the writeback subsystem must flush them first. This is the source of the historic "inode reclaim stall" problem: under heavy XFS workloads with millions of cached inodes, the shrinker could exhaust clean inodes in seconds and then stall because dirty ones couldn't be freed without I/O. The non-blocking reclaim work (5.4) added feedback signals so kswapd backs off and gives writeback time to clean inodes rather than spinning.

### Inode slab cache

All inode allocations go through per-filesystem slab caches. The VFS calls `new_inode_pseudo(sb)` or `new_inode(sb)`, which call `alloc_inode(sb)`. If `sb->s_op->alloc_inode` is defined (almost all modern filesystems), the filesystem allocates a container struct embedding `struct inode` — e.g. `struct ext4_inode_info` — from its own slab cache (e.g. `ext4_inode_cachep`). This allows the filesystem to initialise private fields and avoids a second allocation. Generic pseudo-filesystems that don't define `alloc_inode` get a plain `struct inode` from the global `inode_cache` slab.

All filesystem inode slabs are created with `SLAB_RECLAIM_ACCOUNT`, so their memory appears under `SReclaimable` in `/proc/meminfo`.

### Locking evolution

**Original (2.4–2.6.36)**: A single global `inode_lock` spinlock protected the hash table, the LRU list, `i_state`, and `i_count`. On a 4-core system this was fine; on 32+ cores it became the dominant contention point for parallel `open()`/`stat()` workloads.

**2.6.37 scalability series**: `inode_lock` was replaced by:
- Per-bucket spinlocks for the hash table (eliminating hash contention).
- Per-inode `i_lock` spinlock for `i_state` and `i_count`.
- Per-CPU counters for `nr_inodes` and `nr_unused` (eliminating stat-update cacheline bouncing).
- Lazy LRU updates — LRU operations are deferred to batch points rather than executed inline on every reference drop.

The result was "lock traffic and contention down by an order of magnitude on an 8-way box" for parallel create/unlink workloads.

## Key Data Structures

**`inode_hashtable`** (`fs/inode.c`) — global `struct hlist_head[]`; keyed by `(sb, i_ino % hash_size)`; per-bucket spinlocks since 2.6.37.

**`sb->s_inode_lru`** (`struct list_lru`) — per-NUMA-node, per-memcg LRU of unused inodes for one superblock; same `list_lru` infrastructure as the dcache.

**`sb->s_inodes`** (`struct list_head`) — full list of all inodes belonging to a superblock; used by `evict_inodes()` during unmount to catch any remaining inodes.

**Per-filesystem slab caches** (e.g. `ext4_inode_cachep`) — embed `struct inode` plus filesystem-private fields in one allocation; all flagged `SLAB_RECLAIM_ACCOUNT`.

## Key Functions / Entry Points

**`iget_locked(sb, ino)`** (`fs/inode.c`) — standard inode lookup-or-allocate; returns cached inode (not `I_NEW`) or fresh inode (`I_NEW` set, caller must fill and call `unlock_new_inode()`).

**`iget5_locked(sb, hashval, test, set, data)`** (`fs/inode.c`) — generalised form with custom comparison and init callbacks; used by NFS, CIFS, and other filesystems with composite inode identities.

**`iput(inode)`** (`fs/inode.c`) — drop reference; if last ref and `i_nlink > 0`, add to LRU; if last ref and `i_nlink == 0`, evict immediately.

**`igrab(inode)`** (`fs/inode.c`) — conditionally bump refcount only if inode is not already being freed; returns NULL if `I_FREEING` is set.

**`unlock_new_inode(inode)`** (`fs/inode.c`) — clears `I_NEW`, wakes waiters; called by filesystem after filling the inode.

**`evict(inode)`** (`fs/inode.c`) — performs the full eviction sequence: `I_FREEING`, unhash, `evict_inode()`, `I_CLEAR`, `destroy_inode()`.

**`prune_icache_sb(sb, sc)`** (`fs/inode.c`) — shrinker scan callback; drains LRU entries, skipping dirty/referenced inodes.

**`evict_inodes(sb)`** (`fs/inode.c`) — synchronously evicts all inodes for a superblock; called during unmount.

**`invalidate_inodes(sb, kill_dirty)`** (`fs/inode.c`) — marks all inodes `I_FREEING` and evicts them; called when a filesystem is force-unmounted.

## Important Flags & Config Options

| Knob / Flag | Meaning |
|-------------|---------|
| `vm.vfs_cache_pressure` | sysctl; default 100; scales icache reclaim aggressiveness relative to page cache |
| `I_NEW` | inode allocated but not yet filled; all lookups block until cleared |
| `I_FREEING` | eviction started; `iget*` skips this inode |
| `I_DIRTY_*` | various dirty state bits; prevent LRU eviction until written back |
| `I_SYNC` | writeback in progress |
| `SLAB_RECLAIM_ACCOUNT` | slab flag on inode caches; memory counted as reclaimable in `/proc/meminfo` |
| `ihash_entries=N` | kernel cmdline; override automatic `inode_hashtable` size |

## Interactions with Other Subsystems

- **→ [[Dentry Cache]]**: every positive dentry holds a reference to an inode (`d_inode`); dentry eviction calls `iput()`, potentially triggering inode eviction in a cascade.
- **← [[Page Reclaim]]**: `icache_shrinker` is invoked by `shrink_slab()` under global memory pressure; `vm.vfs_cache_pressure` controls its weight.
- **← [[Memory Cgroups (memcg)]]**: `list_lru` memcg awareness enables per-cgroup inode reclaim; `icache_shrinker` is `SHRINKER_MEMCG_AWARE`.
- **→ [[Address Space]]**: each inode has an embedded `struct address_space` (`i_data`) that owns the inode's page cache; inode eviction calls `truncate_inode_pages_final()` to clear it.
- **→ [[Writeback]]**: dirty inodes (`I_DIRTY_*`) are tracked in the writeback subsystem's `bdi_writeback` structures; they cannot be LRU-evicted until writeback completes.
- **→ [[VFS]]**: `inode_init()` is called from `vfs_caches_init()`; every VFS path that resolves a dentry to an inode uses `iget_locked()` / `iget5_locked()`.

## Design Decisions & Tradeoffs

**Embedding `struct inode` in filesystem structs**: Rather than allocating a generic inode and a separate filesystem-private struct, filesystems embed `struct inode` in a larger container. This avoids a second allocation, improves cache locality (inode and its private data are adjacent), and allows `container_of()` to recover the private struct from any inode pointer. The cost is that each filesystem must define `alloc_inode` and `destroy_inode`, increasing boilerplate.

**Keeping unused inodes in the hash table**: An inode with `i_count == 0` stays hashed rather than being immediately removed. This means a subsequent `iget*` for the same inode is a cache hit — it just bumps `i_count` and removes it from the LRU. Without this, every close-then-reopen of a file would require reading the inode from disk.

**I_NEW serialisation**: The "allocate, set I_NEW, hash, unlock" protocol ensures that two concurrent openers of the same inode never both read it from disk. The first gets the inode locked with `I_NEW`; the second finds it in the hash, sees `I_NEW` set, and waits. Only after the first caller calls `unlock_new_inode()` does the second proceed — reading from the now-populated in-memory struct. This avoids duplicate I/O and struct corruption.

**Non-blocking reclaim tradeoff**: Original icache shrinkers would wait on `i_rwsem` or writeback completion while scanning, which could block the memory reclaim path for seconds. The non-blocking approach (trylock, skip dirty inodes) means the shrinker makes fast forward progress but may leave dirty inodes in the LRU longer. The feedback mechanism (shrinker signals "I need more time") allows kswapd to back off and let writeback drain dirty inodes asynchronously.

## How It Has Evolved

- **2.4**: Global `inode_lock` spinlock; single per-superblock list; no per-CPU anything.
- **2.6.x**: Separate `inode_in_use` and `inode_unused` lists; basic shrinker registered.
- **2.6.37** (2010): Global `inode_lock` decomposed into per-bucket hash locks + per-inode `i_lock`; per-CPU `nr_inodes`/`nr_unused` counters; lazy LRU updates.
- **3.12** (2013): `list_lru` NUMA-awareness; inode LRU moved to `list_lru` per superblock.
- **3.16** (2014): `list_lru` memcg-awareness; `icache_shrinker` marked `SHRINKER_MEMCG_AWARE`.
- **5.4** (2019): Non-blocking inode reclaim; shrinker feedback signals to prevent stalls on dirty XFS inodes.
- **5.9** (2020): Shrinker bitmap optimisation skips shrinkers with empty LRUs.

## Further Reading

1. [Overview of the Linux VFS — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/vfs.html)
2. [Inode cache scalability — LWN.net](https://lwn.net/Articles/407560/)
3. [Non-blocking inode reclaim — LWN.net](https://lwn.net/Articles/801851/)
4. [Per-memcg slab shrinkers — LWN.net](https://lwn.net/Articles/628829/)

## LKML Highlights

- **Inode cache scalability series** — `[PATCH 0/17] fs: Inode cache scalability` (Dave Chinner, 2010): 17-patch series replacing the global `inode_lock`; the review debate centred on whether per-bucket locking was sufficient or whether per-inode locking was needed for writeback and eviction paths.
- **Non-blocking reclaim** — `20190801021009.10801-1-david@fromorbit.com` (Dave Chinner, 2019): The XFS inode stall problem; reviewers pushed for a generic solution rather than XFS-specific hacks, leading to the `list_lru`-based clean-inode detection approach.
- **list_lru per-memcg** — Part of the Glauber Costa / Vladimir Davydov memcg slab shrinker series (2014); same thread as the dcache memcg work; the inode and dentry shrinkers both gained memcg awareness in the same patchset.
