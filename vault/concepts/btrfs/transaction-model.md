---
title: "Btrfs Transaction Model"
category: concept
tags: [btrfs, transactions, journaling, crash-recovery, copy-on-write]
subsystem: btrfs
kernel_version: "2.6.29"
researched: 2026-04-05
status: complete
sources:
  - https://lwn.net/Articles/361457/
  - https://lwn.net/Articles/499156/
  - https://lwn.net/Articles/576276/
  - https://github.com/torvalds/linux/blob/master/fs/btrfs/transaction.h
  - https://linux-btrfs.vger.kernel.narkive.com/ZMThTEc9/questions-regarding-fsync-in-btrfs
---

# Btrfs Transaction Model

## Purpose

Btrfs must atomically commit groups of metadata changes — subvolume creates, file writes, directory operations — so that a crash never leaves the filesystem in a partially-applied state. Unlike ext4 and xfs, btrfs achieves this entirely through **copy-on-write (CoW)**: it never overwrites existing metadata blocks in place, so the old consistent state is always recoverable on disk. A transaction is the epoch boundary at which the new state is "sealed" by writing a new superblock that points to all the CoW'd root blocks.

## Mental Model

Think of a btrfs transaction as a staging area. All metadata writes during the transaction go to freshly allocated blocks, leaving the previous generation's blocks untouched. At commit, a new superblock is written pointing to the new root of the root tree (which now transitively references all new metadata). Once the superblock write completes and is acknowledged by the disk, the old blocks become freeable. A crash before the superblock write leaves the old superblock in place — the old consistent state is still fully reachable.

This eliminates the need for a traditional write-ahead log (WAL) for crash consistency. However, a lighter-weight **log tree** is used specifically for `fsync` durability without requiring a full transaction commit.

## How It Works

### Transaction lifecycle and state machine

Every btrfs transaction is represented by `struct btrfs_transaction`:

```c
struct btrfs_transaction {
    u64                      transid;         /* monotonically incrementing ID */
    atomic_t                 num_writers;     /* tasks currently writing inside */
    atomic_t                 num_extwriters;  /* external (non-join) writers */
    enum btrfs_trans_state   state;
    struct btrfs_delayed_ref_root delayed_refs; /* deferred extent updates */
    atomic_t                 pending_ordered; /* ordered extents awaiting IO */
    struct list_head         list;            /* fs_info->trans_list */
    ...
};
```

The `state` field progresses through a strict sequence:

| State | Meaning |
|---|---|
| `TRANS_STATE_RUNNING` | Transaction open; writers actively joining |
| `TRANS_STATE_COMMIT_PREP` | Commit requested; new writers must open a successor transaction |
| `TRANS_STATE_COMMIT_START` | Commit in progress; ordered extents being waited on |
| `TRANS_STATE_COMMIT_DOING` | Heavy lifting: delayed refs, pending snapshots, qgroups |
| `TRANS_STATE_UNBLOCKED` | New transaction can accept writers; old still finalising |
| `TRANS_STATE_SUPER_COMMITTED` | Superblock written to disk |
| `TRANS_STATE_COMPLETED` | All cleanup done; old blocks freed |

### Joining a transaction — `btrfs_trans_handle`

No code modifies btrfs metadata without first obtaining a per-task handle by calling `btrfs_start_transaction()` or `btrfs_join_transaction()`. The handle is `struct btrfs_trans_handle`:

```c
struct btrfs_trans_handle {
    u64            transid;       /* ID of the transaction this handle joined */
    u64            bytes_reserved;/* metadata bytes pre-reserved for this op */
    struct btrfs_transaction *transaction;
    struct btrfs_block_rsv   *block_rsv; /* reservation pool to charge */
    short          aborted;       /* non-zero = error; transaction is doomed */
    unsigned int   type;          /* START / JOIN / ATTACH / USERSPACE */
};
```

`btrfs_start_transaction(root, num_items)` pre-reserves metadata space for `num_items` B-tree modifications before the handle is returned. This is critical: reserving space before writing ensures the filesystem never reaches ENOSPC mid-transaction, which would otherwise leave metadata in a partially written state. If space cannot be reserved, the call blocks or returns `-ENOSPC` to the caller — never to the middle of a write.

### Metadata writes inside a transaction

All B-tree mutations (`btrfs_insert_item`, `btrfs_del_item`, path-modifying CoW) must be performed while holding a `btrfs_trans_handle`. Each mutation may trigger `btrfs_cow_block()`, which:
1. Allocates a new metadata extent.
2. Copies the existing block into it.
3. Records a **delayed reference** (`btrfs_delayed_ref`) to decrement the refcount on the old extent and increment it on the new one.
4. Updates the parent's key pointer to point to the new block.
5. Propagates CoW up to the tree root.

Rather than updating the extent tree immediately on every CoW (which would cause cascading B-tree churn), these back-reference changes are batched in `btrfs_transaction.delayed_refs`. The delayed ref root organises them into a red-black tree keyed by extent bytenr, and they are processed in bulk during transaction commit by `btrfs_run_delayed_refs()`.

### Transaction commit — `btrfs_commit_transaction()`

When triggered (by `sync`, a 30-second background flush, or explicit request), the commit proceeds in phases:

1. **Flush pending ordered extents** (`TRANS_STATE_COMMIT_START`): all file data IO initiated during this transaction must complete before metadata is committed, ensuring no file blocks are referenced in the new metadata that haven't hit disk yet.

2. **Create pending snapshots** (`TRANS_STATE_COMMIT_DOING`): any `BTRFS_IOC_SNAP_CREATE` that was issued during this transaction creates its snapshot root item now.

3. **Run delayed refs** (`TRANS_STATE_COMMIT_DOING`): `btrfs_run_delayed_refs()` processes all deferred extent back-reference updates, updating the extent tree (`btrfs_extent_item`) for every allocated or freed block. This is typically the most time-consuming phase.

4. **Write dirty metadata** (`TRANS_STATE_COMMIT_DOING`): all modified `extent_buffer` pages are written to disk via the block layer. Btrfs waits for all metadata IO to complete.

5. **Write new superblock** (`TRANS_STATE_SUPER_COMMITTED`): `write_ctree_super()` writes the updated `btrfs_super_block` (with incremented `generation` and updated root tree `bytenr`) to all super-block locations (up to 3 copies at fixed offsets). A barriers-enforced two-phase write ensures the superblock is only committed after all metadata has been persisted.

6. **Cleanup** (`TRANS_STATE_COMPLETED`): old blocks whose refcount hit zero during step 3 are handed to the free-space tracking structures.

### The log tree — fast fsync without a full commit

A full transaction commit is expensive (involves serialising all in-flight writers, running all delayed refs). For `fsync(2)`, btrfs uses a lighter path via the **log tree** (tree ID `BTRFS_LOG_TREE_OBJECTID`):

1. The inode's dirty metadata (inode item, directory entries, file extent items) is copied into a per-subvolume log tree.
2. The file's data blocks are ordered to disk.
3. The log tree itself is flushed: `btrfs_sync_log()` writes the log tree root to the log super (a secondary superblock-like structure).

If a crash occurs between the log flush and the next full transaction commit, the log tree is **replayed** at mount time: `btrfs_recover_log_trees()` walks the log tree and re-applies its items into the main filesystem trees. Once a full transaction commits, the log tree for that transaction is discarded — the main trees already reflect its changes.

The log tree only holds one transaction's worth of fsync'd data. Crucially, the log tree approach means a single-file `fsync` need not stall other writers or touch the extent tree — it only writes that file's metadata.

**Limitation**: if a file that was fsync'd is in a directory that was concurrently modified, the directory's delayed items may need to be committed too, because directory indexes are stored as delayed items and the log tree needs a consistent directory view for recovery.

### Transaction abort

Any error during transaction commit (IO error writing a metadata block, ENOMEM in delayed ref processing) triggers `btrfs_abort_transaction()`:

1. Sets `btrfs_trans_handle.aborted` on the current handle.
2. Sets the filesystem-wide `fs_info->aborted_transaction` error code.
3. Transitions the filesystem to read-only (`BTRFS_FS_STATE_ERROR`).

All subsequent handle operations check `TRANS_ABORTED(trans)` via `READ_ONCE()`. A transaction abort is unrecoverable online — the user must remount or run `btrfs check`.

## Key Data Structures

**`struct btrfs_transaction`** (`fs/btrfs/transaction.h`) — one per open transaction; tracks all in-flight writers and batches delayed refs.
- `transid` — monotonic counter; the generation embedded in every `btrfs_header`
- `delayed_refs` — red-black tree of `btrfs_delayed_ref_node`; processed at commit
- `pending_ordered` — count of ordered extents that must complete before commit
- `state` — seven-stage state machine controlling concurrency

**`struct btrfs_trans_handle`** (`fs/btrfs/transaction.h`) — per-task, per-join token.
- `bytes_reserved` — pre-reserved metadata space; must be set before any write
- `block_rsv` — the reservation pool being charged (global, per-inode, or delalloc)
- `aborted` — non-zero means the transaction is doomed; callers must propagate the error

**`btrfs_delayed_ref_node`** (`fs/btrfs/delayed-ref.h`) — one pending back-reference update.
- `bytenr` / `num_bytes` — the extent being updated
- `action` — `BTRFS_ADD_DELAYED_REF` or `BTRFS_DROP_DELAYED_REF`
- `ref_root` — which B-tree is the owner (for tree back-refs) or `0` for data refs

**`btrfs_super_block`** (`include/uapi/linux/btrfs_tree.h`) — written last at commit.
- `generation` — must equal `btrfs_transaction.transid`
- `root` / `root_level` — bytenr of root tree root; updated atomically at commit

## Key Functions / Entry Points

**`btrfs_start_transaction(root, num_items)`** (`fs/btrfs/transaction.c`) — reserves space and joins (or starts) the current running transaction; returns a handle.

**`btrfs_commit_transaction(trans)`** (`fs/btrfs/transaction.c`) — drives all commit phases; blocks until the superblock is committed.

**`btrfs_run_delayed_refs(trans, count)`** (`fs/btrfs/extent-tree.c`) — processes up to `count` delayed refs, updating the extent tree; called repeatedly during commit.

**`btrfs_sync_log(trans, root, ctx)`** (`fs/btrfs/tree-log.c`) — flushes the log tree for a single subvolume after an fsync; does not commit the main transaction.

**`btrfs_recover_log_trees(fs_root)`** (`fs/btrfs/tree-log.c`) — called at mount; replays any committed log trees into the main filesystem.

**`btrfs_abort_transaction(trans, errno)`** (`fs/btrfs/transaction.c`) — marks the transaction and filesystem as failed; transitions FS to read-only.

**`write_ctree_super(trans)`** (`fs/btrfs/disk-io.c`) — writes the new superblock to all super locations; the point of no return for a transaction commit.

## Important Flags & Config Options

| Symbol / Option | Effect |
|---|---|
| `BTRFS_TRANS_JOIN` | Handle type: join the running transaction without pre-reserving space (used for metadata-only ops that already reserved elsewhere) |
| `BTRFS_TRANS_ATTACH` | Attach to an already-running commit without incrementing writer count; used by internal helpers |
| `commit_interval` mount option | Seconds between periodic transaction commits (default 30). Lower values reduce data loss window but increase write amplification. |
| `btrfs.commit=N` module param | Alternative to mount option for commit interval |
| `BTRFS_FS_STATE_ERROR` | fs_info flag set on transaction abort; all subsequent operations return `-EIO` |

## Interactions with Other Subsystems

- **↑ Userspace**: `fsync(2)` → log tree path; `sync(2)` / `syncfs(2)` → full `btrfs_commit_transaction`; `ioctl(BTRFS_IOC_SNAP_CREATE*)` → pending snapshot executed at next commit.
- **→ [[multiple-b-trees]]**: Every B-tree mutation (CoW) is performed inside a transaction; the tree's root block pointer is only stable once committed.
- **→ [[subvolumes-and-snapshots]]**: Snapshot creation is deferred until `TRANS_STATE_COMMIT_DOING`, not executed at ioctl time. The transaction provides the atomicity that makes O(1) snapshot creation safe.
- **→ [[checksumming-and-data-integrity]]**: Data checksums are written to the checksum tree inside a transaction; they are committed atomically with the extent items that reference the data.
- **→ Block layer (ordered extents)**: The transaction waits for all ordered extents (`btrfs_ordered_extent`) to complete before the commit proceeds, ensuring file data is on disk before metadata references it.
- **← VFS**: `btrfs_sync_file()` (the `.fsync` VFS op) decides whether to take the log tree fast path or fall back to a full commit based on flags such as `BTRFS_INODE_NEEDS_FULL_SYNC`.

## Design Decisions & Tradeoffs

**CoW instead of WAL for crash consistency**: Traditional filesystems journal metadata changes in a write-ahead log. Btrfs's CoW approach means the old generation is always intact on disk — no journal replay is needed for crash recovery. The downside is write amplification: a single-item update propagates CoW all the way to the root, touching O(depth) blocks (typically 3–5 for a large filesystem).

**Delayed refs to amortise extent tree updates**: Updating the extent tree for every CoW'd block synchronously would cause O(N²) B-tree churn for a batch of N writes. Batching as delayed refs and flushing at commit reduces this to O(N log N) at the cost of holding references in memory until commit and requiring careful space reservation to ensure the extent tree updates can be written.

**Log tree for fsync durability without full commits**: Full commits are expensive because they must serialise all writers and flush the entire dirty metadata set. The log tree gives fsync O(changed-file-metadata) cost instead of O(dirty-transaction) cost, at the price of a separate recovery path (`btrfs_recover_log_trees`) and the need to ensure the log is discarded after a full commit.

**Space reservation before writing**: Pre-reserving metadata space at handle acquisition time means ENOSPC is reported to the caller, not mid-transaction. This is crucial for correctness but means some space is temporarily over-reserved: if a batch reserves for 10 items but only uses 3, the extra 7 items' worth of space is held until the handle is released.

**Transaction abort is unrecoverable online**: Rather than attempt partial rollback (which would require an undo log btrfs doesn't have), any IO error aborts the transaction and makes the filesystem read-only. This is conservative but safe.

## How It Has Evolved

- **2.6.29 (2009)**: Initial merge; CoW-based transaction model present from the start.
- **2.6.37 (2011)**: Log tree (fsync fast path) merged, dramatically reducing fsync latency for workloads writing many small files.
- **3.3 (2012)**: Per-inode metadata reservations improved; previously all reservations came from a global pool that caused priority inversions.
- **3.7 (2012)**: Tree modification log merged (separate from the log tree — used for consistent backref resolution during balance/scrub).
- **4.x**: Continuous improvements to delayed-ref batching and processing order to reduce commit latency spikes.
- **5.x+**: Ongoing work on async discard, free-space tree, and reducing write amplification on SSDs.

## Further Reading

1. **LWN — "Supporting transactions in btrfs"** (2009): https://lwn.net/Articles/361457/ — Discusses user-space transaction ioctls and the log tree for fsync.
2. **LWN — "Btrfs: tree modification log"** (2012): https://lwn.net/Articles/499156/ — The tree mod log for concurrent backref resolution.
3. **LWN — "The Btrfs filesystem: An introduction"** (2013): https://lwn.net/Articles/576276/ — High-level overview including the CoW consistency model.
4. **Kernel source — transaction.h**: https://github.com/torvalds/linux/blob/master/fs/btrfs/transaction.h — canonical struct definitions.

## LKML Highlights

- **Log tree for fsync** (Chris Mason, 2009, around kernel 2.6.37 merge window): thread debating whether btrfs should use a traditional journal for fsync or a purpose-built log tree. The log tree approach won because it avoids serialising all writers on each fsync.
- **Space reservation overhaul** (Josef Bacik, ~3.3 era): discussions around per-inode vs global reservation pools and how to avoid priority inversions where a large writer blocks small flushes.
