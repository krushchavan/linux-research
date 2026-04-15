---
title: "OverlayFS Layer Stack"
category: concept
tags: [overlayfs, filesystem, union-mount, containers, mount-options]
subsystem: overlayfs
kernel_version: "3.18"
researched: 2026-04-15
status: complete
sources:
  - https://kernel-internals.org/filesystems/overlayfs/
  - https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
  - https://github.com/torvalds/linux/blob/master/fs/overlayfs/super.c
---

# OverlayFS Layer Stack

## Purpose

The layer stack is the structural foundation of an overlay mount: it encodes which directories participate in the union, in what order, and which (if any) accepts writes. Without a well-defined stack structure, overlayfs would have no principled way to determine which copy of a file wins when names collide, or where to direct writes so that read-only layers remain untouched.

## Mental Model

Think of the layer stack as a stack of acetate slides on an overhead projector. The topmost slide is the writable upper layer — the only one you can draw on. Below it are one or more read-only lower slides, stacked oldest-first. Looking down through all the slides, you see the union of everything drawn: where the same position is used on multiple slides, the uppermost wins. The original lower slides never change, so any other projector using those same slides shows a different composed picture depending on what is on its own top slide.

## How It Works

The layer stack is assembled at mount time by `ovl_fill_super()` in `fs/overlayfs/super.c`. It parses three mount options — `lowerdir=`, `upperdir=`, and `workdir=` — and builds an `ovl_fs` structure that holds `vfsmount`/`dentry` path references to every participating directory.

**Lower layers** are specified as a colon-separated list in `lowerdir=`. Multiple lower layers are ordered from *most recent* (leftmost) to *oldest* (rightmost), mirroring the image layering model used by OCI container runtimes: the leftmost lower layer corresponds to the topmost container image layer, and the rightmost corresponds to the base image. When a name appears in more than one lower layer, only the leftmost (topmost) match is visible in the merged view.

**Upper layer** (`upperdir=`) is the single writable directory. It is always conceptually above all lower layers. Any write, copy-up result, or whiteout creation lands here. If `upperdir=` is omitted the overlay is read-only — useful for union-mounting several source trees without enabling writes.

**Work directory** (`workdir=`) must reside on the same underlying filesystem as `upperdir`. It provides atomic scratch space: during copy-up, a temporary file is created in `$workdir/work/` and then atomically renamed into the upper layer. The rename is a single atomic directory-entry operation (same filesystem guarantees no cross-device move). On next mount, any orphaned temp files left by a previous crash are cleaned up.

`ovl_parse_opt()` in `params.c` converts the raw mount option strings into an `ovl_config` struct. Validation then ensures that upper and work are on the same filesystem, that no layer is a subtree of another, and that the underlying filesystems meet feature requirements (e.g., xattr support, file-handle support if `index=on` is requested).

The resulting layers are stored in the `layers[]` flexible array inside `struct ovl_fs`, with the upper layer at index 0 and lower layers at indices 1…N. Each entry is an `ovl_layer` holding a reference-counted `vfsmount` and the associated `dentry`. Whenever overlayfs needs to look up or access a real file, it iterates this array from top to bottom until it finds the first layer that contains the name (or exhausts all layers for ENOENT).

**Data-only lower layers** (specified with `::` separator syntax in newer kernels) hold file data but not directory structure. They appear at the bottom of the stack and are only consulted for the data of metacopy files whose metadata lives in a regular lower layer above them — a split useful for advanced containerization where metadata and data storage are on different devices.

## Key Data Structures

**`struct ovl_fs`** (`fs/overlayfs/ovl_entry.h`) — the per-mount superblock private data; holds the complete layer stack.
- `upper_mnt` — `vfsmount` of the upper layer; NULL for read-only overlays
- `workbasedir` / `workdir` — dentries for the work base directory and its `work/` subdirectory
- `layers[]` — flexible array of `ovl_layer`, entry 0 is upper, 1…N are lower
- `numlayer` — total number of layers including upper (if present)
- `numdatalayer` — number of data-only layers at the bottom of the stack
- `config` — `ovl_config` struct holding all parsed mount options

**`struct ovl_layer`** (`fs/overlayfs/ovl_entry.h`) — one entry in the layer array.
- `mnt` — `vfsmount` reference for this layer's filesystem
- `idx` — index in the `layers[]` array; 0 = upper
- `fsid` — per-layer filesystem ID used by xino for inode number encoding

## Key Functions / Entry Points

**`ovl_fill_super()`** (`super.c`) — called by the VFS `get_tree` path; builds `ovl_fs`, validates all layers, and initialises the superblock.

**`ovl_parse_opt()`** (`params.c`) — parses `lowerdir=`, `upperdir=`, `workdir=` strings into `ovl_config`; handles the `lowerdir+` extended API introduced in 6.8.

**`ovl_get_lowerstack()`** (`super.c`) — resolves each colon-separated lower path string to a `(dentry, vfsmount)` pair and populates `layers[]`.

**`ovl_check_layer()`** (`super.c`) — validates that a candidate layer is not a subtree of another layer and that the underlying filesystem supports required features.

## Important Flags & Config Options

- `lowerdir=<path>[:<path>…]` — one or more read-only lower layers, topmost first
- `upperdir=<path>` — writable upper layer; omit for a read-only overlay
- `workdir=<path>` — work directory; must be on the same filesystem as `upperdir`
- `lowerdir+` (fsconfig API, 6.8) — alternative to colon-joining; passes each lower dir as a separate `FSCONFIG_SET_STRING` call, avoiding ambiguity with colons in paths
- `CONFIG_OVERLAY_FS` — compiles the overlayfs module; no per-feature symbol for the layer stack itself

## Interactions with Other Subsystems

- **↑ Userspace**: Mount options are passed via `mount(2)` or the new mount API (`fsopen` + `fsconfig` + `fsmount`); container runtimes use the new API to pass file descriptors as layer specifications (`FSCONFIG_SET_FD`)
- **→ [[vfs]]**: VFS calls `ovl_fill_super()` during mount; overlayfs registers `ovl_super_operations` and holds `vfsmount` references into each layer's filesystem, keeping those mounts alive for the overlay's lifetime
- **← [[security]]**: LSM hooks (`security_sb_mount()`, `security_sb_kern_mount()`) fire during mount validation; SELinux and Smack inspect the layer paths before the overlay is assembled

## Design Decisions & Tradeoffs

**Same-filesystem constraint for upper+work** — Requiring `workdir` and `upperdir` on the same filesystem was a deliberate constraint. The alternative (cross-filesystem copy instead of rename) would have been complex and not atomic. The rename-into-place design is the simplest way to guarantee crash consistency, and the co-location constraint is the price.

**Ordered lower stack vs. true tree merging** — Earlier union filesystem designs (AUFS, UnionFS) tried to merge directories recursively at every level. OverlayFS chose a flat ordered stack and left the recursive merge logic to the `ovl_lookup()` call at each directory level. This simplifies the core structure at the cost of making multi-layer directory merging slightly less general, but it maps cleanly to the container image layering model.

**Read-only overlays** — Supporting overlays without `upperdir` was not in the original design; it was added when operators found it useful for merging source trees read-only (e.g. combining a squashfs root with a tmpfs overlay without exposing write access). The absence of `upper_mnt` is checked throughout the code with `ovl_upper_mnt(ofs)`.

## How It Has Evolved

- **3.18**: Initial design — one upper, one lower, one workdir; all required
- **4.19**: Multiple lower layers added; `lowerdir` option accepts colon-separated list
- **5.11**: `userxattr` support: lower layers may be on filesystems using `user.*` namespace for overlay xattrs, enabling unprivileged mounts
- **6.8**: `lowerdir+` via the `fsconfig` API: layers can be passed as file descriptors or individual strings without escaping colons
- **6.13**: `FSCONFIG_SET_FD` for all layer types: upper, work, and lower layers can now all be specified as open file descriptors

## Further Reading

1. [Overlay Filesystem — kernel.org documentation](https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html) — authoritative reference for all mount options
2. [kernel-internals.org: OverlayFS](https://kernel-internals.org/filesystems/overlayfs/) — container-focused technical deep dive
3. [Unioning file systems — LWN.net (2009)](https://lwn.net/Articles/324291/) — historical context and competing approaches

## LKML Highlights

- **Initial merge (2014)**: `<20140107100516.GB8742@doriath>` — Miklos Szeredi's RFC covering the single-upper/single-lower design; the colon-separated multi-lower syntax came later in response to Docker's need to layer many images
- **Multiple lower layers (2018)**: `[PATCH v3 0/14] overlayfs: multiple lower layers` — added `numlayer` / `numdatalayer` split and the ability to stack more than one read-only layer
