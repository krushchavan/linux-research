---
title: "iWARP Transport"
category: concept
tags: [rdma, iwarp, tcp-offload, ddp, mpa, iw-cm]
subsystem: rdma
kernel_version: "2.6.19 (iw_cm, iw_cxgb3); 5.3 (siw)"
researched: 2026-09-26
status: complete
explained: "[[iwarp-transport-explained]]"
sources:
  - https://datatracker.ietf.org/doc/html/rfc5040
  - https://datatracker.ietf.org/doc/html/rfc7306
  - https://en.wikipedia.org/wiki/IWARP
  - https://man.archlinux.org/man/iwpmd.8.en
  - https://github.com/linux-rdma/rdma-core/blob/master/iwpmd/iwpmd.8.in
  - https://github.com/animeshtrivedi/blog/blob/master/post/2019-06-26-siw.md
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/iwcm.c
  - https://github.com/torvalds/linux/blob/master/include/rdma/iw_cm.h
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/rw.c
  - https://github.com/torvalds/linux/tree/master/drivers/infiniband/hw
---

# iWARP Transport

> 📘 Plain-language version: [[iwarp-transport-explained]]

## Purpose

**iWARP** (Internet Wide Area RDMA Protocol) is the IETF's RDMA transport. It layers RDMA semantics on top of **TCP** instead of on a lossless fabric. Where RoCE borrows InfiniBand's transport and asks Ethernet to be lossless, iWARP borrows TCP's reliability, congestion control and routability, so RDMA works over ordinary lossy, routed IP networks, including WANs, with no PFC or DCB configuration. In Linux, iWARP devices are ordinary RDMA devices behind the same verbs API, but they come with transport-specific rules the core must enforce: a TCP-based connection manager, a port-space arbitration daemon, and memory-registration requirements for RDMA READ.

## Mental Model

TCP is a **byte pipe**: it guarantees order and delivery but not message boundaries, so a receiver normally copies bytes into a buffer, then parses. iWARP adds **shipping labels inside the pipe**. Every chunk of data (a DDP segment) carries a label saying either "this belongs at offset X of memory region STag Y" (*tagged*) or "this is part of message N for the next receive buffer" (*untagged*). A NIC that understands the labels can **place each chunk directly into its final memory location as it comes off the wire**, even before earlier TCP segments are complete, and without the host CPU. That is "direct data placement". MPA framing makes sure labels can be found in the byte stream even after resegmentation.

## How It Works

**The protocol stack (IETF RFCs).**

```
RDMAP  (RFC 5040)  — RDMA operations: Send, RDMA Write, RDMA Read Request/Response, Terminate
DDP    (RFC 5041)  — Direct Data Placement: tagged (STag+TO) and untagged (QN, MSN, MO) buffers
MPA    (RFC 5044)  — Marker PDU Aligned framing over TCP: FPDUs, optional markers, CRC32c
TCP / IP           — reliability, ordering, congestion control, routing
```

- **RDMAP** encodes the familiar verbs operations. An RDMA Write is a tagged DDP message to the peer's STag (the iWARP name for an rkey) and Tagged Offset. An RDMA Read sends a *Read Request* (untagged, on a dedicated queue number) naming the source STag/offset and the requester's *sink* STag/offset, and the responder answers with tagged *Read Response* segments written into the sink. A Send is untagged and consumes the next posted receive. *Terminate* reports fatal errors.
- **DDP** puts a header on each segment. Tagged: `STag`, `TO`. Untagged: `QN` (queue), `MSN` (message sequence number), `MO` (message offset). Plus a "last" flag. Because every segment says where it goes, **out-of-order TCP segments can be placed immediately**; delivery (the completion) happens in order.
- **MPA** frames DDP segments into **FPDUs** (Framed PDUs: length, payload, padding, **CRC32c**) sized to fit TCP segments. Optional **markers** every 512 bytes point back to the FPDU header so a receiver joining mid-stream (after loss) can find frame boundaries. Modern implementations negotiate markers off and rely on FPDU/segment alignment. The MPA **start-up** exchange (MPA Request/Reply, carrying up to 512 bytes of private data plus CRC and marker negotiation) runs over the new TCP connection before RDMA mode starts. **RFC 6581** ("Enhanced RDMA Connection Establishment") adds MPA v2 with IRD/ORD negotiation and a mechanism for the peer-to-peer ("RTR") first message. **RFC 7306** adds atomics and immediate data.

**Connection management in Linux (`iwcm.c`).** iWARP has no InfiniBand CM MADs. Connections are TCP connections, so the core provides a separate **iWARP CM** (`iw_cm`) that `rdma_cm` drives for iWARP devices (see [[rdma-cm-connection-manager]]):
- `iw_cm_connect(cm_id, iw_param)` passes `private_data`, `ord`/`ird` (outbound and inbound RDMA READ depths) and the QPN to the provider's `iw_connect`. The provider (NIC firmware, or siw in software) performs the TCP 3-way handshake and MPA exchange. On success the core gets `IW_CM_EVENT_CONNECT_REPLY` and moves the QP to RTS (`iw_cm_init_qp_attr`).
- `iw_cm_listen()` asks the provider to create a listening endpoint. An incoming connection plus MPA Request becomes `IW_CM_EVENT_CONNECT_REQUEST` → `cm_conn_req_handler()`, which creates a child `iw_cm_id` for rdma_cm to deliver as `RDMA_CM_EVENT_CONNECT_REQUEST`. `iw_cm_accept()` sends the MPA Reply.
- `iw_cm_disconnect(cm_id, abrupt)` does a graceful TCP FIN close or an abortive RST, then moves the QP through CLOSING. The state machine is `enum iw_cm_state`: IDLE → LISTEN / CONN_SENT / CONN_RECV → ESTABLISHED → CLOSING → DESTROYING.

**Port-space arbitration: iwpmd.** Hardware iWARP NICs run their own TCP stack in the adapter, but they **share the host's IP addresses**. If the NIC picked TCP port 5000 for an RDMA connection while a host application bound 5000, the host stack and the NIC would both claim incoming segments. The **iWARP port mapper** fixes this. Before connecting or listening, `iw_cm_map()` sends an `RDMA_NL_IWPM` netlink request (`iwpm_add_mapping()`) to the userspace daemon **`iwpmd`** (rdma-core), which *opens a real socket* and binds the port through the host stack, reserving it. It returns the "mapped" address, stored in `iw_cm_id.m_local_addr`/`m_remote_addr`. The NIC uses the mapped port on the wire. Mappings are released on destroy. Providers that use host TCP sockets directly (siw) don't need a mapping because the kernel stack owns the port.

**Memory-registration rule for RDMA READ.** On InfiniBand and RoCE, the requester of an RDMA READ names its local sink with an lkey, a purely local handle. In iWARP, the Read *Response* is a tagged write into the requester's memory, so the sink must be described by an **STag with remote-write access**, i.e. a registered MR, not just an lkey or local DMA address. That's why the core's `rdma_rw` *always* uses MR registration for READs on iWARP (`rdma_rw_io_needs_mr()` returns true for `rdma_protocol_iwarp()` and `DMA_FROM_DEVICE`) and uses `IB_WR_RDMA_READ_WITH_INV` so the temporary STag invalidates itself when the read completes (see [[rdma-rw-api]]). NFS/RDMA, iSER and NVMe-oF inherit this automatically.

**Other semantic differences surfaced through the core.**
- **No UD, no multicast, no atomics (historically)**: iWARP is connection-only (RC). `rdma_cap_*()` helpers let ULPs check.
- **Peer-to-peer RTR**: iWARP requires the *active* side to send first after MPA. MPA v2 defines a zero-length RDMA Write or Read as the "ready to receive" signal, and drivers insert it transparently.
- **QP state transitions** are driven by TCP events (FIN, RST, retransmission timeout) rather than IB timers, so a stalled TCP connection surfaces as `IW_CM_EVENT_CLOSE` or an error completion.
- **GIDs** are just the MAC/IP of the netdev. There is no RoCE-style GID table machinery beyond port binding (`iw_ifname`, `ib_device_set_netdev`).

**Implementations in Linux.**
- **Chelsio T4–T7** (`iw_cxgb4`, `drivers/infiniband/hw/cxgb4`) — full TCP offload engine plus iWARP; historically the flagship iWARP hardware.
- **Intel E810 / X722** (`irdma`, which replaced `i40iw` in 5.14) — supports iWARP *and* RoCE v2, selectable per port.
- **Marvell/QLogic FastLinQ** (`qedr`) — iWARP and RoCE.
- **siw** — software iWARP over kernel TCP sockets (see [[soft-rdma-rxe-and-siw]]).
- Removed: `iw_cxgb3`, `nes` (Intel NetEffect), `i40iw`.

## Key Data Structures

**`struct iw_cm_id`** (`include/rdma/iw_cm.h`) — `cm_handler`, `context`, `device`, `local_addr`/`remote_addr`, `m_local_addr`/`m_remote_addr` (port-mapped), `provider_data`, `event_handler`, `tos`, `mapped`, `afonly`.

**`struct iw_cm_conn_param`** — `private_data`, `private_data_len`, `ord`, `ird`, `qpn`.

**`struct iwcm_id_private`** (`iwcm.h`) — `state` (`enum iw_cm_state`), `qp`, `refcount`, work lists for provider events.

**`struct iw_cm_event`** — `event` (`IW_CM_EVENT_CONNECT_REQUEST`, `_CONNECT_REPLY`, `_ESTABLISHED`, `_DISCONNECT`, `_CLOSE`), `status`, addresses, private data, `ird`/`ord`.

## Key Functions / Entry Points

- **`iw_cm_connect()` / `iw_cm_listen()` / `iw_cm_accept()` / `iw_cm_reject()` / `iw_cm_disconnect()`** (`iwcm.c`)
- **`iw_cm_map()` → `iwpm_add_mapping()`** (`iwcm.c`, `iwpm_msg.c`) — port reservation via iwpmd
- **`cm_conn_req_handler()` / `cm_conn_rep_handler()` / `cm_conn_est_handler()`** — provider event handling
- **`iw_cm_init_qp_attr()`** — QP state for iWARP transitions
- **`cma_connect_iw()` / `cma_iw_handler()` / `cma_iw_listen()`** (`cma.c`) — rdma_cm glue
- **`rdma_rw_io_needs_mr()`** (`rw.c`) — enforces the READ-sink registration rule
- Provider ops: `iw_connect`, `iw_accept`, `iw_reject`, `iw_create_listen`, `iw_destroy_listen`, `iw_add_ref`, `iw_rem_ref`, `iw_get_qp`

## Important Flags & Config Options

- `CONFIG_INFINIBAND_ADDR_TRANS` (rdma_cm + iw_cm), provider configs `CONFIG_INFINIBAND_CXGB4`, `CONFIG_INFINIBAND_IRDMA`, `CONFIG_INFINIBAND_QEDR`, `CONFIG_RDMA_SIW`
- `iwpmd` service and `/etc/iwpmd.conf` (netlink buffer sizing)
- ice devlink generic parameters `enable_iwarp` / `enable_roce` (mutually exclusive) — switch an E810 function between iWARP and RoCE v2 for irdma
- `rdma_protocol_iwarp()`, `rdma_cap_iw_cm()` — capability checks for ULPs
- MPA negotiation: CRC on/off, markers off, MPA v2 IRD/ORD

## Interactions with Other Subsystems

- **↑ Userspace**: same verbs and librdmacm APIs; `iwpmd` daemon; `rping`/perftest with `-R`
- **→ net**: shares IP addresses and the TCP port space with the host stack (hence iwpmd); siw uses kernel TCP sockets directly; offload NICs keep separate TCP state that the host stack can't see (a long-standing netdev objection to TOE)
- **→ rdma_cm**: `iw_cm` is its transport backend for iWARP ([[rdma-cm-connection-manager]])
- **→ rdma_rw / MR**: mandatory READ-sink registration ([[rdma-rw-api]], [[memory-registration-and-ib-umem]])
- **vs RoCE**: iWARP gets loss tolerance, routability and standard TCP congestion control (in NIC firmware) without PFC. RoCE gets lower silicon complexity, multicast/UD and a larger ecosystem ([[roce-v1-and-v2]], [[roce-congestion-control-pfc-ecn-dcqcn]])
- **vs io_uring + TCP**: both run over lossy TCP networks. io_uring still runs TCP in the host kernel (with zero-copy send/receive options), while iWARP offloads TCP and placement to the NIC and adds one-sided semantics

## Design Decisions & Tradeoffs

- **TCP as the substrate.** iWARP inherits decades of congestion control, loss recovery and middlebox compatibility and works on any IP network. The price is putting a full TCP stack in NIC hardware (a TOE), which is expensive, harder to update, and historically opposed by Linux netdev maintainers because offloaded connections bypass netfilter, qdisc and host TCP fixes. That is part of why iWARP hardware lives entirely in the RDMA subsystem, not in netdev.
- **Direct placement despite reordering.** DDP's self-describing segments let hardware place out-of-order data without reassembly buffers. MPA framing and markers were needed because TCP resegmentation can split headers. Markers added so much complexity that implementations disable them and rely on alignment.
- **Separate port mapper in userspace.** Avoids giving offload NICs a back door into the host TCP port table, at the cost of a daemon dependency and a netlink round trip per connection or listen.
- **STag-based READ sinks.** A cleaner wire protocol (Read Response is just a tagged write), but it forces registration for every READ, which the core hides in `rdma_rw`.
- **Market outcome.** RoCE won the datacenter mainstream (AI, storage) through ecosystem and silicon cost, while iWARP persists in Chelsio, Intel E810 and siw deployments, especially where lossless fabrics are impractical. Modern "lossy RoCE" work re-implements iWARP's key advantage, loss tolerance, inside RoCE NICs.

## How It Has Evolved

- **2002–2007** — RDMA Consortium and IETF RDDP working group; RFCs 5040/5041/5044 published 2007
- **2.6.19 (2006)** — `iw_cm` and the first iWARP driver (Ammasso `amso1100`), then `iw_cxgb3` (Chelsio T3)
- **2.6.3x** — `iw_cxgb4`, `nes` (NetEffect)
- **2012–2014** — RFC 6581 (enhanced connection establishment, MPA v2); RFC 7306 (atomics, immediate data)
- **3.x–4.x** — iWARP port mapper and `iwpmd` (Tatyana Nikolova, Intel, 3.18); `i40iw` (X722, 4.8)
- **5.3** — siw
- **5.14** — `irdma` replaces `i40iw` with iWARP + RoCE v2
- **2020s** — `nes`, `iw_cxgb3` removed; iWARP remains supported but sees little new protocol work

## Further Reading

- IETF — [RFC 5040 (RDMAP)](https://datatracker.ietf.org/doc/html/rfc5040), RFC 5041 (DDP), RFC 5044 (MPA), RFC 6581 (Enhanced Connection Establishment), [RFC 7306 (RDMA Protocol Extensions)](https://datatracker.ietf.org/doc/html/rfc7306)
- Wikipedia — [iWARP](https://en.wikipedia.org/wiki/IWARP)
- rdma-core — [iwpmd(8)](https://man.archlinux.org/man/iwpmd.8.en)
- Blog — [Animesh Trivedi on SoftiWARP (siw)](https://github.com/animeshtrivedi/blog/blob/master/post/2019-06-26-siw.md)
- Related: [[rdma]], [[soft-rdma-rxe-and-siw]], [[rdma-cm-connection-manager]], [[rdma-rw-api]], [[roce-v1-and-v2]], [[tcp-ip-stack]]

## LKML Highlights

- **"iWARP connection manager" (Tom Tucker / Steve Wise, Open Grid Computing, 2006)** — added `iw_cm` and plugged it into `rdma_cm`. The debate was about whether to push offloaded TCP connection state into the kernel's TCP tables, and netdev refused, which is why iWARP ports are arbitrated by a separate mechanism.
- **"RDMA/core: iWARP port mapper" (Tatyana Nikolova, Intel, 2014, 3.18)** — introduced the netlink `RDMA_NL_IWPM` client and `iwpmd` so offload NICs could reserve TCP ports through the host socket layer, fixing collisions between RDMA and host TCP applications on shared IPs.
- **"RDMA/rw: Use MR for all iWARP RDMA READs" (2016, rdma_rw)** — encoded the STag-sink requirement once in the core, removing per-ULP iWARP special cases. (Message-ids unavailable: lore was unreachable this session.)
