---
title: "MADs and Subnet Administration"
category: concept
tags: [rdma, infiniband, mad, subnet-manager, sa, management]
subsystem: rdma
kernel_version: "2.6.11"
researched: 2026-09-26
status: complete
explained: "[[mad-and-subnet-administration-explained]]"
sources:
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/mad.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/mad_priv.h
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/mad_rmpp.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/sa_query.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/user_mad.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/security.c
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_mad.h
  - https://www.kernel.org/doc/html/latest/infiniband/user_mad.html
---

# MADs and Subnet Administration

> 📘 Plain-language version: [[mad-and-subnet-administration-explained]]

## Purpose

An InfiniBand fabric has no DHCP, ARP or routing protocols in the IP sense. It is configured and queried *in-band* with **Management Datagrams (MADs)**: fixed-size 256-byte UD packets sent to two reserved queue pairs on every port. **QP0** carries Subnet Management Packets (SMPs), which a **Subnet Manager** (SM, e.g. OpenSM or a switch-embedded SM) uses to discover the topology, assign LIDs and program switch forwarding tables. **QP1** (the General Services Interface, GSI) carries everything else: connection management (CM), **Subnet Administration** (SA) queries for paths and multicast groups, performance counters (PMA), and vendor classes. The kernel's MAD layer owns QP0 and QP1 and multiplexes them among many independent agents, in the kernel and in userspace, handling transaction matching, timeouts, retries and multi-packet segmentation (RMPP).

## Mental Model

The MAD layer is **the building's mailroom for management mail**. Each port has two mail slots: QP0, the landlord's slot for structural notices, and QP1, the general slot. Tenants (agents such as the CM, the SA client, OpenSM through umad, `perfquery`) register which *class* of mail they handle. Outgoing mail gets a tracking number (transaction ID, TID). The mailroom keeps a copy, re-sends it if no reply arrives before the timeout, and when a reply arrives matches its TID to the sender. Oversized letters (SA table dumps) are split into numbered pages and reassembled (RMPP).

## How It Works

**Port setup.** When an IB-capable port is added, `ib_mad_port_open()` creates the special QPs: `IB_QPT_SMI` (QP0, IB only) and `IB_QPT_GSI` (QP1), with a shared CQ and send/receive queues sized by the `ib_core` module parameters `send_queue_size`/`recv_queue_size`. It posts receive buffers and brings the QPs to RTS. On **RoCE** ports there is no subnet manager and no QP0, but QP1 exists, because the CM's REQ/REP/RTU exchange is still a MAD, carried over RoCE v1 Ethernet or v2 UDP.

**Registering an agent.** A consumer calls `ib_register_mad_agent(device, port, qp_type, reg_req, rmpp_version, send_handler, recv_handler, context, flags)`. `reg_req` names the management class and version plus a method bitmask for unsolicited MADs the agent wants (e.g. the CM registers for `IB_MGMT_CLASS_CM` Send methods, and a PMA agent for `Get` on the performance class). The MAD layer indexes agents by class and version and by method, so incoming *requests* can be routed. It also assigns each agent a high 32-bit TID prefix (`hi_tid`). Replies to that agent's own requests are routed by matching the TID, no matter what class they are. Access to QP0 and SMP classes is gated by LSM hooks: `ib_mad_agent_security_setup()` checks the SELinux `infiniband_endport` permission and sets `smp_allowed`.

**Sending.** The agent allocates a send buffer (`ib_create_send_mad()`: header plus data, optionally RMPP-segmented), fills in the address handle (destination LID/GID, remote QPN = 1, Q_Key `IB_QP1_QKEY`) and calls `ib_post_send_mad()`. If a response is expected, the layer keeps the request on a wait list with `timeout_ms` and `retries`. `timeout_sends()` retransmits or eventually completes it with `IB_WC_RESP_TIMEOUT_ERR`. **Directed-route SMPs**, which the SM uses before LIDs exist and which route hop by hop by port number, are specially handled (`handle_outgoing_dr_smp()`). One destined for the local port is processed locally and never hits the wire.

**Receiving.** Receive completions arrive in `ib_mad_recv_done()`. The layer validates the header (base version, class, method, attribute), runs SMI checks for directed-route MADs, and optionally lets the *driver* consume the MAD first (`process_mad`, used by some HCAs to answer PMA or SMA queries in firmware). It then dispatches: a *response* goes to the agent whose `hi_tid` matches and completes the waiting send, and a *request* goes to the agent registered for that class/version/method. Unmatched requests get an automatic "unsupported" response or are dropped.

**Flow control (solicited MADs).** A busy SA or a CM connection storm can overflow the fixed-size receive queue with responses to the node's own requests. The layer now caps outstanding solicited sends per agent (`sol_fc_max`, a fraction of the receive-queue depth: 1/4 for most classes, 1/32 for SA) and parks extra sends on a `backlog_list` until earlier ones complete.

**RMPP.** SA "GetTable" responses (all path records, all multicast groups) exceed 256 bytes. `mad_rmpp.c` implements the Reliable Multi-Packet Protocol: segments with sequence numbers, a sliding window, ACKs and retransmission, reassembled before the agent's `recv_handler` sees one large buffer.

**Subnet Administration client (`sa_query.c`).** The kernel's SA client registers an agent for `IB_MGMT_CLASS_SUBN_ADM` and offers asynchronous queries: `ib_sa_path_rec_get()` (path records for rdma_cm route resolution), `ib_sa_join_multicast()` / multicast member records (for IPoIB and rdma_cm UD), service records, and ClassPortInfo (SA capabilities). It caches the SM's address per port and refreshes on `IB_EVENT_SM_CHANGE`/`LID_CHANGE`. Large fabrics can overwhelm the SM with path queries, so the SA client can hand PathRecord requests to a **userspace resolver** such as `ibacm` over `RDMA_NL_LS` netlink (`ib_nl_make_request()`), falling back to the SA on timeout (`sa_local_svc_timeout_ms`).

**Userspace access (`user_mad.c`).** `/dev/infiniband/umadN` (one per port) lets userspace register MAD agents (`IB_USER_MAD_REGISTER_AGENT[2]` ioctls) and `read()`/`write()` whole MADs with an address header. OpenSM, `ibnetdiscover`, `perfquery`, `smpquery`, `ibdiagnet` and `ibacm` all use it. `/dev/infiniband/issmN` is the "IsSM" lock: while a process holds it open, the port advertises the `IsSM` capability bit so the fabric knows an SM lives there.

**Multicast (`multicast.c`).** Joins are reference-counted per port and group, so several kernel users (IPoIB, rdma_cm) share one SA membership, and memberships are re-joined after SM changes or port events.

## Key Data Structures

**`struct ib_mad_agent`** (`include/rdma/ib_mad.h`) — a registered agent: `device`, `port_num`, `qp` (QP0 or QP1), `recv_handler`, `send_handler`, `hi_tid`, `rmpp_version`, `smp_allowed`, `security`.

**`struct ib_mad_send_buf`** — an outgoing MAD: `mad` (buffer), `ah`, `timeout_ms`, `retries`, `context[]`, RMPP segment info.

**`struct ib_mad_recv_wc`** — a received MAD (possibly RMPP-reassembled): `wc`, `recv_buf`, `mad_len`, `mad_seg_size`.

**`struct ib_mad_agent_private`** (`mad_priv.h`) — internal: `send_list`, `wait_list`, `backlog_list`, `sol_fc_*` counters, timeout work.

**`struct ib_sa_path_rec` / `sa_path_rec`** — the path record: SGID/DGID, SLID/DLID, P_Key, SL, MTU, rate, packet lifetime, traffic class, flow label; with RoCE extensions (`rec_type`, dmac, ifindex).

## Key Functions / Entry Points

- **`ib_register_mad_agent()` / `ib_unregister_mad_agent()`** (`mad.c`)
- **`ib_create_send_mad()` / `ib_post_send_mad()` / `ib_free_send_mad()`**
- **`ib_mad_recv_done()` / `ib_mad_send_done()`** — CQ callbacks, dispatch and completion
- **`ib_mad_port_open()` / `ib_mad_port_close()`** — QP0/QP1 lifecycle per port
- **`ib_sa_path_rec_get()` / `ib_sa_join_multicast()`** (`sa_query.c`, `multicast.c`)
- **`ib_umad_write()` / `ib_umad_read()` / `ib_umad_ioctl()`** (`user_mad.c`)

## Important Flags & Config Options

- `CONFIG_INFINIBAND_USER_MAD` — umad and issm devices
- `ib_core.send_queue_size`, `ib_core.recv_queue_size` — QP0/QP1 depths
- `ib_sa` netlink local service (`ibacm`) and `sa_local_svc_timeout_ms`
- Management classes: `IB_MGMT_CLASS_SUBN_LID_ROUTED` (0x01), `_SUBN_DIRECTED_ROUTE` (0x81), `_SUBN_ADM` (0x03), `_PERF_MGMT` (0x04), `_CM` (0x07), vendor ranges
- SELinux classes `infiniband_endport` (SMP access) and `infiniband_pkey`

## Interactions with Other Subsystems

- **↑ Userspace**: OpenSM, infiniband-diags (`ibstat`, `ibnetdiscover`, `perfquery`), `ibacm`, UFM; through `umad`/`issm`
- **→ QP/CQ layer**: uses special QP types and the `ib_alloc_cq` polling API
- **→ LSM**: SMP and P_Key enforcement (`security.c`)
- **← CM**: `ib_cm` sends REQ/REP/RTU/DREQ as MADs on QP1 ([[rdma-cm-connection-manager]])
- **← IPoIB / rdma_cm**: path queries and multicast joins through the SA client
- **← Performance counters**: `rdma statistic` and sysfs port counters on some devices come from PMA MADs

## Design Decisions & Tradeoffs

- **Centralized management (SM) over distributed routing protocols.** The SM computes routes for the whole fabric (min-hop, up/down, fat-tree, DOR engines) and programs switches. That gives deterministic, deadlock-free routing for HPC topologies, but makes the SM and SA a scalability bottleneck and a single point of control. Hence the local path caching (`ibacm`) and flow control.
- **Kernel-owned special QPs, userspace SMs.** The kernel doesn't run a subnet manager. It only multiplexes QP0 and QP1 safely, keeping complex, policy-heavy routing in userspace.
- **Fixed 256-byte MADs.** Simple to buffer and parse, but large responses need RMPP, and OPA later extended MADs to 2 KiB (`OPA_MGMT_MAD_SIZE`).
- **RoCE keeps QP1 but drops QP0.** The CM protocol is reused as-is on Ethernet. Addressing and path information come from IP instead of the SA.

## How It Has Evolved

- **2.6.11** — MAD layer, SA client, umad (OpenIB)
- **2.6.1x** — RMPP, multicast module
- **4.x** — netlink PathRecord offload to `ibacm`; OPA (Intel Omni-Path) jumbo MADs; SELinux InfiniBand hooks (4.13)
- **6.x (2025)** — solicited-MAD flow control (`sol_fc_*`, backlog list) to survive SA/CM storms on very large clusters

## Further Reading

- kernel.org — [Userspace MAD access](https://www.kernel.org/doc/html/latest/infiniband/user_mad.html)
- InfiniBand Architecture Specification Vol. 1, Chapters 13–16 (management model, SMA/SA, RMPP)
- OpenSM — https://github.com/linux-rdma/opensm
- Related: [[rdma]], [[rdma-cm-connection-manager]], [[ib-device-and-client-model]]

## LKML Highlights

- **SELinux InfiniBand hooks (Dan Jurgens, Mellanox, 2017, 4.13)** — added P_Key and endport access control, so a container can't send SMPs or use partitions it isn't labelled for; `security.c` and `smp_allowed` come from this.
- **ib_nl local SA (Kaike Wan, Intel, 2015)** — routed PathRecord queries through netlink to `ibacm` to offload the SM in large fabrics, with transparent fallback to the SA.
- **Solicited MAD flow control (NVIDIA, 2025)** — per-agent outstanding limits and a backlog list, motivated by receive-queue overflow when thousands of nodes query the SA or connect at once. (Message-ids not retrieved: lore was unreachable.)
