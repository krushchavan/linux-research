---
title: "Virtual File System (VFS) — Explained"
category: explained
original: "[[vfs]]"
subsystem: vfs
tags: [explained, vfs, dcache, path-lookup, mount-api]
converted: 2026-09-25
---

# The Virtual File System (VFS), explained

> Plain-language companion to [[vfs|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Linux runs dozens of filesystems: ext4, btrfs and XFS on disks, tmpfs in memory, NFS and SMB over the network, `/proc` generated on the fly. Programs shouldn't care which one they're using. `open("/etc/passwd")` has to work the same everywhere, and other kernel code (memory management, security modules, namespaces) needs one consistent place to hook in.

That common layer also sits on the hottest path in the system. Every file name passes through it, often on many cores at once, so it has to cache aggressively and avoid lock contention.

(This note covers VFS internals: the name cache, path lookup, mounting and registration. For the broader overview, see [[fs-explained|the filesystem subsystem]].)

## The big picture

VFS is a **dispatch table in the shape of a tree**. The **dentry cache** is the tree: every path component ever looked up is kept as a dentry, linked parent to child like the directory hierarchy. Each dentry points to an inode, and each inode points to a table of operations supplied by its filesystem. A call like `open` is, at heart, a walk down the tree followed by a jump through a table. Superblocks are the roots of subtrees; mounts are the joins between them.

```text
 syscalls: open / read / write / stat / mount
      │
  path lookup ──▶ dentry cache ── miss ──▶ filesystem's lookup (ext4, btrfs, tmpfs, NFS…)
      │              │ hit
      │           inode ──▶ page cache
      ▼              │
  open file ─────────┘        filesystem ──▶ block layer / network
  (fd)                        superblock ──▶ registered filesystem type
```

## The pieces

### The dentry cache
Each **dentry** is one path component. They sit in a global hash table keyed by (parent, name), searched under RCU. On a hit the dentry comes back; on a miss the parent directory's lookup method is called, and the result is cached. Dentries can be:
- **positive:** the name maps to a live inode
- **negative:** the name is known *not* to exist, sparing repeated failed lookups (important for shells searching `$PATH`)
- **unused:** no references, on an LRU list and eligible for eviction
- **in use:** referenced by open files, working directories and so on

Under memory pressure, a shrinker walks the LRU and frees unused dentries (tunable through a vm setting), which can make rarely used paths slower to look up again. Each dentry packs its lock and reference count into one word, so references can often be taken without the lock. See [[dentry-cache-explained|the dentry cache]].

### Path lookup
Path lookup turns a string into a (mount, dentry) pair, for `open`, `stat`, `rename`, `unlink`, `mkdir` and all the rest. It walks one component at a time, keeping its position, the effective root, the current component and sequence-number snapshots in a small walk record. It runs in two modes:
1. **RCU-walk**, the fast path: no reference counts, no writes to shared memory, just reads followed by checks of per-dentry sequence counters (and a global mount counter at mount points) to confirm nothing changed.
2. **REF-walk**, the fallback: takes references and directory locks. Used when RCU-walk hits a concurrent rename, a cache miss, or anything that must sleep.

Reaching a dentry that has something mounted on it switches to that filesystem's root. Symlinks are followed with a bounded stack (at most 40); special links like `/proc/self/exe` return a location directly. See [[path-lookup-explained|path lookup]].

### Mounts and mount namespaces
Each mounted filesystem instance is a **mount** recording its superblock, root dentry, where it's grafted, its parent mount and its namespace. A **mount namespace** is a per-process view of the mount tree; creating a new one copies it, and later mounts in one don't affect the other. Shared, slave, private and unbindable propagation control which mounts spread between views, the basis of systemd mount units and container mounts. A global sequence lock keeps mount crossings consistent with concurrent unmounts. See [[mount-namespace-explained|mount namespaces]].

### Registering filesystems and the mount API
Filesystems register a **filesystem type** at module load: a name, how to set up a mount, how to tear down a superblock, and capability flags (needs a device, mountable in a user namespace, supports idmapped mounts).

The old way passed a mount callback an opaque option string. Options were parsed deep inside the filesystem while a superblock was half built, so errors were hard to report and partial set-ups hard to undo. The new API (5.1) builds a mount step by step:
1. **open a context** for a filesystem type, with defaults filled in
2. **configure** options one at a time, each validated immediately, with errors reported right there
3. **create** the mount: find a suitable existing superblock or make a new one, producing a detached mount
4. **attach** it at a mount point in a chosen namespace

This is the key design change in mounting: *what* to mount is fully checked before *where* it goes, and configuration can happen before anything is committed. See [[filesystem-registration-explained|filesystem registration]].

### The inode cache
Inodes are cached by (superblock, inode number) in a hash table. A filesystem's lookup asks the cache first; on a miss it gets a new, locked inode to fill in from disk. Each superblock also lists all its inodes, for unmount, sync and memory reclaim. Inodes are reference-counted; marking one dirty puts it on its backing device's writeback list; when its count hits zero it's evicted at once if deleted (no links left), otherwise kept on an LRU until reclaimed. See [[inode-cache-explained|the inode cache]].

### Event hooks (fsnotify)
VFS is the natural place to report file events. Small inline hooks at create, unlink, mkdir, rmdir, rename, open, read, write and attribute changes feed inotify and fanotify. Each hook is essentially free when nobody is watching: it checks for watchers on the inode or superblock first. fanotify can also pause an operation until a user-space daemon allows or denies it. See [[fsnotify-explained|fsnotify]].

## A request's journey

`open("/etc/passwd")`, then a read:

1. **Start fast.** Path lookup begins in RCU-walk at the root.
2. **"etc" is cached.** The dentry cache has it: a hit with no reference taken.
3. **"passwd" misses.** Lookup switches to REF-walk and asks ext4 to look the name up.
4. **Fetch the inode.** ext4 asks the inode cache, gets a fresh locked inode, reads it from disk and fills it in; a dentry for "passwd" is created and cached.
5. **Open.** VFS allocates an open-file object with the inode's file operations, lets ext4 run its open hook, and returns a descriptor. This is where the name-to-object dispatch pays off: from here on, operations go straight through the file's table.
6. **Read.** The read misses in the page cache, so ext4 reads the page from disk through the block layer, and the data is returned.

## Tradeoffs

- **What it gives you:** one interface for every filesystem; hard links, concurrent opens and shared superblocks handled by the four-object model (superblock, inode, dentry, file); lookups that scale across cores; and single hook points for security modules, namespaces and notifications.
- **What it costs / requires:** an indirect call on every operation; RCU-walk's complexity (sequence checks on every read, RCU-safe freeing of inodes); locking when negative dentries are replaced by newly created files.
- **Where it bites:** dcache and icache eviction under memory pressure makes cold lookups slow. Idmapped mounts need filesystems to opt in before the VFS will translate IDs for them.

## How it got here

- **0.x–1.x:** a minimal VFS modelled on Sun's design, with the four objects but no dentry cache.
- **2.0 (1996):** the dentry cache. **2.4 (2001):** a separate address space for page-cache management.
- **2.6.12 (2005):** mount namespaces as a first-class feature. **2.6.38 (2011):** RCU-walk, the biggest multi-core scalability gain.
- **3.9 (2013):** the combined lock-and-count in dentries.
- **5.1 (2019):** the new mount API (Al Viro). **5.12 (2021):** idmapped mounts (Christian Brauner), per-mount ID translation for rootless containers without changing each filesystem.
- **6.x:** fanotify pre-content hooks (6.6), FUSE over io_uring (6.12), and more flexible detached and nested idmapped mounts (6.15). In progress: a large rework of inode reference counting (Josef Bacik, 2025), Landlock expansion, larger folios, and unprivileged mount management.

## Related

- Technical version: [[vfs]]
- [[fs-explained|Filesystem subsystem]], [[core-in-memory-structures-explained|Core VFS objects]], [[vfs-locking-model-explained|VFS locking model]]
- [[dentry-cache-explained|Dentry cache]], [[path-lookup-explained|Path lookup]], [[mount-namespace-explained|Mount namespaces]], [[filesystem-registration-explained|Filesystem registration]], [[inode-cache-explained|Inode cache]], [[fsnotify-explained|fsnotify]]
- [[page-cache-explained|Page cache]], [[address-space-explained|Address space]], [[fuse-explained|FUSE]], [[nfs-explained|NFS]], [[overlayfs-explained|OverlayFS]]
