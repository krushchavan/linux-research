---
title: "Btrfs Subvolumes and Snapshots"
category: concept
tags: [btrfs, filesystem, snapshots, copy-on-write, subvolumes]
subsystem: btrfs
kernel_version: "2.6.29"
researched: 2026-04-05
status: complete
sources:
  - https://lwn.net/Articles/579009/
  - https://lwn.net/Articles/237904/
  - https://lwn.net/Articles/506244/
  - https://btrfs.readthedocs.io/en/latest/Subvolumes.html
  - https://archive.kernel.org/oldwiki/btrfs.wiki.kernel.org/index.php/SysadminGuide.html
---

# Btrfs Subvolumes and Snapshots

## Purpose

A btrfs subvolume is an independently mountable filesystem tree within a single btrfs volume. Subvolumes allow a single disk partition to contain multiple isolated filesystem namespaces — each with its own inode space — that can be individually snapshotted, deleted, sent, or received. Snapshots give users O(1) point-in-time copies without duplicating data, enabling cheap backups, rollbacks, and incremental replication.

## Mental Model

Think of a btrfs volume as a library building and each subvolume as a separate room inside that building. All rooms share the same walls, pipes, and electrical system (the underlying block allocator, chunk manager, and CoW machinery). A snapshot is like photocopying the index card of a room — you now have two index cards pointing at the same shelves. As books are added or moved (writes), new copies of affected shelves are made and only the modified room's index card is updated; the other room's index card still points at the old shelves. Eventually each room accumulates its own diverged history, all sharing any pages that were never written after the snapshot.

## How It Works

### Subvolumes as independent B-trees

Every btrfs subvolume is backed by its own **filesystem tree** — the same kind of B-tree described in [[multiple-b-trees]], with tree ID ≥ 256 for user subvolumes (IDs 1–255 are reserved for internal trees like the extent tree). The **root tree** (tree ID 1) acts as the directory of all subvolumes: it stores one `ROOT_ITEM` key per subvolume, and that item contains the `btrfs_root_item` struct, whose most important field is the **bytenr** (byte address) of the B-tree's root block on disk.

```c
struct btrfs_root_item {
    struct btrfs_inode_item inode;   /* the "inode" of the subvol root */
    __le64 generation;               /* increments with every CoW */
    __le64 root_dirid;               /* always 256 — the top-level dir inode */
    __le64 bytenr;                   /* disk address of the B-tree root block */
    __le64 byte_limit;
    __le64 bytes_used;
    __le64 last_snapshot;            /* generation when last snapshot was taken */
    __le64 flags;                    /* BTRFS_ROOT_SUBVOL_RDONLY etc. */
    __le32 refs;                     /* refcount; 0 = pending deletion */
    struct btrfs_disk_key drop_progress;
    __u8   drop_level;
    __u8   level;                    /* current height of the B-tree */
    ...
};
```

Every subvolume has inode 256 as its root directory. Inodes within a subvolume are numbered independently — inode 256 in subvolume A and inode 256 in subvolume B are unrelated. This means **hard links cannot cross subvolume boundaries**: the kernel enforces this because a hard link requires sharing an inode, which must live in exactly one B-tree.

### Creating a subvolume

When userspace calls `ioctl(fd, BTRFS_IOC_SUBVOL_CREATE, &args)`, the kernel:

1. Allocates a new tree ID from the root tree's objectid counter.
2. Creates a new, empty B-tree with a single leaf block.
3. Inserts a fresh `ROOT_ITEM` into the root tree pointing at that leaf.
4. Creates inode 256 (the root dir) inside the new B-tree.
5. Adds a `DIR_ITEM`/`DIR_INDEX` pair in the parent directory's tree so the subvolume appears as a directory entry.

The entire operation fits in one [[transaction-model|btrfs transaction]], so it is atomic.

### Creating a snapshot — O(1) copy

A snapshot is created with `ioctl(fd, BTRFS_IOC_SNAP_CREATE_V2, &args)`. The kernel takes what amounts to a **refcount bump on the root block**:

1. Read the source subvolume's `ROOT_ITEM` from the root tree.
2. Copy the struct verbatim into a new `ROOT_ITEM` entry (new tree ID) in the root tree. Both entries now share the same `bytenr` — the same root block on disk.
3. Walk the shared root block and increment the back-reference count on every extent that block covers. In practice this is done lazily via **delayed refs** (`btrfs_delayed_ref`) rather than walking the entire tree at creation time — the full extent-tree bookkeeping is deferred until the shared extents are actually CoW'd.
4. Set the `last_snapshot` field in the original subvolume's `ROOT_ITEM` to the current generation.

The result is that snapshot creation touches only ~O(1) metadata entries regardless of how many gigabytes the subvolume contains. There is no data copy; both subvolumes point at identical B-tree blocks.

### Copy-on-write divergence

After the snapshot, reads from either subvolume walk the shared B-tree blocks identically. The moment a write occurs to a block in one subvolume, `btrfs_cow_block()` is invoked:

1. Allocate a new metadata extent.
2. Copy the existing block's contents into it.
3. Update the parent's key pointer (`btrfs_key_ptr.blockptr`) to point at the new block.
4. Propagate CoW upward through every ancestor node up to the root.
5. Write the new `ROOT_ITEM.bytenr` into the root tree.

The other subvolume's `ROOT_ITEM.bytenr` is unchanged — it still points at the old block. Over time each subvolume accumulates its own chain of CoW'd blocks while continuing to share any extents that have not yet been written in that subvolume.

### Read-only snapshots

Passing `BTRFS_SUBVOL_RDONLY` in `btrfs_ioctl_snap_create_v2.flags` sets `BTRFS_ROOT_SUBVOL_RDONLY` in the snapshot's `root_item.flags`. The VFS enforces this: any write attempt returns `-EROFS`. Read-only snapshots are required as the **source** for `BTRFS_IOC_SEND`.

### Snapshot deletion — the slow path

Deleting a subvolume or snapshot is deceptively expensive. The kernel must walk the entire B-tree, decrement back-references on every file data extent and metadata block, and free each extent that hits refcount zero. To avoid blocking the filesystem for long deletions, btrfs uses the `drop_progress`/`drop_level` fields in `btrfs_root_item` to checkpoint progress. The deletion is spread across multiple transactions; the subvolume becomes invisible to the user immediately (its root tree entry is removed) but physical cleanup continues in the background via `btrfs_drop_snapshot()` → `btrfs_drop_subtree()`.

The "snapshot deletion requires space" problem is real: freeing extents may require writing new extent tree metadata, so a disk that is 100% full cannot delete its way to free space without first creating some headroom.

### Nested subvolumes and snapshot scoping

A subvolume can contain mount points for other subvolumes — these are **nested subvolumes**. When a snapshot is taken, the snapshot does **not** cross subvolume boundaries: nested subvolumes appear as empty directories in the snapshot. This is intentional — each subvolume has its own independent `ROOT_ITEM` and snapshotting operates on exactly one.

### send/receive — incremental replication

`BTRFS_IOC_SEND` produces a stream of instructions that reconstructs a subvolume on another host:

- **Full send**: streams every file and directory from a read-only snapshot.
- **Incremental send**: given a **clone source** (an older read-only snapshot), walks both B-trees simultaneously, emitting only the differences as `btrfs_send_cmd` opcodes: `WRITE`, `CLONE`, `RENAME`, `UNLINK`, `CHMOD`, etc.

The clone source must be a common ancestor present on both sender and receiver. The receiver replays the instruction stream via `BTRFS_IOC_RECEIVE`. Because the send stream can reference extent data via `CLONE` rather than `WRITE`, incremental sends are bandwidth-efficient when data blocks are shared between the two snapshots.

Internally, `btrfs_send` maintains a **send context** (`btrfs_send_ctx`) that tracks iterator state across both B-trees, emitting diff commands as it walks. The send stream is versioned; stream version 2 adds compressed extent support.

## Key Data Structures

**`btrfs_root_item`** (`include/uapi/linux/btrfs_tree.h`) — on-disk descriptor for a subvolume/snapshot root.
- `bytenr` — disk address of the B-tree root block; the only field that differs between a subvolume and its snapshot at creation
- `last_snapshot` — generation at last snapshot; used by CoW to know when extents must be copied
- `flags` — `BTRFS_ROOT_SUBVOL_RDONLY` makes the subvolume read-only
- `refs` — reference count; 0 triggers asynchronous deletion
- `drop_progress`/`drop_level` — checkpoint for incremental snapshot deletion

**`btrfs_ioctl_snap_create_v2`** (`include/uapi/linux/btrfs.h`) — userspace argument struct for `BTRFS_IOC_SNAP_CREATE_V2`.
- `fd` — open file descriptor inside the source subvolume
- `name` — name for the new snapshot directory entry
- `flags` — `BTRFS_SUBVOL_RDONLY` (read-only), `BTRFS_SUBVOL_QGROUP_INHERIT`

**`btrfs_delayed_ref`** (`fs/btrfs/delayed-ref.h`) — deferred extent back-reference update created at snapshot time; batched and applied at transaction commit to avoid O(tree-size) work at snapshot creation.

**`btrfs_send_ctx`** (`fs/btrfs/send.c`) — runtime state for an ongoing send operation; holds references to both the snapshot and the clone-source B-trees and tracks iterator position.

## Key Functions / Entry Points

**`btrfs_create_subvol()`** (`fs/btrfs/ioctl.c`) — creates a new empty subvolume; allocates tree ID, creates root dir inode 256, inserts `ROOT_ITEM`.

**`btrfs_snapshot_subtree()`** / **`create_snapshot()`** (`fs/btrfs/ioctl.c`) — called by `BTRFS_IOC_SNAP_CREATE_V2`; copies `ROOT_ITEM`, increments root block refcount via delayed refs.

**`btrfs_drop_snapshot()`** (`fs/btrfs/extent-tree.c`) — async B-tree walk that frees all extents of a deleted subvolume across multiple transactions, checkpointing via `drop_progress`.

**`btrfs_ioctl_send()`** / **`send_subvol()`** (`fs/btrfs/send.c`) — implements `BTRFS_IOC_SEND`; drives the diff walk and serialises the send stream to a pipe fd.

**`btrfs_cow_block()`** (`fs/btrfs/ctree.c`) — CoW's a metadata block when a write occurs; allocates new extent, copies, updates parent key pointer, propagates to root.

## Important Flags & Config Options

| Flag / Option | Where | Effect |
|---|---|---|
| `BTRFS_SUBVOL_RDONLY` | `snap_create_v2.flags` | Creates a read-only snapshot (required for send source) |
| `BTRFS_ROOT_SUBVOL_RDONLY` | `root_item.flags` | Kernel-side RO flag; toggled by `BTRFS_IOC_SUBVOL_SETFLAGS` |
| `BTRFS_SUBVOL_QGROUP_INHERIT` | `snap_create_v2.flags` | Propagates qgroup limits from parent to snapshot |
| `btrfs_ioctl_send_args.flags` | send ioctl | `BTRFS_SEND_FLAG_NO_FILE_DATA`: metadata-only send; `BTRFS_SEND_FLAG_COMPRESSED`: send compressed extents as-is |
| `subvol=` / `subvolid=` mount option | mount | Mounts a specific subvolume as the filesystem root |
| `BTRFS_DEFAULT_SUBVOL` | root tree | The default subvolume ID returned when `subvol=` is not specified |

## Interactions with Other Subsystems

- **↑ Userspace**: `btrfs(8)` wraps the ioctls (`BTRFS_IOC_SUBVOL_CREATE`, `BTRFS_IOC_SNAP_CREATE_V2`, `BTRFS_IOC_SEND`, `BTRFS_IOC_RECEIVE`, `BTRFS_IOC_SUBVOL_SETFLAGS`); `snapper` and `timeshift` use subvolume snapshots as a backup primitive.
- **→ [[transaction-model]]**: Every subvolume/snapshot create and delete runs inside a btrfs transaction. The [[transaction-model|transaction model]] provides the atomicity guarantee; snapshot creation and deletion are journal-safe.
- **→ [[multiple-b-trees]]**: Subvolumes *are* B-trees. All B-tree mechanics (CoW, `btrfs_path`, `extent_buffer` locking) apply directly.
- **→ [[checksumming-and-data-integrity]]**: Each shared data extent retains its checksum regardless of which subvolume reads it; checksums survive snapshots without recomputation.
- **→ [[raid-and-multi-device-support]]**: Data extents shared between subvolumes benefit from RAID redundancy uniformly; the multi-device layer is below the subvolume abstraction.
- **← VFS mount layer**: The VFS [[mount-namespace]] sees each subvolume as a distinct `super_block`-equivalent tree (they share one `super_block` but have separate `btrfs_root` instances). `do_mount` with `subvol=` redirects the root dentry to the named subvolume's inode 256.
- **← qgroups**: Quota groups track per-subvolume space consumption, counting shared vs exclusive extents for each subvolume/snapshot pair.

## Design Decisions & Tradeoffs

**Snapshots are subvolumes**: Chris Mason's original design made snapshots and subvolumes the same kernel object — a snapshot is a subvolume whose `ROOT_ITEM` was created by copying another's. This eliminates a separate snapshot code path but means snapshot deletion is as expensive as subvolume deletion (full tree walk).

**O(1) creation via delayed refs**: Incrementing refcounts on every shared extent at snapshot creation time would be O(tree-size). Btrfs defers this work via `btrfs_delayed_ref` entries that are batched at transaction commit. This makes creation fast but means the extent tree is not fully consistent between transaction commits.

**No cross-subvolume hard links**: Each subvolume has its own inode namespace. A hard link requires a shared inode number, which cannot span B-trees. This was a deliberate choice to keep the per-subvolume B-tree model clean; the alternative (a global inode table) would have complicated snapshot semantics.

**Nested subvolumes not included in parent snapshots**: Crossing into a child subvolume's B-tree during snapshot would require transactionally snapshotting all descendants, which could be arbitrarily deep. The design stops at the subvolume boundary. Tooling like `snapper` handles recursive snapshots in userspace by snapshotting each subvolume independently.

**Send stream requires read-only source**: Allowing send from a live read-write subvolume would produce an inconsistent stream as concurrent writes race with the iterator. Requiring read-only snapshots is the practical enforcement of a consistent view.

**Deletion space paradox**: Freeing extents requires writing new extent-tree metadata. A completely full btrfs filesystem may not be able to complete snapshot deletion until some external space is freed. This is a known pain point that has driven efforts like free-space tree (tree ID 10) and space reservation improvements.

## How It Has Evolved

- **2.6.29 (2009)**: Initial btrfs merge; subvolumes and snapshots present from the beginning as core features.
- **2.6.37 (2011)**: `BTRFS_IOC_SNAP_CREATE_V2` added, replacing `BTRFS_IOC_SNAP_CREATE` with proper flags support including `BTRFS_SUBVOL_RDONLY`.
- **3.6 (2012)**: `BTRFS_IOC_SEND` / `BTRFS_IOC_RECEIVE` merged, enabling send/receive for snapshot replication.
- **4.4 (2016)**: Send stream version 2 with compressed extent support (`BTRFS_SEND_FLAG_COMPRESSED`).
- **5.7 (2020)**: Snapshot-aware defragmentation removed (it was too complex and caused unexpected performance regressions).
- **6.x**: Ongoing work on async discard and free-space tree improvements to alleviate the deletion-needs-space problem.

## Further Reading

1. **LWN — "Btrfs: Subvolumes and snapshots"** (2009): https://lwn.net/Articles/579009/ — Original design walkthrough by Chris Mason; covers the snapshot-as-subvolume model.
2. **LWN — "A look at btrfs"** (2008): https://lwn.net/Articles/237904/ — Early design overview including the CoW model underlying snapshots.
3. **LWN — "Btrfs send/receive"** (2012): https://lwn.net/Articles/506244/ — Introduction of the send/receive feature.
4. **Btrfs documentation — Subvolumes**: https://btrfs.readthedocs.io/en/latest/Subvolumes.html
5. **Btrfs SysadminGuide**: https://archive.kernel.org/oldwiki/btrfs.wiki.kernel.org/index.php/SysadminGuide.html — Flat vs nested layout discussion.

## LKML Highlights

- **`BTRFS_IOC_SEND` initial merge discussion** (`[PATCH] btrfs: add send/receive`, Alexander Block, 2012): thread around `20120130083301.GA26650@requ.de` — debate on requiring read-only snapshots as source and stream versioning strategy.
- **Snapshot deletion space reservation** — multiple threads from 2012–2014 around `btrfs_drop_snapshot` and reservation stealing; led to the `BTRFS_RESERVE_FLUSH_ALL` path to ensure deletion can always make progress.
