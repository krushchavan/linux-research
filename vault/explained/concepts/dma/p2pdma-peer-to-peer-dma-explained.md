---
title: "PCI Peer-to-Peer DMA (P2PDMA) — Explained"
category: explained
original: "[[p2pdma-peer-to-peer-dma]]"
subsystem: dma
tags: [explained, dma, pci, p2pdma, zone-device]
converted: 2026-09-26
---

# PCI peer-to-peer DMA, explained

> Plain-language companion to [[p2pdma-peer-to-peer-dma|the technical note]]. Same facts, fewer identifiers.

## The problem

Moving data between two PCIe devices, say an RDMA card and an NVMe SSD, normally **bounces through system RAM**: one device writes into host memory, the other reads it back out. That uses the memory channels twice and adds latency and cache pollution, even though the CPU never looks at the data. **P2PDMA** lets one device DMA *directly into another device's memory window* (an NVMe controller memory buffer, a GPU memory aperture, an accelerator's buffer) across the PCIe fabric, never touching RAM. The kernel has to represent that device memory so ordinary I/O paths can carry it, decide whether the hardware topology can safely route traffic between two particular devices, and give each device the right address.

## The idea in one paragraph

PCIe is a **tree of roads**: devices are houses, switches are local intersections, and the root complex (host bridge) is the town centre. Classic DMA always goes house → town centre → RAM warehouse → town centre → other house. P2PDMA lets a delivery go **straight between houses**. If they share a local intersection, the truck turns there and never reaches the town centre, the fastest route, but the address must be the one the switch understands (a *bus* address). If the only route is through the town centre, it's allowed only when the town centre is known to forward house-to-house traffic correctly, and then the address is whatever the IOMMU expects. The kernel is the **route planner** that checks the map before allowing the trip.

## Step by step

### Step 1: Three roles
- **Provider:** a driver exposing device memory for others, such as an NVMe controller memory buffer, or (through dma-buf) GPUs, VFIO devices and RDMA cards.
- **Client:** a DMA-capable device that can target that memory, like RDMA cards and NVMe controllers. Clients use the ordinary DMA API; P2P is handled transparently.
- **Orchestrator:** code that picks a provider close to all the clients and allocates from it; the NVMe-oF target is the classic one.

### Step 2: Give device memory page structures
This is the key trick. A provider registers a range of its memory window, and the kernel creates special **device-memory page structures** for it, with an allocator to hand out pieces. Having page structures means block I/O, scatter lists and user-page pinning all work unchanged, so P2P memory can flow through the block layer and the RDMA stack. The catch: it's device memory, so the CPU must not copy to it with ordinary memcpy (special accessors only), and it has no normal page lifetime. Since 6.19, each window also records its **bus offset** separately, so users that don't have page structures (dma-buf, VFIO) can compute addresses too.

### Step 3: Check the route
For a provider and a client, the kernel walks both devices' paths up the tree to their common ancestor:
- **a common switch (not the root port):** allowed, and the client must be given the **PCI bus address**, not an IOMMU address, because the IOMMU never sees the transfer. If the switch has **ACS redirect** turned on, traffic is forced up to the root anyway and is treated as crossing the host bridge. Operators often disable redirect for P2P, giving up some isolation.
- **only via the host bridge:** allowed only on CPUs known to handle it (AMD Zen and newer) or host bridges on an **allowlist** (certain Intel Xeons and specific accelerator devices, sometimes only when both devices share one host bridge). Then a normal mapping is used, through the IOMMU or directly.
- **otherwise:** not supported, and mapping fails.

Decisions are cached per client, and orchestrators can score providers by distance to several clients and pick the closest.

### Step 4: Map through the ordinary DMA API
When a client maps memory, the DMA layer recognises P2P pages, looks up the cached route decision and provider, and gives switch-local pieces their bus address (marked so unmapping skips the IOMMU) and host-bridge pieces a normal mapping. Block devices that can accept P2P memory say so (NVMe does), and the block layer refuses P2P pages for queues that can't.

### Step 5: User-space access (6.2+)
A provider's published memory can be mapped by a program through sysfs. Pinning such pages is refused unless the caller explicitly opts in, and long-term pins are refused outright, so only paths that opted in can use them: direct I/O in the block layer, and therefore **io_uring direct reads and writes**. A program can read from one NVMe drive straight into another drive's memory buffer.

### Step 6: NVMe-oF target offload
With a configuration switch, the NVMe-oF target allocates I/O buffers from a P2P provider (such as an NVMe controller memory buffer) near both the RDMA card and the SSD. The RDMA card then reads the host's write data straight into that buffer, and the SSD writes from it, with no host DRAM involved.

### Step 7: dma-buf and VFIO (6.19+)
Device memory without page structures is shared through **dma-buf**: the exporter hands out DMA addresses computed with the same routing rules and revokes them through invalidation. In 6.19, VFIO can export a passed-through device's memory window as a dma-buf, so an RDMA card can register VFIO-assigned device memory. In 2026 VFIO added memory mapping of those dma-bufs for isolated helper processes, a lighter core was split out for platforms without device-memory pages, and RDMA devices can export their own device memory.

### Step 8: Removal
A provider can only go away after every mapping is gone: page references drop to zero, or dma-buf importers have been invalidated. User mappings are torn down when the driver unbinds.

## The picture

```text
            root complex (host bridge) ── RAM
             /                        \
         switch A                   switch B
         /     \                        \
   RDMA NIC   NVMe SSD (CMB)           GPU
 NIC → CMB: common switch A → BUS address, skips IOMMU            ✓ fastest
 NIC → GPU: via host bridge → allowed only if CPU/bridge allowlisted ✓/✗
 old way:   NIC → RAM → SSD (twice the memory bandwidth)
```

## Tradeoffs

- **What it gives you:** device-to-device transfers without touching RAM, working through the ordinary block, RDMA and DMA interfaces; the basis for NVMe-oF target offload, GPUDirect-style storage and networking, and device-memory dma-bufs.
- **What it costs / requires:** giving device memory page structures meant special cases everywhere (no CPU memcpy, no long-term pins, opt-in pinning), and a long push to represent P2P memory without pages, now materialising through the provider and dma-buf work. Mixed scatter lists (bus addresses and IOMMU addresses) complicate the DMA API, and switch-local traffic bypasses IOMMU protection.
- **Where it bites:** crossing the host bridge is refused unless the platform is known good, because many root complexes silently drop or mishandle peer-to-peer traffic. That prevents corruption but frustrates users on unlisted hardware, and disabling ACS redirect to enable switch-local routing trades away isolation.

## How it got here

- **2012–2017:** out-of-tree work around NVMe, RDMA and NVMe-oF (Stephen Bates, Logan Gunthorpe).
- **4.20 (2018):** merged (Logan Gunthorpe, with Christoph Hellwig and Steve Wise), with the NVMe-oF target option and RDMA support; review produced the "common switch by default" rule and the allowlist.
- **5.x:** allowlist growth, route caching, P2P support in the core DMA mapping paths (5.18–6.0).
- **6.2 (2022):** user-space mapping plus direct I/O.
- **6.x:** Arm64 support; no need to disable the IOMMU; block-queue capability flag.
- **6.19 (2025):** provider records and VFIO export through dma-buf (Leon Romanovsky, Jason Gunthorpe, Vivek Kasireddy).
- **2026:** VFIO dma-buf mapping (Matt Evans), the lighter core, and discussion of device-initiated I/O.

## Related

- Technical version: [[p2pdma-peer-to-peer-dma]]
- [[dma-mapping-api-explained|DMA mapping API]], [[dma-buf-sharing-explained|dma-buf sharing]], [[memory-registration-and-ib-umem-explained|RDMA memory registration]], [[nvme-over-fabrics-rdma-and-tcp-explained|NVMe over Fabrics]], [[rdma-explained|RDMA]]
- [[get-user-pages-and-pinning-explained|Page pinning]], [[bio-layer-explained|bio layer]], [[blk-mq-explained|blk-mq]], [[devmem-tcp-explained|devmem TCP]]
