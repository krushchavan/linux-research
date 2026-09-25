---
title: "NFS LOCALIO — Explained"
category: explained
original: "[[nfs-localio]]"
subsystem: nfs
tags: [explained, nfs, localio, containers, performance]
converted: 2026-09-25
---

# NFS LOCALIO, explained

> Plain-language companion to [[nfs-localio|the technical note]]. Same facts, fewer identifiers.

## The problem

Sometimes the NFS client and the NFS server run in the same kernel, typically containers on one host mounting an NFS export served from that same host. Even then, every read and write takes the full network route: encode the call, send it over a socket, loop it back through the network stack, receive and decode it, do the work, and encode and send the reply the same way. All that burns CPU and adds latency for data that never needed to leave the machine.

The tricky part is knowing *safely* that both ends really are in the same kernel. Comparing IP addresses doesn't work: containers can have separate network namespaces with overlapping addresses, firewall rules can redirect traffic, and virtual IPs move.

## The idea in one paragraph

LOCALIO is a **short circuit**. Normally the client sends a message down a wire and waits for the reply. Once LOCALIO has proven the server lives in the same kernel, the client opens a door straight into the server's own cache of open files and reads and writes directly, with the same permission checks but none of the packing, sending and unpacking. The proof is a **shared-memory handshake**: the client writes a secret into kernel memory and asks the server whether it can see it.

## Step by step

### Step 1: The handshake
1. The client makes a short-lived random UUID and registers it in a structure held by a small shared module that both client and server code can reach.
2. At mount or connection setup, it sends the UUID to the server in a special "is this UUID local?" call.
3. The server looks for it in the same shared memory. Only code in the same kernel could find it, so a match proves co-location.
4. The server also checks that both sides are in the same network namespace, which matters when two containers on one host have separate ones.

If all checks pass, the client keeps a reference to the server's per-namespace state and turns the local path on. The check is per mount and repeated on reconnect.

An earlier loopback-NFS idea had the server publish a UUID for the client to fetch. Having the client generate the nonce instead saves a round trip and avoids a race between creating and checking it.

### Step 2: The short-circuited path
This is the key step. Normally a read goes: page request, RPC task, encode, socket, network, server, VFS read, encode, socket, network, decode. With LOCALIO, a read goes from the page request straight to the server's cached open file, then a VFS read. In detail:
- the client turns its NFS file handle into the server's **cached open file**, once per inode on first local I/O
- reads and writes are ordinary VFS reads and writes on that file, using the calling task's credentials
- commit (flush to stable storage) is done locally with an fsync of the range

Using the server's file cache, rather than opening a fresh kernel file, avoids opening and closing on every I/O, reuses its garbage collection and reference counting, and shares page cache already warmed by other clients. Metadata operations (attributes, lookups) still go over RPC.

### Step 3: Staying safe
- **Only AUTH_SYS** (`sec=sys`). The local path skips the security-context handling that Kerberos needs, so Kerberos mounts aren't eligible. The main use case, trusted containers on the same host, doesn't need more for now.
- **No writeback deadlock.** The client's writeback might wait on a page that the server's write path is also waiting on. To prevent that, the client flags the server's file so the server-side write skips its own writeback.
- **No teardown race.** The client holds a per-CPU reference on the server's namespace state for as long as any local I/O is in flight, so removing a container can't free the server's state under it. Per-CPU counting keeps this cheap on the fast path.

Normal permission checks still apply, since both sides go through the VFS.

### Step 4: Falling back
If the host differs, the namespace differs, or the mount isn't AUTH_SYS, the mount simply uses the normal RPC path. LOCALIO is opportunistic: it never makes a mount fail. Mount options can force it on or off.

## The picture

```text
 normal:   client ─ encode ─ socket ─▶ loopback network ─▶ socket ─ decode ─ nfsd ─ VFS read
                  ◀─ decode ─ socket ◀─ loopback network ◀─ socket ─ encode ─┘

 handshake:  client writes UUID into shared kernel memory
             "is UUID local?" ─▶ server: found it + same network namespace ⇒ local

 LOCALIO:  client ─▶ server's cached open file ─▶ VFS read / write / fsync
           (holds a reference on the server's namespace while I/O is in flight)
```

## Tradeoffs

- **What it gives you:** throughput close to direct local filesystem access for containers mounting NFS from their own host, with no change to applications and automatic fallback.
- **What it costs / requires:** both client and server support compiled in; AUTH_SYS only; a shared module and careful reference handling across two subsystems.
- **Where it bites:** only data reads, writes and commits are short-circuited, so metadata-heavy workloads still pay RPC costs. Kerberos-secured mounts get no benefit.

## How it got here

- **2013:** "Loopback NFS: theory and practice" explored the problems of NFS mounts served from the same host, the investigation that motivated LOCALIO.
- **~6.13:** LOCALIO merged, short-circuiting reads, writes and commits for NFSv3 and NFSv4 AUTH_SYS mounts.
- **Ongoing:** more authentication types and better locality detection for unusual multi-namespace setups.

## Related

- Technical version: [[nfs-localio]]
- [[nfs-explained|NFS subsystem]], [[nfs-client-explained|NFS client]], [[nfs-server|NFS server]], [[sunrpc|SUNRPC]]
- [[fs-explained|Filesystem subsystem (VFS)]], [[page-cache-explained|Page cache]], [[writeback-infrastructure-explained|Writeback]]
