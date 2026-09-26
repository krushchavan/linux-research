---
title: "RDMA Transports Compared: InfiniBand vs RoCE vs iWARP vs EFA SRD vs Ultra Ethernet"
category: concept
tags: [comparison, rdma, infiniband, roce, iwarp, ultra-ethernet]
subsystem: comparisons
kernel_version: "InfiniBand 2.6.11; iWARP 2.6.19; RoCE v1 3.0 / v2 4.5; EFA 5.2; Ultra Ethernet RFC 2025 (drivers/ultraeth, not merged)"
researched: 2026-09-26
status: complete
explained: "[[rdma-transports-infiniband-roce-iwarp-efa-srd-ultra-ethernet-explained]]"
sources:
  - https://lwn.net/Articles/1013363/
  - https://lwn.net/Articles/786036/
  - https://lwn.net/Articles/773973/
  - https://lwn.net/Articles/1033763/
  - https://lwn.net/Articles/856287/
  - https://github.com/amzn/amzn-drivers/blob/master/kernel/linux/efa/SRD.txt
  - https://assets.amazon.science/a6/34/41496f64421faafa1cbe301c007c/a-cloud-optimized-transport-protocol-for-elastic-and-scalable-hpc.pdf
  - https://blog.ipspace.net/2022/12/quick-look-aws-srd/
  - https://ultraethernet.org/wp-content/uploads/sites/20/2026/01/UE-Specification-1.0.2-1.pdf
  - https://blogs.arista.com/blog/demystifying-ultra-ethernet
  - https://blog.viavisolutions.com/2025/08/13/inside-ue-1-0-what-ultra-ethernet-means-for-ai-and-hpc-networks/
  - https://lists.openwall.net/netdev/2025/03/12/69
  - https://docs.nvidia.com/networking/display/RDMAAwareProgrammingv17/Key+Concepts
---

# RDMA Transports Compared: InfiniBand vs RoCE vs iWARP vs EFA SRD vs Ultra Ethernet

> 📘 Plain-language version: [[rdma-transports-infiniband-roce-iwarp-efa-srd-ultra-ethernet-explained]]

> Comparison note under `comparisons/`. Deep dives: [[rdma]], [[roce-v1-and-v2]], [[iwarp-transport]], [[roce-congestion-control-pfc-ecn-dcqcn]], [[queue-pairs-and-completion-queues]], [[mad-and-subnet-administration]], [[soft-rdma-rxe-and-siw]]. Related comparisons: [[io-uring-vs-rdma]], [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk]].

## Purpose

"RDMA" names a *programming model*: registered memory, queue pairs, one-sided READ/WRITE, completions without the kernel on the data path ([[verbs-api-and-uverbs]]). It does not name a wire protocol. At least five transports carry that model today, and they differ in the things that decide whether RDMA works at scale:

- **what the network below must guarantee** (lossless or lossy)
- **how reliability is recovered** (go-back-N, selective repeat, TCP)
- **whether ordering is required**, which decides whether traffic can be sprayed across many paths
- **how many connections** a job of N nodes × p processes needs
- **how the Linux kernel represents it** (a verbs device, a vendor QP type, or a new subsystem).

InfiniBand defined the model in 1999–2000. RoCE and iWARP ported it onto Ethernet in two opposite ways. AWS's SRD and the Ultra Ethernet Transport (UET) are the cloud and AI-era answers to the scaling limits that RC over a single path runs into.

## Mental Model

Shipping a long document across a city as numbered pages:

- **InfiniBand**: a **private railway** with a signal system (credit-based flow control) that never lets a train leave unless the next station has room. Nothing is ever lost, so the receiver can insist pages arrive in order, and one dispatcher (the Subnet Manager) plans every route.
- **RoCE**: the same trains on the **public road network**. Either the roads are made "lossless" with traffic lights at every junction (PFC), which can gridlock, or the trains learn to cope with the occasional lost page (Resilient RoCE, selective repeat).
- **iWARP**: put every page in a **registered-mail envelope (TCP)**. The postal service handles losses and congestion, and each page says exactly where it goes in the binder (DDP), so it can be filed on arrival even out of order.
- **EFA SRD**: **send the pages by many couriers along up to 64 routes at once**, retransmit any that go missing within microseconds, and let the receiver reassemble. The receiver must not care about order.
- **Ultra Ethernet**: SRD's idea **standardised for everyone**, with a menu of ordering modes, trimmed "headers-only" packets instead of silent drops, and connections that exist only while traffic flows.

## How It Works

### 1. InfiniBand: the reference design

InfiniBand is a complete fabric: its own link layer, switches, addressing (16-bit **LIDs** within a subnet, 128-bit **GIDs** across subnets) and management plane. Its key property is **credit-based link-level flow control**: a sender transmits only when the receiver has advertised buffer credits, so **congestion never causes packet loss**. The transport (the **BTH** header, packet sequence numbers, ACK/NAK) was designed assuming that. Reliable Connected (RC) QPs recover the rare corruption loss with **go-back-N**, resending from the lost PSN, which is cheap when losses are almost nonexistent.

A **Subnet Manager** (OpenSM, or a switch-embedded SM) discovers the topology via **MADs** on QP0, assigns LIDs and programs switch forwarding tables. Consumers query it for path records via Subnet Administration on QP1 ([[mad-and-subnet-administration]]). Routing is deterministic per destination LID. Adaptive routing on modern NVIDIA Quantum switches adds per-packet path choice, relying on NIC-side reordering support.

**QP types**: RC (reliable, ordered, all ops including READ and atomics), UC (unreliable connected, WRITE/SEND), UD (unreliable datagram, SEND only, MTU-sized, one QP talks to many), and **XRC** (shares receive resources across processes on a node). NVIDIA's **DC** (Dynamically Connected, mlx5-only vendor QP type) is a reliable transport where a single initiator QP connects to targets on demand, cutting QP count for all-to-all jobs.

**In Linux**: the original stack (2.6.11, 2005). `ib_core`, `ib_mad`, `ib_cm`, IPoIB and drivers such as mlx5_ib live in `drivers/infiniband/`. Every other transport below plugs into this same verbs core. Cornelis Omni-Path (hfi1, moving to hfi2 in 2026) is an IB-verbs-compatible fabric with its own link layer and PSM2 userspace path.

### 2. RoCE: the InfiniBand transport over Ethernet

RoCE keeps the IB transport **unchanged** (BTH, PSNs, RC semantics, go-back-N) and swaps the lower layers ([[roce-v1-and-v2]]). **v1** (EtherType 0x8915) is L2-only. **v2** encapsulates in **UDP port 4791** over IPv4/IPv6, making it routable. The UDP source port is hashed from the QP numbers to give ECMP entropy per connection. The kernel represents RoCE addresses as GID-table entries bound to netdevs (so namespaces, VLANs and bonding work), and rdma_cm resolves peers through IP routing and the neighbour table. There is no Subnet Manager: CM MADs ride on QP1 inside UDP.

The hard part is the **network guarantee**. Go-back-N over a lossy network collapses throughput, so classic RoCE deployments build **lossless Ethernet**: PFC pause on a dedicated priority plus **ECN/DCQCN** congestion control, which throttles each QP's rate on CNPs ([[roce-congestion-control-pfc-ecn-dcqcn]]). PFC brings congestion spreading, head-of-line blocking, pause storms and deadlocks. Hence **Resilient/lossy RoCE**: NIC-side **selective repeat** and adaptive retransmission, with ECN-only congestion control and no PFC. Vendors layer on proprietary multipath (NVIDIA Spectrum-X adaptive routing with NIC reordering, Broadcom and AMD programmable congestion control).

**In Linux**: RoCE devices are ordinary verbs devices whose port link layer is Ethernet (`rdma_protocol_roce()`). Drivers include mlx5, bnxt_re, irdma (E810), qedr, hns, erdma, ionic (AMD Pensando, 2025) and mana (Microsoft). **rxe** implements RoCE v2 fully in software over any netdev ([[soft-rdma-rxe-and-siw]]).

### 3. iWARP: RDMA semantics over TCP

iWARP takes the opposite approach: **keep TCP/IP's reliability and congestion control** and add RDMA placement semantics on top ([[iwarp-transport]]). The IETF stack is **RDMAP** (operations) → **DDP** (each segment carries its target: STag + tagged offset, or queue/message number/offset) → **MPA** (framing into TCP with CRC32c). Because every segment is self-describing, **out-of-order TCP segments can be placed directly**, while completions are delivered in order. TCP handles loss, congestion and routing on any ordinary Ethernet, with **no PFC and no special switch configuration**.

The costs come from TCP. Hardware must implement a full TCP offload engine (Chelsio T-series, Intel E810/X722 via irdma, Marvell qedr). Connections share the host's IP address, so ports are arbitrated with the host stack through the **iwpmd** port mapper over netlink. The protocol is **RC-only** (no UD, multicast was never supported, and atomics came later via RFC 7306). RDMA READ sinks must be registered with remote-write STags, which makes `rdma_rw` always use MRs for reads on iWARP. Connection setup is TCP handshake plus MPA negotiation through `iw_cm` instead of IB CM MADs.

**In Linux**: `iw_cm`/`iwcm.c`, drivers iw_cxgb4, irdma, qedr, and **siw** (software iWARP over kernel TCP sockets). iWARP has lost market share to RoCE in data centres, but it remains the "works on any network" option, and siw is valuable for testing.

### 4. AWS EFA and SRD: reliable, unordered, multipath datagrams

AWS observed that RC over single-path ECMP handles cloud fabrics badly. Hash collisions create hotspots, a single flow is limited to one path, and PFC is not an option at AWS scale. Per-connection state also explodes: all-to-all with RC needs roughly **N × p²** QPs. **SRD (Scalable Reliable Datagram)**, implemented in the Nitro card, makes three different choices:

- **Reliable but out of order.** SRD guarantees at-most-once, reliable delivery but **does not preserve order**. Dropping the in-order requirement lets it **spray a single flow's packets across up to 64 paths** (varying the encapsulation's entropy), with retransmission in microseconds driven by hardware RTT measurement rather than millisecond TCP timers. AWS reported P99.9 latency reductions of about 85% versus single-path TCP.
- **Datagram addressing.** Like UD, each work request names its destination by an **Address Handle**. SRD reliability contexts are managed implicitly by the device, so a process needs roughly **p QPs instead of N × p²**.
- **Congestion control in the NIC**, per path, with no reliance on PFC.

The price is **semantic**: the SRD QP originally supported **only SEND** (MTU-sized, no segmentation), and upper layers must tolerate reordering. Message segmentation, tag matching and ordering are done by **libfabric's EFA provider**, which is why HPC and ML jobs use EFA through libfabric (with NCCL via aws-ofi-nccl) rather than raw verbs. Later EFA generations added **RDMA READ**, and then **RDMA WRITE**, with weak ordering semantics, which is what enables GPUDirect-style one-sided transfers on p4d/p5 instances. SRD also underlies EBS io2 Block Express and ENA Express, so the same transport carries storage and TCP traffic.

**In Linux**: `drivers/infiniband/hw/efa` (5.2, [LWN](https://lwn.net/Articles/786036/)). EFA is a verbs device exposing a **vendor QP type** (`EFA_QP_DRIVER_TYPE_SRD`) through `efadv_create_qp_ex()` alongside UD. The ENA netdev and the EFA device are separate PCI functions with no in-kernel coupling. The kernel handles control plane only (create QP/AH/MR/CQ, dma-buf MRs). The data path is entirely user-mapped.

### 5. Ultra Ethernet Transport (UET): a standardised, multipath-native RDMA transport

The **Ultra Ethernet Consortium** (AMD, Arista, Broadcom, Cisco, HPE, Intel, Meta, Microsoft and many others) published **UE 1.0 in June 2025** (1.0.x updates in 2026). It is a new transport, **not a RoCE revision**, designed for AI/HPC fabrics of up to ~1M endpoints. Its structure (per the spec and the kernel RFC):

- **Semantic sublayer (SES)**: RDMA-style operations (send, tagged send, one-sided read/write, atomics) mapped directly to the **libfabric 2.0** API rather than verbs. The Linux-facing software story is libfabric-first.
- **Packet Delivery Sublayer (PDS)**: reliability and ordering, selectable per traffic class: **ROD** (reliable ordered), **RUD** (reliable unordered, the default for bulk data, enabling spraying), **RUDI** (reliable unordered for idempotent operations, allowing cheaper recovery) and **UUD** (unreliable unordered). **Packet Delivery Contexts (PDCs)** are created **ephemerally** on the first packet, with no handshake round trip, and torn down when idle, so connection state scales with *active* peers rather than job size. Selective ACKs and coalescing are built in.
- **Congestion management (CMS)**: a **sender-based** algorithm (NSCC) pacing on ECN and delay signals, plus an optional **receiver-credit** scheme (RCCC) for incast. It is designed around **packet spraying**, varying entropy per packet so every flow uses every path.
- **Packet trimming**: a congested switch **truncates** a packet to its headers instead of dropping it and forwards it at high priority, so the receiver learns about a loss in one RTT instead of by timeout.
- **Transport security (TSS)**: built-in encryption and authentication with **group keys** per job.
- **Link layer (optional)**: link-level retry (LLR) and credit-based flow control (CBFC) as a PFC replacement for operators who want lossless links.
- UET runs over **IP/UDP** (IANA port **4793**) on standard Ethernet switches, with profiles (AI Base, AI Full, HPC) choosing subsets.

**In Linux (as of 2026)**: an RFC "Ultra Ethernet driver introduction" (Nikolay Aleksandrov, Enfabrica, with contributors from Broadcom, AMD, HPE, IBM, Cornelis and Keysight; March 2025, [LWN](https://lwn.net/Articles/1013363/)) proposed **`drivers/ultraeth/`** (`CONFIG_ULTRAETH`): a software **PDS** model implementing RUD with PSN tracking, retransmit, SACK and coalescing, **Fabric Endpoints (FEPs)**, **jobs** and **PDCs**, managed by a new **`ultraeth` YAML netlink family**, with a note that later versions would reuse InfiniBand infrastructure. Where UET belongs, whether as a new subsystem, a new transport under `drivers/infiniband` with libfabric on top, or purely in vendor NIC firmware exposed via verbs-like providers, is the open question for the kernel. Early UET NICs (AMD Pensando Pollara, Broadcom Thor Ultra) ship with vendor drivers first. The **ionic** RDMA driver (2025, [LWN](https://lwn.net/Articles/1033763/)) is the verbs side of that AMD hardware.

### 6. Side-by-side

| | InfiniBand | RoCE v2 | iWARP | EFA SRD | Ultra Ethernet (UET) |
|---|---|---|---|---|---|
| Wire | IB link + LRH/GRH + BTH | Eth/IP/UDP 4791 + BTH | Eth/IP/TCP + MPA/DDP/RDMAP | Nitro encapsulation (proprietary) | Eth/IP/UDP 4793 + PDS/SES |
| Network requirement | own lossless fabric (credits) | lossless (PFC) or ECN + selective repeat | any IP network | AWS fabric, lossy OK | standard Ethernet, lossy OK (optional LLR/CBFC) |
| Reliability | RC go-back-N | go-back-N (selective repeat on newer NICs) | TCP | NIC retransmit, µs RTO | PDS: SACK, trimming-driven fast loss detection |
| Ordering | in order (RC) | in order (RC) | in-order delivery, out-of-order placement | **unordered** | per mode: ROD / RUD / RUDI / UUD |
| Multipath | adaptive routing (switch + NIC) | ECMP per QP; vendor spraying | ECMP per TCP flow | **spray up to 64 paths** | **per-packet spraying by design** |
| Congestion control | credits + IB CC | DCQCN (ECN/CNP), vendor CC | TCP CC | per-path, in NIC | NSCC (sender) + RCCC (receiver credit) |
| Connection state | per QP pair (RC); XRC/DC to reduce | per QP pair | per TCP connection | implicit, ~p QPs per node | ephemeral PDCs, no handshake |
| One-sided ops | READ/WRITE/atomics | READ/WRITE/atomics | READ/WRITE (atomics RFC 7306) | SEND first; READ, later WRITE | read/write/atomics (SES) |
| Management | Subnet Manager, MADs | IP routing, rdma_cm | TCP + iwpmd | AWS control plane | IP; job/FEP model |
| Primary API | verbs | verbs | verbs | libfabric (efa provider) over verbs | libfabric 2.0 |
| Linux | `drivers/infiniband` core, mlx5 | same core, many drivers, rxe | `iw_cm`, cxgb4/irdma/qedr, siw | `hw/efa`, vendor QP type | RFC `drivers/ultraeth` + netlink (not merged) |

## Key Data Structures

**BTH (Base Transport Header)** — opcode, destination QPN, PSN, P_Key; shared by IB, RoCE v1 and v2, so one NIC transport engine serves all three.

**`struct ib_gid_attr`** (`include/rdma/ib_cache.h`) — GID type (`IB_GID_TYPE_IB`, `ROCE`, `ROCE_UDP_ENCAP`) and bound netdev; picks the transport encapsulation per connection.

**`struct iw_cm_id`** (`include/rdma/iw_cm.h`) — iWARP connection with `m_local_addr`/`m_remote_addr` (port-mapped addresses).

**EFA SRD QP** (`efadv_create_qp_ex`, `EFA_QP_DRIVER_TYPE_SRD`) — datagram QP with implicit reliability contexts; each WR carries an AH.

**UET PDC / FEP / job** (RFC `drivers/ultraeth/`) — packet delivery context (PSN space, retransmit state) between two fabric endpoints within a job, created on demand.

## Key Functions / Entry Points

- **`rdma_protocol_ib()` / `rdma_protocol_roce()` / `rdma_protocol_iwarp()`** (`include/rdma/ib_verbs.h`) — how ULPs branch on transport.
- **`rdma_get_udp_sport()` / `rdma_calc_flow_label()`** — RoCE v2 ECMP entropy.
- **`iw_cm_connect()` / `iw_cm_map()`** (`drivers/infiniband/core/iwcm.c`) — iWARP connect and port mapping.
- **`efa_create_qp()`** (`drivers/infiniband/hw/efa/efa_verbs.c`) — SRD/UD QP creation via admin queue.
- **`ib_register_mad_agent()`**, **`ib_sa_path_rec_get()`** — IB management plane.

## Important Flags & Config Options

- `CONFIG_INFINIBAND`, `CONFIG_MLX5_INFINIBAND`, `CONFIG_INFINIBAND_EFA`, `CONFIG_INFINIBAND_IRDMA`, `CONFIG_RDMA_RXE`, `CONFIG_RDMA_SIW`; proposed `CONFIG_ULTRAETH`.
- configfs `rdma_cm/<dev>/ports/N/default_roce_mode`, `default_roce_tos` (RoCE version and DSCP).
- DCB: `dcb pfc`, `dcb app` (DSCP trust), mlx5 `cc_params` debugfs (DCQCN).
- irdma `roce_ena` / devlink param selecting iWARP vs RoCE per port.
- QP attributes `rnr_retry`, `retry_cnt`, `timeout` — how RC tolerates loss and receiver starvation.

## Interactions with Other Subsystems

- **↑ Userspace**: libibverbs/rdma-core providers for all verbs transports; **libfabric** (efa, verbs, and UET providers), UCX, NCCL (via net plugins such as aws-ofi-nccl); MPI on top.
- **→ Networking**: RoCE and iWARP bind to netdevs (GIDs, routes, neighbours, namespaces, bonding); DCB netlink for PFC/ETS ([[roce-gid-table-and-netdev-binding]]).
- **→ mm / DMA**: all share MR registration, ODP and dma-buf MRs ([[memory-registration-and-ib-umem]], [[memory-pinning-and-registration-strategies]]).
- **← Storage ULPs**: NVMe-oF, iSER, NFS/RDMA, SMB Direct run over any verbs transport, with iWARP-specific MR rules handled by `rdma_rw` ([[rdma-rw-api]]).

## Design Decisions & Tradeoffs

- **Make the network lossless, or make the transport tolerate loss?** InfiniBand and classic RoCE chose lossless (credits, PFC), which keeps the NIC transport simple (go-back-N) but pushes complexity and failure modes into the fabric. iWARP, SRD and UET tolerate loss in the endpoint. Industry momentum since ~2020 (Resilient RoCE, SRD, Google Falcon, UET) is clearly towards lossy fabrics with smarter NICs.
- **Ordering is what prevents multipath.** RC's in-order semantics tie a flow to one path, or force NICs to buffer and reorder. SRD and UET RUD drop ordering at the transport and push it to the layers that need it (libfabric, MPI tag matching, NCCL). That's what makes per-packet spraying, and thus near-full bisection utilisation, possible.
- **Connection state scaling.** RC's per-pair QPs don't scale to 100k-GPU jobs. XRC, DC, SRD's implicit contexts and UET's ephemeral PDCs are successive answers to the same N × p² problem.
- **Verbs vs libfabric.** Verbs mirrors InfiniBand's hardware model. SRD and UET expose semantics (unordered, datagram, tagged) that verbs expresses awkwardly, so both lean on libfabric. For Linux that raises the question of whether new transports belong in the RDMA subsystem at all, which the UET RFC's separate netlink family and `drivers/ultraeth` directory put up for debate.
- **Reuse TCP (iWARP) vs replace it.** iWARP inherits decades of TCP robustness but also its costs (offload engine complexity, port sharing, slower loss recovery). SRD and UET build purpose-built reliability with µs-scale timers instead.

## How It Has Evolved

- **2000–2005** — InfiniBand spec; OpenIB stack merged in Linux 2.6.11.
- **2007** — iWARP RFCs 5040/5041/5044; `iw_cm` and Chelsio/NetEffect drivers.
- **2010 / 2014** — RoCE v1 (IBTA annex); RoCE v2 (routable UDP), kernel support ~4.5 with GID types.
- **2015** — DCQCN and TIMELY published; PFC-based lossless RoCE becomes the data-centre norm.
- **2017–2019** — Resilient RoCE / selective repeat on ConnectX; siw merged (5.3); EFA driver merged (5.2).
- **2020** — SRD paper (IEEE Micro); EFA adds RDMA READ.
- **2023** — Ultra Ethernet Consortium founded; Google publishes Falcon (via OCP).
- **2025** — UE 1.0 spec (June); UET kernel RFC (`drivers/ultraeth`, March); ionic (AMD Pensando) RDMA driver; UET NICs announced.
- **2026** — UE 1.0.x updates; dma-buf export/import across RDMA drivers; hfi1 → hfi2.

## Further Reading

1. [LWN: Ultra Ethernet driver introduction](https://lwn.net/Articles/1013363/) and the [netdev RFC thread](https://lists.openwall.net/netdev/2025/03/12/69)
2. [LWN: EFA driver](https://lwn.net/Articles/786036/); [AMD Pensando RDMA driver](https://lwn.net/Articles/1033763/); [irdma](https://lwn.net/Articles/856287/)
3. [SRD paper: A Cloud-Optimized Transport Protocol for Elastic and Scalable HPC](https://assets.amazon.science/a6/34/41496f64421faafa1cbe301c007c/a-cloud-optimized-transport-protocol-for-elastic-and-scalable-hpc.pdf); [SRD.txt in amzn-drivers](https://github.com/amzn/amzn-drivers/blob/master/kernel/linux/efa/SRD.txt); [ipSpace: a quick look at SRD](https://blog.ipspace.net/2022/12/quick-look-aws-srd/)
4. [Ultra Ethernet Specification 1.0.2](https://ultraethernet.org/wp-content/uploads/sites/20/2026/01/UE-Specification-1.0.2-1.pdf); [Arista: Demystifying Ultra Ethernet](https://blogs.arista.com/blog/demystifying-ultra-ethernet); [VIAVI: Inside UE 1.0](https://blog.viavisolutions.com/2025/08/13/inside-ue-1-0-what-ultra-ethernet-means-for-ai-and-hpc-networks/)
5. [NVIDIA RDMA Aware Programming: Key Concepts](https://docs.nvidia.com/networking/display/RDMAAwareProgrammingv17/Key+Concepts)
6. Vault: [[roce-v1-and-v2]], [[iwarp-transport]], [[roce-congestion-control-pfc-ecn-dcqcn]], [[rdma]]

## LKML Highlights

- **"[RFC PATCH 00/13] Ultra Ethernet driver introduction" (Nikolay Aleksandrov, netdev, March 2025)** — a software PDS (RUD) with jobs, FEPs and PDCs under `drivers/ultraeth` and a new netlink family. It raised where a non-IB RDMA transport should live, with a stated plan to reuse IB infrastructure.
- **"RDMA/efa: Elastic Fabric Adapter (EFA) driver" (Gal Pressman, 2019)** — introduced SRD as a driver-specific QP type in the verbs core rather than a new core QP type, the precedent for exposing non-IB transport semantics through vendor extensions.
- **iWARP port mapper and siw merge (2014–2019)** — the long debate over hardware TCP stacks sharing host IP addresses (iwpmd) and whether a software iWARP (siw) belonged upstream, resolved when siw merged in 5.3.
