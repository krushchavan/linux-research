---
title: "Storage Fabrics Compared: NVMe/RDMA vs NVMe/TCP vs iSER/iSCSI vs NVMe/FC vs NFS over RDMA — Explained"
category: explained
original: "[[storage-fabrics-nvme-of-iser-iscsi-nvme-fc-nfs-rdma]]"
subsystem: comparisons
tags: [explained, comparison, nvme-of, iscsi, rdma]
converted: 2026-09-26
---

# Storage fabrics compared, explained

> Plain-language companion to [[storage-fabrics-nvme-of-iser-iscsi-nvme-fc-nfs-rdma|the technical note]]. Same facts, fewer identifiers.

## The problem

Networked storage lets one machine (the *initiator* or *host*) use disks that live in another (the *target*). Every protocol for this has to solve the same four problems:
1. **Carrying commands**: send "read these blocks" or "write this data" and get the result back.
2. **Moving the data**: ideally straight from the host's buffer to the target's, with no extra copies.
3. **Parallelism**: how many independent queues exist, and whether each CPU can use its own.
4. **Failures**: lost paths, reconnection, and using several paths at once.

The protocols in Linux differ in two ways. The first is the **command language**: SCSI (iSCSI, iSER, Fibre Channel's traditional protocol), NVMe (NVMe over fabrics on RDMA, TCP or Fibre Channel), or files (NFS). The second is the **way data moves**: RDMA, where one side's network card reads or writes the other's memory directly; TCP streams; or Fibre Channel hardware. On the target side there's a third choice: a **kernel target**, or a **user-space target that polls constantly** (SPDK).

## The idea in one paragraph

Imagine a warehouse (the target) taking orders from shops. **iSCSI** sends orders and goods along one long conveyor belt (a single TCP connection), with paperwork designed for a single slow disk. **iSER** keeps the same paperwork, but the warehouse's forklift reaches straight into the shop's stockroom (RDMA). **NVMe over fabrics** uses lean paperwork designed for flash and gives **every CPU its own lane**. The goods move by forklift (RDMA), by lane conveyor (TCP), or on existing dedicated freight rail (Fibre Channel). **NFS over RDMA** orders files rather than blocks, but the forklift still moves the bulk data. An **SPDK target** replaces the dispatchers with clerks who stand at every lane watching continuously: far more throughput per clerk, but the clerks are never idle.

## Step by step

### Step 1: iSCSI, SCSI over a TCP stream
iSCSI wraps SCSI commands and data in messages sent over TCP. A session between host and target usually uses **one TCP connection**. Linux's host side has a user-space daemon for login and discovery and a kernel data path, and remote disks appear as ordinary SCSI disks. The kernel's target is called **LIO**.

Small writes can travel with the command. Larger writes wait for the target to say "ready for data", and reads come back as data messages. Payload is **copied** between network buffers and storage buffers on both ends, and optional checksums cost more CPU.

The limits come from the design. The SCSI layer and the single connection serialise work, and queue depth is per session, not per CPU. iSCSI was designed when a disk spun. Against NVMe SSDs the protocol becomes the bottleneck, and NVMe over TCP commonly delivers substantially more I/O per CPU core on the same network.

### Step 2: iSER, iSCSI with RDMA moving the data
**iSER** keeps iSCSI's login, sessions and SCSI commands, but moves the data with RDMA. Commands and status travel as RDMA messages. For a read, the target **writes directly into the host's registered memory**. For a write, the target **reads directly from it**. There are no "ready for data" round trips and no copies. Linux has both the host side (plugged into the normal iSCSI tools) and the target side (plugged into LIO), and both support end-to-end data-integrity checking.

iSER gave existing SCSI setups RDMA-class latency. It still carries the SCSI layer and per-session queues, and for new flash deployments it has largely been replaced by NVMe over RDMA.

### Step 3: NVMe over RDMA, one RDMA connection per CPU
NVMe over fabrics ([[nvme-over-fabrics-rdma-and-tcp-explained|NVMe over Fabrics]]) keeps NVMe's defining feature: **many independent queues**. The host opens one admin queue and **one I/O queue per CPU**, each its own reliable RDMA connection, matched one-to-one with the block layer's per-CPU queues ([[blk-mq-explained|blk-mq]]). There is no SCSI layer and no locking between CPUs.

Commands are small fixed-size messages. Small writes ride inside the command. For larger buffers the host registers the memory on the fly and tells the target where it is. Then **the target moves the data**: it writes into host memory for reads and reads from host memory for writes ([[rdma-rw-api-explained|RDMA read/write API]]). The reply also tells the host's card to revoke access to that buffer, so the host CPU never touches the payload. The target can even move data between the network card and an SSD's own memory without touching the target's main memory ([[p2pdma-peer-to-peer-dma-explained|P2PDMA]]).

Special polled queues give an interrupt-free path end to end. Latency adds roughly 5–10 µs over a local SSD. It needs an RDMA network and correctly sized locked-memory limits ([[memory-pinning-and-registration-strategies-explained|memory pinning]]).

### Step 4: NVMe over TCP, one socket per CPU
NVMe over TCP (5.0) keeps the per-CPU queue design but makes each queue a **kernel TCP socket**. Commands, responses and data travel as typed messages, and large writes wait for "ready for data" messages from the target. Sending is zero-copy, because the kernel hands storage pages straight to the network stack. **Receiving still copies** data into storage buffers, and optional checksums are computed in software. Those two costs are the gap to RDMA.

This is the key step, because it explains the market. What NVMe over TCP buys is **deployability**: any Ethernet, any NIC, routable, with no special switches and no memory registration. Security comes from **TLS 1.3 in the kernel** (6.7) plus in-band authentication. A long-running proposal would let NICs place received data directly and check the checksums in hardware, but it isn't merged. NVMe over TCP is now the default "NVMe over the network" choice.

### Step 5: NVMe over Fibre Channel, NVMe on existing SAN hardware
**NVMe over FC** carries NVMe commands and data on Fibre Channel, alongside traditional SCSI traffic on the same adapters and switches. Fibre Channel is **lossless by design** (credit-based, like InfiniBand), provides zoning and naming services, and the adapter moves the data itself, so the host CPU never copies payload. It is the storage equivalent of RDMA without an RDMA stack.

Linux has a generic NVMe over FC host and target, sitting above adapter drivers from Broadcom/Emulex (host and target) and Marvell/QLogic (host). Enterprise distributions have fully supported it since around 2018–2019. Connections form automatically when remote ports appear. A software loopback driver emulates a Fibre Channel fabric for testing. Its niche is clear: organisations with a Fibre Channel investment can run NVMe end to end without adopting RDMA.

### Step 6: NFS over RDMA, files with RDMA for the bulk data
NFS over RDMA ([[nfs-over-rdma-svcrdma-xprtrdma-explained|NFS over RDMA]]) swaps the **remote procedure call transport** underneath NFS, not the file protocol ([[sunrpc-explained|SunRPC]]). Calls and replies travel as RDMA messages with credit-based flow control. Each message lists the host memory areas the server should read from (the data of an NFS write) or write into (the data of an NFS read). The server moves bulk data with RDMA, and the client makes sure no page returns to the page cache while a remote machine could still write to it.

Compared with block protocols, this gives **shared file semantics** (locking, delegations, parallel NFS) with RDMA data movement. Small-I/O latency is higher than NVMe over RDMA, but large sequential I/O approaches wire speed with little CPU.

### Step 7: Kernel targets vs SPDK
Every fabric has a kernel target: the NVMe target, LIO for SCSI protocols, and the NFS server. They are interrupt-driven with polling hybrids, work with the rest of the block layer (device mapper, RAID, multipath), and share CPUs with other work.

**SPDK** runs the whole target in user space ([[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk-explained|kernel bypass]]). Its user-space NVMe driver polls the SSDs, RDMA is used directly from user space, and TCP runs through kernel sockets with busy polling, io_uring, or a user-space network stack. Pinned threads **poll everything continuously**, with no interrupts or context switches. SPDK reports **up to about 8× more I/O per core and about 90% less software latency** than the kernel target.

The costs: dedicated cores burn 100% CPU even when idle (a 2025 study found most polling cycles wasted at moderate load). The SSDs leave the kernel, so no filesystems or device mapper on the target. And it needs its own tooling. The kernel has been closing the gap by adopting polling selectively ([[polling-vs-interrupts-io-uring-napi-rdma-cq-explained|polling vs interrupts]]). The rule of thumb: SPDK for dedicated storage appliances, the kernel target for general servers.

## The picture

```text
              commands     data moved by                       queues          network needed
 iSCSI        SCSI         TCP, copied both ends               per session     any IP
 iSER         SCSI         target RDMA read/write              per session     RDMA fabric
 NVMe/RDMA    NVMe         target RDMA read/write              per CPU         RDMA fabric
 NVMe/TCP     NVMe         TCP; zero-copy send, copy on recv   per CPU         any IP
 NVMe/FC      NVMe         Fibre Channel adapter               per CPU         FC SAN
 NFS/RDMA     files (RPC)  server RDMA read/write              credits         RDMA fabric

 target:  kernel (interrupts + selective polling)   vs   SPDK (user space, always polling)
```

## Tradeoffs

- **What it gives you:** a spectrum from "runs on anything" (iSCSI, NVMe over TCP) to "host CPU never touches data" (RDMA, Fibre Channel), with a file-level option (NFS over RDMA) and a choice of kernel or polled user-space targets.
- **What it costs / requires:** RDMA needs a well-run network and memory registration. Fibre Channel needs a SAN. TCP needs nothing, but pays a receive copy. SPDK trades whole cores and kernel storage features for efficiency.
- **Where it bites:** the command language matters more than the wire. NVMe's per-CPU queues are why NVMe over TCP beats iSCSI on the same network, and why iSER never caught NVMe over RDMA despite using RDMA too. On security, NVMe over TCP has standard TLS, while RDMA transports rely mostly on network isolation.

## How it got here

- **2005–2008:** iSCSI host (2.6.13), iSER host (2.6.19), NFS over RDMA (2.6.24).
- **2011–2013:** LIO becomes the kernel's SCSI target (2.6.38); iSER target added (3.10).
- **2016–2017:** NVMe over fabrics with RDMA (4.8); NVMe over Fibre Channel (4.10).
- **2019:** NVMe over TCP (5.0).
- **5.x–6.x:** native NVMe multipath, polled queues, direct NIC-to-SSD transfers, in-band authentication; zero-copy TCP sends (6.5); TLS for NVMe over TCP (6.7); NIC offload for TCP receive still under review.

## Related

- Technical version: [[storage-fabrics-nvme-of-iser-iscsi-nvme-fc-nfs-rdma]]
- [[nvme-over-fabrics-rdma-and-tcp-explained|NVMe over Fabrics]], [[nfs-over-rdma-svcrdma-xprtrdma-explained|NFS over RDMA]], [[rdma-rw-api-explained|RDMA read/write API]], [[blk-mq-explained|blk-mq]]
- [[rdma-transports-infiniband-roce-iwarp-efa-srd-ultra-ethernet-explained|RDMA transports]], [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk-explained|Kernel bypass]], [[polling-vs-interrupts-io-uring-napi-rdma-cq-explained|Polling vs interrupts]]
