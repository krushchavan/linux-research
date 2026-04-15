---
title: "OverlayFS Copy-Up"
category: concept
tags: [overlayfs, copy-on-write, filesystem, containers]
subsystem: overlayfs
kernel_version: "3.18"
researched: 2026-04-15
status: complete
sources:
  - https://kernel-internals.org/filesystems/overlayfs/
  - https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
  - https://lwn.net/Articles/755891/
  - https://github.com/torvalds/linux/blob/master/fs/overlayfs/copy_up.c
---

# OverlayFS Copy-Up

## Purpose

Copy-up is the copy-on-write mechanism that makes overlayfs safe for writes: when a process writes to a file that exists only in a read-only lower layer, copy-up promotes the file to the writable upper layer before allowing the write. Without copy-up, overlayfs would need to make lower layers writable — destroying their shareability — or return EROFS on every write to a shared file.

## Mental Model

Copy-up is like a hotel notepad placed on top of a printed form. You never touch the form itself; instead, you write on the fresh pad. The first time you write, the pad has to be laid down (copy-up). After that, every subsequent write goes straight to the pad. The original form stays pristine and can be photocopied for the next guest.

## How It Works

Every write path in overlayfs — `write()`, `truncate()`, `chmod()`, `chown()`, hard-linking — begins by checking whether the target inode has an upper-layer dentry. The check is `OVL_E(dentry)->__upperdentry == NULL`. If it is NULL, the file lives only in the lower stack and must be copied up before the operation can proceed.

`ovl_copy_up()` (`fs/overlayfs/copy_up.c`) is the entry point. It does not copy just the file; it first ensures the entire directory ancestry exists in the upper layer. It walks from the file up toward the overlay root, collecting any path component that is missing from the upper layer. Then it works back down, creating each missing ancestor directory in the upper layer and setting `trusted.overlay.opaque="y"` on it if the directory contains children that should hide lower-layer contents.

The actual file copy is atomic by design. The procedure is:

1. Create a temp file inside `$workdir/work/` on the upper filesystem.
2. Transfer file data from the lower layer to the temp file using `do_splice_direct()` — a zero-copy in-kernel splice path that avoids userspace memory and double buffering.
3. Copy the file's permissions, ownership, timestamps, and extended attributes.
4. Atomically `rename()` the temp file to the final path in the upper layer.

The rename is the commit point. Because both the workdir and the upper layer are on the same filesystem, the rename is a single atomic directory-entry operation. A crash between steps 1–3 leaves an orphan in workdir (cleaned up on next mount); a crash after step 4 leaves a fully valid upper file. No partial state is ever visible to other processes.

After copy-up completes, `ovl_inode_update_locked()` sets `__upperdentry` on the overlay inode and bumps `version` to invalidate any stale page-cache references. From this point, VFS dispatches directly to the upper-layer file for all subsequent operations.

**Metacopy shortcut**: When `metacopy=on`, metadata-only operations (chmod, chown, utimes) do not copy file data. Only the inode metadata is created in the upper layer, stamped with `trusted.overlay.metacopy`. File reads continue to be served from the lower layer — preserving page-cache sharing between containers. Full data copy-up is deferred until the file is opened for writing.

**fsync semantics**: After data copy-up, overlayfs issues `vfs_fsync()` on the upper file before the rename. This ensures that if the machine crashes immediately after copy-up, the file survives on the upper filesystem. The `fsync=strict` mount option extends this to directories and metadata-only copies; `fsync=volatile` skips it entirely for maximum throughput.

## Key Data Structures

**`struct ovl_inode`** (`fs/overlayfs/ovl_entry.h`) — the overlay-layer inode, wrapping real upper/lower inodes.
- `__upperdentry` — dentry in the upper layer; NULL until copy-up completes
- `oe` — `ovl_entry` pointer holding the lower-layer dentry chain
- `version` — incremented on copy-up to invalidate page-cache

**`struct ovl_copy_up_ctx`** (`fs/overlayfs/copy_up.c`) — temporary context for a single copy-up operation.
- `parent` — upper-layer parent dentry to create the copy under
- `dentry` — the source overlay dentry being copied
- `metacopy` — true if this is a metadata-only copy

## Key Functions / Entry Points

**`ovl_copy_up()`** (`copy_up.c`) — top-level entry point; sets up context and calls `ovl_copy_up_one()` for each missing ancestor.

**`ovl_copy_up_one()`** (`copy_up.c`) — copies a single path component; handles both directories and regular files.

**`ovl_copy_up_data()`** (`copy_up.c`) — performs the splice-based data transfer; skipped for metacopy.

**`ovl_copy_up_metadata()`** (`copy_up.c`) — clones mode, uid/gid, timestamps, and xattrs from lower to temp file.

**`ovl_inode_update_locked()`** (`inode.c`) — updates `__upperdentry` and bumps `version` after copy-up completes.

## Important Flags & Config Options

- `metacopy={on|off}` — enables metadata-only copy-up (default: off)
- `fsync={auto|strict|volatile}` — controls fsync behavior during data copy-up
- `CONFIG_OVERLAY_FS` — compile-time switch; no separate symbol for copy-up

## Interactions with Other Subsystems

- **↑ Userspace**: Triggered transparently by any write, stat-modifying, or link operation on a lower-layer file; userspace never observes it directly
- **→ [[vfs]]**: Uses `vfs_fsync()`, `vfs_rename()`, `vfs_create()` to manipulate upper-layer files
- **→ [[fscrypt]]**: Blocked from running on fscrypt-encrypted upper layers; the encryption key context of the lower and upper directories may differ
- **← [[security]]**: SELinux/Smack labels are preserved by copying xattrs; LSM hooks fire on both the copy-create and the rename-into-place steps

## Design Decisions & Tradeoffs

**Workdir-staged atomic rename** — Copying directly to the final path would risk a partially-written file being visible. The workdir-plus-rename pattern guarantees atomicity at the cost of requiring workdir to be co-located with upper. This was considered non-negotiable; the alternative (locking the parent directory during copy) would have caused contention in multi-threaded container workloads.

**Ancestor directory pre-creation** — Early versions tried to create only the immediate parent, leading to races where a lookup could find a file whose parent directory did not yet exist in the upper layer. Pre-creating the full ancestry serializes this work and eliminates the race.

**Metacopy as an opt-in** — Making metadata-only copy the default would break applications that rely on `st_ino` identity between a file's inode and its data inode (tools like rsync, backup software). Metacopy changes the semantic: before first write, the overlay inode's `st_ino` differs from the data inode. This is safe but surprising, so it is opt-in.

## How It Has Evolved

- **3.18**: Copy-up added as the basic CoW mechanism; always full data copy
- **4.13**: `index=on` — copy-up now checks the index directory to reconnect hard links instead of creating independent upper inodes
- **5.2**: `metacopy=on` — metadata-only copy-up path added; data deferred to first write
- **5.8**: Performance improvements: avoid unnecessary copy-up for `O_TMPFILE` and anonymous mappings
- **6.12**: fs-verity integration: `trusted.overlay.metacopy` can embed a lower-file digest; copy-up verifies integrity before promoting

## Further Reading

1. [Overlayfs: Delayed copy up of data — LWN.net](https://lwn.net/Articles/755891/) — motivation and design of metacopy
2. [kernel.org OverlayFS docs](https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html) — mount option reference including fsync modes
3. [`fs/overlayfs/copy_up.c`](https://github.com/torvalds/linux/blob/master/fs/overlayfs/copy_up.c) — the canonical implementation

## LKML Highlights

- **Metacopy series (2018)**: `[PATCH 0/28] overlayfs: Delayed copy up of data` by Amir Goldstein — 28-patch series motivating the change with container chown benchmarks; debate centred on whether the complexity was worth the inode-identity change.
