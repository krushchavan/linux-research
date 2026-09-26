---
title: "Devmem TCP vs GPUDirect RDMA vs io_uring zcrx — Explained"
category: explained
original: "[[devmem-tcp-vs-rdma-gpudirect-vs-io-uring-zcrx]]"
subsystem: comparisons
tags: [explained, comparison, gpu, zero-copy, rdma, devmem]
converted: 2026-09-26
---

# Devmem TCP vs GPUDirect RDMA vs io_uring zcrx, explained

> Plain-language companion to [[devmem-tcp-vs-rdma-gpudirect-vs-io-uring-zcrx|the technical note]]. Same facts, fewer identifiers.

## The problem

Distributed AI training and inference constantly move tensors between GPUs on different machines. The naive path, GPU → host RAM → network card → wire → card → host RAM → GPU, crosses PCIe through the root complex twice on each side and costs host memory bandwidth and CPU time. Linux now has **three** ways to let the network card DMA straight to and from accelerator memory. All three rest on **dma-buf**, the kernel's shared way of saying "here is device memory another driver may DMA into". They differ in who runs the transport, what the network must provide, how buffers get handed back, and how much of the kernel's networking stays involved.

## The idea in one paragraph

All three **deliver freight straight into a warehouse behind a locked gate** (GPU memory). **GPUDirect RDMA** hires a **private courier with its own road network** (an RDMA card and fabric): each crate is addressed "gate key R, shelf X" and dropped there, and nobody in either office gets involved. **Devmem TCP** and **io_uring zcrx** use the **public postal service** (kernel TCP over any Ethernet): the post office still reads every envelope and handles lost mail, but a special sorting rule (header split plus steering to a dedicated queue) sends the *contents* of certain mail straight through the gate while the envelopes go to the office. Devmem tells the recipient with **receipts in the mailbox** (socket control messages, handed back through a socket option); zcrx pins them on a **shared noticeboard** (completion entries, handed back through a refill ring).

## Step by step

### Step 1: The shared foundation, a handle on GPU memory
The GPU driver **exports** a dma-buf for an allocation (NVIDIA's open kernel modules, AMD, Intel, or a test exporter). The network side **attaches** it and gets DMA addresses valid for that card. If card and GPU sit under the same PCIe switch, that's a direct peer-to-peer bus address and traffic never reaches the root complex; otherwise it goes through an allowlisted host bridge (see [[p2pdma-peer-to-peer-dma-explained|P2PDMA]]). The topology rules are shared by all three: put GPU and card under one switch for performance, turn off **ACS redirect** on that switch or peer traffic bounces off the root complex, and set up the IOMMU so it permits the mapping.

### Step 2: GPUDirect RDMA
The application registers the GPU dma-buf as an RDMA **memory region**. Cards that support on-demand paging get a dynamic import; others get a pinned one, and 2026 added a pinned-but-revocable form. The card's translation table now points at GPU memory. The older route, NVIDIA's out-of-tree "peer memory" module, was never merged upstream and is now discouraged. For data, a collective library (NCCL, UCX, NIXL) posts RDMA writes or sends naming the local region's key, and the remote key names the *remote* GPU's memory. The card reads GPU memory over PCIe, the RDMA transport carries it, and the remote card writes it into remote GPU memory. **No kernel work per transfer on either side, and no CPU touches a header.** Buffer reuse is up to the application's protocol, since the region stays registered. The price: RDMA cards end to end, InfiniBand or RoCE with lossless or ECN tuning ([[roce-congestion-control-pfc-ecn-dcqcn-explained|RoCE congestion control]]), and connection and key state per peer.

### Step 3: Devmem TCP
An admin binds the dma-buf to specific **receive queues** through netlink; those queues' page pools now hand out GPU-memory buffers ([[devmem-tcp-rx-dmabuf-binding-and-token-recycling-explained|devmem RX binding]], [[netdev-queue-management-api-explained|queue API]]). On receive, **header split** puts headers in host memory and payload in GPU memory, and flow steering pins the flow to a bound queue ([[header-split-and-flow-steering-for-zero-copy-rx-explained|header split and steering]]). Kernel TCP processes headers (acknowledgements, reordering, congestion control) on packets whose payload it can't read. Receiving returns control messages giving offset, size and a **token** for each fragment, and the application launches GPU kernels on those offsets. It hands buffers back by passing tokens to a socket option (up to 128 ranges or 1024 fragments per call). Sending works from a separate transmit binding with zero-copy send ([[devmem-tcp-tx-explained|devmem TX]]). Requirements: an Ethernet card with header split, flow steering, checksum offload and driver support. **Any TCP peer** over any routed, lossy network works. Google built this to run GPU networking on its A3 VMs, then upstreamed the mechanism.

### Step 4: io_uring zcrx with a dma-buf area
This is the same receive mechanism as devmem, reached through io_uring. The application registers a zcrx instance whose area is the dma-buf, and it takes the same queue-binding path. Card requirements are identical. The difference is the interface: completions arrive as **completion-queue entries** carrying area and offset, and buffers go back by writing entries into a **refill ring** in shared memory, with no system call. Two consequences: there's **no copy fallback** for GPU memory (the kernel can't read it, so data that misses the steered queue can't be delivered this way), and sending from GPU memory through io_uring isn't in mainline, so GPU transmit uses devmem's path ([[zero-copy-rx-zcrx-explained|zcrx internals]]).

### Step 5: Line them up
This is the key step: they differ mainly in **who decides where the bytes land**.
- **RDMA:** the wire protocol names key and address; the kernel does nothing per packet and the receiving CPU is idle (a one-sided operation); it needs RDMA hardware on both ends and a tuned fabric; it can send from the GPU.
- **Devmem TCP:** the receive queue a flow hashes to decides; the kernel runs TCP on headers; it works with any TCP peer on any IP network; buffers come back as tokens through a socket option; the bound queues are dedicated; the payload is unreadable to firewalls, BPF and packet capture (headers only); binding receive queues needs admin rights in the network namespace, transmit binding doesn't.
- **zcrx:** the same as devmem on the wire, with a ring for completions and returns, unprivileged ring registration (queue configuration is still done by an admin), and no GPU transmit of its own.

For containers, RDMA uses virtual functions or macvlan RDMA devices, while devmem and zcrx use netkit queue leasing (2026).

## The picture

```text
                    GPU memory (exported as dma-buf)
                 ▲                    ▲                    ▲
     RDMA write by key      payload via header split   same, via io_uring
 ┌───────────────┴───┐   ┌──────────────┴─────────┐   ┌──────┴──────────────┐
 │ GPUDirect RDMA     │   │ Devmem TCP              │   │ zcrx (dma-buf area) │
 │ RDMA card+fabric   │   │ kernel TCP on headers   │   │ kernel TCP on hdrs  │
 │ no kernel per pkt  │   │ tokens via socket opt   │   │ refill ring         │
 │ RDMA peer only     │   │ any TCP peer            │   │ any TCP peer        │
 └────────────────────┘   └─────────────────────────┘   └─────────────────────┘
      PCIe: GPU and card under one switch, ACS redirect off
```

## Tradeoffs

- **What it gives you:** GPUDirect RDMA has the lowest latency (around 2 µs class) and zero CPU. Devmem and zcrx accept per-packet header processing to win **any network, any peer** deployment and the kernel's congestion control, the explicit bet behind Google's devmem work.
- **What it costs / requires:** RDMA brings a fabric and its operational burden. The TCP schemes rely on header split and steering, so they need dedicated queues, careful card configuration, and payloads the host can't read (no software checksum, no payload BPF, no packet capture of data). Verbs is a specialist API; devmem uses sockets plus control messages; zcrx uses io_uring. Libraries such as NCCL plugins hide the differences, which is why all three coexist.
- **Where it bites:** buffer lifecycle. RDMA regions stay registered and the application manages reuse, but devmem and zcrx *lend* card buffers to the application, so slow returns starve the receive queue and cause drops; zcrx's ring makes returns cheaper than devmem's socket option. And on most hardware all three pin GPU memory while bound, so it can't be evicted. Only RDMA supports dynamic attachment (on cards with on-demand paging), and 2026 revocation work pushes every importer toward bounded revoke.

## How it got here

- **2013–2021:** GPUDirect RDMA through NVIDIA's out-of-tree peer-memory module, never upstreamed.
- **5.12 (2021):** RDMA memory regions backed by dma-buf, the upstream path for GPUDirect RDMA.
- **2022–2023:** Google proposes device-memory TCP; its TCP-based GPU networking runs on A3 VMs.
- **6.12 (2024):** devmem TCP receive upstream. **6.15–6.16 (2025):** io_uring zcrx, dma-buf areas, devmem transmit.
- **2026:** dma-buf revocation semantics; RDMA dma-buf export and pinned-revocable import; zcrx events and multiple areas; netkit queue leasing brings devmem and zcrx into Kubernetes pods.

## Related

- Technical version: [[devmem-tcp-vs-rdma-gpudirect-vs-io-uring-zcrx]]
- [[devmem-tcp-explained|devmem TCP]], [[zero-copy-rx-zcrx-explained|io_uring zcrx]], [[memory-registration-and-ib-umem-explained|RDMA memory registration]], [[dma-buf-sharing-explained|dma-buf sharing]], [[p2pdma-peer-to-peer-dma-explained|P2PDMA]]
- [[rdma-explained|RDMA]], [[netmem-and-net-iov-abstraction-explained|netmem and net_iov]], [[page-pool-explained|Page pool]], [[io-uring-vs-rdma-explained|io_uring vs RDMA]], [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk-explained|Kernel-bypass comparison]]
