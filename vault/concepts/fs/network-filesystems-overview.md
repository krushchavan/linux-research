---
title: "Network Filesystems Overview"
category: concept
tags: [network-filesystem, nfs, cifs, ceph, afs, netfs, fscache]
subsystem: fs
kernel_version: 5.13
researched: 2026-04-17
status: complete
explained: "[[network-filesystems-overview-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html
  - https://www.kernel.org/doc/html/latest/filesystems/caching/fscache.html
  - https://www.kernel.org/doc/html/latest/filesystems/ceph.html
  - https://docs.kernel.org/filesystems/afs.html
  - https://www.kernel.org/doc/html/latest/filesystems/9p.html
  - https://lwn.net/Articles/894589/
  - https://lwn.net/Articles/877058/
  - https://lwn.net/Articles/955944/
---

# Network Filesystems Overview

> 📘 Plain-language version: [[network-filesystems-overview-explained]]

## Purpose

Network filesystems let Linux processes access files stored on remote servers using the same `read()`, `write()`, `stat()`, and `mmap()` syscalls they use on local disks. Without them, distributed workloads would require application-level networking code for every file operation. The kernel's job is to make the remote storage transparent to POSIX applications while hiding latency, partial failures, and protocol-specific quirks behind the VFS abstraction.

## Mental Model

Think of the Linux network filesystem stack as three tiers layered between the remote server and an application's file descriptor:

1. **Protocol drivers** (NFS, CIFS, AFS, Ceph, 9P) — translate VFS operations into wire RPCs and manage server state such as leases, delegations, and sessions.
2. **Shared infrastructure** ([[netfs]] library, [[fscache]] cache layer) — provides common buffered-I/O mechanics, local disk caching, retry logic, and folio lifecycle management so protocol drivers only need to implement the RPC boundary.
3. **VFS / page cache** — the same machinery used by local filesystems; network filesystems plug in via `file_operations` and `address_space_operations`, so the MM subsystem sees no difference.

The unifying insight is that all network filesystems face the same structural problems: splitting a large VM request into RPC-sized chunks, stitching results back together, optionally caching data locally, and retrying on transient failure. The [[netfs]] library (introduced in 5.13) exists precisely to solve these problems once rather than N times.

## How It Works

### VFS entry and inode lifecycle

A network filesystem mounts just like any other filesystem: `mount()` creates a `struct super_block`, allocates root inodes, and registers `super_operations`, `inode_operations`, and `file_operations`. The difference from a local filesystem is that inodes are backed by remote state. Every time the VFS wants inode attributes, the filesystem must decide whether cached values are still valid — either by checking a lease/delegation granted by the server, by issuing a `GETATTR` RPC, or by checking a version counter such as NFSv4's `change` attribute.

When an application calls `open()`, the path-lookup machinery (`namei.c`) calls through `inode_operations.lookup()`. For network filesystems, `lookup()` either returns a cached dentry if it already knows the server's answer, or sends a `LOOKUP` RPC (NFS), `NtCreateFile` (CIFS), or `FetchStatus` (AFS) to discover whether the name exists and to fetch initial attributes.

### Buffered reads and the page cache

When an application calls `read()`, the VFS calls `filemap_read()`, which checks whether the requested folios are in the page cache. On a cache miss, `read_folio()` is called on the address space. For a filesystem using the [[netfs]] library, `netfs_read_folio()` handles this: it allocates a `netfs_io_request`, asks the fscache layer whether a local copy exists, and either reads from local cache (a `READ_FROM_CACHE` subrequest) or dispatches the filesystem's `issue_read()` callback to fire an RPC.

The `issue_read()` callback is the only part the protocol driver must write. For NFS, this becomes an `nfs_netfs_issue_read()` wrapper that feeds into the existing `nfs_pageio_descriptor` machinery. For AFS, it becomes an `afs_issue_read()` call that queues an `FS.FetchData64` RPC over RxRPC. The netfs library handles everything above: folio pinning, subrequest tiling at RPC-size boundaries, partial completion unlocking, and automatic fallback from a stale cache entry to a network fetch.

### Local caching with fscache

[[fscache]] sits between the netfs library and a cache backend (CacheFiles). Its purpose is to map a network file — identified by a volume cookie (e.g., `nfs,10.0.0.1:/export`) and a data cookie (inode number + generation) — to a local file on disk managed by CacheFiles. When netfs asks whether a folio range is cached, fscache checks its cookie state and dispatches to CacheFiles, which performs a direct I/O read from the backing tmpfile.

The fscache rewrite (v5.17, David Howells) eliminated the old operation-scheduling state machine in favour of a two-level cookie model: a `struct fscache_volume` per superblock, and a `struct fscache_cookie` per inode. Cookies are reference-counted; when no file holds a cookie open, the cookie is retired after a timeout, freeing the CacheFiles backing store. This design removed all back-pointers from fscache into the network filesystem, so fscache does not need to hold network filesystem data structures alive.

### Write path

Writes land in the page cache via `write_iter()`. The netfs library's `netfs_file_write_iter()` handles dirty-folio accounting and marks folios with `NETFS_FOLIO_COPY_TO_CACHE` when a local cache is active. At writeback time, `netfs_writepages()` walks dirty folios and builds two independent I/O streams: stream 0 targets the remote server (via `issue_write()` callbacks), stream 1 targets the local cache directly. The two streams run in parallel with independent subrequest boundaries, so a large sequential write completes both server upload and cache population in a single writeback pass.

---

## The Network Filesystems

### NFS (Network File System)

NFS is the most widely deployed network filesystem on Linux. The kernel ships both a client (`fs/nfs/`) and a server (`fs/nfsd/`). NFSv3 uses stateless UDP/TCP RPC; NFSv4 introduced a stateful connection with leases, delegations (allowing client-side caching of file opens and locks without per-operation server round-trips), and Compound RPCs that batch multiple operations. NFSv4.1 added sessions for exactly-once semantics and pNFS (parallel NFS) for striped access across multiple servers. NFSv4.2 added server-side copy and sparse file support.

The NFS client uses the SunRPC layer (`net/sunrpc/`) for transport. Authentication is pluggable: AUTH_UNIX (UID/GID in the wire header), RPCSEC_GSS (Kerberos-5 tickets via `rpc.gssd`), and AUTH_TLS. The client manages state via `struct nfs_client` (one per server address) and `struct nfs_server` (one per export). Delegations are tracked in `struct nfs_delegation`; when a delegation is recalled by the server (because another client modified the file), the client flushes its page-cache copy and returns the delegation before proceeding.

NFS does not yet use the [[netfs]] library for its I/O engine; it retains its own `nfs_pageio_descriptor` and `nfs_pgio_header` infrastructure. Integration has been discussed at LSFMM but remains a future project.

### CIFS / SMB

The `cifs.ko` driver (`fs/smb/client/`) implements the SMB1 (CIFS), SMB2, and SMB3 protocols used by Windows file servers and Samba. SMB3 is the current default and is required for features like RDMA (SMB Direct), encryption, multichannel (multiple TCP connections per session), and directory leases.

The client connects to a server via `struct TCP_Server_Info` (one per address), multiplexes sessions as `struct cifs_ses`, and mounts shares as `struct cifs_tcon`. Requests are packaged as `struct smb_rqst` — scatter-gather lists of `kvec` and `iov_iter` — and dispatched through `SendReceive2()` over TCP or, with `CONFIG_CIFS_SMB_DIRECT`, over an RDMA queue pair.

SMB Direct (SMB3 over RDMA) adds a transport layer (`fs/smb/client/smbdirect.c`) that bypasses TCP, using RDMA reads and writes to achieve near-zero-copy transfers with sub-microsecond latencies. The first production-ready kernel release for both client- and server-side SMB Direct was v5.15.

CIFS has been progressively integrating with the [[netfs]] library since v6.7, allowing its read path to use the shared subrequest model and fscache integration.

### kAFS (Andrew File System)

kAFS (`fs/afs/`) is the in-kernel client for the AFS distributed filesystem originally developed at Carnegie Mellon. AFS organises storage into *cells* (administrative domains), each containing *volumes* (named namespaces). Clients discover server locations via DNS SRV records or explicit configuration in `/proc/fs/afs/cells`.

The transport layer uses the RxRPC protocol (`net/rxrpc/`) — a UDP-based connection-oriented protocol with per-call acknowledgement and retry. Security is handled via RXGK (a Kerberos-based mechanism) or the older kaserver. kAFS is a first-class netfs library consumer: its `afs_request_ops` callbacks implement `issue_read()` and `issue_write()` on top of AFS's `FS.FetchData64` and `FS.StoreData64` RPCs.

A key AFS concept is *delegations* for caching: a server grants a client a *callback* promise — "I will notify you if anyone else changes this file." While the callback is valid, the client need not revalidate the inode on every access. When another client modifies a file, the server sends a `CM.CallBack` message, invalidating the local cache. This is architecturally similar to NFSv4 delegations.

AFS mountpoints — volume root directories stored as specially formatted symlinks — are transparently followed by kAFS, which auto-mounts the referenced volume as a kernel mountpoint.

### Ceph

Ceph (`fs/ceph/`, shared library in `net/ceph/`) is a distributed filesystem designed for massive scalability. Unlike NFS and AFS, which have a single metadata server, Ceph uses a cluster of Metadata Servers (MDS) that partition the namespace dynamically. File data is striped across Object Storage Daemons (OSDs) in configurable-size chunks.

The kernel client communicates with two separate clusters: the MDS cluster for metadata operations (via `struct ceph_mds_client`), and the OSD cluster for data operations via RADOS (via `struct ceph_osd_client`). Both use the `libceph` library (`net/ceph/`) for messenger, authentication (cephx), and CRUSH map computation (which maps object names to OSD addresses without querying a central server). The messenger uses TCP connections; RDMA support has been proposed but not merged.

Ceph implements *capabilities* (a superset of AFS callbacks) per-inode per-client, granting selective read/write/cache authority. A client holding a `FILE_CACHE` capability may serve reads from its page cache without contacting the MDS. Capabilities are revoked when the MDS needs to grant conflicting access to another client.

CephFS uses the [[netfs]] library for its read path, with `ceph_netfs_issue_read()` dispatching OSD reads.

### 9P / v9fs

v9fs (`fs/9p/`) implements Plan 9's 9P2000.L file protocol. Unlike the other network filesystems, 9P is deliberately minimal: it has no server-side caching semantics, no leases, and no callbacks. The server is purely stateless from the client's perspective — every operation goes to the server.

This simplicity makes 9P an excellent virtualisation filesystem. Its `virtio` transport (`net/9p/trans_virtio.c`) exposes host directories to KVM guests as virtio devices, avoiding the overhead of TCP. WSL 2 and other hypervisors use 9P over virtio for host filesystem sharing. The `tcp`, `unix`, and `fd` transports are also available for traditional network use.

v9fs protocol versions:
- `9P2000` — original Plan 9 protocol
- `9P2000.u` — Unix extensions (UID/GID, symlinks, special files)
- `9P2000.L` — Linux extensions (POSIX ACLs, file locking, efficient readdir)

Because 9P has no cache coherency protocol, it relies on the client either being the sole writer (virtio use case) or accepting races (shared multi-client deployments). v9fs integrates with [[netfs]] for read path sharing and with [[fscache]] for optional local caching.

### FUSE (Filesystem in Userspace)

FUSE (`fs/fuse/`) allows filesystem implementations to run as userspace daemons, communicating with the kernel via a `/dev/fuse` file descriptor. While not a network filesystem itself, FUSE is the mechanism that powers many network filesystem clients (SSHFS, rclone's VFS, GCS FUSE, S3FS). The kernel side marshals VFS operation arguments into FUSE wire messages and blocks until the userspace daemon replies.

FUSE is documented in [[vault/subsystems/fuse|fuse]]; it is mentioned here because it completes the landscape — network filesystems that cannot or do not want to implement kernel drivers use FUSE as their integration point.

---

## Key Data Structures

**`struct netfs_inode`** (`include/linux/netfs.h`) — embedded in each network filesystem's inode wrapper; holds the `netfs_request_ops` table pointer, fscache cookie, server-side file size, and I/O policy flags.

**`struct fscache_cookie`** (`include/linux/fscache.h`) — represents a single cached object (file); maps to a CacheFiles backing tmpfile. Managed via `fscache_acquire_cookie()` / `fscache_relinquish_cookie()`.

**`struct fscache_volume`** (`include/linux/fscache.h`) — represents a cache volume (e.g., one NFS export or one AFS volume). Contains the printable string key distinguishing this volume from others.

**`struct nfs_client`** (`include/linux/nfs_fs_sb.h`) — one per server IP address; holds the RPC client, session state, and server capabilities.

**`struct ceph_mds_client`** (`fs/ceph/mds_client.h`) — manages all MDS sessions, cap tracking, and directory delegations for a mounted CephFS.

**`struct TCP_Server_Info`** (`fs/smb/client/cifsglob.h`) — one per CIFS/SMB server connection; multiplexes all sessions and tree-connects over a single TCP connection.

**`struct afs_server`** (`fs/afs/internal.h`) — tracks an AFS fileserver's address list, volume locations, and callback records.

---

## Key Functions / Entry Points

**`nfs_read_folio()`** (`fs/nfs/read.c`) — NFS `address_space_ops.read_folio`; builds an `nfs_pgio_header` and dispatches a `READ` RPC.

**`ceph_read_iter()`** (`fs/ceph/file.c`) — CephFS read dispatch; calls `netfs_read_folio()` which eventually calls `ceph_netfs_issue_read()` for OSD object reads.

**`afs_file_readpage()`** → `netfs_read_folio()` → `afs_issue_read()` (`fs/afs/file.c`) — issues `FS.FetchData64` over RxRPC.

**`cifs_read_iter()`** → `netfs_read_folio()` → `cifs_req_issue_read()` (`fs/smb/client/file.c`) — builds an SMB2 `READ` compound request.

**`v9fs_file_read_iter()`** (`fs/9p/vfs_file.c`) — issues a 9P `TREAD` message over the active transport.

**`fscache_begin_read_operation()`** (`include/linux/fscache.h`) — called by netfs before issuing subrequests; sets up the cache operation context for the request.

---

## Important Flags & Config Options

| Symbol | Effect |
|---|---|
| `CONFIG_NFS_FS` | NFS client; `CONFIG_NFS_V4` adds NFSv4, `CONFIG_NFS_V4_1` adds sessions and pNFS |
| `CONFIG_CIFS` | SMB/CIFS client; `CONFIG_CIFS_SMB_DIRECT` adds RDMA transport |
| `CONFIG_AFS_FS` | kAFS client; `CONFIG_RXRPC` required for the RxRPC transport |
| `CONFIG_CEPH_FS` | CephFS kernel client; requires `CONFIG_LIBCEPH` |
| `CONFIG_9P_FS` | v9fs; `CONFIG_9P_FS_POSIX_ACL` for POSIX ACL support |
| `CONFIG_FSCACHE` | Local cache layer; `CONFIG_CACHEFILES` for the CacheFiles backend |
| `CONFIG_NETFS_SUPPORT` | netfs library; automatically selected by any filesystem that uses it |
| `CONFIG_NFS_FSCACHE` | Enable fscache for NFS (client-side caching) |

Sysctl / mount options:
- `nfs`: `rsize=`, `wsize=` — RPC read/write size caps; `proto=rdma` for NFS over RDMA
- `cifs`: `vers=3.0`, `seal` (encryption), `multichannel`, `rdma` (SMB Direct)
- `ceph`: `readdir_max_entries=`, `rsize=`, `wsize=`
- `9p`: `trans=virtio`, `cache=loose|fscache|none`

---

## Interactions with Other Subsystems

- **↑ Userspace**: `read()`, `write()`, `mmap()`, `stat()`, `getdents()` — all land on VFS entry points that the network filesystem implements. Network filesystems must handle `O_DIRECT` (bypass page cache) and `O_SYNC` (flush to server before returning).
- **→ [[netfs]]**: AFS, Ceph, 9P, and CIFS delegate buffered I/O, readahead, writeback, and DIO to the netfs library. NFS retains its own I/O engine but wraps it with `nfs_netfs_*` shims to integrate with fscache.
- **→ [[fscache]]**: Network filesystems that enable local caching call `fscache_acquire_cookie()` at inode load time. The netfs library mediates all cache I/O via the fscache API.
- **→ [[mm]]**: The page cache (XArray of folios), `get_user_pages()` for DIO, writeback pressure via `struct writeback_control`, and memory-mapped I/O via `vm_operations_struct.fault` — network filesystems consume all of these.
- **→ net**: SunRPC (`net/sunrpc/`) for NFS, SMB2/TCP for CIFS, RxRPC (`net/rxrpc/`) for AFS, libceph messenger (`net/ceph/`) for Ceph, and various 9P transports all use the kernel's socket and network layer.
- **→ [[security]]**: `nfsd` enforces export permissions; NFSv4 ACLs and RPCSEC_GSS integrate with the kernel keyring and kerberos via `gssd`. CIFS uses SMB signing and SMB encryption for wire security. kAFS uses RXGK.
- **← [[vfs]]**: `super_operations`, `inode_operations`, `dentry_operations`, `file_operations`, and `address_space_operations` are the contracts network filesystems must implement.

---

## Design Decisions & Tradeoffs

**Per-filesystem I/O engines vs. shared netfs library**: Before netfs, each network filesystem implemented its own readahead, writeback, fscache integration, and DIO logic. AFS, Ceph, CIFS, and 9P each had roughly 1,000–3,000 lines of duplicated infrastructure that diverged over time. The netfs library trades implementation flexibility (each filesystem could tune every detail) for code reuse and correctness uniformity. NFS was not included because its existing infrastructure was too deeply intertwined with its own RPC layer to refactor without risk.

**Stateful vs. stateless protocols**: NFSv3 and 9P are largely stateless — every operation carries enough context for the server to execute it independently. This simplifies server recovery (clients just retry) but prevents server-side optimisations like delegation-based caching. NFSv4, AFS, and Ceph are stateful: the server tracks per-client state, enabling delegations and capabilities, but server recovery requires clients to reclaim state within a grace period.

**In-kernel vs. userspace servers**: Linux ships both an in-kernel NFS server (`nfsd`) and supports Samba (`smbd`) as a userspace SMB server. In-kernel servers avoid context switches for every I/O operation and can participate directly in VFS locks, but they are harder to evolve. ksmbd (merged in v5.15) is a new in-kernel SMB3 server that trades nfsd's maturity for simpler SMB3-only design.

**Cache coherency granularity**: NFS uses the `change` attribute (a server-side version counter) to detect modifications; AFS uses per-inode callbacks; Ceph uses per-inode capability revocation. All three must decide how long to trust cached data before revalidating. Aggressive caching improves performance but risks stale reads under concurrent modification — a fundamental tension in distributed filesystems.

---

## How It Has Evolved

- **v2.6.x**: NFS, CIFS, AFS, Ceph, and 9P existed as independent implementations with no shared infrastructure. fscache existed but was complex and underused.
- **v5.13 (2021)**: netfs library merged, absorbing AFS's read infrastructure. fscache rewrite began.
- **v5.17 (2022)**: fscache rewrite complete; simplified cookie model, CacheFiles rewritten. NFS integrates fscache via `nfs_netfs_*` wrappers.
- **v5.19 – v6.5 (2022–2023)**: Ceph, 9P, and AFS fully delegate I/O to netfs. Approximately 8,000 lines of duplicate code removed.
- **v6.7 (2024)**: CIFS begins netfs integration. ksmbd (in-kernel SMB3 server) reaches maturity.
- **v6.9 (2024)**: netfs writeback reworked; two-stream model stabilised for server + cache parallel writeback.
- **v6.13 (2025)**: Per-subrequest work items replaced by single collector; sequential read performance fixed for CIFS and AFS.
- **2026 (in-progress)**: `folio_queue` → `bvecq` buffer redesign; NFS netfs integration under discussion.

---

## Further Reading

1. [The netfslib helper library — LWN.net (2022)](https://lwn.net/Articles/894589/)
2. [fscache, cachefiles: Rewrite — LWN.net (2021)](https://lwn.net/Articles/877058/)
3. [netfs, afs, cifs: Delegate high-level I/O to netfslib — LWN.net (2023)](https://lwn.net/Articles/947758/)
4. [Network Filesystem Services Library — kernel.org docs](https://www.kernel.org/doc/html/latest/filesystems/netfs_library.html)
5. [Filesystem Caching — kernel.org docs](https://www.kernel.org/doc/html/latest/filesystems/caching/fscache.html)
6. [Ceph Distributed File System — kernel.org docs](https://www.kernel.org/doc/html/latest/filesystems/ceph.html)
7. [kAFS: AFS Filesystem — kernel.org docs](https://docs.kernel.org/filesystems/afs.html)
8. [v9fs: Plan 9 Resource Sharing for Linux — kernel.org docs](https://www.kernel.org/doc/html/latest/filesystems/9p.html)
9. [The Ceph filesystem — LWN.net (2007)](https://lwn.net/Articles/258516/)
10. [Network filesystem cache-management interfaces — LWN.net (2016)](https://lwn.net/Articles/718064/)

## LKML Highlights

- **netfs library initial merge** (David Howells, 2021, `lwn.net/Articles/894589/`): The patch series moving AFS's read infrastructure into a shared library. The discussion reveals the core design tension — whether to provide a generic VFS-level I/O library or leave each filesystem independent — and how the iov_iter abstraction was chosen to hide folio/bvec/page differences from filesystem drivers.
- **fscache/cachefiles rewrite** (David Howells, 2021, `lwn.net/Articles/877058/`): Elimination of the old operation-scheduling state machine. The thread shows why reverse pointers from fscache to network filesystem data structures caused lifecycle bugs and why the two-level volume/data cookie model resolved them.
- **CIFS netfs integration** (Shyam Prasad N / David Howells, 2024): Discussion around integrating CIFS with netfslib, specifically how CIFS's existing scatter-gather RPC model maps to the subrequest model and where the size-negotiation callback (`prepare_read()`) must truncate subrequests to the server's negotiated `MaxReadSize`.
