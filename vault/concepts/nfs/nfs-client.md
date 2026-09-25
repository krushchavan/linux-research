---
title: "NFS Client"
category: concept
tags: [nfs, network-filesystem, rpc, caching, state-management]
subsystem: nfs
kernel_version: "2.6"
researched: 2026-04-05
status: complete
explained: "[[nfs-client-explained]]"
sources:
  - https://lwn.net/Articles/898262/
  - https://docs.kernel.org/admin-guide/nfs/nfs-client.html
  - https://github.com/torvalds/linux/blob/master/fs/nfs/client.c
  - https://github.com/torvalds/linux/tree/master/fs/nfs
  - https://avidandrew.com/understanding-nfs-caching.html
---

# NFS Client

> 📘 Plain-language version: [[nfs-client-explained]]

## Purpose

The Linux NFS client integrates a remote NFS filesystem into the local VFS, allowing processes to read and write files on a network server using the same syscalls they use for local files. It must handle network latency, server-side state (NFSv4+), aggressive caching with coherency enforcement, and recovery from server restarts and network interruptions — all while appearing to userspace as a normal POSIX filesystem.

## Mental Model

The NFS client is a **caching proxy** that translates VFS operations into RPC calls to a remote server. It maintains an aggressive attribute and data cache (backed by the page cache) to avoid round-trips, and enforces cache coherency using timestamps (NFSv2/3) or server-issued change attributes and delegations (NFSv4+). The deeper the NFS version, the more state the client tracks: NFSv4 introduces per-file open state, locks, and delegations, which the client must recover if the server reboots.

## How It Works

### Object hierarchy

The NFS client has a layered object hierarchy:

```
nfs_client          — one per (server address, NFS version) pair
  └── nfs_server    — one per mounted export (one nfs_client may back many mounts)
        └── nfs_inode — one per inode; embeds struct inode
              └── nfs_page — one per pending read/write page request
```

**`struct nfs_client`** (`include/linux/nfs_fs_sb.h`) represents the connection to a specific server IP + NFS version. It holds the `rpc_clnt` (RPC transport), server capabilities, and NFSv4 client ID / lease management state. One `nfs_client` is shared across all mounts of the same server:
- `cl_rpcclient` — the `rpc_clnt` used for all RPCs to this server
- `cl_clientid` — NFSv4 client ID negotiated at session setup
- `cl_state` — connection state flags (`NFS_CS_READY`, `NFS_CS_SESSION_INITING`, etc.)
- `cl_lease_time` — server-granted lease duration (NFSv4)

**`struct nfs_server`** (`include/linux/nfs_fs_sb.h`) represents one mounted export. It holds per-mount settings (rsize, wsize, acdirmin, acregmax), a back-pointer to `nfs_client`, and the root file handle for this mount point.

**`struct nfs_inode`** (`include/linux/nfs_fs.h`) embeds `struct inode` and adds NFS-specific metadata:
```c
struct nfs_inode {
    struct inode         vfs_inode;     /* must be first */
    __u64                fileid;        /* NFS file ID */
    struct nfs_fh        fh;            /* NFS file handle */
    unsigned short       cache_validity; /* NFS_INO_INVALID_ATTR, etc. */
    unsigned long        read_cache_jiffies;  /* when attrs were last validated */
    __u64                change_attr;   /* NFSv4 change counter */
    struct nfs_open_context *cache_access; /* NFSv4 open context for caching */
    struct list_head     open_files;    /* NFSv4 open state list */
    ...
};
```

### Attribute caching and revalidation

NFS clients cache inode attributes (size, mtime, ctime, permissions) to avoid a `GETATTR` RPC on every `stat()`. Cached attributes are valid for a configurable window: `acregmin`–`acregmax` for files, `acdirmin`–`acdirmax` for directories (defaults: 3–60 s for files, 30–60 s for directories).

On each VFS operation that needs current attributes, `nfs_revalidate_inode()` checks whether the cached attributes are still within their TTL. If stale, it sends a `GETATTR` RPC and updates `nfs_inode.cache_validity`. In NFSv4, the server provides a `change` attribute (a 64-bit counter) which is compared against `nfs_inode.change_attr` — a change in this value (even without mtime change) invalidates the cache, fixing a classic NFS coherency problem with same-second writes.

### Page cache and write buffering

Read data and write-buffered data live in the VFS page cache. Reads use `nfs_readpage()` / `nfs_readpages()` which submit `READ` RPCs via `nfs_pgio_header`. Writes use `nfs_write_begin()` / `nfs_write_end()` which mark pages dirty; writeback is driven by `nfs_writepage()` / `nfs_writepages()` which batch dirty pages into `nfs_pgio_header` structs and send `WRITE` RPCs.

In NFSv3, writes use either `UNSTABLE` (server buffers, faster) or `FILE_SYNC` (disk-sync, slower) modes. After unstable writes, the client must send a `COMMIT` RPC to flush server buffers before closing a file or syncing — this is the "open-to-close coherency" model: data written between `open` and `close` may be buffered in the server's memory, but is committed to stable storage by the time `close` returns.

### NFSv4 open state

NFSv4 is a stateful protocol. Opening a file with `OPEN` RPC returns an **open stateid** that the client must present in subsequent `READ`, `WRITE`, and `LOCK` calls. The open state is tracked per `nfs4_state` struct, linked from `nfs_inode.open_files`. When the server reboots (detected via expired lease), the client must re-establish all open state through an `nfs4_recovery` workqueue process.

**Delegations** are server-issued promises that no other client is modifying the file. A **read delegation** lets the client cache aggressively without checking the server on every read. A **write delegation** gives exclusive write access; the client can buffer writes and only commit on close. If another client wants to open the file, the server sends a callback (`CB_RECALL`) which the client honours by flushing buffers and returning the delegation.

### RPC transport

All NFS operations are translated to RPC calls via `fs/sunrpc/`. Each NFS version provides an `rpc_program` with per-procedure descriptors (`nfs_procedures[]`). The common path is:
1. Build an `rpc_task` with the operation's XDR encode/decode functions and arguments.
2. Submit to the `rpc_clnt` which manages connection state, retransmission, and backoff.
3. On reply, the XDR decode function fills in the kernel structs.
4. Wake the waiting process.

The `[[sunrpc]]` and `[[xdr-encoding]]` subsystems handle the transport and encoding layers respectively.

## Key Data Structures

**`struct nfs_client`** (`include/linux/nfs_fs_sb.h`) — one per server; holds `rpc_clnt` and NFSv4 lease state.

**`struct nfs_server`** (`include/linux/nfs_fs_sb.h`) — one per mount; holds per-mount options, rsize/wsize, root fh.

**`struct nfs_inode`** (`include/linux/nfs_fs.h`) — embeds `struct inode`; adds file handle, change attr, open state list.

**`struct nfs4_state`** (`include/linux/nfs4.h`) — per-open-file NFSv4 state; holds open stateid, lock state, delegation.

**`struct nfs_pgio_header`** (`include/linux/nfs_fs.h`) — groups a batch of `nfs_page` requests for a single `READ` or `WRITE` RPC.

## Key Functions / Entry Points

**`nfs_create_server()`** (`fs/nfs/client.c`) — allocates `nfs_client` + `nfs_server`, probes server capabilities via `FSINFO`, sets up RPC client.

**`nfs_revalidate_inode()`** (`fs/nfs/inode.c`) — checks and refreshes cached attributes; sends `GETATTR` if stale.

**`nfs_readpages()` / `nfs_writepages()`** (`fs/nfs/read.c`, `fs/nfs/write.c`) — page cache read/write dispatch; batches page requests into RPCs.

**`nfs4_proc_open()`** (`fs/nfs/nfs4proc.c`) — sends `OPEN` compound RPC, creates `nfs4_state`, handles delegation.

**`nfs4_handle_exception()`** (`fs/nfs/nfs4proc.c`) — processes NFSv4 error codes, triggers state recovery on `NFS4ERR_STALE_CLIENTID` / `NFS4ERR_EXPIRED`.

**`nfs4_recovery_handle_error()`** / `nfs4_state_manager()` (`fs/nfs/nfs4state.c`) — workqueue-driven state recovery after server restart.

## Important Flags & Config Options

| Option | Effect |
|---|---|
| `vers=3\|4\|4.1\|4.2` | NFS protocol version |
| `rsize=N` / `wsize=N` | Read/write chunk size (default: server-negotiated, up to 1 MiB) |
| `acregmin=N` / `acregmax=N` | Attribute cache lifetime for regular files |
| `acdirmin=N` / `acdirmax=N` | Attribute cache lifetime for directories |
| `noac` | Disable attribute caching (coherent but slow) |
| `sync` | Synchronous writes (equivalent to `FILE_SYNC` mode) |
| `fsc` / `nofsc` | Enable/disable FS-Cache (local disk caching of NFS data) |
| `hard` / `soft` | Hard: retry forever on server unreachable; soft: return errors after `retrans` retries |

## Interactions with Other Subsystems

- **↑ Userspace**: standard POSIX filesystem syscalls (`open`, `read`, `write`, `stat`, `fsync`); `mount(2)` with type `nfs`; `mount.nfs(8)` utility.
- **→ [[sunrpc]]**: every NFS operation becomes an RPC call; the sunrpc layer handles transport, authentication (AUTH_SYS, Kerberos via RPCSEC_GSS), and retransmission.
- **→ [[xdr-encoding]]**: request and response arguments are encoded/decoded using XDR; each NFS version provides XDR codec functions.
- **→ VFS page cache**: read data is cached in the page cache; dirty pages are written back via `nfs_writepages`.
- **→ FS-Cache**: optionally caches read-only NFS data to a local block device, reducing network traffic for repeated reads.
- **← [[nfs-server]]**: the client's server counterpart; the client initiates RPCs; the server sends NFSv4 callbacks (`CB_RECALL`, `CB_NOTIFY`) in the reverse direction.

## Design Decisions & Tradeoffs

**Aggressive caching vs. coherency**: NFS's default `ac` (attribute caching) means clients may serve stale data for up to `acregmax` seconds. This is a deliberate performance/coherency tradeoff. `noac` provides full coherency at the cost of a `GETATTR` on every operation. Applications requiring coherent cross-client access should use NFSv4 delegations or application-level coordination.

**Stateful NFSv4 vs. stateless NFSv3**: NFSv3 is stateless — every operation is idempotent, recovery from server restart is trivial (just retry). NFSv4 tracks per-client lease state which enables delegations and locking but requires complex recovery when the server reboots (`state_manager` workqueue with exponential backoff and `RECLAIM_COMPLETE`).

**Hard vs. soft mount**: Hard mounts retry indefinitely; soft mounts return `-EIO` after `retrans` failures. Hard is safer for data integrity but risks hanging processes on server outages. Soft is more responsive but may corrupt open files on transient failures. Most production deployments use hard mounts with `intr` to allow SIGKILL to interrupt stuck operations.

**open-to-close coherency**: On `close()`, any dirty pages are committed to the server's stable storage (a `COMMIT` RPC in NFSv3, implicit in NFSv4 `CLOSE`). Between open and close, cached writes may not be visible to other clients unless they also open the file. This is weaker than POSIX but acceptable for most workloads and avoids synchronous writes on every operation.

## How It Has Evolved

- **2.0 (1992)**: NFSv2 client merged into Linux.
- **2.2 (1999)**: NFSv3 support added.
- **2.6.0 (2003)**: NFSv4 client merged.
- **2.6.38 (2011)**: NFSv4.1 client merged (sessions, pNFS framework).
- **3.9 (2013)**: NFSv4.2 features (server-side copy, space reservation).
- **4.x**: FS-Cache integration; improved writeback coalescing.
- **5.3 (2019)**: NFSv4.2 `READ_PLUS` (sparse file support).

## Further Reading

1. **LWN — "NFS: the new millennium"** (2021): https://lwn.net/Articles/898262/ — NFSv4 state management and change attribute evolution.
2. **Kernel docs — NFS client**: https://docs.kernel.org/admin-guide/nfs/nfs-client.html
3. **Understanding NFS Caching**: https://avidandrew.com/understanding-nfs-caching.html
