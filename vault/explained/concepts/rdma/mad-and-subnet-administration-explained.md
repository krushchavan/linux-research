---
title: "MADs and Subnet Administration — Explained"
category: explained
original: "[[mad-and-subnet-administration]]"
subsystem: rdma
tags: [explained, rdma, infiniband, management, subnet-manager]
converted: 2026-09-26
---

# Management datagrams and subnet administration, explained

> Plain-language companion to [[mad-and-subnet-administration|the technical note]]. Same facts, fewer identifiers.

## The problem

An InfiniBand fabric has no DHCP, ARP or IP-style routing protocols. It's configured and queried **in-band**, with small fixed-size (256-byte) **management datagrams (MADs)** sent to two reserved queue pairs on every port. One carries subnet-management packets, which a **subnet manager** (OpenSM, or one built into a switch) uses to discover the topology, assign local addresses (LIDs) and program switch forwarding tables. The other carries everything else: connection setup, **subnet administration** queries for paths and multicast groups, performance counters and vendor traffic. Many independent programs, in the kernel and in user space, need to share those two queue pairs safely.

## The idea in one paragraph

The MAD layer is **the building's mailroom for management mail**. Each port has two mail slots: one for the landlord's structural notices, one for general mail. Tenants (the connection manager, the subnet-administration client, OpenSM, diagnostic tools) register which **class** of mail they handle. Outgoing mail gets a **tracking number**; the mailroom keeps a copy, re-sends it if no reply comes in time, and matches replies back to the sender. Oversized letters, such as full table dumps, are split into numbered pages and reassembled.

## Step by step

### Step 1: Open the special queues
When an InfiniBand port appears, the kernel creates both special queue pairs, posts receive buffers and brings them up. On **RoCE** ports there's no subnet manager and no subnet-management queue, but the general one still exists, because connection setup is still done with MADs, carried in Ethernet (v1) or UDP (v2).

### Step 2: Register an agent
A consumer registers for a management class and version, plus the request methods it wants to receive (the connection manager takes connection messages; a performance agent takes counter queries). Incoming *requests* are routed by class, version and method. Each agent also gets its own prefix for transaction IDs, so *replies* to its requests find it regardless of class. Access to subnet-management traffic is checked by security modules (SELinux can decide who may send those packets).

### Step 3: Send and wait
An agent builds a MAD, addresses it, and posts it. If it expects a reply, the MAD waits on a list with a timeout and retry count; unanswered MADs are resent, and eventually fail with a timeout. **Directed-route** packets, which the subnet manager uses before addresses exist and which travel hop by hop by port number, get special handling, and one addressed to the local port never leaves the machine.

### Step 4: Receive and dispatch
Incoming MADs are validated. The driver may answer some itself first (some cards answer counter or management queries in firmware). Then a **reply** goes to the agent whose transaction prefix matches, completing its waiting send, and a **request** goes to the agent registered for that class and method. Unmatched requests get an automatic "unsupported" answer or are dropped.

### Step 5: Flow control
This is the key step for very large clusters. When thousands of nodes query the subnet administrator or connect at once, replies to a node's own requests can overflow its fixed-size receive queue. So each agent may only have a limited number of reply-expecting requests outstanding (a quarter of the receive queue for most classes, one thirty-second for subnet administration); extra sends wait on a backlog until earlier ones finish (added in 2025).

### Step 6: Big replies
Table dumps (all paths, all multicast groups) don't fit in 256 bytes. The **Reliable Multi-Packet Protocol** splits them into numbered segments with a sliding window, acknowledgements and retransmission, and reassembles them before the agent sees one large buffer.

### Step 7: Subnet administration
The kernel's client asks the subnet administrator for **path records** (source and destination addresses, partition, service level, MTU, rate, lifetime), which the RDMA connection manager uses to set up connections, and for **multicast** membership (for IPoIB and datagram users), plus service and capability records. It remembers where the subnet manager is and refreshes when it changes. Because large fabrics can overwhelm the subnet manager with path queries, path lookups can be handed over netlink to a **user-space resolver cache** (ibacm), falling back to the subnet administrator on timeout. Multicast joins are reference-counted, so several kernel users share one membership, and re-joined after subnet-manager changes.

### Step 8: User-space access
A per-port device lets user space register agents and read and write whole MADs; OpenSM, ibnetdiscover, perfquery, smpquery, ibdiagnet and ibacm all use it. A second per-port device is the "I am the subnet manager" lock: while a process holds it open, the port advertises that a subnet manager lives there.

## The picture

```text
 port: [QP0: subnet management]   [QP1: general services]
 agents: connection manager (CM class)   SA client   perf agent   OpenSM via user device
 send: MAD + transaction ID ─▶ wait list (timeout, retries) ─ reply? match ID → agent
 receive request: validate → driver first? → agent for class/version/method
 big replies: segmented + windowed (RMPP) → reassembled
 flow control: ≤ ¼ (SA: 1/32) of receive queue outstanding, rest on backlog
```

## Tradeoffs

- **What it gives you:** a central subnet manager computing deterministic, deadlock-free routes for HPC topologies, and safe sharing of the management queues among many kernel and user agents, with retries, segmentation and access control.
- **What it costs / requires:** the subnet manager and administrator become a scalability bottleneck and single point of control, hence path caching and flow control. Fixed 256-byte MADs are simple but need segmentation for big replies; Intel Omni-Path later extended them to 2 KB.
- **Where it bites:** connection storms and path-query floods on huge clusters overflowed receive queues until 2025's flow control. RoCE keeps the connection protocol but drops the subnet manager, so addressing there comes from IP instead.

## How it got here

- **2.6.11:** MAD layer, subnet-administration client and user access (OpenIB).
- **2.6.1x:** multi-packet protocol and the multicast module.
- **4.x:** path-query offload to ibacm (Kaike Wan, 2015); Omni-Path jumbo MADs; SELinux InfiniBand hooks (Dan Jurgens, 4.13).
- **2025:** per-agent flow control and backlog for very large clusters.

## Related

- Technical version: [[mad-and-subnet-administration]]
- [[rdma-explained|RDMA subsystem]], [[rdma-cm-connection-manager|Connection manager]], [[ib-device-and-client-model-explained|Device and client model]], [[queue-pairs-and-completion-queues-explained|Queue pairs and CQs]]
