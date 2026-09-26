---
title: "RDMA Connection Manager (rdma_cm)"
category: concept
tags: [rdma, rdma-cm, connection-management, ib-cm, iwarp, roce]
subsystem: rdma
kernel_version: "2.6.17 (rdma_cm, ucma 2.6.18)"
researched: 2026-09-26
status: complete
explained: "[[rdma-cm-connection-manager-explained]]"
sources:
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/cma.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/cma_priv.h
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/addr.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/cm.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/iwcm.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/ucma.c
  - https://github.com/torvalds/linux/blob/master/include/rdma/rdma_cm.h
  - https://lwn.net/Articles/174629/
  - https://github.com/linux-rdma/rdma-core
---

# RDMA Connection Manager (rdma_cm)

> 📘 Plain-language version: [[rdma-cm-connection-manager-explained]]

## Purpose

Before two reliable-connected QPs can talk, each must learn the other's QP number, starting packet sequence number, path (addresses, MTU, service level) and capabilities, and both must move their QPs through INIT → RTR → RTS in a coordinated way (see [[queue-pairs-and-completion-queues]]). Each transport does this differently: InfiniBand uses CM MADs and a subnet manager, RoCE uses CM MADs over UDP/Ethernet with IP-derived GIDs, and iWARP uses a real TCP connection plus an MPA handshake. The **RDMA CM** (`rdma_cm`, `cma.c`) hides all of that behind a **sockets-like, IP-addressed API**, so ULPs and applications can write transport-independent code: resolve address, resolve route, connect or listen/accept, disconnect.

## Mental Model

`rdma_cm` is **a travel agent for QPs**. You say "I want to reach 10.0.0.2 port 4420" and it (1) figures out which of your RDMA devices and ports can get there and which source GID to use (address resolution), (2) books the path, from the SA on InfiniBand or from IP routing and neighbour tables on Ethernet (route resolution), (3) negotiates with the other side's agent, using the IB CM's REQ/REP/RTU dance or iWARP's TCP + MPA, and (4) hands you a QP already transitioned to RTS. It reports progress as events on a queue, because every step is asynchronous and may involve network round trips.

## How It Works

**Creating an ID.** Kernel users call `rdma_create_id(net, handler, ctx, ps, qp_type)`. Userspace uses librdmacm → `/dev/infiniband/rdma_cm` → `ucma.c`, which creates an ID with `rdma_create_user_id()` and turns every callback into a queued event that `rdma_get_cm_event()` reads. The ID is a `struct rdma_cm_id` embedded in the private `struct rdma_id_private`. Its **port space** `ps` (`RDMA_PS_TCP` for RC, `RDMA_PS_UDP` for UD, `RDMA_PS_IB`, `RDMA_PS_IPOIB`) partitions the port-number namespace. The IB Service ID is built as `RDMA_IB_IP_PS_TCP | port` (e.g. `0x0000000001060000 | 4420`), so an IP-style port maps onto an IB service ID. Every ID carries a state from `enum rdma_cm_state` (`IDLE`, `ADDR_QUERY`, `ADDR_RESOLVED`, `ROUTE_QUERY`, `ROUTE_RESOLVED`, `CONNECT`, `DISCONNECT`, `ADDR_BOUND`, `LISTEN`, `DEVICE_REMOVAL`, `DESTROYING` ...). Transitions go through `cma_comp_exch()` so concurrent API calls and callbacks can't corrupt it.

**Step 1 — address resolution (`rdma_resolve_addr`).** The active side supplies a destination `sockaddr` (IPv4, IPv6 or native `AF_IB`) and optionally a source. `addr.c`'s `rdma_resolve_ip()` does an ordinary **IP route lookup** (`ip_route_output_key`/`ip6_route_output`) to find the outgoing `net_device`. It then fetches the L2 address: for RoCE and iWARP via the **neighbour table** (`dst_fetch_ha()`, sending ARP/ND if needed), for IPoIB via its hardware address. For IB with `ib_nl` enabled, it can ask a userspace resolver over `RDMA_NL_LS`. The result goes into `struct rdma_dev_addr` (source and dest hardware addresses, netdev ifindex, network type). The CM then **binds the ID to an RDMA device**: `cma_acquire_dev_by_src_ip()` finds the `ib_device`/port whose GID table contains a GID for that netdev and IP (see [[roce-gid-table-and-netdev-binding]]) and chooses RoCE v1 vs v2 by the configured default. Loopback and `INADDR_ANY` destinations get special handling (`cma_resolve_loopback`). Success fires `RDMA_CM_EVENT_ADDR_RESOLVED`.

**Step 2 — route resolution (`rdma_resolve_route`).** The work depends on the transport:
- **InfiniBand** (`cma_resolve_ib_route`): sends an SA **PathRecord** query to the subnet manager (`ib_sa_path_rec_get`) for source/dest GIDs, P_Key and QoS class, getting back SL, MTU, rate, packet lifetime and optional inbound/outbound or alternate paths.
- **RoCE / "IBoE"** (`cma_resolve_iboe_route`): there is no SM, so the path record is *synthesized* locally. MTU comes from the netdev's MTU, the rate from link speed, and the traffic class or DSCP from `rdma_set_service_type()`/ToS or the configfs `default_roce_tos`. The GID type (v2 = UDP/IP) goes into the path. The destination MAC comes from step 1.
- **iWARP** (`cma_resolve_iw_route`): nothing to do, because TCP will route.

Success fires `RDMA_CM_EVENT_ROUTE_RESOLVED`.

**Step 3a — active connect.** The application calls `rdma_create_qp(id, pd, attr)`, which creates the QP and moves it to INIT with the right port and P_Key, then `rdma_connect(id, conn_param)`. `conn_param` carries `private_data` (up to 56 bytes for IB/RoCE after the CMA header, and more for iWARP), `responder_resources`, `initiator_depth`, `retry_count` and `rnr_retry_count`. On IB and RoCE, `cma_connect_ib()` creates an `ib_cm_id` and sends a CM **REQ** MAD over QP1 (on RoCE v2 that's UDP port 4791 like all RoCE traffic). The REQ carries the local QPN, starting PSN, path and private data. On iWARP, `cma_connect_iw()` calls `iw_cm_connect()`, and the *driver* (or siw) opens a TCP connection and exchanges MPA request and reply frames carrying the private data. The `iwpmd` port mapper daemon, over netlink, reserves the TCP port so it doesn't collide with the host stack.

**Step 3b — passive listen/accept.** `rdma_bind_addr()` then `rdma_listen(id, backlog)`. Binding to a wildcard address listens on *every* RDMA device, current and future (`listen_any_list`). Each device gets an internal child listen ID, created as devices appear. An incoming REQ reaches `cma_ib_req_handler()`, which uses the path's GID, P_Key and IP data (plus the `ib_client` `get_net_dev_by_params` hook for IPoIB) to find the matching `net_device` and namespace, looks up the listener by port, creates a **new** `rdma_cm_id` for the connection, and delivers `RDMA_CM_EVENT_CONNECT_REQUEST` with the private data. The passive side creates its QP and calls `rdma_accept()`. The CM moves the QP INIT → RTR using the peer's QPN and PSN from the REQ (`cma_modify_qp_rtr`), then sends **REP**.

**Step 4 — establishment.** The active side receives REP, moves its QP to RTR and then RTS (`cma_modify_qp_rts`), and sends **RTU** (ready to use). It gets `RDMA_CM_EVENT_ESTABLISHED`. The passive side moves to RTS on receiving the RTU, or on the first incoming packet (`rdma_notify(IB_EVENT_COMM_EST)`, because RTU can be lost), and gets `ESTABLISHED`. iWARP completes when the MPA reply arrives. The QP is now ready, and neither side called `ib_modify_qp()` itself.

**Disconnect and time-wait.** `rdma_disconnect()` moves the QP to ERR (flushing outstanding WRs) and sends a **DREQ**, answered by **DREP**. Both sides get `RDMA_CM_EVENT_DISCONNECTED`. The IB CM keeps the QPN in **time-wait** until packets from the old connection can no longer be in flight (`RDMA_CM_EVENT_TIMEWAIT_EXIT`), the same idea as TCP TIME_WAIT for QP-number reuse.

**Failure paths.** A missing path gives `ROUTE_ERROR`. A peer with no listener sends **REJ** (`RDMA_CM_EVENT_REJECTED`, with a reason code such as "invalid service ID" or "consumer reject" with private data). CM retries exhausted give `UNREACHABLE`. Address changes (bond failover, IP removal) give `ADDR_CHANGE`. `DEVICE_REMOVAL` asks the user to destroy everything on the ID before the device can be unregistered (see [[ib-device-and-client-model]]).

**UD and multicast.** For `RDMA_PS_UDP` there is no connection. `rdma_connect()` performs a **SIDR** (Service ID Resolution) exchange to learn the remote QPN and Q_Key, and `rdma_join_multicast()` joins IB multicast groups through the SA, or for RoCE maps the group to an Ethernet multicast MAC plus IGMP/MLD.

**Extras.** **ECE** (Enhanced Connection Establishment, `rdma_connect_ece`/`rdma_accept_ece`, 5.8) lets vendors negotiate optional features inside CM messages. `rdma_set_ack_timeout()`, `rdma_set_min_rnr_timer()`, `rdma_set_reuseaddr()` and `rdma_set_afonly()` mirror socket options. `rdma_resolve_ib_service()` (2025, `ADDRINFO_*` states and events) resolves an IB service name or ID through the SA into addresses, like `getaddrinfo` for native IB.

## Key Data Structures

**`struct rdma_cm_id`** (`include/rdma/rdma_cm.h`) — the public handle.
- `device`, `port_num` — the bound RDMA device and port
- `qp` — the QP created by `rdma_create_qp()`
- `route` — `struct rdma_route`: `addr` (src/dst sockaddrs + `rdma_dev_addr`) and `path_rec` (primary, alternate, inbound/outbound)
- `ps`, `qp_type` — port space and service
- `event_handler`, `context` — callback and user cookie

**`struct rdma_id_private`** (`cma_priv.h`) — internal state.
- `state` — `enum rdma_cm_state`
- `cm_id.ib` / `cm_id.iw` — the transport-specific CM handle
- `bind_list` — port reservation in the port space
- `listen_list` / `listen_item` — wildcard listener fan-out to per-device listeners
- `handler_mutex` — serializes event delivery for one ID
- `tos`, `timeout_ms`, `qkey`, `qp_num`, `seq_num`, `options` (reuseaddr, afonly)

**`struct rdma_cm_event`** — `event`, `status`, `param.conn` (private data, depths, retry counts, remote QPN) or `param.ud`, `ece`.

## Key Functions / Entry Points

- **`rdma_create_id()` / `rdma_destroy_id()`** (`cma.c`)
- **`rdma_resolve_addr()`** → `rdma_resolve_ip()` (`addr.c`) → `addr_handler()` → `cma_acquire_dev_by_src_ip()`
- **`rdma_resolve_route()`** → `cma_resolve_ib_route()` / `cma_resolve_iboe_route()` / `cma_resolve_iw_route()`
- **`rdma_create_qp()` / `rdma_init_qp_attr()`** — CM-managed QP setup
- **`rdma_connect()` / `rdma_listen()` / `rdma_accept()` / `rdma_reject()` / `rdma_disconnect()`**
- **`cma_ib_handler()` / `cma_ib_req_handler()` / `cma_iw_handler()`** — translate transport CM events into `rdma_cm` events
- **`ib_send_cm_req()` / `ib_send_cm_rep()` / `ib_send_cm_rtu()`** (`cm.c`) — IB CM protocol engine
- **`iw_cm_connect()` / `iw_cm_accept()`** (`iwcm.c`) — iWARP CM
- **`ucma_write()`** (`ucma.c`) — userspace command channel

## Important Flags & Config Options

- `CONFIG_INFINIBAND_ADDR_TRANS` (rdma_cm), `CONFIG_INFINIBAND_ADDR_TRANS_CONFIGFS`
- configfs `/sys/kernel/config/rdma_cm/<dev>/ports/<n>/default_roce_mode` — `IB/RoCE v1` or `RoCE v2`
- configfs `.../default_roce_tos` — ToS/DSCP for RoCE CM connections (ties into PFC/ECN classes)
- `rdma_set_option(RDMA_OPTION_ID_TOS | _REUSEADDR | _AFONLY | _ACK_TIMEOUT)`
- `ib_cm` retry and timeout behaviour is derived from path packet lifetime and `max_cm_retries`
- `iwpmd` daemon — iWARP port mapping

## Interactions with Other Subsystems

- **↑ Userspace**: librdmacm (`rdma_create_id`, `rdma_getaddrinfo`, `rdma_connect`, `rdma_get_cm_event`); `rping`, `ucmatose`, `ib_write_bw -R` (perftest with rdma_cm)
- **→ net**: IP routing, neighbour resolution (ARP/ND), `net_device` lookup, network namespaces (IDs are per-netns); iWARP uses real TCP sockets and port mapping
- **→ MAD / SA**: path records and multicast from the subnet manager on IB ([[mad-and-subnet-administration]])
- **→ GID cache**: source GID selection per netdev and VLAN ([[roce-gid-table-and-netdev-binding]])
- **← Kernel ULPs**: NVMe-oF RDMA host and target, xprtrdma/svcrdma (NFS), iSER, RTRS/RNBD, SMB Direct (ksmbd, cifs), RDS
- **Compared with io_uring**: io_uring connections are just TCP sockets (`IORING_OP_CONNECT`/`ACCEPT`, multishot accept), with no separate CM. RDMA needs a CM because transport state lives in the NIC and must be negotiated out of band before the first byte moves.

## Design Decisions & Tradeoffs

- **IP addressing everywhere.** Even native IB is addressed by IP (through IPoIB) or `AF_IB`, so applications don't deal with LIDs or GIDs. The cost is that address resolution depends on IP routing and neighbour state being correct, so ARP problems become RDMA connection problems.
- **Event-driven asynchronous API.** Every step can block on the network (SA query, ARP, CM MADs), so rdma_cm exposes events rather than blocking calls. librdmacm offers synchronous wrappers for simple apps. In-kernel ULPs build their own state machines on the events (NVMe-oF's `nvme_rdma_cm_handler`).
- **The CM drives QP transitions.** Centralizing INIT/RTR/RTS in `cma.c` prevents PSN, QPN and path mismatches. Apps that need custom attributes use `rdma_init_qp_attr()` and modify the QP themselves.
- **Separate transport CMs under one front end.** The IB CM protocol (from the IBTA spec) and iWARP MPA are very different, and `rdma_cm` translates both into one event model, at the price of a large, subtle `cma.c` (over 5,600 lines) that has been a steady source of races around device removal and listener fan-out.
- **Small private data.** CM REQ private data is limited (92 bytes, 56 usable after the CMA header), so ULPs exchange rkeys and parameters in-band after connecting, or pack minimal data (NVMe-oF's queue ID and size).

## How It Has Evolved

- **2.6.17–2.6.18 (2006)** — rdma_cm and ucma (Sean Hefty, Intel); LWN "userspace support for RDMA connection manager"
- **2.6.19–2.6.20** — iWARP CM integration
- **2.6.3x** — RoCE (IBoE) route synthesis
- **4.x** — RoCE v2 GID types in address and route; configfs defaults; network namespace support for IDs
- **4.x** — `AF_IB` native addressing
- **5.8** — ECE
- **5.x** — ack timeout and min RNR timer setters; many listener and removal race fixes
- **2025–26** — `rdma_resolve_ib_service()` and the `ADDRINFO_*` states for SA-based service resolution; `rdma_restrict_node_type()`

## Further Reading

- LWN — [IB: userspace support for RDMA connection manager](https://lwn.net/Articles/174629/) (2006)
- rdma-core — `librdmacm/man/rdma_cm.7`, `rdma_connect.3`, `rdma_get_cm_event.3`, example `rping.c`
- Source — `drivers/infiniband/core/cma.c`, `addr.c`, `cm.c`, `iwcm.c`
- InfiniBand Architecture Specification Vol. 1, Chapter 12 (Communication Management)
- Related: [[rdma]], [[queue-pairs-and-completion-queues]], [[roce-gid-table-and-netdev-binding]], [[iwarp-transport]], [[nvme-over-fabrics-rdma-and-tcp]]

## LKML Highlights

- **"IB: userspace support for RDMA connection manager" (Sean Hefty, 2006; LWN 174629)** — introduced `ucma` and the event-queue model librdmacm still uses. The review debated exposing kernel CM events through a character device versus netlink.
- **RoCE v2 and rdma_cm (Matan Barak / Moni Shoua, 2015–16)** — added GID types to address and route resolution and configfs `default_roce_mode`, so one host can speak v1 and v2 depending on the peer.
- **Listener and device-removal race fixes (Jason Gunthorpe, 2020–21)** — reworked `handler_mutex`, the `listen_list` fan-out and destroy ordering after syzkaller found use-after-frees through ucma. (Exact message-ids unavailable: lore was unreachable this session.)
