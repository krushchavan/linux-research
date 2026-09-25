---
title: "Space Accounting and Block Groups"
category: concept
tags: [btrfs, space-accounting, block-groups, enospc, chunk-allocator, free-space]
subsystem: btrfs
kernel_version: "2.6.29 (initial btrfs merge); major rework 4.2 (ticketed ENOSPC)"
researched: 2026-04-11
status: complete
explained: "[[space-accounting-and-block-groups-explained]]"
sources:
  - https://lwn.net/Articles/348659/
  - https://lwn.net/Articles/918005/
  - https://lwn.net/Articles/660324/
  - https://archive.kernel.org/oldwiki/btrfs.wiki.kernel.org/index.php/Btrfs_design.html
  - https://josefbacik.github.io/kernel/btrfs/2020/09/11/btrfs-update.html
  - https://patchwork.kernel.org/project/linux-btrfs/patch/1458926760-17563-8-git-send-email-jbacik@fb.com/
  - https://btrfs.readthedocs.io/en/latest/dev/dev-btrfs-design.html
  - https://btrfs.readthedocs.io/en/latest/Administration.html
---

# Space Accounting and Block Groups

> 📘 Plain-language version: [[space-accounting-and-block-groups-explained]]

## Purpose

Btrfs must answer two distinct questions at all times: *where on disk is free space?* and *will the current operation fit without running out of space mid-transaction?* These are harder than they look. Btrfs's copy-on-write semantics mean that a write never overwrites the original block, so both the old and new versions exist simultaneously until the transaction commits. A single write can cascade into dozens of B-tree node updates. Without careful accounting, the filesystem can reach a state where there is apparently free space on disk but no way to complete the next transaction — the dreaded phantom ENOSPC.

Block groups are the primary unit that organises both on-disk layout and in-memory accounting. Every byte of disk space belongs to exactly one block group, and every allocation decision starts by selecting an appropriate block group.

## Mental Model

Think of the disk as partitioned into fixed-size regions called **block groups** (~256 MiB for metadata, ~1 GiB for data). Each block group is either a data group, a metadata group, or a system group, and carries a RAID profile (SINGLE, DUP, RAID1, RAID5, etc.). A **chunk** is the on-disk backing store for a block group — when btrfs needs a new block group it carves a chunk out of the raw device space first, then creates a block group pointing into that chunk.

Free space within each block group is tracked by the **free space cache** (a per-block-group B-tree or bitmap). Aggregate space totals across all block groups of the same type roll up into a **space_info** structure. All reservations — for delalloc writes, metadata COW, and the global emergency reserve — are recorded against `space_info` *before* any actual block allocation happens. This separation between reservation and allocation is the key insight: the kernel commits to consuming space eagerly so it can fail early and cleanly rather than midway through a transaction.

## How It Works

### Block Groups: Layout and Lifecycle

When btrfs formats or grows a filesystem it calls `btrfs_alloc_chunk()`, which asks each device's allocator for a contiguous region of raw space. The result is a **device extent** — a `[device, offset, length]` triple written to the device tree. The chunk allocator then creates a **chunk item** in the chunk tree mapping the logical address range to those physical device extents, and finally creates a `btrfs_block_group` in memory and a block group item on disk.

`struct btrfs_block_group` (in `fs/btrfs/block-group.h`) is the central in-memory object:

```c
struct btrfs_block_group {
    struct btrfs_fs_info *fs_info;
    struct btrfs_space_info *space_info; /* parent aggregate */
    u64 start;           /* logical start address */
    u64 length;          /* size of this block group */
    u64 used;            /* bytes allocated within the group */
    u64 bytes_super;     /* bytes reserved for superblock copies */
    u64 reserved;        /* bytes reserved but not yet allocated */
    u64 pinned;          /* bytes pinned by in-flight transactions */
    u64 flags;           /* BTRFS_BLOCK_GROUP_DATA/METADATA/SYSTEM | profile */
    atomic_t reservations; /* concurrent reservation count */
    struct rb_node cache_node; /* position in block_group_cache_tree */
    /* ... free space cache state, zone info for ZNS, etc. */
};
```

Block groups are indexed by logical start address in `fs_info->block_group_cache_tree` (a red-black tree), making range lookups O(log n). A newly created block group starts in `BTRFS_BLOCK_GROUP_FLAG_NEEDS_FREE_SPACE` state — its free space cache must be loaded from disk (or synthesised as "entirely free") before any allocation can proceed.

Block groups are retired when their `used` counter drops to zero. `btrfs_delete_unused_bgs()` (called periodically and at unmount) removes empty block groups, freeing their device extents back to the chunk allocator. This reclamation path is the mirror of `btrfs_alloc_chunk()`.

#### Allocation Profiles

Each block group carries flags encoding its **profile**: `BTRFS_BLOCK_GROUP_SINGLE`, `DUP`, `RAID0`, `RAID1`, `RAID1C3`, `RAID1C4`, `RAID5`, `RAID6`, or `RAID10`. The profile determines how the chunk allocator stripes or mirrors data across devices. For single-device filesystems, metadata defaults to `DUP` (two copies within the same device), while data defaults to `SINGLE`. On multi-device filesystems, metadata defaults to `RAID1`.

Block groups of different profiles cannot be mixed for the same type (data or metadata) within the same filesystem mount — a mismatch triggers a balance operation to re-encode block groups into the new profile.

#### Size Classes (since 6.1)

The first-fit extent allocator within a block group performs poorly when large extents are freed and small writes start filling their gaps. Kernel 6.1 introduced **size classes** for data block groups: `BTRFS_BLOCK_GROUP_SIZE_CLASS_SMALL`, `MEDIUM`, and `LARGE`. The size class is determined dynamically when loading a block group from disk (no on-disk change) and guides the allocator to prefer block groups whose existing free extents match the incoming write size, reducing fragmentation within individual block groups.

### space_info: Aggregate Accounting

`struct btrfs_space_info` (in `fs/btrfs/space-info.h`) aggregates the state of all block groups sharing the same type (DATA, METADATA, or SYSTEM):

```c
struct btrfs_space_info {
    u64 flags;               /* BTRFS_BLOCK_GROUP_DATA / METADATA / SYSTEM */
    u64 total_bytes;         /* sum of all block group lengths of this type */
    u64 bytes_used;          /* sum of btrfs_block_group.used */
    u64 bytes_pinned;        /* COW'd blocks still referenced by old transactions */
    u64 bytes_reserved;      /* reserved by the chunk allocator (not yet in a BG) */
    u64 bytes_may_use;       /* reserved by callers awaiting actual allocation */
    u64 bytes_readonly;      /* blocks the allocator cannot touch (e.g. super copies) */
    u64 bytes_zone_unusable; /* ZNS: space past the write pointer that cannot be reset */
    /* ticket queues, flush state, lock ... */
    spinlock_t lock;
    struct list_head tickets;          /* FIFO queue of blocked reservations */
    struct list_head priority_tickets; /* high-priority (deadlock-safe) reservations */
};
```

The accounting invariant is:
```
total_bytes >= bytes_used + bytes_pinned + bytes_reserved
              + bytes_may_use + bytes_readonly + bytes_zone_unusable
```

`bytes_may_use` is the key field for pre-reservation. Every time a caller reserves space (for a delalloc write, a metadata COW, etc.) `bytes_may_use` is incremented immediately. When actual block allocation happens later, `bytes_may_use` is decremented and `bytes_used` in the relevant block group is incremented. If the reservation call discovers that `bytes_may_use` would exceed available space, it does *not* proceed — it either flushes dirty data or queues a ticket and blocks.

`/sys/fs/btrfs/<UUID>/allocation/data/` (and `metadata/`, `system/`) exposes these fields live to userspace, making it possible to observe the accounting state without unmounting.

### Free Space Cache: Per-Block-Group Free Space Tracking

Within each block group, the allocator must find a suitable free extent quickly. Two implementations have existed:

**Space cache v1** (legacy): a special inode (`FREE_SPACE_CACHE` inode) per block group whose data pages store a compact in-memory representation of free extents. The in-memory structure is `struct btrfs_free_space_ctl`, which holds a red-black tree of `struct btrfs_free_space` entries. Each entry represents either a contiguous free range or a bitmap for small fragmented regions. The cache is loaded lazily on first allocation from that block group and written back to disk at transaction commit.

**Free Space Tree / space cache v2** (default since btrfs-progs 5.15, kernel ~5.15): instead of per-inode caches, free space information is stored in a dedicated B-tree (`FREE_SPACE_TREE`) in the filesystem itself. This is transactional (updates to free space are part of the same commit as the extent changes that produced them), crash-consistent without separate cache invalidation, and faster to rebuild after an unclean shutdown. The free space tree uses two key types: `FREE_SPACE_INFO_KEY` (per block group statistics) and `FREE_SPACE_EXTENT_KEY` / `FREE_SPACE_BITMAP_KEY` (individual free ranges or bitmaps).

When the allocator searches for space in a block group, `btrfs_find_space_for_alloc()` queries `btrfs_free_space_ctl` (v1) or the free space tree (v2), selecting the best fitting free extent. The allocator then calls `btrfs_alloc_extent()` which modifies the extent tree to record the new allocation, and updates `btrfs_block_group.used`.

### Space Reservation: The Ticketing System

The reservation path is exercised far more often than actual allocation. Almost every VFS operation that modifies the filesystem must reserve space first. The pattern is:

1. **Calculate worst-case bytes needed**: for metadata, the kernel computes the maximum number of B-tree nodes that could be COW'd by this operation (including all ancestors up to the root). For delalloc data writes, it is the extent size being written.
2. **Call `btrfs_reserve_metadata_bytes()` or `btrfs_reserve_data_bytes()`**: these attempt to increment `space_info→bytes_may_use` by the required amount. If `total_bytes - (bytes_used + bytes_pinned + ... + bytes_may_use) >= needed`, the reservation succeeds immediately — fast path, no lock contention beyond a spin.
3. **Slow path — flush and retry**: if immediate reservation fails, the kernel enters a flush loop controlled by `enum btrfs_flush_state`:

```
FLUSH_DELAYED_ITEMS_NR → FLUSH_DELAYED_ITEMS → FLUSH_DELAYED_REFS_NR
→ FLUSH_DELAYED_REFS → FLUSH_DELALLOC → FLUSH_DELALLOC_WAIT
→ ALLOC_CHUNK → ALLOC_CHUNK_FORCE → RUN_DELAYED_IPUTS
→ COMMIT_TRANS
```

Each state triggers a progressively more aggressive reclamation step: first flushing cheap delayed items (inode updates, directory index entries), then flushing delalloc ranges (forcing dirty pages to disk, making pinned extents reclaimable), then allocating a new chunk (expanding total_bytes), and finally committing the current transaction (unpinning all extents freed in prior transactions).

4. **Ticketing — FIFO fairness**: if all flush states are exhausted and space is still unavailable, the thread enqueues a `struct reserve_ticket` on `space_info→tickets` (or `priority_tickets` for deadlock-safe operations), then sleeps. An **async flusher workqueue** (`btrfs_async_reclaim_metadata_space`) runs flush states in the background and, as space is freed, iterates the ticket list in order, satisfying each ticket until space runs out again. If the flusher makes two full passes without satisfying a ticket, it wakes all remaining tickets with `-ENOSPC`. This FIFO discipline prevents starvation and ensures reservation latency is predictable under pressure.

**Priority tickets** skip the queue and are used only by operations that must not block (e.g., transaction commit itself), to prevent deadlocks where the commit needs metadata space to finish but the space is stuck waiting for a commit.

### The Global Reserve

A special metadata block group region called the **global reserve** (`fs_info→global_block_rsv`) is kept perpetually pre-reserved. Its purpose is to absorb the metadata cost of a transaction commit even when `bytes_may_use` is otherwise exhausted. The global reserve is typically 512 KB – a few MiB and is never handed out to normal reservations. If a commit cannot proceed even with the global reserve, the filesystem force-aborts (`btrfs_handle_fs_error()`), becoming read-only to prevent corruption.

### Delalloc and the Delayed Ref System

Write calls go through the **delalloc** path: pages are dirtied and `bytes_may_use` is incremented by the write size, but no extent is allocated yet. The actual extent allocation is deferred until writeback (`btrfs_run_delalloc_range()`). At that point `bytes_may_use` is decremented and the block group's `used` counter is incremented.

Similarly, freeing a block does not immediately reduce `bytes_used` — it creates a **delayed ref** in the delayed refs tree. Delayed refs are batched and run during transaction commit or when `bytes_pinned` pressure is high. Until a ref is processed, the freed space is counted in `bytes_pinned` and unavailable for reuse, preventing a new transaction from observing freed space that the old transaction's rollback could still need.

## Key Data Structures

**`struct btrfs_block_group`** (`fs/btrfs/block-group.h`) — one per block group; tracks per-group used/pinned/reserved bytes, profile flags, position in `block_group_cache_tree`, and pointer to its parent `space_info`.

**`struct btrfs_space_info`** (`fs/btrfs/space-info.h`) — one per type (DATA/METADATA/SYSTEM); aggregates all block groups of that type and owns the reservation ticket queues.

**`struct btrfs_free_space_ctl`** (`fs/btrfs/free-space-cache.h`) — per-block-group in-memory free space tracker; holds red-black tree of free extents and bitmaps for fragmented regions. Used by space cache v1; v2 uses the free space tree B-tree directly.

**`struct reserve_ticket`** (`fs/btrfs/space-info.h`) — represents a blocked reservation: `bytes` needed, `error` result, and a `wait_queue_head_t` for sleeping until the ticket is satisfied or rejected.

**`struct btrfs_block_rsv`** (`fs/btrfs/block-rsv.h`) — a named reservation pool (global, transaction, delayed refs, etc.) that pre-claims a chunk of `bytes_may_use` so individual operations can draw from it without re-entering the slow path.

## Key Functions / Entry Points

**`btrfs_reserve_metadata_bytes(fs_info, block_rsv, orig_bytes, flush)`** (`fs/btrfs/space-info.c`) — the metadata reservation entry point; fast path or slow-path flush loop; may queue a ticket and sleep.

**`btrfs_reserve_data_bytes(fs_info, bytes, flush)`** (`fs/btrfs/space-info.c`) — the data reservation entry point; unified ticketing since ~5.10.

**`btrfs_free_reserved_data_space()` / `btrfs_free_reserved_extent()`** — release a reservation back to `bytes_may_use` when an operation is cancelled or after allocation completes.

**`btrfs_alloc_chunk(trans, type)`** (`fs/btrfs/volumes.c`) — allocates a new chunk across devices, creates device extents and a new block group; called from the `ALLOC_CHUNK` flush state.

**`btrfs_delete_unused_bgs(fs_info)`** (`fs/btrfs/block-group.c`) — removes empty block groups, reclaiming their device extents; runs in a kthread.

**`btrfs_find_space_for_alloc(block_group, offset, bytes, empty_size, hint_byte)`** (`fs/btrfs/free-space-cache.c`) — searches the free space cache for a suitable extent within one block group.

**`btrfs_run_delayed_refs(trans, count)`** (`fs/btrfs/extent-tree.c`) — processes queued extent tree modifications (allocations and frees), converting `bytes_pinned` into truly free space.

**`btrfs_async_reclaim_metadata_space()` / `btrfs_async_reclaim_data_space()`** (`fs/btrfs/space-info.c`) — async flusher workqueue handlers; iterate flush states and wake satisfied tickets.

## Important Flags & Config Options

**`BTRFS_BLOCK_GROUP_DATA` / `METADATA` / `SYSTEM`** — type flags in `btrfs_block_group.flags`; determine which `space_info` the block group rolls up into.

**`BTRFS_BLOCK_GROUP_RAID*` / `DUP` / `SINGLE`** — profile flags; control how the chunk allocator stripes/mirrors across devices.

**`space_cache=v2`** mount option (now default) — enables the free space tree; `space_cache=v1` or `nospace_cache` are the alternatives.

**`commit=<seconds>`** mount option — controls how long dirty data can sit before a transaction commit; shorter values reduce `bytes_pinned` buildup but increase commit overhead.

**`btrfs balance`** — userspace tool that rewrites block groups, changing their profile or filling gaps; the kernel side runs through `btrfs_relocate_chunk()`.

**`/sys/fs/btrfs/<UUID>/allocation/{data,metadata,system}/`** — live sysfs view of `space_info` fields (`total_bytes`, `bytes_used`, `bytes_pinned`, `bytes_may_use`, etc.).

## Interactions with Other Subsystems

- **↑ Userspace**: `write()` / `fallocate()` trigger delalloc reservations via `btrfs_check_data_free_space()`; `df` / `statfs()` read `space_info` totals; `btrfs filesystem df` breaks down by type and profile.
- **→ [[Transaction Model]]**: every metadata change happens inside a transaction. The space reservation system ensures a transaction can always commit by holding the global reserve. Committing a transaction unpins extents freed in that transaction, immediately replenishing available space.
- **→ [[Multiple B-Trees]]**: the extent tree is the authoritative record of all allocated extents. Space accounting in `space_info` and `btrfs_block_group` must always be consistent with the extent tree's on-disk state after a commit.
- **→ [[RAID and Multi-device Support]]**: chunk allocation is inherently multi-device — the chunk allocator must find space across N devices simultaneously and honour the stripe/mirror constraints of the chosen profile.
- **→ [[Subvolumes and Snapshots]]**: snapshots increase reference counts on extents rather than copying data, so they do not consume additional `bytes_used` immediately. However they delay freeing space (delayed refs accumulate for all snapshot-shared extents) and can make ENOSPC more surprising if many snapshots exist.
- **← Page cache / writeback**: btrfs writeback (`btrfs_writepages()`) triggers `btrfs_run_delalloc_range()`, which converts delalloc reservations into real allocations and clears `bytes_may_use`.
- **← Balance / relocation**: `btrfs_relocate_chunk()` temporarily over-reserves space while moving a block group's data to a new location, requiring careful interaction with `space_info` limits.

## Design Decisions & Tradeoffs

**Reserve before allocate**: Reserving space (`bytes_may_use`) before actual allocation means operations fail at reservation time, never mid-transaction. The cost is pessimism: worst-case metadata estimates are generous, so `bytes_may_use` can look large even when little space is actively used. This is why `btrfs filesystem df` often shows unexpectedly high "Metadata" used figures.

**Flush state ladder**: the ordered progression through flush states (delayed items → delalloc → new chunk → commit) tries the cheapest reclamation first. This keeps normal operations fast while providing progressively stronger guarantees under pressure. The risk is that some flush states (especially `COMMIT_TRANS`) are expensive and can cause latency spikes.

**Ticketing for fairness**: prior to the ticketing system (~4.2 for metadata, ~5.10 unified), concurrent threads racing to flush could produce "thundering herd" effects and false ENOSPC as multiple flushers competed and one won while others starved. FIFO tickets eliminate this at the cost of slightly higher complexity in the slow path.

**Block group granularity**: 256 MiB metadata / 1 GiB data block groups are large enough to amortise B-tree overhead but small enough to be reclaimed reasonably quickly. On very small filesystems (<50 GiB) metadata block groups default to 256 MiB, which can mean the filesystem runs out of metadata space even when data space is plentiful, particularly when RAID1 is used (each block group consumes 2× the raw device space).

**Free space tree (v2) over per-inode cache (v1)**: the per-inode cache (v1) required a separate invalidation/rebuild step after unclean shutdown and was not transactional with the rest of the filesystem. The free space tree is fully transactional, eliminating that inconsistency window, but it adds write amplification because every extent allocation or free also modifies the free space tree.

## How It Has Evolved

**2009 (2.6.29)**: initial merge. Basic block group model with space cache v1 (per-inode). `space_info` existed but reservation was coarse.

**2009 (2.6.32)**: Josef Bacik's metadata ENOSPC overhaul — introduced per-transaction reservation, worst-case metadata calculation, and `bytes_may_use`. Prevented the "commits fail mid-transaction" class of bugs.

**2012 (3.4)**: async flusher for metadata reservations; delalloc flushing integrated into the reservation slow path.

**2016 (4.2)**: ticketed ENOSPC infrastructure for metadata — FIFO reservation queue, `priority_tickets` for deadlock avoidance, async worker satisfying tickets as space is reclaimed.

**2018 (4.19)**: improved global reserve sizing and accounting; cleaner separation between `block_rsv` types.

**2020 (~5.10)**: unified ticketing extended to data reservations (previously data used a simpler "whoever wins the race" model); Josef Bacik's data reservation rework eliminated early ENOSPC corner cases in write-heavy workloads.

**2021 (5.15)**: Free Space Tree (v2) became the default for new filesystems with btrfs-progs 5.15; kernel-side support had been present since 4.5.

**2022 (6.1)**: data block group size classes introduced to reduce fragmentation in the first-fit allocator for mixed small/large write workloads. Zoned block device support added `bytes_zone_unusable` to `space_info` and sub-space splitting for dedicated block groups.

## Further Reading

1. [Btrfs: proper metadata -ENOSPC handling — LWN.net](https://lwn.net/Articles/348659/) — original Josef Bacik patch description explaining the reservation model.
2. [Ticketed ENOSPC infrastructure — patchwork](https://patchwork.kernel.org/project/linux-btrfs/patch/1458926760-17563-8-git-send-email-jbacik@fb.com/) — design of the FIFO ticket system.
3. [btrfs: data block group size classes — LWN.net](https://lwn.net/Articles/918005/) — motivation and design for size-class-aware allocation.
4. [Rework btrfs qgroup reserved space framework — LWN.net](https://lwn.net/Articles/660324/) — how quota groups interact with the reservation framework.
5. [Josef Bacik's btrfs development update (2020)](https://josefbacik.github.io/kernel/btrfs/2020/09/11/btrfs-update.html) — overview of unified data+metadata ticketing.
6. [btrfs zoned: automatic BG reclaim — LWN.net](https://lwn.net/Articles/852744/) — block group reclaim on zoned devices.
7. [Btrfs design — kernel.org archive](https://archive.kernel.org/oldwiki/btrfs.wiki.kernel.org/index.php/Btrfs_design.html) — original design rationale for extent block groups.

## LKML Highlights

- **Metadata ENOSPC overhaul** (Josef Bacik, 2009): `[PATCH] Btrfs: proper metadata -ENOSPC handling` — the foundational patch introducing `bytes_may_use` and worst-case transaction reservation. The discussion clarified why ENOSPC must be detected *before* a transaction starts rather than inside it, because mid-transaction failures are unrecoverable without aborting the entire commit.
- **Ticketed ENOSPC** (Josef Bacik, 2016, `1458926760-17563-8-git-send-email-jbacik@fb.com`): `[07/14] Btrfs: introduce ticketed enospc infrastructure` — debate centred on whether a FIFO queue was the right fairness model (vs. priority-based) and on the priority_tickets escape hatch for deadlock avoidance.
- **Unified data ticketing** (Josef Bacik, ~2020): extended the metadata ticketing model to data; key discussion was whether data reservations could safely share the same flush-state ladder as metadata or needed separate states to avoid starving metadata operations.
