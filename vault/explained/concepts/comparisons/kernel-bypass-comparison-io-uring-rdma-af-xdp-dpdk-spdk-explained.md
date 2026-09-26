---
title: "Kernel-Bypass Comparison: io_uring vs RDMA vs AF_XDP vs DPDK vs SPDK — Explained"
category: explained
original: "[[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk]]"
subsystem: comparisons
tags: [explained, comparison, kernel-bypass, io_uring, rdma, af-xdp]
converted: 2026-09-26
---

# Kernel bypass compared (io_uring, AF_XDP, RDMA, DPDK, SPDK), explained

> Plain-language companion to [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk|the technical note]]. Same facts, fewer identifiers.

## The problem

"Kernel bypass" covers very different designs. They all attack the same costs (system calls, interrupts, context switches, copies, and general-purpose stack processing), but they take different amounts of the kernel out of the path and give up different things in return. Five Linux-relevant approaches sit on one line, running from "the kernel does everything, it's cheaper to talk to" to "the kernel only hands over the device":
- **io_uring** skips a system call per operation and, optionally, interrupts and copies, but *not* the kernel's I/O stacks. The kernel owns the device.
- **AF_XDP** skips the network stack for steered queues, while the driver and XDP stay in the kernel. The kernel owns the device and shares it per queue.
- **RDMA** takes the kernel *and* the remote CPU off the data path; the transport runs in the network card. The kernel owns the control plane.
- **DPDK** skips everything: user-space drivers own the card's queues (unless the driver is "bifurcated").
- **SPDK** skips everything for storage: a user-space NVMe driver owns the SSD.

## The idea in one paragraph

Think of **how much of the restaurant you rent**. With **io_uring** you still eat in the restaurant (the kernel), but you get a **tablet to order in batches** instead of calling a waiter for each dish. With **AF_XDP** you get a **private hatch onto the kitchen's raw-ingredient deliveries** for some tables: the kitchen (driver and XDP) still unpacks the deliveries but skips the cooking (the stack). With **RDMA** you hire a **robot courier** that moves boxes between your pantry and another house's pantry with nobody at either house involved. With **DPDK and SPDK** you **rent the whole kitchen** (the device) and run it with your own staff (polling drivers): nobody else can use it, and you enforce your own health code.

## Step by step

### Step 1: io_uring: the kernel does the work, the interface gets cheaper
Shared submission and completion rings let the application batch requests, or let a kernel thread pick them up with no system call at all. Registered files and buffers skip per-operation lookups and pinning. Polled I/O spins on NVMe completion queues instead of taking interrupts, and passthrough sends NVMe commands straight to the drive's character device. Networking gets zero-copy send and **zcrx**, zero-copy receive through kernel TCP using header split and steering ([[io-uring-internals-explained|io_uring internals]], [[sqpoll-explained|SQPOLL]], [[registered-resources-explained|registered resources]], [[uring-cmd-passthrough-explained|passthrough]], [[zero-copy-rx-zcrx-explained|zcrx]]). It **keeps** the VFS, optional page cache, filesystems, TCP/IP, firewalling, cgroups, sharing of every device among many users, and standard tools. It **costs** per-operation stack processing (block layer, TCP) and its own attack surface, which some distributions restrict. Reported storage numbers: a FAST '24 study measured NVMe passthrough "within 9–16%" of SPDK, and secondary summaries put a fully tuned io_uring stack at about 80% of SPDK's peak IOPS. For databases, one study found gains depend on architecture (14% for PostgreSQL following their guidelines).

### Step 2: AF_XDP: skip the network stack, keep the driver
An XDP program redirects frames from a card queue into an AF_XDP socket whose **user memory area** holds the frames; four rings pass frame indexes back and forth, and in zero-copy mode the card DMAs straight into that memory. A "needs wakeup" flag and busy polling remove system calls and interrupts ([[af-xdp-explained|AF_XDP]], [[xdp-explained|XDP]]). It **keeps** the kernel driver and device ownership: traffic that isn't steered still flows through the normal stack on the same card, XDP programs can filter and steer, and access is controlled by capabilities and per-queue binding. It **gives up** TCP/IP for those frames, so applications get raw link-layer frames and must bring their own protocol processing. It's used for load balancers, network functions and capture, and by DPDK's AF_XDP driver, which runs DPDK applications on unmodified kernel drivers.

### Step 3: RDMA: hardware transport, kernel control plane
The kernel creates queue pairs, completion queues and memory regions, pins and maps memory, and brokers connections. After that, user space writes work requests, rings the card's doorbell and polls completions, all in shared memory; the card runs the reliable transport and places data by key on the remote host ([[rdma-explained|RDMA]], [[verbs-api-and-uverbs-explained|verbs and uverbs]], [[queue-pairs-and-completion-queues-explained|queue pairs and CQs]]). It **keeps** kernel-managed device and resource lifetimes, cgroup limits, sharing among processes, and hot-unplug safety. It **gives up** per-operation kernel visibility (no firewall or traffic shaping on RDMA traffic) and needs RDMA cards on both ends plus, for RoCE, a tuned fabric. Its unique property: **one-sided operations with zero remote CPU**. Nothing else here can write into another machine's memory without software running there.

### Step 4: DPDK: user space owns the card
The card (or a virtual function) is detached from its kernel driver and handed to **VFIO**. DPDK's polling driver maps the device's registers and DMA rings into the process, uses **huge-page** buffer pools as DMA-safe memory (mapped through the IOMMU by VFIO), and dedicates cores to busy-polling queues in a run-to-completion loop. No interrupts, no system calls, no kernel per packet. Two variants soften this: **bifurcated** drivers (NVIDIA mlx5) keep the card bound to the kernel driver and create raw packet queues through the RDMA subsystem's user-space interface, with flow rules sending chosen traffic to DPDK and the rest to the kernel; and the **AF_XDP driver** runs over kernel drivers at some cost in throughput. DPDK **gives up** kernel networking on its queues (bring your own TCP/IP stack or do link and network-layer processing yourself), sharing the device with the kernel (unless bifurcated), standard tools, and power efficiency.

### Step 5: SPDK: user space owns the SSD
NVMe drives are detached from the kernel driver and handed to VFIO. SPDK's user-space driver maps the controller registers and allocates queues in DMA-safe huge-page memory, and each application thread gets **its own NVMe queue pair**, so there's no locking. Completions are **polled**, because interrupts can't practically be routed to user space, add jitter and context switches, and checking a completion queue is only a cached memory read. SPDK also includes a block-device layer, an NVMe-oF **target** over RDMA and TCP (the user-space counterpart of the kernel target, see [[nvme-over-fabrics-rdma-and-tcp-explained|NVMe over Fabrics]]), a VM backend, and an io_uring backend for when bypass isn't possible. Reported numbers: roughly a million-plus IOPS per core, and 4.2 million IOPS on 5 cores across 8 drives. A 2025 study found about 85% of polling cycles wasted spinning on empty queues at moderate load, which is the power cost of always polling. SPDK **gives up** filesystems, the page cache, kernel NVMe multipath and device sharing, and recovery and management become the application's job.

### Step 6: Choosing
This is the key step: pick by what you're willing to lose.
- **Default to io_uring** for servers, databases and storage engines that want less overhead without leaving the kernel's semantics; add polled I/O and passthrough for NVMe, and zcrx for high-bandwidth TCP receive.
- **AF_XDP** for raw-packet processing at high rates while keeping the kernel driver and sharing the card with normal traffic.
- **RDMA** for cluster fabrics where microsecond latency, zero remote CPU or GPU-direct transfers justify RDMA cards: AI collectives, HPC, disaggregated storage, distributed caches.
- **DPDK** for dedicated packet-processing appliances (virtual routers, 5G user-plane functions, firewalls) that need every cycle and can own the card.
- **SPDK** for dedicated storage targets and appliances that can burn cores for maximum IOPS per SSD and don't need kernel features.

## The picture

```text
 more kernel kept ◀──────────────────────────────────────────────▶ more kernel bypassed
 io_uring            AF_XDP                RDMA                   DPDK / SPDK
 kernel stacks run   driver + XDP only     kernel sets up,        user-space driver
 every operation     raw frames to user    CARD runs transport    owns device via VFIO
 device shared       shared per queue      shared per QP          not shared*
 security: per op    at bind + XDP         card keys + setup      IOMMU only
 polling optional    polling optional      polling optional       always polling
                                           zero remote CPU!
 * except bifurcated DPDK drivers
```

## Tradeoffs

- **What it gives you:** the further right you go, the fewer cycles per operation, up to no system calls, interrupts, copies or stack processing at all. RDMA is off the line: it keeps kernel ownership but moves the transport into hardware.
- **What it costs / requires:** the more you bypass, the less comes free. io_uring keeps everything; AF_XDP drops the network stack; DPDK and SPDK drop the driver and device sharing. Kernel-mediated approaches enforce policy per operation (io_uring) or at bind time (AF_XDP, RDMA setup). VFIO-based bypass trusts the application with the whole device, fenced only by the IOMMU.
- **Where it bites:** peak numbers everywhere come from polling, and SPDK's own research shows the waste. io_uring, AF_XDP and RDMA can switch between polling and interrupts; DPDK and SPDK are built around polling ([[polling-vs-interrupts-io-uring-napi-rdma-cq-explained|polling vs interrupts]]). Meanwhile the kernel keeps absorbing bypass wins: passthrough approaches SPDK, AF_XDP gives DPDK a kernel-friendly backend, zcrx and devmem bring zero-copy receive to kernel TCP, and queue leasing brings them into containers. The remaining gaps are protocol processing cost (TCP versus none) and one-sided remote access (RDMA only).

## How it got here

- **2005:** RDMA verbs in Linux.
- **2010–2013:** DPDK (Intel, open-sourced 2013) on UIO, then VFIO (Linux 3.6, 2012). **2015:** SPDK's user-space NVMe driver.
- **2018:** AF_XDP (4.18), pitched as "DPDK-like" speed while keeping the kernel driver; DPDK gets an AF_XDP driver soon after.
- **2019:** io_uring (5.1). **2022:** NVMe passthrough through io_uring (5.19), later measured within 9–16% of SPDK.
- **2024–2025:** devmem TCP (6.12), io_uring zcrx (6.15), AF_XDP multi-buffer and transmit metadata.
- **2026:** netkit queue leasing brings AF_XDP and memory providers into containers; zcrx events and export; research on power-efficient polling for SPDK.

## Related

- Technical version: [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk]]
- [[io-uring-vs-rdma-explained|io_uring vs RDMA]], [[devmem-tcp-vs-rdma-gpudirect-vs-io-uring-zcrx-explained|Devmem vs GPUDirect vs zcrx]], [[polling-vs-interrupts-io-uring-napi-rdma-cq-explained|Polling vs interrupts]]
- [[af-xdp-explained|AF_XDP]], [[rdma-explained|RDMA]], [[zero-copy-rx-zcrx-explained|zcrx]], [[uring-cmd-passthrough-explained|io_uring passthrough]], [[blk-mq-explained|blk-mq]]
- [[p2pdma-peer-to-peer-dma-explained|P2PDMA]], [[get-user-pages-and-pinning-explained|Page pinning]], [[huge-pages-hugetlbfs-explained|Huge pages]], [[netdev-queue-management-api-explained|Queue management API]]
