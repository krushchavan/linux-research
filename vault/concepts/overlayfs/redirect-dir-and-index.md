---
title: "OverlayFS Redirect Dir and Index"
category: concept
tags: [overlayfs, filesystem, hardlinks, rename, POSIX, containers]
subsystem: overlayfs
kernel_version: "4.13"
researched: 2026-04-15
status: complete
explained: "[[redirect-dir-and-index-explained]]"
sources:
  - https://kernel-internals.org/filesystems/overlayfs/
  - https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
  - https://github.com/torvalds/linux/blob/master/fs/overlayfs/dir.c
  - https://github.com/torvalds/linux/blob/master/fs/overlayfs/namei.c
  - https://github.com/torvalds/linux/blob/master/fs/overlayfs/copy_up.c
---

# OverlayFS Redirect Dir and Index

> 📘 Plain-language version: [[redirect-dir-and-index-explained]]

## Purpose

Two separate features address specific POSIX compliance gaps that arise from overlayfs's layered architecture:

- **`redirect_dir`**: enables `rename(2)` on directories that span the overlay boundary, which would otherwise fail with `EXDEV`.
- **`index`**: preserves hard-link identity across copy-up; without it, copying one member of a hard-link set silently breaks the links.

Both features trade simplicity for POSIX correctness in scenarios that matter to production container and build-tool workloads.

## Mental Model

**Redirect dir** is like forwarding mail. When you move a directory in the upper layer, you leave a forwarding note (`trusted.overlay.redirect` xattr) at the old location pointing to the new one. Future callers who approach from the lower layer follow the note automatically and end up at the right place.

**Index** is like a shared library borrowing card. When the first copy of a book (hard link) is checked out (copied up), a card is filed under the book's serial number (the lower inode's file handle). When a second copy of the same book is checked out later, the librarian finds the card and simply issues another checkout slip for the same physical book on the upper shelf, instead of printing a new copy.

## How It Works

### `redirect_dir` — Cross-Layer Directory Rename

The problem: overlayfs allows renaming a pure-upper directory anywhere in the tree. But renaming a *merged* or *lower* directory is harder — the directory's lower-layer children still live at their original lower path. If overlayfs moved only the upper directory entry, future lookups via the lower path would find the original lower directory and expose its children as if the rename never happened.

With `redirect_dir=off` (the default in some distributions), `ovl_rename()` returns `EXDEV` if the source directory has any lower-layer component. Applications must fall back to `cp -r` + `rm -r`, which breaks atomicity.

With `redirect_dir=on`, `ovl_rename()` in `fs/overlayfs/dir.c` proceeds as follows:

1. Copy up the source directory (its inode only, not its children — children are still in lower layers).
2. Perform the `rename()` in the upper layer.
3. Write the *original lower path* as a `trusted.overlay.redirect` xattr on the newly renamed upper directory entry.

Future calls to `ovl_lookup()` entering that directory check for the xattr. If found, the redirect path is used to locate the lower-layer contribution instead of the current upper path. From the user's perspective, the directory moved cleanly and its contents (from lower layers) follow it.

**Security consideration**: `redirect_dir` is restricted to privileged mounts by default. Allowing unprivileged processes to write `trusted.overlay.redirect` would let them redirect arbitrary lower paths, potentially exposing files they should not see.

**`redirect_dir=follow`** (default in some distros): follows existing redirects during lookup but does not create new ones on rename, providing read compatibility without enabling creation.

### `index` — Hard-Link Preservation Across Copy-Up

The problem: in Linux, hard links are multiple directory entries pointing to the same inode. In overlayfs's lower layer, two names (`/usr/bin/foo` and `/usr/bin/foo-link`) may reference the same lower inode. When a process writes to `foo`, overlayfs copies up only `foo` — creating a fresh upper inode. The other name, `foo-link`, still points to the lower inode. From now on, writing through `foo` does not update `foo-link` and vice versa: the hard-link relationship is broken silently.

With `index=on`, overlayfs maintains an *index directory* at `$workdir/index/`. The algorithm:

1. Before copying up a file, overlayfs encodes a file handle (NFS-style export handle) for the lower inode as a hex string.
2. It checks `$workdir/index/` for an entry with that name.
3. **If an entry exists**: another hard link in the set has already been copied up. Overlayfs creates a hard link in the upper layer between the current name and the already-copied upper inode, instead of duplicating data. The upper link count stays accurate.
4. **If no entry exists**: overlayfs copies up the file normally and creates an index entry at `$workdir/index/<file-handle-hex>` pointing to (hard-linked to) the new upper inode.

After copy-up with the index, both `foo` and `foo-link` in the upper layer are genuine hard links to the same upper inode. Writes through either name are immediately visible through the other.

The index also serves as a form of NFS-export stability: `nfs_export=on` uses the same file-handle encoding to allow overlayfs to re-derive a dentry from an NFS file handle across remounts.

**Compatibility constraint**: `index=on` requires the underlying filesystems to support NFS-style file handles (the `export_operations` must be registered). This excludes tmpfs and some network filesystems as lower layers.

## Key Data Structures

**`$workdir/index/`** — a directory within the work directory; entries are named by the hex-encoded NFS file handle of the corresponding lower inode; each entry is a hard link to the upper-layer inode.

**`trusted.overlay.redirect`** (`namei.c`, `dir.c`) — xattr on upper-layer directory entries created by `redirect_dir`; value is the absolute overlay path of the original lower directory.

## Key Functions / Entry Points

**`ovl_rename()`** (`dir.c`) — handles `rename(2)` at the overlay level; triggers redirect xattr creation when `redirect_dir=on` and the source has a lower component.

**`ovl_get_index_inode()`** (`namei.c`) — looks up a file handle in `$workdir/index/` and returns the index inode if found.

**`ovl_copy_up_one()`** (`copy_up.c`) — the per-component copy-up function; when `index=on`, calls `ovl_get_index_inode()` before data copy-up and creates the index entry after.

**`ovl_link_up()`** (`copy_up.c`) — called when an index entry is found; creates a hard link in the upper layer instead of copying data.

**`ovl_lookup()`** (`namei.c`) — follows `trusted.overlay.redirect` xattrs when `redirect_dir=follow|on`.

## Important Flags & Config Options

- `redirect_dir={on|off|follow|nofollow}` — controls redirect creation and following; default varies by distribution
- `CONFIG_OVERLAY_FS_REDIRECT_DIR` — enables redirect_dir support at compile time
- `CONFIG_OVERLAY_FS_REDIRECT_ALWAYS_FOLLOW` — makes `redirect_dir=follow` the compile-time default
- `index={on|off}` — enables/disables the index feature; default off
- `CONFIG_OVERLAY_FS_INDEX` — enables index support at compile time
- `nfs_export={on|off}` — enables NFS re-export of overlay mounts; requires `index=on`

## Interactions with Other Subsystems

- **↑ Userspace**: Both features are transparent to userspace — `rename(2)` succeeds instead of returning `EXDEV`; hard links remain coherent across writes without application involvement
- **→ [[vfs]]**: `ovl_rename()` calls `vfs_rename()` on the upper layer; index entries are created with `vfs_link()`; redirect xattrs are written via `vfs_setxattr()`
- **→ [[nfs]]**: `nfs_export=on` uses the same file handle encoding as the index to allow stateless NFS clients to re-derive overlay dentries after remount
- **← [[security]]**: LSM hooks fire on redirect xattr writes and on index entry creation; `CAP_DAC_READ_SEARCH` is needed for file handle encoding on some filesystems

## Design Decisions & Tradeoffs

**Redirect xattr instead of directory move** — Moving lower-layer directory children would require modifying the lower layer, which is forbidden. The redirect xattr is the minimal change that makes the rename appear atomic to userspace while leaving the lower layer intact. The downside is extra xattr lookups on every directory entry into a redirected directory.

**Index keyed by file handle** — Using the NFS file handle (rather than, say, inode number + device) is deliberate: file handles survive remounts and work across different filesystems. Inode numbers alone are not stable enough (a filesystem format might reuse them). The cost is that `index=on` requires `export_operations` support in the underlying filesystem.

**`redirect_dir` off by default** — Creating redirect xattrs permanently alters the upper layer in ways that cannot be cleanly reversed if the feature is later disabled. Distributions that ship with `redirect_dir=on` cannot safely downgrade to older kernels without potentially inconsistent redirect xattrs. This is why many distros ship `redirect_dir=follow` (reads existing redirects but creates no new ones) as a conservative middle ground.

**Hard-link breakage is the existing behavior** — Without `index=on`, the breakage is silent and has surprised many developers. The decision not to enable it by default was driven by the export_operations constraint: making it the default would break overlays on filesystems that do not support file handles (notably tmpfs). The index feature is opt-in precisely because it is not universally applicable.

## How It Has Evolved

- **4.10**: `redirect_dir` first merged; required for cross-layer directory renames
- **4.13**: `index` feature merged; hard-link preservation and NFS export support
- **4.17**: `xino` interoperates with index; file handles used for both xino and index entry naming
- **4.19**: `nfs_export=on` builds on index to enable stateless NFS re-export of overlay mounts
- **5.x**: `redirect_dir=follow` semantics stabilised; `nofollow` option added to disable even reading existing redirects

## Further Reading

1. [Overlay Filesystem — kernel.org documentation](https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html) — `redirect_dir` and `index` option reference and semantics
2. [kernel-internals.org: OverlayFS](https://kernel-internals.org/filesystems/overlayfs/) — container-focused explanation of hard-link identity across layers
3. [Overlayfs: Improve POSIX compliance — LWN.net (2018)](https://lwn.net/Articles/755891/) — metacopy series includes discussion of index and redirect interactions

## LKML Highlights

- **`redirect_dir` (2016)**: `[PATCH 0/9] overlayfs: allow moving directory trees` — Miklos Szeredi and Amir Goldstein debated whether the xattr approach was POSIX-safe; the thread established that `EXDEV` is always preferable to silently corrupt state, making the feature opt-in.
- **`index` (2017)**: `[PATCH v5 0/16] ovl: overlay NFS export` — the index feature was introduced as part of the NFS export series; the hard-link preservation benefit was a side-effect that became the primary motivation for end-user adoption.
