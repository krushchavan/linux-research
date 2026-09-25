---
title: "fscache Subsystem — Explained"
category: explained
original: "[[fscache]]"
subsystem: fscache
tags: [explained, fscache, netfs, cachefiles, network-filesystems]
converted: 2026-09-25
---

# The fscache subsystem, explained

> Plain-language companion to [[fscache|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Network filesystems (NFS, AFS, Ceph, SMB/CIFS, 9P) are slow compared with a local disk, especially over long-distance links where round trips dominate. Keeping a copy of remote files on local disk helps a lot, but writing a correct disk cache is hard, and having each network filesystem build its own would duplicate all that work.

The cache also has to behave well in awkward cases: files bigger than the whole cache, or a set of open files that together won't fit. Preloading whole files before use would make large files unusable, so the cache has to work **piece by piece, on demand**.

## The big picture

fscache is a **forwarding switchboard** between network filesystems and local cache storage. A filesystem registers each file with the switchboard. When it needs a range of data, it asks: if the switchboard has a copy, it hands it back; if not, it says "miss", and the filesystem fetches from the network while also feeding the data back into the cache for next time. The switchboard doesn't care what the data means. It only knows keys, sizes and validity tokens.

```text
   NFS · AFS · Ceph · SMB · 9P        (network filesystems)
                 │
         netfs helper library          splits reads/writes into pieces,
                 │                     runs cache and network pieces in parallel
           fscache core                identity: cache → volume → file handles
                 │
        CacheFiles backend  ◀──────▶  user-space daemon (culling, on-demand fetch)
                 │  direct I/O
     local filesystem (ext4, XFS, btrfs…) on local disk
```

On a read miss, data flows top to bottom: the helper library splits the read into pieces, fscache checks which ranges are cached, hits go to CacheFiles, and misses go to the network, all in parallel.

## The pieces

### Handles: cache, volume and file cookies
Everything that takes part in caching is represented by a handle called a **cookie**. There are three levels:
- a **cache** cookie for each registered backend, which mainly anchors the backend's table of operations
- a **volume** cookie for a group of cached files, typically one mount. The filesystem names it with a printable key (server address, export path and so on) and attaches validity data used to spot stale entries after a remount
- a **file** cookie for each cached file, created with a binary key (such as the inode number), validity data and the file's size

A file cookie goes through four phases:
1. **acquired:** nothing is allocated in the backend yet
2. **in use:** the backend finds or creates the file on disk, and a count tracks how many open files are using it
3. **unused:** when the count reaches zero, the backend object can be retired; the filesystem hands over the final size and validity data
4. **relinquished:** the cookie is removed for good, and optionally its on-disk copy is discarded

Since the 5.17 rewrite, fscache stores keys, sizes and validity data in the cookie itself rather than calling back into the filesystem to fetch them. See [[fscache-cookie-subsystem-explained|the cookie subsystem]].

### The netfs helper library
Every network filesystem needs the same fiddly plumbing: readahead, reading single pages, preparing and finishing writes, and direct I/O, all made correct in the presence of a cache. The helper library does this once. Filesystems supply only their network-call hooks.

It organises I/O at three levels:
- a **request** is one user-visible operation, such as one readahead or one write call
- a **stream** is a run of pieces headed for the same destination. A read has one stream; a cached write has two, one to the server and one to the cache, each cut into pieces that suit its destination (say 1 MB for the server, block-aligned for the cache)
- a **subrequest** is one network call or one cache I/O

Pages unlock progressively as their pieces complete, not when the whole request finishes. See [[netfs-helper-library-explained|the netfs helper library]].

### CacheFiles: the storage backend
CacheFiles stores cached data as ordinary files on an already-mounted local filesystem. That way it reuses the local filesystem's block allocation, journalling and crash recovery instead of inventing its own.
- **Layout:** a `cache/` directory for live objects and a `graveyard/` for retired ones. Each volume becomes a directory tree and each file becomes a regular file named after its key (encoded if it contains awkward characters, and split across nested directories if too long).
- **Staleness:** each cache file carries an extended attribute holding the filesystem's validity data. On lookup, a mismatch marks the copy stale and it is replaced.
- **I/O:** reads and writes use asynchronous **direct I/O**, going straight between disk and the network filesystem's pages. The old design read into the backing file's own page cache and then copied, keeping two copies of the data in memory.
- **Space:** three pairs of thresholds (for blocks and for file counts) say when culling starts, when it stops, and when all new caching halts. The kernel only moves objects to the graveyard; a user-space daemon picks victims by access time, oldest first, and deletes them.
- **Security:** CacheFiles temporarily switches the credentials it acts with when touching cache files, and SELinux gives cache files and the daemon their own narrow labels.

See [[cachefiles-backend-explained|CacheFiles]].

### On-demand mode
In some setups, such as Kata Containers, the "local" store is itself remote, so the kernel can't fill the cache on its own. On-demand mode (6.1) lets the kernel send "open" or "read this range" requests to a user-space daemon over a device file. The daemon fetches the data, writes it into the cache file and replies.

## A request's journey

Readahead of 128 pages from a cached NFS file where the first half is cached:

1. **Setup (earlier).** At mount, NFS got a volume cookie keyed by server and export. When the file was opened, it got a file cookie and marked it in use, and CacheFiles opened (or created) the backing file.
2. **Readahead arrives.** The page cache asks the helper library to read pages 0–127.
3. **Check the cache.** The library asks fscache which ranges are present: pages 0–63 are, 64–127 aren't.
4. **Split and issue in parallel.** This is the key step. Pages 0–63 go to CacheFiles as a direct-I/O read; pages 64–127 go to NFS as a network call. Both run at once.
5. **Unlock as they land.** As each piece completes, its pages are marked valid and unlocked, without waiting for the other piece.
6. **Fill the cache in the background.** The pages fetched from the network are written into the cache file asynchronously; the program isn't kept waiting.

If the server's copy later changes (new generation number or size), the filesystem **invalidates** the cookie. A counter in it is bumped, so any in-flight cache I/O sees the mismatch and fails harmlessly. CacheFiles then swaps in a fresh temporary file as the backing store without waiting for old I/O to drain.

## Tradeoffs

- **What it gives you:** transparent local caching for all the major network filesystems, working at any file size, with cache and network I/O in parallel and one shared, tested implementation of the plumbing.
- **What it costs / requires:** first access to data is still slow (only requested ranges are fetched); storing keys and validity data in cookies duplicates some data; culling depends on a user-space daemon; on-demand mode adds a round trip to user space on every miss.
- **Where it bites:** if the culling daemon dies, retired objects pile up in the graveyard until it restarts. The cache is only as fresh as each filesystem's validity checks.

## How it got here

- **2003–2006:** the original design by David Howells, motivated by NFS over slow wide-area links; it snooped the backing file's page cache and relied on a complex callback API.
- **2.6.30 (2009):** merged upstream after years out of tree, with CacheFiles as the main backend. Filesystems added support over the next decade, but the internal state machine stayed notoriously complex.
- **5.12 (2021):** the netfs helper library appears as a separate module.
- **5.17 (2022):** a major rewrite removing about 13,000 lines and adding 7,200: the state machine went, direct I/O replaced page-cache snooping, back-pointers into filesystems were eliminated (ending a class of use-after-free bugs), and a two-level volume/file hierarchy replaced a multi-level index.
- **6.1 (2022):** on-demand mode for container caching.
- **6.x (ongoing):** the stream model (parallel server and cache streams) and folio-based I/O; SMB porting, faster large reads, and work towards in-kernel culling continue.

## Related

- Technical version: [[fscache]]
- [[fscache-cookie-subsystem-explained|Cookie subsystem]], [[netfs-helper-library-explained|netfs helper library]], [[cachefiles-backend-explained|CacheFiles backend]]
- [[network-filesystems-overview-explained|Network filesystems overview]]
- [[vfs|VFS]], [[page-cache-explained|Page cache]], [[mm-explained|Memory management]], [[block-explained|Block layer]], [[security|Security]]
