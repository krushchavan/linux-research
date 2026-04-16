---
title: "CacheFiles Backend"
category: concept
tags: [cachefiles, fscache, caching, backend, on-disk, cachefilesd]
subsystem: fscache
kernel_version: "2.6.30"
researched: 2026-04-15
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/caching/cachefiles.html
  - https://www.kernel.org/doc/html/latest/filesystems/caching/backend-api.html
  - https://lwn.net/Articles/877058/
  - https://lwn.net/Articles/176487/
---

# CacheFiles Backend

## Purpose

CacheFiles is the production cache backend for [[fscache]]. It implements the `fscache_cache_ops` interface by storing cached data as ordinary files on an already-mounted local filesystem (ext4, xfs, btrfs, etc.), reusing the local filesystem's block allocator, crash recovery, and VFS locking rather than inventing its own. This design means you can add a cache with nothing more than a directory—no partitioning, no special formatting.

## Mental Model

CacheFiles is a **filing clerk** who uses ordinary filing cabinets (the local filesystem) to store photocopies (cached data). Each cabinet drawer is a volume, each folder is a cached file. The clerk is handed requests by fscache, fetches or files documents, and defers space management paperwork to the cachefilesd daemon.

## How It Works

### On-Disk Layout

CacheFiles roots its structure at a configurable directory (set by the daemon as the "dir" command). Inside this root two directories always exist:

- `cache/` — active cached objects
- `graveyard/` — retired or culled objects awaiting daemon deletion

Within `cache/`, volumes map to directories named by the volume's printable key. Each cached file within a volume maps to a regular file. The filename encodes the data cookie's binary key:

| Key type | Filename prefix |
|---|---|
| Printable index object | `I...` |
| Encoded index object | `J...` |
| Printable data file | `D...` |
| Encoded data file | `E...` |
| Printable special | `S...` |
| Encoded special | `T...` |

For keys with `/`, NUL, or other characters unsuitable for filenames, the key is base-64 encoded (producing a longer `J...` or `E...` filename). Keys longer than `NAME_MAX` are split across nested directories using `+`-prefixed intermediate directories.

### Extended Attributes (xattrs)

Each cache file carries an xattr (`user.CacheFiles.cache`) containing the object type identifier and the netfs's `aux_data` blob (coherency data from the [[fscache-cookie-subsystem]]). On cookie lookup, CacheFiles reads this xattr and compares the stored coherency data against the current value the filesystem reports. A mismatch means the cached content is stale: CacheFiles creates a replacement backing file and retires the old one to the graveyard.

This is how fscache detects, for example, that an NFS file has been modified on the server while the client was offline—the mtime in the xattr no longer matches the server-returned mtime, so the old cache content is discarded.

### I/O: Async Direct I/O

All cache reads and writes use async direct I/O via the kiocb interface (`IOCB_DIRECT`). This was the central change in the 5.17 rewrite:

- **Old path**: CacheFiles read data into its own page cache and then copied pages into the netfs's page cache. Memory overhead was doubled: two copies of every cached page existed simultaneously.
- **New path**: CacheFiles issues DIO reads/writes directly into the netfs's folios. No intermediate buffer; the data goes from disk to the application's folio in one transfer.

The async completion path calls back into netfslib via `netfs_subreq_terminated()` when the DIO operation completes, which progresses the overall `netfs_request` and unlocks folios.

### Space Management

CacheFiles maintains six configurable thresholds expressed as percentages of total disk space and total file count:

```
0% ── bstop/fstop ── bcull/fcull ── brun/frun ── 100%
         │                │              │
       Halt            Cull          Cull stops
     allocation         on            when both
                       either          exceeded
```

- Below `bstop`/`fstop`: all allocation halts; cached reads still work but no new data can be written to the cache.
- Below `bcull`/`fcull`: the daemon's culling loop activates.
- Above `brun`/`frun`: the daemon stops culling.

The kernel module itself only performs object lifecycle transitions (moving objects to the graveyard); the daemon (`cachefilesd`) does actual file deletion via directory scanning and `unlinkat()` calls. This keeps complex namespace operations out of the kernel.

### Culling: LRU by Access Time

The daemon periodically scans the `cache/` tree, collecting objects whose access time (`atime`) is oldest. It builds a sorted list and unlinks from least recently used until thresholds are satisfied. This is a simple LRU approximation—there is no more sophisticated eviction policy in the current implementation (though moving culling into the kernel and adding priority tiers is a stated future goal).

### Security Model

When the kernel creates or accesses a cache file on behalf of a user process, it needs to act with privileges the user does not have (the cache directory is owned by root/cachefilesd). CacheFiles solves this with credential switching:

- The **objective security context** (`task->real_cred`) remains the user process's credentials—this is what `/proc` shows, and it's unchanged.
- The **subjective security context** (`task->cred`) is temporarily replaced with the cachefilesd daemon's credentials while the kernel performs cache file operations.

This prevents LSM (SELinux, AppArmor) from seeing the operation as the unprivileged user process accessing root-owned files. Cache files are labelled `cachefiles_var_t` in SELinux; the daemon operates as `cachefilesd_t` with a narrow permission set: stat, scan, and delete (no read/write or create).

### On-Demand Mode (CONFIG_CACHEFILES_ONDEMAND)

Added in 6.1, this mode replaces the original model where the kernel always fetched missing data from the network directly. In on-demand mode:

1. On a cache miss, the kernel sends a message to the daemon via `/dev/cachefiles` using `struct cachefiles_msg`.
2. The daemon fetches the data from the network (or any other source) and writes it into the cache file through an anonymous file descriptor.
3. The daemon ACKs the message; the kernel resumes the blocked read.

This allows the "local filesystem" backing the cache to itself be a network store (e.g., a container image overlay), enabling deployment in Kata Containers and similar environments where there is no truly local disk. The tradeoff is one IPC round trip on every cache miss.

The three message types are:
- `CACHEFILES_OP_OPEN` — daemon should open a cache object and return an anonymous fd
- `CACHEFILES_OP_READ` — daemon should populate a specific byte range in the cache file
- `CACHEFILES_OP_CLOSE` — daemon should close its anonymous fd for a cookie being withdrawn

## Key Data Structures

**`struct fscache_cache_ops`** (`include/linux/fscache-cache.h`) — the interface CacheFiles implements:
- `lookup_cookie()` — allocate or find the on-disk object for a data cookie; called by `fscache_use_cookie()`
- `withdraw_cookie()` — decommission a cookie cleanly (flush pending I/O, close backing file)
- `invalidate_cookie()` — retire the old backing object and create a fresh tmpfile replacement
- `resize_cookie()` — truncate or extend the backing file on inode size change
- `begin_operation()` — set up an I/O operation (kiocb state, DIO parameters); called before each cache read/write

**`struct cachefiles_msg`** (`include/uapi/linux/cachefiles.h`) — on-demand protocol wire format:
- `msg_id` — unique request identifier (used to match ACKs)
- `opcode` — `CACHEFILES_OP_OPEN`, `CACHEFILES_OP_READ`, `CACHEFILES_OP_CLOSE`
- `len` — total message length including `data[]` payload
- `object_id` — CacheFiles internal object identifier
- `data[]` — variable-length payload (volume key, cookie key, byte range for READ)

## Key Functions / Entry Points

**`cachefiles_open_file()`** (`fs/cachefiles/namei.c`) — opens or creates the backing regular file for a cookie during `lookup_cookie()`; verifies coherency via xattr.

**`cachefiles_check_auxdata()`** (`fs/cachefiles/xattr.c`) — reads and compares the `user.CacheFiles.cache` xattr against the cookie's current coherency data; returns stale/fresh/absent.

**`cachefiles_read()`** (`fs/cachefiles/io.c`) — issues async DIO read from the backing file into the netfs's folios; calls `netfs_subreq_terminated()` on completion.

**`cachefiles_write()`** (`fs/cachefiles/io.c`) — issues async DIO write from the netfs's folios into the backing file; used for cache-fill writes after RPC reads.

**`cachefiles_cull()`** (`fs/cachefiles/culling.c`) — kernel-side helper that moves an object from `cache/` to `graveyard/`; actual deletion is done by the daemon.

**`cachefiles_ondemand_read()`** (`fs/cachefiles/ondemand.c`) — sends a `CACHEFILES_OP_READ` message to the daemon via `/dev/cachefiles` and blocks until the daemon ACKs.

## Important Flags & Config Options

- `CONFIG_CACHEFILES` — the CacheFiles backend kernel module
- `CONFIG_CACHEFILES_DEBUG` — enables expensive debug assertions and per-object state checking
- `CONFIG_CACHEFILES_ONDEMAND` — enables the on-demand mode; required for Kata Containers and EROFS-over-network use cases
- `/proc/fs/cachefiles` — runtime statistics (reads, writes, culls, errors)
- `/sys/module/cachefiles/parameters/debug` — debug bitmask (0 = off, 1 = object, 2 = I/O, 4 = naming)

**Daemon configuration** (in `/etc/cachefilesd.conf`):
- `dir /var/cache/fscache` — root of the cache directory
- `brun 10` / `bcull 7` / `bstop 3` — block threshold percentages
- `frun 10` / `fcull 7` / `fstop 3` — file count threshold percentages
- `secctx cachefiles_kernel_t` — SELinux context the kernel module should use

## Interactions with Other Subsystems

- **← [[fscache-cookie-subsystem]]**: CacheFiles receives `lookup_cookie()`, `withdraw_cookie()`, `invalidate_cookie()`, and `begin_operation()` calls from fscache when cookies transition states
- **← [[netfs-helper-library]]**: netfslib dispatches cache subrequests to CacheFiles through the fscache I/O path; CacheFiles calls back via `netfs_subreq_terminated()`
- **→ [[vfs]]**: CacheFiles uses standard VFS calls (`vfs_open()`, `kernel_read()`, `kernel_write()`, async DIO via kiocb) on the local filesystem; it does not bypass VFS
- **→ [[security]]**: CacheFiles uses credential switching (`override_creds()` / `revert_creds()`) and SELinux type transitions; every cache file operation runs under the module's security context, not the user's
- **↑ Userspace**: the `cachefilesd` daemon opens `/dev/cachefiles`, issues configuration commands, handles culling, and (in on-demand mode) answers kernel read requests

## Design Decisions & Tradeoffs

**Reuse an existing local filesystem rather than format a raw partition**: This means CacheFiles inherits crash consistency, block allocation, and directory operations for free. The downside is CacheFiles can only be as fast as the local filesystem allows—it cannot, for example, use a log-structured layout optimised for cache workloads. The design prioritises operational simplicity (no special partitioning) over maximum throughput.

**Culling in userspace**: Moving objects to a graveyard and letting `cachefilesd` delete them keeps complex namespace manipulation (recursive directory deletion, large `unlinkat()` storms) out of the kernel. The tradeoff: if the daemon dies, graveyard objects accumulate until it restarts, potentially consuming disk space. The daemon must be kept alive by the init system.

**DIO instead of page-cache snooping**: The pre-5.17 approach of reading data into the backing file's page cache and then copying to the netfs page cache doubled memory usage for all cached data. DIO reads directly into the netfs's folios at the cost of more complex async I/O bookkeeping (no page-cache shortcuts, must handle `O_DIRECT` alignment constraints on the backing filesystem).

**On-demand mode via character device**: The `/dev/cachefiles` IPC mechanism was chosen to reuse existing kernel-userspace messaging patterns. The alternative (netlink) would have added protocol complexity. The character device approach means on-demand mode requires a running daemon—there is no fallback to in-kernel network fetching.

## How It Has Evolved

- **2.6.30 (2009)**: First upstream merge. Basic cache-on-filesystem model; page-cache snooping for I/O; complex object state machine.
- **4.x–5.10**: Incremental fixes; NFS, AFS, Ceph integration; persistent issues with the object state machine under heavy load.
- **5.17 (2022)**: Complete rewrite: async DIO replaces page-cache snooping; tmpfile-based invalidation; object state machine removed; xattr content map introduced for presence tracking.
- **6.1 (2022)**: `CONFIG_CACHEFILES_ONDEMAND` added; `/dev/cachefiles` request-reply protocol for container and overlay use cases.

## Further Reading

1. [fscache, cachefiles: Rewrite (LWN, 2021)](https://lwn.net/Articles/877058/) — the definitive article on the 5.17 CacheFiles rewrite
2. [Network filesystem caching on local cache files (LWN, 2006)](https://lwn.net/Articles/176487/) — original design rationale
3. [kernel.org: Cache on Already Mounted Filesystem](https://www.kernel.org/doc/html/latest/filesystems/caching/cachefiles.html) — daemon configuration, on-disk format, security model
4. [kernel.org: FS-Cache Backend API](https://www.kernel.org/doc/html/latest/filesystems/caching/backend-api.html) — complete `fscache_cache_ops` reference
