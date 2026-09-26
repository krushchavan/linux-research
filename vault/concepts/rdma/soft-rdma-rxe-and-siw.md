---
title: "Software RDMA: rxe (Soft-RoCE) and siw (soft-iWARP)"
category: concept
tags: [rdma, rxe, siw, soft-roce, iwarp, software-provider]
subsystem: rdma
kernel_version: "4.8 (rxe); 5.3 (siw)"
researched: 2026-09-26
status: complete
explained: "[[soft-rdma-rxe-and-siw-explained]]"
sources:
  - https://github.com/torvalds/linux/tree/master/drivers/infiniband/sw/rxe
  - https://github.com/torvalds/linux/tree/master/drivers/infiniband/sw/siw
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/sw/rxe/rxe_net.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/sw/rxe/rxe_odp.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/sw/siw/siw_cm.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/sw/siw/siw_qp_tx.c
  - https://raw.githubusercontent.com/torvalds/linux/master/MAINTAINERS
  - https://lwn.net/Articles/914607/
---

# Software RDMA: rxe (Soft-RoCE) and siw (soft-iWARP)

> 📘 Plain-language version: [[soft-rdma-rxe-and-siw-explained]]

## Purpose

RDMA applications and kernel ULPs need an RDMA device, but RDMA NICs are expensive and not everywhere: laptops, CI runners, cloud VMs, the "other end" of a heterogeneous link. Linux ships two **software RDMA providers** that implement the full verbs interface in the kernel on top of any ordinary Ethernet netdev:
- **rxe (Soft-RoCE)** — speaks RoCE v2: InfiniBand transport headers inside UDP/IP, port 4791. It can interoperate with hardware RoCE NICs.
- **siw (soft-iWARP)** — speaks iWARP: the RDMAP/DDP/MPA protocol stack over an ordinary **kernel TCP socket**. It can interoperate with hardware iWARP NICs (Chelsio, Intel irdma in iWARP mode).

They register a normal `ib_device`, so libibverbs, librdmacm, NVMe-oF, NFS/RDMA and the rest work unchanged. They exist for development, testing and interoperability. They give the RDMA *API* and one-sided semantics, not RDMA *performance*: the CPU does all the work the NIC would.

## Mental Model

A hardware RDMA NIC is a **dedicated courier company** with its own trucks: your CPU hands off a parcel and forgets it. rxe and siw are **the same courier brand run from your own garage**. The paperwork (verbs, WQEs, CQEs, keys) is identical and the recipient can't tell the difference, but every delivery is driven by your own CPU in kernel threads, and it rides the public roads (the kernel's UDP or TCP stack) rather than a private lane. That makes it perfect for rehearsals and for talking to a real courier on the other end, and useless when you actually need the CPU for other work.

## How It Works

**Creating a device.** Both register `rdma_link_ops` with the core. An admin runs `rdma link add rxe0 type rxe netdev eth0` (or `type siw`), which reaches `nldev_newlink()` → `rxe_newlink()` → `rxe_net_add(ibdev_name, ndev)`, or the siw equivalent. The provider allocates an `ib_device` with `dma_device = NULL`. That makes `ib_uses_virt_dma()` true: "DMA addresses" in SGEs and umems are plain kernel virtual addresses, because the "device" is the CPU. It binds the port to the netdev and registers. For rxe, the core's RoCE GID management then fills the GID table from the netdev's IPs like for any RoCE port ([[roce-gid-table-and-netdev-binding]]). Deleting the netdev or running `rdma link del` unregisters the device, and uverbs users are disassociated.

**Userspace data path.** rdma-core's `librxe` and `libsiw` providers keep the verbs data path mostly in userspace memory: the SQ, RQ and CQ rings are shared memory mmapped from the kernel (`rxe_mmap.c`, `siw` mmap), and `ibv_poll_cq` is still a pure memory read. There is no hardware to notice a doorbell, so **`ibv_post_send` ends in a syscall** (the uverbs `POST_SEND` command) that kicks the kernel's send engine. Receives can be posted to the shared RQ without a syscall.

### rxe (Soft-RoCE)

**Transport engines.** Each rxe QP has three work items (`struct rxe_task`: a work_struct plus state), historically tasklets and converted to workqueues so they may sleep, which was needed for ODP page faults:
- **requester** (`rxe_req.c`) — walks the SQ, splits each WQE into MTU-sized packets, builds BTH/RETH/AETH/ATMETH headers (`rxe_hdr.h`), copies payload from the source MR (`rxe_mr_copy()`, which resolves lkey → pages, or faults them in for ODP MRs), and hands packets to `rxe_xmit_packet()`.
- **responder** (`rxe_resp.c`) — processes inbound requests: checks PSN ordering, validates rkey/PD/access for RDMA WRITE/READ/atomics, copies into or out of the target MR, generates ACKs and READ responses, and consumes RQ WQEs for SENDs. Duplicate and out-of-order detection follows the IBTA RC rules.
- **completer** (`rxe_comp.c`) — processes ACKs, NAKs and READ responses for the requester side, runs the retransmit and RNR timers, and posts CQEs.

**Networking.** `rxe_net.c` opens a kernel **UDP tunnel socket** on port 4791 per network namespace (`rxe_ns.c` keeps IPv4 and IPv6 sockets per netns, created lazily with the first device), with `encap_rcv = rxe_udp_encap_recv`. Received UDP datagrams to 4791 are diverted straight into `rxe_rcv()`, which verifies the **ICRC** (the invariant CRC over IB headers and payload, computed in software, `rxe_icrc.c`) and dispatches to the responder or completer queue of the destination QP. Transmit builds an skb with IP/UDP headers from the path's GID attributes and sends it with `ip_local_out()`, so the packet goes through the host's routing, netfilter and qdisc, which hardware RoCE bypasses. Multicast (`rxe_mcast.c`) maps IB multicast onto IP multicast.

**Features.** RC, UC and UD QPs, SRQ, memory windows, atomics (including ATOMIC_WRITE), FLUSH for persistent memory, and **ODP** (`rxe_odp.c`, Daisuke Matsuda / Fujitsu, 6.x): rxe checks `HMM_PFN_VALID` per page and calls the core's `ib_umem_odp_map_dma_and_lock()` itself when a page isn't present, then copies under `umem_mutex`. Software counters (`rxe_hw_counters.c`) mirror hardware ones (retries, duplicates, sequence errors).

### siw (soft-iWARP)

**Connection management.** iWARP connections are TCP connections. `siw_cm.c` implements the iWARP CM provider: on `connect` it creates a kernel TCP socket, connects, and exchanges **MPA** request and reply frames (carrying rdma_cm private data and negotiating CRC and markers). It then hooks the socket's `sk_data_ready` to `siw_qp_llp_data_ready()`. The `iwpmd` port mapper coordinates port numbers with the host TCP stack.

**Receive.** When TCP has data, `sk_data_ready` runs `tcp_read_sock(sk, &rd_desc, siw_tcp_rx_data)`. siw parses DDP segments directly out of the TCP receive queue (`siw_qp_rx.c`): tagged segments (RDMA WRITE, READ response) are placed straight at the STag+offset in the target memory region, and untagged ones (SEND) into the next RQ buffer. The MPA CRC32c is verified if negotiated. Because DDP segments carry their own placement information, data lands in its final location even though it arrived over a byte stream.

**Transmit.** Posting a WR queues it and either processes it inline or wakes a **per-CPU TX kthread** (`siw_run_sq`) that runs `siw_sq_resume()`. `siw_qp_tx.c` frames FPDUs (MPA framing + DDP + RDMAP headers) and sends them with `sock_sendmsg()` using **`MSG_SPLICE_PAGES`**, a zero-copy TCP transmit that references the MR's pages instead of copying them, falling back to copying when pages can't be spliced. It stops when the socket's send buffer is full and resumes from the TX thread when space frees up. Optional GSO-sized FPDUs (`try_gso`, if both ends agree) cut per-segment overhead.

## Key Data Structures

**`struct rxe_dev`** (`rxe_verbs.h`) — embeds `ib_device`; object pools (`rxe_pool`) for QPs, CQs, MRs, etc.; `ndev` binding; stats.

**`struct rxe_qp`** — `req`/`resp`/`comp` state and their `rxe_task`s; SQ/RQ as `rxe_queue` (shared with userspace); PSN tracking; retransmit and RNR timers.

**`struct rxe_task`** (`rxe_task.h`) — `work`, `state`, `func`, scheduling counters.

**`struct siw_device` / `struct siw_qp`** (`siw.h`) — `siw_qp` holds `tx_ctx` and `rx_stream` (DDP parsing state), the CEP (connection endpoint) with the TCP socket, and the SQ/RQ/ORQ/IRQ arrays (outbound and inbound READ queues).

**`struct siw_cep`** (`siw_cm.h`) — connection endpoint: socket, MPA state machine, saved `sk_data_ready`.

## Key Functions / Entry Points

- **`rxe_newlink()` / `rxe_net_add()`** — create a Soft-RoCE device on a netdev
- **`rxe_udp_encap_recv()` → `rxe_rcv()`** — inbound packet path
- **`rxe_requester()` / `rxe_responder()` / `rxe_completer()`** — transport engines
- **`rxe_xmit_packet()` / `rxe_icrc_generate()`** — outbound path
- **`rxe_odp_mr_copy()` / `rxe_odp_mr_init_user()`** — software ODP
- **`siw_newlink()`**, **`siw_connect()` / `siw_accept()`** (`siw_cm.c`) — device and connection setup
- **`siw_tcp_rx_data()`** (`siw_qp_rx.c`) — DDP placement from the TCP receive queue
- **`siw_qp_sq_process()` / `siw_run_sq()`** (`siw_qp_tx.c`) — transmit

## Important Flags & Config Options

- `CONFIG_RDMA_RXE` (selects `NET_UDP_TUNNEL`, `CRC32`), `CONFIG_RDMA_SIW` (selects `CRYPTO_CRC32C`)
- `rdma link add <name> type rxe|siw netdev <ifname>`; `rdma link del <name>`
- siw compile-time tunables (const globals in `siw_main.c`, not module parameters): `zcopy_tx`, `try_gso`, `loopback_enabled`, `mpa_crc_required`, `mpa_crc_strict`, `siw_tcp_nagle`, `peer_to_peer`
- rdma_cm `default_roce_mode` must be RoCE v2 when talking to rxe (rxe doesn't do v1)
- Netdev MTU caps RoCE path MTU (RoCE MTUs are 256…4096 and must fit in the Ethernet MTU with headers)

## Interactions with Other Subsystems

- **↑ Userspace**: rdma-core `librxe`/`libsiw` providers; the same `ibv_*` and `rdma_*` APIs; used heavily by rdma-core's and the kernel's RDMA selftests (`tools/testing/selftests/rdma/rxe*`)
- **→ net (rxe)**: UDP tunnel sockets, `ip_local_out()`, routing, neighbour, netfilter, qdisc, netns; GID table from netdev IPs
- **→ net (siw)**: kernel TCP sockets, `tcp_read_sock`, `MSG_SPLICE_PAGES`, iWARP port mapper over netlink
- **→ mm**: umem without DMA (virtual addresses), ODP through HMM (rxe)
- **← rdma core**: registered like hardware; `rdma_link_ops` for creation; disassociation on removal
- **Compared with io_uring**: a siw QP is effectively kernel TCP driven by a kernel thread with zero-copy send, which is close to what io_uring's `IORING_OP_SEND_ZC` plus a registered buffer does. The difference is that siw exposes RDMA semantics (placement by STag, one-sided READ/WRITE) that a remote hardware iWARP NIC can serve without its CPU.

## Design Decisions & Tradeoffs

- **Full protocol in software, standard wire format.** Interoperability with hardware peers is the main value: a server with an RDMA NIC can serve many clients without one, and the server side still gets hardware offload. The cost is that client CPU does per-packet work, ICRC or CRC32c, and copies (rxe copies payload into skbs, while siw can splice pages on transmit).
- **UDP (rxe) vs TCP (siw).** RoCE v2 assumes a *lossless* fabric (PFC/ECN). rxe has only IB-style go-back-N retransmission and does badly under loss. iWARP rides TCP, so siw inherits congestion control, loss recovery and middlebox friendliness, which makes it the more robust software option on lossy networks.
- **Virtual DMA addresses.** Setting `dma_device = NULL` removes DMA-mapping cost and IOMMU complexity. It also means software providers can't take part in P2P or dma-buf flows that need real bus addresses, and can't use the DMA IOVA paths in `rdma_rw`.
- **Tasklets → workqueues (rxe).** Needed for ODP (faults sleep) and to reduce softirq latency spikes. It costs some latency from scheduling.
- **Syscall per post.** Unavoidable without hardware doorbells. It makes software RDMA a poor fit for small-message rates, but acceptable for correctness and bulk transfers.

## How It Has Evolved

- **4.8 (2016)** — rxe merged (originally from System Fabric Works; maintained by Mellanox, then Zhu Yanjun)
- **5.3 (2019)** — siw merged (Bernard Metzler, IBM Zurich)
- **5.x** — rxe memory windows, atomic write, FLUSH; siw GSO, MPA CRC options; many syzkaller-driven fixes to both
- **6.2–6.x** — rxe tasklet → workqueue conversion; rxe ODP (explicit, then prefetch, atomics, flush); per-netns rxe sockets (`rxe_ns.c`); siw moves from `sendpage` to `MSG_SPLICE_PAGES` (6.5)
- **Current maintainers** — rxe: Zhu Yanjun; siw: Bernard Metzler (MAINTAINERS)

## Further Reading

- LWN — [On-Demand Paging on SoftRoCE](https://lwn.net/Articles/914607/)
- rdma-core — `providers/rxe`, `providers/siw`; `Documentation/rxe.md`
- RFC 5040 (RDMAP), RFC 5041 (DDP), RFC 5044 (MPA) — iWARP specifications
- IBTA RoCE v2 annex (Annex A17) — RoCE v2 encapsulation
- Related: [[rdma]], [[roce-v1-and-v2]], [[iwarp-transport]], [[on-demand-paging-odp]], [[tcp-ip-stack]]

## LKML Highlights

- **"RDMA/rxe: On-Demand Paging on SoftRoCE" `<cover.1668157436.git.matsuda-daisuke@fujitsu.com>`** — converted the requester, responder and completer tasklets to workqueues so rxe can sleep on page faults, and implemented explicit ODP without hardware support. Motivated by RDMA to persistent memory with concurrent filesystem metadata updates.
- **"SIW: software iWARP kernel driver module" (Bernard Metzler, 2017–2019)** — went through many revisions over two years. Reviewers questioned the value of software iWARP and asked for the transmit path to use core TCP interfaces cleanly. It was merged for 5.3.
- **rxe maintenance and syzkaller fixes (2020–2024)** — a long run of use-after-free and race fixes in rxe's pools and task scheduling that led to the workqueue rework. (Specific message-ids unavailable: lore was unreachable this session.)
