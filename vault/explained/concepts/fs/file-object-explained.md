---
title: "File Object (struct file) — Explained"
category: explained
original: "[[file-object]]"
subsystem: fs
tags: [explained, fs, vfs, open-file, file-operations]
converted: 2026-09-25
---

# The file object, explained

> Plain-language companion to [[file-object|the technical note]]. Same facts, fewer identifiers.

## The problem

Ten processes can have the same file open, each reading at a different position, with different access modes, and some of them sharing a position after `dup` or `fork`. That per-open state can't live in the file's inode (which is shared by everyone) or in the descriptor number (which is just a per-process index). And every read, write or `ioctl` needs to reach the right operations for whatever the file really is: a regular file, a device, a socket, a pipe.

## The idea in one paragraph

Each successful `open` creates a **file object**, the kernel's version of POSIX's "open file description". It holds the *open state*: current position, flags, the opener's credentials, readahead state and the operations table to use. The chain is descriptor → file object → name (dentry) → inode → disk. Descriptors can share a file object (`dup`, `fork`); separate `open` calls get separate file objects pointing at the same inode, which is how many readers keep independent positions.

## Step by step

### Step 1: What it holds
- the **path** it was opened by (mount + name), with a shortcut to the inode
- the **operations table**, copied from the inode at open and fixed from then on
- a **reference count**
- open **flags** (non-blocking, append...) and **access mode** (read, write, exec)
- the **position**, plus a lock for when several threads share this open file
- the **credentials** at open time: some checks (such as opened-for-execution) are done once, at open, not on every read
- **readahead** state
- per-open **error cursors**, so each open file sees a write error exactly once
- a shortcut to the page cache, and **private data** for the driver or filesystem

### Step 2: Opening
`open` resolves the path, allocates a file object from its slab cache, fills it in, copies the operations and calls the driver's or filesystem's open hook (which can set up private data or refuse). Then it finds a free descriptor number and publishes the file object into that slot. From that moment, other threads sharing the table can see it.

### Step 3: Reference counting
The file object lives while its count is above zero. References are held by every descriptor slot that points to it, by system calls in progress, and by long-lived users such as splice pipes and io_uring.
- **Safe borrow:** take a reference, use it, drop it. Works across process boundaries.
- **Fast borrow:** for a single-threaded process, nobody else can close the descriptor during the system call, so the reference count isn't touched at all; a flag records which way was used so the release matches. Avoiding that shared atomic write matters on many-core machines. Since 6.9 the handle is a single packed word with automatic, scope-based release, which removed a whole class of leaks and use-after-free bugs.
- **Position-locked borrow:** if several descriptors share this file object, reads and writes that update the position take its lock, so they don't race. Single users pay nothing.

### Step 4: Sharing through fork and dup
`fork` copies the descriptor table and bumps each file object's count, so parent and child share open file objects, and therefore positions, but have separate tables. Threads with shared files share one table outright. `dup2` points a second descriptor at the same file object.

### Step 5: Closing
Closing a descriptor calls the **flush** hook once for that descriptor (NFS uses it to write back before close) and drops a reference. When the *last* reference goes, the final cleanup is deferred to a safe point: the **release** hook runs, the name reference is dropped, and the object is freed.

### Step 6: The operations table
This is the plugin point for everything done through a descriptor: open and release; reading and writing (the iterator-based versions, which handle synchronous, asynchronous, vectored and kernel-initiated I/O the same way); seeking; `mmap`; polling (for select, poll and epoll); fsync; `ioctl` (including the 32-bit compatibility version); reading directory entries; zero-copy splicing; preallocation and hole punching; access hints; per-descriptor flush; POSIX locks; and validating flag changes.

The note records that the older simple buffer-and-length read and write callbacks were removed in 6.8 (Jens Axboe's 437-patch series), leaving only the iterator versions, which ended decades of duplicated code and bridge shims.

### Step 7: Per-open readahead
Every file object carries its own readahead window: where it starts, how big it is, how much of it is fetched ahead asynchronously, and the device's maximum. Sequential reading grows it; random reading shrinks it. Because it's per open, two processes reading the same file keep separate windows.

## The picture

```text
 process: fd 3 ─┐                 other process: fd 7 ──▶ [ file object B ]
         fd 4 ─┴─▶ [ file object A ]                        position 0
 (dup)              position 8192                            │
                    flags, creds, ops, readahead             │
                          │                                  │
                          └──────▶ [ dentry ] ──▶ [ inode ] ◀┘
                                                   (shared)
 close(3): flush, drop ref (fd 4 still holds A)
 close(4): flush, last ref → release, free A
```

## Tradeoffs

- **What it gives you:** exact POSIX semantics (shared positions after `dup` and `fork`, independent ones for separate opens), per-open credentials and readahead, and one operations table for every kind of file.
- **What it costs / requires:** reference counting that must be exactly right; the fast-borrow shortcut adds rules (never return to user space holding a borrowed reference).
- **Where it bites:** threads sharing one open file contend on the position lock. Getting the borrow-and-release pairing wrong caused real leaks and use-after-free bugs, which is why release is now enforced by the compiler.

## How it got here

- **2.4:** the file object with read/write callbacks and one global lock for descriptor tables.
- **2.6.3 (2004):** lock-free descriptor lookup (Nick Piggin).
- **2.6.22 (2007):** iterator-based read and write, unifying asynchronous and vectored I/O.
- **3.4 (2012):** the old big-kernel-lock `ioctl` path gone.
- **5.0–5.9:** per-open error cursors for precise `fsync` error reporting, including superblock-level errors.
- **6.8–6.9 (2024):** the simple read/write callbacks removed; the packed borrow handle with automatic release (Al Viro).

## Related

- Technical version: [[file-object]]
- [[file-descriptor-and-open-file-table-explained|Descriptors and the open file table]]
- [[core-in-memory-structures-explained|Core VFS objects]], [[fs-explained|Filesystem subsystem (VFS)]]
- [[dentry-explained|Dentries]], [[inode]], [[address-space-explained|Address space]], [[page-cache-explained|Page cache]]
- [[path-lookup]], [[io_uring-explained|io_uring]]
