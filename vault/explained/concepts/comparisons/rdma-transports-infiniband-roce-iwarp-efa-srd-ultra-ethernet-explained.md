---
title: "RDMA Transports Compared: InfiniBand vs RoCE vs iWARP vs EFA SRD vs Ultra Ethernet — Explained"
category: explained
original: "[[rdma-transports-infiniband-roce-iwarp-efa-srd-ultra-ethernet]]"
subsystem: comparisons
tags: [explained, comparison, rdma, roce, ultra-ethernet]
converted: 2026-09-26
---

# RDMA transports compared, explained

> Plain-language companion to [[rdma-transports-infiniband-roce-iwarp-efa-srd-ultra-ethernet|the technical note]]. Same facts, fewer identifiers.

## The problem

"RDMA" is a **programming model**. Applications register memory, post work to queues, let the network card read and write remote memory directly, and collect completions, with no kernel on the data path ([[verbs-api-and-uverbs-explained|verbs]]). The model says nothing about what goes on the wire. At least five different transports carry it today.

The differences between them decide whether RDMA works at scale:
- **what the network must guarantee**: does it have to never drop packets?
- **how lost packets are recovered**: resend everything after the loss, only the missing packets, or leave it to TCP
- **whether data must arrive in order**, which decides whether one flow can be spread across many network paths
- **how many connections** a job of many nodes and processes needs
- **how Linux represents it**: an ordinary RDMA device, a vendor-specific extension, or something new.

## The idea in one paragraph

Picture sending a long document across a city as numbered pages. **InfiniBand** is a private railway with signals that never let a train leave unless the next station has room, so nothing is lost and pages can be required to arrive in order. **RoCE** runs the same trains on public roads, either by adding traffic lights everywhere to prevent loss (which can gridlock) or by teaching the trains to cope with the odd lost page. **iWARP** puts every page in registered mail (TCP), and each page says exactly where it goes in the binder. **AWS's SRD** sends pages by many couriers over up to 64 routes at once and resends missing ones within microseconds, but the receiver must not care about order. **Ultra Ethernet** standardises SRD's idea for everyone and adds a menu of ordering options.

## Step by step

### Step 1: InfiniBand, the reference design
InfiniBand is a complete network with its own links, switches, addresses and management. Its defining property is **credit-based flow control**: a sender only transmits when the receiver has said it has buffer space, so **congestion never causes packet loss**.

The transport was built on that assumption. Reliable connections recover the rare corrupted packet by **going back and resending from the lost packet onward**. That is simple, and cheap when loss almost never happens. A central **Subnet Manager** discovers the topology, hands out addresses and programs the switches ([[mad-and-subnet-administration-explained|subnet management]]).

InfiniBand offers several connection types: reliable connected (everything, in order), unreliable connected, unreliable datagram (one queue talks to many peers, one packet per message), and variants that share receive resources. NVIDIA's "dynamically connected" type cuts the number of queues all-to-all jobs need. In Linux, InfiniBand is the original RDMA stack (2005), and every other transport plugs into the same core ([[rdma-explained|RDMA subsystem]]).

### Step 2: RoCE, the InfiniBand transport on Ethernet
RoCE keeps InfiniBand's transport **exactly as it is** and replaces the layers below it ([[roce-v1-and-v2-explained|RoCE v1 and v2]]). Version 1 is Ethernet-only. Version 2 wraps packets in UDP/IP so they can be routed, and varies the UDP source port per connection so switches spread connections across paths. Because RoCE addresses are tied to Linux network interfaces, namespaces, VLANs and bonding all work.

The hard part is the network. "Go back and resend everything" performs terribly on a lossy network, so classic RoCE builds **lossless Ethernet**: pause frames on a dedicated priority, plus congestion notifications that throttle each sender ([[roce-congestion-control-pfc-ecn-dcqcn-explained|PFC, ECN and DCQCN]]). Pause frames bring their own problems: congestion spreading to innocent flows, pause storms and deadlocks. So newer NICs support **lossy RoCE**, which resends only the missing packets and relies on congestion signals alone. RoCE is supported by many NIC drivers, and Linux also has a pure software version ([[soft-rdma-rxe-and-siw-explained|rxe and siw]]).

### Step 3: iWARP, RDMA semantics on top of TCP
iWARP takes the opposite approach: **keep TCP's reliability and congestion control** and add RDMA placement on top ([[iwarp-transport-explained|iWARP]]). Every segment carries its own destination address in the target buffer, so **segments that arrive out of order can be placed immediately**, while completions are still reported in order. It runs on any ordinary IP network, with no special switch configuration.

The costs come from TCP. The NIC needs a full TCP engine. It shares the host's IP addresses, so a helper daemon reserves ports to avoid clashes with the host's own TCP stack. It only supports reliable connections, and RDMA reads need extra memory registration. iWARP has lost ground to RoCE in data centres, but it remains the "works on any network" option.

### Step 4: AWS SRD, reliable but unordered, across many paths
AWS found that reliable connections over a single path suit cloud networks badly. Hash collisions create hotspots, one flow can only use one path, and lossless Ethernet isn't practical at AWS scale. Connection state also explodes: all-to-all communication with reliable connections needs a queue for every pair of processes on every pair of machines.

**SRD** (Scalable Reliable Datagram), built into AWS's Nitro card, makes three different choices. This is the key step, because it shows what dropping ordering buys.
- **Reliable, but not in order.** Without an ordering requirement, a single flow can be **sprayed across up to 64 paths**, and lost packets are resent within microseconds based on hardware round-trip measurements. AWS reported about 85% lower 99.9th-percentile latency than single-path TCP.
- **Datagram addressing.** Each request names its destination directly, and the NIC keeps the reliability state behind the scenes. A process needs roughly one queue per local process rather than one per remote peer.
- **Congestion control in the NIC**, per path, with no need for lossless Ethernet.

The price is in the programming model. SRD originally supported only small sends. Reordering, splitting large messages and matching messages to receives are left to the **libfabric** library, which is why HPC and ML jobs use AWS's EFA adapter through libfabric (and NCCL through a plugin) rather than raw RDMA calls. Later generations added one-sided reads and then writes. In Linux, EFA is an ordinary RDMA device exposing SRD as a vendor-specific queue type, and the kernel only handles setup.

### Step 5: Ultra Ethernet, a standard multipath RDMA transport
The **Ultra Ethernet Consortium** (most of the networking industry) published version 1.0 in June 2025. It is a **new transport, not a RoCE revision**, aimed at AI and HPC networks of up to about a million endpoints.
- **Operations** (send, tagged send, one-sided read and write, atomics) map directly onto libfabric rather than the classic RDMA API.
- **Delivery** is selectable: reliable ordered, reliable unordered (the default for bulk data, which allows spraying), reliable unordered for operations that are safe to repeat, and unreliable. Per-peer delivery state is **created on the first packet, with no handshake**, and dropped when idle, so state grows with *active* peers, not job size.
- **Congestion control** combines a sender-side algorithm with an optional receiver-granted credit scheme for many-to-one traffic, all designed around per-packet spraying.
- **Packet trimming**: a congested switch **cuts a packet down to its headers** instead of dropping it, so the receiver learns about the loss in one round trip rather than by timeout.
- **Built-in encryption** with per-job keys, and optional link-level features for operators who want lossless links.
- It runs over UDP/IP on standard Ethernet switches.

In Linux, a 2025 proposal (from Enfabrica, with several vendors contributing) added a software model of the delivery layer in a new driver directory, with its own netlink interface. As of 2026 it is not merged. Whether Ultra Ethernet belongs in the RDMA subsystem, in a new subsystem, or only in vendor NIC firmware is an open question.

### Step 6: Choosing
- **InfiniBand** when you control a dedicated fabric and want the most mature option.
- **RoCE** when you want InfiniBand's model on Ethernet and can run the network carefully, or have NICs that tolerate loss.
- **iWARP** when the network must be ordinary IP with no tuning.
- **SRD** on AWS, through libfabric.
- **Ultra Ethernet** for new AI and HPC fabrics built around multipath spraying, as hardware and software mature.

## The picture

```text
                  network must be        recovery            ordering        paths per flow
 InfiniBand       lossless (credits)     resend from loss    in order        1 (adaptive routing)
 RoCE             lossless (pause) or    resend from loss /  in order        1 per connection
                  lossy + smart NIC      only missing pkts
 iWARP            any IP network         TCP                 placed any      1 per TCP flow
                                                             order, done in
                                                             order
 EFA SRD          lossy OK               NIC, microseconds   unordered       up to 64
 Ultra Ethernet   lossy OK (optional     selective ack +     chosen per      every path
                  lossless links)        trimming            traffic class   (per packet)

      ◀── smart network, simple NIC ─────────────── simple network, smart NIC ──▶
```

## Tradeoffs

- **What it gives you:** one programming model across very different networks. The newer transports trade in-order delivery for multipath spraying, near-full network utilisation and far fewer connections.
- **What it costs / requires:** lossless designs push complexity into the network (pause storms, deadlocks, careful tuning). Loss-tolerant designs need smarter NICs, and unordered delivery pushes ordering and message matching up into libraries such as libfabric, MPI and NCCL.
- **Where it bites:** "RDMA works the same everywhere" is only true at the API level. Ordering guarantees, supported operations, connection limits and even which API to use (classic RDMA verbs or libfabric) differ by transport. Ultra Ethernet's place in the kernel is still undecided.

## How it got here

- **2000–2005:** InfiniBand specified and merged into Linux 2.6.11.
- **2007:** iWARP standards and the first Linux iWARP drivers.
- **2010–2016:** RoCE, then routable RoCE v2; congestion control for lossless Ethernet published in 2015.
- **2017–2020:** loss-tolerant RoCE; software iWARP merged; EFA driver merged (5.2); SRD described publicly in 2020.
- **2023–2025:** Ultra Ethernet Consortium founded; 1.0 specification (June 2025); first Linux proposal (March 2025); new vendor RDMA drivers (AMD Pensando).
- **2026:** specification updates; the kernel question still open.

## Related

- Technical version: [[rdma-transports-infiniband-roce-iwarp-efa-srd-ultra-ethernet]]
- [[rdma-explained|RDMA subsystem]], [[roce-v1-and-v2-explained|RoCE v1 and v2]], [[iwarp-transport-explained|iWARP]], [[roce-congestion-control-pfc-ecn-dcqcn-explained|RoCE congestion control]]
- [[queue-pairs-and-completion-queues-explained|Queue pairs and CQs]], [[mad-and-subnet-administration-explained|Subnet management]], [[soft-rdma-rxe-and-siw-explained|Software RDMA]], [[roce-gid-table-and-netdev-binding-explained|RoCE addressing]]
- [[memory-pinning-and-registration-strategies-explained|Memory pinning and registration]], [[io-uring-vs-rdma-explained|io_uring vs RDMA]]
