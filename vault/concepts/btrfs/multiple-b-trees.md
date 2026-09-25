---
title: "Btrfs Multiple B-Trees"
category: concept
tags: [btrfs, b-tree, cow, extent-tree, chunk-tree, metadata]
subsystem: btrfs
kernel_version: "2.6.29"
researched: 2026-04-05
status: complete
explained: "[[multiple-b-trees-explained]]"
sources:
  - https://lwn.net/Articles/342892/
  - https://archive.kernel.org/oldwiki/btrfs.wiki.kernel.org/index.php/Btrfs_design.html
  - https://archive.kernel.org/oldwiki/btrfs.wiki.kernel.org/index.php/Btrees.html
  - https://dxuuu.xyz/btrfs-internals-3.html
  - https://lwn.net/Articles/878790/
---

# Btrfs Multiple B-Trees

> 📘 Plain-language version: [[multiple-b-trees-explained]]

## Purpose

Btrfs organises all of its metadata — file data extents, directory entries, space allocation, block address mapping, data checksums, subvolume roots, and more — as a collection of copy-on-write (CoW) B-trees. Rather than one monolithic metadata structure, Btrfs uses a family of specialised trees, each holding one category of metadata, all sharing the same on-disk node format and the same in-kernel B-tree manipulation code. This design allows metadata to be cached, checksummed, copy-on-write'd, and replicated using a single, well-tested code path regardless of whether a block contains inode data or checksum data.

## Mental Model

Think of Btrfs as a database built on CoW B-trees. The key insight is that every piece of metadata in the filesystem — whether it is a file's size, a directory entry, an allocated extent, a device stripe map, or a block checksum — is represented as a typed item stored under a three-component key `(objectid, type, offset)` inside one of the trees. The B-tree code does not know or care what the items contain; it just inserts, deletes, and looks up keys. Specialisation comes from which tree a given item lives in and what its type byte means.

All trees share a common node structure and all modifications are copy-on-write: instead of modifying a node in place, Btrfs allocates a new block, writes the modified version there, and updates the parent's block pointer — also via CoW. This propagates up to the tree root. The root's block address is stored in the superblock (or in the root tree for all non-root trees), so a single atomic superblock write atomically commits an entire tree of changes.

## How It Works

### The B-tree node format

Every B-tree node — whether an internal node or a leaf — starts with a `struct btrfs_header`:

```c
struct btrfs_header {
    u8    csum[BTRFS_CSUM_SIZE]; /* checksum of this block */
    u8    fsid[BTRFS_FSID_SIZE]; /* filesystem UUID */
    __le64 bytenr;               /* logical address of this block */
    __le64 flags;                /* BTRFS_HEADER_FLAG_WRITTEN, etc. */
    u8    chunk_tree_uuid[BTRFS_UUID_SIZE]; /* chunk tree UUID */
    __le64 generation;           /* transaction generation when written */
    __le64 owner;                /* objectid of the tree that owns this node */
    __le32 nritems;              /* number of key-ptr pairs (internal) or items (leaf) */
    u8    level;                 /* 0 = leaf, >0 = internal node */
};
```

The `level` field distinguishes node type. A level-0 node is a **leaf**; it stores actual items. Level ≥ 1 is an **internal node**; it stores key-pointer pairs that direct tree traversal.

**Internal nodes** contain an array of `struct btrfs_key_ptr` entries immediately after the header:
```c
struct btrfs_key_ptr {
    struct btrfs_disk_key key;   /* smallest key in the child subtree */
    __le64 blockptr;             /* logical block number of child node */
    __le64 generation;           /* generation at which child was last written */
};
```
Binary search on the `key` array finds which child pointer to follow.

**Leaf nodes** use a two-region layout: item descriptors grow from the front, item payloads grow from the back. This avoids fragmentation and allows items of variable size:
```c
struct btrfs_item {
    struct btrfs_disk_key key;
    __le32 offset;  /* offset from end of header to payload start */
    __le32 size;    /* payload size in bytes */
};
```
The payload for `btrfs_item[i]` is at `(char*)leaf + sizeof(btrfs_header) + offset[i]`.

### The universal key: (objectid, type, offset)

Every item in every Btrfs tree is identified by a 17-byte `struct btrfs_disk_key`:
```c
struct btrfs_disk_key {
    __le64 objectid;  /* what object this item belongs to */
    u8     type;      /* what kind of item it is */
    __le64 offset;    /* sub-address or sub-index within the object */
};
```

`objectid` is the most significant field; all items for a given object are contiguous in the tree. `type` acts as a namespace within the object; it determines what the payload struct means. `offset` further qualifies the item; for extent items it is the byte offset on disk, for checksums it is the first byte checksummed.

This means a single `btrfs_search_slot(root, key, path, ...)` call locates any item in any tree using the same code path.

### In-memory: extent_buffer and btrfs_path

On-disk blocks are cached in memory as `struct extent_buffer` objects. An extent buffer wraps one or more folios (typically one 4 KiB block = one folio) and exposes accessor macros for reading/writing the little-endian on-disk structs. Every extent buffer has:
- A logical start address (`start`).
- A reference count and RW-lock (`btrfs_tree_lock(eb)` / `btrfs_tree_unlock(eb)`).
- Dirty/uptodate flags.

Tree traversal is tracked by `struct btrfs_path`:
```c
struct btrfs_path {
    struct extent_buffer *nodes[BTRFS_MAX_LEVEL]; /* one eb per level */
    int  slots[BTRFS_MAX_LEVEL];   /* item/key-ptr index at each level */
    u8   locks[BTRFS_MAX_LEVEL];   /* lock type held at each level */
    int  reada;                    /* readahead hint */
    /* … */
};
```
A `btrfs_path` is stack-allocated by callers; `btrfs_search_slot()` fills it in. After use, `btrfs_release_path()` drops all extent buffer references.

### Copy-on-write mechanics

When a leaf or node needs to be modified (insert, delete, or update), `btrfs_cow_block()` is called:
1. Allocates a new block from the extent allocator.
2. Copies the old node content to the new block.
3. Applies the modification to the new block.
4. Updates the parent's `btrfs_key_ptr.blockptr` to point to the new block — which itself requires CoW-ing the parent, propagating up to the tree root.
5. The old block is freed (its reference count decremented) at transaction commit.

This propagation means any single modification creates a log-n chain of new blocks from leaf to root. The root's new block address is stored in the root item (in the root tree) or in the superblock (for the root tree itself). Committing the transaction is a single atomic write of the superblock, making the entire change visible at once.

### The tree family

Btrfs maintains the following trees, all rooted in the superblock (for the top-level trees) or in the root tree (for all others):

#### Root tree (BTRFS_ROOT_TREE_OBJECTID = 1)

The root tree stores the root items for all other trees. Each entry maps an `(objectid=tree_id, BTRFS_ROOT_ITEM_KEY, 0)` to a `struct btrfs_root_item` containing the block number and generation of that tree's root node. The superblock stores the root tree's own root block address directly.

The root tree also stores subvolume and snapshot metadata:
- `BTRFS_ROOT_ITEM_KEY` — root block pointer and statistics for each subvolume tree
- `BTRFS_ROOT_REF_KEY` / `BTRFS_ROOT_BACKREF_KEY` — parent-child relationships between subvolumes

When code needs to open any tree, it looks up its root item in the root tree.

#### Extent tree (BTRFS_EXTENT_TREE_OBJECTID = 2)

The extent tree tracks every allocated byte range on the logical address space. It serves the role that a traditional block bitmap plays in ext4, but with full back-reference metadata. Two key item types:

- `BTRFS_EXTENT_ITEM_KEY (bytenr, EXTENT_ITEM, len)` — records one allocated extent: reference count, flags (DATA vs METADATA), inline back-references.
- `BTRFS_METADATA_ITEM_KEY` — compact form for metadata extents (single tree node).

Back-references inside extent items identify every B-tree node or file that holds a reference to the extent:
- **Tree back-references** (`BTRFS_TREE_BLOCK_REF_KEY`): which tree's node uses this extent.
- **Extent data back-references** (`BTRFS_EXTENT_DATA_REF_KEY`): which file (root+objectid+offset) uses this data extent.

These back-references enable snapshot-aware defragmentation (balance), efficient `btrfs scrub` (walk all extents and verify checksums), and fast `btrfs device remove` (find every extent on the removed device and relocate it).

#### Chunk tree (BTRFS_CHUNK_TREE_OBJECTID = 3) + Device tree

The chunk tree maps logical byte ranges to physical stripe layouts across physical devices. Every `(BTRFS_FIRST_CHUNK_TREE_OBJECTID, BTRFS_CHUNK_ITEM_KEY, logical_offset)` item contains:
- Number of stripes.
- Per-stripe: device UUID, device offset, stripe length.
- RAID profile (RAID0/1/10/5/6/single/dup).

The chunk tree answers: "logical address X is at which physical device and offset?" It is the I/O translation layer.

The **device tree** (not a separate tree object but items in the chunk tree with `BTRFS_DEV_ITEM_KEY`) maintains the reverse mapping: for each device, which logical chunks are on it. This is used for device removal and balance operations.

The chunk tree is special: it is also stored in a dedicated area of the superblock (`sys_chunk_array`) for the bootstrap problem — you need to read the chunk tree to translate addresses, but the chunk tree itself is stored at an address that needs translating. The superblock embeds the mapping for the chunks that hold the chunk tree and root tree.

#### Filesystem trees (per-subvolume)

Each subvolume (including the default subvolume, id=5 in most setups) has its own filesystem tree. These trees store:
- `BTRFS_INODE_ITEM_KEY (ino, INODE_ITEM, 0)` — inode metadata (size, times, mode, nlinks)
- `BTRFS_INODE_REF_KEY (ino, INODE_REF, parent_ino)` — directory entry back-reference
- `BTRFS_DIR_ITEM_KEY (dir_ino, DIR_ITEM, hash)` — directory entry (name→inode mapping)
- `BTRFS_DIR_INDEX_KEY (dir_ino, DIR_INDEX, index)` — readdir index for consistent ordering
- `BTRFS_EXTENT_DATA_KEY (ino, EXTENT_DATA, file_offset)` — file data: either inline data or an extent pointer (`struct btrfs_file_extent_item`) giving the logical address and length of a data extent

Each subvolume tree is independent; creating a snapshot is O(1): the root tree gains a new root item pointing to the same root block as the original, with reference counts incremented. CoW ensures future modifications to either the original or the snapshot diverge without affecting the other.

#### Checksum tree (BTRFS_CSUM_TREE_OBJECTID = 7)

The checksum tree stores per-block checksums for all data extents. Each `(BTRFS_EXTENT_CSUM_OBJECTID, BTRFS_EXTENT_CSUM_KEY, logical_offset)` item contains a packed array of 4-byte (CRC32c) or 32-byte (XXHASH64, SHA256, BLAKE2b) checksums, one per 4 KiB sector. Checksums are written when data is written and verified on every read.

#### Free space tree (BTRFS_FREE_SPACE_TREE_OBJECTID = 10)

The free space tree (introduced as a v2 replacement for the older free-space cache in v1) tracks unallocated space within each block group using `BTRFS_FREE_SPACE_BITMAP_KEY` (for contiguous ranges) and `BTRFS_FREE_SPACE_EXTENT_KEY` (for individual free extents). It enables fast allocation without scanning the extent tree on mount.

#### Log tree (temporary, per-subvolume)

The log tree is a per-subvolume temporary tree used for fsync-on-ordered-mode writes. When `fsync(2)` is called, the modified inodes and their directory entries are written to the log tree; if a crash occurs before the next full transaction commit, the log tree is replayed at mount to recover the fsync'd data. Log trees are deleted after successful transaction commit.

### Tree locking

Btrfs uses a reader-writer lock (`btrfs_tree_lock` / `btrfs_tree_read_lock`) on each extent buffer node. For write operations, a top-down locking protocol is used: nodes are locked from root to leaf, and parent nodes can be unlocked early ("lock coupling" / "tree modification context") once it is proven that the modification will not split or merge the parent.

## Key Data Structures

**`struct btrfs_header`** (`fs/btrfs/ctree.h`) — common prefix for every on-disk node: checksum, fsid, logical address, generation, owner, item count, level.

**`struct btrfs_disk_key`** — three-component key: objectid (u64), type (u8), offset (u64); stored big-endian for correct byte-order comparison.

**`struct btrfs_key_ptr`** — internal node entry: key + blockptr + generation.

**`struct btrfs_item`** — leaf node descriptor: key + offset-from-end + size.

**`struct extent_buffer`** (`fs/btrfs/extent_io.h`) — in-memory wrapper for a B-tree node; backed by folios; carries reference count and RW lock.

**`struct btrfs_path`** (`fs/btrfs/ctree.h`) — per-operation traversal cursor: `nodes[]` + `slots[]` arrays for each level from root to leaf.

**`struct btrfs_root`** (`fs/btrfs/ctree.h`) — in-memory handle for one B-tree: root block pointer, root item, commit root, object ID.

## Key Functions / Entry Points

**`btrfs_search_slot(trans, root, key, path, ins_len, cow)`** (`fs/btrfs/ctree.c`) — core lookup: descends tree from root to leaf, placing extent buffer pointers + slot indices into `path`; `ins_len > 0` triggers CoW for write operations.

**`btrfs_insert_item(trans, root, key, data, data_size)`** (`fs/btrfs/ctree.c`) — insert a new item; calls `btrfs_search_slot` then `btrfs_setup_item_for_insert`.

**`btrfs_del_item(trans, root, path)`** (`fs/btrfs/ctree.c`) — delete item at current path position.

**`btrfs_cow_block(trans, root, buf, parent, parent_slot, cow_ret)`** (`fs/btrfs/ctree.c`) — copy-on-write a single node; allocates new extent, copies content, updates parent pointer.

**`btrfs_read_node_slot(eb, slot)`** (`fs/btrfs/ctree.c`) — read the child extent_buffer for a given key-ptr slot in an internal node.

**`btrfs_init_new_buffer(trans, root, bytenr, level, owner)`** (`fs/btrfs/ctree.c`) — allocate and initialise a new tree node.

## Important Flags & Config Options

| Flag / Feature | Meaning |
|----------------|---------|
| `BTRFS_FEATURE_INCOMPAT_EXTENT_TREE_V2` | Use per-block-group extent trees (global roots) |
| `BTRFS_FEATURE_COMPAT_RO_FREE_SPACE_TREE` | Use free space tree v2 (default in modern kernels) |
| `BTRFS_FEATURE_INCOMPAT_METADATA_UUID` | Separate UUID for metadata |
| `BTRFS_CSUM_TYPE_CRC32` / `_XXHASH` / `_SHA256` / `_BLAKE2` | Checksum algorithm for checksum tree |
| `max_inline=N` | Max file data stored inline in filesystem tree leaf (default 2048 bytes) |

## Interactions with Other Subsystems

- **→ [[Btrfs Transaction Model]]**: every tree modification is part of a transaction; CoW block allocation is recorded in the transaction's modified extents; the transaction commit atomically updates all tree roots.
- **→ [[Btrfs Subvolumes and Snapshots]]**: each subvolume is a separate filesystem tree; snapshots share extent buffer blocks with the original via reference counting in the extent tree.
- **→ [[Btrfs RAID and Multi-Device Support]]**: the chunk tree maps logical stripes to physical device locations; RAID profiles are encoded in chunk items.
- **→ [[Btrfs Checksumming and Data Integrity]]**: the checksum tree stores per-block CRC32c (or stronger) checksums; `btrfs_verify_data_checksum()` looks up the checksum tree on every read.
- **→ [[Address Space]]**: `btrfs_get_extent()` walks the filesystem tree's `EXTENT_DATA_KEY` items to translate file offsets to logical addresses, which the chunk tree then maps to physical I/O.

## Design Decisions & Tradeoffs

**Single node format for all tree types**: Using identical on-disk format (header + key-ptr array or header + item array) for every tree allows a single set of B-tree manipulation functions. The alternative — specialised node formats per tree type — would have allowed tighter packing but would require maintaining N independent implementations.

**Back-references in extent items**: Traditional filesystems (ext2, ext3) track space usage only forward (inode → block) and have no reverse map. Btrfs's explicit back-references in the extent tree enable O(log n) per-extent reverse lookup. The cost is larger extent tree items and more writes per operation. The payoff: `btrfs device remove` relocates all extents on a device without scanning the entire filesystem, and `btrfs scrub` can identify *which file* owns a corrupted block.

**CoW vs. journal**: A journal (WAL) modifies blocks in place and writes a log for crash recovery. CoW never modifies an existing block; every write allocates new space. CoW is simpler to reason about (no redo/undo logic), naturally enables snapshots, and eliminates the journaling overhead. The cost is write amplification (log-n new blocks per modification) and fragmentation over time (addressed by balance).

**Multiple trees vs. single tree**: Having one giant tree for all metadata would simplify the root-of-roots structure but would create contention: concurrent transactions on different subvolumes, concurrent checksum writes, and space allocation would all serialize on a single tree root lock. Separate trees allow independent locking and concurrent transaction participation.

## How It Has Evolved

- **2.6.29** (2009): Initial Btrfs merge; root, extent, chunk, filesystem, and checksum trees present.
- **3.2** (2012): Extent item format changed to reduce size (`BTRFS_METADATA_ITEM_KEY`).
- **3.9** (2013): Free space tree v2 proposed (free_space_tree feature flag).
- **5.x**: Free space tree enabled by default on newly created filesystems; block group tree patchwork.
- **6.1** (2022): Extent tree v2 / global roots feature (`EXTENT_TREE_V2`): multiple per-block-group extent trees to reduce contention and improve parallel allocation.

## Further Reading

1. [A short history of btrfs — LWN.net](https://lwn.net/Articles/342892/)
2. [Btrfs design documentation — archive.kernel.org](https://archive.kernel.org/oldwiki/btrfs.wiki.kernel.org/index.php/Btrfs_design.html)
3. [Understanding btrfs internals part 3 — dxuuu.xyz](https://dxuuu.xyz/btrfs-internals-3.html)
4. [Btrfs extent tree v2 — LWN.net](https://lwn.net/Articles/878790/)

## LKML Highlights

- **Extent tree v2 (global roots)** — Josef Bacik (2021–2022): The original single extent tree became a scalability bottleneck for large filesystems (hundreds of millions of extents) because all allocation operations serialised on its root lock. Global roots create per-block-group extent trees, allowing parallel allocation in separate block groups. The review debate centred on the migration path and whether existing features (balance, qgroups) could be disabled without breaking user expectations.
- **Free space tree v2** — Josef Bacik (2015): The v1 free space cache stored free-space metadata as a special file in the filesystem tree — leading to a chicken-and-egg bootstrap problem on mount (need free space to write the cache but need the cache to find free space). The v2 free space tree is a proper B-tree rooted in the root tree, resolving the bootstrap issue and enabling crash-consistent free space tracking.
