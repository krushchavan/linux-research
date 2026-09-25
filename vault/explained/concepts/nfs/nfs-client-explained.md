---
title: "NFS Client — Explained"
category: explained
original: "[[nfs-client]]"
subsystem: nfs
tags: [explained, nfs, caching, coherency, state-recovery]
converted: 2026-09-25
---

# The NFS client, explained

> Plain-language companion to [[nfs-client|the technical note]]. Same facts, fewer identifiers.

## The problem

The NFS client has to make files on a remote server behave like local ones, through the normal `open`, `read`, `write` and `stat` calls. Every trip to the server costs network latency, so the client wants to cache as much as it can. But other clients may be changing the same files, so a cache that's too eager shows stale data. On top of that, newer NFS versions keep state on the server (open files, locks, delegations) that the client must rebuild if the server reboots or the network drops.

## The idea in one paragraph

The client is a **caching proxy**. It turns file operations into remote procedure calls, keeps attributes and file data in the kernel's normal caches to avoid round trips, and decides when cached data can no longer be trusted: by timestamps in NFSv2/v3, and by the server's change counter and delegations in NFSv4. The newer the protocol version, the more state it tracks, and the more it has to recover after trouble.

## Step by step

### Step 1: Four layers of objects
- a **client** record per (server address, NFS version): the RPC connection, server capabilities and, for NFSv4, the client ID and lease. All mounts of that server share it.
- a **server** record per mounted export: its options (read and write sizes, attribute cache lifetimes) and the export's root file handle
- an **NFS inode** per file, wrapping the normal inode with the server's file ID and file handle, which cached attributes are valid, the change counter, and (NFSv4) the list of open states
- a **page request** per page waiting to be read or written, grouped into batches that each become one call

### Step 2: Caching attributes
Calling the server for every `stat` would be ruinous, so attributes (size, times, permissions) are cached for a window: by default 3 to 60 seconds for files and 30 to 60 seconds for directories. When an operation needs attributes past their window, the client sends a GETATTR and refreshes them.

NFSv4 adds a **change counter**, a 64-bit number the server bumps on every change. Comparing it catches modifications that timestamps miss, such as two writes within the same second, a classic NFS problem.

### Step 3: Reading and writing through the page cache
Reads and buffered writes use the normal page cache. Reads batch pages into READ calls. Writes dirty pages, and writeback later batches them into WRITE calls.

In NFSv3, writes can be **unstable** (the server holds them in memory: faster) or **file-sync** (written to disk: slower). After unstable writes the client must send a COMMIT to make the server flush them before a close or sync completes.

### Step 4: Close-to-open coherency
This is the key rule. On `close`, all dirty data is committed to the server's stable storage (COMMIT in NFSv3, implied by CLOSE in NFSv4). On `open`, the client revalidates. So once one client has closed a file, the next client to open it sees everything written. Between open and close, other clients may not see cached writes. That's weaker than POSIX, but it avoids a synchronous write on every call and suits most workloads.

### Step 5: NFSv4 open state and delegations
NFSv4 is stateful. An OPEN returns an **open state ID** that must accompany later reads, writes and locks for that file. With a **read delegation**, the client can cache aggressively without checking the server; with a **write delegation**, it has exclusive write access and can buffer writes until close. When another client wants the file, the server sends a recall, and the client flushes and hands the delegation back. See [[delegations-and-locking-explained|delegations and locking]].

### Step 6: Getting calls onto the wire
Every operation becomes an RPC: build a task with the right encoders and arguments, hand it to the connection (which handles reconnection, retransmission and back-off), decode the reply into kernel structures, and wake the waiting process. See [[sunrpc-explained|SUNRPC]] and [[xdr-encoding-explained|XDR]].

### Step 7: Recovering after a server reboot
If NFSv4 calls start failing with "stale client ID" or "expired", the client knows the server has lost its state. A background state manager then rebuilds it: re-registering, re-opening files and reclaiming locks, with back-off, and finally telling the server it has finished reclaiming.

## The picture

```text
 client record (server X, NFSv4) ── RPC connection, client ID, lease
   ├─ mount /a (server record: rsize, wsize, cache lifetimes, root handle)
   │    └─ NFS inode: file handle, change counter, cached attrs, open states
   │          └─ page requests → batched READ / WRITE calls
   └─ mount /b  (shares the same client record)

 stat():  attributes fresh? ── yes ─▶ answer from cache
                             no ──▶ GETATTR → compare change counter
 close(): flush + COMMIT        open(): revalidate   ⇒ close-to-open coherency
```

## Tradeoffs

- **What it gives you:** remote files with local-file calls, far fewer round trips thanks to caching, and (NFSv4) delegations and locking.
- **What it costs / requires:** stale attributes for up to the cache window (60 seconds for files by default); `noac` turns caching off for full coherency, at the cost of a GETATTR on every operation. NFSv4 recovery is complex.
- **Where it bites:** mount type. **Hard** mounts retry forever, which is safe for data but can hang processes during an outage; **soft** mounts return I/O errors after a few retries, which is responsive but can corrupt open files on a transient failure. Most production systems use hard mounts and allow a kill signal to break stuck operations.

## How it got here

- **2.0 (1992):** NFSv2 client. **2.2 (1999):** NFSv3.
- **2.6.0 (2003):** NFSv4 client.
- **2.6.38 (2011):** NFSv4.1 client, with sessions and the pNFS framework.
- **3.9 (2013):** NFSv4.2 features such as server-side copy and space reservation.
- **4.x:** local disk caching integration and better write coalescing. **5.3 (2019):** sparse-file-aware reads.

## Related

- Technical version: [[nfs-client]]
- [[nfs-explained|NFS subsystem]], [[nfs-server-explained|NFS server]], [[sunrpc-explained|SUNRPC]], [[xdr-encoding-explained|XDR]], [[nfsv4.1-sessions-explained|Sessions]]
- [[delegations-and-locking-explained|Delegations and locking]], [[nfs-fscache-explained|NFS local caching]]
- [[page-cache-explained|Page cache]], [[writeback-infrastructure-explained|Writeback]], [[fs-explained|Filesystem subsystem (VFS)]]
