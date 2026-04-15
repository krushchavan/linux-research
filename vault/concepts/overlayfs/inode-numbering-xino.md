---
title: "OverlayFS Inode Numbering (xino)"
category: concept
tags: [overlayfs, filesystem, inode, st_ino, containers, xino]
subsystem: overlayfs
kernel_version: "4.17"
researched: 2026-04-15
status: complete
sources:
  - https://kernel-internals.org/filesystems/overlayfs/
  - https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
  - https://github.com/torvalds/linux/blob/master/fs/overlayfs/inode.c
---

# OverlayFS Inode Numbering (xino)

## Purpose

By default, overlayfs assigns `st_ino` values arbitrarily — an upper-layer file gets its inode number from the upper filesystem, a lower-layer file gets its number from whichever lower filesystem it lives on. Because different filesystems have independent inode number spaces, two files from different layers can accidentally share the same `st_ino`, or the same file's `st_ino` can change across remounts. The `xino` (cross-filesystem inode numbering) feature composes globally unique, stable inode numbers by encoding a per-filesystem ID into the high bits of each real inode number.

## Mental Model

Imagine each underlying filesystem as a department in a company, each issuing its own employee badge numbers starting from 1. Without coordination, two employees from different departments can have badge 42. The xino scheme is like adding a department prefix: department 1 issues badges 1-00001, 1-00002, …; department 2 issues 2-00001, 2-00002, …. Numbers never collide, and anyone holding a badge can tell at a glance which department it came from.

## How It Works

Each underlying filesystem that contributes to the overlay is assigned a small integer *fsid* at mount time. The fsid is recorded in `ovl_layer.fsid` for each entry in `ovl_fs.layers[]`.

For any real inode with number `real_ino` from a filesystem with id `fsid`, the synthetic `st_ino` exposed by the overlay is:

```
synthetic_ino = (fsid << high_bit_shift) | (real_ino & low_bit_mask)
```

The `high_bit_shift` is chosen so that the upper `log2(max_fsid)` bits of the 64-bit inode number space carry the fsid, and the lower bits carry the real inode number. Most filesystems leave the high bits of their inode numbers unused — ext4, xfs, and btrfs all fit comfortably in the low 48 bits — so the encoding is lossless for practical filesystem sizes.

If any filesystem has real inode numbers so large that they would overflow the lower bits (i.e., they already use the bits reserved for the fsid prefix), xino silently falls back to non-unique numbering for those particular inodes and emits a kernel warning. This is a graceful degradation rather than a hard failure.

**Single-filesystem optimisation**: If all layers reside on the same underlying filesystem, all inodes are already globally unique by real number — no encoding is needed. `xino=auto` detects this case and enables xino implicitly with zero overhead. This is the common case for development environments where upper and lower layers are both on the same host filesystem.

**Stable across remounts**: Because the fsid is derived from stable filesystem properties (device number, UUID) rather than from mount order, the same `st_ino` values are produced on every mount. Applications that cache `(st_dev, st_ino)` pairs — such as `find -samefile`, rsync, backup software — can rely on these being consistent across container restarts.

`ovl_assign_ino()` in `fs/overlayfs/inode.c` is called when an overlay inode is first instantiated. It determines whether xino is active for the layer and either returns the real inode number directly or computes the encoded form. The result is stored in `ovl_inode.vfs_inode.i_ino`.

## Key Data Structures

**`struct ovl_layer`** (`fs/overlayfs/ovl_entry.h`) — per-layer metadata including the fsid.
- `fsid` — small integer assigned at mount time; 0 for the upper layer

**`struct ovl_inode`** (`fs/overlayfs/ovl_entry.h`) — per-inode overlay state; `vfs_inode.i_ino` holds the xino-encoded inode number after `ovl_assign_ino()` runs.

## Key Functions / Entry Points

**`ovl_assign_ino()`** (`inode.c`) — called when creating an overlay inode; encodes fsid into the inode number if xino is active for the layer.

**`ovl_map_ino()`** (`inode.c`) — translates a real inode number to its xino-encoded form given an fsid; pure arithmetic, no I/O.

**`ovl_get_fsid()`** (`super.c`) — assigns or retrieves the fsid for a given underlying filesystem; called during mount when each layer is registered.

## Important Flags & Config Options

- `xino={on|auto|off}` — mount option controlling xino behaviour
  - `on`: always encode; fails with EINVAL if any filesystem's inode numbers are too large
  - `auto`: enable only if all layers share the same underlying filesystem (or if all filesystems support file handles and have compatible inode sizes); gracefully degrade otherwise
  - `off`: disable; inodes get raw numbers from their respective filesystems, collisions possible
- `CONFIG_OVERLAY_FS_XINO_AUTO` — sets `xino=auto` as the compile-time default

## Interactions with Other Subsystems

- **↑ Userspace**: Transparent — `stat(2)` returns the encoded `st_ino`; tools that compare `(st_dev, st_ino)` pairs work correctly across containers and remounts
- **→ [[vfs]]**: The encoded `st_ino` is set directly on `vfs_inode.i_ino`; VFS propagates it to `stat(2)` without further transformation
- **← [[index]]**: The `index` feature (hard-link preservation) uses NFS file handles for a related but separate purpose; both features co-exist because xino addresses `stat(2)` visibility while index addresses inode identity across copy-up

## Design Decisions & Tradeoffs

**High-bit encoding vs. a separate lookup table** — A hash table mapping overlay inodes to unique IDs would be simpler to reason about but would require kernel memory proportional to the number of live inodes and would not survive remounts. The bit-encoding approach is O(1), stateless, and remount-stable, at the cost of restricting how many distinct filesystems an overlay can span (a practical limit of around 16–64 layers is far more than any real workload uses).

**Graceful fallback for large inode numbers** — Failing hard on inode-number overflow would make xino unusable on filesystems with large inode numbers. The graceful fallback (non-unique numbering for overflow inodes + warning) trades strict correctness for availability. In practice, overflows only happen on filesystems with billions of files — uncommon in container base images.

**`xino=auto` as the default** — Making the optimisation automatic for the single-filesystem case means most developers never need to think about xino. The explicit `on` and `off` modes exist for operators who need predictability across diverse layer configurations.

## How It Has Evolved

- **4.17**: `xino` feature merged; `xino={on|auto|off}` mount option; single-filesystem auto-detect
- **4.19**: xino interoperates with multiple lower layers; `ovl_layer.fsid` extended to cover each lower layer separately
- **5.x**: Integration with `index` feature: file handles used by index encode both inode identity and fsid for remount stability
- **6.x**: `CONFIG_OVERLAY_FS_XINO_AUTO` changed to default-on in most distribution configs

## Further Reading

1. [Overlay Filesystem — kernel.org documentation](https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html) — `xino` mount option reference
2. [kernel-internals.org: OverlayFS](https://kernel-internals.org/filesystems/overlayfs/) — explains xino in the context of container restart stability

## LKML Highlights

- **`xino` introduction (2018)**: `[PATCH v3 0/9] ovl: constant and unique d_ino across copy up and layer boundaries` by Amir Goldstein — the central debate was whether to always encode (risking EINVAL on large-inode filesystems) or to auto-detect; the `auto` mode was the compromise.
