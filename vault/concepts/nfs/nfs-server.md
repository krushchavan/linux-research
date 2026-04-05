---
title: "NFS Server (knfsd/nfsd)"
category: concept
tags: [nfs, nfsd, knfsd, server, rpc, export, file-handle]
subsystem: nfs
kernel_version: "2.2"
researched: 2026-04-05
status: complete
sources:
  - https://docs.kernel.org/filesystems/nfs/exporting.html
  - https://man7.org/linux/man-pages/man7/nfsd.7.html
  - https://lwn.net/Articles/192715/
  - https://lwn.net/Articles/788686/
  - https://github.com/torvalds/linux/tree/master/fs/nfsd
---

# NFS Server (knfsd/nfsd)

## Purpose

The Linux kernel NFS server (historically "knfsd", now simply "nfsd") serves files from the local filesystem to NFS clients over the network. It runs entirely in kernel space — unlike the older user-space `nfsd` that required a context switch per request — allowing it to call VFS functions directly on exported paths. This makes it dramatically faster than user-space NFS servers for high-throughput workloads while still being configurable from userspace via the `nfsd` pseudo-filesystem (`/proc/fs/nfsd/`).

## Mental Model

Knfsd is a pool of kernel threads (`nfsd/N`) that sit in a loop, pulling RPC requests from the sunrpc service layer, dispatching each to the appropriate NFS procedure handler, and writing back the reply. Each handler translates the NFS operation into one or more VFS calls (via the `export_operations` interface), operates on the exported filesystem, and serialises the result as an XDR response. Unlike a normal filesystem, knfsd never holds long-lived kernel references to dentries across RPC calls — instead, it encodes a **file handle** (opaque byte string) at `lookup` time and decodes it on every subsequent request to find the file again.

## How It Works

### Thread pool and request dispatch

The nfsd service is started by userspace writing the desired thread count to `/proc/fs/nfsd/threads`. The kernel creates `nfsd_last_thread()` → `nfsd()` kernel threads, each associated with a `svc_rqst` (request context). Threads block in `svc_recv()` waiting for a request on any listened socket (UDP, TCP, or RDMA via xprtrdma).

```c
struct svc_rqst {
    struct svc_serv     *rq_server;   /* the owning svc_serv */
    struct svc_pool     *rq_pool;     /* pool this thread belongs to */
    struct svc_procedure *rq_procinfo; /* procedure being handled */
    struct xdr_buf      rq_arg;       /* incoming XDR buffer */
    struct xdr_buf      rq_res;       /* outgoing XDR buffer */
    struct auth_domain  *rq_client;   /* authenticated client */
    struct svc_export   *rq_exp;      /* matched export */
    ...
};
```

When a packet arrives, `svc_process()` decodes the RPC header (program number, version, procedure), looks up the procedure in the registered `svc_program` table (`nfsd_program` for NFS, `nfsacl_program` for ACLs), calls the XDR decode function for the request, then dispatches to the procedure handler (`nfsd_proc_*` for v2/v3, `nfsd4_proc_compound` for v4).

### Exports and the export table

Before serving any file, knfsd must verify the requested path is within an exported subtree with the right permissions for the requesting client. Exports are maintained by userspace (`exportfs(8)`) writing to `/proc/fs/nfsd/exports` (or via the `MOUNTD_REEXPORT` ioctl). The kernel stores them in an `svc_export` struct keyed by `(auth_domain, dentry+mnt)`.

A client that presents a file handle for a path not under any export, or for a path whose export does not permit access from that client's IP/auth domain, receives `NFS3ERR_ACCES` or `NFS3ERR_STALE`.

### File handles

NFS clients address files with **file handles** — opaque blobs that the server must be able to resolve back to an inode at any time, including after a server restart. Knfsd's file handle format is:

```
struct knfsd_fh {
    u32       fh_size;
    union {
        struct fid   fh_base;   /* filesystem-provided file ID */
        /* legacy v2 format: dev+ino+generation */
    };
};
```

The critical piece is the `fid` (file identifier), which is filesystem-specific: ext4 encodes inode number + generation; btrfs encodes inode + subvolume root ID; XFS encodes inode number + generation. The generation number is essential for detecting inode reuse — after a file is deleted and a new inode is allocated the same number, the old file handle's generation won't match and the client gets `NFS3ERR_STALE`.

To produce a file handle, knfsd calls `export_operations.encode_fh(dentry, fh_buf, max_len, parent_dentry)`. To resolve a file handle back to a dentry, it calls `export_operations.fh_to_dentry(sb, fid, fh_len, fileid_type)`. For path reconstruction (needed by some NFSv4 operations), it calls `export_operations.get_parent(dentry)` walking up to the export root.

A filesystem must set `sb->s_export_op` to an `export_operations` struct to be NFS-exportable. Most in-kernel filesystems do this. FUSE filesystems require the daemon to also implement `encode_fh`/`fh_to_dentry`.

### I/O caching — `nfsd_file`

Rather than opening a new file descriptor for every RPC read or write, knfsd maintains a **per-inode file cache** (`nfsd_file`) in a hash table. An `nfsd_file` holds an open `struct file` for a given (inode, flags) combination, reference-counted across concurrent RPC threads. This avoids repeated `dentry_open()` calls and keeps the file's `struct file` (and thus the address space's page cache) warm between requests.

For writes, knfsd calls `vfs_write()` / `nfsd_write()` which goes through the page cache and writeback machinery of the exported filesystem. For `COMMIT` RPCs (NFSv3) or `LAYOUTCOMMIT` (pNFS), knfsd calls `vfs_fsync_range()` to flush the server's page cache to stable storage.

### NFSv4 state management

NFSv4 introduced client-tracked state: the server assigns each client a **clientid** (via `SETCLIENTID` / `EXCHANGE_ID`), then tracks **open-owners** (per-process open state), **lock-owners**, and **delegations** per clientid. All this state has a **lease** — if the client doesn't renew within `fs.nfsd.nfsv4leasetime` seconds, the server reclaims the state.

State is stored in:
- `nfs4_client` — one per clientid; holds open owners and lock owners
- `nfs4_openowner` / `nfs4_lockowner` — one per {clientid, owner string} pair
- `nfs4_ol_stateid` — one per open/lock state; holds the stateid
- `nfs4_delegation` — issued when a client can safely cache a file

Delegations are revoked via `CB_RECALL` callbacks sent from the server to the client (using the client's reverse channel in NFSv4.1 sessions). `CB_RECALL` is sent when another client wants to open the delegated file in a conflicting mode.

### The nfsd pseudo-filesystem

`/proc/fs/nfsd/` exposes knfsd control and state:
- `threads` — read/write thread count
- `exports` — currently active exports
- `clients/` (Linux 4.x+) — one directory per NFSv4 clientid; shows open files, lock state, delegations
- `versions` — enabled NFS versions

## Key Data Structures

**`svc_serv`** (`include/linux/sunrpc/svc.h`) — one per NFS service instance (also shared between mounts in containers); holds thread pool, programme registration, socket list.

**`svc_rqst`** (`include/linux/sunrpc/svc.h`) — per-thread request context; holds XDR buffers, authenticated client, matched export.

**`svc_export`** (`include/linux/nfsd/export.h`) — one per exported path per auth domain; holds path, export flags (`NFSEXP_READONLY`, `NFSEXP_ROOTSQUASH`, etc.), and `export_operations` pointer.

**`nfsd_file`** (`fs/nfsd/filecache.h`) — cached open file for a given inode; avoids repeated `dentry_open()` per RPC.

**`nfs4_client`** (`fs/nfsd/state.h`) — one per NFSv4 clientid; holds lease expiry, open owners, and delegations.

**`export_operations`** (`include/linux/exportfs.h`) — filesystem-provided interface; required for NFS export.
- `encode_fh` — encode inode identity into a portable file handle fragment
- `fh_to_dentry` — decode a file handle fragment back to a dentry
- `get_parent` — walk up to parent dentry (used for NFSv4 path reconstruction)
- `flags` — e.g. `EXPORT_OP_STABLE_HANDLES` if handles are stable across reboots

## Key Functions / Entry Points

**`nfsd()`** (`fs/nfsd/nfssvc.c`) — main loop for each nfsd kernel thread; calls `svc_recv()` + `svc_process()`.

**`nfsd_dispatch()`** (`fs/nfsd/nfssvc.c`) — decodes request, calls the procedure handler, encodes response.

**`nfsd4_proc_compound()`** (`fs/nfsd/nfs4proc.c`) — handles NFSv4 COMPOUND RPCs; iterates operations in the compound and dispatches each.

**`fh_verify()`** (`fs/nfsd/nfsfh.c`) — decodes and validates a file handle; verifies the inode is within an exported subtree and the client has access.

**`nfsd_file_acquire()`** (`fs/nfsd/filecache.c`) — acquires (or creates) a cached `nfsd_file` for an inode.

**`nfsd4_setclientid()` / `nfsd4_exchange_id()`** (`fs/nfsd/nfs4proc.c`) — client ID negotiation at NFSv4 / NFSv4.1 session setup.

## Important Flags & Config Options

| Flag / Option | Effect |
|---|---|
| `/proc/fs/nfsd/threads` | Number of nfsd kernel threads |
| `fs.nfsd.nfsv4leasetime` | NFSv4 lease duration (seconds); shorter = faster recovery, more renewal traffic |
| `NFSEXP_READONLY` | Export is read-only |
| `NFSEXP_ROOTSQUASH` | Map root UID to `nobody` |
| `NFSEXP_ALLSQUASH` | Map all UIDs to `nobody` |
| `NFSEXP_SUBTREECHECK` | Verify every request is within the exported subtree (expensive; avoid for large trees) |
| `EXPORT_OP_STABLE_HANDLES` | Filesystem guarantees file handles survive across reboots |

## Interactions with Other Subsystems

- **↑ Userspace**: `nfsd(8)`, `exportfs(8)`, `mountd(8)` configure the service via `/proc/fs/nfsd/`; `nfsstat(8)` reads statistics.
- **→ [[sunrpc]]**: knfsd is a consumer of the sunrpc service layer (`svc_create`, `svc_recv`, `svc_process`); sunrpc handles socket management, AUTH_SYS and Kerberos authentication, and RPC retransmission detection.
- **→ [[xdr-encoding]]**: each NFS procedure has XDR codec functions for request decode and response encode; defined in `fs/nfsd/nfsxdr.c` (v2/v3) and `fs/nfsd/nfs4xdr.c` (v4).
- **→ VFS**: every NFS operation eventually calls a VFS function: `vfs_getattr`, `vfs_open`, `vfs_read`, `vfs_write`, `vfs_create`, `vfs_mkdir`, `vfs_rename`, etc.
- **→ [[nfs-localio]]**: allows kernel-to-kernel NFS I/O bypass for loopback mounts (Linux 6.x+).
- **← NFS client**: the client sends RPCs; the server sends NFSv4 callbacks to the client's reverse channel.

## Design Decisions & Tradeoffs

**Kernel-space server vs. user-space**: The original Linux NFS server was user-space (`unfsd`). Moving to kernel space eliminated context switches per request and allowed direct VFS calls, dramatically increasing throughput. The tradeoff is that bugs in knfsd can panic the kernel, and the nfsd code is complex (handling NFSv2/v3/v4/v4.1/v4.2 in one codebase).

**File handles via `export_operations`**: Rather than defining a fixed knfsd-internal inode encoding, knfsd delegates handle encoding to each filesystem. This lets ZFS, Btrfs, ext4, and XFS use whatever encoding best matches their inode structure. The cost is that every exportable filesystem must implement `export_operations` and ensure `generation` numbers are durable.

**`nfsd_file` cache**: Opening a kernel file object (`struct file`) has non-trivial cost (dentry reference, permissions check, f_op setup). Caching it across requests amortises this cost for busy files. The cache must be invalidated on `unlink` or `rename`, and must not hold files open longer than necessary to avoid blocking `umount`.

**Subtree checking**: NFS file handles are opaque; a client could present a handle from outside an exported subtree. `NFSEXP_SUBTREECHECK` (historically the default) causes every operation to walk the dentry tree upward to verify the file is within the export root. This is expensive and is now opt-in; instead, most modern exports rely on the generation number check to detect stale handles.

## How It Has Evolved

- **2.2 (1999)**: knfsd (kernel NFS server) merged, replacing user-space `unfsd`.
- **2.6.0 (2003)**: NFSv4 server merged.
- **2.6.38 (2011)**: NFSv4.1 server merged; sessions, pNFS support.
- **3.11 (2013)**: NFSv4.2 server support (server-side copy, space reservation).
- **5.3 (2019)**: `nfsd_file` per-inode file cache introduced to reduce open overhead.
- **6.x**: NFSv4 signed file handles for security; NFS LOCALIO for loopback bypass.

## Further Reading

1. **Kernel docs — Making Filesystems Exportable**: https://docs.kernel.org/filesystems/nfs/exporting.html
2. **nfsd(7)**: https://man7.org/linux/man-pages/man7/nfsd.7.html
3. **LWN — "exposing knfsd state to userspace"** (2019): https://lwn.net/Articles/788686/
