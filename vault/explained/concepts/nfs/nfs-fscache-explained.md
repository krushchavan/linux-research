---
title: "NFS fscache Integration — Explained"
category: explained
original: "[[concepts/nfs/fscache|fscache (NFS)]]"
subsystem: nfs
tags: [explained, nfs, fscache, cachefiles, netfs]
converted: 2026-09-25
---

# NFS local caching with fscache, explained

> Plain-language companion to [[concepts/nfs/fscache|the technical note]]. Same facts, fewer identifiers.

## The problem

Without a local disk cache, every NFS read that misses the in-memory page cache goes to the server. Over a slow or congested wide-area link that round trip hurts, and in places like render farms, where many clients read the same assets at once, it hammers the server with the same requests again and again. Memory alone can't hold everything, so a copy on local disk helps a great deal.

But NFS shouldn't have to build its own disk cache. AFS, Ceph and 9P need the same thing, and the hard parts (knowing when a cached copy is stale, managing disk space, surviving crashes) are the same for all of them.

## The idea in one paragraph

NFS uses [[fscache-explained|fscache]], a shared caching layer that works like a **local post office**. NFS hands it labelled parcels: a label for each mounted share (the *volume*) and one for each file within it. The post office finds the right shelf and returns the contents if it has them; otherwise NFS fetches from the server and the result is filed for next time. The shelves themselves are managed by a pluggable backend, almost always [[cachefiles-backend-explained|CacheFiles]], which keeps ordinary files in a directory on a local ext4 or XFS filesystem. Checking whether a copy is still valid stays NFS's job, since fscache knows nothing about the protocol.

## Step by step

### Step 1: A label per mounted share
When an NFS share is mounted with the `fsc` option, NFS gets a **volume** handle from fscache, keyed by a printable string built from the NFS version, flags, server address, export path and filesystem ID (no slashes, at most 254 bytes). Mounts of the same export normally share a superblock, and therefore share a volume and its cached data. The `nosharecache` option forces a separate superblock and a separate cache; `fsc=<tag>` names a cache volume explicitly.

### Step 2: A label per file
When a file is opened, NFS gets a **file** handle keyed by a binary string derived from the NFS file handle plus a uniquifier. It doesn't repeat the server details, since the volume already gives that context. Two paths to the same file on the same superblock end up at the same cached object.

### Step 3: In use while open
Opening marks the file's cookie **in use**, so the backend won't evict its cached copy while the file is open. The backend finds or creates the backing file in the background; reads that arrive before it's ready are queued. On the last close, the cookie becomes **unused** again and the copy may be culled under disk pressure. When the inode leaves memory, the cookie is released, and if the file was invalidated, its cached copy is deleted too.

### Step 4: Reading through netfs
This is the key step. Since the conversion landed around 6.3, NFS reads on `fsc` mounts go through the shared [[netfs-explained|netfs]] library (only when caching is configured and active; otherwise NFS keeps its own path):
1. netfs checks which parts of the requested range are missing from the page cache
2. for each missing part, it asks the cache; if the data is on disk, CacheFiles reads it straight into the page cache with direct I/O, and no network call is made
3. on a miss, netfs calls NFS's "issue read" hook, which sends the range through NFS's normal request machinery, possibly as several separate calls
4. a small tracker adds up the bytes and remembers the first error; when the last call finishes, NFS tells netfs how much arrived
5. netfs puts the data in the page cache and writes it into the local cache at the same time, for next time

The tracker exists because netfs expects one answer per piece, while NFS may split a piece into many calls.

### Step 5: Keeping the cache honest
NFS attaches validity data to each cookie: the server's modification and change times, the file size, and the change counter. When a cookie is looked up, a mismatch invalidates the cached copy. NFS also invalidates explicitly when it sees that the server's file has changed, for example when an OPEN or GETATTR reply shows a new change counter.

With NFSv2 and v3 nothing tells a client that another client changed a file, so caching is safe only for read-mostly data. Writes from this client do go through to the server, but other clients' writes won't invalidate the local copy, and a process that doesn't close and reopen the file may see stale data. That's a deliberate choice, and the operator carries the risk. NFSv4's delegations and change counter let invalidation happen more accurately.

### Step 6: The storage underneath
A user-space daemon configures CacheFiles through a device file: where the cache lives (typically `/var/cache/fscache`) and three space thresholds, for example stop culling at 10% free, start culling at 7%, refuse new objects at 3%. Volumes become directories and files become regular files, with stable encoded names, so the same NFS file always lands at the same cache path on a given host. CacheFiles uses direct I/O on the local filesystem to avoid holding the data twice in memory. Culling removes the least recently accessed objects; they go to a graveyard directory first and are deleted in the background.

## The picture

```text
 NFS mount (fsc) ─▶ volume cookie  "nfs,4.2,…,server,/export,fsid"
 open(file)      ─▶ file cookie    key = NFS file handle + uniquifier  (in use)

 read miss in page cache
   └─ netfs: on local disk? ─ yes ─▶ CacheFiles direct read ─▶ page cache
                            └ no ──▶ NFS issue read ─▶ READ call(s) ─▶ server
                                        tracker: last reply → report bytes
                                     data ─▶ page cache + copy into local cache
 server file changed (new change counter) ─▶ invalidate cached copy
```

## Tradeoffs

- **What it gives you:** repeated reads served from local disk instead of the network, one shared cache design across network filesystems, and the same statistics and culling tools for all.
- **What it costs / requires:** an extra layer of indirection; more metadata work on the local cache filesystem, since data is written to both the page cache and the cache file; a daemon to manage space.
- **Where it bites:** stale data on NFSv2/v3 when others write. Shared superblocks mean mounts with different SELinux contexts can share a cache volume, which can clash ("cache volume key already in use"); `nosharecache` avoids it. When NFS was used as a caching re-export proxy under heavy load, server threads were reported hanging in cookie state waits.

## How it got here

- **2.6.30:** initial fscache and CacheFiles with NFS integration (David Howells), using a page-by-page interface that watched page flags from outside the filesystem. It couldn't cache partial pages at end of file, broke with large folios, and raced with page reclaim.
- **5.17 (2022):** the fscache rewrite. The state machine, operation manager and page snooping went, replaced by asynchronous direct I/O and the netfs helpers. NFS, Ceph, SMB and 9P caching were temporarily disabled while filesystems converted.
- **6.3 (2023):** Dave Wysochanski's series moved NFS reads onto netfs, engaged only for `fsc` mounts, and dropped NFS's own cache statistics in favour of fscache's.

## Related

- Technical version: [[concepts/nfs/fscache|NFS fscache integration]]
- [[fscache-explained|fscache subsystem]], [[fscache-cookie-subsystem-explained|Cookies]], [[cachefiles-backend-explained|CacheFiles]], [[netfs-explained|netfs]], [[netfs-helper-library-explained|netfs helper library]]
- [[nfs-explained|NFS subsystem]], [[nfs-client-explained|NFS client]], [[delegations-and-locking-explained|Delegations]]
- [[page-cache-explained|Page cache]], [[page-reclaim-explained|Page reclaim]], [[block-explained|Block layer]]
