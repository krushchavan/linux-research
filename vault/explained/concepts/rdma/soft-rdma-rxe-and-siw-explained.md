---
title: "Software RDMA: rxe and siw — Explained"
category: explained
original: "[[soft-rdma-rxe-and-siw]]"
subsystem: rdma
tags: [explained, rdma, rxe, siw, soft-roce]
converted: 2026-09-26
---

# Software RDMA (rxe and siw), explained

> Plain-language companion to [[soft-rdma-rxe-and-siw|the technical note]]. Same facts, fewer identifiers.

## The problem

RDMA applications and kernel users need an RDMA device, but RDMA cards are expensive and absent from laptops, CI runners, many cloud VMs, and often from one end of a mixed link. Linux ships two **software RDMA providers** that implement the full verbs interface in the kernel on top of any ordinary Ethernet interface:
- **rxe (Soft-RoCE):** speaks RoCE v2, so it can talk to hardware RoCE cards
- **siw (soft-iWARP):** speaks iWARP over an ordinary kernel TCP socket, so it can talk to hardware iWARP cards

They register as normal RDMA devices, so libraries, NVMe-oF, NFS/RDMA and the rest work unchanged. They give the RDMA *API* and one-sided semantics, not RDMA *performance*: the CPU does all the work a card would.

## The idea in one paragraph

A hardware RDMA card is **a dedicated courier company** with its own trucks: your CPU hands off a parcel and forgets it. rxe and siw are **the same courier brand run from your own garage**. The paperwork (verbs, work requests, completions, keys) is identical and the recipient can't tell the difference, but every delivery is driven by your own CPU in kernel threads, on public roads (the kernel's UDP or TCP stack) instead of a private lane. Perfect for rehearsals and for talking to a real courier at the other end; useless when you need the CPU for other work.

## Step by step

### Step 1: Create a device
An administrator runs `rdma link add rxe0 type rxe netdev eth0` (or `type siw`). The provider creates an RDMA device with **no DMA device**, so the "DMA addresses" in requests and registrations are plain kernel virtual addresses; the "device" is the CPU. It binds to the interface and registers. For rxe, the RoCE address table then fills from the interface's IPs as for any RoCE port. Deleting the interface or the link unregisters the device, and user processes are disassociated.

### Step 2: The user-space data path
The user libraries keep rings in shared memory mapped from the kernel, so polling completions is still just a memory read, and receive buffers can be posted without a system call. But with no hardware to watch a doorbell, **posting a send ends in a system call** that kicks the kernel's send engine.

### Step 3: rxe's three engines
Each rxe queue pair has three work items (originally tasklets, converted to workqueues so they may sleep, which on-demand paging needs):
- **requester:** walks the send queue, splits each request into MTU-sized packets, builds the InfiniBand transport headers, copies payload from the source memory region (faulting pages in for on-demand regions), and transmits
- **responder:** handles incoming requests: checks sequence order, validates the key, protection domain and access rights for writes, reads and atomics, copies into or out of the target region, sends acknowledgements and read responses, and consumes receive buffers for sends, following the InfiniBand rules for duplicates and ordering
- **completer:** handles acknowledgements, negative acknowledgements and read responses for the requester side, runs retransmit and receiver-not-ready timers, and posts completions

### Step 4: rxe on the wire
rxe opens a kernel **UDP tunnel socket** on port 4791 in each network namespace. Incoming datagrams to that port are diverted straight into rxe, which checks the invariant CRC (computed in software) and hands the packet to the right queue pair's responder or completer. Outgoing packets get IP and UDP headers from the path's address and go through the host's **IP output path**, including routing, netfilter and queueing disciplines, all of which hardware RoCE bypasses. InfiniBand multicast maps to IP multicast. Features include all three queue-pair services, shared receive queues, memory windows, atomics, flush for persistent memory, and **software on-demand paging** (6.x, Daisuke Matsuda), where rxe checks page validity itself and faults pages in before copying.

### Step 5: siw connections
iWARP connections are TCP connections. siw creates a kernel TCP socket, connects, exchanges the iWARP handshake frames (carrying private data and negotiating CRCs), then hooks the socket so it's told when data arrives. The port-mapper daemon coordinates port numbers with the host TCP stack.

### Step 6: siw receive and transmit
This is the key step for siw. When TCP has data, siw parses iWARP segments **directly out of the TCP receive queue**: tagged segments (writes, read responses) go straight to their target region and offset, untagged ones (sends) into the next receive buffer, and the CRC is checked if negotiated. Data lands in its final place even though it came over a byte stream. To transmit, a posted request is processed inline or handed to a **per-CPU transmit thread**, which builds iWARP frames and sends them with a **zero-copy** TCP send that references the region's pages rather than copying (falling back to copying when it must), pausing when the socket's buffer fills. Optionally, both ends can agree on segmentation-offload-sized frames to cut per-segment overhead.

## The picture

```text
 app (librxe/libsiw) ─ post send ─ SYSCALL (no hardware doorbell) ─▶ kernel engine
 rxe: requester → IB headers → UDP:4791 → IP stack (routing, netfilter, qdisc) → NIC
      NIC → UDP tunnel socket → rxe: check ICRC → responder / completer → completion
 siw: TCP socket ─ data ready ─▶ parse iWARP segments in place → place at region+offset
      transmit thread → frames → zero-copy TCP send (pages referenced, not copied)
 peer can be a real hardware RoCE / iWARP card
```

## Tradeoffs

- **What it gives you:** the full RDMA API on any Ethernet interface; interoperability with hardware peers, so a server with an RDMA card can serve many clients without one while still getting offload on its own side; a basis for RDMA tests and CI.
- **What it costs / requires:** the client CPU does all per-packet work, CRCs and copies (rxe copies payload into packets; siw can avoid copies on transmit); a system call per post makes small-message rates poor. With no real DMA device they can't take part in peer-to-peer or dma-buf flows or the IOMMU-based paths.
- **Where it bites:** RoCE v2 assumes a lossless fabric, and rxe has only InfiniBand-style go-back retransmission, so it does badly under loss. siw rides TCP and inherits its congestion control and loss recovery, making it the more robust software option on lossy networks. rxe only does v2, so peers must use v2.

## How it got here

- **4.8 (2016):** rxe merged (from System Fabric Works; now maintained by Zhu Yanjun).
- **5.3 (2019):** siw merged (Bernard Metzler, IBM Zurich) after two years of revisions questioning the value of software iWARP and asking for clean use of core TCP interfaces.
- **5.x:** rxe memory windows, atomic write and flush; siw segmentation offload and CRC options; many fuzzing-driven fixes.
- **6.2–6.x:** rxe moves to workqueues and gains on-demand paging, then per-namespace sockets; siw switches to the page-splicing zero-copy send (6.5).

## Related

- Technical version: [[soft-rdma-rxe-and-siw]]
- [[rdma-explained|RDMA subsystem]], [[roce-v1-and-v2-explained|RoCE v1 and v2]], [[iwarp-transport-explained|iWARP]], [[on-demand-paging-odp-explained|On-demand paging]], [[roce-gid-table-and-netdev-binding-explained|RoCE GID table]]
- [[tcp-ip-stack-explained|TCP/IP stack]]
