---
title: "NFS over RDMA (xprtrdma and svcrdma) — Explained"
category: explained
original: "[[nfs-over-rdma-svcrdma-xprtrdma]]"
subsystem: nfs
tags: [explained, nfs, rdma, sunrpc, direct-data-placement]
converted: 2026-09-26
---

# NFS over RDMA, explained

> Plain-language companion to [[nfs-over-rdma-svcrdma-xprtrdma|the technical note]]. Same facts, fewer identifiers.

## The problem

NFS runs on SunRPC, which normally uses TCP. Every read reply and write request carries file data inside the RPC byte stream, so both client and server copy it through socket buffers and spend CPU in the TCP stack. **RPC-over-RDMA** replaces the transport under SunRPC with RDMA: small RPCs travel as RDMA sends, while bulk data moves by **direct data placement**, the server's card writing read data straight into the client's page-cache pages and reading write data straight out of them. In Linux the client side is **xprtrdma** and the server side **svcrdma**, plugged into SunRPC's generic transport frameworks. NFS itself (v3, v4.x) doesn't change; it's `mount -o rdma,port=20049`.

## The idea in one paragraph

An RPC message is a **letter with attachments**. Over TCP, the attachments are stapled into the letter and everyone handles the whole bundle. RPC-over-RDMA sends just the **letter** (the RPC header and small arguments, "inline") in an RDMA send, plus a **claim ticket** for each attachment: a *chunk* naming a key, length and offset in the sender's registered memory. The other side picks up attachments straight from the sender's shelves (RDMA read) or puts results straight onto the requester's shelves (RDMA write). The rule of version 1 is that **the server always does the RDMA operations**: the client only registers memory and hands out tickets, so the server controls its own resource use and the client never has to reach into the server's memory.

## Step by step

### Step 1: Connect
The client mount creates an RDMA transport and connects through the RDMA connection manager, creating a reliable queue pair. The connection handshake advertises **inline thresholds**, the biggest message sent in a single send (1 KB by default in the standard; Linux negotiates up to 4 KB). The server enables RDMA by writing to its port list, creating a listener. Both sides pre-post **receive buffers**, and every message carries **credits** saying how many requests the peer may have outstanding, so the client never sends more than the server has buffers for. This RPC-level flow control replaces TCP's window.

### Step 2: The header and its chunk lists
Every message starts with a transaction ID, version, credits, a message type, and three lists:
- a **read list:** pieces the *server* must RDMA-read from the client, such as NFS write data, each marking where it belongs in the message
- a **write list:** client buffers the server should RDMA-write results into, such as NFS read data
- a **reply chunk:** a client buffer for the *whole* reply when it might be too big to send inline (directory listings, large attributes, ACLs)

A request too big to send inline travels entirely as a read chunk.

### Step 3: Client sends
The client decides a strategy per RPC. NFS tells it which part of the message is eligible for direct placement (the standard allows only bulk data, like read/write payloads and directory or link data). For each chunk, the client takes a pre-allocated memory region, maps the relevant **page-cache pages** into it, and writes the key, length and offset into the header. It then posts a chain: a registration request per region, then the send carrying the header and inline data (sent straight from pages where possible, otherwise gathered into one buffer).

### Step 4: Server receives and runs the request
A receive completion hands the message to svcrdma, which parses the header into a structured chunk list. If there's a read list, it builds RDMA reads with the shared rw helper, waits for them, and splices the pulled data into the request's pages at the right positions, so nfsd sees an ordinary, complete RPC. nfsd then does the work (a write goes to the VFS, say).

### Step 5: Server replies
For a read, the data pages go to the client's **write chunk** by RDMA write. If the reply body doesn't fit inline, it's written into the **reply chunk**. Finally the reply header (and any inline part) goes out as a send, **with invalidate** of the client's key if the client supports it, so the client's memory region is revoked remotely. Reliable-connection ordering guarantees the writes land before the send arrives.

### Step 6: Client completes, safely
This is the key step for safety. The client's reply handler checks the transaction ID and credits, adjusts its window, fixes up the reply for data that arrived by RDMA write, and makes sure **every memory region used by the RPC is invalidated**, either trusting the remote invalidation or posting a local one **before** handing the reply to NFS. No page can go back to the page cache while a remote machine could still write into it.

### Step 7: Callbacks and errors
NFSv4.1 server-to-client callbacks (like delegation recalls) run over the same connection with roles reversed, using a few reserved credits. After a queue error or disconnect, pending RPCs are retransmitted after reconnecting (NFSv3) or replayed through the session's slot table (NFSv4.1), and regions that might have been exposed are re-registered with fresh keys before reuse.

## The picture

```text
 NFS READ 1 MB:
   client: register page-cache pages → key K ─ SEND {READ call, write list: [K, 1 MB]}
   server: read file → RDMA WRITE 1 MB into K ─ SEND_WITH_INV {reply, invalidate K}
   client: K invalidated? ✓ → complete read (data already in page cache)
 NFS WRITE 1 MB:
   client: SEND {WRITE call, read list: [K2, 1 MB]}
   server: RDMA READ from K2 → splice into request → nfsd writes via VFS → SEND reply
```

## Tradeoffs

- **What it gives you:** NFS data moved with no socket-buffer copies and little CPU, landing directly in the page cache, without changing NFS itself; the server never exposes its memory and paces transfers itself.
- **What it costs / requires:** client-to-server bulk data needs an extra round trip (the server has to read it), which is why small writes go inline; invalidating before completion costs a round trip unless the server invalidates remotely.
- **Where it bites:** deciding what goes inline versus in chunks, and guessing whether a reply might be large enough to need a reply chunk, is a major source of complexity and bugs, and motivates the version 2 drafts. The server parses peer-supplied chunk lists and turns them into RDMA operations and page offsets, fertile ground for arithmetic bugs; 2026 hardening (Chuck Lever with Chris Mason) added bounds checks and fixed an underflow and a wraparound.

## How it got here

- **2.6.24–2.6.25 (2008):** the client (Tom Talpey, NetApp) and server (Tom Tucker, Open Grid Computing).
- **2010:** the first RPC-over-RDMA standards.
- **3.x–4.x:** Chuck Lever (Oracle) takes over the client; older registration modes removed in favour of fast registration; remote invalidation (4.9); NFSv4.1 callbacks (4.4).
- **2017:** revised standards based on implementation experience.
- **4.x–5.x:** the server rebuilt on the rw helper, multiple connections, thorough tracepoints; parsed chunk-list rewrite (5.11); zero-copy inline sends.
- **2026:** chunk-list hardening against crafted peers, write-chunk fixes, and version 2 in IETF drafts.

## Related

- Technical version: [[nfs-over-rdma-svcrdma-xprtrdma]]
- [[sunrpc-explained|SunRPC]], [[xdr-encoding-explained|XDR]], [[nfs-client-explained|NFS client]], [[nfs-server-explained|NFS server]], [[nfsv4.1-sessions-explained|NFSv4.1 sessions]]
- [[rdma-explained|RDMA]], [[rdma-rw-api-explained|rw API]], [[rdma-cm-connection-manager-explained|Connection manager]], [[page-cache-explained|Page cache]]
