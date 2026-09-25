---
title: "NFS Server (knfsd) — Explained"
category: explained
original: "[[nfs-server]]"
subsystem: nfs
tags: [explained, nfs, nfsd, file-handles, exports]
converted: 2026-09-25
---

# The NFS server (knfsd), explained

> Plain-language companion to [[nfs-server|the technical note]]. Same facts, fewer identifiers.

## The problem

An NFS server has to serve local files to many clients over the network, quickly, safely and in a way that survives its own reboots. Clients don't keep an open connection to "a file" the way a local process does. They send a request, get an answer, and come back later, possibly after the server has restarted, expecting to reach the same file. The server must also check every request against what it has agreed to export, and to whom.

The original Linux NFS server ran in user space, paying a context switch for every request and reaching files only through system calls.

## The idea in one paragraph

Run the server **inside the kernel** as a pool of threads. Each thread loops: take an RPC request, check it, turn it into ordinary VFS calls on the exported filesystem, and send back the answer. The server holds no long-lived references to files between requests. Instead, it gives clients an opaque **file handle** encoding the file's identity (in a form each filesystem defines), and decodes that handle again on every later request to find the file.

## Step by step

### Step 1: Start the thread pool
User space starts the service by writing a thread count to a control file. The kernel creates that many `nfsd` threads, each with its own request context, and each blocks waiting for a request on any listening socket (UDP, TCP or RDMA).

### Step 2: Receive and dispatch
When a request arrives, the RPC layer decodes its header (program, version, procedure), finds the procedure in the registered NFS program, decodes the arguments, and calls the handler: one per operation for v2/v3, and for v4 a single handler that walks each operation in a compound request in turn.

### Step 3: Check the export
Before serving anything, the server confirms the target is inside an exported tree and that the export allows this client (by IP address or authentication domain). Exports are set up from user space (`exportfs`) and stored per (client domain, exported path). A handle outside any export, or not allowed for this client, gets an access-denied or stale-handle error.

### Step 4: File handles
This is the key step. A file handle must lead back to the right file at any time, including after a server restart. The core of it is a **file identifier** that each filesystem defines: ext4 and XFS use inode number plus generation; btrfs uses inode plus subvolume. The **generation number** catches reuse: if a file is deleted and its inode number handed to a new file, the old handle's generation won't match, and the client gets "stale" rather than someone else's file.

Filesystems provide three export hooks: turn a file into a handle fragment, turn a fragment back into a file, and find a directory's parent (for rebuilding paths). A filesystem is exportable only if it provides them; most in-kernel filesystems do, and a FUSE daemon must implement them itself.

### Step 5: Cache open files
Opening a kernel file object for every read or write would be costly (a reference, a permission check, setup). So the server keeps a **file cache**: an open file per (inode, access mode), shared by threads and reference-counted, which also keeps that file's page cache warm. Writes go through the exported filesystem's normal page cache and writeback; a commit call flushes the range to stable storage. The cache must drop entries on unlink or rename, and must not hold files open so long that it blocks unmounting.

### Step 6: NFSv4 state
NFSv4 servers track state per client: a **client ID**, then per-process **open owners** and **lock owners**, a **state ID** for each open or lock, and **delegations**. All of it hangs off a **lease**: if the client doesn't renew within the lease time, the server reclaims its state. A delegation is recalled with a callback, over the NFSv4.1 session's back channel, when another client wants a conflicting open.

### Step 7: Watching and controlling it
A control filesystem exposes the thread count, active exports, enabled NFS versions and, per NFSv4 client, a directory showing its open files, locks and delegations.

## The picture

```text
 user space: set thread count · exportfs · mountd
                     │
   nfsd threads ── wait for request (UDP / TCP / RDMA)
        │ decode header → find procedure → decode arguments
        │ check export: inside exported tree? client allowed?
        │ file handle ──decode──▶ (inode + generation) ──▶ file   [stale if reused]
        │ file cache: open file per (inode, mode)
        │ VFS read / write / create / rename … on exported filesystem
        └ encode reply → send
   NFSv4: client ID → owners → state IDs, delegations  (all under a lease)
```

## Tradeoffs

- **What it gives you:** far higher throughput than a user-space server, since there are no per-request context switches and VFS calls are direct; filesystems choose their own handle encoding; open files are reused across requests.
- **What it costs / requires:** a bug in the server can crash the kernel; one complex codebase for NFS v2 through v4.2; every exportable filesystem must implement the export hooks and keep generation numbers durable.
- **Where it bites:** subtree checking (verifying each request walks up to the export root) is expensive and is now opt-in; most setups rely on generation checks instead. Squashing options (map root, or everyone, to `nobody`) and read-only exports are common sources of "permission denied" surprises.

## How it got here

- **2.2 (1999):** the in-kernel server merged, replacing the user-space one.
- **2.6.0 (2003):** NFSv4 server. **2.6.38 (2011):** NFSv4.1 server, with sessions and pNFS.
- **3.11 (2013):** NFSv4.2 features such as server-side copy and space reservation.
- **5.3 (2019):** the open-file cache.
- **6.x:** signed file handles for security, and LOCALIO for same-host clients.

## Related

- Technical version: [[nfs-server]]
- [[nfs-explained|NFS subsystem]], [[nfs-client-explained|NFS client]], [[nfs-localio-explained|LOCALIO]], [[delegations-and-locking-explained|Delegations and locking]]
- [[sunrpc-explained|SUNRPC]], [[xdr-encoding-explained|XDR]], [[nfsv4.1-sessions-explained|Sessions]]
- [[fs-explained|Filesystem subsystem (VFS)]], [[dentry-explained|Dentries]], [[page-cache-explained|Page cache]]
