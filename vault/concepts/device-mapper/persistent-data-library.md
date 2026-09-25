---
title: "Persistent Data Library"
category: concept
tags: [device-mapper, metadata, btree, transaction, thin-provisioning, block]
subsystem: device-mapper
kernel_version: "3.2"
researched: 2026-04-18
status: complete
explained: "[[persistent-data-library-explained]]"
sources:
  - https://static.lwn.net/kerneldoc/admin-guide/device-mapper/persistent-data.html
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/thin-provisioning.html
---

# Persistent Data Library

> 📘 Plain-language version: [[persistent-data-library-explained]]

## Overview

The persistent-data library (`drivers/md/persistent-data/`) provides a shared, transactional metadata framework for device-mapper targets that need to persist complex data structures on block devices. Before its introduction in Linux 3.2 alongside thin provisioning, every target (snapshot, mirror) implemented its own on-disk metadata format. The library consolidates B-tree operations, transaction management, space allocation, and buffer caching into a single reusable stack.

## How It Works

The library is structured as three cooperating layers, each building on the one below.

### Block Manager (bottom layer)

`dm-block-manager.c` is the lowest level. It maintains a fixed-size block cache on a metadata block device, with per-block read/write locking. A caller obtains a `dm_block *` with `dm_bm_read_lock()` or `dm_bm_write_lock()`, reads or modifies the block's data, then releases it with `dm_bm_unlock()`. The block manager enforces that no two writers hold the same block simultaneously, and that readers and writers don't overlap.

Most clients never touch the block manager directly; the transaction manager wraps it with copy-on-write semantics.

### Transaction Manager

`dm-transaction-manager.c` enforces copy-on-write (COW) semantics on top of the block manager. The rule is simple: you can only write to a block if you either (a) freshly allocated it in the current transaction or (b) shadowed it — that is, you created a new copy and will modify the copy, leaving the original untouched.

`dm_tm_shadow_block(tm, original, shadow)` is the shadow operation. It allocates a new block, copies the original's content into it, and returns a write-locked handle to the new block. The original block's reference count is decremented; if it reaches zero, it will be freed when the transaction commits. Shadowing is elided within the same transaction: if you shadow a block you already allocated or shadowed this transaction, the transaction manager returns the same block again without double-allocating.

A `dm_tm_commit(tm, superblock)` call flushes all written blocks to storage, then atomically updates the metadata device's superblock. This is the only point at which the on-disk state advances. If power is cut at any earlier point, the on-disk state remains at the previous commit; the in-progress shadow blocks are simply abandoned and their space is reclaimed during the next mount's repair pass.

### Space Maps

Two space map implementations handle block reference counting and allocation:

**`dm_sm_disk`** — a simple, flat array used for data devices (the pool of blocks handed to thin-provisioned LVs). Allocation is cheap: find the next free bit, return the block number.

**`dm_sm_metadata`** — a self-describing space map for the metadata device itself. It must track its own blocks inside the space it manages, which creates a recursive dependency. To avoid infinite regress, the metadata space map uses a B-tree internally, and that B-tree's blocks are tracked by a simpler auxiliary structure. Growing the metadata space map updates the B-tree, which updates the auxiliary structure — carefully ordered to remain crash-consistent.

Both space maps are reference-counted: `dm_sm_inc_block()` and `dm_sm_dec_block()` allow the thin-pool to implement snapshot COW correctly. When a snapshot is taken, the physical block shared between the snapshot and origin has its reference count incremented. Writes to either must shadow the block first; the reference count drops back to 1 when only one mapping holds it.

### B+ Tree

`dm-btree.c` is the primary key-value store. Keys are 64-bit integers; values are fixed-length byte arrays of caller-specified size. Nesting is explicit: you can specify a multi-level tree where values at each level are B-tree root block numbers rather than data, enabling arbitrary-depth lookups.

Thin provisioning's mapping metadata is a two-level nested B-tree:
- **Outer tree**: maps `device_id` (thin LV identifier) → root block of inner tree
- **Inner tree**: maps `virtual_block_number` → `physical_block_number`

A read of virtual block V on device D becomes: look up D in the outer tree → get inner-tree root → look up V in inner tree → get physical block. Both lookups traverse a COW B-tree whose nodes are managed by the transaction manager, so the full mapping is crash-consistent.

All B-tree modifications (insert, delete, update) use the shadow operation internally: the path from root to the modified leaf is shadowed, resulting in a new root block per commit. Old roots remain on disk until the transaction manager decrements their reference counts.

## Key Data Structures

- `struct dm_block_manager` — cache + locking for metadata blocks
- `struct dm_transaction_manager` — COW enforcement + commit logic
- `struct dm_space_map` — allocation interface (two implementations: disk, metadata)
- `struct dm_btree_info` — describes a tree: levels, value size, comparison and copy functions

## Key Functions

- `dm_block_manager_create(bdev, block_size, max_held_per_writer)` — create block manager
- `dm_tm_create(bm, superblock_location)` — wrap a block manager with a transaction manager
- `dm_tm_commit(tm, sb_block)` — flush and update superblock atomically
- `dm_tm_shadow_block(tm, orig, vt, shadow_out)` — COW a block for modification
- `dm_btree_insert(info, root, keys, value, new_root_out)` — insert/update in tree
- `dm_btree_lookup(info, root, keys, value_out)` — read from tree
- `dm_btree_remove(info, root, keys, new_root_out)` — delete from tree
- `dm_sm_new_block(sm, block_out)` — allocate one block via space map

## Design Decisions

**Single B-tree implementation for all targets** — before 3.2, dm-snapshot had its own exception store format, mirror had its log format, and each was independently buggy. The persistent-data library provides one well-tested transaction model. Targets that adopt it (thin, cache, era) benefit from years of correctness work without implementing their own COW semantics.

**Reference-counted blocks** — reference counting is more expressive than a simple allocated/free bitmap. It allows shared physical blocks between snapshots at no extra cost: the space map holds the reference count, and only when the count reaches zero is the physical block freed.

## Interactions

- **[[dm-bufio]]**: `dm-bufio` is an alternative simpler buffer cache used by dm-integrity; the persistent-data library uses its own block manager (not dm-bufio) for heavier workloads
- **[[target-framework]]**: thin, cache, and era targets create a persistent-data stack in their constructors
- **[[block]]**: the metadata device is itself a block device accessed via the block manager
