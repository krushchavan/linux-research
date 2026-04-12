---
title: "NFS fscache Integration"
category: concept
tags: [nfs, fscache, caching, cachefiles, netfs, network-filesystem]
subsystem: nfs
kernel_version: "2.6.30"
researched: 2026-04-12
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/caching/fscache.html
  - https://www.kernel.org/doc/html/latest/filesystems/caching/netfs-api.html
  - https://www.kernel.org/doc/html/latest/filesystems/caching/backend-api.html
  - https://www.kernel.org/doc/html/v6.5/filesystems/caching/fscache.html
  - https://lwn.net/Articles/837939/
  - https://lwn.net/Articles/312708/
  - https://lwn.net/Articles/160122/
  - https://support.tools/post/caching-nfs-files-with-cachefilesd/
  - https://lore.kernel.org/all/CALF+zOmbPOskW_tQgZd8cz-PsSf4W+=+kaW9VQDHiNHc=5d39w@mail.gmail.com/
---

# NFS fscache Integration

## Purpose

NFS fscache gives the NFS client a way to cache file data on a local disk so
that repeated reads of the same data bypass the network entirely. Without it,
every read that misses the kernel page cache must issue an RPC to the server —
a round trip that is especially expensive over slow or congested WANs, and
wasteful on render farms where many clients read the same assets simultaneously.
fscache is a general intermediary layer: NFS does not talk to the disk cache
directly; instead it registers with fscache, which delegates actual storage to a
pluggable backend (almost always CacheFiles, which stores objects in a directory
on a locally mounted ext4 or XFS filesystem).

## Mental Model

Think of fscache as a local post office between NFS and the disk: NFS hands the
post office a labelled parcel (a cookie tied to an inode or a superblock), the
post office finds the right shelf (a CacheFiles object) and hands back the
contents if they are there, or forwards the request to the server (via an NFS
RPC) if not, filing the returned data for next time. The "labels" that identify
shelves are structured hierarchically — first by server+share (a *volume key*),
then by file identity within that share (a *cookie key*) — so objects from
different servers never collide.

## How It Works

### Layered architecture

The stack has three tiers. At the top, the NFS client (a *network filesystem*
in fscache parlance) requests caching services. In the middle, the `fscache`
module (kernel/fs/fscache/) arbitrates: it maintains the cookie hierarchy,
manages coherency, and dispatches I/O to whichever backend is registered. At the
bottom, CacheFiles (fs/cachefiles/) does the actual disk work by creating and
reading ordinary files inside a configured cache directory. This separation means
fscache's contract with NFS and its contract with CacheFiles are independent;
AFS, Ceph, and 9P also use fscache without touching CacheFiles internals.

### Cookie hierarchy

fscache organises its namespace into three levels.

**Volume cookies** represent one NFS superblock — one mounted share. NFS
acquires a volume cookie during `nfs_fscache_get_super_cookie()`, called from
the superblock initialisation path. The cookie's *volume key* is a printable
string that encodes enough information to distinguish any two superblocks:

```
"nfs,<version>,<flags>,<server-addr>,<share-path>,<fsid>"
```

The key must be printable (no '/' characters) and at most 254 bytes. If two NFS
mounts share a superblock (the default when server and export match), they share
a volume cookie and therefore share the cache — they see the same cached objects.
The `nosharecache` mount option forces a unique superblock and thus an isolated
cache namespace, which is sometimes needed to avoid coherency conflicts between
mounts with different options.

**Data file cookies** (one per inode) are acquired inside `nfs_open_context`
setup, specifically from `nfs_fscache_open_file()` when a file is opened with
fscache enabled. The cookie's *index key* is a binary blob derived from the NFS
file handle plus a uniquifier: fields that identify the exact file object on the
server without embedding the volume key (the volume cookie already provides that
context). If the same file is accessed through two different paths on the same
superblock, they resolve to the same binary key and thus the same cache object.

**Cache cookies** exist at the backend level and are not exposed to NFS.

### Lifecycle of a data file cookie

When NFS calls `nfs_fscache_open_file()` it calls `fscache_use_cookie()`, which
marks the cookie *in-use* and prevents the backend from culling the backing
object while the file is open. In the background, fscache asks CacheFiles to
look up or create the corresponding file object (a file inside `/var/cache/fscache/`
with an encoded path). This lookup is asynchronous — the file may already be
open for a read before the backend has finished preparing the object. fscache
handles this with an internal state machine: reads that arrive before the object
is ready are queued.

On the last `close()`, NFS calls `fscache_unuse_cookie()`. The cookie transitions
back to *unused* and the backend may now cull the object if disk pressure
demands it. When the inode is evicted from memory, NFS calls
`fscache_relinquish_cookie()`, which releases the cookie entirely. Passing
`retire=true` additionally removes the cached object from disk — NFS does this
when the inode has been invalidated and the cached data should not be reused.

### Read path (modern netfs API, kernel ≥ 6.3)

Prior to kernel 5.17, NFS fscache used a page-by-page API
(`fscache_read_or_alloc_page()` and friends). The 5.17 fscache modernisation by
David Howells replaced this with an async DIO model using `iov_iter` and the
`ITER_XARRAY` iterator class, and introduced the `netfs` helper module that can
handle `readpage`, `readahead`, and `write_begin` on behalf of filesystems that
opt in.

The NFS conversion by Dave Wysochanski (landed ~6.3) adopts this model
*conditionally*: the netfs read path is used only when `CONFIG_NFS_FSCACHE` is
set and an `fsc` mount is active. When enabled, `struct nfs_inode` contains an
embedded `struct netfs_inode` (inside an anonymous union so the `vfs_inode`
field stays at the same offset). `struct netfs_inode` in turn embeds the VFS
`inode` and holds the `fscache_cookie`. The helper `netfs_inode()` gives back
the `netfs_inode`, and `netfs_i_cookie()` gives the cookie.

A buffered read now goes through the netfs layer. netfs first checks whether the
requested folio range is already in the page cache. For each missing range, it
tries to satisfy the read from the fscache cookie (CacheFiles checks its on-disk
object). If the data is present on disk, it is read by CacheFiles directly into
the page cache via async DIO — no NFS RPC is issued. If the data is absent (a
cache miss), netfs calls back into NFS via the `issue_read()` callback of
`struct netfs_request_ops`.

NFS's `issue_read()` implementation (`nfs_netfs_issue_read()`) allocates a
small tracking structure, then dispatches the range through the normal NFS pgio
layer (`nfs_pageio_add_page()` etc.). Multiple RPCs may be generated for a
single netfs subrequest. As each RPC completes in `nfs_netfs_read_completion()`,
the tracking structure accumulates the byte count and the first error. When the
last RPC for the subrequest completes, NFS calls `netfs_subreq_terminated()` to
tell the netfs layer how many bytes were transferred (or that an error occurred).
netfs then copies the returned data into the page cache and simultaneously writes
it to the fscache cookie for future cache hits.

### Coherency

fscache itself has no protocol knowledge; coherency is the filesystem's
responsibility. NFS carries coherency data as auxiliary data attached to the
cookie (server-reported `mtime`, `ctime`, file size, and a change attribute).
When a cookie is looked up, fscache compares the stored auxiliary data with what
NFS provides; a mismatch causes invalidation. NFS calls `fscache_invalidate()`
explicitly when it detects that the server's version of the file has changed —
for example, when an `OPEN` or `GETATTR` response shows a new `change`
attribute.

NFS v2/v3 have weak coherency: there is no server-pushed notification that
another client has modified a file. For these versions, caching is only safe
for read-mostly workloads. The mount option `fsc` alone enables caching;
operators on NFS v2/v3 must accept the risk of serving stale data to processes
that do not close-reopen the file. NFS v4 and later use delegations and change
attributes which allow fscache invalidation to be driven more accurately.

### CacheFiles backend

CacheFiles is almost always the backend in practice. It is configured by the
`cachefilesd` daemon, which opens `/dev/cachefiles` and writes configuration
directives specifying the cache root directory (typically `/var/cache/fscache/`)
and threshold percentages:

```
dir /var/cache/fscache
brun 10%    # culling stops when this much space is free
bcull 7%    # culling starts when free space drops here
bstop 3%    # cache rejects new objects at this level
```

Inside the cache root, CacheFiles creates an object hierarchy using encoded
filenames. Volume cookies map to top-level directories (prefixed `I…` or `J…`
for index objects). Data file cookies map to regular files inside those
directories (prefixed `D…` or `E…`). The encoding is stable: the same NFS file
always maps to the same cache file path on the same host.

CacheFiles reads and writes cache objects using `O_DIRECT` file I/O on the
underlying local filesystem, bypassing its page cache to avoid double-buffering.
The *on-demand read mode* (`CONFIG_CACHEFILES_ONDEMAND`) extends this with a
userspace-relay path — a userspace process can serve cache READ requests through
the `/dev/cachefiles` character device — but this is not used in the standard
NFS caching configuration.

Culling removes objects in LRU order (based on atime) when free space drops
below the configured thresholds. Objects in the `graveyard/` subdirectory have
been culled but not yet unlinked; cachefilesd's cleanup thread unlinks them in
the background.

## Key Data Structures

**`struct fscache_volume`** (`include/linux/fscache.h`) — represents one logical
volume (one NFS superblock). Holds the volume key string and a reference to the
cache. NFS stores the pointer as `server->fscache` (the NFS server structure).

**`struct fscache_cookie`** (`include/linux/fscache.h`) — represents one cached
object, typically one NFS inode. Key fields:
- `volume` — back-pointer to the owning volume
- `key` / `key_len` — binary index key identifying this object within its volume
- `aux_data` / `aux_len` — coherency data (mtime, ctime, size, change attr)
- `object_size` — current size of the cached data
- `flags` — state machine bits (FSCACHE_COOKIE_IS_CACHING, FSCACHE_COOKIE_NO_DATA_TO_READ, etc.)

**`struct netfs_inode`** (`include/linux/netfs.h`) — added by the netfs helper
layer inside `struct nfs_inode` when `CONFIG_NFS_FSCACHE=y`. Contains:
- `inode` — the embedded VFS inode (replaces the direct `inode` field in `nfs_inode`)
- `cache` — pointer to the `fscache_cookie` for this inode

**`struct netfs_io_subrequest`** (`include/linux/netfs.h`) — describes a single
I/O subrequest from the netfs layer to NFS. Key fields:
- `start` / `len` — byte range
- `transferred` — bytes successfully transferred so far
- `error` — accumulated error

## Key Functions / Entry Points

**`nfs_fscache_get_super_cookie()`** (`fs/nfs/fscache.c`) — called from NFS
superblock setup; acquires the volume cookie via `fscache_acquire_volume()` using
the server+share derived key.

**`nfs_fscache_open_file()`** (`fs/nfs/fscache.c`) — called on file open; acquires
the data cookie with `fscache_acquire_cookie()` then marks it in-use with
`fscache_use_cookie()`.

**`nfs_fscache_release_file()`** (`fs/nfs/fscache.c`) — called on file close;
calls `fscache_unuse_cookie()` to allow culling.

**`nfs_netfs_issue_read()`** (`fs/nfs/fscache.c`) — the `issue_read` callback in
`struct netfs_request_ops`; dispatches NFS RPCs for a cache-miss subrequest.

**`nfs_netfs_read_completion()`** (`fs/nfs/fscache.c`) — called by NFS pgio when
each RPC in a subrequest completes; on the last RPC calls `netfs_subreq_terminated()`.

**`fscache_invalidate()`** (`include/linux/fscache.h`) — called by NFS when it
detects server-side file changes; discards the stale cached data.

**`fscache_acquire_volume()`** / **`fscache_relinquish_volume()`** — volume
cookie lifecycle, called from NFS superblock init/destroy.

**`fscache_acquire_cookie()`** / **`fscache_relinquish_cookie()`** — data cookie
lifecycle, called from NFS inode init/evict paths.

## Important Flags & Config Options

| Symbol | Purpose |
|---|---|
| `CONFIG_NFS_FSCACHE` | Compiles fscache support into the NFS module |
| `CONFIG_FSCACHE` | The fscache intermediary layer itself |
| `CONFIG_CACHEFILES` | The CacheFiles backend |
| `CONFIG_FSCACHE_STATS` | Enables `/proc/fs/fscache/stats` counters |
| `CONFIG_FSCACHE_DEBUG` | Enables runtime debug bitmask at `/sys/module/fscache/parameters/debug` |
| `CONFIG_CACHEFILES_ONDEMAND` | Enables userspace-driven on-demand cache reads |

**Mount options** (added to the NFS mount command):
- `fsc` — enable fscache for this mount
- `fsc=<tag>` — use a named cache volume (useful when multiple mounts of the same export should share or separate their caches)
- `nosharecache` — force a unique superblock (and unique cache volume) even if server+export match another mount

**Runtime observability**:
- `/proc/fs/fscache/stats` — cumulative counters for cookie allocations, cache hits/misses, I/O ops, invalidations
- `/proc/fs/fscache/cookies` — per-cookie state dump
- `/proc/fs/nfsfs/volumes` — lists NFS volumes with their FSC-enabled flag

## Interactions with Other Subsystems

- **↑ Userspace**: the `fsc` mount option is the only user-visible control knob.
  `cachefilesd` runs in userspace to manage the CacheFiles backend and culling.
  `/proc/fs/fscache/stats` and the `mountstats` file surface cache effectiveness.
- **→ [[fscache]]**: NFS calls the fscache API (`fscache_acquire_volume`,
  `fscache_acquire_cookie`, `fscache_use_cookie`, `fscache_read`,
  `fscache_invalidate`) to request caching services without knowing the backend.
- **→ [[netfs]]**: when `CONFIG_NFS_FSCACHE` is enabled, the NFS read path
  delegates to the netfs helper library for readahead and page cache management.
  NFS provides `struct netfs_request_ops` (specifically `issue_read`) and embeds
  `struct netfs_inode` inside `nfs_inode`.
- **← [[nfs-client]]**: the NFS client drives the cookie lifecycle (acquire on
  iget, use on open, unuse on close, relinquish on evict, invalidate on change
  detection).
- **→ [[page-reclaim]]**: fscache uses ordinary page cache pages for its internal
  tracking; CacheFiles uses direct I/O to the backing filesystem to avoid
  competing with the host page cache.
- **→ [[block]]**: CacheFiles ultimately issues block I/O through the local
  filesystem (ext4/XFS/etc.) stack.

## Design Decisions & Tradeoffs

**Why a separate fscache intermediary rather than caching inside NFS directly?**
Multiple network filesystems (AFS, Ceph, 9P) need the same local-cache
capability. A shared intermediary means a single coherent backend API and a
single set of culling, statistics, and debugging tools. The cost is an extra
indirection: NFS cannot shortcut directly to disk.

**Why CacheFiles stores objects as regular files in a local filesystem:** The
alternative (a block-level cache or a dedicated cache partition) would require a
separate filesystem and admin complexity. Using an existing filesystem gains
journaling, wear levelling (for SSDs), and easy inspection. The downside is
write amplification: writing to both the NFS page cache and the cache file
doubles metadata work on the cache filesystem.

**Why the old page-based API was retired:** The original API monitored page
dirty/writeback state from outside the filesystem and had to wait for complete
pages before caching them. This made it impossible to cache partial pages at
EOF, broke with large-folio and huge-page support, and caused correctness
problems when pages were reclaimed before the cache write completed. The new
async DIO model writes data to the cache at the same time as it fills the page
cache, from within the I/O completion path, avoiding these races.

**Coherency on NFS v2/v3:** The kernel made an explicit tradeoff: provide
caching for read-mostly workloads even on protocol versions that cannot provide
cache-invalidation notifications. The burden is on the operator to know their
workload. Writing to an fsc-mounted NFS v2/v3 export does write through to the
server, but other clients writing concurrently will not trigger a local cache
invalidation.

**Volume key uniqueness and superblock sharing:** NFS by default shares
superblocks (and thus cache volumes) between mounts of the same export. This is
efficient but causes a subtle bug: two mounts with different SELinux context
labels share a volume key, yet the cached objects are technically from different
security domains. The `nosharecache` mount option forces distinct superblocks
and avoids this. The `fsc=<tag>` mechanism additionally allows explicit cache
namespacing.

## How It Has Evolved

**~2008 (2.6.30):** David Howells landed the initial fscache + CacheFiles
implementation along with NFS integration. The API was page-based: NFS called
`fscache_read_or_alloc_page()` for each page and hooked writeback via page flags.

**5.17 (2022):** Major fscache modernisation by David Howells. Removed the object
state machine, the I/O operation manager, and the page-cache snooping mechanism.
Replaced with async DIO using `iov_iter`, the `ITER_XARRAY` class for efficient
xarray-range iteration, and the `netfs` helper module. This release temporarily
*disabled* fscache integration in NFS, Ceph, CIFS, and 9P while the filesystems
were converted to the new API.

**6.3 (2023):** Dave Wysochanski's v11 patchset converted NFS buffered reads to
use the netfs API with fscache. The conversion was non-invasive to the NFS pgio
layer: netfs is only engaged when fscache is configured and an `fsc` mount is
active. NFS-specific fscache statistics (`NFSIOS_FSCACHE` counters, the `fsc:`
mountstats line) were removed in favour of the unified `/proc/fs/fscache/stats`.

## Further Reading

1. [fscache: Modernisation (LWN, 2021)](https://lwn.net/Articles/837939/) — overview of the 5.17 API redesign
2. [Justifying FS-Cache (LWN, 2009)](https://lwn.net/Articles/312708/) — original motivation; render farm use case
3. [FS-Cache: Make NFS use FS-Cache (LWN, 2006)](https://lwn.net/Articles/160122/) — early NFS integration proposal
4. [kernel.org: General Filesystem Caching](https://www.kernel.org/doc/html/latest/filesystems/caching/fscache.html) — current architecture reference
5. [kernel.org: Network Filesystem Caching API](https://www.kernel.org/doc/html/latest/filesystems/caching/netfs-api.html) — netfs helper API
6. [kernel.org: Cache Backend API](https://www.kernel.org/doc/html/latest/filesystems/caching/backend-api.html) — CacheFiles integration point
7. [Caching NFS files with cachefilesd (support.tools)](https://support.tools/post/caching-nfs-files-with-cachefilesd/) — practical setup guide

## LKML Highlights

**"Convert NFS with fscache to the netfs API" (v11, 2023)**
`20230220134308.1193219-1-dwysocha@redhat.com` — Dave Wysochanski's 5-patch series
that landed NFS on the modernised fscache/netfs API. The cover letter documents
the core engineering challenge: the netfs layer expects a single response per
subrequest, while the NFS pgio layer may generate many RPCs for the same range.
The fix is a small reference-counted tracker structure that collects per-RPC
results and fires `netfs_subreq_terminated()` when the last RPC completes. Also
reveals two known issues at the time: `rsize < readahead` causing cache bypasses,
and "Cache volume key already in use" with multiple mounts with explicit SELinux
contexts.

**Cookie state deadlock report (2023)**
`CALF+zOnr0B2w-0jY4DK6Asgb8m2g9d9hecR0mgw6wausaEEaSA@mail.gmail.com` — Chris
Chilvers reported nfsd threads blocking indefinitely on `folio_wait_bit_common`
when using NFS as a caching re-export proxy. The kernel log showed repeated
`fscache_begin_operation: cookie state change wait timed out` messages, pointing
to a liveness issue in the cookie state machine under heavy concurrent load. The
thread illustrates the difficulty of integrating an asynchronous, reference-counted
caching layer with a synchronous, folio-locked filesystem I/O model.
