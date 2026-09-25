---
title: "Inode (struct inode)"
category: concept
tags: [fs, vfs, inode, metadata, permissions]
subsystem: fs
kernel_version: "2.6"
researched: 2026-09-25
status: complete
explained: "[[inode-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://docs.kernel.org/filesystems/multigrain-ts.html
  - https://lwn.net/Articles/940758/
  - https://lwn.net/Articles/992430/
  - https://lwn.net/Articles/946569/
---

# Inode (struct inode)

> 📘 Plain-language version: [[inode-explained]]

## Purpose

An inode is the kernel's in-memory representation of **one filesystem object**: a regular file, directory, symlink, device node, FIFO or socket. It holds everything about the object except its name: type and permission bits, owner, size, link count, timestamps, where its data is cached, and which filesystem code implements its operations. Names live in dentries; open-file state lives in `struct file`. Keeping these apart lets one object have many names (hard links) and many open instances, while every permission check, `stat()`, page-cache lookup and directory operation goes through one shared, filesystem-neutral structure. This note covers `struct inode` itself and its lifecycle; how inodes are hashed, cached and reclaimed is in [[inode-cache]], and how inodes fit with superblocks, dentries and files is in [[core-in-memory-structures]].

## Mental Model

An inode is a **case file with a standard cover sheet**. The cover sheet (`struct inode`) has boxes every filesystem fills in the same way: type, permissions, owner, size, dates, link count, and a slip naming the department that handles it (`i_op`, `i_fop`). Behind the cover, each filesystem staples its own pages (extent maps, on-disk locations, journal state), and the VFS never reads them. The VFS works only with the cover sheet; when something filesystem-specific is needed, it calls the department named on the slip.

## How It Works

**Birth: embedded, not standalone.** A filesystem almost never allocates a bare `struct inode`. Instead its superblock's `alloc_inode` method allocates a larger filesystem structure (for ext4, `struct ext4_inode_info`) that **embeds** a `struct inode` as a member, and returns a pointer to that member. The filesystem gets back to its private part with `container_of()` (ext4's `EXT4_I(inode)`). This avoids a second allocation and a pointer chase on every operation. There are two ways an inode comes into existence:
- **Loading an existing object.** A directory `lookup` finds the on-disk inode number and calls `iget_locked(sb, ino)` (or `iget5_locked()` with a custom match). If the inode is already cached it is returned with a new reference; otherwise a fresh one is allocated, hashed, and returned **locked with `I_NEW` set**, so concurrent lookups of the same number wait while the filesystem reads the on-disk inode and fills in the fields. The filesystem then calls `unlock_new_inode()` to publish it.
- **Creating a new object.** `create`, `mkdir`, `mknod`, `symlink` or `tmpfile` call `new_inode(sb)`, initialise ownership with `inode_init_owner()` (which applies the parent's setgid rules and the caller's idmapping), allocate the on-disk inode, then attach it to the new name with `d_instantiate()` or `d_instantiate_new()`.

**The cover sheet.** The fields that matter most:
- **identity and type**: `i_ino` (inode number), `i_sb` (owning superblock), `i_mode` (file type plus permission bits), `i_rdev` for device nodes, `i_generation` (distinguishes reuse of an inode number, used by NFS file handles)
- **ownership**: `i_uid`, `i_gid`, stored as kernel IDs (`kuid_t`/`kgid_t`) so user namespaces and idmapped mounts can translate them
- **size and space**: `i_size`, `i_blocks`/`i_bytes`
- **link count**: `i_nlink`, changed only through `set_nlink()`, `inc_nlink()`, `drop_nlink()`, `clear_nlink()`
- **timestamps**: access, modification and change times, plus a birth time some filesystems keep privately
- **operations**: `i_op` (`struct inode_operations`: name and attribute operations) and `i_fop` (`struct file_operations`, copied into each `struct file` at open)
- **data**: `i_mapping`, which normally points at the embedded `i_data`, the inode's [[address-space]] (its page cache)
- **state and locks**: `i_state` flags, reference count `i_count`, `i_rwsem`, `i_lock`, list links for the hash, LRU, superblock and writeback lists
- **type-specific**: a union of `i_pipe`, `i_cdev`, `i_link` (fast symlink body), plus `i_private` for filesystem use
- **change detection**: `i_version`, a counter that changes on every modification, for NFS

**Operations through `i_op`.** Directory inodes implement the namespace: `lookup`, `create`, `link`, `unlink`, `symlink`, `mkdir`, `rmdir`, `mknod`, `rename` (with `RENAME_NOREPLACE`/`RENAME_EXCHANGE`), and optionally `atomic_open` (look up, create and open in one step, important for network filesystems) and `tmpfile` (an unnamed file, for `O_TMPFILE`). Symlinks implement `get_link`, which may be called during RCU path walk and must not sleep there. All inodes may implement `permission`, `getattr`, `setattr`, `listxattr`, `get_acl`/`set_acl`, `fiemap`, `update_time` and `fileattr_get`/`fileattr_set` (the `FS_IOC_GETFLAGS`-style attribute flags). Methods are called without VFS locks unless documented otherwise; for example `lookup` runs with the directory's `i_rwsem` held.

**Permission checks.** Every access goes through `inode_permission()`, which rejects writes to read-only filesystems and immutable files, then calls the filesystem's `permission` method or the generic `generic_permission()`: owner/group/other mode bits, POSIX ACLs if present, then capability overrides (`CAP_DAC_OVERRIDE`, `CAP_DAC_READ_SEARCH`). All of these take the mount's idmapping, so an idmapped mount can present the same inode with different ownership. During RCU path walk the call carries `MAY_NOT_BLOCK`; a filesystem that would need to sleep returns `-ECHILD` and the walk retries in reference-counted mode. Security modules get their hook afterwards.

**Changing attributes.** `chmod`, `chown`, `truncate` and `utimes` all become a `struct iattr` passed to `notify_change()`, which checks permission and calls the filesystem's `setattr`. Filesystems validate with `setattr_prepare()` (ownership rules, clearing setuid/setgid on chown, size limits) and apply generic fields with `setattr_copy()`, doing size changes themselves because truncation must also drop page cache and free blocks.

**Timestamps.** Writes and metadata changes update mtime and ctime through helpers such as `inode_set_ctime_current()`. Traditionally the kernel uses a **coarse** clock (updated once per tick) so that a file written many times per tick isn't dirtied every time. The catch: NFS clients and `make` compare timestamps to detect changes, and two writes within one tick look identical. **Multigrain timestamps** (6.13, after an attempt in 6.6 was reverted) fix this for filesystems that opt in with `FS_MGTIME`: when someone *queries* mtime or ctime, a spare bit in the ctime nanoseconds field is set, and the next update then takes a **fine-grained** timestamp so the change is visible, while unqueried updates stay cheap. A global monotonic floor keeps timestamps from appearing to go backwards across files. Around 6.6–6.7, direct access to the timestamp fields was replaced with accessor functions (`inode_get_mtime()`, `inode_set_ctime()` and friends) to make such changes possible.

**Change counter.** `i_version` gives NFSv4 a reliable change attribute. Since 4.16 it is incremented **lazily**: a flag records whether anyone has queried the counter since the last increment, and it's only bumped (forcing the inode to be logged) when someone is watching.

**Dirtying and writeback.** Changing inode metadata calls `mark_inode_dirty()` (or `mark_inode_dirty_sync()` for changes like timestamps that `fdatasync` can skip). That sets `I_DIRTY_*` bits in `i_state`, calls the filesystem's `dirty_inode` (journaling filesystems log the change here), and queues the inode on its backing device's writeback list, where [[writeback-infrastructure]] later calls `write_inode`. `I_DIRTY_TIME` lets lazytime mounts keep timestamp-only changes in memory for a long time.

**Links, unlinking and orphans.** `unlink` removes a name and drops `i_nlink`; the inode itself survives while any reference remains. An open-but-unlinked file (`i_nlink == 0`, still open) is a classic Unix idiom, so filesystems keep such inodes on an **orphan list** on disk; after a crash they finish deleting them at mount.

**Death.** `iput()` drops a reference. When the count reaches zero, the superblock's `drop_inode` decides whether to keep the inode cached (the default for linked inodes, which go onto the LRU for [[inode-cache]] to reclaim later) or evict it now (always for unlinked inodes). Eviction calls the filesystem's `evict_inode`, which must call `truncate_inode_pages_final()` to drop the page cache and, if `i_nlink` is zero, free the on-disk inode and its blocks, then `clear_inode()`. Memory is released with `destroy_inode`/`free_inode`, the latter after an RCU grace period, because lockless path walk may still be looking at the inode.

## Key Data Structures

**`struct inode`** (`include/linux/fs.h`) — the VFS object; see the field walk-through above.

**`struct inode_operations`** — `lookup`, `create`, `link`, `unlink`, `symlink`, `mkdir`, `rmdir`, `mknod`, `rename`, `get_link`, `permission`, `get_acl`, `set_acl`, `setattr`, `getattr`, `listxattr`, `fiemap`, `update_time`, `atomic_open`, `tmpfile`, `fileattr_get`, `fileattr_set`.

**`struct iattr`** — requested attribute changes: `ia_valid` mask, `ia_mode`, `ia_vfsuid`/`ia_vfsgid`, `ia_size`, `ia_atime`/`ia_mtime`/`ia_ctime`, `ia_file`.

**`i_state` flags** — `I_NEW` (being set up), `I_DIRTY_SYNC`/`I_DIRTY_DATASYNC`/`I_DIRTY_PAGES`/`I_DIRTY_TIME`, `I_FREEING`, `I_WILL_FREE`, `I_CLEAR`, `I_SYNC`, `I_REFERENCED`.

## Key Functions / Entry Points

**`iget_locked()` / `iget5_locked()` / `unlock_new_inode()`** (`fs/inode.c`) — load an inode by number, publish it once filled.
**`new_inode()` / `inode_init_owner()`** — allocate and initialise a new inode.
**`inode_permission()` / `generic_permission()`** (`fs/namei.c`) — access checks.
**`notify_change()` / `setattr_prepare()` / `setattr_copy()`** (`fs/attr.c`) — attribute changes.
**`mark_inode_dirty()`** — record metadata changes for writeback.
**`inode_set_ctime_current()` / `fill_mg_cmtime()`** — timestamp updates with multigrain support.
**`iput()` / `evict()` / `clear_inode()`** — release and eviction.
**`set_nlink()` / `inc_nlink()` / `drop_nlink()`** — link count management.

## Important Flags & Config Options

- `FS_MGTIME` (file_system_type flag) — opt into multigrain timestamps.
- Mount options `lazytime`, `noatime`, `relatime`, `strictatime` — how often access and timestamp-only changes are written.
- `SB_I_VERSION` — maintain `i_version`.
- Inode flags `S_IMMUTABLE`, `S_APPEND`, `S_NOATIME`, `S_DAX`, `S_SWAPFILE` (in `i_flags`).
- `/proc/sys/fs/inode-nr`, `inode-state` — inode counts.

## Interactions with Other Subsystems

- **↑ Userspace**: `stat`, `chmod`, `chown`, `utimensat`, `link`, `unlink`, `rename`, `open(O_TMPFILE)`, `ioctl(FS_IOC_GETFLAGS)`.
- **→ [[dentry]]**: names point to inodes; `d_instantiate()` connects a new inode to its name.
- **→ [[address-space]] / [[page-cache]]**: each inode's data is cached through `i_mapping`.
- **→ [[writeback-infrastructure]]**: dirty inodes are queued per backing device and written back later.
- **← [[path-lookup]]**: calls `permission` and `lookup` on directory inodes, in RCU mode when possible.
- **← [[inode-cache]]**: keeps unused inodes hashed and on the LRU, and reclaims them under memory pressure.
- **→ [[lsm-framework]]**: security modules attach per-inode data and check every operation.
- **→ [[user-namespaces]]**: ownership is stored as kernel IDs and translated through idmappings.

## Design Decisions & Tradeoffs

- **Embedding instead of pointing.** Filesystems embed `struct inode` in their own structure, saving an allocation and pointer chase, at the cost of `struct inode` size mattering to every filesystem and constant pressure to keep it small.
- **Names separate from objects.** Splitting dentries from inodes makes hard links, rename and caching clean, but means an inode can't know "its" path.
- **Coarse vs. fine timestamps.** Coarse times keep writes cheap; fine times make changes detectable. Multigrain gets both by going fine only when someone is watching, after a first attempt in 6.6 was reverted because of ordering anomalies between files.
- **Lazy change counting.** Incrementing `i_version` only when queried avoids logging the inode on every write when no NFS client cares.
- **RCU-freed inodes.** Lockless path walk needs inodes to stay valid briefly after eviction, costing an RCU-deferred free.

## How It Has Evolved

- **Early Linux** — per-filesystem data lived in a union inside `struct inode`; later replaced by embedding `struct inode` in filesystem structures.
- **2.6.x** — `i_mutex` protects the inode; RCU path walk (2.6.38) adds `MAY_NOT_BLOCK` permission checks and RCU-freed inodes.
- **3.5** — `kuid_t`/`kgid_t` for user namespaces.
- **4.7** — `i_mutex` becomes the read/write semaphore `i_rwsem`, allowing parallel lookups in one directory.
- **4.16** — lazy `i_version` increments (Jeff Layton).
- **5.12 / 6.3** — idmapped mounts, then `mnt_idmap` passed to all permission and attribute methods (Christian Brauner).
- **6.6–6.7** — timestamp accessor functions; multigrain timestamps merged and then reverted.
- **6.13** — multigrain timestamps re-merged with timekeeping support.

## Further Reading

1. [fs: multigrain timestamp redux — LWN](https://lwn.net/Articles/992430/)
2. [fs: implement multigrain timestamps — LWN](https://lwn.net/Articles/940758/)
3. [fs: new accessor methods for inode atime and mtime — LWN](https://lwn.net/Articles/946569/)
4. [Overview of the Linux Virtual File System — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/vfs.html)
5. [Multigrain timestamps — kernel.org](https://docs.kernel.org/filesystems/multigrain-ts.html)

## LKML Highlights

> lore.kernel.org was unreachable (TLS certificate error) during this session; summarised from LWN.

- **"fs: implement multigrain timestamps" (Jeff Layton, 2023)** — fine-grained ctime/mtime only after a query; merged for 6.6 and reverted weeks later when files updated in sequence could show out-of-order timestamps.
- **"fs: multigrain timestamp redux" (Jeff Layton, 2024)** — second attempt with a global monotonic floor kept in the timekeeping code to avoid extra seqcount loops, merged for 6.13.
