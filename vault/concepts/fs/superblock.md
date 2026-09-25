---
title: "Superblock (struct super_block)"
category: concept
tags: [fs, vfs, superblock, mount, freeze]
subsystem: fs
kernel_version: "2.6"
researched: 2026-09-25
status: complete
explained: "[[superblock-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://lwn.net/Articles/780268/
  - https://lwn.net/Articles/752298/
  - https://lwn.net/Articles/1054228/
  - https://lwn.net/Articles/379862/
  - https://lwn.net/Articles/939937/
  - https://static.lwn.net/kerneldoc/filesystems/api-summary.html
---

# Superblock (struct super_block)

> 📘 Plain-language version: [[superblock-explained]]

## Purpose

A `struct super_block` represents **one mounted filesystem instance**: one ext4 volume, one tmpfs, one NFS export. Everything that belongs to the filesystem as a whole rather than to a single file lives here: its block size and limits, mount flags, the root dentry, the list of its inodes, its operations vector, its backing device, and state for syncing, freezing and unmounting. The on-disk "superblock" of a block filesystem is the persistent record of that information; the in-memory `super_block` is what the VFS actually works with, and it exists for filesystems with no disk at all. Without it, there would be no single object to hang per-filesystem state on, and no way to share one filesystem between several mounts.

## Mental Model

A superblock is the **head office of a filesystem**. Mount points are just street addresses pointing to it (several addresses can point to the same office, as with bind mounts). The head office keeps the staff list (all inodes), the procedures manual (`s_op`), the company rules (flags, limits), and the front door (the root dentry). When the company closes for a stocktake (a freeze), the head office stops new work in stages. When the last address pointing to it goes away, the head office shuts down (`kill_sb`).

## How It Works

**Registration.** A filesystem type registers a `struct file_system_type` with `register_filesystem()`: its `name` (as shown in `/proc/filesystems`), `fs_flags` such as `FS_REQUIRES_DEV`, `FS_USERNS_MOUNT` or `FS_MGTIME`, `init_fs_context` to start a mount, a `parameters` table describing accepted mount options, and `kill_sb` to tear an instance down. It also keeps the list of all superblocks of that type (`fs_supers`).

**Mounting: build a configuration first.** Since the new mount API (5.2, David Howells), mounting is a two-phase process. The kernel creates a **filesystem context** (`struct fs_context`) and calls the type's `init_fs_context`, which installs `struct fs_context_operations`. Each mount option is then parsed individually through `parse_param` against the declared parameter table, with errors and warnings logged into the context rather than lost. Only when configuration is complete does the kernel call `get_tree`. With the classic `mount(2)` system call all of this happens inside the kernel; the new system calls expose the phases to user space: `fsopen()` creates the context, `fsconfig()` sets options and finally issues `FSCONFIG_CMD_CREATE`, `fsmount()` turns the result into a detached mount, and `move_mount()` attaches it. `fspick()` opens an existing superblock's context for reconfiguration.

**Mounting: find or create the superblock.** `get_tree` usually calls a helper that decides whether an existing superblock can be reused. `get_tree_bdev()` (block devices) looks for a superblock already on that device; `get_tree_nodev()` always makes a new one (tmpfs); `get_tree_single()` shares one instance system-wide; `get_tree_keyed()` shares one per key, such as a namespace. Underneath, `sget_fc()` walks the type's superblock list with a test callback: on a match it returns the existing superblock (which is how mounting the same device twice yields one instance), otherwise it allocates a new one with `alloc_super()` and assigns it an identity via the set callback (for example an anonymous device number for non-disk filesystems). A new superblock then goes to the filesystem's **`fill_super`**, which reads and validates the on-disk superblock, sets `s_blocksize`, `s_maxbytes`, `s_magic`, `s_op`, `s_xattr`, `s_export_op` and time granularity, reads the root inode, and creates the root dentry `s_root` with `d_make_root()`. On success the superblock is marked active and a mount (`struct vfsmount`) is created pointing to its root. Since 6.6 user space can learn whether a mount reused an existing superblock, because silently getting different options than requested was a long-standing surprise.

**The operations vector.** `struct super_operations` is how the VFS calls back into the filesystem for whole-filesystem and inode-lifecycle work:
- `alloc_inode`, `destroy_inode`, `free_inode` (RCU-deferred) — inode memory, usually embedding `struct inode` in a filesystem structure
- `dirty_inode`, `write_inode`, `drop_inode`, `evict_inode` — inode metadata writeback and eviction
- `sync_fs` — flush everything for this filesystem (for example commit the journal)
- `freeze_fs`, `unfreeze_fs` (or the whole-process `freeze_super`/`thaw_super`) — quiesce and resume
- `statfs` — `df` numbers
- `put_super` — release filesystem state at unmount
- `show_options`, `show_devname`, `show_path`, `show_stats` — what `/proc/mounts` shows
- `umount_begin` — forced-unmount notification (network filesystems)
- `nr_cached_objects`, `free_cached_objects` — let filesystem-private caches join memory reclaim
- `shutdown` — emergency shutdown when the underlying device goes away

**Per-superblock state.** Beyond the fields above: `s_flags` (`SB_RDONLY`, `SB_NOSUID`, `SB_NODEV`, `SB_NOEXEC`, `SB_SYNCHRONOUS`, `SB_LAZYTIME`, `SB_I_VERSION`…), `s_iflags` for internal flags, `s_bdev` and `s_bdi` (the backing device and its writeback context), `s_inodes` (every inode of this filesystem, used at unmount, sync and for dropping caches), a per-superblock **shrinker** plus LRU lists for its dentries and inodes (so memory reclaim is per filesystem and NUMA-aware), `s_user_ns` (the user namespace that owns it, which decides who may mount and how IDs are interpreted), `s_uuid`, `s_id`, `s_fs_info` (the filesystem's private data), and the reference counts `s_count` (structure lifetime) and `s_active` (active mounts).

**Locking.** `s_umount`, a read/write semaphore, protects the superblock against unmount and remount: operations that need the filesystem to stay mounted (sync, freeze, quota) take it for reading; unmount and remount take it for writing. The global `sb_lock` protects the superblock lists. Per-inode and per-dentry locking is separate.

**Syncing.** `sync(2)` and `syncfs(2)` call `sync_filesystem()`, which writes back dirty inodes and pages via the backing device's writeback machinery, then calls `sync_fs` so the filesystem can commit its journal or transaction, and flushes the block device.

**Freezing.** Snapshots (LVM, device-mapper), backups and the `FIFREEZE` ioctl need the filesystem in a consistent, unchanging state on disk. `freeze_super()` does this in stages, tracked in per-superblock counters that writers enter and leave:
1. **`SB_FREEZE_WRITE`** — new `write()`-style modifications block; page faults still allowed.
2. **`SB_FREEZE_PAGEFAULT`** — page-fault writes block too; the filesystem is then synced, and no new dirty pages or inodes can appear during the sync.
3. **`SB_FREEZE_FS`** — internal modification sources block too (for example XFS truncating preallocations during inode reclaim), usually by refusing new transactions; then `freeze_fs` is called.
Thawing reverses the process. Because block-device freezes, `FIFREEZE`, suspend and internal users can all freeze the same filesystem, freezes carry a **holder** (user space vs. kernel) and may be allowed to **nest** (`FREEZE_MAY_NEST`), so one party's thaw can't undo another's freeze. Getting the interplay between device-level and filesystem-level freezes right has been an ongoing source of fixes.

**Remount.** Changing options on a live superblock (for example read-write to read-only) goes through the context's `reconfigure` method. Going read-only requires that no file is open for writing and that everything is synced; the filesystem then stops accepting changes.

**Unmount.** When the last mount goes away (`s_active` drops to zero), `deactivate_locked_super()` calls the type's `kill_sb`, usually `kill_block_super()` or `kill_anon_super()`, which calls `generic_shutdown_super()`: evict every dentry and inode (`evict_inodes()`), sync, call `put_super`, and release the device. The structure is freed once `s_count` also reaches zero. Lazy unmount detaches the mount point immediately but only kills the superblock when the last user leaves.

## Key Data Structures

**`struct super_block`** (`include/linux/fs.h`)
- `s_type`, `s_op`, `s_export_op`, `s_xattr`, `s_d_op` — type and operations
- `s_root` — root dentry
- `s_blocksize`, `s_blocksize_bits`, `s_maxbytes`, `s_magic`, `s_time_gran`, `s_time_min`/`s_time_max` — limits
- `s_flags`, `s_iflags` — mount and internal flags
- `s_bdev`, `s_bdi`, `s_dev` — backing device and writeback context
- `s_umount` — unmount/remount rwsem
- `s_writers` — freeze level and per-level writer counters
- `s_inodes`, `s_inode_lru`, `s_dentry_lru`, `s_shrink` — inode list and reclaim
- `s_user_ns`, `s_uuid`, `s_id` — ownership and identity
- `s_fs_info` — filesystem-private data
- `s_count`, `s_active` — lifetime and active mount counts

**`struct file_system_type`** — `name`, `fs_flags`, `init_fs_context`, `parameters`, `kill_sb`, `owner`, `fs_supers`.

**`struct fs_context`** — mount configuration in progress: `fs_type`, `ops`, `fs_private`, `root`, `sb_flags`, `source`, `user_ns`, `purpose` (new mount, submount or reconfigure), and a log for error messages.

## Key Functions / Entry Points

**`register_filesystem()`** (`fs/filesystems.c`) — add a filesystem type.
**`get_tree_bdev()` / `get_tree_nodev()` / `get_tree_single()` / `get_tree_keyed()`** (`fs/super.c`) — superblock lookup-or-create strategies.
**`sget_fc()`** — find a matching superblock or allocate one.
**`d_make_root()`** — create the root dentry in `fill_super`.
**`sync_filesystem()`** — writeback plus `sync_fs`.
**`freeze_super()` / `thaw_super()`** — staged freeze and thaw.
**`generic_shutdown_super()` / `kill_block_super()` / `kill_anon_super()`** — unmount teardown.
**`fsopen()`, `fsconfig()`, `fsmount()`, `fspick()`, `move_mount()`** (`fs/fsopen.c`, `fs/namespace.c`) — new mount API system calls.

## Important Flags & Config Options

- `file_system_type.fs_flags`: `FS_REQUIRES_DEV`, `FS_BINARY_MOUNTDATA`, `FS_USERNS_MOUNT` (mountable in user namespaces), `FS_ALLOW_IDMAP`, `FS_MGTIME`, `FS_RENAME_DOES_D_MOVE`.
- `SB_*` flags from mount options: `SB_RDONLY`, `SB_NOSUID`, `SB_NODEV`, `SB_NOEXEC`, `SB_SYNCHRONOUS`, `SB_DIRSYNC`, `SB_LAZYTIME`, `SB_I_VERSION`, `SB_POSIXACL`.
- Freeze levels `SB_FREEZE_WRITE`, `SB_FREEZE_PAGEFAULT`, `SB_FREEZE_FS`, `SB_FREEZE_COMPLETE`; freeze holders `FREEZE_HOLDER_USERSPACE`, `FREEZE_HOLDER_KERNEL`, `FREEZE_MAY_NEST`.
- `/proc/filesystems`, `/proc/self/mountinfo`, `fsfreeze(8)`, `/proc/sys/vm/drop_caches`.

## Interactions with Other Subsystems

- **↑ Userspace**: `mount`, `fsopen`/`fsconfig`/`fsmount`, `umount`, `statfs`, `sync`/`syncfs`, `FIFREEZE`/`FITHAW`, `/proc/mounts`.
- **→ [[inode]] / [[inode-cache]]**: allocates, writes back and evicts inodes through `s_op`; tracks all of them in `s_inodes`.
- **→ [[dentry-cache]]**: owns the root dentry and a per-superblock dentry LRU.
- **→ [[mount-namespace]]**: mounts point to a superblock's root; one superblock can back many mounts.
- **→ [[writeback-infrastructure]]**: the backing device's writeback context flushes dirty data and inodes.
- **← [[filesystem-registration]]**: filesystem types create superblocks through their mount context.
- **← [[device-mapper]] / LVM**: snapshots freeze the filesystem on top via the block device.
- **→ [[user-namespaces]]**: `s_user_ns` decides who may mount and how IDs are mapped.

## Design Decisions & Tradeoffs

- **One superblock, many mounts.** Sharing a superblock between mounts of the same device keeps caches coherent, but means a second mount can silently get the first mount's options; the 6.6 "superblock reuse" flag lets user space detect this.
- **Staged configuration instead of one option string.** The fs_context API parses options one at a time with declared types and reports detailed errors, at the cost of converting every filesystem and maintaining two user-facing interfaces. Clean-ups to `fsconfig()` behaviour were still being discussed in 2026.
- **Staged freezing.** Blocking writes, then faults, then internal activity avoids deadlocks and dirty data sneaking in during the final sync, but requires every modification path to enter and leave the freeze counters correctly.
- **Per-superblock reclaim.** Dentry and inode LRUs and shrinkers per superblock make reclaim fairer and NUMA-aware, and let filesystems add their own caches, at the cost of more complex shrinker bookkeeping.

## How It Has Evolved

- **2.6.x** — `get_sb()` mount methods; `freeze_super()`/`thaw_super()` added for the `FIFREEZE` ioctl (2.6.35).
- **3.x** — per-superblock shrinkers and LRU lists; staged freeze levels with per-level writer counters.
- **4.x** — `s_user_ns` and `FS_USERNS_MOUNT` for mounting in user namespaces.
- **5.2 (2019)** — new mount API: `fs_context`, `fsopen`, `fsconfig`, `fsmount`, `fspick`, `move_mount` (David Howells); filesystems converted over the following releases.
- **6.6** — detect superblock reuse; freeze holders; reworked block-device/superblock relationship (Christian Brauner, Jan Kara).
- **6.13** — `FS_MGTIME` opt-in for multigrain timestamps.
- **Ongoing** — fixes to freeze nesting between block-device and filesystem freezes; `fsconfig()` clean-ups.

## Further Reading

1. [VFS: Provide new mount UAPI — LWN](https://lwn.net/Articles/780268/)
2. [VFS: Introduce filesystem context — LWN](https://lwn.net/Articles/752298/)
3. [Cleanup on aisle fsconfig() — LWN (2026)](https://lwn.net/Articles/1054228/)
4. [fs: allow userspace to detect superblock reuse — LWN](https://lwn.net/Articles/939937/)
5. [Introduce freeze_super and thaw_super for the fsfreeze ioctl — LWN](https://lwn.net/Articles/379862/)
6. [Overview of the Linux Virtual File System — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/vfs.html)
7. [Linux Filesystems API summary — kernel docs](https://static.lwn.net/kerneldoc/filesystems/api-summary.html)

## LKML Highlights

> lore.kernel.org was unreachable (TLS certificate error) during this session; summarised from LWN and list archives.

- **"VFS: Introduce filesystem context" (David Howells, 2018–2019)** — replaced the single option-string `mount(2)` with a staged configuration object and new system calls, after many revisions over whether errors could be reported meaningfully.
- **"fs: allow userspace to detect superblock reuse" (2023)** — addressed mounts that silently reused an existing superblock with different options.
- **"Cleanup on aisle fsconfig()" (2026)** — revisited inconsistent handling of conflicting parameters, noting the in-context message log holds only eight entries before it overflows.
