---
title: "netfs Inode Context"
category: concept
tags: [netfs, inode, fscache, locking, network-filesystem]
subsystem: netfs
kernel_version: "5.13"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html
  - https://lwn.net/Articles/894589/
---

# netfs Inode Context

## Purpose

Every file in a network filesystem that uses netfs needs per-inode state: a pointer to its I/O operation callbacks, an fscache cookie for optional local caching, the server's notion of file size (which may differ from the kernel's `i_size`), and control flags that change I/O policy. Rather than patching `struct inode` or using a separate sidecar allocation, netfs defines `struct netfs_inode` — a struct that embeds the VFS inode and extends it with netfs-private fields — which filesystems embed in their own inode wrappers.

## Mental Model

Think of `struct netfs_inode` as the **netfs-aware inode supertype**. The VFS inode is at offset zero (so all VFS code continues to work without casts), and the extra netfs fields sit immediately after. From the filesystem's perspective, the wrapper is just a slightly larger allocation; from netfs's perspective, `netfs_inode()` is a container_of accessor that gives it everything it needs to manage I/O for that file without knowing anything about the filesystem's other private fields.

## How It Works

### Embedding in the filesystem's inode wrapper

A network filesystem allocates its own inode wrapper struct with `struct netfs_inode` as the first embedded field:

```c
struct afs_vnode {           /* AFS example */
    struct netfs_inode  netfs;   /* must be first */
    /* AFS-private fields follow */
    struct afs_fid      fid;
    ...
};
```

The VFS `struct inode` is itself the first field of `struct netfs_inode`, so `&vnode->netfs.inode` is a valid `struct inode *`. The accessor `netfs_inode(inode)` walks from any `struct inode *` back to the surrounding `struct netfs_inode *` via `container_of`.

At inode allocation time (inside `->alloc_inode()`), the filesystem calls `netfs_inode_init(netfs_inode, ops, use_zero_point)` to zero the netfs fields and set the `ops` pointer. The `ops` pointer is the only required input — it points to the filesystem's static `netfs_request_ops` table.

### fscache cookie

`netfs_inode.cache` holds the `fscache_cookie *` for this file. It is NULL if caching is disabled or the cookie has not yet been acquired. At file open, the filesystem calls `fscache_use_cookie(cookie, will_modify)` to signal that the file is actively being accessed; this prevents the cookie from being discarded under memory pressure. At file close, `fscache_unuse_cookie(cookie, aux_data, object_size)` updates the cookie's coherency metadata and allows reclamation.

The cookie is the handle through which netfs interacts with fscache: when a read subrequest hits the cache, netfs passes `netfs_inode.cache` to `fscache_begin_read_operation()`; when a folio is dirtied, `fscache_dirty_folio()` tags the folio with the cookie.

### remote_i_size

`remote_i_size` stores the file size as reported by the server, independently of `inode.i_size`. This is necessary because the kernel may have cached data beyond the server's current EOF (e.g., the file was truncated on the server without notifying the client), or the server may report a larger size than the client has yet fetched (e.g., another client extended the file). Netfs uses `remote_i_size` to decide whether a hole in the read range is genuinely sparse or simply represents data not yet downloaded, and filesystems can implement `netfs_request_ops.update_i_size()` to update both sizes atomically.

### I/O policy flags

The `flags` field drives per-inode I/O mode selection:

- `NETFS_ICTX_UNBUFFERED` — all I/O bypasses the page cache. Used when the filesystem guarantees server-side coherency (e.g., when a DIO-only mode is enabled). `netfs_file_read_iter()` and `netfs_file_write_iter()` automatically select the unbuffered path when this flag is set.
- `NETFS_ICTX_WRITETHROUGH` — on buffered write, data is synchronously written to server and cache before the write syscall returns. Slower, but guarantees durability without relying on periodic writeback.
- `NETFS_ICTX_SINGLE_NO_UPLOAD` — the file is a read-only monolithic object (e.g., a cached executable). Reads use `netfs_read_single()` (one RPC, no subrequest splitting); writeback uses `netfs_writeback_single()` to update only the local cache, never the server.

### Four-class locking model

Network filesystems have more complex concurrency requirements than local filesystems. A local write holds `i_rwsem` and updates pages atomically; a network write may race with server-side concurrent writers that the kernel cannot control. netfs imposes a four-class locking model on top of VFS locking:

1. **Buffered reads** — fully concurrent; no extra locking beyond the individual folio lock. Multiple processes can read through the page cache simultaneously.
2. **Buffered writes** — serialized with each other using an internal per-inode write semaphore. Concurrent with buffered reads.
3. **Direct (unbuffered) I/O** — fully concurrent. DIO bypasses the page cache entirely, so there is no folio contention; correctness is provided by the server's own locking protocol.
4. **Major operations** (truncate, fallocate, `setattr`) — exclusive. These take `i_rwsem` directly and exclude all other I/O.

mmap is treated as a pseudo-class: concurrent with everything, but acts as a shared buffer that may trigger loopback DIO within the same file.

The six transition functions implement the class boundaries:
- `netfs_start_io_read()` / `netfs_end_io_read()` — class 1 (buffered read entry/exit)
- `netfs_start_io_write()` / `netfs_end_io_write()` — class 2 (buffered write entry/exit)
- `netfs_start_io_direct()` / `netfs_end_io_direct()` — class 3 (DIO entry/exit)

Major operations (class 4) manage `i_rwsem` themselves; netfs does not provide wrappers.

## Key Data Structures

**`struct netfs_inode`** (`include/linux/netfs.h`) — the per-file netfs context; must be embedded first in the filesystem's inode wrapper.
- `inode` — embedded `struct inode`; VFS inode for this file
- `ops` — pointer to `const struct netfs_request_ops`; the filesystem's I/O callback table
- `cache` — `struct fscache_cookie *`; NULL if caching is inactive
- `remote_i_size` — `loff_t`; server-reported file size
- `flags` — `unsigned long`; policy flags (`NETFS_ICTX_UNBUFFERED`, `NETFS_ICTX_WRITETHROUGH`, `NETFS_ICTX_SINGLE_NO_UPLOAD`)

## Key Functions / Entry Points

**`netfs_inode(inode)`** (`include/linux/netfs.h`) — container_of from `struct inode *` to `struct netfs_inode *`; used throughout netfs to access per-file state.

**`netfs_inode_init(ctx, ops, zero_point)`** (`fs/netfs/`) — initializes a newly allocated `netfs_inode`; sets `ops`, zeroes other fields. Called from `->alloc_inode()`.

**`netfs_start_io_read()` / `netfs_end_io_read()`** — class-1 buffered-read lock/unlock.

**`netfs_start_io_write()` / `netfs_end_io_write()`** — class-2 buffered-write lock/unlock.

**`netfs_start_io_direct()` / `netfs_end_io_direct()`** — class-3 DIO lock/unlock.

**`fscache_use_cookie()` / `fscache_unuse_cookie()`** (`fs/fscache/`) — activate/deactivate the fscache cookie at open/close; called by the filesystem, not by netfs directly.

## Important Flags & Config Options

- `NETFS_ICTX_UNBUFFERED` — skip page cache for all I/O on this inode
- `NETFS_ICTX_WRITETHROUGH` — synchronous write-through to server and cache
- `NETFS_ICTX_SINGLE_NO_UPLOAD` — read-only monolithic object; use single-blob I/O path
- `I_PINNING_NETFS_WB` — inode state flag (not Kconfig); set when dirty folios pin the fscache cookie to prevent teardown during writeback

## Interactions with Other Subsystems

- **↑ VFS**: the embedded `struct inode` is returned from `->alloc_inode()` and used by all VFS paths; `netfs_inode()` is the bridge back to netfs state.
- **→ [[fscache]]**: `netfs_inode.cache` is the fscache cookie handle; all cache operations go through it.
- **← Filesystem**: the filesystem embeds `struct netfs_inode`, calls `netfs_inode_init()`, and implements `netfs_request_ops` pointed to by `ops`.
- **← [[mm]]**: folio allocation and the page cache are mm facilities; netfs reads/writes go through the page cache via the embedded inode's `i_mapping`.

## Design Decisions & Tradeoffs

**Embedding vs. sidecar pointer**: An alternative design would store netfs state in a separate allocation pointed to from `struct inode` (similar to how some subsystems use `inode->i_private`). Embedding `struct netfs_inode` instead keeps hot fields (ops, cache cookie, flags) in the same cache line as the inode itself, avoiding a pointer dereference on every I/O path entry. The cost is that all filesystems using netfs must change their inode allocator — a one-time migration cost.

**`remote_i_size` as a separate field**: Some early designs updated `i_size` directly and relied on cache invalidation to keep it coherent. A dedicated `remote_i_size` field was chosen instead because it allows netfs to detect mid-flight size changes (the server shrinks the file while a read is in progress) and handle them as hole-fill vs. EOF decisions without corrupting `i_size`.

**Four locking classes vs. a single rwsem**: A single rwsem for all I/O types would be simpler but would serialise buffered reads against each other (bad for read-heavy workloads) or allow DIO to race with truncate (unsafe). The four-class model gives maximum concurrency within each class while providing strong isolation between classes that need it.

## How It Has Evolved

- **v5.13**: `struct netfs_inode` introduced with `inode`, `ops`, `cache`, `flags`.
- **v5.19**: `remote_i_size` added to track server-side size independently.
- **v6.7**: `I_PINNING_NETFS_WB` flag meaning migrated from fscache's `I_PINNING_FSCACHE_WB` to netfs's flag; writeback resource pinning now owned entirely by netfs.
- **v6.9**: `NETFS_ICTX_SINGLE_NO_UPLOAD` flag and single-blob object API added for read-only cached objects.

## Further Reading

1. [Network Filesystem Services Library — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html)
2. [The netfslib helper library — LWN.net](https://lwn.net/Articles/894589/)
