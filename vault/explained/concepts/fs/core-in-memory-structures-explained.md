---
title: "Core VFS In-Memory Structures — Explained"
category: explained
original: "[[core-in-memory-structures]]"
subsystem: fs
tags: [explained, fs, vfs, inode, dentry]
converted: 2026-09-25
---

# The core VFS in-memory objects, explained

> Plain-language companion to [[core-in-memory-structures|the technical note]]. Same facts, fewer identifiers.

## The problem

When a program reads a file, the kernel is juggling several separate questions at once: which filesystem is this on, what are this file's size and permissions, what is it called and where in the tree, where is that filesystem mounted, which parts of it are cached in memory, and who has it open at what position?

Each question has a different lifetime and different sharing rules. Many names can point to one file; many processes can open one file; one filesystem can be mounted in several places. Stuffing all of this into one object wouldn't work. Nearly every filesystem code path passes through these objects, so understanding how they fit together is the prerequisite for following any of it.

## The idea in one paragraph

Use **six objects, each answering one question**, linked into a graph. From a process's point of view the chain is: file descriptor → **open file** → (**name** + **mount**) → **inode** → **address space** → cached pages, with every object also pointing back at its **superblock**. Each object comes with a table of operations supplied by the filesystem, and VFS only ever calls filesystem code through those tables.

| Object | Question it answers |
|---|---|
| superblock | Which mounted filesystem instance am I on? |
| inode | What are this file's metadata and where is its data? |
| dentry | What is this file called, and where in the tree? |
| mount | Where is this filesystem attached? |
| address space | Which of this file's pages are cached? |
| file | Who has it open, with what flags, at what position? |

## Step by step

### Step 1: Superblock: one mounted filesystem
One per mounted filesystem instance (bind mounts share it). It holds the block size, the filesystem's magic number, its root directory, a list of all its live inodes and unused inodes, the device used for writeback, the last writeback error, and a pointer to the filesystem's own private data. Its operations cover allocating and freeing inodes, writing inode metadata, evicting inodes, syncing, freezing for snapshots, reporting statistics and cleaning up at unmount. It's built at mount time and destroyed when the last mount goes.

### Step 2: Inode: one filesystem object
A file, directory, symlink, device, socket or pipe, identified by (filesystem, inode number). It holds type and permissions, owner, flags such as immutable or append-only, size, timestamps, link count, a reference count and state flags, plus the list of names (dentries) pointing at it. It has two operation tables: one for metadata (look up, create, link, unlink, rename, permission, attributes), and the default operations to use when it's opened.

Most filesystems wrap the inode inside a bigger private structure of their own and get back to it by pointer arithmetic.

### Step 3: Dentry: a name
Caches the result of resolving one path component: a name and its parent, plus the inode it refers to (a **positive** dentry) or a record that no such file exists (a **negative** one). It has a sequence counter that lets lock-free path lookup check it hasn't changed, a combined lock and reference count, links to its children, and an optional operations table (network filesystems use it to revalidate cached names). The global dentry cache is the main accelerator for path lookup.

### Step 4: Mount: where a filesystem is attached
The public part says which root directory and superblock a mount uses, its flags (no-setuid, read-only...), and its ID mapping. The internal part adds where it's attached in its parent, which mount namespace it belongs to, its child mounts, and links for mount propagation between shared subtrees. A global hash table maps (parent mount, mountpoint dentry) to the mount, so crossing into a mounted filesystem during lookup is a constant-time step.

### Step 5: Address space: cached data
Every inode embeds one; it holds the cached pages (folios) in an index, the tree of every memory mapping of the file, counts, where writeback should resume, the last writeback error, and the filesystem's page-cache operations. See [[address-space-explained|Address space]].

### Step 6: File: one open
The only truly per-open object (shared between processes only through `dup` or `fork`). It records the path it was opened by (mount + dentry), shortcuts to the inode and address space, the operations table copied from the inode at open, a reference count, open flags and access mode, the current position with a lock for multi-threaded use, a per-open cursor for writeback errors, and private data for the driver.

### Step 7: Operations tables are the plugin interface
This is the key design point. Each object has its own table, provided by the filesystem (inode tables can differ for files and directories). VFS never calls filesystem code directly; it always goes through a table. That's what lets hundreds of filesystem types coexist behind one set of system calls.

### Step 8: Lifetimes and caching
Objects are created lazily and cached aggressively:
- superblock: from mount until the last unmount
- inode: from first lookup or creation; cached by (filesystem, number); freed when unused and memory is needed
- dentry: one per distinct path component looked up; reclaimed under memory pressure
- mount: from `mount` to `umount`
- file: from each `open` until the last reference is dropped
- cached pages: from a cache miss until reclaim evicts them

## The picture

```text
 process ─▶ descriptor table ─▶ [ file ] position, flags, ops
                                  │
                   ┌──────────────┼──────────────┐
                   ▼              ▼              ▼
               [ mount ]      [ dentry ] ─────▶ [ inode ] ─▶ [ address space ] ─▶ cached folios
                   │           "file.txt"        size, mode      page index
                   │             │ parent        │ ops
                   ▼             ▼                ▼
             [ superblock ] ◀── all point back to their filesystem instance
```

## Tradeoffs

- **What it gives you:** each concern has its own object and lifetime, so hard links (many names, one inode), shared opens, bind mounts and aggressive caching all fall out naturally, and any filesystem can plug in through operation tables.
- **What it costs / requires:** an indirect call through a table for every filesystem operation, and several objects to allocate and track per open file.
- **Where it bites:** getting the reference counting and lifetimes right across six linked objects is subtle; much VFS bug-fixing is about exactly that.

## How it got here

The source note doesn't give a separate history for these objects; see the [[fs-explained|filesystem subsystem overview]] for how VFS evolved from its Sun-inspired four-object model.

## Related

- Technical version: [[core-in-memory-structures]]
- [[fs-explained|Filesystem subsystem (VFS)]]: the overview
- [[superblock]], [[inode]], [[dentry-explained|dentry]], [[dentry-cache-explained|dentry-cache]], [[inode-cache-explained|inode-cache]], [[file-object-explained|file-object]], [[mount-namespace-explained|mount-namespace]]
- [[address-space-explained|Address space]], [[page-cache-explained|Page cache]], [[path-lookup-explained|path-lookup]]
