---
title: "Storage Fabrics Compared: NVMe/RDMA vs NVMe/TCP vs iSER/iSCSI vs NVMe/FC vs NFS over RDMA (Kernel vs SPDK Targets)"
category: concept
tags: [comparison, nvme-of, iscsi, rdma, nfs, spdk]
subsystem: comparisons
kernel_version: "iSCSI initiator 2.6.13; iSER initiator 2.6.19; LIO target 2.6.38 (isert 3.10); NFS/RDMA 2.6.24; NVMe-oF RDMA 4.8; NVMe/FC 4.10; NVMe/TCP 5.0; NVMe/TCP TLS 6.7"
researched: 2026-09-26
status: complete
sources:
  - https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/configuring-nvme-over-fabrics-using-nvme-fc_managing-storage-devices
  - https://access.redhat.com/solutions/3522911
  - https://documentation.suse.com/sles/15-SP5/html/SLES-all/cha-nvmeof.html
  - https://docs.nvidia.com/networking/display/mlnxofedv551032/iscsi+extensions+for+rdma+(iser)
  - https://www.iol.unh.edu/knowledge/implementation-and-comparison-iscsi-over-rdma
  - https://www.starwindsoftware.com/blog/iscsi-vs-nvme-of-performance-comparison/
  - https://review.spdk.io/download/performance-reports/SPDK_rdma_perf_report_2107.pdf
  - https://simplyblock.io/glossary/nvme-over-rdma-vs-nvme-over-tcp/
  - https://simplyblock.io/glossary/spdk-target/
  - https://spdk.io/blog/
---

# Storage Fabrics Compared: NVMe/RDMA vs NVMe/TCP vs iSER/iSCSI vs NVMe/FC vs NFS over RDMA

> Comparison note under `comparisons/`. Deep dives: [[nvme-over-fabrics-rdma-and-tcp]], [[nfs-over-rdma-svcrdma-xprtrdma]], [[rdma-rw-api]], [[blk-mq]]. Related comparisons: [[rdma-transports-infiniband-roce-iwarp-efa-srd-ultra-ethernet]], [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk]], [[polling-vs-interrupts-io-uring-napi-rdma-cq]].

## Purpose

Every networked storage protocol has to solve the same four problems:

1. **Command transport**: carry a read or write request, and its status, between initiator and target.
2. **Data movement**: move the payload, ideally straight between the initiator's buffer and the target's media buffer without extra copies.
3. **Queueing and parallelism**: how many independent queues exist, and how they map onto CPUs.
4. **Failure handling**: path loss, reconnection, multipath.

The protocols in Linux split along two axes. The first is the **command set**: SCSI (iSCSI, iSER, FCP) versus NVMe (NVMe-oF over RDMA, TCP or FC) versus file (NFS). The second is the **data mover**: RDMA one-sided operations, TCP byte streams, or Fibre Channel exchanges. The target side adds a third choice: the **in-kernel target** (`nvmet`, LIO, `nfsd`) or a **userspace polled target** (SPDK). This note compares them.

## Mental Model

A warehouse (the target) taking orders from shops (initiators):

- **iSCSI**: orders and goods travel as **one long conveyor belt (a single TCP connection per session)**. Each order is wrapped in SCSI paperwork designed for one disk with a single queue. It is reliable and runs anywhere, but everything funnels through one belt.
- **iSER**: the same SCSI paperwork, but the warehouse's **forklift reaches directly into the shop's stockroom** (RDMA) to drop off or pick up goods.
- **NVMe-oF**: new, lean paperwork designed for flash, and **one private lane per CPU** (per-queue connections). Over RDMA the warehouse's forklift does the lifting. Over TCP the goods ride in lane conveyors. Over FC they ride on the existing dedicated freight rail.
- **NFS/RDMA**: the order is for a *file* rather than a block. The server's forklift still moves bulk data straight in and out of the client's page cache.
- **SPDK target**: the warehouse **fires its dispatchers and has clerks stand at every lane polling continuously**. Throughput per clerk is much higher, but clerks are never idle.

## How It Works

### 1. iSCSI: SCSI over a TCP stream

iSCSI (RFC 3720/7143) wraps SCSI CDBs and data in **PDUs** carried over TCP (port 3260). A **session** between initiator IQN and target IQN usually has **one TCP connection** (multiple connections per session, MC/S, exist in the spec but Linux's initiator doesn't support them, and dm-multipath across sessions is used instead). The Linux initiator is **open-iscsi**: `iscsid` in userspace handles login and discovery, and the kernel `libiscsi` + `iscsi_tcp` data path appears as a SCSI host (`scsi_transport_iscsi`), so disks show up as `/dev/sdX` through the SCSI midlayer. The in-kernel target is **LIO** (`drivers/target/`, `iscsi_target_mod`), configured through configfs with `targetcli`.

Data movement: writes can carry **immediate/unsolicited data** up to `FirstBurstLength`. Larger writes wait for target **R2T** PDUs, and reads come back as Data-In PDUs. Payload is copied between socket buffers and SCSI scatterlists on both ends. Header and data digests (CRC32c) are optional and CPU-costly.

**Limits**: the SCSI midlayer and a single connection per session serialise work. Queue depth is per session, not per CPU. iSCSI was designed when a LUN was a spinning disk, so against NVMe SSDs the protocol stack, not the media, becomes the bottleneck. Benchmarks commonly show NVMe/TCP delivering substantially more IOPS per core than iSCSI on the same network.

### 2. iSER: iSCSI with RDMA as the data mover

**iSER** (RFC 7145) keeps iSCSI's login, session model and SCSI semantics, but replaces the TCP data path with an **RDMA datamover**. Command and status PDUs travel as RDMA SENDs. For a READ the target **RDMA WRITEs** data into the initiator's registered buffer, and for a WRITE the target **RDMA READs** from it, with **no R2T round trips** and no copies. Linux has the initiator **`ib_iser`** (`drivers/infiniband/ulp/iser/`, 2.6.19), plugged in as an iSCSI transport so open-iscsi selects it by `iface.transport_name=iser`, and the target **`ib_isert`** (`drivers/infiniband/ulp/isert/`, 3.10) plugged into LIO. Both register memory with fast-registration MRs, use T10-PI signature MRs for end-to-end data integrity, and run on any verbs transport (IB, RoCE, iWARP), with iSER using `rdma_rw` on the target side for READ/WRITE chains.

iSER gave RDMA-class latency to existing SCSI deployments. It still carries the SCSI midlayer and per-session queueing, and it has been largely superseded by NVMe/RDMA for new flash deployments.

### 3. NVMe over RDMA: NVMe queues as RDMA QPs

NVMe-oF ([[nvme-over-fabrics-rdma-and-tcp]]) keeps NVMe's defining property: **many independent submission/completion queue pairs**. The host creates one admin queue and **one I/O queue per CPU**, each a **separate RC QP**, mapped 1:1 to [[blk-mq]] hardware contexts. There's no SCSI midlayer and no cross-CPU locking. Commands are 64-byte **capsules** in RDMA SENDs. The data buffer is described by a **keyed SGL** (address, length, rkey): small writes go **in-capsule**, and larger buffers are registered with a fast-registration `IB_WR_REG_MR` chained before the SEND. The **target moves the data**: RDMA WRITE for reads, RDMA READ for writes (via `rdma_rw_ctx_init()`), then a response SEND. The response uses **SEND_WITH_INV** so the host's MR is invalidated remotely. The host CPU never touches payload. Target `nvmet-rdma` supports **SRQ** per device and **P2PDMA**, moving data between the NIC and an NVMe SSD's controller memory buffer without touching host DRAM.

Poll queues (`nr_poll_queues`) let io_uring IOPOLL spin on the RDMA CQ via `ib_process_cq_direct()` for interrupt-free completion. Latency adds roughly 5–10 µs over local NVMe. Needs: an RDMA fabric (IB or well-run RoCE), memory registration and `RLIMIT_MEMLOCK` sizing ([[memory-pinning-and-registration-strategies]]).

### 4. NVMe over TCP: NVMe queues as TCP sockets

NVMe/TCP (5.0) keeps the per-CPU queue model but makes each queue a **kernel TCP socket** (port 4420). PDUs are ICReq/ICResp, CapsuleCmd/CapsuleResp, C2HData for reads, and **R2T + H2CData** for writes beyond in-capsule size. Per-queue `io_work` runs on a chosen CPU. Sends use **`MSG_SPLICE_PAGES`** (zero-copy from bio pages). Receives parse PDUs straight out of the socket queue with `read_sock`, but payload is still **copied** into bio pages, and optional **CRC32c data digests** are computed in software. Those two costs are the gap to RDMA.

What it buys is **deployability**: any Ethernet, any NIC, routable, with no PFC, no special switches and no memory registration. Security comes from **TLS 1.3 via kernel TLS** (6.7, handshake by `tlshd` through the `net/handshake` upcall) and in-band **DH-HMAC-CHAP** authentication. Narrowing the CPU gap: NIC **ULP DDP + CRC offload** (NVIDIA, long-running netdev series, not merged as of this tree) would place C2HData directly into block buffers, and busy-poll or poll queues cut latency. NVMe/TCP is now the default "NVMe-oF for everyone" choice, and hyperscale block services and most new storage arrays support it.

### 5. NVMe over Fibre Channel: NVMe on existing SAN rails

**FC-NVMe** (T11 FC-NVMe/FC-NVMe-2) maps NVMe capsules and data onto Fibre Channel **exchanges and sequences**, alongside SCSI FCP traffic on the same HBAs and switches. The FC fabric is **lossless by design** (buffer-to-buffer credits, like InfiniBand), provides zoning and name services, and the HBA offloads data movement, so the host CPU never copies payload. This is the storage equivalent of RDMA without an RDMA stack.

In Linux the transport-independent **`nvme-fc`** host (`drivers/nvme/host/fc.c`, 4.10) and **`nvmet-fc`** target (`drivers/nvme/target/fc.c`) sit above LLDDs that implement `nvme_fc_port_template`: Broadcom/Emulex **lpfc** (host and target; target ports selected with `lpfc_enable_nvmet=<WWPNs>`) and Marvell/QLogic **qla2xxx** (host). Enterprise distributions have supported NVMe/FC fully since RHEL 7.6/8.0. Connections are discovered through FC name-server events, and udev rules (`nvmefc-boot-connections`, `nvme connect-all`) auto-connect when remote ports appear. The testing driver **`fcloop`** emulates an FC fabric in software. NVMe/FC's niche is clear: shops with a Fibre Channel SAN investment can run NVMe end to end without adopting RDMA or giving up FC's operational model (zoning, dedicated storage network).

### 6. NFS over RDMA: files, with bulk data by RDMA

NFS/RDMA ([[nfs-over-rdma-svcrdma-xprtrdma]]) replaces the **SunRPC transport** under NFS rather than the file protocol ([[sunrpc]]). RPC calls and replies travel as RDMA SENDs (port 20049) with **credit-based flow control**, and each message carries **chunk lists**: a *read list* the server RDMA READs from the client (NFS WRITE payload), a *write list* the server RDMA WRITEs into (NFS READ data), and a *reply chunk* for large replies. The client (`xprtrdma`) registers page-cache pages with FRWR, and the server (`svcrdma`) uses `rdma_rw` and replies with SEND_WITH_INV. The client guarantees that no page returns to the page cache while a peer could still write it.

Compared with block fabrics, NFS/RDMA gives **shared file semantics** (locking, delegations, pNFS layouts) with RDMA data movement. It is common in HPC and appliance storage. Its per-RPC chunk marshalling makes small-I/O latency higher than NVMe/RDMA, but large sequential I/O approaches wire speed with little CPU.

### 7. Kernel targets vs SPDK

Every fabric above has an **in-kernel target**: `nvmet` (RDMA, TCP, FC, loop, passthru), **LIO** (iSCSI, iSER, FC, SRP, vhost-scsi), and **nfsd** (TCP, RDMA). They are interrupt-driven with NAPI and CQ polling hybrids, integrate with the block layer (dm, md, bcache, NVMe multipath), are configured via configfs, and share CPUs with other work.

**SPDK** runs the entire target in userspace: a **polled** userspace NVMe driver (vfio/uio, [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk]]), userspace RDMA via verbs (already kernel-bypass), and for TCP either kernel sockets with busy-poll, or io_uring, or a DPDK/VPP stack. Pinned reactor threads **poll** network and NVMe queues continuously, with a lockless message-passing model and no interrupts or context switches. SPDK reports **up to ~8× more IOPS per core and ~90% less software latency** than the kernel target in its RDMA perf reports. The cost:
- dedicated cores burning 100% CPU even when idle (HotStorage '25 measured most polling cycles wasted at moderate load)
- the SSDs are removed from the kernel (no filesystem or dm on the target)
- separate tooling and upgrades, and its own failure domain.

The kernel has been closing the gap with io_uring passthrough, poll queues, SRQ, NAPI busy-poll and IRQ suspension ([[polling-vs-interrupts-io-uring-napi-rdma-cq]]). The rule of thumb: SPDK for dedicated storage appliances where every core-µs counts, the kernel target for general servers, hyperconverged nodes and anything needing kernel storage features.

### 8. Side-by-side

| | iSCSI | iSER | NVMe/RDMA | NVMe/TCP | NVMe/FC | NFS/RDMA |
|---|---|---|---|---|---|---|
| Command set | SCSI | SCSI | NVMe | NVMe | NVMe | NFS (file) over RPC |
| Wire | TCP 3260 | RDMA (IB/RoCE/iWARP) | RDMA, rdma_cm port 4420 | TCP 4420 (8009 discovery) | FC exchanges | RDMA, port 20049 |
| Queues | per session (1 conn) | per session | **per-CPU QPs** | **per-CPU sockets** | per-CPU FC queues | per transport; credits |
| Data movement | TCP copy both ways | target RDMA READ/WRITE | target RDMA READ/WRITE, in-capsule small writes | send zero-copy (splice), **receive copy** | HBA offload | server RDMA READ/WRITE via chunks |
| Write flow control | R2T | none (RDMA READ) | none (RDMA READ) | R2T / H2CData | FC XFER_RDY | read chunks |
| Integrity | CRC32c digests (SW) | T10-PI sig MRs | T10-PI integrity MRs | digests (SW) or TLS | FC CRC + T10-PI | RDMA ICRC |
| Security | CHAP, IPsec | CHAP | DH-HMAC-CHAP | **TLS 1.3 (kTLS)**, DH-HMAC-CHAP | zoning, LUN masking | RPCSEC_GSS / Kerberos |
| Network needs | any IP | RDMA fabric | RDMA fabric | any IP | FC SAN | RDMA fabric |
| Multipath | dm-multipath | dm-multipath | native NVMe ANA | native NVMe ANA | native NVMe ANA | session trunking / nconnect |
| Linux host | open-iscsi + `iscsi_tcp` | `ib_iser` | `nvme-rdma` | `nvme-tcp` | `nvme-fc` + lpfc/qla2xxx | `xprtrdma` |
| Linux target | LIO | LIO + `ib_isert` | `nvmet-rdma` | `nvmet-tcp` | `nvmet-fc` (lpfc) | `svcrdma` (nfsd) |
| SPDK target | yes (iSCSI) | no | yes | yes | FC via vendor | no |

## Key Data Structures

**`struct nvmf_ctrl_options`** (`drivers/nvme/host/fabrics.h`) — transport, address, NQNs, queue counts (`nr_io_queues`, `nr_write_queues`, `nr_poll_queues`), digests, TLS, reconnect timers.

**`struct nvme_fc_port_template`** (`include/linux/nvme-fc-driver.h`) — the LLDD operations (`create_queue`, `fcp_io`, `ls_req`) an FC HBA driver supplies to `nvme-fc`.

**`struct iscsi_transport`** (`include/scsi/scsi_transport_iscsi.h`) — lets `iscsi_tcp`, `ib_iser` and offload HBAs plug into open-iscsi's session model.

**`struct se_device` / `struct se_cmd`** (`include/target/target_core_base.h`) — LIO's backend device and command, shared by iSCSI, iSER, FC and vhost fabrics.

**`struct rpcrdma_xprt` / `struct svcxprt_rdma`** — client and server NFS/RDMA transports.

## Key Functions / Entry Points

- **`nvmf_create_ctrl()`** (`drivers/nvme/host/fabrics.c`) — entry from `nvme connect`.
- **`nvme_rdma_queue_rq()` / `nvme_tcp_queue_rq()` / `nvme_fc_queue_rq()`** — per-transport blk-mq submission.
- **`nvmet_rdma_handle_command()` / `nvmet_tcp_io_work()` / `nvmet_fc_handle_fcp_rqst()`** — target command intake.
- **`iser_send_command()`** (`drivers/infiniband/ulp/iser/iser_initiator.c`), **`isert_put_datain()`** — iSER data paths.
- **`rpcrdma_marshal_req()`**, **`svc_rdma_sendto()`** — NFS/RDMA chunk marshalling and reply.

## Important Flags & Config Options

- `CONFIG_NVME_RDMA`, `CONFIG_NVME_TCP`, `CONFIG_NVME_TCP_TLS`, `CONFIG_NVME_FC`, `CONFIG_NVME_TARGET_{RDMA,TCP,FC,FCLOOP,PASSTHRU}`, `CONFIG_NVME_MULTIPATH`.
- `CONFIG_ISCSI_TCP`, `CONFIG_INFINIBAND_ISER`, `CONFIG_INFINIBAND_ISERT`, `CONFIG_ISCSI_TARGET`, `CONFIG_TARGET_CORE`.
- `CONFIG_SUNRPC_XPRT_RDMA` (client and server).
- nvme-cli: `--nr-poll-queues`, `--nr-write-queues`, `--hdr-digest`, `--data-digest`, `--tls`, `--ctrl-loss-tmo`; nvmet configfs `param_inline_data_size`, `use_srq`.
- lpfc `lpfc_enable_fc4_type`, `lpfc_enable_nvmet`; qla2xxx `ql2xnvmeenable`.
- open-iscsi `iface.transport_name=iser`, `FirstBurstLength`, `MaxRecvDataSegmentLength`.

## Interactions with Other Subsystems

- **↑ Userspace**: nvme-cli/libnvme, `nvme-stas` (discovery), open-iscsi/`iscsiadm`, `targetcli` (LIO), `nvmetcli`, `tlshd`, `mount -o proto=rdma`.
- **→ Block layer**: NVMe-oF hosts are blk-mq drivers ([[blk-mq]]); iSCSI/iSER/FCP go through the SCSI midlayer; targets submit bios or passthru commands.
- **→ RDMA**: iSER, NVMe/RDMA and NFS/RDMA share rdma_cm, FRWR registration and `rdma_rw` ([[rdma-rw-api]], [[rdma-transports-infiniband-roce-iwarp-efa-srd-ultra-ethernet]]).
- **→ Networking**: NVMe/TCP and iSCSI use kernel TCP, kTLS, `net/handshake`, busy-poll, `MSG_SPLICE_PAGES` ([[tcp-ip-stack]]).
- **→ DMA**: P2PDMA for NIC↔SSD CMB transfers in `nvmet-rdma` ([[p2pdma-peer-to-peer-dma]]).

## Design Decisions & Tradeoffs

- **Command set matters more than wire.** Moving from SCSI to NVMe (per-CPU queues, 64-byte commands, no midlayer) is why NVMe/TCP beats iSCSI on the same network, and why iSER never caught NVMe/RDMA despite sharing RDMA data movement.
- **Who moves the data.** RDMA and FC let the *target* (or HBA) place payload directly in host memory, so the host CPU does no data work. TCP transports must copy on receive unless DDP offload lands. This is the core efficiency gap and the reason for the long-running ULP DDP series.
- **Deployability vs efficiency.** RDMA needs a well-run fabric (lossless RoCE or IB) and memory registration; FC needs a SAN; TCP needs nothing. The market has largely picked NVMe/TCP for general use, NVMe/RDMA for low-latency AI and HPC storage, and NVMe/FC for FC shops.
- **Target-driven writes.** NVMe/RDMA and iSER eliminate R2T by having the target RDMA READ write data when it's ready, which gives the target natural flow control without a round trip. TCP transports use R2T/H2C to achieve the same buffer control at the cost of latency on large writes.
- **Kernel vs SPDK.** Polling in userspace wins on IOPS per core and tail latency but monopolises cores and gives up kernel storage features. The kernel's response has been to import polling selectively (poll queues, IOPOLL, busy-poll, SRQ) rather than adopt the always-poll model.
- **Security moves into the transport.** NVMe/TCP adopted TLS 1.3 via kTLS plus in-band authentication. RDMA transports lean on fabric isolation (P_Keys, VLANs) and have no standard wire encryption, a gap UET's TSS and vendor RoCE encryption are addressing.

## How It Has Evolved

- **2.6.13 (2005)** — open-iscsi initiator merged; 2.6.19 iSER initiator.
- **2.6.24 (2008)** — NFS/RDMA client; server shortly after.
- **2.6.38 (2011)** — LIO becomes the in-kernel SCSI target (replacing STGT/SCST contention); 3.10 adds `ib_isert`.
- **4.8 (2016)** — NVMe-oF with RDMA transport, host and `nvmet` target.
- **4.10 (2017)** — NVMe/FC host and target, lpfc support; qla2xxx follows.
- **5.0 (2019)** — NVMe/TCP host and target (Sagi Grimberg).
- **5.x** — native NVMe multipath/ANA default; P2PDMA in nvmet-rdma; poll queues for RDMA and TCP; in-band authentication (6.0).
- **6.x** — `MSG_SPLICE_PAGES` for NVMe/TCP sends (6.5); **TLS for NVMe/TCP** (6.7); secure channel concatenation and TLS KeyUpdate (2025–26); ULP DDP offload series still iterating.

## Further Reading

1. Vault deep dives: [[nvme-over-fabrics-rdma-and-tcp]], [[nfs-over-rdma-svcrdma-xprtrdma]], [[rdma-rw-api]]
2. [Red Hat: Configuring NVMe/FC](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/configuring-nvme-over-fabrics-using-nvme-fc_managing-storage-devices); [NVMe/FC support status](https://access.redhat.com/solutions/3522911); [SUSE: NVMe-oF](https://documentation.suse.com/sles/15-SP5/html/SLES-all/cha-nvmeof.html)
3. [NVIDIA: iSER](https://docs.nvidia.com/networking/display/mlnxofedv551032/iscsi+extensions+for+rdma+(iser)); [UNH-IOL: Implementation and comparison of iSCSI over RDMA](https://www.iol.unh.edu/knowledge/implementation-and-comparison-iscsi-over-rdma)
4. [SPDK NVMe-oF RDMA performance report](https://review.spdk.io/download/performance-reports/SPDK_rdma_perf_report_2107.pdf); [SPDK blog](https://spdk.io/blog/)
5. [StarWind: iSCSI vs NVMe-oF performance](https://www.starwindsoftware.com/blog/iscsi-vs-nvme-of-performance-comparison/); [simplyblock: NVMe/RDMA vs NVMe/TCP](https://simplyblock.io/glossary/nvme-over-rdma-vs-nvme-over-tcp/)
6. To research: [[iscsi-iser-and-lio-target]], [[nvme-over-fibre-channel]]

## LKML Highlights

- **"nvme-tcp: add NVMe over TCP host driver" (Sagi Grimberg, 2018)** — argued that per-queue sockets and blk-mq mapping would bring NVMe-oF to commodity Ethernet with acceptable CPU cost. It merged in 5.0 and is now the most widely deployed NVMe-oF transport.
- **"nvme-tcp receive offloads" / ULP DDP (Aurelien Aptel, Boris Pismenny, 2021–2025)** — NIC direct data placement and CRC offload for NVMe/TCP; reviewers debated how to keep TCP in the kernel while letting the NIC parse ULP PDUs, and the series remains unmerged.
- **"nvme-tcp: TLS support" (Hannes Reinecke, 2023)** — introduced the `net/handshake` userspace TLS upcall (with Chuck Lever), later reused by NFS, making kTLS the standard way kernel storage protocols get encryption.
