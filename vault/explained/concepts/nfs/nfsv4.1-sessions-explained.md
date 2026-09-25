---
title: "NFSv4.1 Sessions — Explained"
category: explained
original: "[[nfsv4.1-sessions]]"
subsystem: nfs
tags: [explained, nfs, sessions, exactly-once, back-channel]
converted: 2026-09-25
---

# NFSv4.1 sessions, explained

> Plain-language companion to [[nfsv4.1-sessions|the technical note]]. Same facts, fewer identifiers.

## The problem

Networks lose replies. When an NFS client doesn't hear back, it resends the request. For a read that's harmless, but for rename, remove or attribute changes it isn't: if the first attempt actually succeeded and only the reply was lost, the server runs it a second time. A repeated rename or remove can then fail oddly, or act on the wrong thing. NFSv4.0 had no reliable way to tell a retry from a new request.

There was a second pain point. For callbacks, such as recalling a delegation, the NFSv4.0 server had to open its own connection *to* the client, which firewalls and NAT often blocked.

## The idea in one paragraph

A session works like a **numbered set of lanes** shared by client and server. The client has a fixed number of **slots**; every request occupies one slot and carries that slot's **sequence number**, counting how many times the slot has been used. The server runs each request and saves the reply under (session, slot, sequence number). If the same triple arrives again, it's a retry, and the server returns the saved reply without running the operation again. The client moves a slot to its next number only after getting a valid reply, which gives **exactly-once** behaviour. The same connection is also used in reverse for server-to-client callbacks.

## Step by step

### Step 1: Create the session
After agreeing a client ID, the client creates a session, proposing limits for each direction: largest request, largest reply, and how many requests may be outstanding at once. That last number is the **slot count**. The server replies with the agreed values and a 16-byte session ID, and sets aside room to save one reply per slot.

### Step 2: Every request starts with a sequence header
Every compound request in NFSv4.1 begins with a **sequence** operation carrying the session ID, the slot number, that slot's sequence number, the highest slot the client currently needs, and a flag saying whether the server must save the reply.

### Step 3: The server checks the number
This is the key step. Before anything else in the compound, the server finds the session, checks the slot is in range, and compares sequence numbers:
- **one more than last time:** a new request. Run it and save the reply.
- **the same as last time:** a retry. Return the saved reply without running anything.
- **anything else:** out of order, so reject it.

The slot is marked busy while the request runs, and it's released, with its saved reply updated, only when the request finishes. So two unsafe operations can never be in flight on one slot at the same time.

### Step 4: Save only what needs saving
For operations that are safe to repeat (reads, attribute fetches), the client can tell the server not to save the reply, saving server memory. A retry of such a request is simply run again, which is harmless because repeating it gives the same answer.

### Step 5: The back channel
Instead of the server opening a separate connection to the client, NFSv4.1 uses the **same connection in reverse**, with limits agreed at session creation. Callbacks start with their own sequence header and then carry operations such as recalling a delegation or a pNFS layout. Delegations therefore work through NAT and firewalls with no extra connection.

### Step 6: Shrinking on demand
Each sequence reply can include a target highest slot. If the server is short of memory it lowers the target, the client gradually stops using the higher slots, and the server frees their memory, all without tearing the session down. Growing it again needs extra steps or a new session.

### Step 7: In the Linux client
The Linux client keeps a session record with two slot tables, one per direction. Before each call it takes a free slot, waiting if all are busy, and fills in the sequence header; after the reply it processes the sequence result and releases the slot. pNFS layout operations use ordinary slots, and layout recalls arrive on the back channel.

## The picture

```text
 session (ID 0xA1…)                         server reply cache
 slot 0: seq 41 ──RENAME──▶ run, save  ──▶  [0x A1, slot 0, 41] = OK
          (reply lost)
 slot 0: seq 41 ──RENAME──▶ same triple ──▶ return saved OK (not run again)
 slot 0: seq 42 ──REMOVE──▶ new request ──▶ run, save
 slot 3: seq 7  ──READ (don't save)──▶ run; a retry just runs again

 same TCP connection, reverse direction:  server ──recall delegation──▶ client
```

## Tradeoffs

- **What it gives you:** exactly-once execution for unsafe operations, direct lookup of saved replies by slot number (NFSv4.0's duplicate-request cache needed a hash lookup for every request), callbacks that pass through NAT and firewalls, and the transport pNFS relies on.
- **What it costs / requires:** memory for a saved reply per slot, allocated even when the workload never needs it; a slot count that is awkward to raise after creation, which suits burst workloads poorly.
- **Where it bites:** with all slots busy, new requests wait; the Linux client caps slots at 64 by default. Callbacks now arrive on the client's existing connection, which can change what a strict firewall policy needs to allow.

## How it got here

- **2.6.38 (2011):** NFSv4.1 client and server merged.
- **3.7 (2012):** an improved back channel.
- **3.9 (2013):** dynamic slot-table renegotiation fully implemented.
- **5.3 (2019):** NFSv4.2 sessions fully supported.

## Related

- Technical version: [[nfsv4.1-sessions]]
- [[nfs-explained|NFS subsystem]], [[nfs-client-explained|NFS client]], [[nfs-server-explained|NFS server]], [[pnfs-explained|pNFS]], [[sunrpc|SUNRPC]]
- [[delegations-and-locking-explained|Delegations and locking]]
