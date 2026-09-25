---
title: "Inode (struct inode) — Explained"
category: explained
original: "[[inode]]"
subsystem: fs
tags: [explained, fs, vfs, inode, permissions]
converted: 2026-09-25
---

# The inode, explained

> Plain-language companion to [[inode|the technical note]]. Same facts, fewer identifiers.

## The problem

Every file, directory, symlink, device node, pipe or socket needs somewhere in the kernel to keep its facts: type, permissions, owner, size, link count, timestamps, where its data is cached, and which filesystem code handles it. Dozens of filesystems each store these facts differently on disk, yet permission checks, `stat()`, the page cache and directory operations all need to read them the same way. And the facts must stay separate from **names** (one file can have many hard links) and from **open instances** (one file can be open many times).

## The idea in one paragraph

An inode is a **case file with a standard cover sheet**. The cover sheet, the VFS inode, has boxes every filesystem fills in the same way: type, permissions, owner, size, dates, link count, plus a slip naming the department that handles it (its operation tables). Behind the cover, each filesystem staples its own pages, such as extent maps and on-disk locations, which the VFS never reads. The VFS works only from the cover sheet and calls the named department whenever it needs something filesystem-specific. Names live in dentries and open-file state in file objects. How inodes are cached and reclaimed is in [[inode-cache-explained|the inode cache note]].

## Step by step

### Step 1: Born inside a bigger structure
A filesystem rarely allocates a bare VFS inode. It allocates its own larger structure (ext4's per-inode information, for example) with the VFS inode **embedded** inside, and gets back to its private part from the embedded one by pointer arithmetic. That saves an allocation and a pointer hop on every operation. An inode comes into being in one of two ways:
- **Loading an existing file:** a directory lookup finds the inode number and asks the cache for it. On a hit, the cached inode is returned. On a miss, a new one is created and returned **locked and marked new**, so anyone else looking up the same number waits while the filesystem reads it from disk; then it's unlocked and published.
- **Creating a new file:** create, mkdir, mknod, symlink or tmpfile allocate a fresh inode, set its owner (applying the parent directory's setgid rule and the caller's ID mapping), allocate it on disk, and attach it to the new name.

### Step 2: What's on the cover sheet
- **identity and type:** inode number, owning superblock, type plus permission bits, device number for device nodes, and a generation number that tells reuses of the same inode number apart (NFS file handles depend on it)
- **ownership:** user and group, stored as kernel IDs so user namespaces and ID-mapped mounts can translate them
- **size and space used**, and the **link count** (changed only through dedicated helpers)
- **timestamps:** access, modification and change times
- **operation tables:** one for name and attribute operations, one copied into every open file
- **data:** a pointer to the inode's page cache
- **state:** flags, a reference count, locks, and membership in hash, LRU, superblock and writeback lists
- **extras:** pipe, character-device or symlink-text pointers, private filesystem data, and a **change counter** for NFS

### Step 3: What the operation table does
Directory inodes implement the namespace: look up a name, create, link, unlink, symlink, mkdir, rmdir, mknod, rename (including "don't replace" and "swap" variants), plus optional **atomic open** (look up, create and open in one step, important for network filesystems) and **tmpfile** (an unnamed file). Symlinks provide their target, possibly during lock-free path walk, where they mustn't sleep. Any inode may supply its own permission check, get/set attributes, extended attributes and ACLs, extent reporting, time updates and attribute flags. Methods run without VFS locks unless documented otherwise; lookup, for example, runs with the directory locked.

### Step 4: Permission checks
This is the key step, since every access goes through it. The check first refuses writes to read-only filesystems and immutable files, then uses the filesystem's own check or the generic one: owner/group/other bits, POSIX ACLs if present, then capability overrides. Everything takes the mount's **ID mapping** into account, so an ID-mapped mount can show the same inode with different ownership. During lock-free path walk the check is told it **must not block**; a filesystem that would need to sleep answers "retry", and the walk restarts in the slower, reference-counted mode. Security modules get their say afterwards.

### Step 5: Changing attributes
chmod, chown, truncate and utimes all become one "set attributes" request. The VFS checks permission and hands it to the filesystem, which validates it with a shared helper (ownership rules, clearing setuid/setgid on chown, size limits) and applies the generic parts with another. Size changes are left to the filesystem, because truncating also drops cached pages and frees blocks.

### Step 6: Timestamps that can tell changes apart
Normally the kernel stamps modification and change times from a **coarse** clock that ticks once per timer tick, so a file written many times per tick isn't dirtied each time. But NFS clients and build tools compare timestamps to spot changes, and two writes in one tick look identical. **Multigrain timestamps** (6.13, after a 6.6 attempt was reverted) fix this for filesystems that opt in: when someone *reads* the modification or change time, a spare bit is set, and the next update takes a **fine-grained** timestamp so the change is visible. Unobserved updates stay cheap, and a global floor stops timestamps appearing to go backwards between files. Accessor functions replaced direct field access around 6.6–6.7 to make this possible.

### Step 7: A change counter for NFS
NFSv4 needs a reliable "has this changed?" value. The change counter goes up on every modification, but since 4.16 only **lazily**: a flag notes whether anyone has read the counter since the last increment, and it's bumped (forcing the inode to be written out) only when someone is watching.

### Step 8: Dirty, unlinked, and gone
Changing metadata marks the inode **dirty**, lets the filesystem log the change (journaling filesystems do it here) and queues the inode for [[writeback-infrastructure-explained|writeback]]; timestamp-only changes can wait a long time under lazytime. Unlinking removes a name and lowers the link count, but the inode lives on while anyone holds a reference; files open-but-deleted sit on an on-disk **orphan list**, finished off at the next mount after a crash. When the last reference goes, the filesystem decides whether to keep the inode cached (normal for linked files) or evict it now (always for unlinked ones). Eviction drops the page cache, frees the on-disk inode and blocks if the link count is zero, and releases memory **after an RCU grace period**, because lock-free path walk may still be looking at it.

## The picture

```text
 dentry "report.txt" ─┐
 dentry "old-name"   ─┴─▶ VFS inode (cover sheet)          open file A ─┐
                          type/mode, owner, size, nlink=2               ├─▶ same inode
                          times, change counter              open file B ─┘
                          ops ─▶ filesystem code
                          page cache ─▶ cached data
                          [ext4-private part wrapped around it]
 lifecycle: lookup/create → use → mark dirty → writeback → last ref → cache or evict → RCU free
```

## Tradeoffs

- **What it gives you:** one standard view of every filesystem object for permissions, stat, caching and directory operations; hard links and multiple opens for free; ID-mapping support throughout.
- **What it costs / requires:** because every filesystem embeds the VFS inode, its size matters to everyone and there's constant pressure to keep it small. Separating names from objects means an inode can't know "its" path.
- **Where it bites:** timestamps pit cheapness against detectability; multigrain gets both by going fine only when someone is watching, but the first attempt was reverted because files updated one after another could show out-of-order times. Lock-free path walk requires permission checks that can't sleep and inodes freed only after a grace period.

## How it got here

- **Early Linux:** per-filesystem data lived in a union inside the inode, later replaced by embedding the inode in filesystem structures.
- **2.6.38:** lock-free path walk, with non-blocking permission checks and RCU-freed inodes.
- **3.5:** kernel user and group IDs for user namespaces. **4.7:** the inode lock became a reader/writer semaphore, allowing parallel lookups in one directory.
- **4.16:** lazy change-counter increments (Jeff Layton).
- **5.12 / 6.3:** ID-mapped mounts, then ID mappings passed to every permission and attribute method (Christian Brauner).
- **6.6–6.7:** timestamp accessors; multigrain timestamps merged and reverted. **6.13:** multigrain timestamps back, with timekeeping help.

## Related

- Technical version: [[inode]]
- [[inode-cache-explained|Inode cache]], [[core-in-memory-structures-explained|Core VFS structures]], [[dentry-explained|Dentry]], [[path-lookup-explained|Path lookup]], [[superblock-explained|Superblock]]
- [[address-space-explained|Address space]], [[page-cache-explained|Page cache]], [[writeback-infrastructure-explained|Writeback]], [[lsm-framework-explained|LSM framework]], [[user-namespaces-explained|User namespaces]]
