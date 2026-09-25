---
title: "Linux Filesystem Subsystem (VFS) — Explained"
category: explained
original: "[[fs]]"
subsystem: fs
tags: [explained, fs, vfs, dcache, writeback]
converted: 2026-09-25
---

# The Linux filesystem subsystem (VFS), explained

> Plain-language companion to [[fs|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Linux supports dozens of filesystems: ext4, btrfs, XFS, tmpfs, NFS, procfs and more. Some live on disks, some on the network, some are made up on the fly by the kernel. Programs shouldn't have to care which one they're using: `open`, `read`, `write`, `stat` and `unlink` must work the same everywhere.

At the same time, the common work (turning a path into a file, caching names and file data, writing dirty data back, notifying watchers) shouldn't be reimplemented by every filesystem, and it has to be fast on machines with many cores.

## The big picture

The **Virtual File System** (VFS) is an **object-oriented plugin framework written in C**. It defines four core objects (superblock, inode, dentry and file) and, for each, a table of operations. A concrete filesystem registers itself and supplies its own versions of those operations. VFS drives every system call from start to finish and calls into the filesystem only where storage-specific knowledge is needed. Programs never know which filesystem they're talking to.

```text
 program: open / read / write / stat
            │ system call
            ▼
 ┌──────────────────── VFS ────────────────────┐
 │ path lookup ──▶ dentry cache (names)         │
 │ open file objects  ·  inodes  ·  superblocks │
 │ page cache (file data) ◀─▶ writeback workers │
 │ fsnotify (watchers)                          │
 └──────┬──────────────┬──────────────┬─────────┘
        ▼              ▼              ▼
      ext4           btrfs      tmpfs / NFS / procfs ...
        │              │              │ (memory, network, or made up)
        └──── block layer ──── storage
```

## The pieces

### Superblock: one mounted filesystem

A superblock represents one *mounted instance* of a filesystem: its mount options, root directory, list of inodes, dirty inodes and the filesystem's own metadata. See [[superblock]].

1. A filesystem module registers itself with VFS.
2. Mounting calls the filesystem's mount function, which reads its on-disk superblock, builds the in-memory one with a root directory, and hands it back.
3. The filesystem supplies superblock operations: allocate an inode, write one back, sync, and tear down. VFS calls most of them without holding locks, so network filesystems can safely wait on I/O.

### Inode: one filesystem object

An inode represents a file, directory, symlink, device, FIFO or socket: everything about it *except* its name and place in the tree. See [[inode]] and [[inode-cache]].

1. For disk filesystems, an inode is a cached copy of on-disk metadata, read in by the parent directory's lookup operation and reused afterwards.
2. Hard links are several names pointing at one inode. The inode is freed only when its link count hits zero *and* nobody has it open.
3. It carries operations for creating children, following symlinks, checking permissions and getting or setting attributes, plus a pointer to the operations used when it's opened, and to its **address space** (its page cache).

### Dentry and the dentry cache: names

A dentry maps one path component to its inode. The **dentry cache** is an in-memory view of the whole namespace. Without it, opening `/usr/bin/python` would ask the filesystem about each component every time. See [[dentry]] and [[dentry-cache]].

1. Dentries live only in RAM, never on disk.
2. Lookups split the path into components and look each up in a hash table. A hit is instant; a miss asks the parent directory's filesystem, then caches the answer.
3. **Negative dentries** record that a name *doesn't* exist, so repeated failed lookups are cheap too.
4. Unused dentries are reclaimed by a shrinker under memory pressure. Mount points are attached to dentries, which is how lookups cross into mounted filesystems.

### File: one open instance

A file object is the kernel side of an open file descriptor: current position, open flags and any per-open private data. See [[file-object]] and [[file-descriptor-and-open-file-table]].

1. `open` allocates one, points it at the dentry (and so the inode), copies the inode's file operations, and calls the filesystem's open.
2. The descriptor number the program gets is an index into its descriptor table.
3. File operations are the richest table: reading and writing (the iterator-based versions are also what io_uring uses), `mmap`, locking, polling, `ioctl`, and zero-copy splicing.

### Address space: the page cache link

Every inode with data has an address space that ties the file to the page cache. See [[address-space-explained|Address space]] and [[page-cache-explained|Page cache]].

1. Cached file data is held as **folios** in an index by file offset. Reads check it and, on a miss, ask the filesystem to read a folio (or a readahead window).
2. Dirty folios are tagged and later written back by per-device writeback workers.
3. `O_DIRECT` bypasses the cache entirely.
4. Since 5.16, folios are replacing single pages throughout; filesystems that support large folios opt in, and the cache then uses multi-page blocks.

### Writeback: flushing dirty data

`write()` normally only dirties the cache; writeback gets the data to disk later, so a write doesn't wait for the device. See [[writeback-infrastructure]].

1. Dirtying a folio puts its inode on its **backing device's** dirty list. Each device (and, since 4.2, each cgroup on it) has its own worker.
2. Triggers:
   - **periodic:** every 5 seconds by default, writing data dirty for more than 30 seconds
   - **ratios:** above 10% of memory dirty, workers wake; above 20%, writers are throttled
   - **`fsync` / `sync`:** write and wait for everything in range
   - **memory pressure:** reclaim may write individual folios as a last resort
3. Per-device workers replaced a shared pool of "pdflush" threads (removed in 3.2), where one slow disk could starve an SSD of writeback threads.

### fsnotify: telling programs about changes

The common framework behind inotify, fanotify and the old dnotify. See [[fsnotify]] and [[inotify-and-fanotify]].

1. VFS calls a lightweight hook at each interesting event (create, delete, modify, access, attribute change).
2. Hooks do nothing unless someone has placed a **mark** on the object (a file, a mount or a whole filesystem), so there's no cost when nobody is watching.
3. With marks present, the event is passed to each interested group. inotify queues events per watched inode; fanotify can watch whole mounts and can even **hold a process** until a daemon (an anti-virus scanner, say) allows or denies an access.

### Path lookup: from a string to a file

Turning `/usr/bin/python` into a dentry and mount, used by nearly every file system call. See [[path-lookup]].

1. The path is walked component by component, through the dentry cache, calling the filesystem on misses.
2. **RCU-walk** (2.6.38) is the fast path: it takes no locks and touches no reference counts, checking consistency with sequence counters. This is the key to scaling on many cores, since cached lookups leave no footprint.
3. If something changes underneath (a rename, a mount change, a symlink needing to sleep), it falls back to **ref-walk**, which takes references and locks.
4. Symlinks are followed up to 40 levels deep; mount points are crossed transparently.

## A request's journey

Opening and reading `/home/user/file.txt` on ext4:

1. **System call.** `open` enters VFS, which starts a path walk.
2. **Walk the path.** "home" and "user" are found in the dentry cache; "file.txt" isn't.
3. **Ask the filesystem.** ext4's lookup reads the inode; VFS caches a new dentry for it.
4. **Create the open file.** VFS allocates a file object, copies the inode's file operations, calls ext4's open, and returns a descriptor.
5. **Read.** `read` goes through VFS to ext4's read path, which checks the page cache: a miss.
6. **Fetch from disk.** ext4 reads the folio via the block layer; it lands in the page cache.
7. **Copy out.** 4096 bytes are copied to the program's buffer. Next time, it's a cache hit.

Later, if the program writes, the folio is dirtied and its inode queued on the device's dirty list; a writeback worker eventually calls ext4 to write it out, and writers are throttled if dirty data piles up.

## Tradeoffs

- **What it gives you:** one interface for every filesystem, self-contained new filesystems (pseudo-filesystems like procfs never touch a disk), near-free repeated path lookups, and scalable lock-free lookup.
- **What it costs / requires:** an indirect call on every filesystem operation; memory for dentries of every path ever looked up.
- **Where it bites:** when memory is tight, the dentry-cache shrinker can cause lookup latency spikes. Separating names from inodes makes hard links and atomic renames clean, but it adds complexity for filesystems (like NFS) that must reconcile the two.

## How it got here

- **Before 2.0:** a thin layer over ext and minix; the four-object model came from Sun's VFS when Linux gained NFS.
- **2.4:** the dentry cache became central and the address space was introduced.
- **2.6:** inode locking became a read/write semaphore; zero-copy splice and sendfile.
- **2.6.38 (2011):** RCU-walk path lookup, removing VFS's biggest multi-core bottleneck.
- **3.x:** a combined lock-and-count for dentries to reduce cache-line bouncing; per-device writeback replaced pdflush (3.2).
- **5.1 (2019):** a new mount API that validates options before anything is written, and enables privilege-separated mounting for containers.
- **5.12–6.15:** idmapped mounts (a filesystem shown to a container with remapped user and group IDs), FUSE support for them, and more mount APIs for containers.

## Related

- Technical version: [[fs]]
- [[vfs]]: the VFS deep dive
- [[superblock]], [[inode]], [[dentry]], [[dentry-cache]], [[file-object]], [[path-lookup]]
- [[address-space-explained|Address space]], [[page-cache-explained|Page cache]], [[writeback-infrastructure]]
- [[fsnotify]], [[inotify-and-fanotify]]
- [[mm-explained|Memory management]], [[block-explained|Block layer]], [[btrfs-explained|Btrfs]], [[nfs]], [[fuse]]
- [[lsm-framework|LSM framework]], [[mount-namespace]]
