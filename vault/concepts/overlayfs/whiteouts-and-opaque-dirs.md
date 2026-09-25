---
title: "OverlayFS Whiteouts and Opaque Directories"
category: concept
tags: [overlayfs, filesystem, union-mount, deletion, containers]
subsystem: overlayfs
kernel_version: "3.18"
researched: 2026-04-15
status: complete
explained: "[[whiteouts-and-opaque-dirs-explained]]"
sources:
  - https://kernel-internals.org/filesystems/overlayfs/
  - https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
  - https://github.com/torvalds/linux/blob/master/fs/overlayfs/dir.c
  - https://github.com/torvalds/linux/blob/master/fs/overlayfs/namei.c
---

# OverlayFS Whiteouts and Opaque Directories

> 📘 Plain-language version: [[whiteouts-and-opaque-dirs-explained]]

## Purpose

Because lower layers in overlayfs are immutable, it is impossible to physically delete a file from them. Yet from the overlay's perspective, the file must disappear from the merged view. Whiteouts and opaque directory markers are the mechanism that makes deletion and directory replacement work without ever modifying a lower layer — they are shadow entries in the upper layer that override lower content.

## Mental Model

Imagine a whiteboard covered in permanent marker drawings (the lower layer). You cannot erase permanent marker. Instead, you stick white paper patches (whiteouts) over the drawings you want to hide. From a distance the patch is invisible — the drawing underneath has simply ceased to exist. When you cover an entire region with a fresh blank sheet (an opaque directory), nothing from the original drawing beneath that region shows through at all.

## How It Works

### Whiteouts — Hiding a File or Directory

When `unlink()` or `rmdir()` is called on a path that exists only in a lower layer, overlayfs cannot modify that layer. Instead, `ovl_create_whiteout()` (in `fs/overlayfs/dir.c`) creates a *whiteout entry* in the upper layer at the same path.

A whiteout has one of two physical forms depending on the underlying upper filesystem:

- **Character device 0:0**: the traditional Unix representation; a character special file with major:minor = 0:0. It is cheap to create on all filesystems.
- **Regular file + `trusted.overlay.whiteout` xattr**: used when the upper filesystem does not support character devices (e.g., some network filesystems). The zero-size file is otherwise unremarkable; it is identified as a whiteout only by the presence of the xattr.

During path lookup, `ovl_lookup_single()` in `namei.c` checks each name it encounters. If it finds a character device with device number 0:0, or a regular file bearing `trusted.overlay.whiteout`, it treats that entry as a whiteout and immediately returns ENOENT — it does not continue looking in lower layers. From the caller's perspective the file simply does not exist.

### Opaque Directories — Hiding an Entire Directory Tree

Deleting and recreating a directory poses a harder problem: if the new upper-layer directory does not hide the original lower-layer directory, the lower directory's children bleed through into the merged view as phantom entries that the user thought were deleted.

When overlayfs copies up a directory (as part of copying up a child), it sets the `trusted.overlay.opaque="y"` xattr on the upper-layer directory. This *opaque* marker tells `ovl_lookup()` that when entering this directory it should not descend into any lower layers for additional content. The lower directory's children become invisible.

The same marker is set when a directory is `rmdir()`d and then recreated via `mkdir()`: overlayfs creates a fresh upper directory with `trusted.overlay.opaque="y"`, ensuring the old lower content stays hidden.

### The Opaque Hint Xattr

A third xattr, `trusted.overlay.opaque="x"` (the "impure" flag), is a performance optimisation. Without it, overlayfs would have to scan every directory's upper-layer children on each lookup to detect whether any of them are whiteouts. The impure flag is set on a directory whenever a whiteout child is created inside it. On subsequent lookups, overlayfs checks the flag: if absent, it skips the whiteout scan entirely; if present, it performs the scan. This bounds the cost of the lookup to directories that actually contain whiteouts.

### Unprivileged Mounts

Privileged overlay mounts use the `trusted.*` xattr namespace. For unprivileged user-namespace mounts (enabled by the `userxattr` mount option, added in 5.11), the same mechanism uses `user.overlay.*` xattrs instead. The logic is identical; only the xattr prefix differs. Because `user.*` xattrs are accessible to unprivileged users, overlayfs takes care to prevent privilege escalation: only the overlay kernel code itself reads and interprets these xattrs — they are never passed through to userspace as-is.

## Key Data Structures

**Whiteout** — not a kernel struct; physically either a `(S_IFCHR, dev_t 0:0)` inode or a zero-size regular file with `trusted.overlay.whiteout` xattr in the upper layer.

**Opaque directory** — not a separate struct; an upper-layer directory dentry decorated with the `trusted.overlay.opaque="y"` or `"x"` xattr. Detected at lookup time via `ovl_check_dir_xattr()`.

## Key Functions / Entry Points

**`ovl_create_whiteout()`** (`dir.c`) — called from `ovl_unlink()` and `ovl_rmdir()`; creates the whiteout entry in the upper layer.

**`ovl_is_whiteout()`** (`namei.c`) — tests whether a dentry is a whiteout (character device 0:0 or `trusted.overlay.whiteout` xattr present).

**`ovl_lookup_single()`** (`namei.c`) — core name resolution; stops lookup and returns ENOENT on whiteout; stops lower-layer descent on opaque directory.

**`ovl_check_dir_xattr()`** (`namei.c`) — reads the `trusted.overlay.opaque` xattr from a directory dentry and returns the opaque/impure flag value.

**`ovl_set_opaque()`** (`dir.c`) — sets `trusted.overlay.opaque="y"` on an upper-layer directory; called during copy-up of opaque directories and during directory recreation.

**`ovl_set_impure()`** (`dir.c`) — sets `trusted.overlay.opaque="x"` on an upper-layer directory when a whiteout child is added to it.

## Important Flags & Config Options

- `userxattr` — mount option (5.11+); switches all overlay xattrs from `trusted.overlay.*` to `user.overlay.*` to enable unprivileged mounts
- No separate Kconfig symbol; whiteout/opaque support is always compiled in with `CONFIG_OVERLAY_FS`
- The upper filesystem must support the `trusted.*` (or `user.*`) xattr namespace; filesystems that do not (e.g., FAT) cannot be used as an upper layer

## Interactions with Other Subsystems

- **↑ Userspace**: Whiteouts are completely transparent — userspace sees ENOENT as if the file were genuinely absent; opaque dirs appear as normal empty directories
- **→ [[vfs]]**: `ovl_create_whiteout()` calls `vfs_mknod()` or `vfs_create()` + `vfs_setxattr()` on the upper layer; all xattr operations go through VFS
- **← [[security]]**: LSM hooks fire on the whiteout creation (`security_inode_mknod()`) and on xattr writes; SELinux labels the whiteout inode according to the type transition rules for the parent directory

## Design Decisions & Tradeoffs

**Character device 0:0 as whiteout representation** — This convention was inherited from unionfs and AUFS. The choice is somewhat arbitrary but has the advantage that it is cheap to create (no data, minimal metadata) and unambiguous — no real file system would create a 0:0 device for any other purpose. The xattr-based fallback was added later to support network filesystems as upper layers.

**Opaque xattr instead of directory scanning** — An alternative design would scan every lower-layer directory on every lookup. The xattr approach moves the cost to write time (creating a whiteout sets the impure xattr on the parent) rather than read time. For read-heavy container workloads, this is a large win: most directories are clean and the scan is skipped entirely.

**`trusted.*` namespace for xattrs** — Using `trusted.*` xattrs means that only privileged processes (with `CAP_SYS_ADMIN`) can read or write these xattrs, which prevents unprivileged processes from forging whiteouts on the upper filesystem. The `userxattr` (unprivileged) mode had to carefully restrict which processes can influence the xattr values to avoid privilege escalation.

## How It Has Evolved

- **3.18**: Whiteouts and opaque directories present from the initial merge; character device 0:0 form
- **4.19**: Impure xattr (`trusted.overlay.opaque="x"`) added to avoid directory-wide whiteout scans; `redirect_dir` feature interacts with opaque directories
- **5.11**: `userxattr` mount option: `user.overlay.*` namespace for unprivileged mounts; same whiteout logic, different xattr prefix
- **5.15**: Xattr fallback (`trusted.overlay.whiteout`) added for upper filesystems that do not support device files

## Further Reading

1. [Overlay Filesystem — kernel.org documentation](https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html) — covers whiteout behaviour and the opaque xattr semantics
2. [kernel-internals.org: OverlayFS](https://kernel-internals.org/filesystems/overlayfs/) — container-focused deep dive including whiteout creation scenarios
3. [Unioning file systems — LWN.net (2009)](https://lwn.net/Articles/324291/) — historical context on the whiteout convention from earlier union filesystem designs

## LKML Highlights

- **Impure xattr optimisation (2018)**: `[PATCH] ovl: set opaque flag on directories that may contain whiteouts` — Amir Goldstein introduced the impure hint to avoid scanning clean directories; the thread debated whether the overhead was measurable in practice.
- **`userxattr` feature (2020)**: `[PATCH v3 0/8] overlayfs: unprivileged mounts` — extended discussion of the security model needed to safely use `user.*` xattrs for whiteouts without enabling privilege escalation through crafted xattrs.
