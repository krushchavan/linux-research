---
title: "Btrfs Balance and Device Management"
category: concept
tags: [btrfs, balance, device-management, chunk-relocation, multi-device, raid]
subsystem: btrfs
kernel_version: "2.6.29 (multi-device); balance filters 3.3; device replace 3.9"
researched: 2026-04-11
status: complete
sources:
  - https://lwn.net/Articles/437883/
  - https://lwn.net/Articles/577961/
  - https://lwn.net/Articles/524589/
  - https://man.archlinux.org/man/btrfs-balance.8.en
  - https://github.com/torvalds/linux/blob/master/fs/btrfs/volumes.c
  - https://github.com/torvalds/linux/blob/master/fs/btrfs/dev-replace.c
  - https://kernel-internals.org/filesystems/btrfs/
---

# Btrfs Balance and Device Management

## Purpose

Btrfs separates the act of adding/removing devices from the act of redistributing data across them. When a device is added, new writes begin landing on it but existing data stays where it was; the **balance** operation is the mechanism that physically moves block groups across devices to achieve the layout the administrator actually wants. Without balance, adding a device to reduce storage load would have no effect on existing data, removing a device would be impossible, and changing a RAID profile (e.g. from `single` to `RAID1`) would require a full filesystem migration.

Device management (add, remove, replace) and balance are also the kernel's hooks for online growth, shrink, and fault tolerance without unmounting.

## Mental Model

Think of balance as a **chunk relocator with a filter front-end**. The filesystem's data and metadata are organised into block groups, each backed by a chunk that maps a logical address range to physical stripes on one or more devices. Balance iterates every block group in the filesystem, applies a set of filters to decide whether this particular block group should be moved, and if so calls the chunk relocator: write the block group's contents to a freshly allocated chunk somewhere else, update the chunk tree, then delete the old chunk. The old device extents are thereby freed.

Device add, remove, and replace are special cases of this pattern: adding a device makes its space available for future chunk allocation; removing a device triggers a balance restricted to that device's chunks; replace copies chunks to a new device in the background while normal IO continues.

All three operations are **mutually exclusive**: only one of {balance, device add/remove, device replace} may run at a time, enforced by the `exclusive_operation` atomic in `btrfs_fs_info`.

## How It Works

### The Exclusive Operation Lock

Before any device management operation starts, the kernel calls `btrfs_exclop_start(fs_info, op)`, which does a `cmpxchg` on `fs_info->exclusive_operation`. If another operation is already set, the call fails with `-EBUSY`. This prevents, for example, a balance from running while a device replace is in progress — the two would fight over which physical device chunks should end up on. On completion (or cancellation), `btrfs_exclop_finish()` clears the field.

The locking hierarchy for device operations is:
```
uuid_mutex → device_list_mutex → chunk_mutex → balance_mutex
```

### Balance: Chunk Relocation

**Entry point**: `btrfs_balance(fs_info, bargs, bctl)` in `fs/btrfs/balance.c` (kernels post-5.x; formerly in `volumes.c`).

Balance begins by loading all block groups into a list (iterating `fs_info->block_group_cache_tree`). For each block group it calls the filter chain. If the block group passes the filters, `btrfs_relocate_chunk()` is invoked:

1. **Mark the block group read-only**: set `BTRFS_BLOCK_GROUP_FLAG_RELOCATING`. New COW writes avoid it.
2. **Create a relocation inode**: `btrfs_relocate_block_group()` creates a special in-memory inode whose data pages are backed by the block group's extents. File extents are created pointing to every extent inside the block group.
3. **Write the relocation data**: the inode's pages are dirtied and written back through normal writeback. Because the block group is read-only for new allocations, writeback allocates new extents in other block groups.
4. **Update back-references**: `btrfs_finish_one_extent()` rewrites each extent reference in the extent tree to point to the new physical location.
5. **Delete the old chunk**: once all extents have been relocated and references updated, the old chunk item is removed from the chunk tree and device extents are freed to the device allocator.

This sequence is crash-safe: if the filesystem is remounted mid-balance, the balance state is stored in a `BTRFS_BALANCE_ITEM_KEY` in the root tree. At the next mount, the kernel checks for this item and either resumes (if the same filters were in use) or marks the balance as interrupted (requiring explicit `btrfs balance resume`).

**Background execution**: balance runs in a kernel thread (`balance_kthread`) so the ioctl call returns immediately after starting. Progress is tracked in `btrfs_balance_control.stat` (block groups left / total) and exported via the `BTRFS_IOC_BALANCE_PROGRESS` ioctl.

**Cancellation**: `BTRFS_IOC_BALANCE_CANCEL` sets `BTRFS_BALANCE_STATE_CANCEL_REQ` in `bctl->flags`. The chunk relocation loop checks this flag after each block group and exits cleanly if set. Since 5.7, the check interval was tightened so cancellation responds within seconds rather than waiting for a full chunk relocation to complete.

#### Balance Filters

The user-facing `btrfs balance start -d<filters> -m<filters> -s<filters>` maps to `struct btrfs_balance_args` — one per block group type (data/metadata/system) in `struct btrfs_ioctl_balance_args`. Each `btrfs_balance_args` carries a `profiles` bitmask and an `flags` field selecting which filters are active:

| Filter | Flag | Semantics |
|--------|------|-----------|
| `usage=N` | `BTRFS_BALANCE_ARGS_USAGE` | Relocate block groups used at most N%. `usage=0` reclaims empty BGs. |
| `usage=min..max` | `BTRFS_BALANCE_ARGS_USAGE_RANGE` | Range form; useful for targeted defragmentation of fragmented BGs. |
| `devid=N` | `BTRFS_BALANCE_ARGS_DEVID` | Only relocate BGs with at least one stripe on device N. Used by `device delete`. |
| `drange=start..end` | `BTRFS_BALANCE_ARGS_DRANGE` | Physical byte range on any device; move BGs overlapping this range. Used by shrink/resize. |
| `vrange=start..end` | `BTRFS_BALANCE_ARGS_VRANGE` | Logical address range of the block group itself. |
| `limit=N` | `BTRFS_BALANCE_ARGS_LIMIT` | Process at most N block groups this run. Safe way to run balance incrementally. |
| `limit=min..max` | `BTRFS_BALANCE_ARGS_LIMIT_RANGE` | Range form. |
| `stripes=min..max` | `BTRFS_BALANCE_ARGS_STRIPES_RANGE` | Number of stripes in the block group; relevant for RAID profiles. |
| `profiles=flags` | `BTRFS_BALANCE_ARGS_PROFILES` | Pipe-separated profile set: only balance BGs matching these profiles. |
| `convert=profile` | `BTRFS_BALANCE_ARGS_CONVERT` | Re-encode relocated BGs into the specified profile (RAID conversion). |
| `soft` | `BTRFS_BALANCE_ARGS_SOFT` | With `convert=`: skip BGs already in the target profile. Allows safe resume after interruption. |

The filter evaluation (`should_balance_chunk()`) is applied per block group before committing to relocation. An absent filter means "match all"; multiple filters are ANDed.

#### Key Structs for Balance

```c
/* User ↔ kernel interface (passed via ioctl) */
struct btrfs_ioctl_balance_args {
    __u64 flags;               /* BTRFS_BALANCE_STATE_* and BTRFS_BALANCE_ARG_* */
    struct btrfs_balance_args data;     /* filters for data BGs */
    struct btrfs_balance_args meta;     /* filters for metadata BGs */
    struct btrfs_balance_args sys;      /* filters for system BGs */
    struct btrfs_balance_progress stat; /* progress counters (out) */
};

/* Per-type filter spec */
struct btrfs_balance_args {
    __u64 profiles;     /* bitmask of profiles to match */
    union { __u64 usage; struct { __u32 usage_min; __u32 usage_max; }; };
    __u64 devid;
    __u64 pstart; __u64 pend;  /* drange */
    __u64 vstart; __u64 vend;  /* vrange */
    __u64 target;   /* convert target profile */
    __u64 flags;    /* BTRFS_BALANCE_ARGS_* */
    union { __u64 limit; struct { __u32 limit_min; __u32 limit_max; }; };
    __u32 stripes_min; __u32 stripes_max;
};

/* In-kernel balance state */
struct btrfs_balance_control {   /* lives at fs_info->balance_ctl */
    struct btrfs_balance_args data, meta, sys;
    u64 flags;                   /* BTRFS_BALANCE_STATE_* */
    struct btrfs_balance_progress stat;
    struct task_struct *thread;
    atomic_t threads_running;
};
```

### Device Add

`btrfs device add /dev/sdX /mnt` calls `BTRFS_IOC_ADD_DEV` → `btrfs_init_new_device()` in `volumes.c`:

1. Open the block device and verify it is not already part of a btrfs filesystem (scan its superblock).
2. Allocate a new `struct btrfs_device` and assign a `devid` (next free integer in `fs_devices->num_devices`).
3. Within a transaction, write a `BTRFS_DEV_ITEM_KEY` into the chunk tree for the new device.
4. If this is the filesystem's first second device and metadata is currently `SINGLE` or `DUP`, the kernel automatically allocates a new system chunk on the new device (`btrfs_alloc_new_system_chunk()`).
5. Update `fs_info->fs_devices` to include the new device. From this point, `btrfs_alloc_chunk()` can use the new device for future chunk allocations.

**No immediate data movement occurs.** Existing block groups are not touched; only new chunk allocations (triggered by writes or balance) can land on the new device.

### Device Remove

`btrfs device delete /dev/sdX /mnt` → `BTRFS_IOC_RM_DEV` → `btrfs_rm_device()`:

1. Verify the device can be removed: enough space remains on surviving devices to hold the filesystem's data under the current RAID profile.
2. Mark the device as `BTRFS_DEV_STATE_MISSING` (so no new IO is sent to it).
3. **Implicitly run balance with `-ddevid=N -mdevid=N -sdevid=N`**: all block groups with any stripe on this device are relocated to the remaining devices. This is the expensive part — it can take hours on a full device.
4. Once all chunks are evacuated, remove the `BTRFS_DEV_ITEM_KEY` from the chunk tree in a transaction and close the block device.

The remove operation respects the exclusive operation lock; it cannot proceed if a balance is already running. It also cannot complete if there is not enough space on remaining devices (returns `-ENOSPC`).

Special case: `btrfs device delete missing /mnt` is used when a device has physically failed and is already absent. The filesystem must be mounted with `-o degraded`. The missing device's chunks were already lost (or read from mirrors); the command removes the dead device entry from the chunk tree and requires subsequent balance to rebuild parity or mirrors.

### Device Replace

`btrfs replace start /dev/src /dev/dst /mnt` → `BTRFS_IOC_DEV_REPLACE` → `btrfs_dev_replace_start()` in `dev-replace.c`. Replace is safer than add+remove because it never removes the source device until all data is confirmed on the target:

1. **Initialize target device**: `btrfs_init_dev_replace_tgtdev()` opens the replacement device, validates its size (must be ≥ source device), and allocates a `btrfs_device` for it.
2. **Persist replace state**: a `btrfs_dev_replace_item` is written to the tree of tree roots so the operation survives a crash/reboot.
3. **Dual-write during replace**: the write path in `btrfs_map_block()` calls `handle_ops_on_dev_replace()`. If a write targets a logical address whose stripe lands on the source device, the write is also sent to the corresponding location on the target device. This ensures data written *after* replace started is already on the target.
4. **Copy existing data via scrub**: `btrfs_scrub_dev()` is called to read every existing extent on the source device, verify its checksum, and write it to the target device via `scrub_write_block_to_dev_replace()`. The scrub reads from the *commit root* snapshot so it sees a consistent view of the extent tree.
5. **Finishing** (`btrfs_dev_replace_finishing()`): once the scrub pass completes:
   - Update the chunk mapping tree: replace the source device's entries with the target device (`btrfs_dev_replace_update_device_in_mapping_tree()`).
   - Swap device UUIDs and devids so the target device now logically *is* the old source device.
   - Close and remove the source device.
   - Clear the replace state item from disk.

Device replace is **crash-resumable**: on the next mount, the kernel finds the in-progress replace state item and resumes the scrub from where it left off (scrub tracks progress per device offset).

The `-r` flag to `btrfs replace start` avoids reading from the source device during the copy phase, which is useful when the source is failing and reads might return errors; data is read from mirror copies on other devices instead.

```c
/* Device replace on-disk state */
struct btrfs_dev_replace_item {
    __le64 src_devid;
    __le64 cursor_left;   /* progress: bytes processed on source device */
    __le64 cursor_right;  /* upper bound of the replace scan window */
    __le64 cont_reading_from_srcdev_mode; /* 0 = avoid source, 1 = read from source */
    __le32 replace_state; /* BTRFS_IOCTL_DEV_REPLACE_STATE_* */
    __le64 time_started;
    __le64 time_stopped;
    __le64 num_write_errors;
    __le64 num_uncorrectable_read_errors;
};
```

## Key Data Structures

**`struct btrfs_fs_devices`** (`fs/btrfs/volumes.h`) — runtime container for all devices in a filesystem instance.
- `devices` — list of `btrfs_device` structs
- `num_devices` / `rw_devices` — total and writable device counts
- `missing_devices` — count of absent devices (used to gate degraded-mode decisions)
- `chunk_alloc_policy` — `BTRFS_CHUNK_ALLOC_REGULAR` or `BTRFS_CHUNK_ALLOC_ZONED`
- `rotating` — true if any device has rotational media; affects chunk allocation heuristics

**`struct btrfs_device`** (`fs/btrfs/volumes.h`) — per-device runtime descriptor.
- `devid` — integer device ID, used in chunk tree keys
- `bdev` / `bdev_file` — underlying block device
- `dev_state` — bitmap: `BTRFS_DEV_STATE_WRITEABLE`, `BTRFS_DEV_STATE_IN_FS_METADATA`, `BTRFS_DEV_STATE_MISSING`, `BTRFS_DEV_STATE_REPLACE_TGT`
- `total_bytes` / `bytes_used` — capacity and allocation accounting
- `fs_devices` — back-pointer to the enclosing `btrfs_fs_devices`
- `io_failures` — for automatic device health tracking

**`struct btrfs_balance_control`** (`fs/btrfs/volumes.h`) — in-kernel balance state, stored at `fs_info->balance_ctl`.

**`struct btrfs_dev_replace`** (`fs/btrfs/dev-replace.h`) — in-kernel device replace state.
- `replace_state` — current state: `NEVER_STARTED`, `STARTED`, `SUSPENDED`, `FINISHED`, `CANCELED`
- `srcdev` / `tgtdev` — source and target `btrfs_device` pointers
- `cursor_left` / `cursor_right` — scrub progress window on the source device

## Key Functions / Entry Points

**`btrfs_balance(fs_info, bargs, bctl)`** (`fs/btrfs/balance.c`) — top-level balance entry point; validates filters, spawns `balance_kthread`, returns immediately.

**`balance_kthread(data)`** (`fs/btrfs/balance.c`) — balance worker thread; iterates block groups, applies filters via `should_balance_chunk()`, calls `btrfs_relocate_chunk()`.

**`btrfs_relocate_chunk(fs_info, chunk_offset)`** (`fs/btrfs/volumes.c`) — relocates one block group: marks it read-only, calls `btrfs_relocate_block_group()`, then frees the old chunk.

**`btrfs_relocate_block_group(fs_info, bg)`** (`fs/btrfs/relocation.c`) — moves all extents within a block group to new locations, updating back-references.

**`btrfs_init_new_device(trans, path)`** (`fs/btrfs/volumes.c`) — device add implementation; allocates `btrfs_device`, writes `DEV_ITEM` to chunk tree.

**`btrfs_rm_device(fs_info, bargs, bdev_file)`** (`fs/btrfs/volumes.c`) — device remove; calls balance on the target device, then removes its chunk tree entries.

**`btrfs_dev_replace_start(fs_info, args)`** (`fs/btrfs/dev-replace.c`) — device replace entry; sets up dual-write, starts scrub-based copy.

**`btrfs_dev_replace_finishing(fs_info, scrub_ret)`** (`fs/btrfs/dev-replace.c`) — completes the replace: swaps device identities in the chunk map, removes the source device.

**`handle_ops_on_dev_replace(op, bioc, tgt_dev, dev_index)`** (`fs/btrfs/volumes.c`) — called from the write path during an active replace; duplicates writes destined for the source device onto the target.

**`btrfs_exclop_start(fs_info, op)`** / **`btrfs_exclop_finish(fs_info)`** (`fs/btrfs/fs.h`) — acquire/release the exclusive operation lock (atomic CAS on `fs_info->exclusive_operation`).

## Important Flags & Config Options

| Option / Flag | Effect |
|---|---|
| `BTRFS_IOC_BALANCE_V2` | Main balance ioctl (supersedes V1 which lacked filters) |
| `BTRFS_IOC_BALANCE_CTL` | Pause / resume / cancel a running balance |
| `BTRFS_IOC_BALANCE_PROGRESS` | Query block groups processed / total |
| `BTRFS_IOC_DEV_REPLACE` | Start / status / cancel device replace |
| `BTRFS_IOC_ADD_DEV` / `RM_DEV` | Device add and remove |
| `-o skip_balance` | Mount option: do not auto-resume an interrupted balance; leaves the balance paused |
| `-o degraded` | Mount with a missing device; required before `device delete missing` |
| `BTRFS_DEV_STATE_REPLACE_TGT` | Set on the target device during replace; tells the write path to duplicate writes |
| `BTRFS_BALANCE_STATE_PAUSE_REQ` / `CANCEL_REQ` | Set by ioctl; checked between each block group in the balance loop |

## Interactions with Other Subsystems

- **↑ Userspace**: `btrfs(8)` wraps all balance and device management ioctls. `btrfs balance start/pause/resume/cancel/status` and `btrfs device add/delete/replace` are the primary interfaces.
- **→ [[space-accounting-and-block-groups]]**: balance is the mechanism that reclaims unused block groups (empty ones are the cheapest case: `usage=0`). Chunk relocation temporarily over-reserves space in `space_info` while the old and new chunks both exist. After relocation, the freed device extents are returned to the device allocator, shrinking `space_info->total_bytes` if a device is removed.
- **→ [[raid-and-multi-device-support]]**: balance is the primary online profile conversion tool. The `convert=` filter instructs the chunk relocator to allocate the replacement chunk with a different RAID profile. The chunk tree and device tree are updated atomically within btrfs transactions.
- **→ [[transaction-model]]**: each block group relocation happens inside a separate transaction. This means a crash mid-balance leaves the filesystem consistent: some block groups have been relocated and others have not. The balance state item records progress so work already done is not repeated.
- **→ [[checksumming-and-data-integrity]]**: during device replace, scrub reads every extent, verifies its checksum, and only writes to the target if the data is good. If the source device has an unreadable sector, btrfs tries to read from a mirror (RAID1/RAID10) or reconstruct via parity (RAID5/6) before writing to the target.
- **→ Scrub** (`fs/btrfs/scrub.c`): device replace internally reuses the scrub engine (`btrfs_scrub_dev()` with `is_dev_replace=true`). Scrub and replace cannot run simultaneously on the same device.
- **← Block layer**: device add opens a new `struct block_device` via `btrfs_get_bdev_and_sb()`; device remove closes it via `blkdev_put()`. Replace closes the source device only after the finishing step completes.

## Design Decisions & Tradeoffs

**Balance as a universal data mover**: rather than implementing separate "profile conversion", "device evacuation", and "space rebalancing" codepaths, btrfs uses a single chunk relocation engine with a filter front-end. This is elegant but means even trivial operations (e.g. reclaiming a few empty block groups) go through the full relocation machinery, which has non-trivial overhead. The `limit=N` filter was added specifically to make incremental balance practical.

**Device replace over add+delete**: Device replace was added in 3.9 (2012) because add+delete has a dangerous window: after the old device is removed but before all data has been written to the new device, the filesystem's redundancy is temporarily reduced. Replace maintains the dual-write path throughout, so the source device remains live until the target is fully populated. The trade-off is complexity: the write-path must carry an extra destination for every write during replace.

**Mutual exclusion of device operations**: forcing balance, add/remove, and replace to be mutually exclusive simplifies the chunk tree update logic significantly — the allocator and the relocator do not need to coordinate concurrent chunk-level changes. The cost is that users cannot, for example, run balance and add a device simultaneously. In practice this has not been a reported pain point because device operations are infrequent.

**Balance state persistence**: storing the balance filter state in a tree item (persisted on every commit) allows balance to survive reboots, which is essential for large filesystems where a full balance can take many hours. The alternative — stateless balance that always restarts from scratch — would make balance impractical for production use.

**No background auto-balance**: btrfs does not automatically rebalance after adding a device. Data distribution becomes uneven silently, and users must run balance explicitly. This was a deliberate choice to avoid unexpected IO load; it is also why freshly added devices show 0% usage until balance runs. The `skip_balance` mount option exists for the opposite reason: users who do not want an interrupted balance to auto-resume on next mount.

## How It Has Evolved

- **2.6.29 (2009)**: Multi-device support (add/remove) present at initial merge. Balance existed as a simple "rewrite everything" operation.
- **3.3 (2012)**: Filtered balance ioctl (`BTRFS_IOC_BALANCE_V2`) introduced by Ilya Dryomov. Adds `usage`, `devid`, `drange`, `vrange`, `profiles`, `convert`, `soft` filters and progress monitoring. Previous unfiltered balance (`BTRFS_IOC_BALANCE`) deprecated.
- **3.9 (2013)**: Device replace added by Stefan Behrens. Scrub infrastructure extended to write to a replacement device. `btrfs_dev_replace` state machine introduced.
- **4.x**: Balance state persistence improved; `limit` and `stripes` filters added; balance/replace interaction hardened.
- **5.7 (2020)**: Balance cancellation response time dramatically improved by making the cancel check occur between individual extent relocations rather than between whole block groups.
- **6.0 (2022)**: `send` and relocation (balance, device remove, shrink) can run concurrently for the first time — previously they were also mutually exclusive. This was a significant usability improvement for backup workflows.
- **6.4+ (2023–2024)**: Dynamic block group reclaim uses the relocation mechanism internally for automatic background reclamation of underutilized block groups when `bg_reclaim_threshold` sysfs knob is set.

## Further Reading

1. [btrfs: Balance management — LWN.net](https://lwn.net/Articles/437883/) — patch series description introducing filtered balance; explains the filter design.
2. [Btrfs: Working with multiple devices — LWN.net](https://lwn.net/Articles/577961/) — admin-level walkthrough of device add, remove, replace, and balance workflows.
3. [Btrfs: Add device replace code — LWN.net](https://lwn.net/Articles/524589/) — patch series description for device replace; explains the dual-write mechanism.
4. [btrfs-balance(8) man page — Arch Linux](https://man.archlinux.org/man/btrfs-balance.8.en) — comprehensive reference for all balance filters and operational details.

## LKML Highlights

- **Filtered balance introduction** (Ilya Dryomov, 2012): `[PATCH 0/19] btrfs: filtered balance ioctl` — the thread debated whether filters should be per-type (separate for data/metadata/system) or global; per-type won because profile conversion requires specifying target profiles independently for each block group type.
- **Device replace** (Stefan Behrens, 2012): `[PATCH 00/22] Btrfs: Add device replace code` — discussion centred on the dual-write approach vs. a copy-then-switch approach; dual-write was chosen because it maintains full redundancy throughout and is trivially restartable after a crash.
