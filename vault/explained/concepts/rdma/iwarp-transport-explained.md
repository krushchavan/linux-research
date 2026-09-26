---
title: "iWARP Transport — Explained"
category: explained
original: "[[iwarp-transport]]"
subsystem: rdma
tags: [explained, rdma, iwarp, tcp, direct-data-placement]
converted: 2026-09-26
---

# iWARP, explained

> Plain-language companion to [[iwarp-transport|the technical note]]. Same facts, fewer identifiers.

## The problem

RDMA needs reliable delivery underneath. RoCE gets it by borrowing InfiniBand's transport and asking Ethernet to be **lossless**, which takes careful switch configuration and usually stays inside one datacenter. **iWARP** takes the other route: it puts RDMA on top of **TCP**, inheriting TCP's reliability, congestion control and ability to cross routed and lossy networks, even WANs, with no special switch setup. In Linux, iWARP cards are ordinary RDMA devices behind the same verbs API, but they bring rules the core must enforce: a TCP-based connection handshake, a way to share TCP port numbers with the host, and a registration requirement for RDMA reads.

## The idea in one paragraph

TCP is a **byte pipe**: order and delivery are guaranteed, but not message boundaries, so a normal receiver copies bytes into a buffer and then parses them. iWARP puts **shipping labels inside the pipe**. Each chunk of data says either "this belongs at offset X of memory region Y" or "this is part of message N, for the next receive buffer". A card that reads the labels can **place each chunk straight into its final memory location** as it comes off the wire, even before earlier TCP segments have arrived, without the host CPU. That's "direct data placement". A framing layer makes sure the labels can still be found even after TCP re-splits the stream.

## Step by step

### Step 1: Four layers
The IETF standards stack:
- **RDMAP** (RFC 5040): the operations: send, RDMA write, RDMA read request and response, and "terminate" for fatal errors
- **DDP** (RFC 5041): direct data placement, with the labels
- **MPA** (RFC 5044): framing over TCP, with a CRC32c per frame
- **TCP/IP**: reliability, ordering, congestion control, routing

### Step 2: How operations map to labels
An **RDMA write** is a *tagged* message: every segment names the peer's memory region (a "steering tag", iWARP's word for a remote key) and an offset. A **send** is *untagged*: segments name a queue, message number and offset within the message, and fill the next posted receive buffer. An **RDMA read** sends a small request naming the source region and the requester's own **sink** region; the responder answers with tagged writes into that sink.

### Step 3: Place out of order, complete in order
This is the key step. Because every segment says where its bytes go, **segments that arrive out of order can be placed immediately**, with no reassembly buffer. Completions are still reported in order.

### Step 4: Framing
MPA packs placement segments into frames (length, payload, padding, CRC32c) sized to fit TCP segments. Optional **markers** every 512 bytes point back to the frame header, so a receiver that loses its place can find frame boundaries again. They added so much complexity that implementations negotiate them off and rely on frames lining up with TCP segments. Before RDMA mode starts, the two sides exchange an MPA request and reply over the new TCP connection, carrying up to 512 bytes of private data and negotiating CRC and markers. Version 2 (RFC 6581) adds negotiation of how many reads each side may have outstanding, and a defined "ready to receive" first message; RFC 7306 adds atomics and immediate data.

### Step 5: Connecting through a TCP-based manager
iWARP has no InfiniBand-style connection messages; connections are TCP connections. So the kernel has a separate **iWARP connection manager** that the general RDMA connection manager drives for iWARP cards. To connect, it hands private data, read depths and the queue number to the card (or to siw in software), which does the TCP handshake and MPA exchange; on success the queue pair moves to ready-to-send. Listening creates an endpoint on the card; an incoming connection plus MPA request becomes a connection-request event, and accepting sends the MPA reply. Disconnecting closes TCP gracefully or abortively. Because the queue's life follows TCP events (FIN, reset, retransmission timeout), a stalled TCP connection shows up as a close event or an error completion.

### Step 6: Sharing port numbers with the host (iwpmd)
Hardware iWARP cards run their own TCP stack but **share the host's IP addresses**. If the card chose TCP port 5000 while a host program also used 5000, both would claim incoming segments. The fix is a **port mapper**: before connecting or listening, the kernel asks a user-space daemon, **iwpmd**, over netlink; it opens a real socket and binds the port through the host stack, reserving it, and returns the mapped port the card then uses on the wire. Mappings are released afterwards. siw doesn't need this because it uses kernel TCP sockets, which already own their ports.

### Step 7: Reads need registered sinks
On InfiniBand and RoCE, the requester of a read names its local destination with a purely local key. In iWARP, the read response is a tagged *write* into the requester's memory, so the destination must be a **registered region with remote-write access**. The core's rw helper therefore always registers memory for iWARP reads, using a read variant that invalidates the temporary tag when the read completes. NFS/RDMA, iSER and NVMe-oF get this for free.

### Step 8: Other differences
iWARP is connection-only: no datagram mode, no multicast, and historically no atomics, so upper layers check capabilities. After the MPA exchange the *active* side must send first; with MPA v2 a zero-length write or read acts as that signal, inserted by drivers. Addresses are just the interface's MAC and IP, with no RoCE-style address table.

### Step 9: Implementations
Chelsio T4–T7 cards (the flagship, with full TCP offload), Intel E810/X722 (the irdma driver, which replaced i40iw in 5.14 and can run iWARP or RoCE v2 per port), Marvell/QLogic FastLinQ, and **siw** in software. Older drivers (cxgb3, NetEffect, i40iw) have been removed.

## The picture

```text
 RDMA write of 64 KB to remote region Y
   ─▶ tagged segments {region Y, offset 0}, {Y, 16K}, {Y, 32K}, {Y, 48K}
   ─▶ MPA frames (+CRC32c) ─▶ TCP ─▶ IP (routable, lossy is fine)
 receiver NIC: segment {Y, 32K} arrives early → placed immediately at Y+32K
               completion reported when all arrive, in order
 ports: kernel ─netlink─▶ iwpmd binds port via host socket ─▶ NIC uses mapped port
```

## Tradeoffs

- **What it gives you:** RDMA over ordinary IP networks, including lossy and routed ones and WANs, with standard TCP congestion control and no lossless-Ethernet configuration; placement without reassembly buffers.
- **What it costs / requires:** a full TCP stack in card hardware, which is expensive and hard to update. Linux network maintainers have long opposed TCP offload because offloaded connections bypass netfilter, queueing disciplines and host TCP fixes, which is partly why iWARP lives entirely in the RDMA subsystem. The port mapper adds a daemon dependency and a netlink round trip per connection. Every read needs a temporary registration.
- **Where it bites:** in the market, RoCE won the datacenter mainstream (AI, storage) on ecosystem and silicon cost. iWARP persists with Chelsio, Intel E810 and siw, especially where lossless fabrics aren't practical, and newer "lossy RoCE" work re-creates iWARP's main advantage inside RoCE cards.

## How it got here

- **2002–2007:** the RDMA Consortium and IETF work; RFCs 5040, 5041 and 5044 published in 2007.
- **2.6.19 (2006):** the iWARP connection manager (Tom Tucker, Steve Wise) and the first drivers. Netdev refused to put offloaded TCP state into the kernel's TCP tables, so iWARP ports needed separate arbitration.
- **2012–2014:** MPA v2 (RFC 6581) and protocol extensions (RFC 7306).
- **3.18 (2014):** the port mapper and iwpmd (Tatyana Nikolova, Intel).
- **4.8:** i40iw. **2016:** the rw helper started registering all iWARP read sinks centrally. **5.3:** siw. **5.14:** irdma.
- **2020s:** old drivers removed; iWARP supported but with little new protocol work.

## Related

- Technical version: [[iwarp-transport]]
- [[rdma-explained|RDMA subsystem]], [[soft-rdma-rxe-and-siw|rxe and siw]], [[rdma-cm-connection-manager|Connection manager]], [[rdma-rw-api|rw API]], [[memory-registration-and-ib-umem|Memory registration]], [[roce-v1-and-v2|RoCE v1 and v2]], [[roce-congestion-control-pfc-ecn-dcqcn|RoCE congestion control]]
- [[tcp-ip-stack-explained|TCP/IP stack]]
