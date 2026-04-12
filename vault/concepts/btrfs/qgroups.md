---
title: "Btrfs Quota Groups (Qgroups)"
category: concept
tags: [btrfs, qgroups, quota, space-accounting, snapshots, squota]
subsystem: btrfs
kernel_version: "3.8"
researched: 2026-04-12
status: complete
sources:
  - https://lwn.net/Articles/462401/
  - https://lwn.net/Articles/548316/
  - https://lwn.net/Articles/660324/
  - https://lwn.net/Articles/944371/
  - https://github.com/torvalds/linux/blob/8949b9a114019b03fbd0d03d65b8647cba4feef3/fs/btrfs/qgroup.h
  - https://github.com/torvalds/linux/blob/master/fs/btrfs/qgroup.c
  - https://btrfs.readthedocs.io/en/latest/Qgroups.html
  - https://man7.org/linux/man-pages/man8/btrfs-qgroup.8.html
  - https://blogs.oracle.com/linux/btrfs-qgroup-quota-vs-simple-quota
---

# Btrfs Quota Groups (Qgroups)

## Purpose

Btrfs quota groups exist to answer two questions that are impossible to answer with a simple per-directory byte counter in a snapshot-aware filesystem: "how much space does this subvolume own exclusively?" and "how much space would be freed if I deleted this subvolume?" Without qgroups, the reflink and snapshot machinery that makes btrfs powerful also makes space accounting intractable — a single extent can be referenced by dozens of subvolumes simultaneously, and no individual subvolume can be charged the full extent size without double-counting.

## Mental Model

Think of qgroups as an overlay accounting ledger that sits on top of the extent tree. Every extent in the filesystem has a set of "owners" (the subvolume roots that reference it). The qgroup system tracks, for each quota group, two aggregate numbers:

- **referenced (rfer)**: the total bytes reachable through this qgroup, counting shared extents in full.
- **exclusive (excl)**: bytes that *only* this qgroup references — the space that would actually be freed on deletion.

Groups form a DAG: leaf qgroups at level 0 correspond 1:1 with subvolumes (e.g. `0/256`). Parent qgroups at higher levels (e.g. `1/100`) aggregate multiple children, letting you set a shared capacity limit across a set of related subvolumes. A fresh snapshot shares nearly every extent with its source; excl starts near zero and grows as the two diverge through writes.

## How It Works

### Enabling quotas and the quota tree

Quota tracking is off by default. It is enabled with `btrfs quota enable`, which creates a dedicated **quota tree** in the filesystem. This tree stores four key types:

- `BTRFS_QGROUP_STATUS_KEY` — a single status item recording whether quotas are active and whether a rescan is in progress.
- `BTRFS_QGROUP_INFO_KEY` — one per qgroup; records current `rfer` and `excl` values plus their compressed-bytes variants.
- `BTRFS_QGROUP_LIMIT_KEY` — one per qgroup; records the user-configured `max_rfer` and `max_excl` limits and a `lim_flags` bitmask indicating which limits are active.
- `BTRFS_QGROUP_RELATION_KEY` — one per parent/child relationship in the hierarchy; encodes the DAG edges.

When quotas are enabled on a non-empty filesystem, a **rescan** is automatically started (`btrfs_qgroup_rescan()`). The rescan worker walks the entire extent tree, calls `btrfs_find_all_roots()` for each extent to discover which subvolume roots reference it, and updates the in-memory and on-disk qgroup accounting from scratch. Until the rescan completes, qgroup numbers are not reliable.

### In-memory state: `struct btrfs_qgroup`

Each qgroup is represented at runtime by a `struct btrfs_qgroup` (defined in `fs/btrfs/qgroup.h`):

```c
struct btrfs_qgroup {
    u64 qgroupid;           /* level<<48 | subvol_id */

    /* current accounting */
    u64 rfer;               /* referenced bytes */
    u64 rfer_cmpr;          /* referenced bytes, compressed */
    u64 excl;               /* exclusive bytes */
    u64 excl_cmpr;          /* exclusive bytes, compressed */

    /* user-configured limits */
    u64 lim_flags;
    u64 max_rfer;
    u64 rsv_rfer;
    u64 max_excl;
    u64 rsv_excl;

    /* reservation tracking */
    struct btrfs_qgroup_rsv rsv; /* DATA, META_PERTRANS, META_PREALLOC */

    /* hierarchy */
    struct list_head groups;    /* parent qgroups */
    struct list_head members;   /* child qgroups */
    struct list_head dirty;     /* link onto fs_info->dirty_qgroups */

    struct rb_node node;        /* positioned in fs_info->qgroup_tree */
    struct kobject kobj;        /* sysfs exposure */
};
```

The `qgroupid` encodes the hierarchy level in the top 16 bits and the ID in the lower 48. For level-0 subvolume qgroups the level bits are 0, so `qgroupid == subvolume_id`. A parent group at level 1 with user-assigned ID 100 would have `qgroupid = (1ULL << 48) | 100`.

All active qgroups live in an in-memory red-black tree (`fs_info->qgroup_tree`) keyed by `qgroupid`. When an accounting update is needed, the relevant `btrfs_qgroup` is found, modified in memory, and appended to the `dirty` list for writeback at transaction commit.

### The three phases of qgroup operation

The kernel comments describe qgroup operation as having three distinct phases: **reserve**, **trace**, and **account**.

**Reserve** happens before any write. When a buffered write arrives or metadata is about to be allocated, `btrfs_qgroup_reserve_data()` or `btrfs_qgroup_reserve_meta()` checks the qgroup limits and either grants the reservation or returns `-EDQUOT`. The `btrfs_qgroup_rsv` struct inside `btrfs_qgroup` accumulates these reservations by type: `DATA`, `META_PERTRANS` (metadata for one transaction), and `META_PREALLOC` (metadata reserved ahead of time). This three-way split exists because metadata cannot be precisely predicted before allocation; the system over-reserves metadata per-root and releases the excess at commit time. A critical fix (kernel 3.19, the reserved-space rework) made reservation idempotent — repeated reservations for overlapping byte ranges are deduplicated per-inode via a range-tracking map, preventing the false `-EDQUOT` errors that plagued early kernels where each buffered write re-reserved the full range.

**Trace** runs during the CoW and reference-count machinery. As delayed references are processed — new extents allocated, old extents dropped, backreferences added or removed — `btrfs_qgroup_trace_extent()` records each dirty extent in a red-black tree of `btrfs_qgroup_extent_record` structs. These records accumulate the `bytenr`, `num_bytes`, and the set of roots that held the extent *before* the current transaction (the `old_roots` ulist, captured at the time the delayed ref was first inserted).

**Account** runs at transaction commit time, after all delayed refs have been applied to the extent tree but before the transaction is finalised. `btrfs_qgroup_account_extents()` iterates the dirty-extent records. For each record it calls `btrfs_find_all_roots()` to discover the *new* set of roots referencing the extent (the current state of the extent tree), compares that with the saved `old_roots`, and computes the delta: extents that gained a new root increase that root's `rfer`; extents that became uniquely owned by fewer roots shift `excl`. The result is propagated upward through the qgroup hierarchy: each parent's `rfer` and `excl` are recomputed from its children.

The reason accounting is deferred to commit time (rather than happening inline at write time) is that `btrfs_find_all_roots()` must walk backref chains in the extent tree. This walk requires read locks on internal B-tree nodes and cannot safely occur while write locks are held on the same tree — doing it inline would create deadlock. By deferring to commit time the kernel ensures no conflicting write locks are held.

### Hierarchy propagation

When a parent qgroup P has children C1 and C2, P's accounting is not simply C1.rfer + C2.rfer. Shared extents (referenced by both C1 and C2) would be double-counted in that naive sum. Instead, the kernel re-runs the same backref-walking logic across all roots in the combined set, computing for P:

- `rfer`: all bytes reachable from any subvolume assigned to P (shared extents counted once).
- `excl`: bytes reachable only from subvolumes assigned to P and no other qgroup at the same level.

This means adding a new child to a parent qgroup, or removing one, requires a **qgroup rescan** to recompute the parent's numbers correctly, unless the child's `rfer == excl` (all its data is exclusive), in which case the arithmetic adjustment is trivial and no rescan is needed.

### Enforcement at write time

When a write reservation is attempted and would push a qgroup's `rfer` past `max_rfer`, or `excl` past `max_excl`, `btrfs_qgroup_check_reserved_leak()` returns `-EDQUOT` and the write is rejected. Because the check happens during reservation (before actual allocation) rather than at commit time, limit enforcement is proactive — the user sees the error at the `write()` or `fallocate()` call, not later.

### Squota: simple quotas (kernel 6.7)

Traditional qgroups carry a steep performance cost: `btrfs_find_all_roots()` must walk backref chains for every dirty extent at every transaction commit. In snapshot-heavy workloads (e.g. container environments creating and deleting many snapshots) this backref walking makes commit time grow super-linearly, causing throughput collapses of 25–76% measured in practice.

Simple quotas (squotas, enabled via `btrfs quota enable --simple`) eliminate backref walking entirely by adopting a permanent-ownership model: **every extent is accounted forever to the subvolume that first allocated it**. A new on-disk inline reference type `OWNER_REF` (type 188) is stamped into each extent at allocation time, recording the creating subvolume. This requires an incompatible feature flag (`SIMPLE_QUOTA`) on the filesystem.

The tradeoff is deliberate: squota cannot compute shared vs. exclusive usage. When a subvolume takes a snapshot, the snapshot's blocks are still charged to the original subvolume, not the snapshot. Deleting the original while clones persist produces counterintuitive but predictable accounting — the clone's blocks remain "owned" by the (now-deleted) original, and are reported as zero usage in the clone until they are rewritten. Squota reuses the full qgroup API (hierarchy, limits, `show` output), with the convention that `excl == rfer` always, since the concepts collapse under permanent ownership.

## Key Data Structures

**`struct btrfs_qgroup`** (`fs/btrfs/qgroup.h`) — in-memory representation of one qgroup.
- `rfer`, `excl` — the current accounting values updated at transaction commit.
- `max_rfer`, `max_excl` — the enforcement thresholds; zero means unlimited.
- `rsv` — per-type reservation counters; checked and decremented at commit.
- `groups`, `members` — doubly-linked lists threading the hierarchy DAG.
- `dirty` — links this qgroup onto `fs_info->dirty_qgroups` when its numbers change.

**`struct btrfs_qgroup_extent_record`** (`fs/btrfs/qgroup.h`) — one dirty extent awaiting accounting.
- `bytenr`, `num_bytes` — identifies the extent.
- `old_roots` — a `struct ulist *` of the roots that referenced this extent before the current transaction began; captured at delayed-ref insert time.

**`struct btrfs_qgroup_rsv`** (`fs/btrfs/qgroup.h`) — per-qgroup reservation state.
- `rsv[BTRFS_QGROUP_RSV_NUM]` — array indexed by reservation type; tracks bytes reserved but not yet committed.

**`struct ulist`** (`fs/btrfs/ulist.h`) — a small unsorted list of `u64` values used to represent sets of root IDs. Backed by a slab-allocated linked list; optimised for the small cardinalities typical in backref walks.

## Key Functions / Entry Points

**`btrfs_qgroup_reserve_data()`** (`fs/btrfs/qgroup.c`) — called by the buffered-write path before any allocation; checks limits and records the reservation in the per-inode range map to prevent duplicate reservations.

**`btrfs_qgroup_reserve_meta()`** (`fs/btrfs/qgroup.c`) — called before metadata allocation; reserves space against `META_PERTRANS` or `META_PREALLOC` slots.

**`btrfs_qgroup_trace_extent()`** (`fs/btrfs/qgroup.c`) — called from the delayed-ref processing path to record an extent as dirty; captures the `old_roots` ulist at this point.

**`btrfs_qgroup_account_extents()`** (`fs/btrfs/qgroup.c`) — the accounting heart; called during `btrfs_commit_transaction()` after all delayed refs are processed; iterates dirty extents, calls `btrfs_find_all_roots()`, and updates `rfer`/`excl` on affected qgroups.

**`btrfs_qgroup_rescan()`** (`fs/btrfs/qgroup.c`) — starts the background rescan worker; required after enabling qgroups on a non-empty fs or after hierarchy changes that cannot be computed arithmetically.

**`btrfs_find_all_roots()`** (`fs/btrfs/backref.c`) — walks the extent tree backref chains to build the complete set of subvolume roots referencing a given extent; the expensive call that squota eliminates.

**`btrfs_quota_enable()`** / **`btrfs_quota_disable()`** (`fs/btrfs/qgroup.c`) — create/destroy the quota tree and initialise/tear down the in-memory qgroup structures.

## Important Flags & Config Options

**`BTRFS_QGROUP_STATUS_FLAG_ON`** — set in the on-disk status item when quotas are enabled; checked at mount time.

**`BTRFS_QGROUP_STATUS_FLAG_INCONSISTENT`** — set when the quota tree is known to be stale (after a crash during rescan, or after balance/snapshot operations that dirtied the accounting). Signals that a rescan is needed.

**`BTRFS_QGROUP_LIMIT_MAX_RFER`** / **`BTRFS_QGROUP_LIMIT_MAX_EXCL`** — `lim_flags` bits that indicate whether the corresponding limit field is active.

**`BTRFS_FS_QUOTA_ENABLED`** (per-fs flag in `fs_info->flags`) — the fast-path check; most write paths test this bit before calling any qgroup function, making the overhead near-zero when quotas are disabled.

**`btrfs quota enable --simple`** (userspace) — enables squota mode; sets the `SIMPLE_QUOTA` incompatible feature flag on the superblock. Cannot be mixed with traditional qgroups on the same filesystem.

**sysfs tunable: `drop_subtree_threshold`** (kernel 6.1) — when the number of subvolumes in a subtree being deleted exceeds this threshold, the kernel temporarily skips exact qgroup accounting for speed, marking the quota tree inconsistent and requiring a later rescan. Trades short-term accuracy for faster snapshot deletion in bulk-delete workloads.

## Interactions with Other Subsystems

- **↑ Userspace**: `btrfs quota enable/disable`, `btrfs qgroup create/assign/limit/show`, and `btrfs quota rescan` are the primary interfaces via ioctls (`BTRFS_IOC_QUOTA_CTL`, `BTRFS_IOC_QGROUP_CREATE`, etc.). Write syscalls (`write`, `fallocate`) receive `-EDQUOT` when a limit is exceeded.
- **→ [[transaction-model]]**: All qgroup accounting updates are tied to the transaction lifecycle. Reservations are checked before a transaction's allocations; accounting is finalised at `btrfs_commit_transaction()`. The quota tree is flushed as part of the normal tree-writeback sequence.
- **→ [[multiple-b-trees]]**: The quota tree is a first-class B-tree in the btrfs on-disk format, managed by the same CoW B-tree engine as all other trees. Its root pointer is stored in the superblock.
- **→ [[subvolumes-and-snapshots]]**: Every snapshot creation and deletion triggers qgroup updates. Snapshot creation calls `btrfs_qgroup_inherit()` to propagate quota settings; deletion initiates drop-subtree accounting that can be expensive.
- **← [[space-accounting-and-block-groups]]**: Qgroups operate at the extent-ownership level, above the block-group allocator. Block groups track free/used physical space; qgroups track logical ownership of allocated extents across subvolumes. They are complementary, not overlapping.

## Design Decisions & Tradeoffs

**Deferred accounting at commit time vs. inline accounting**: Updating `rfer`/`excl` inline during extent operations was the obvious design, but `btrfs_find_all_roots()` cannot run while write locks on the extent tree are held. Deferring to commit time — after delayed refs are applied — means the extent tree is in a stable, lock-free-readable state. The cost is that qgroup numbers are only fully accurate after each commit, not after each write.

**Lazy refcounting and the rescan cost**: Btrfs's fundamental design choice is that extent backreferences are recorded lazily (via delayed refs) and resolved on demand. This makes snapshot creation O(1) but makes "how many roots reference this extent?" an expensive query requiring backref-chain traversal. Qgroups pay this cost at every commit. The squota design sidesteps it entirely by eliminating the need for the question — at the cost of losing shared/exclusive distinction.

**Hierarchical qgroups vs. per-subvolume-only**: The hierarchy makes qgroups flexible enough to model container storage pools, where multiple subvolumes share a quota envelope. But it also makes accounting significantly more expensive: updating a parent's numbers requires aggregating all children's extents with deduplication. In practice most users never use hierarchy beyond level 0, and the complexity has been a source of bugs.

**Squota's permanent-ownership model**: Charging extents permanently to the creator is semantically strange (a deleted subvolume can still "own" extents in a clone) but it completely eliminates backref walking and makes commit-time overhead O(dirty extents) rather than O(dirty extents × average backref depth). Meta's reported performance results (3–22% variance vs. baseline for squota, vs. 25–76% regression for traditional qgroups under snapshot-heavy workloads) validated the tradeoff for production use.

## How It Has Evolved

- **3.8** — Initial qgroup support merged; basic per-subvolume tracking with hierarchy. Missing rescan support, so enabling on non-empty filesystems was unreliable.
- **3.10** — Quota rescan added, making qgroups usable on existing filesystems. Automatic rescan on quota enable.
- **3.19** — Major reserved-space rework: per-inode range map prevents duplicate reservations; the false `-EDQUOT` on repeated writes to the same range is fixed.
- **4.x** — Delayed subtree scan optimisation: balance operations no longer trigger qgroup overhead if no concurrent writes are happening.
- **6.1** — `drop_subtree_threshold` sysfs tunable added; lets users trade accounting accuracy for faster bulk snapshot deletion.
- **6.7** — Simple quotas (squota) merged (`BTRFS_FEATURE_INCOMPAT_SIMPLE_QUOTA`); introduces `OWNER_REF` inline reference and eliminates backref walking entirely for the common case.

## Further Reading

1. [btfs: Subvolume Quota Groups — LWN (original introduction)](https://lwn.net/Articles/462401/)
2. [btrfs: simple quotas — LWN (squota design)](https://lwn.net/Articles/944371/)
3. [Btrfs: quota rescan for 3.10 — LWN](https://lwn.net/Articles/548316/)
4. [Rework btrfs qgroup reserved space framework — LWN](https://lwn.net/Articles/660324/)
5. [Quota groups — btrfs official docs](https://btrfs.readthedocs.io/en/latest/Qgroups.html)
6. [btrfs-qgroup(8) man page](https://man7.org/linux/man-pages/man8/btrfs-qgroup.8.html)
7. [Btrfs Qgroup Quota vs. Simple Quota — Oracle Linux blog](https://blogs.oracle.com/linux/btrfs-qgroup-quota-vs-simple-quota)

## LKML Highlights

- **[PATCH 0/2] btrfs: qgroup: stale qgroups related improvements** (`cover.1713508989.git.wqu@suse.com`) — 2024 thread addressing automatic removal of stale qgroups for fully-dropped subvolumes; reveals ongoing complexity in keeping the qgroup state consistent after subvolume deletion.
- **[RFC,07/11] btrfs: qgroup: save and pass old_roots ulist** (`1427098117-25152-8-git-send-email-quwenruo@cn.fujitsu.com`) — key design thread showing how capturing `old_roots` at delayed-ref insert time (rather than at commit time) avoids a second backref walk and resolves a correctness hole where concurrent operations could corrupt the before/after comparison.
- **[PATCH 0/7] btrfs: qgroup: Delay subtree scan to reduce overhead** (spinics v4 thread) — debate around deferring balance-triggered subtree rescans until CoW actually occurs; illustrates the tension between accounting correctness and performance.
