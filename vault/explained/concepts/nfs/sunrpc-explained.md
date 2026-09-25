---
title: "SunRPC (Kernel RPC Layer) — Explained"
category: explained
original: "[[sunrpc]]"
subsystem: nfs
tags: [explained, nfs, sunrpc, rpc, transports]
converted: 2026-09-25
---

# SunRPC, the kernel's RPC layer, explained

> Plain-language companion to [[sunrpc|the technical note]]. Same facts, fewer identifiers.

## The problem

NFS, its lock manager, its status monitor and rpcbind all work by one machine calling procedures on another. Every one of them needs the same plumbing: managing sockets, serialising arguments, matching replies to requests, retransmitting when replies go missing, backing off when the server is overloaded, and checking credentials. Writing that separately for each protocol would be wasteful and error-prone, and pushing it into a user-space daemon would cost a context switch on every call.

It also has to cope with thousands of calls in flight at once without dedicating a thread to each.

## The idea in one paragraph

SunRPC is a **typed call/reply service over UDP, TCP or RDMA**, built into the kernel. A caller names a program, version and procedure and supplies arguments; SunRPC encodes them, sends them, retransmits on timeout, verifies authentication and hands back a result or error. Crucially, each call is a small **task**, a state machine that moves through its stages, rather than a blocked thread. That lets huge numbers of calls be outstanding at once on a small pool of threads.

## Step by step

### Step 1: Three kinds of object
- a **client** per (server address, program, version, authentication type): default timeouts, credentials, the procedure table, and a reference to a transport. NFS keeps this handle, and many calls share it.
- a **transport** per physical connection (a TCP or UDP socket, or an RDMA link). Several clients can share one; NFS and the lock manager, for instance, can use the same TCP connection to a server. It owns the slot table, a congestion window, and send and receive queues.
- a **task** per call in flight: the state machine for that call.

### Step 2: Reserve a slot
A new task first claims a **slot** on its transport. Slots cap the number of concurrent calls so the server isn't overwhelmed; when they run out, tasks queue on a backlog.

### Step 3: Encode and send
The procedure's encoder serialises the arguments into XDR, and SunRPC puts the RPC header in front: program, version, procedure, a **transaction ID**, and credentials. The transport sends it with a kernel socket send for TCP and UDP, or by posting a work request for RDMA.

### Step 4: Match the reply
This is the key step. The task goes to sleep keyed by its transaction ID. A per-transport receive worker reads incoming replies, looks each ID up in a hash table of pending requests, and wakes the matching task. Lookup is constant-time, and replies can arrive in any order. UDP retransmissions reuse the same ID, which lets the server spot duplicates.

### Step 5: Decode, finish or retry
On a reply, the procedure's decoder turns it into kernel structures and the completion runs. If no reply comes in time, SunRPC shrinks the transport's congestion window and retransmits with exponential back-off. If the server rejects the credential's verifier, the credential may be refreshed and the call retried. "Soft" tasks give up after a set number of timeouts; "hard" ones retry forever.

### Step 6: Plug-in transports and authentication
Transports plug in through a table of operations: UDP (stateless, with SunRPC doing retransmission), TCP (connection management and reconnecting) and RDMA (high-performance NFS over InfiniBand or RoCE), with QUIC being explored. Authentication plugs in the same way: none, AUTH_SYS (user and group IDs, unverified), and RPCSEC_GSS (Kerberos, with integrity and optional privacy, and credentials that expire). New transports and security types don't require touching NFS or the lock manager.

### Step 7: The server side
Servers use a different pair: a **service** (a pool of kernel threads plus listening sockets, such as the NFS server) and a per-thread **request** record holding the incoming and outgoing buffers. The dispatch loop decodes the header, authenticates, calls the handler and encodes the reply.

### Step 8: Asking user space (the RPC cache)
The NFS server often needs answers only user space can give: which client name an IP address belongs to, which export options apply, which identity a user name maps to. Rather than query DNS or LDAP from the kernel, SunRPC keeps caches with an upcall channel. On a miss, the kernel sets the request aside and writes the key to the channel; a daemon (`rpc.mountd`, `rpc.idmapd`) resolves it and writes the answer back; the request is requeued and completes. Entries expire after a time-to-live.

## The picture

```text
 NFS / lock manager ─▶ client (program, version, auth)
                          │
                       task ─ reserve slot ─ encode ─ send ─ sleep on transaction ID
                          │                                    ▲
                    transport (TCP / UDP / RDMA)               │
                      slot table · congestion window           │
                          ▼                                    │
                     network ─▶ reply ─▶ receive worker: look up ID ─▶ wake task
                          timeout? shrink window, back off, retransmit

 server: service threads ─ decode ─ authenticate ─ handler ─ encode reply
         cache miss ─▶ upcall to rpc.mountd / rpc.idmapd ─▶ answer ─▶ retry request
```

## Tradeoffs

- **What it gives you:** one shared, in-kernel RPC engine for NFS and friends, thousands of concurrent calls on few threads, and pluggable transports and security.
- **What it costs / requires:** a state machine whose every stage must be re-entrant and keep all its state in the task, which makes the code complex; transaction IDs must not collide.
- **Where it bites:** SunRPC's congestion window is separate from TCP's. It limits concurrent calls whatever TCP would allow, which protects servers but can cap throughput on fast links.

## How it got here

- **2.0:** SunRPC arrives with the original Linux NFS client.
- **2.6.x:** the asynchronous task model completed; RPCSEC_GSS (Kerberos) added.
- **3.3 (2012):** the RDMA transport.
- **5.4 (2019):** prototype work on RPC-over-TLS begins.
- **6.x:** RDMA improvements continue; QUIC transport experiments.

## Related

- Technical version: [[sunrpc]]
- [[nfs-explained|NFS subsystem]], [[xdr-encoding|XDR]], [[rpcsec-gss-and-kerberos-explained|RPCSEC_GSS and Kerberos]], [[nfsv4.1-sessions-explained|Sessions]]
- [[nfs-client-explained|NFS client]], [[nfs-server-explained|NFS server]]
