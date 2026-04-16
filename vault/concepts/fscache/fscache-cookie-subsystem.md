---
title: "fscache Cookie Subsystem"
category: concept
tags: [fscache, cookie, caching, network-filesystem, lifecycle]
subsystem: fscache
kernel_version: "5.17"
researched: 2026-04-15
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/caching/fscache.html
  - https://www.kernel.org/doc/html/latest/filesystems/caching/backend-api.html
  - https://lwn.net/Articles/837939/
  - https://lwn.net/Articles/877058/
---

# fscache Cookie Subsystem

## Purpose

The cookie subsystem is the identity layer of [[fscache]]. Every participant in the cache is represented by an opaque cookie—network filesystems never see cache internals directly, only cookies. Cookies manage the lifecycle of cached objects from initial acquisition through use and eventual retirement, decoupling the network filesystem from the specifics of the underlying cache backend.

## Mental Model

A cookie is a **checked-in luggage ticket**. The filesystem hands in a description of an object (key + coherency data) and receives a ticket. Later it hands the ticket back to retrieve cached data. The luggage storage system (fscache + CacheFiles) decides where to actually put the luggage—the traveller doesn't need to know.

## How It Works

### Three Cookie Levels

The cookie hierarchy has exactly three levels:

**Cache cookies** (`struct fscache_cache`) represent a registered backend. There is one cache cookie per active cache backend. CacheFiles calls `fscache_acquire_cache()` to obtain one, then `fscache_add_cache()` to bring it online with an operations table. The cache cookie mainly anchors the `struct fscache_cache_ops` pointer table that fscache dispatches into.

**Volume cookies** (`struct fscache_volume`) represent a logical grouping—typically one superblock's worth of files. A network filesystem creates one volume cookie per mount point by calling `fscache_acquire_volume(volume_key, coherency_data, coherency_len)`. The `volume_key` is a printable string (no `/`, max 254 bytes) that encodes the mount's identity—for NFS this might be `"nfs,10.0.0.1:/export"`. fscache hashes this string and passes it to the backend's lookup to find or create the matching on-disk container.

**Data file cookies** (`struct fscache_cookie`) cache the content of individual files. A filesystem calls `fscache_acquire_cookie(volume, key, key_len, aux_data, aux_len, object_size)` during inode creation. The `key` is a binary blob (typically the inode number) unique within the volume; `aux_data` is coherency data (mtime, generation) used to detect stale cache entries.

### Cookie Lifecycle

A cookie transitions through a defined set of states:

```
QUIESCENT ──use──> ACTIVE ──unuse──> QUIESCENT
                     │
                  invalidate
                     │
                  QUIESCENT (fresh backing object)
                     │
                  relinquish
                     ▼
                  DEAD
```

**QUIESCENT**: Acquired but not yet bound to a file open. No backend resources held. The key and coherency data live in the cookie struct, ready for when the file is opened.

**ACTIVE** (after `fscache_use_cookie()`): The backend's `lookup_cookie()` runs, finding or creating the on-disk object. An internal reference count (`n_active`) is incremented. Multiple opens of the same file increment the same counter rather than creating multiple backend objects.

**Back to QUIESCENT** (after `fscache_unuse_cookie()`): `n_active` decrements. At zero, the backend may flush or retain the object. The caller passes the final size and updated coherency data at this point, so the backend can update the xattr for next time.

**DEAD** (after `fscache_relinquish_cookie()`): The cookie is destroyed. If `retire=true`, the backend's on-disk object is queued for deletion.

### Invalidation Without I/O Drain

When a file changes on the server, the filesystem calls `fscache_invalidate()`. Rather than waiting for all in-flight cache reads to complete before discarding the backing file (which could stall for seconds), fscache uses an `inval_counter` field. Incrementing this counter immediately makes all in-flight I/O operations see a version mismatch—they check the counter before committing results, and if it has changed they simply drop the data. The backend simultaneously uses the VFS `tmpfile` mechanism to create a new empty backing file, which becomes the target for future writes. The old file is retired asynchronously.

This design means invalidation is O(1) from the filesystem's perspective—no waiting, no synchronisation point.

### Eliminated Back-Pointers (post-5.17 design)

Before 5.17, fscache held callbacks into the netfs for key serialisation, coherency data retrieval, and I/O completion. This meant fscache kept live references into network filesystem data structures, creating complex teardown ordering requirements. The rewrite eliminated all such callbacks: the key, coherency data, and file size are copied into the cookie at acquisition time. Fscache now owns everything it needs without calling back.

## Key Data Structures

**`struct fscache_cookie`** (`include/linux/fscache.h`) — represents one file's cache entry.
- `volume` — pointer to parent `struct fscache_volume`
- `cache_priv` — backend's opaque per-object pointer (CacheFiles stores a `struct cachefiles_object` here)
- `flags` — bitfield: `FSCACHE_COOKIE_NO_DATA_TO_READ` (backing file empty), `FSCACHE_COOKIE_HAVE_DATA` (backend has content), `FSCACHE_COOKIE_RETIRED` (object should be deleted on release), `FSCACHE_COOKIE_NEEDS_UPDATE` (coherency data is dirty)
- `n_active` — count of active users (file opens) holding the cookie live
- `inval_counter` — invalidation generation counter; I/O checks this before committing results
- `object_size` — current file size tracked for cache coherency
- `key` / `key_len` — binary index key copied at acquisition

**`struct fscache_volume`** (`include/linux/fscache.h`) — represents a superblock-level container.
- `key` — printable NUL-terminated string (no `/`)
- `key_hash` — architecture-independent hash of key for fast lookup
- `coherency[]` — validity data compared against stored value on cache binding
- `cache` — pointer to parent `struct fscache_cache`

## Key Functions / Entry Points

**`fscache_acquire_volume()`** (`fs/fscache/volume.c`) — called by filesystem during superblock setup; creates or finds a volume cookie.

**`fscache_acquire_cookie()`** (`fs/fscache/cookie.c`) — called during inode creation; creates a data cookie bound to a volume.

**`fscache_use_cookie()`** (`fs/fscache/cookie.c`) — called at file open; activates the cookie and triggers backend `lookup_cookie()`.

**`fscache_unuse_cookie()`** (`fs/fscache/cookie.c`) — called at file close; decrements `n_active`, updates size/coherency.

**`fscache_invalidate()`** (`fs/fscache/cookie.c`) — increments `inval_counter`; the backend replaces the backing object atomically.

**`fscache_relinquish_cookie()`** (`fs/fscache/cookie.c`) — destroys the cookie; `retire=true` deletes the on-disk object.

**`fscache_update_cookie()`** (`fs/fscache/cookie.c`) — updates stored coherency data and object size without closing the cookie.

## Important Flags & Config Options

- `CONFIG_FSCACHE` — enables the fscache core; required for any backend or netfs user
- `CONFIG_FSCACHE_STATS` — exports `/proc/fs/fscache/stats` with per-counter breakdown of cookie allocation, I/O, LRU eviction, and space management events
- `FSCACHE_COOKIE_NO_DATA_TO_READ` — set on a freshly created cookie before any data has been written; tells the netfs not to bother trying a cache read
- `FSCACHE_COOKIE_RETIRED` — set before `fscache_relinquish_cookie(retire=true)`; the backend scheduler sees this and queues the backing object for deletion

## Interactions with Other Subsystems

- **→ [[cachefiles-backend]]**: fscache dispatches cookie lookup, withdrawal, invalidation, and I/O through the `struct fscache_cache_ops` table; CacheFiles implements each callback
- **← [[netfs-helper-library]]**: netfslib calls `fscache_use_cookie()` / `fscache_unuse_cookie()` on behalf of filesystems during file open/close, and `fscache_begin_read_operation()` before issuing I/O subrequests
- **← [[vfs]]**: indirectly, via the network filesystems that embed cookies in their inodes

## Design Decisions & Tradeoffs

**Cookie granularity at inode level**: Each inode gets its own data cookie rather than, say, a per-range or per-page cookie. This is the right granularity for NFS/AFS-style filesystems where coherency is per-file (generation + mtime). A finer granularity would mean more cookies to manage; a coarser granularity (per-mount) would make partial invalidation impossible.

**Copying keys and coherency data into the cookie**: Pre-5.17, fscache called back into the filesystem to serialise the key on demand. This was flexible but meant fscache could not safely operate after the filesystem started its shutdown. Copying data at acquisition time allows fscache to operate the cookie completely independently, at the cost of a small per-cookie memory allocation.

**`inval_counter` for non-blocking invalidation**: The alternative (drain all I/O before retiring the old object) could stall for seconds under heavy read load. The counter approach trades a small window where an in-flight read returns a stale-but-consistent result (which it then discards) for immediate forward progress.

## How It Has Evolved

- **Pre-5.17**: Four-level index hierarchy (cache → primary index → secondary index → data file); complex callback table (`struct fscache_cookie_def`) with callbacks for key generation, coherency checking, and I/O completion; object state machine in `fscache_object` tracking 20+ states.
- **5.17**: Collapsed to two levels (volume + data); eliminated `fscache_cookie_def`; data copied into cookie at acquisition; `inval_counter` replaces drain-and-retire pattern; object state machine removed entirely.

## Further Reading

1. [fscache: Modernisation (LWN)](https://lwn.net/Articles/837939/) — explains the cookie API changes in detail
2. [fscache, cachefiles: Rewrite (LWN)](https://lwn.net/Articles/877058/) — covers the rationale for removing back-pointers
3. [kernel.org fscache API docs](https://www.kernel.org/doc/html/latest/filesystems/caching/fscache.html) — complete cookie lifecycle API reference
