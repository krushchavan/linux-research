---
title: "NFS Delegations and Locking — Explained"
category: explained
original: "[[delegations-and-locking]]"
subsystem: nfs
tags: [explained, nfs, delegations, byte-range-locking, state-recovery]
converted: 2026-09-25
---

# NFS delegations and locking, explained

> Plain-language companion to [[delegations-and-locking|the technical note]]. Same facts, fewer identifiers.

## The problem

In NFSv3, a client had no way of knowing whether anyone else was touching a file, so it asked the server for fresh attributes on every open, generating constant traffic even for files nobody else ever used. Locking was worse: it ran through a separate, fragile protocol (the Network Lock Manager) the server couldn't see properly, which made recovery after crashes messy.

Two things were needed: a way for the server to say "you're the only one using this, cache freely", and locking built into the protocol so the server knows exactly who holds what and can restore it cleanly after a reboot.

## The idea in one paragraph

A **delegation** is like checking a file out on loan. The server gives the client a token and says: "this file is yours for now. Serve opens, reads and locks from your own cache, and I'll call you before I let anyone else in." The client can then work almost entirely locally. When someone else needs the file, the server **recalls** the delegation, and the client hands everything back: flushing data, re-registering its opens and locks with the server, then returning the token. Without a delegation, every lock and unlock is a normal call to the server, which tracks it all under the client's **lease**, ready to be reclaimed if the server restarts.

## Step by step

### Step 1: Granting a delegation
Delegations are handed out when a file is opened: the server's reply to OPEN can include a delegation token of type **read** or **write**. The client records it on the inode. A read delegation means no other client will write the file, so the client can serve further opens itself, skip revalidating attributes, and keep locks local. A write delegation would also let it serve other opens for reading, but Linux's server doesn't grant those in practice.

### Step 2: Working locally
While the delegation is held, byte-range locks taken by processes are recorded only in the client's own open state; the server hears nothing. That's also why, if the client ever has to reclaim locks while still holding a delegation, there's nothing to reclaim: no lock calls were ever sent.

### Step 3: The recall
This is the key step. When a second client opens the file for writing, the server can't allow it while the read delegation is out. It sends a **recall** callback to the holder, over the session's back channel in NFSv4.1 or a separate callback connection in NFSv4.0, and tells the second client "try again later" until the delegation is back. The holder then:
1. **flushes dirty pages** so the server has every cached write
2. **re-opens explicitly:** during the delegation, its token stood in for real open tokens, so each open is now registered with the server
3. **re-sends its locks:** each byte-range lock is registered with a lock call, and only now does the server see them
4. **returns the delegation** with a return call; the server destroys it
5. **frees its record** once no concurrent reader can be using it

Delegations also appear to the local kernel as a kind of lease on the file, so a conflicting local operation triggers the same return sequence.

### Step 4: Other ways a delegation ends
- **Lease expiry:** clients must renew their lease regularly. If one can't (a network split, a crash), the server drops its state, and the client discovers the loss when it recovers.
- **Unmount:** delegations are returned without reclaiming locks.
- **Memory pressure:** delegations no longer used by any open file are returned.
- **Before its own conflicting change:** before the client changes attributes or deletes the file itself, it returns the delegation first, saving a recall round trip.

Linux's server also skips the recall when the conflict comes from the *same* client that holds the delegation, which helps patterns like "open a temp file, delete it, keep writing, close". The file then lingers in memory with no names until the client returns the delegation.

### Step 5: Locking without a delegation
Without a delegation, locking is a network conversation:
- **lock:** take a shared or exclusive range lock; the server returns a lock token that identifies it from then on
- **test:** check whether a range is locked, without taking it
- **unlock:** release all or part of a range

Unlike POSIX locks, NFSv4 locks **never wait at the protocol level**: a contested lock is refused at once, and the client must keep retrying. Remote clients therefore compete poorly with local processes. Linux orders waiters in a queue and uses provisional locks that can be withdrawn if a client stops polling. NFSv4.1 added a way to cancel a pending request, but there's still no "your lock is ready" message from the server.

### Step 6: Recovering after a server restart
After a reboot the server enters a **grace period** (90 seconds by default) in which it accepts only reclaims of previously held state, not new locks, so rightful owners get their locks back before anyone else can grab them. When a client notices the restart (a stale-client error or a reset connection), it:
1. re-establishes its client identity
2. reclaims its opens, marking them as previously held
3. reclaims its locks the same way
4. (NFSv4.1) says it has finished, so the server can end grace early once every client is done

A client that doesn't finish in time loses its locks, and applications see I/O or bad-descriptor errors.

## The picture

```text
 client A: OPEN ──▶ server: "here's a READ delegation"
   A caches: opens, reads, locks (server sees nothing)

 client B: OPEN for write ──▶ server: "try again later"
                              server ──recall──▶ A
   A: flush dirty pages → re-open explicitly → re-send locks → return delegation
 server ──▶ B: OPEN granted

 no delegation:  LOCK / TEST / UNLOCK each go to the server (refused at once if contested)
 server reboot:  grace period → clients reclaim opens + locks → "done" → normal service
```

## Tradeoffs

- **What it gives you:** far less traffic for files only one client uses, local locking while delegated, and full server visibility and clean recovery for locks.
- **What it costs / requires:** a complicated recall sequence (opens and locks must be re-registered one by one), a reliable callback path, and lease renewal traffic.
- **Where it bites:** a client that can't be reached holds up everyone else until its lease runs out. That's why Linux's server avoids write delegations, which would block other clients' reads indefinitely. Polling-based locks are unfair to remote waiters.

## How it got here

- **NFSv4.0:** delegations and in-protocol locking, with a separate callback connection that was fragile behind NAT.
- **NFSv4.1 (2010):** the session back channel made recalls reliable; added early exit from grace and lock cancellation.
- **~2013:** a long-running patch series (nine-plus versions) worked on directory delegations. Its key insight was to drop inode locks before waiting for a delegation break, avoiding deadlocks with unresponsive clients.
- **2023–2024:** the VFS hooks for breaking directory delegations on link, rename and unlink landed, enabling directory delegations in the server for lookup-heavy workloads.
- **Ongoing:** races between concurrent opens and delegation returns keep producing subtle bugs and fixes.

## Related

- Technical version: [[delegations-and-locking]]
- [[nfs-explained|NFS subsystem]], [[nfs-client|NFS client]], [[nfs-server|NFS server]], [[nfsv4.1-sessions|NFSv4.1 sessions]], [[sunrpc|SUNRPC]]
- [[vfs-locking-model-explained|VFS locking model]], [[page-cache-explained|Page cache]], [[writeback-infrastructure-explained|Writeback]]
