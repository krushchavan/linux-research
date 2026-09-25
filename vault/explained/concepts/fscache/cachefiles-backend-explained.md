---
title: "CacheFiles Backend — Explained"
category: explained
original: "[[cachefiles-backend]]"
subsystem: fscache
tags: [explained, fscache, cachefiles, caching]
converted: 2026-09-25
---

# The CacheFiles backend, explained

> Plain-language companion to [[cachefiles-backend|the technical note]]. Same facts, fewer identifiers.

## The problem

[[fscache-explained|fscache]] lets network filesystems keep copies of remote data on local disk, but something has to actually store those copies. Writing a dedicated on-disk cache format would mean reinventing block allocation, directories and crash recovery, and would force admins to set aside a special partition.

The storage layer also has to spot stale copies when the remote file changes, avoid wasting memory on duplicate copies of data, keep disk usage within limits, and access root-owned cache files on behalf of ordinary users without confusing security modules.

## The idea in one paragraph

Store the cache as **ordinary files in an ordinary directory** on an already-mounted local filesystem (ext4, XFS, btrfs). Think of a filing clerk using normal filing cabinets: each drawer is a volume, each folder a cached file. The local filesystem provides allocation, crash safety and locking for free, and adding a cache needs nothing more than a directory. Each file is labelled with the remote file's validity data so stale copies can be detected, data moves by direct I/O so there's only one copy in memory, and the messy work of deleting old files is handed to a user-space daemon.

## Step by step

### Step 1: The layout on disk
Under a root directory chosen by the daemon there are always two directories: `cache/` for live objects and `graveyard/` for retired ones awaiting deletion. Each volume becomes a directory named after its key, and each cached file becomes a regular file named after its key. A short prefix letter says whether the name is printable or encoded and what kind of object it is. Keys with slashes, NULs or other awkward characters are base-64 encoded, and keys too long for one filename are split across nested directories.

### Step 2: Detecting stale copies
Each cache file carries an extended attribute holding the object type and the network filesystem's validity data (for NFS, things like the modification time). When a file is looked up, CacheFiles compares the stored data with what the filesystem reports now. If they differ, the cached content is stale: CacheFiles creates a replacement backing file and moves the old one to the graveyard. This is how a client notices that a file changed on the server while it was offline.

### Step 3: Moving data with direct I/O
This is the key step. All cache reads and writes use asynchronous **direct I/O** straight between disk and the network filesystem's own pages.

Before the 5.17 rewrite, CacheFiles read data into the backing file's page cache and then copied it into the network filesystem's page cache, so every cached page existed twice in memory. Now data goes from disk to the application's page in one transfer. When the I/O completes, CacheFiles notifies the [[netfs-helper-library|netfs helper library]], which advances the overall request and unlocks the pages. The cost is more complex asynchronous bookkeeping, and having to respect the backing filesystem's direct-I/O alignment rules.

### Step 4: Keeping disk usage in bounds
Six thresholds, three for disk blocks and three for file counts, each a percentage:
- above the **run** level: culling stops
- below the **cull** level: culling starts
- below the **stop** level: nothing new is written to the cache (cached reads still work)

Typical daemon settings are 10%, 7% and 3%.

### Step 5: Culling in user space
The kernel only moves objects into the graveyard. The `cachefilesd` daemon scans the cache tree, sorts objects by last access time, and deletes the least recently used until the thresholds are met. It's a simple approximation of LRU; moving culling into the kernel and adding priority tiers is a stated future goal. Keeping mass directory deletion out of the kernel was the reason for the split.

### Step 6: Acting with borrowed credentials
The cache directory belongs to root or the daemon, not the user whose read triggered the cache access. So while doing cache file operations, the kernel temporarily switches the credentials it *acts* with to the daemon's, while the process's visible identity (what `/proc` shows) stays the same. Security modules therefore see the cache module accessing its files, not an unprivileged user touching root-owned ones. In SELinux, cache files get their own type, and the daemon's own permissions are narrow: stat, scan and delete, no reading or writing.

### Step 7: On-demand mode
Added in 6.1 for setups such as Kata Containers, where the "local" store is itself remote and the kernel can't fill the cache alone:
1. on a miss, the kernel sends a message through a device file: open this object, read this range, or close
2. the daemon fetches the data from wherever it likes and writes it into the cache file through a file descriptor the kernel gave it
3. the daemon acknowledges, and the blocked read resumes

A device file was chosen over netlink to reuse familiar messaging patterns. The catch is that on-demand mode needs a running daemon and adds a round trip to user space for every miss.

## The picture

```text
 fscache: "look up / read / write / invalidate this cookie"
                    │
               CacheFiles
   ┌────────────────┼──────────────────────────┐
   │ root/                                      │
   │   cache/<volume>/<file>  + validity xattr  │ ◀── direct I/O into netfs pages
   │   graveyard/  (retired, stale)             │
   └────────────────┼──────────────────────────┘
                    │ (acting with daemon credentials)
         local filesystem (ext4 / XFS / btrfs)

 cachefilesd: scan by access time → delete oldest until above "run" level
 disk free:  0% ── stop ── cull ── run ── 100%
```

## Tradeoffs

- **What it gives you:** a cache that needs only a directory, inherits crash safety and allocation from a mature filesystem, holds one copy of data in memory, and detects staleness per file.
- **What it costs / requires:** it can be no faster than the local filesystem allows (no cache-tuned layout, for example); culling needs a daemon; on-demand mode needs the daemon for every miss.
- **Where it bites:** if the daemon dies, retired objects accumulate in the graveyard and eat disk space until it restarts, so the init system must keep it alive.

## How it got here

- **2.6.30 (2009):** first upstream merge, with page-cache snooping for I/O and a complex object state machine.
- **4.x–5.10:** incremental fixes and NFS, AFS and Ceph integration, with persistent state-machine trouble under heavy load.
- **5.17 (2022):** complete rewrite: direct I/O replaced snooping, invalidation uses a fresh temporary file, the state machine went, and an extended-attribute content map tracks presence.
- **6.1 (2022):** on-demand mode through a device-file protocol, for containers and overlays.

## Related

- Technical version: [[cachefiles-backend]]
- [[fscache-explained|fscache subsystem]], [[fscache-cookie-subsystem|Cookie subsystem]], [[netfs-helper-library|netfs helper library]]
- [[network-filesystems-overview-explained|Network filesystems overview]]
- [[vfs|VFS]], [[security|Security]]
