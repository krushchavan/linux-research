---
title: "OverlayFS Directory Merging"
category: concept
tags: [overlayfs, filesystem, union-mount, readdir, containers, dentry]
subsystem: overlayfs
kernel_version: "3.18"
researched: 2026-04-15
status: complete
explained: "[[directory-merging-explained]]"
sources:
  - https://kernel-internals.org/filesystems/overlayfs/
  - https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
  - https://github.com/torvalds/linux/blob/master/fs/overlayfs/namei.c
  - https://github.com/torvalds/linux/blob/master/fs/overlayfs/readdir.c
---

# OverlayFS Directory Merging

> 📘 Plain-language version: [[directory-merging-explained]]

## Purpose

Unlike regular files — where the first layer containing the name wins absolutely — directories with the same name in multiple layers must be *merged*: their contents combined into a single view. Without directory merging, overlayfs could not expose a coherent tree; a directory present in both the upper layer and a lower layer would simply shadow the lower version, hiding all entries that only existed below. Merging is what makes union mounts useful as a layered filesystem.

## Mental Model

Think of each layer as a filing cabinet drawer. A directory named `/etc` might have its own folder in several drawers. When you open the overlay's `/etc` folder, it is as if you emptied all matching drawers into one pile on your desk. If two drawers have a file with the same name, the one from the higher drawer (the upper layer) goes on top and the lower one stays face-down, invisible. Anything in only one drawer shows up in the pile as-is. And if the top drawer has a note saying "destroy this file" (a whiteout), that file from lower drawers is left out of the pile entirely.

## How It Works

### Lookup: resolving a single name

`ovl_lookup()` in `fs/overlayfs/namei.c` is the core function that resolves every name within an overlay mount. It is called by the VFS for every `path_walk()` step. Its job is to produce a single overlay dentry that represents the merged result of the name across all layers.

The algorithm:

1. **Search the upper layer first.** If a whiteout is found, stop immediately and return ENOENT — the name is deleted.
2. If a non-whiteout entry is found in the upper layer, record it as `upperdentry`.
3. **Walk lower layers in order** (topmost lower layer first). For each lower layer:
   - If the name is not found, skip to the next layer.
   - If the name is a non-directory, record it only if no upper and no earlier lower has been found yet (first-match-wins for non-directories).
   - If the name is a directory, always record it (it may contribute entries to a merge).
4. **Merge or shadow.** If both an upper directory and one or more lower directories were found, overlayfs creates an overlay dentry whose `ovl_entry` holds references to all contributing lower dentries. This is the *merged directory*. If only one layer contributed (e.g., a pure upper directory), the dentry still references only that layer.
5. **Redirect following.** If the upper directory bears a `trusted.overlay.redirect` xattr (set by `redirect_dir`), `ovl_lookup()` follows the redirect to the original lower path before collecting lower contributions. This enables cross-layer directory renames.

The result — a single overlay dentry — hides all the layer complexity from the VFS caller.

### readdir: listing a merged directory

`ovl_iterate()` in `fs/overlayfs/readdir.c` handles `getdents(2)` on a merged directory. It must produce a union of all contributing layers' contents, deduplicated by name.

`ovl_iterate()` maintains a hash set of names already emitted. It iterates the upper layer first, emitting every entry that is not a whiteout and recording the name in the set. It then iterates each lower layer in order; for each name, it checks the hash set. If the name was already emitted (from upper or a higher lower layer), it is skipped. If it is a whiteout at the upper layer, it is also skipped. Otherwise the entry is emitted and its name added to the set.

The hash set prevents duplicates without requiring sorting, keeping the implementation O(N) in total entries across all layers rather than O(N log N).

### Short-circuit for pure-upper directories

A directory in the upper layer that has no lower-layer counterpart (it was created fresh in the upper layer, not copied up from below) is a *pure upper* directory. Overlayfs detects this with `ovl_path_type()` — if the type flags indicate no lower component, `ovl_lookup()` skips the lower walk entirely. Most directories in a running container are pure upper (they were created after the container started), so this short-circuit eliminates the lower-layer scan for the common case.

### Interaction with whiteouts during readdir

If the directory is *impure* (has the `trusted.overlay.opaque="x"` xattr), `ovl_iterate()` must check whether each lower-layer name has been whited out in the upper layer. It does this by looking up the name in the upper layer before emitting the lower-layer entry. Without the impure flag, this check is skipped — the common case for clean upper directories is free.

## Key Data Structures

**`struct ovl_entry`** (`fs/overlayfs/ovl_entry.h`) — per-dentry overlay state.
- `numlower` — number of lower layers that contributed to this dentry (0 for pure upper)
- `lowerstack[]` — array of `ovl_path` (dentry + mnt pairs), one per contributing lower layer

**`struct ovl_readdir_data`** (`fs/overlayfs/readdir.c`) — temporary state for an `ovl_iterate()` call.
- `names` — hash set of names already emitted to the caller
- `is_upper` — whether we are currently iterating the upper layer (affects whiteout treatment)

## Key Functions / Entry Points

**`ovl_lookup()`** (`namei.c`) — core name resolution; searches upper then lower layers and builds a merged or pure dentry.

**`ovl_iterate()`** (`readdir.c`) — implements `getdents(2)` over a merged directory; unions and deduplicates entries from all contributing layers.

**`ovl_path_type()`** (`overlayfs.h`) — returns a bitmask indicating whether the overlay dentry has an upper component, one or more lower components, or both; used for short-circuit decisions throughout the codebase.

**`ovl_check_dir_xattr()`** (`namei.c`) — reads opaque/impure xattrs to determine whether a directory requires whiteout scanning during readdir.

## Important Flags & Config Options

- `redirect_dir={on|off|follow|nofollow}` — controls whether `ovl_lookup()` follows `trusted.overlay.redirect` xattrs when resolving lower-layer contributions to a merged directory
- No separate Kconfig symbol for directory merging; it is always part of `CONFIG_OVERLAY_FS`

## Interactions with Other Subsystems

- **↑ Userspace**: Transparent — `opendir(3)` / `readdir(3)` / `getdents(2)` see a single merged directory; there is no visible difference between a pure lower, pure upper, or merged directory from userspace
- **→ [[vfs]]**: VFS calls `ovl_lookup()` for every path component and `ovl_iterate()` for directory listings; overlayfs returns standard dentries and dirents that VFS handles normally
- **← [[locking]]**: The `d_lock` of the overlay dentry and of each contributing lower dentry must be acquired carefully; `ovl_lookup()` uses `inode_lock()` on the inode to protect `__upperdentry` and `ovl_entry` updates

## Design Decisions & Tradeoffs

**First-match-wins for non-directories** — The choice to expose only the topmost copy of a non-directory file (rather than merging file contents) was deliberate and correct. File merging would be semantically undefined for binary files and complex even for text files. The policy is simple and predictable: the highest layer wins.

**Full merge for directories** — Directories are the exception because their "content" is their name-to-inode mapping, which has a natural union semantics: the merged directory contains all names from all layers, with upper shadowing lower for the same name. This is the key insight that makes layered container images work: each image layer contributes its new or changed files, and the directory structure is unioned across all layers.

**Hash set deduplication in readdir** — An alternative (used by earlier union filesystem implementations) was to sort all entries and merge-deduplicate. The hash set approach is simpler to implement and avoids the need to buffer all entries before emitting any. The downside is that readdir order is now determined by upper-first iteration rather than being alphabetical, which is legal (POSIX does not guarantee order) but differs from single-layer filesystems.

**`ovl_path_type()` short-circuit** — Avoiding the lower walk for pure-upper directories was a significant performance optimisation for container workloads where most directory operations happen on newly created upper-layer directories. The check is a bitmask test on the dentry flags and is essentially free.

## How It Has Evolved

- **3.18**: Basic upper/lower merge for one lower layer; linear scan for readdir
- **4.19**: Multiple lower layers added; `ovl_entry.lowerstack[]` extended to hold N lower paths; readdir extended to iterate N+1 layers
- **5.x**: Impure xattr and hash-set deduplication in readdir optimised to avoid scanning clean directories for whiteouts
- **6.8**: `redirect_dir` handling refined to correctly merge directories that have been moved cross-layer

## Further Reading

1. [Overlay Filesystem — kernel.org documentation](https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html) — directory merge semantics and whiteout visibility rules
2. [kernel-internals.org: OverlayFS](https://kernel-internals.org/filesystems/overlayfs/) — container-focused explanation of layer merge behaviour
3. [Overlayfs issues and experiences — LWN.net (2015)](https://lwn.net/Articles/636943/) — covers real-world POSIX compliance gaps surfaced by Docker including `st_ino` and merge edge cases

## LKML Highlights

- **Multiple lower layers (2018)**: `[PATCH v3 0/14] overlayfs: multiple lower layers` — the main discussion revolved around how to extend `ovl_entry.lowerstack[]` without breaking existing code paths and how to maintain O(N) lookup behaviour.
- **Readdir deduplication (2016)**: discussion during the `redirect_dir` patch series about whether deduplication should be done at `ovl_lookup()` or `ovl_iterate()` time; the decision to use a hash set in `ovl_iterate()` was settled here.
