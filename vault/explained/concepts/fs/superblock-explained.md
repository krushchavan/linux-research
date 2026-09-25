---
title: "Superblock (struct super_block) — Explained"
category: explained
original: "[[superblock]]"
subsystem: fs
tags: [explained, fs, vfs, superblock, mount]
converted: 2026-09-25
---

# The superblock, explained

> Plain-language companion to [[superblock|the technical note]]. Same facts, fewer identifiers.

## The problem

Some things belong to a whole filesystem rather than to any one file: its block size and limits, whether it's read-only, its root directory, the list of all its inodes, the code that implements it, the device underneath, and how to sync, freeze or unmount it. They need one home. That home must also work for filesystems with no disk at all (tmpfs, procfs), and must let the same filesystem appear at several places in the directory tree without two diverging copies of its caches.

## The idea in one paragraph

A superblock is the **head office of one mounted filesystem instance**. Mount points are only street addresses pointing to it, and several addresses can share one office, as with bind mounts or mounting the same device twice. The office keeps the staff list (every inode), the procedures manual (the filesystem's operation table), the company rules (flags and limits) and the front door (the root dentry). For a stocktake (a **freeze**) it stops new work in stages; when the last address pointing to it disappears, it closes down. A block filesystem's on-disk "superblock" is the persistent record of some of this; the in-memory superblock is what the kernel actually works with.

## Step by step

### Step 1: Register the filesystem type
A filesystem type registers itself with a name (listed in /proc/filesystems), flags (needs a block device? mountable inside user namespaces? supports fine-grained timestamps?), a function that starts a mount, a table describing its mount options, and a function to tear an instance down.

### Step 2: Build a mount configuration
Since the **new mount API** (5.2, David Howells), mounting has two phases. First a **filesystem context** is created, and each option is parsed and checked one at a time against the declared table, with errors logged into the context instead of lost. Only when configuration is complete is the filesystem created. The classic `mount()` call does all of this inside the kernel; new system calls expose the phases to user space: open a context, configure it option by option and create, turn the result into a detached mount, then move it into place. Another call reopens an existing filesystem's context for reconfiguration.

### Step 3: Find or create the superblock
This is the key step. The filesystem picks a sharing strategy: one superblock per block device, a new one every time (tmpfs), one for the whole system, or one per key such as a namespace. The kernel searches the type's existing superblocks with a match test. If one matches, it's **reused**, which is how mounting the same device twice gives one shared instance with one set of caches. Otherwise a new superblock is allocated and given an identity (an anonymous device number for disk-less filesystems), and the filesystem's **fill** function reads and checks the on-disk superblock, sets block size, maximum file size, magic number, operation tables and timestamp limits, reads the root inode and creates the root dentry. The superblock becomes active and a mount pointing at its root is created. Since 6.6, user space can tell when a mount reused an existing superblock, because silently ending up with the first mount's options was a long-standing surprise.

### Step 4: The procedures manual
The filesystem's superblock operations cover:
- inode memory: allocate (usually a bigger filesystem structure with the VFS inode inside), destroy, free after an RCU grace period
- inode lifecycle: note it's dirty, write it back, decide whether to keep it cached, evict it
- sync everything (for example commit the journal), freeze and unfreeze
- statistics for `df`, cleanup at unmount, what `/proc/mounts` shows, forced-unmount notice for network filesystems
- letting private caches join memory reclaim, and an emergency shutdown when the device vanishes

### Step 5: What else it keeps
Mount flags (read-only, nosuid, nodev, noexec, synchronous, lazytime…), the backing device and its writeback context, the list of all its inodes (used by unmount, sync and cache dropping), **per-filesystem LRU lists and shrinkers** for its dentries and inodes (so memory reclaim is per filesystem and NUMA-aware), the owning user namespace (who may mount it and how IDs are read), a UUID, private filesystem data, and two counters: one for the structure's lifetime and one for active mounts.

### Step 6: Locking
A reader/writer semaphore guards against unmount and remount. Work that needs the filesystem to stay mounted (sync, freeze, quota) takes it for reading; unmount and remount take it for writing. A global lock protects the lists of superblocks.

### Step 7: Sync
`sync` and `syncfs` write back dirty inodes and pages through the backing device's writeback machinery, then call the filesystem's sync hook so it can commit its journal or transaction, then flush the device.

### Step 8: Freeze, in stages
Snapshots (LVM, device-mapper), backups and the freeze ioctl need the filesystem consistent and unchanging on disk. Freezing goes in three stages, tracked by counters every writer enters and leaves:
1. **block new writes**; page faults still allowed
2. **block page-fault writes too**, then sync, knowing no new dirty pages or inodes can appear during the sync
3. **block internal activity** as well (for example XFS trimming preallocations when reclaiming inodes), usually by refusing new transactions, then call the filesystem's freeze hook

Thawing reverses it. Since device-level freezes, the freeze ioctl, suspend and kernel users can all freeze the same filesystem, each freeze records a **holder** (user space or kernel) and may be allowed to **nest**, so one party's thaw can't undo another's freeze. The interplay between device and filesystem freezes is still producing fixes.

### Step 9: Remount and unmount
Changing options on a live filesystem goes through the context's reconfigure step; going read-only requires that nothing is open for writing and everything is synced. When the last mount goes, the filesystem's kill function runs the generic shutdown: evict every dentry and inode, sync, call the filesystem's cleanup, release the device. The structure itself is freed when its lifetime count reaches zero. A lazy unmount detaches the mount point at once but shuts the filesystem down only when its last user leaves.

## The picture

```text
 fsopen("ext4") → fsconfig(option by option) → create
      │ find matching superblock for /dev/sdb1?
      ├─ yes → reuse (same caches, same options)
      └─ no  → allocate → fill: read disk superblock, root inode, root dentry
                              │
 mounts: /data ─┐             ▼
 /bind  ────────┴──▶ superblock: flags, limits, ops, root, inode list, LRUs, bdi
 freeze: writes ✗ → faults ✗ + sync → internal ✗ + freeze hook
 last mount gone → evict inodes, sync, cleanup, release device
```

## Tradeoffs

- **What it gives you:** one place for filesystem-wide state and behaviour; coherent caches when a filesystem is mounted in several places; staged, detailed mount configuration; safe freezing for snapshots; per-filesystem memory reclaim.
- **What it costs / requires:** two mount interfaces to maintain; every modification path must enter and leave the freeze counters correctly; per-filesystem shrinkers add bookkeeping.
- **Where it bites:** superblock reuse means a second mount can quietly get the first mount's options (now detectable). Clean-ups to how the configuration call handles conflicting options were still being discussed in 2026, including that the context's message log holds only eight entries before overflowing. Nested freezes by different holders keep needing fixes.

## How it got here

- **2.6.x:** older single-call mount methods; freeze and thaw added for the freeze ioctl (2.6.35).
- **3.x:** per-filesystem shrinkers and LRU lists; staged freeze levels.
- **4.x:** owning user namespaces and mounts inside user namespaces.
- **5.2 (2019):** the new mount API (David Howells), with filesystems converted over the following releases.
- **6.6:** superblock-reuse detection, freeze holders, and reworked device/superblock relationships (Christian Brauner, Jan Kara).
- **6.13:** filesystems can opt into fine-grained timestamps.

## Related

- Technical version: [[superblock]]
- [[inode-explained|Inode]], [[inode-cache-explained|Inode cache]], [[dentry-cache-explained|Dentry cache]], [[core-in-memory-structures-explained|Core VFS structures]], [[filesystem-registration-explained|Filesystem registration]], [[mount-namespace-explained|Mount namespaces]]
- [[writeback-infrastructure-explained|Writeback]], [[device-mapper-explained|Device mapper]], [[user-namespaces-explained|User namespaces]], [[vfs-explained|VFS]]
