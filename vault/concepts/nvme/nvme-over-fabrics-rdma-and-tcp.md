---
title: "NVMe over Fabrics: RDMA and TCP Transports"
category: concept
tags: [nvme, nvme-of, rdma, tcp, storage-networking, blk-mq]
subsystem: nvme
kernel_version: "4.8 (NVMe-oF RDMA host/target); 5.0 (NVMe/TCP); 6.7 (NVMe/TCP TLS)"
researched: 2026-09-26
status: complete
explained: "[[nvme-over-fabrics-rdma-and-tcp-explained]]"
sources:
  - https://github.com/torvalds/linux/blob/master/drivers/nvme/host/rdma.c
  - https://github.com/torvalds/linux/blob/master/drivers/nvme/host/tcp.c
  - https://github.com/torvalds/linux/blob/master/drivers/nvme/host/fabrics.c
  - https://github.com/torvalds/linux/blob/master/drivers/nvme/target/rdma.c
  - https://github.com/torvalds/linux/blob/master/drivers/nvme/target/tcp.c
  - https://lwn.net/Articles/772556/
  - https://lwn.net/Articles/952342/
  - https://lwn.net/Articles/941139/
  - https://lwn.net/Articles/856557/
  - https://lwn.net/Articles/1048984/
  - https://lwn.net/Articles/863204/
---

# NVMe over Fabrics: RDMA and TCP Transports

> 📘 Plain-language version: [[nvme-over-fabrics-rdma-and-tcp-explained]]

## Purpose

NVMe was designed as a PCIe protocol: submission and completion queues in host memory, doorbell registers, one small command per I/O, highly parallel queues. **NVMe over Fabrics (NVMe-oF)** carries that same queue-pair model across a network, so a host can use a remote SSD (or a whole storage array) with close to local latency. Commands and completions travel as **capsules**, data moves either inline or by transport-specific means. Linux implements both roles: the **host** (initiator: `nvme-rdma`, `nvme-tcp`, `nvme-fc` in `drivers/nvme/host/`) makes remote namespaces appear as ordinary `/dev/nvmeXnY` block devices, and the **target** (`nvmet` with `nvmet-rdma`, `nvmet-tcp`, `nvmet-fc` in `drivers/nvme/target/`) exports local block devices or files. RDMA and TCP are the two IP-network transports. They show in miniature the whole RDMA-vs-sockets tradeoff this vault's RDMA and io_uring notes explore.

## Mental Model

A local NVMe SSD is a **mailroom with a pneumatic tube**: the host drops command slips into a queue, rings a bell (doorbell), and the device pulls data straight out of host memory by DMA. NVMe-oF extends the tube across a network, and the transports differ in *who carries the parcels*:
- **RDMA**: the remote target's NIC reaches *directly into the host's memory*, using keys the host handed over in the command, and pulls or pushes the data itself (RDMA READ/WRITE). The host CPU only posts the command and later reads the completion.
- **TCP**: everything travels as a **byte stream of PDUs**. The host sends the command, then data flows in PDUs through both kernels' TCP stacks. The host CPU copies data out of socket buffers and computes digests, unless offloads help.

Same NVMe semantics, same block device, very different CPU cost per byte.

## How It Works

**Common fabric layer (`fabrics.c`).** `nvme connect -t rdma|tcp -a <ip> -s 4420 -n <subsysnqn>` (nvme-cli) writes an option string to `/dev/nvme-fabrics`. `nvmf_create_ctrl()` parses it (`struct nvmf_ctrl_options`: transport, traddr/trsvcid, NQNs, `nr_io_queues`, `queue_size`, `nr_poll_queues`, `nr_write_queues`, `hdr_digest`/`data_digest`, `tls`, keep-alive, reconnect/`ctrl_loss_tmo`) and calls the transport's `create_ctrl`. Each controller has one **admin queue** and N **I/O queues** (default one per CPU), each a separate transport connection, mapped 1:1 onto [[blk-mq]] hardware contexts. So a block request from CPU 5 is submitted on queue 5 with no cross-CPU locking, the property that makes NVMe scale. The host sends a **Fabrics Connect** command per queue (with host NQN and controller ID), optionally in-band **authentication** (DH-HMAC-CHAP, `auth.c`), and then standard NVMe admin (Identify, Set Features) and I/O commands. A **discovery controller** (`nvme discover`) returns log pages listing subsystems and ports. **Native NVMe multipath** (`multipath.c`) merges paths (e.g. two RDMA ports, or RDMA + TCP) into one `/dev/nvmeXnY` with ANA-aware path selection. On connection loss the host enters RECONNECTING and retries every `reconnect_delay` until `ctrl_loss_tmo`.

**RDMA transport — host (`host/rdma.c`).** Each queue is an rdma_cm connection (`nvme_rdma_cm_handler()` drives ADDR/ROUTE resolution and connect, with private data carrying queue ID and size) and an RC QP with a CQ from the shared pool (`ib_cq_pool_get`), polled via `IB_POLL_SOFTIRQ` or, for poll queues, `IB_POLL_DIRECT` from `nvme_rdma_poll()`. In `nvme_rdma_queue_rq()`, for each request:
1. The 64-byte **SQE** lives in a pre-mapped buffer. The data buffer is described with an NVMe **Keyed SGL** (`nvme_rdma_map_data()`) using the cheapest option:
   - *inline* (`nvme_rdma_map_sg_inline`): small writes up to the target's in-capsule data size are sent *in the SEND itself* with the PD's `local_dma_lkey`, with no registration and no remote access
   - *single* (`nvme_rdma_map_sg_single`): a single contiguous segment uses the PD's `unsafe_global_rkey`, only when `register_always=N` (default is Y, for security)
   - *fast registration* (`nvme_rdma_map_sg_fr`): otherwise, register an MR from the QP's pool with an `IB_WR_REG_MR` chained before the SEND, and put `{addr, length, rkey}` in the SGL. With T10-PI, an integrity MR is used instead.
2. `nvme_rdma_post_send()` posts REG_MR + SEND as one chain with one doorbell.
3. The **target does the data movement**. For a host read it RDMA WRITEs data into the host buffer. For a host write it RDMA READs from the host buffer. The host CPU never touches the data.
4. The completion capsule (CQE) arrives in a pre-posted receive buffer, and `nvme_rdma_recv_done()` completes the block request. The target sends the response with **SEND_WITH_INV** naming the rkey, so the host's MR is invalidated remotely with no extra local work request.

**RDMA transport — target (`target/rdma.c`).** `nvmet-rdma` listens through rdma_cm on port 4420 (configured in configfs `/sys/kernel/config/nvmet/ports/*`), posts receive buffers (optionally a shared SRQ per device, `use_srq`, `srq_size`), and for each command calls `rdma_rw_ctx_init()` to build RDMA READ/WRITE chains against the host's keyed SGL ([[rdma-rw-api]]), chaining the response SEND behind the WRITE. Backends are block devices (`io-cmd-bdev.c`, bio submission), files (`io-cmd-file.c`, kiocb), or NVMe **passthru** to a local controller. With P2PDMA the target can even move data between an RDMA NIC and an NVMe SSD's controller memory buffer without touching host RAM.

**TCP transport — host (`host/tcp.c`).** Each queue is a kernel TCP socket (port 4420, or 8009 for discovery), with `TCP_NODELAY`, a priority (`so_priority`), and a work item `io_work` pinned to a CPU (the queue's `io_cpu`, or unbound with `wq_unbound`). NVMe/TCP defines PDUs:
- *ICReq/ICResp* — connection initialization: negotiate header and data digests, `maxh2cdata`, PDU alignment
- *CapsuleCmd* / *CapsuleResp* — the SQE (+ in-capsule data) and the CQE
- *C2HData* — controller-to-host data for reads
- *R2T* (Ready to Transfer) + *H2CData* — for writes beyond in-capsule size, the target asks for data in chunks, so it can control buffer usage

Sending (`nvme_tcp_try_send()`): requests go on a lock-free `req_list`, and the submitting context either sends directly (if it owns `send_mutex` and is on the right CPU) or kicks `io_work`. Data PDUs are sent with **`MSG_SPLICE_PAGES`**, so bio pages are referenced into skbs instead of copied, falling back to copying for slab or unspliceable pages. Receiving: `sk->sk_data_ready` is hooked to `nvme_tcp_data_ready()`, which schedules `io_work`. That calls `sock->ops->read_sock(sk, desc, nvme_tcp_recv_skb)` to parse PDUs straight out of the socket receive queue. PDU headers go to a small buffer (`nvme_tcp_recv_pdu`), and C2HData payload is **copied** into the request's bio pages with `skb_copy_datagram_iter()` (`nvme_tcp_recv_data`). That receive copy, plus **CRC32c data digests** computed in software (`nvme_tcp_ddgst_update`), is the main CPU cost of NVMe/TCP compared with RDMA. Poll queues (`nr_poll_queues`) let `io_uring` IOPOLL or `RWF_HIPRI` spin in `nvme_tcp_poll()` → `nvme_tcp_try_recv()` with socket busy-polling instead of waiting for softirq plus workqueue.

**TCP transport — target (`target/tcp.c`).** This mirrors the host: a listener socket, per-queue `io_work`, R2T flow control for writes, `MSG_SPLICE_PAGES` sends of read data, and `read_sock` receive.

**TLS and authentication (TCP).** Since 6.7 (Hannes Reinecke), NVMe/TCP can run over **kernel TLS 1.3**: after TCP connect, the kernel asks userspace `tlshd` (ktls-utils) through the `net/handshake` netlink upcall (Chuck Lever) to perform the TLS handshake with a PSK from the `.nvme` keyring (`nvme gen-tls-key`), then continues with kTLS on the socket. The "concat" mode (secure channel concatenation) derives the TLS PSK from in-band DH-HMAC-CHAP authentication. 2025–26 work added handling of TLS **KeyUpdate** requests. Data digests are redundant under TLS and are disabled with it.

**Offloads for TCP.** Two approaches narrow the gap to RDMA without replacing TCP:
- **ULP DDP / CRC offload** (NVIDIA, Aurelien Aptel, v20 in Nov 2023): the NIC recognizes NVMe/TCP PDUs in the TCP stream, places C2HData directly into block-layer buffers (skipping the receive copy) and verifies CRC32c, while the kernel still runs TCP. Reported gains were up to 55% (no digest) and up to 138% (with digest) on ConnectX-7. As of this tree the `ulp_ddp` infrastructure is **not merged**; the series has gone through many revisions on netdev.
- **Full NVMeTCP offload** (Marvell QEDN, 2021): offloaded the whole NVMe/TCP queue into the NIC's TCP engine. It was rejected in the TOE tradition.

## Key Data Structures

**`struct nvme_rdma_queue`** (`host/rdma.c`) — `qp`, `ib_cq`, `cm_id`, `rsp_ring` (pre-posted receive buffers), `queue_size`, `cmnd_capsule_len`, `pi_support`.

**`struct nvme_rdma_request`** — SQE buffer, `sge[]` (command + inline data), `mr` (fast-reg MR), `reg_wr`, `reg_cqe`, `data_sgl`/`pi_sgl`.

**`struct nvme_tcp_queue`** (`host/tcp.c`) — `sock`, `io_work`, `io_cpu`, `req_list`/`send_list`, receive state (`pdu`, `pdu_remaining`, `data_remaining`, `ddgst_remaining`), `hdr_digest`/`data_digest`, `tls_enabled`, saved socket callbacks.

**`struct nvmf_ctrl_options`** (`fabrics.h`) — parsed connect options.

**`struct nvme_tcp_hdr` and PDU structs** (`include/linux/nvme-tcp.h`) — `type`, `flags`, `hlen`, `pdo`, `plen`.

**NVMe Keyed SGL descriptor** (`struct nvme_keyed_sgl_desc`) — `addr`, `length[3]`, `key[4]` (the rkey), `type`.

## Key Functions / Entry Points

- **`nvmf_create_ctrl()`** (`fabrics.c`) — parses options and dispatches to the transport
- **`nvme_rdma_queue_rq()` → `nvme_rdma_map_data()` → `nvme_rdma_post_send()`**; **`nvme_rdma_recv_done()`**; **`nvme_rdma_cm_handler()`**
- **`nvme_tcp_queue_rq()` → `nvme_tcp_queue_request()` → `nvme_tcp_try_send()`**; **`nvme_tcp_io_work()`**; **`nvme_tcp_recv_skb()`**; **`nvme_tcp_start_tls()`**
- **`nvmet_rdma_handle_command()` / `nvmet_rdma_rw_ctx_init()`** (`target/rdma.c`)
- **`nvmet_tcp_io_work()` / `nvmet_tcp_try_recv()` / `nvmet_tcp_try_send()`** (`target/tcp.c`)
- **`nvme_rdma_poll()` / `nvme_tcp_poll()`** — polled completions for IOPOLL

## Important Flags & Config Options

- `CONFIG_NVME_RDMA`, `CONFIG_NVME_TCP`, `CONFIG_NVME_TCP_TLS`, `CONFIG_NVME_TARGET_RDMA`, `CONFIG_NVME_TARGET_TCP`, `CONFIG_NVME_TARGET_TCP_TLS`, `CONFIG_NVME_AUTH`, `CONFIG_NVME_MULTIPATH`
- `nvme_rdma.register_always` (default Y) — refuse the unsafe global rkey
- `nvme_tcp.so_priority`, `nvme_tcp.wq_unbound`, `tls_handshake_timeout`
- `nvmet_rdma.use_srq`, `srq_size`
- nvme-cli: `--nr-io-queues`, `--nr-poll-queues`, `--nr-write-queues`, `--queue-size`, `--hdr-digest`, `--data-digest`, `--tls`, `--ctrl-loss-tmo`, `--reconnect-delay`
- configfs `/sys/kernel/config/nvmet/{subsystems,ports,hosts}` — target configuration (`nvmetcli`)

## Interactions with Other Subsystems

- **↑ Userspace**: nvme-cli (`connect`, `discover`, `gen-tls-key`), nvmetcli, `tlshd`; applications see block devices; io_uring can use `/dev/ng*` char devices with `IORING_OP_URING_CMD` passthrough ([[uring-cmd-passthrough]])
- **→ blk-mq**: one hardware context per fabric queue; poll queues for IOPOLL ([[blk-mq]])
- **→ RDMA**: rdma_cm, CQ pool, MR pools, `rdma_rw`, integrity MRs ([[rdma-cm-connection-manager]], [[rdma-rw-api]], [[queue-pairs-and-completion-queues]])
- **→ net**: kernel TCP sockets, `read_sock`, `MSG_SPLICE_PAGES`, kTLS, `net/handshake` ([[tcp-ip-stack]])
- **→ P2PDMA**: target can map NVMe CMB/PMR as RDMA buffers ([[p2pdma-peer-to-peer-dma]])
- **Compared with io_uring**: a userspace NVMe/TCP initiator (SPDK, or a custom io_uring-based one) can use io_uring networking, zero-copy send, zcrx receive and registered buffers. The kernel NVMe/TCP host already uses the same in-kernel primitives (splice-pages TX, `read_sock` RX). The remaining copy on receive is what zcrx, ULP DDP and RDMA each try to eliminate ([[io-uring-zero-copy-networking]])

## Design Decisions & Tradeoffs

- **RDMA: the target moves the data.** The host only registers memory and posts a SEND, with zero host CPU per byte and the lowest latency (about 10 µs added over local). It needs RDMA NICs on both ends and, for RoCE, a tuned lossless or ECN fabric. Security depends on rkeys, hence `register_always` and remote invalidation, so keys are valid only for the lifetime of one I/O.
- **TCP: run anywhere.** Any NIC, any network, standard congestion control, TLS, and simple deployment made NVMe/TCP the fastest-growing fabric after its 2018 introduction (Sagi Grimberg, Lightbits). The cost is CPU on the receive path: copy plus CRC plus stack processing, and slightly higher latency. Mitigations: `MSG_SPLICE_PAGES` for TX, poll queues and busy-poll, per-CPU queue affinity, and the ULP DDP proposal for RX.
- **One connection per CPU queue.** Preserves NVMe's lock-free parallelism across the fabric, at the cost of many connections (CPUs × controllers × paths) and many QPs for RDMA, which the shared CQ pool and SRQ mitigate.
- **Single-context byte-stream processing (TCP).** Each queue's socket is serviced by one `io_work` on one CPU. That avoids locking and keeps PDU parsing simple, but can bottleneck a single hot queue.
- **In-kernel vs userspace initiators.** The kernel stack gives block devices, multipath, page cache and filesystems. SPDK's userspace NVMe/TCP and NVMe/RDMA initiators bypass the kernel for maximum IOPS per core, but give up those integrations.

## How It Has Evolved

- **4.8 (2016)** — NVMe-oF host and target with RDMA (Christoph Hellwig, Sagi Grimberg, Jay Freyensee, Ming Lin …); `rdma_rw` created alongside
- **4.10–4.13** — FC transport; target file backend later (4.19)
- **5.0 (2019)** — NVMe/TCP host and target (Sagi Grimberg, Lightbits)
- **5.x** — native multipath with ANA, NVMe/TCP poll queues, discovery log changes, T10-PI over RDMA (5.8), target passthru (5.9)
- **6.0** — in-band authentication (DH-HMAC-CHAP, Hannes Reinecke)
- **6.5** — `MSG_SPLICE_PAGES` replaces `sendpage` in nvme-tcp host and target (David Howells)
- **6.7** — NVMe/TCP TLS 1.3 via `tlshd` handshake upcall
- **2023–26** — ULP DDP receive offload series (NVIDIA, unmerged); secure channel concatenation; TLS KeyUpdate handling (2025–26); PCI endpoint target (`pci-epf.c`)

## Further Reading

- LWN — [TCP transport binding for NVMe over Fabrics](https://lwn.net/Articles/772556/) (2018)
- LWN — [nvme: In-kernel TLS support for TCP](https://lwn.net/Articles/941139/) (2023)
- LWN — [nvme-tcp receive offloads](https://lwn.net/Articles/952342/) (2023)
- LWN — [NVMeTCP Offload ULP and QEDN Device Driver](https://lwn.net/Articles/856557/) (2021)
- LWN — [nvme: In-band authentication support](https://lwn.net/Articles/863204/)
- LWN — [nvme-tcp: Support receiving KeyUpdate requests](https://lwn.net/Articles/1048984/)
- NVM Express — NVMe over Fabrics and NVMe/TCP Transport specifications (TP 8000)
- Related: [[rdma]], [[rdma-rw-api]], [[blk-mq]], [[uring-cmd-passthrough]], [[io-uring-zero-copy-networking]], [[p2pdma-peer-to-peer-dma]]

## LKML Highlights

- **`<20181115171626.9306-1-sagi@lightbitslabs.com>`** — "TCP transport binding for NVMe over Fabrics" (Sagi Grimberg). One TCP socket per NVMe queue served by a bound workqueue context, "a completely non-blocking data plane to minimize context switching", header and data digests.
- **`<20230810150630.134991-1-hare@suse.de>`** — in-kernel TLS for NVMe/TCP (Hannes Reinecke). Handshake delegated to `tlshd` via the `net/handshake` upcall, PSKs in a `.nvme` keyring, `NVME_TCP_TLS`/`NVME_TARGET_TCP_TLS` options.
- **`<20231122134833.20825-1-aaptel@nvidia.com>`** — "nvme-tcp receive offloads" v20 (Aurelien Aptel). Generic `ulp_ddp` for direct data placement and CRC offload *alongside* the kernel TCP stack, with up to 138% bandwidth gains with digests. It has been debated for years over layering and whether NIC protocol awareness is acceptable, and is still out of tree.
