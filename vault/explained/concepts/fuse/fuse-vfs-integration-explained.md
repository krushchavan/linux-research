---
title: "FUSE VFS Integration — Explained"
category: explained
original: "[[fuse-vfs-integration]]"
subsystem: fuse
tags: [explained, fuse, vfs, caching, dentry-revalidation]
converted: 2026-09-25
---

# How FUSE plugs into the VFS, explained

> Plain-language companion to [[fuse-vfs-integration|the technical note]]. Same facts, fewer identifiers.

## The problem

The kernel's file layer (the VFS) expects every filesystem to provide inodes, directory entries, a superblock and open-file objects, each with a table of methods it can call. [[fuse-explained|FUSE]] has none of those natively: the real filesystem lives in a user-space daemon that only understands messages on a file descriptor.

Something has to make the daemon *look* like an ordinary kernel filesystem, so that path lookup, `stat`, `open`, `read` and caching all work unchanged. And it has to do so without asking the daemon about everything all the time, because every question is a slow round trip to user space.

## The idea in one paragraph

Think of a **translation booth in an embassy**. On one side, the VFS speaks in method calls on inodes and directory entries; on the other, the daemon speaks FUSE protocol messages. The integration layer registers as a normal filesystem, answers every VFS call through the standard method tables, turns each call into a message, and turns each reply back into kernel objects. To avoid constant round trips, it caches answers with **expiry times** the daemon chooses, and re-asks only when they run out.

## Step by step

### Step 1: Register three filesystem types
When the module loads it registers:
- **fuse:** the usual type for daemon-backed filesystems (network, in-memory, overlay). The "device" argument to `mount` is ignored.
- **fuseblk:** for daemons that manage a real block device, such as ntfs-3g, where the argument names the device.
- **fusectl:** a control filesystem showing one directory per live connection, with files to see waiting requests and to abort.

Each uses the modern mount API: parse options, validate them, then build the superblock.

### Step 2: Build the superblock
On mount, FUSE creates the [[fuse-connection-explained|connection]] and a per-mount record linking a superblock to it (bind mounts can share one connection, so the two have separate lifetimes). After checking the `fd=` option really is a FUSE device from the same user namespace, it:
1. sets the block size to one page and the maximum file size to the largest the kernel allows
2. installs its superblock and extended-attribute method tables
3. registers a **backing device** with the writeback system, so FUSE gets its own slot in dirty-page flushing and can signal congestion when the daemon is slow
4. creates the root inode with the fixed node ID 1 and the mode given at mount, plus its root directory entry
5. sends the init handshake; until the daemon answers, the superblock exists but its features are unknown

### Step 3: FUSE inodes wrap VFS inodes
FUSE allocates its own inode record from a dedicated cache, with a normal VFS inode embedded first, so the kernel can convert either way at no cost. Alongside it FUSE stores:
- the daemon's **node ID** for the inode (plus a generation number to spot recycled IDs), sent in every request about it
- a **lookup count**: how many times lookups have returned this inode
- the **attribute expiry time**, and which attributes are known stale

Node IDs have no fixed relation to inode numbers; the daemon picks both. FUSE sets the kernel's inode number from the node ID, so the inode cache can find an existing inode without asking the daemon. A new inode gets method tables based on its type (directory, regular file or symlink) and attributes from the daemon's reply.

### Step 4: Every method, the same pattern
Directory methods (lookup, create, mkdir, unlink, rmdir, rename, symlink, link, permission, attributes), file methods (attributes, fallocate, copy range) and symlink methods all work the same way: pack the arguments into a message, send it and sleep until the reply, then unpack the results into kernel state. A lookup, for example, sends the parent's node ID and a name, and gets back the child's node ID, attributes and two expiry times: how long the name-to-node mapping can be trusted, and how long the attributes can be.

### Step 5: Two caches with expiry times
This is the key step. FUSE keeps two kinds of cached answer:
- **attributes**, per inode: valid until now plus the daemon's attribute timeout. Anything needing fresh attributes after that sends a getattr first.
- **name lookups**, per directory entry: valid until now plus the entry timeout. New entries start already expired.

While these haven't expired, the kernel answers without the daemon. This pull model is simpler than having the daemon push every change, but changes on the daemon's side (for instance on a network backend) stay invisible until the timeout. Later, daemons gained messages to push invalidations when they need tighter consistency.

### Step 6: Revalidating directory entries
Every path walk through a cached FUSE entry asks FUSE whether it's still good:
1. if it hasn't expired: yes, at the cost of one time comparison (the fast path)
2. if the connection is dead: no, so the kernel drops it and returns an error
3. otherwise: send a lookup. Same node ID and generation, and the entry's expiry is refreshed; different or failed, and the kernel does a fresh lookup

Entries whose timeout is zero aren't kept in the cache at all, so short-lived files don't leave piles of stale entries. Entries that are mount points for nested FUSE filesystems (5.10+) trigger an automatic submount.

### Step 7: Opening and reading files
Opening sends an open request; the daemon returns its own **file handle** and flags, stored in a per-open record and included in every later read, write, fsync and flush, like an NFS file handle. The flags can say:
- **direct I/O:** bypass the page cache for this file
- **keep cache:** keep cached pages across open and close
- **stream:** like a pipe, with no seeking

Reads and writes are split into messages no bigger than the negotiated page limit and sent through the [[fuse-request-queue-explained|request queue]].

### Step 8: Eviction and forget
FUSE never keeps unused inodes on the reuse list; when one is dropped it's evicted at once. Eviction sends a **forget** message carrying the inode's total lookup count, so a single message undoes many lookups, and the daemon knows it may free its own state for that node. The daemon must track counts carefully and only free state when the forgets add up.

## The picture

```text
  VFS: path walk / stat / open / read
    │
    ├─ cached entry still fresh?  ── yes ─▶ answer locally (no daemon)
    │                               no
    ▼
  FUSE method: pack message ─▶ daemon ─▶ reply: node ID + attributes + expiry times
    │
  FUSE inode [ VFS inode | node ID | lookup count | attribute expiry ]
  FUSE entry [ name → node ID | entry expiry ]
  open → daemon file handle (sent with every read/write)
  evict → forget(node ID, total lookups)
```

## Tradeoffs

- **What it gives you:** a user-space filesystem indistinguishable to the VFS from a kernel one, with daemon-tuned caching (long timeouts for local backends, zero for fast-changing remote ones).
- **What it costs / requires:** a larger inode record for every inode; a round trip for every expired answer; careful lookup-count bookkeeping in the daemon.
- **Where it bites:** with timeouts, remote changes show up late unless the daemon pushes invalidations. Write-back caching (3.15) speeds writes but can serve stale reads if something else changes the file.

## How it got here

- **2.6.14 (2005):** initial merge, with synchronous writes (each `write` a round trip) and the three filesystem types.
- **2.6.26:** truncating opens forwarded atomically, saving a round trip.
- **3.15:** write-back caching, joining the kernel's page-writeback path. Opt-in, because read-after-write consistency is dangerous for shared network filesystems.
- **4.6–4.20:** explicit, daemon-driven page-cache invalidation, then push notifications for invalidating inodes and deleting entries. **4.8:** parallel lookups and directory reads.
- **5.10:** nested FUSE submounts. **5.15:** passthrough I/O straight to a lower file the daemon holds open (with care over which credentials the I/O uses). **6.6:** iomap support for large sequential I/O.

## Related

- Technical version: [[fuse-vfs-integration]]
- [[fuse-explained|FUSE subsystem]], [[fuse-connection-explained|Connection]], [[fuse-request-queue-explained|Request queue]], [[fuse-wire-protocol-explained|Wire protocol]]
- [[fs-explained|Filesystem subsystem (VFS)]], [[path-lookup-explained|Path lookup]], [[dentry-cache-explained|Dentry cache]], [[inode-cache-explained|Inode cache]]
- [[page-cache-explained|Page cache]], [[writeback-infrastructure-explained|Writeback]], [[filesystem-registration-explained|Filesystem registration]]
