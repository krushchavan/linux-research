---
title: "Network Filesystems Overview — Explained"
category: explained
original: "[[network-filesystems-overview]]"
subsystem: fs
tags: [explained, fs, nfs, cifs, ceph, netfs]
converted: 2026-09-25
---

# Network filesystems, explained

> Plain-language companion to [[network-filesystems-overview|the technical note]]. Same facts, fewer identifiers.

## The problem

Programs should be able to use files on a remote server with the same `read`, `write`, `stat` and `mmap` calls they use on a local disk. But a network is slow compared with a disk, it can fail partway through, other machines may be changing the same files, and each remote protocol (NFS, SMB, AFS, Ceph, 9P) has its own quirks.

Every network filesystem faces the same structural chores: split big requests into network-sized pieces, stitch the replies back together, optionally keep a local copy on disk, retry on transient failures, and decide how long cached data can be trusted. For years each filesystem did all of this separately.

## The big picture

Think of three tiers between the remote server and a program's file descriptor:
1. **Protocol drivers** (NFS, SMB/CIFS, AFS, Ceph, 9P) turn file operations into network calls and track server state such as leases and delegations.
2. **Shared infrastructure**: the **netfs** library (since 5.13) handles the common buffered-I/O mechanics, and **fscache** keeps optional local copies on disk.
3. **VFS and the page cache**, exactly as for local filesystems, so memory management sees no difference.

```text
 program: read / write / mmap / stat
              │
       VFS + page cache (same as local disks)
              │ miss / writeback
       netfs library: split into sub-requests, retries, folio handling
          │                          │
   fscache → CacheFiles         protocol driver: "issue this read/write"
   (local disk copy)              NFS · SMB · AFS · Ceph · 9P
                                     │
                                  network ──▶ server(s)
```

## The pieces

### Metadata and trust
Mounting works as for any filesystem. The difference is that inodes mirror remote state, so each time attributes are needed the filesystem must decide if its copy is still valid: via a lease or delegation from the server, a fresh attribute request, or a version counter such as NFSv4's change attribute. Looking up a name either uses a cached answer or asks the server.

### Reading through netfs
On a page-cache miss, a netfs-based filesystem hands the request to the library. It creates a request, asks fscache whether a local copy exists, and either reads from the local cache or calls the filesystem's one required hook: **issue this read** as a network call (for example AFS's fetch-data call over its RxRPC protocol, or Ceph's object reads). Everything else (pinning pages, cutting the request into server-sized pieces, unlocking pieces as they complete, falling back from a stale cache to the network) is done once, in the library.

### fscache: local caching
fscache maps a network file, identified by a volume key (for example an NFS server and export) plus a per-file key, to a local file managed by the CacheFiles backend, and reads it back with direct I/O. The 5.17 rewrite (David Howells) replaced a complex operation scheduler with a two-level model: one cookie per volume, one per file, each reference-counted and retired after a timeout when unused. It also removed pointers from fscache back into the filesystems, which had caused lifetime bugs.

### Writing
Writes go into the page cache. At writeback, netfs builds **two independent streams** from the dirty pages: one to the server, one to the local cache, running in parallel with their own piece sizes. A big sequential write uploads to the server and fills the cache in one pass.

## The filesystems

- **NFS** (client and server in the kernel): v3 is mostly stateless; v4 added leases, **delegations** (the client can cache opens and locks without asking the server each time) and compound calls batching several operations; v4.1 added sessions for exactly-once behaviour and parallel NFS across servers; v4.2 added server-side copy and sparse files. Authentication can be plain Unix IDs, Kerberos, or TLS. When the server recalls a delegation because another client changed the file, the client flushes its cached copy first. NFS still uses its own I/O engine, with wrappers for fscache; moving it to netfs is still being discussed.
- **SMB/CIFS** (for Windows servers and Samba): SMB3 is the default and brings encryption, multiple connections per session, directory leases, and **SMB Direct** over RDMA (production-ready for client and server in 5.15), which bypasses TCP for near-zero-copy transfers. It has been moving onto netfs since 6.7.
- **AFS** (kAFS): storage is organised into **cells** and **volumes**, found through DNS or configuration, over the RxRPC protocol with Kerberos-based security. Servers promise **callbacks**, "I'll tell you if someone changes this file", so the client needn't recheck while the promise holds. Special mount-point entries are followed by automatically mounting the referenced volume. A full netfs user.
- **Ceph**: built for huge scale. A cluster of metadata servers divides the namespace dynamically, and file data is striped across object storage daemons. A placement algorithm (CRUSH) computes where objects live without asking a central server. Per-inode **capabilities** grant a client read, write or cache rights, revoked when the servers need to give conflicting access to someone else. Uses netfs for reads.
- **9P (v9fs)**: deliberately minimal and stateless: no leases, no callbacks, every operation goes to the server. That simplicity makes it great for sharing host directories with virtual machines over virtio (WSL 2 does this). With no coherency protocol, it assumes one writer or accepts races.
- **FUSE**: not a network filesystem itself, but the way many are built in user space (SSHFS, rclone, cloud-storage mounts).

## A request's journey

A buffered read of an uncached file on a Ceph mount with local caching:

1. **Program calls `read`.** VFS checks the page cache: miss.
2. **Hand to netfs.** Ceph's read hook passes the request to the netfs library.
3. **Ask the cache.** netfs asks fscache if this range is stored locally. It isn't.
4. **Split and issue.** netfs cuts the request into server-sized pieces and asks Ceph to issue each as an object read to the right storage daemon.
5. **Complete in pieces.** As replies arrive, pages are filled and unlocked; the program's data is copied out.
6. **Fill the cache.** The data is also written to the local CacheFiles store, so next time step 3 is a hit.

## Tradeoffs

- **What it gives you:** remote files with local-file semantics, shared caching, and (since netfs) one tested implementation of the common I/O plumbing: about 8,000 lines of duplicated code removed by 6.5.
- **What it costs / requires:** stateful protocols (NFSv4, AFS, Ceph) enable delegations and capabilities but force clients to reclaim state within a grace period after a server restarts; stateless ones (NFSv3, 9P) recover simply but can't cache as aggressively. In-kernel servers (nfsd, and ksmbd for SMB3 since 5.15) avoid context switches but are harder to evolve than user-space ones like Samba.
- **Where it bites:** every design must choose how long to trust cached data. Aggressive caching is fast but risks stale reads under concurrent changes, a fundamental tension in distributed filesystems.

## How it got here

- **2.6.x:** NFS, CIFS, AFS, Ceph and 9P each with their own infrastructure; fscache existed but was complex and little used.
- **5.13 (2021):** the netfs library, starting from AFS's read code (David Howells).
- **5.17 (2022):** the fscache and CacheFiles rewrite; NFS hooked into fscache through wrappers.
- **5.19–6.5 (2022–2023):** Ceph, 9P and AFS fully on netfs.
- **6.7–6.13 (2024–2025):** SMB moves onto netfs; the two-stream writeback stabilises (6.9); a single completion collector fixes sequential read performance.
- **2026 (in progress):** a new buffer design for netfs, and discussion of moving NFS onto it.

## Related

- Technical version: [[network-filesystems-overview]]
- [[netfs-explained|netfs]], [[netfs-helper-library-explained|netfs-helper-library]], [[fscache-explained|fscache]], [[cachefiles-backend-explained|cachefiles-backend]]
- [[nfs-explained|nfs]], [[nfs-client-explained|nfs-client]], [[nfs-server-explained|nfs-server]], [[fuse-explained|fuse]]
- [[fs-explained|Filesystem subsystem (VFS)]], [[page-cache-explained|Page cache]], [[mm-explained|Memory management]]
- [[sunrpc]], [[security]]
