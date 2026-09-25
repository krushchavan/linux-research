---
title: "NFS — Explained"
category: explained
original: "[[nfs]]"
subsystem: nfs
tags: [explained, nfs, sunrpc, pnfs, network-filesystems]
converted: 2026-09-25
---

# NFS (Network File System), explained

> Plain-language companion to [[nfs|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Programs want to use files on another machine with the same `open`, `read`, `write` and `stat` calls they use on a local disk, with no idea there's a network involved. But the network is slow compared with a disk and can drop or repeat messages, the server can crash and restart, and other clients may be changing the same files. Caching makes things fast but risks showing stale data; not caching is correct but slow.

Linux contains both halves: an NFS **client** that makes remote files look local, and an NFS **server** that exports local filesystems, both built on a shared remote-procedure-call layer.

## The big picture

NFS is **file operations turned into network packets**. The client is a plug-in to the kernel's file layer (the VFS), just like ext4 or btrfs, except that instead of block I/O it encodes each operation as a remote procedure call. **SUNRPC** is the courier: it manages connections, limits how many calls are outstanding, retries, and authenticates. On the other side, the server's kernel threads (`nfsd`) receive the calls, run them against a local filesystem and send back results.

```text
  CLIENT                                        SERVER
  program: open / read / write / stat
     │
   VFS
     │
  NFS client ── cache hit? ─▶ page cache / dentry cache
     │ miss
  SUNRPC client (slots, auth, retries)          SUNRPC server
     │                                              │
  TCP / RDMA / TLS ─────────── network ──────────▶ nfsd threads
                                                    │
                                          exported fs (ext4, XFS, btrfs)
```

## The pieces

### SUNRPC: the transport
SUNRPC is a general RPC layer. To make a call, the NFS client fills in a message (which procedure, how to encode and decode, which credentials) and submits it. SUNRPC turns it into a task that steps through a state machine: encode, pick a connection, wait for a **slot**, send, wait for the reply, decode, finish.

**Slot tables** are the main back-pressure. Each connection allows a fixed number of outstanding calls (default 16, up to 128 for TCP); when all slots are busy, new calls wait. That stops a client from swamping a slow server, and also caps throughput. A client can hold several connections and spread calls across them.

Three kinds of authentication:
- **AUTH_SYS:** plain user and group IDs in each call. No cryptography, easy to spoof.
- **RPCSEC_GSS:** Kerberos-based signing and optional encryption of each call; user space sets up the security context, the kernel does the per-packet crypto.
- **RPC-with-TLS:** the connection is encrypted with TLS at setup, selected with a mount option (5.15+).

See [[sunrpc-explained|SUNRPC]] and [[rpcsec-gss-and-kerberos-explained|RPCSEC_GSS and Kerberos]].

### XDR and compound calls
Arguments and results are packed in **XDR**, a portable binary format, so NFS works between different CPU architectures. Each procedure has an encoder and decoder working on a stream over a buffer chain.

NFSv4 bundles several operations into one **compound** call, processed left to right and stopping at the first error. An `open` that took three round trips in NFSv3 (lookup, access, open) becomes one. See [[xdr-encoding|XDR encoding]].

### NFSv4.1 sessions
Sessions give each client a negotiated table of slots, each with a sequence number that goes up by one per call. From the number, the server can spot a retransmitted call and replay its saved answer instead of running it twice. That's essential for operations like rename or remove, which aren't safe to repeat. The same connection also carries a **back channel** for server-to-client callbacks (recalls, notifications). The server can grow or shrink the slot table on the fly, depending on its memory. See [[nfsv4.1-sessions-explained|NFSv4.1 sessions]].

### The client
Mounting creates a per-server record (connection, capabilities, read/write sizes) and a longer-lived client identity shared by all mounts of that server, then fetches the root.
- **Reads** go through the page cache: a miss sends a read call, and the page is reused afterwards.
- **Writes** dirty pages in the page cache. Writeback later batches them into write calls, then sends a **commit** so the server flushes its own buffers to stable storage.
- **Attributes** are cached and checked for freshness against the server's change counter (NFSv4) or modification and change times (NFSv3).

This is the key rule. NFS promises **close-to-open consistency**: on `open`, the client always revalidates its cache, so it sees everything written by others before they closed; on `close`, it flushes its dirty pages. It's weaker than fully coherent caching (as in AFS), but avoids constant invalidation traffic.

With NFSv4 **delegations**, the server can promise a client that nobody else has the file open in a conflicting way. With a read delegation the client can cache reads without revalidating; with a write delegation it can gather writes and commit at close. The server recalls a delegation when a conflicting open arrives. See [[nfs-client-explained|NFS client]] and [[delegations-and-locking-explained|delegations and locking]].

### pNFS: parallel data paths
pNFS (NFSv4.1+) splits **metadata**, still handled by the main server, from **data**, which the client can read and write directly on storage devices or secondary servers. On open, the client asks for a **layout** describing where the file's data lives: which devices, which stripes, which protocol. Later reads and writes go straight there. Layout types include files and flexfiles (secondary NFS servers), blocks (SAN devices) and objects. The server can recall a layout over the back channel; the client must drain in-flight I/O and return it first. Most deployments skip pNFS because its complexity only pays off at very large scale. See [[pnfs-explained|pNFS]].

### LOCALIO
When client and server run in the **same kernel** (for example, containers on one host), LOCALIO skips the network for reads, writes and commits. To prove they're co-located (IP addresses aren't enough, since containers can have overlapping ones), the client puts a random UUID in shared kernel memory and asks the server whether it can see it. If so, I/O goes straight into the server's local path, with no encoding, sockets or RPC. In testing, 4 KB reads went from about 79K to about 979K operations per second, roughly 12×. It's limited to AUTH_SYS and respects export options such as root squashing. See [[nfs-localio-explained|LOCALIO]].

### The server
`nfsd` runs as a pool of kernel threads. Each takes an incoming call, dispatches it to the right version's handler, and performs it with ordinary VFS operations on the exported path. An export table says which clients may access what, with which options. Files are identified by **file handles**, opaque strings encoding the filesystem and inode, which each exportable filesystem knows how to produce and decode.

NFSv4 servers keep **state**: who has which files open, byte-range locks and delegations. After a restart, the server gives clients a **grace period** (90 seconds by default) to reclaim their state. See [[nfs-server-explained|NFS server]].

## A request's journey

Opening and reading `/mnt/nfs/file.txt` with NFSv4:

1. **Open.** The program calls `open`; the dentry cache misses, so the client sends an OPEN call for "file.txt".
2. **Server opens.** `nfsd` looks the name up on its local filesystem, records open state, and replies with the file handle, a state ID, the change counter and, here, a read delegation.
3. **Client caches.** The client creates its inode, stores the handle, attributes and delegation, and the program gets a file descriptor.
4. **Read.** The program reads 64 KB; the page cache misses, so the client sends a READ call with the handle, offset and count.
5. **Server reads.** `nfsd` reads from its local ext4 and returns 64 KB.
6. **Pages filled.** The data lands in the client's page cache and is returned. Thanks to the delegation, later reads can come from cache without revalidation.

If the server reboots, the client notices (a sequence break or a stale-client error), re-registers, re-opens its files and reclaims locks and delegations during the grace period; anything not reclaimed is discarded.

## Tradeoffs

- **What it gives you:** transparent remote files, strong authentication and encryption options, batching of operations, safe retries via sessions, and optional parallel data paths.
- **What it costs / requires:** stateful NFSv4 needs a complex recovery protocol and the visible grace period after restarts; slot tables cap throughput unless raised; pNFS adds layouts, device lookups and a separate recovery path.
- **Where it bites:** cached attributes can be stale for up to 60 seconds, and close-to-open consistency means two clients writing the same file at once without their own coordination is unsafe.

## How it got here

- **NFSv2 (Linux 1.x):** UDP only. **NFSv3 (late 1990s):** bigger transfers, better errors, still stateless; client and server stabilised in 2.4, with `nfsd` in kernel threads.
- **NFSv4 (2003):** stateful, compound calls, mandatory Kerberos support, byte-range locks; Linux client in 2.6.0.
- **NFSv4.1 (2010):** sessions, multiple connections, pNFS; Linux support in 2.6.37.
- **NFSv4.2 (2016):** sparse files, server-side copy; Linux support in 4.9. **5.3:** re-exporting NFS mounts over NFS.
- **5.15:** RPC-with-TLS (Chuck Lever). Later: LOCALIO, and copy-offload and RDMA hardening around 6.7.
- **In progress:** NFS over QUIC, LOCALIO for more operation types, multipath TCP, and a queued transmission model in SUNRPC for fairness across mounts.

## Related

- Technical version: [[nfs]]
- [[sunrpc-explained|SUNRPC]], [[xdr-encoding|XDR]], [[nfsv4.1-sessions-explained|Sessions]], [[nfs-client-explained|Client]], [[nfs-server-explained|Server]], [[pnfs-explained|pNFS]], [[nfs-localio-explained|LOCALIO]], [[delegations-and-locking-explained|Delegations and locking]], [[rpcsec-gss-and-kerberos-explained|RPCSEC_GSS]]
- [[network-filesystems-overview-explained|Network filesystems overview]], [[fs-explained|Filesystem subsystem (VFS)]], [[page-cache-explained|Page cache]], [[btrfs-explained|btrfs]]
