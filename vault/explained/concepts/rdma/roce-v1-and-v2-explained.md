---
title: "RoCE v1 and v2 — Explained"
category: explained
original: "[[roce-v1-and-v2]]"
subsystem: rdma
tags: [explained, rdma, roce, ethernet, udp]
converted: 2026-09-26
---

# RoCE v1 and v2, explained

> Plain-language companion to [[roce-v1-and-v2|the technical note]]. Same facts, fewer identifiers.

## The problem

RDMA's kernel bypass, zero copies and CPU-free data movement originally required an InfiniBand fabric: its own switches, cables and management. Datacenters wanted the same thing on the Ethernet they already run. **RoCE** (RDMA over Converged Ethernet) carries the InfiniBand transport (queue pairs, reads, writes, sends, atomics, reliable delivery) over Ethernet. Its first version couldn't cross routers; the second can, and it's now the dominant RDMA transport for storage (NVMe-oF), AI training clusters and cloud RDMA.

## The idea in one paragraph

InfiniBand defines a **letter format** (the transport header: which queue pair, which sequence number, which operation) and an **envelope system** (its own local and global routing headers). RoCE keeps the letter and swaps the envelope. **v1** puts the letter plus InfiniBand's global envelope straight into an Ethernet frame, so delivery only works inside one building (one layer-2 domain). **v2** throws the InfiniBand envelope away and uses **IP plus UDP** (destination port **4791**), so any router can forward it and switches can spread flows over paths by hashing the UDP source port. Everything above the envelope (queue pairs, verbs, memory keys, the whole RDMA API) is unchanged.

## Step by step

### Step 1: The formats
- **InfiniBand:** local routing header, optional global header, transport header, extension headers, payload, two CRCs.
- **RoCE v1:** Ethernet (its own ethertype), global header, transport header, extensions, payload, invariant CRC. The local routing header is dropped; Ethernet MACs deliver instead.
- **RoCE v2:** Ethernet, IPv4 or IPv6, UDP to port 4791, transport header, extensions, payload, invariant CRC.

The 12-byte transport header (operation, destination queue pair, sequence number, partition, ack request) is the heart of it, and the card's reliable-connection engine runs on it identically in all three.

### Step 2: How v2 maps the InfiniBand fields onto IP
Source and destination GIDs become IP addresses (IPv4-mapped GIDs become real IPv4 headers), the traffic class becomes **DSCP and ECN**, the hop limit becomes the TTL, and the flow label becomes the **UDP source port**. The invariant CRC skips fields routers change (TTL, DSCP/ECN, IP checksum), so routing and ECN marking don't invalidate it.

### Step 3: The source port is the load-balancing entropy
This is the key step for large fabrics. All RoCE v2 traffic uses destination port 4791, so equal-cost multipath hashing only spreads load if the **source** port varies per connection. The kernel defines one convention every driver uses: combine the local and remote queue numbers into a 20-bit flow label, symmetric so both ends compute the same value, then fold it into the source-port range starting at 0xC000. Each connection sticks to one stable path, and different connections spread across the fabric.

### Step 4: How the kernel represents the choice
Each port advertises which encapsulations it supports, and the address table holds one entry per address per type. **The type of the source address chosen for a connection *is* the choice of v1 or v2**; drivers derive "RoCE v1, IPv4 or IPv6 headers" from it. For connection-manager users, a configured default mode per port decides which type is picked; raw verbs users choose by address index. Both ends must use the same version, and modern cards default to v2.

### Step 5: Building packets
Hardware cards build all headers from the queue pair's address details (destination MAC, VLAN, source address index, traffic class) loaded when it became ready to receive. The core helps drivers that assemble datagram and management headers in software. The software provider **rxe** builds v2 packets entirely in software, sending them through the IP stack with a software CRC.

### Step 6: The details the spec left open
The specification doesn't say how to handle VLANs, find destination MACs, or map multicast. Linux answers: the VLAN comes from the network interface tied to the source address; the destination MAC from the IP neighbour table during address resolution; the source MAC from the interface; multicast GIDs map to IP multicast MACs with IGMP/MLD joins. Because RoCE addresses belong to interfaces, RoCE naturally respects network namespaces and bonding.

### Step 7: The lossless question
InfiniBand never drops packets, and its transport assumes that: on a sequence error it resends everything from the lost packet onward, so one drop can resend a whole window. RoCE therefore traditionally needs **lossless Ethernet** built with priority flow control, plus ECN-based congestion control (DCQCN), which v2 makes possible because switches can mark the IP ECN bits. Later cards add **Resilient RoCE**: v2 over *lossy* fabrics with ECN control only and better loss recovery (selective repeat), avoiding flow control's head-of-line blocking and deadlock risks.

### Step 8: Performance
Hardware RoCE v2 at 100–400 Gb/s achieves roughly 1–2 µs one-way latency for small writes and line-rate bandwidth with near-zero host CPU, much like InfiniBand. The practical difference is operational: getting a lossless or well-controlled Ethernet fabric right at scale.

## The picture

```text
 InfiniBand: [LRH][GRH][BTH][ext][payload][ICRC][VCRC]
 RoCE v1:    [Eth 0x8915][GRH][BTH][ext][payload][ICRC][FCS]          one L2 domain
 RoCE v2:    [Eth][IP (DSCP/ECN, TTL)][UDP sport=hash(QPNs) dport=4791][BTH][ext][payload][ICRC][FCS]
                                                  │ routable, ECMP-balanced, ECN-markable
 connection's version = type of chosen source GID (default mode per port)
```

## Tradeoffs

- **What it gives you:** RDMA on standard Ethernet with the full InfiniBand software stack (verbs, upper layers, MPI) unchanged, and the same card silicon for both; v2 adds routing, multipath, ECN and standard IP tools (DSCP, ACLs, monitoring) for 28–48 extra header bytes per packet.
- **What it costs / requires:** it inherits InfiniBand's assumption of a lossless network, so fabrics need flow control and congestion control tuned carefully, or cards with lossy-fabric recovery. Addresses derived from IPs make RoCE sensitive to address churn, hence the address-table synchronisation machinery.
- **Where it bites:** a fixed destination port with a hashed source port keeps middleboxes simple but still lets big flows collide on one path, which motivates adaptive routing, packet spraying and the Ultra Ethernet effort in AI fabrics. Flow control can cause head-of-line blocking, congestion spreading, pause storms and deadlocks, and lossy-fabric recovery blurs the old iWARP-versus-RoCE argument.

## How it got here

- **2010:** RoCE v1 standardised; Linux 2.6.37 adds it ("IBoE") to mlx4 with MAC-derived addresses (Eli Cohen).
- **2014:** RoCE v2 standardised.
- **4.5 (2016):** v2 in the kernel core: address types, per-type entries, default mode (Matan Barak, Moni Shoua); review settled that the version is a property of the source address.
- **4.x:** the flow-label/source-port convention, default type-of-service, more providers; **4.8:** software v2 with rxe.
- **5.x–6.x:** more providers (irdma, erdma, mana, ionic), bonding, per-namespace RoCE with SR-IOV; lossy-fabric recovery in firmware.
- **2023–2026:** AI fabrics push v2 to 400/800 Gb/s; Ultra Ethernet defines a successor while v2 remains the deployed baseline.

## Related

- Technical version: [[roce-v1-and-v2]]
- [[rdma-explained|RDMA subsystem]], [[roce-gid-table-and-netdev-binding-explained|RoCE GID table]], [[roce-congestion-control-pfc-ecn-dcqcn-explained|RoCE congestion control]], [[iwarp-transport-explained|iWARP]], [[soft-rdma-rxe-and-siw|rxe and siw]], [[rdma-cm-connection-manager-explained|Connection manager]]
