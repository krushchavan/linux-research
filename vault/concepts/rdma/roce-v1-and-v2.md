---
title: "RoCE v1 and v2"
category: concept
tags: [rdma, roce, ethernet, udp, datacenter-networking]
subsystem: rdma
kernel_version: "2.6.37 (RoCE v1 / IBoE in mlx4); 4.5 (RoCE v2)"
researched: 2026-09-26
status: complete
sources:
  - https://en.wikipedia.org/wiki/RDMA_over_Converged_Ethernet
  - https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/configuring_infiniband_and_rdma_networks/configuring-roce_configuring-infiniband-and-rdma-networks
  - https://enterprise-support.nvidia.com/s/article/introduction-to-resilient-roce---faq
  - https://www.cisco.com/c/en/us/td/docs/dcn/whitepapers/roce-storage-implementation-over-nxos-vxlan-fabrics.html
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_verbs.h
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/roce_gid_mgmt.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/cma.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/sw/rxe/rxe_net.c
---

# RoCE v1 and v2

## Purpose

**RoCE (RDMA over Converged Ethernet)** carries the InfiniBand transport layer (queue pairs, RDMA READ/WRITE, SEND, atomics, reliable delivery) over Ethernet instead of an InfiniBand fabric, so datacenters get RDMA's kernel-bypass, zero-copy, CPU-free data movement on the same switches and cables as everything else. There are two wire formats. **RoCE v1** (IBTA, 2010) puts IB packets straight into Ethernet frames and is confined to one L2 broadcast domain. **RoCE v2** (IBTA Annex A17, 2014) puts them inside UDP/IP, which makes RoCE routable across L3 fabrics and ECMP-balanced. RoCE v2 is now the dominant RDMA transport for storage (NVMe-oF), AI training clusters and cloud RDMA.

## Mental Model

InfiniBand defines a **letter format** (the Base Transport Header: which QP, which sequence number, which operation) and an **envelope system** (LRH/GRH: local and global routing addresses). RoCE keeps the letter and swaps the envelope:
- **v1** puts the letter plus IB's *global* envelope (GRH) directly in an Ethernet frame (ethertype `0x8915`). Delivery works only within the same building (L2 domain).
- **v2** throws away the IB envelope and uses **IP + UDP** instead (destination port **4791**). Any IP router can forward it, and switches can spread flows across paths by hashing the UDP source port.

Everything above the envelope (QPs, verbs, memory keys, the whole [[rdma]] API) is unchanged. That is why the kernel handles RoCE mostly as "InfiniBand with a different addressing layer": GIDs become IP addresses ([[roce-gid-table-and-netdev-binding]]) and the subnet manager is replaced by IP routing and ARP.

## How It Works

**Packet formats.**

```
InfiniBand:  | LRH | GRH (opt) | BTH | ext hdrs (RETH/AETH/…) | payload | ICRC | VCRC |
RoCE v1:     | Eth (0x8915) | GRH | BTH | ext hdrs | payload | ICRC | FCS |
RoCE v2:     | Eth | IPv4/IPv6 | UDP (dport 4791) | BTH | ext hdrs | payload | ICRC | FCS |
```

- The **BTH** (Base Transport Header, 12 bytes) carries opcode, destination QPN, PSN, P_Key, and ack-request bit. This is the heart of the IB transport, and the NIC's RC state machine runs on it identically in all three cases.
- **v1** always includes the 40-byte **GRH**, whose SGID/DGID are the IP-derived GIDs, while MAC addresses do L2 delivery. The LRH (LIDs) is dropped because Ethernet has no LIDs.
- **v2** maps GRH fields onto IP. SGID/DGID become IP source and destination (IPv4-mapped GIDs `::ffff:a.b.c.d` become real IPv4 headers). *Traffic class* becomes **DSCP + ECN**, *hop limit* becomes TTL, and *flow label* becomes the **UDP source port**.
- The **ICRC** (invariant CRC) covers fields that don't change hop by hop. In v2 the variant IP fields (TTL, DSCP/ECN, checksum) are masked out so routers and ECN marking don't invalidate it.

**UDP source port = entropy.** Because all RoCE v2 traffic shares destination port 4791, ECMP load balancing only works if the *source* port varies per flow. The kernel defines one convention every driver must use. `rdma_calc_flow_label(lqpn, rqpn)` folds the product of local and remote QPNs into a 20-bit flow label, symmetric so both ends compute the same value. `rdma_flow_label_to_udp_sport(fl)` folds that to 14 bits and ORs it into the valid range starting at `IB_ROCE_UDP_ENCAP_VALID_PORT_MIN` (0xC000). `rdma_get_udp_sport()` applies this when the application didn't set a flow label. The result is that each QP connection hashes to a stable path, and different connections spread across the fabric.

**Kernel representation.** Each port advertises which encapsulations it supports through core capability flags: `RDMA_CORE_CAP_PROT_ROCE` (v1) and `RDMA_CORE_CAP_PROT_ROCE_UDP_ENCAP` (v2), queried with `rdma_protocol_roce_eth_encap()` and `rdma_protocol_roce_udp_encap()`. The GID table gets one entry per address *per type*: `IB_GID_TYPE_ROCE` (v1) and `IB_GID_TYPE_ROCE_UDP_ENCAP` (v2). The GID type of the source entry chosen for a QP's path *is* the choice of v1 or v2 for that connection. `rdma_gid_attr_network_type()` derives `RDMA_NETWORK_ROCE_V1`, `RDMA_NETWORK_IPV4` or `RDMA_NETWORK_IPV6` from it, and drivers use that to build the right headers.

**Selecting the version.** For rdma_cm connections, `/sys/kernel/config/rdma_cm/<dev>/ports/<n>/default_roce_mode` (`IB/RoCE v1` or `RoCE v2`) decides which GID type `cma` picks when it resolves the source address. Raw verbs users choose explicitly by `sgid_index`. Both ends must use the same version: a v1 client can't talk to a v2 server (RHEL docs call this unsupported). Modern NICs default to v2.

**Where the headers get built.** For hardware RoCE the NIC builds everything from the QP's address vector (DMAC, VLAN, SGID index, traffic class) that the driver loaded at RTR. The core helps with `ib_ud_header_init()` (`ud_header.c`) for drivers that assemble UD and QP1 headers in software. The kernel's own **rxe** builds v2 packets completely in software: IP/UDP headers from the GID attribute, `ip_local_out()`, software ICRC (see [[soft-rdma-rxe-and-siw]]).

**L2 details the spec left open.** The IBTA spec doesn't define VLAN handling, GID-to-MAC resolution or multicast mapping. Linux resolves them like this:
- VLAN comes from the GID entry's `ndev` (a VLAN netdev gives a tagged frame)
- the destination MAC comes from the IP neighbour table during rdma_cm address resolution
- the source MAC is the netdev's
- multicast GIDs map to IP multicast MACs, with IGMP/MLD joins.

Because RoCE addresses are tied to netdevs, RoCE naturally respects network namespaces and bonding.

**The lossless-fabric question.** InfiniBand is credit-based and never drops packets, and the IB RC transport assumes that. Its recovery is **go-back-N**: on a sequence error, retransmit from the lost PSN, so one drop can resend a whole window. RoCE therefore traditionally needs a **lossless Ethernet** built with **PFC** (Priority Flow Control, 802.1Qbb: per-priority PAUSE) and ECN-based congestion control (**DCQCN**). v2 made ECN usable: switches mark the IP ECN bits, the receiver NIC returns **CNP** (Congestion Notification Packets, a BTH opcode), and the sender NIC throttles that QP. Later NICs add **Resilient RoCE**: v2 over *lossy* fabrics with ECN/DCQCN only and better loss recovery (selective repeat), avoiding PFC's head-of-line blocking and deadlock risks. See [[roce-congestion-control-pfc-ecn-dcqcn]].

**Performance.** Hardware RoCE v2 on 100–400 GbE achieves roughly 1–2 µs one-way latency for small RDMA WRITEs and line-rate bandwidth with near-zero host CPU, much like InfiniBand. The practical difference is in operations: getting a lossless or well-controlled Ethernet fabric right at scale.

## Key Data Structures

**`enum ib_gid_type`** (`include/rdma/ib_verbs.h`) — `IB_GID_TYPE_IB`, `IB_GID_TYPE_ROCE` (v1), `IB_GID_TYPE_ROCE_UDP_ENCAP` (v2).

**`enum rdma_network_type`** — `RDMA_NETWORK_IB`, `RDMA_NETWORK_ROCE_V1`, `RDMA_NETWORK_IPV4`, `RDMA_NETWORK_IPV6`: which headers go on the wire.

**`struct rdma_ah_attr` / `struct roce_ah_attr`** — address vector for a RoCE destination: `dmac`, plus GRH info (`sgid_attr`, `dgid`, `flow_label`, `traffic_class`, `hop_limit`).

**`struct ib_gid_attr`** — the source address choice, including `gid_type` and `ndev` ([[roce-gid-table-and-netdev-binding]]).

## Key Functions / Entry Points

- **`rdma_protocol_roce()` / `rdma_protocol_roce_eth_encap()` / `rdma_protocol_roce_udp_encap()`** — per-port capability checks
- **`rdma_calc_flow_label()` / `rdma_flow_label_to_udp_sport()` / `rdma_get_udp_sport()`** (`ib_verbs.h`) — ECMP entropy convention
- **`rdma_gid_attr_network_type()` / `ib_network_to_gid_type()`** — GID type ↔ network header type
- **`cma_resolve_iboe_route()`** (`cma.c`) — synthesizes a RoCE path (MTU from netdev, traffic class from ToS, GID type from default mode)
- **`ib_ud_header_init()` / `ib_ud_header_pack()`** (`ud_header.c`) — software header construction for UD/QP1
- **`rxe_prepare()` / `rxe_xmit_packet()`** (`sw/rxe/rxe_net.c`) — full software v2 encapsulation

## Important Flags & Config Options

- configfs `default_roce_mode` (per device/port): `IB/RoCE v1` | `RoCE v2`
- configfs `default_roce_tos` — ToS byte (DSCP + ECN) for rdma_cm connections, usually set to the lossless or ECN-enabled traffic class
- sysfs `ports/<n>/gid_attrs/types/<idx>` — shows each GID's version
- UDP destination port 4791 (IANA-assigned `ROCE_V2_UDP_DPORT`); source ports 0xC000–0xFFFF
- Vendor knobs (mlx5 via devlink or `mlnx_qos`): PFC priorities, trust DSCP, ECN enable, `roce_lossy`/selective repeat

## Interactions with Other Subsystems

- **↑ Userspace**: `ibv_query_gid_type()` / `ibv_query_gid_ex()`; perftest `-x <gid_index>` and `-R` (rdma_cm); `rdma link`
- **→ net**: IP routing and neighbour resolution for DMAC; netdev MTU caps RoCE path MTU (256–4096 bytes); VLAN/bond/netns via GID `ndev`; DCB (`dcbnl`) for PFC and ETS configuration
- **→ rdma_cm**: default mode, ToS, route synthesis ([[rdma-cm-connection-manager]])
- **← Congestion control**: ECN and CNP handling in NIC firmware ([[roce-congestion-control-pfc-ecn-dcqcn]])
- **vs iWARP**: iWARP runs RDMA over TCP, so it is lossy-tolerant and routable by design, at the cost of TCP state in the NIC ([[iwarp-transport]])
- **vs io_uring networking**: io_uring + TCP runs any NIC and any lossy network with the kernel stack's congestion control. RoCE needs RDMA NICs and fabric tuning, but moves data with zero host CPU on both ends

## Design Decisions & Tradeoffs

- **Reuse the IB transport unchanged.** This gave immediate software compatibility (verbs, ULPs, MPI) and hardware reuse (the same ConnectX silicon does IB and RoCE). It also inherited IB's assumption of a lossless network: go-back-N retransmission and small retry windows.
- **v1 L2-only → v2 UDP/IP.** v1 couldn't cross routers or use ECMP, which excluded it from modern L3 Clos fabrics. v2 costs 28–48 extra header bytes per packet, but gains routing, ECMP (via source port), ECN and standard IP tooling (DSCP, ACLs, monitoring).
- **Fixed destination port plus hashed source port.** Keeps middleboxes and ACLs simple while giving switches per-connection entropy. Some flows still collide (elephant flows on one path), which motivates adaptive routing and packet spraying in AI fabrics (and the Ultra Ethernet transport effort).
- **Lossless requirement vs operations.** PFC can cause head-of-line blocking, congestion spreading, pause storms and deadlock in loops. "Resilient RoCE" and vendor selective-repeat retransmission move RoCE towards lossy fabrics, blurring the old iWARP-vs-RoCE argument.
- **GIDs derived from IPs.** Integrates with Linux networking, but makes RoCE sensitive to IP address churn, which led to the GID table synchronization machinery.

## How It Has Evolved

- **2010** — IBTA RoCE (v1) annex; Linux 2.6.37 adds "IBoE" in mlx4 with MAC-derived GIDs
- **2014** — IBTA RoCE v2 (Annex A17)
- **4.5 (2016)** — RoCE v2 in the core: GID types, per-type GID entries, `default_roce_mode`, mlx4/mlx5 v2 support (Matan Barak, Moni Shoua)
- **4.x** — flow-label/UDP-source-port convention helpers; `default_roce_tos`; bnxt_re, qedr and hns join as RoCE providers
- **4.8** — rxe gives software v2
- **5.x–6.x** — more RoCE providers (irdma in RoCE mode, erdma, mana, ionic), LAG, per-netns RoCE with SR-IOV VFs; NIC firmware adds lossy-fabric recovery
- **2023–26** — AI fabrics push RoCE v2 at 400/800G with adaptive routing and spraying; the Ultra Ethernet Consortium defines a successor transport while RoCE v2 remains the deployed baseline

## Further Reading

- Wikipedia — [RDMA over Converged Ethernet](https://en.wikipedia.org/wiki/RDMA_over_Converged_Ethernet) (versions, header layout, comparison with iWARP)
- Red Hat — [Configuring RoCE (RHEL 8)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/configuring_infiniband_and_rdma_networks/configuring-roce_configuring-infiniband-and-rdma-networks)
- NVIDIA — [Introduction to Resilient RoCE FAQ](https://enterprise-support.nvidia.com/s/article/introduction-to-resilient-roce---faq)
- Cisco — [RoCE Storage Implementation over NX-OS VXLAN Fabrics](https://www.cisco.com/c/en/us/td/docs/dcn/whitepapers/roce-storage-implementation-over-nxos-vxlan-fabrics.html)
- Paper — Guo et al., "RDMA over Commodity Ethernet at Scale" (SIGCOMM 2016, Microsoft's RoCE v2 deployment: PFC deadlocks, pause storms)
- Related: [[rdma]], [[roce-gid-table-and-netdev-binding]], [[roce-congestion-control-pfc-ecn-dcqcn]], [[iwarp-transport]], [[soft-rdma-rxe-and-siw]]

## LKML Highlights

- **"Add RoCE v2 support" (Matan Barak, Mellanox, 2015; merged 4.5)** — introduced GID types, duplicated GID entries per type, and `default_roce_mode` in rdma_cm configfs. The review debated whether GID type belongs in the GID table or in the address handle. It ended in the table, making "which version" a property of the source address.
- **Flow-label / UDP source-port helpers (2019–20)** — made every driver use the same symmetric QPN-derived hash, so both directions of a connection take the same ECMP path and the entropy is consistent across vendors.
- **"IB/core: Add RoCE (IBoE) support" (Eli Cohen, 2010)** — the original mlx4 RoCE v1 enablement, mapping IB GIDs onto MAC and VLAN addressing. (Message-ids unavailable: lore was unreachable this session.)
