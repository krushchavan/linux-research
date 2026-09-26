---
title: "NVMe over Fabrics: RDMA and TCP Transports — Explained"
category: explained
original: "[[nvme-over-fabrics-rdma-and-tcp]]"
subsystem: nvme
tags: [explained, nvme, nvme-of, rdma, tcp, storage]
converted: 2026-09-26
---

# NVMe over Fabrics (RDMA and TCP), explained

> Plain-language companion to [[nvme-over-fabrics-rdma-and-tcp|the technical note]]. Same facts, fewer identifiers.

## The problem

NVMe was built for PCIe: command and completion queues in host memory, doorbell registers, one small command per I/O, and lots of parallel queues. Data centres want the same fast model for **remote** SSDs and storage arrays, at close to local latency. **NVMe over Fabrics** carries NVMe's queue model across a network. Linux implements both ends: the **host** makes remote namespaces appear as ordinary `/dev/nvmeXnY` block devices, and the **target** exports local block devices or files. RDMA and TCP are the two IP-network transports, and they show the whole RDMA-versus-sockets tradeoff in miniature.

## The idea in one paragraph

A local NVMe SSD is a **mailroom with a pneumatic tube**: the host drops command slips in a queue, rings a bell, and the device pulls data straight out of host memory. NVMe-oF extends the tube over a network, and the transports differ in *who carries the parcels*. With **RDMA**, the target's card reaches **directly into the host's memory** using keys the host put in the command, and moves the data itself; the host CPU only posts the command and later reads the completion. With **TCP**, everything travels as a **stream of protocol data units** through both kernels' TCP stacks, and the host CPU copies data out of socket buffers and computes checksums unless offloads help. Same NVMe semantics, same block device, very different CPU cost per byte.

## Step by step

### Step 1: Connect a controller
`nvme connect` (transport, address, port 4420, subsystem name) hands an option string to the kernel, which creates a controller with one **admin queue** and N **I/O queues** (by default one per CPU), each its own transport connection and each mapped one-to-one onto a block-layer hardware queue. A request from CPU 5 goes out on queue 5 with no cross-CPU locking, the property that makes NVMe scale. Each queue sends a fabrics connect command, optionally authenticates in-band, then normal NVMe commands follow. A **discovery** controller lists available subsystems and ports. **Native multipath** merges several paths (two RDMA ports, or RDMA plus TCP) into one device with standard path selection. If a connection drops, the host keeps reconnecting until a loss timeout.

### Step 2: RDMA host: describe the data, don't send it
Each queue is an RDMA connection-manager connection with a reliable queue pair and a pooled completion queue. For each request, the host describes its data buffer in the command, using the cheapest option:
- **inline:** small writes up to the target's limit travel *inside the send itself*, with no registration and no remote access
- **single:** one contiguous segment uses a global key, only if the "register always" safety default (on) is turned off
- **fast registration:** otherwise, register a memory region with a registration request chained before the send, and put address, length and key in the command (an integrity region when protection information is used)

Registration and send go out as one chain with one doorbell.

### Step 3: RDMA: the target moves the data
This is the key step for RDMA. For a host **read**, the target RDMA-*writes* the data into the host's buffer; for a host **write**, it RDMA-*reads* from the host's buffer. The host CPU never touches the data. The completion arrives in a pre-posted receive buffer, and the target sends it **with invalidate** of the host's key, so the host's region is revoked without extra work. On the target side, commands arrive in posted receive buffers (optionally a shared receive queue), the rw helper builds the read or write chain against the host's description, and the response is chained right behind the data. Backends are block devices, files, or pass-through to a local NVMe controller; with P2PDMA, data can move between the RDMA card and an SSD's memory buffer without touching host RAM.

### Step 4: TCP host: PDUs over a socket
Each queue is a kernel TCP socket with a work item pinned to one CPU. NVMe/TCP defines messages: an initialisation exchange (negotiating header and data checksums and sizes), command capsules (the command plus any small inline data) and response capsules, controller-to-host data for reads, and, for writes bigger than the inline size, a **ready-to-transfer** request from the target followed by host-to-controller data, so the target controls its buffer use. Sending hands bio pages to the socket **without copying** (page splicing), falling back to copying for pages it can't splice. Receiving parses messages straight out of the socket's receive queue, but read data is **copied** into the request's pages, and **CRC32c data checksums** are computed in software. That receive copy plus checksumming is the main CPU cost compared with RDMA. **Poll queues** let io_uring polled I/O spin on the socket instead of waiting for interrupts and workqueues. The TCP target mirrors all this.

### Step 5: TLS and authentication (TCP)
Since 6.7, NVMe/TCP can run over **kernel TLS 1.3**: after connecting, the kernel asks a user-space helper (`tlshd`) to do the handshake with a pre-shared key from an NVMe keyring, then carries on with kernel TLS. A "concatenation" mode derives the key from in-band authentication, and recent work handles TLS key updates. Data checksums are redundant under TLS and are turned off.

### Step 6: Offloads that narrow the TCP gap
- **Receive placement and checksum offload** (NVIDIA, 20 revisions by late 2023): the card recognises NVMe/TCP messages in the stream, places read data directly into block-layer buffers and checks the CRC, while the kernel still runs TCP. Reported gains were up to 55% without checksums and 138% with them; it is **not merged** and has been debated for years over layering.
- **Full NVMe/TCP offload** (Marvell, 2021): moved the whole queue into the card's TCP engine, and was rejected in the tradition of refusing TCP offload engines.

## The picture

```text
 host (block request on CPU 5) ─▶ fabric queue 5
 RDMA:  register buffer → key K ─ SEND {READ cmd, keyed SGL [addr, len, K]}
        target: read SSD → RDMA WRITE into host buffer ─ SEND_WITH_INV {completion, K}
        host CPU never touches data
 TCP:   SEND capsule {READ cmd}
        target: read SSD → C2H data PDUs → host TCP stack → COPY into pages (+ CRC32c)
        write: capsule → target R2T → host H2C data PDUs (pages spliced, not copied)
```

## Tradeoffs

- **What it gives you:** remote NVMe as ordinary block devices with multipath and filesystems. RDMA adds near-zero host CPU per byte and the lowest latency (about 10 µs over local). TCP runs on any card and network, with standard congestion control and TLS, and simple deployment, which made it the fastest-growing fabric after 2018.
- **What it costs / requires:** RDMA needs RDMA cards on both ends and, for RoCE, a tuned lossless or ECN fabric, with security resting on keys (hence always registering and remote invalidation, so keys live for one I/O). TCP costs CPU on receive (copy, checksum, stack processing) and slightly more latency. One connection per CPU queue preserves NVMe's lock-free parallelism but multiplies connections (CPUs × controllers × paths).
- **Where it bites:** each TCP queue is served by one work item on one CPU, which keeps parsing simple but can bottleneck a single hot queue. User-space initiators like SPDK get more IOPS per core by bypassing the kernel, but give up block devices, multipath, the page cache and filesystems.

## How it got here

- **4.8 (2016):** NVMe-oF host and target over RDMA (Christoph Hellwig, Sagi Grimberg and others), with the rw helper created alongside.
- **4.10–4.19:** Fibre Channel transport; file backend.
- **5.0 (2019):** NVMe/TCP (Sagi Grimberg, Lightbits), one socket per queue with a non-blocking data plane.
- **5.x:** native multipath, TCP poll queues, integrity over RDMA (5.8), target pass-through (5.9).
- **6.0:** in-band authentication (Hannes Reinecke). **6.5:** page splicing replaces the old send-page path. **6.7:** TLS 1.3 through the handshake upcall.
- **2023–26:** the unmerged receive-offload series; secure channel concatenation; TLS key updates; a PCI endpoint target.

## Related

- Technical version: [[nvme-over-fabrics-rdma-and-tcp]]
- [[rdma-explained|RDMA]], [[rdma-rw-api-explained|rw API]], [[rdma-cm-connection-manager-explained|Connection manager]], [[queue-pairs-and-completion-queues-explained|Queue pairs and CQs]], [[p2pdma-peer-to-peer-dma-explained|P2PDMA]]
- [[blk-mq-explained|blk-mq]], [[uring-cmd-passthrough-explained|io_uring passthrough]], [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]], [[tcp-ip-stack-explained|TCP/IP stack]]
