---
title: "OverlayFS Metacopy"
category: concept
tags: [overlayfs, filesystem, copy-on-write, containers, performance, metadata]
subsystem: overlayfs
kernel_version: "5.2"
researched: 2026-04-15
status: complete
sources:
  - https://kernel-internals.org/filesystems/overlayfs/
  - https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
  - https://lwn.net/Articles/755891/
  - https://github.com/torvalds/linux/blob/master/fs/overlayfs/copy_up.c
---

# OverlayFS Metacopy

## Purpose

Full copy-up — copying both metadata and file data to the upper layer before any metadata change — is prohibitively expensive when a container startup performs `chown -R` or `chmod -R` across thousands of files. For a 500 MB shared library, a simple `chmod` would copy 500 MB of data to the upper layer, breaking page-cache sharing between containers and consuming large amounts of storage. Metacopy defers data transfer: only the file's metadata (ownership, permissions, timestamps, extended attributes) is promoted to the upper layer; data stays in the lower layer until the file is actually opened for writing.

## Mental Model

Metacopy is like checking out a book from a library, but only updating the library card (metadata) without actually taking the book off the shelf. You now "own" the checkout record in your name (upper layer) but the physical book (file data) stays on the shelf where all other patrons can still read it. Only when you actually want to mark in the book (write to the file) does the librarian make a photocopy for you to keep (full data copy-up).

## How It Works

### Metadata-Only Copy-Up

When `metacopy=on` is set and a metadata-only operation arrives at a lower-layer inode — `chmod()`, `chown()`, `utimes()`, or setting an xattr — overlayfs detects that no data transfer is needed. Instead of the full copy-up procedure, `ovl_copy_up_metadata()` in `fs/overlayfs/copy_up.c` creates a new upper-layer inode with only the metadata:

1. Create a new regular file (or directory) in the upper layer with the new ownership and permissions.
2. Stamp the new upper inode with the `trusted.overlay.metacopy` xattr as a marker. This xattr signals "this upper inode has no data of its own; look to the lower layer for data."
3. Optionally (with `verity=on`), compute a digest of the lower file's data and embed it in the `trusted.overlay.metacopy` xattr value.

The 500 MB data file is never read. The upper layer now holds a tiny inode record; the lower layer still holds the data.

### Reads Through Metacopy Files

When a process reads a metacopy file, overlayfs detects the `trusted.overlay.metacopy` marker on the upper inode. Instead of serving data from the upper file (which has none), `d_real()` returns the *lower* dentry/inode. The VFS page cache warms up from the lower layer's data. Because multiple containers share the same lower layer, they all share the same page-cache pages — this is the key efficiency gain. No data duplication occurs.

### Lazy Data Copy-Up

When a process opens a metacopy file for writing, overlayfs detects the marker, recognises that data has not yet been promoted, and triggers a *data copy-up*:

1. Create a temp file in `$workdir/work/`.
2. Splice the lower data into the temp file.
3. Remove the `trusted.overlay.metacopy` xattr.
4. Rename the temp file to the upper path (replacing the metadata-only shell).

After this, the upper file is fully self-contained. Subsequent reads and writes operate directly on the upper file without consulting the lower.

### fs-verity Integration

The `verity={on|require}` mount option extends metacopy with tamper detection. When computing a metadata-only copy-up with `verity=on`, overlayfs computes a digest (using the kernel's fsverity or HMAC infrastructure) of the lower file's data and stores it in the `trusted.overlay.metacopy` xattr value. On each read through the metacopy file, overlayfs verifies the lower data against the stored digest, returning EIO if a mismatch is detected.

This enables overlayfs to serve as a trusted execution environment where the upper layer is trusted but the lower layers (e.g., downloaded container images) are treated as potentially tampered. `verity=require` fails the mount if the lower layer cannot be verified.

### Data-Only Lower Layers and Metacopy

The `::` (data-only lower layer) syntax in `lowerdir` is directly motivated by metacopy: it allows splitting metadata layers (regular lower layers) from data layers (data-only lower layers). A metacopy upper inode can point its data reference to a data-only lower layer, allowing metadata and data to live on completely separate storage devices.

## Key Data Structures

**`struct ovl_inode`** (`fs/overlayfs/ovl_entry.h`) — per-inode overlay state.
- `__upperdentry` — points to the metadata-only upper inode after metacopy; non-NULL even though there is no data
- `lowerdata` — dentry of the lower data inode; set for metacopy files, NULL after full copy-up
- `oe` — `ovl_entry` with lower-layer references

**`struct ovl_copy_up_ctx`** (`fs/overlayfs/copy_up.c`) — context for a single copy-up operation.
- `metacopy` — true when performing a metadata-only copy (no data transfer)

## Key Functions / Entry Points

**`ovl_copy_up_metadata()`** (`copy_up.c`) — creates the upper-layer metadata inode and writes the `trusted.overlay.metacopy` marker; called instead of the full copy-up for metadata-only operations when `metacopy=on`.

**`ovl_copy_up_data()`** (`copy_up.c`) — performs the actual data transfer from lower to upper; called lazily on first write to a metacopy file.

**`ovl_check_metacopy_xattr()`** (`copy_up.c`) — reads and validates the `trusted.overlay.metacopy` xattr to detect metacopy inodes; called from the read path.

**`ovl_copy_up_flags()`** (`copy_up.c`) — top-level copy-up entry point that inspects the operation type and decides whether to invoke the metacopy or full path.

## Important Flags & Config Options

- `metacopy={on|off}` — enables metadata-only copy-up; default off
- `verity={off|on|require}` — controls digest generation and verification for metacopy files; default off
  - `on`: generate and verify digests when possible
  - `require`: fail mount if lower layer cannot be verified
- `CONFIG_OVERLAY_FS_METACOPY` — compile-time switch for metacopy support
- Incompatible with `nfs_export=on` (metacopy changes inode identity semantics in ways that break NFS re-export)
- Incompatible with certain `redirect_dir` modes

## Interactions with Other Subsystems

- **↑ Userspace**: Transparent for reads; first write is slightly slower (triggers data copy-up); `stat(2)` reports the upper metadata, `st_ino` may differ from the lower data inode before first write
- **→ [[vfs]]**: `d_real()` returns the lower dentry for reads on metacopy files; VFS page cache is populated from the lower layer transparently
- **→ [[fscrypt]]**: Metacopy files on fscrypt-encrypted lower layers require careful key management; the encryption context of the lower data inode must remain accessible during lazy data copy-up
- **← [[security]]**: SELinux/Smack labels come from the upper metacopy inode; the lower data inode's labels are not directly used but are checked during data copy-up

## Design Decisions & Tradeoffs

**Opt-in rather than default** — Metacopy changes an observable semantic: before the first write, `stat(2)` on a metacopy file returns the upper inode's `st_ino`, but the data is served from the lower inode. Tools like rsync and backup software that rely on `(st_dev, st_ino)` pairs to detect hard links or identify files may behave incorrectly. Making metacopy opt-in means only workloads that understand the trade-off use it.

**Shared page cache as the key benefit** — The primary motivation was not storage savings but CPU and I/O savings during container startup. In a system running 100 containers from the same base image, 100 full copy-ups of `/usr/lib/libssl.so` on every `chmod` would fill the page cache with 100 redundant copies. With metacopy, all 100 containers share a single page-cache entry for the lower-layer file.

**Workdir-staged data copy-up** — When the lazy data copy-up finally occurs, the same atomic workdir-rename pattern used by regular copy-up is applied. This ensures that even the lazy promotion is crash-consistent: a partial data copy in workdir is abandoned on remount; a complete rename is atomic.

**verity as an opt-in security layer** — The digest-in-xattr design was chosen over per-block verification (fs-verity proper) because overlayfs does not own the block layer. Storing a whole-file digest in the metacopy xattr is simple to implement but provides weaker guarantees than per-block fs-verity — a partial write to the lower file goes undetected until the next full-file read. `verity=require` addresses deployment concerns where the lower filesystem is completely untrusted.

## How It Has Evolved

- **5.2**: Metacopy merged; metadata-only copy-up for `chmod`, `chown`, `utimes`, and xattr operations
- **5.8**: Performance refinements: skip metacopy for `O_TMPFILE` and MAP_PRIVATE anonymous mappings
- **6.8**: Data-only lower layers (`::` syntax) enabled; metacopy data references can now span separate storage devices
- **6.12**: `verity={on|require}` merged; `trusted.overlay.metacopy` xattr value extended to carry an optional file digest

## Further Reading

1. [Overlayfs: Delayed copy up of data — LWN.net (2019)](https://lwn.net/Articles/755891/) — the original metacopy motivation article: container `chown` benchmarks and the page-cache sharing argument
2. [Overlay Filesystem — kernel.org documentation](https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html) — `metacopy` and `verity` option reference
3. [kernel-internals.org: OverlayFS](https://kernel-internals.org/filesystems/overlayfs/) — container-focused deep dive including the performance implications of metacopy

## LKML Highlights

- **Metacopy series (2018)**: `[PATCH 0/28] overlayfs: Delayed copy up of data` by Amir Goldstein — 28 patches; central debate was whether the `st_ino` semantic change would break existing tools; the opt-in decision resolved the argument.
- **verity integration (2022–2023)**: `[PATCH v6 0/16] ovl: support fs-verity for data integrity` — Amir Goldstein and Vivek Goyal; debated threat model (whole-file vs. per-block verification) and how to handle digest failures on partial reads.
