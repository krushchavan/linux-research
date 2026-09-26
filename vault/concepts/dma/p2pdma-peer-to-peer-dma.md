---
title: "PCI Peer-to-Peer DMA (P2PDMA)"
category: concept
tags: [dma, pci, p2pdma, zone-device, nvme, rdma]
subsystem: dma
kernel_version: "4.20 (in-kernel P2PDMA); 6.2 (userspace p2pmem mmap + O_DIRECT); 6.19 (p2pdma_provider, VFIO dma-buf export)"
researched: 2026-09-26
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/driver-api/pci/p2pdma.html
  - https://github.com/torvalds/linux/blob/master/drivers/pci/p2pdma.c
  - https://github.com/torvalds/linux/blob/master/include/linux/pci-p2pdma.h
  - https://lwn.net/Articles/767281/
  - https://lwn.net/Articles/764716/
  - https://lwn.net/Articles/791676/
  - https://lwn.net/Articles/782489/
  - https://lwn.net/Articles/931668/
  - https://lwn.net/Articles/1022718/
  - https://lwn.net/Articles/1032302/
  - https://lwn.net/Articles/1080798/
  - https://www.phoronix.com/news/Linux-6.19-DMA-BUF-VFIO-PCI
  - https://patchwork.ozlabs.org/project/linux-pci/cover/20251120-dmabuf-vfio-v9-0-d7f71607f371@nvidia.com/
---

# PCI Peer-to-Peer DMA (P2PDMA)

> Queued as `mm -> p2pdma-peer-to-peer-dma`; filed under `dma/` because the code lives in `drivers/pci/` and the DMA-mapping layer, alongside [[dma-mapping-api]].

## Purpose

Normally, moving data between two PCIe devices (e.g. an RDMA NIC and an NVMe SSD) is a **bounce through system RAM**: device A DMAs into host memory, then device B DMAs out of it. That uses twice the memory-channel bandwidth and adds latency and CPU cache pollution, even though the CPU never looks at the data. **P2PDMA** lets one device DMA *directly into another device's memory BAR* (an NVMe Controller Memory Buffer, a GPU's VRAM aperture, an accelerator's buffer) across the PCIe fabric, never touching RAM. The kernel's job is to (1) represent that device memory so ordinary I/O paths can carry it, (2) decide whether the PCIe topology can safely route a transaction between two specific devices, and (3) produce the correct DMA address for each case (bus address through a switch, or IOVA/physical through a host bridge). It's the plumbing under NVMe-oF target offload, GPUDirect-style storage and networking, and dma-buf exports of device memory.

## Mental Model

PCIe is a **tree of roads**: devices are houses, switches are local intersections, and the root complex (host bridge) is the town centre. Classic DMA always goes house → town centre → RAM warehouse → town centre → other house. P2PDMA lets a delivery go **directly between houses**:
- if they share a local intersection (a switch), the truck turns there and never reaches the town centre. That is the fastest route, but the address must be the *bus* address the switch understands.
- if the only route is through the town centre, it works only if the town centre is known to forward house-to-house traffic correctly (CPU allowlist), and then the address is whatever the IOMMU/host expects.

The kernel is the **route planner** that checks the map before allowing the trip.

## How It Works

**Roles.** The kernel docs define three roles:
- **Provider** — a driver exposing device memory (or doorbells) for others: NVMe's CMB (`nvme-pci`), and via dma-buf, GPUs, VFIO devices and RDMA NICs.
- **Client** — a DMA-capable device that can target P2P memory: RDMA NICs, NVMe controllers. Clients use the standard DMA API, and the core handles P2P pages transparently.
- **Orchestrator** — code that picks a provider close to all clients and allocates from it. The NVMe-oF target is the classic orchestrator.

**Registering P2P memory (provider side).** `pci_p2pdma_add_resource(pdev, bar, size, offset)` takes a BAR range and calls `devm_memremap_pages()` with a `dev_pagemap` of type **`MEMORY_DEVICE_PCI_P2PDMA`**. That creates **ZONE_DEVICE `struct page`s** for the MMIO range. Having struct pages is the key trick: bios, scatterlists, `bio_vec`s and GUP all work with pages, so P2P memory can flow through the block layer and RDMA stack unchanged. A `gen_pool` manages allocation. The provider optionally publishes the memory (`pci_p2pmem_publish()`) for orchestrators to find, and since 6.19 records a **`struct p2pdma_provider`** (`owner`, `bus_offset`) per BAR, separating the "what bus offset does this memory have" information from the pagemap so non-page users (dma-buf, VFIO) can use it without ZONE_DEVICE. These pages are MMIO: the CPU must not `memcpy` them (use `readX`/`writeX`), and they have no normal refcounted lifetime. `p2pdma_folio_free()` returns them to the pool.

**Topology check (`calc_map_type_and_dist()`).** For a provider and a client, the core walks both devices' upstream paths to find a common ancestor:
- **Common PCIe switch, not the root port** → `PCI_P2PDMA_MAP_BUS_ADDR`. The transaction is routed by the switch, so the client must be programmed with the **PCI bus address** (`phys + bus_offset`, via `pci_p2pdma_bus_addr_map()`), *not* an IOMMU IOVA, because the IOMMU never sees it. **ACS** (Access Control Services) redirect on the switch would force traffic up to the root complex anyway, and `pci_bridge_has_acs_redir()` detects that and treats the path as crossing the host bridge. Operators often disable ACS redirect for P2P, which trades away isolation.
- **Only via the host bridge** → allowed only if `cpu_supports_p2pdma()` (AMD Zen and newer) or the host bridge is in `pci_p2pdma_whitelist[]` (Intel Xeon E5 v3, Skylake-SP and later, and specific DSA/IAA/QAT devices; some entries need both devices under the *same* host bridge). Then the result is `PCI_P2PDMA_MAP_THRU_HOST_BRIDGE`, and a **normal** mapping is used: IOVA through the IOMMU, or physical address with dma-direct.
- Otherwise `PCI_P2PDMA_MAP_NOT_SUPPORTED`, and mapping fails.

The result is cached per client in an xarray (`map_types_idx`). `pci_p2pdma_distance_many()` scores a provider against several clients, and `pci_p2pmem_find_many()` picks the closest published provider.

**Mapping (client side).** Clients call the ordinary DMA API. Inside `dma_map_sg()`/`dma_map_sgtable()`, or the newer `dma_map_phys()`/IOVA paths, the DMA layer uses `pci_p2pdma_state(&state, dev, page)`: for P2P pages it returns the cached map type and provider. `BUS_ADDR` segments get the bus address and are flagged (`sg_dma_mark_bus_address`) so unmap skips the IOMMU. `THRU_HOST_BRIDGE` segments are mapped normally. Drivers such as `nvme-pci` handle both types explicitly in their own mapping loops. Block devices that can accept P2P pages advertise `BLK_FEAT_PCI_P2PDMA` (NVMe sets it, including for multipath nodes), and the block layer refuses P2P pages for queues that don't.

**Userspace access (6.2+).** A provider's published memory can be `mmap()`ed from sysfs (`/sys/bus/pci/devices/<bdf>/p2pmem/allocate`, `p2pmem_alloc_mmap()`), giving userspace a VMA backed by P2P pages. GUP refuses such pages unless the caller passes **`FOLL_PCI_P2PDMA`** (checked in `mm/gup.c`), and `FOLL_LONGTERM` is refused. So only subsystems that opted in can pin them: the block layer's `O_DIRECT` path (`iov_iter_extract_pages` with P2P allowed when the queue supports it) and therefore **io_uring O_DIRECT reads and writes**. A program can then read from one NVMe drive straight into another drive's CMB.

**In-kernel orchestration: NVMe-oF target.** With `nvmet` configfs `namespaces/<n>/p2pmem` set (`pci_p2pdma_enable_store()`), the target allocates its I/O buffers from a P2P provider (e.g. an NVMe CMB) close to both the RDMA NIC and the backing SSD. The RDMA NIC then RDMA-READs host write data straight into the CMB, and the SSD writes from the CMB, with no host DRAM involved ([[nvme-over-fabrics-rdma-and-tcp]]).

**dma-buf and VFIO (6.19+).** Device memory without ZONE_DEVICE pages is shared through **dma-buf** instead: an exporter hands out a scatterlist of P2P DMA addresses computed with `pci_p2pdma_map_type()` against a `p2pdma_provider`, and revokes with move/invalidate notifications. In 6.19, **VFIO PCI can export MMIO BAR ranges as dma-bufs** (Leon Romanovsky, Jason Gunthorpe, Vivek Kasireddy), so an RDMA NIC can register VFIO-assigned device memory as an MR ([[memory-registration-and-ib-umem]], [[dma-buf-sharing]]). In 2026 VFIO added `mmap()` of those dma-bufs for isolated subordinate processes, and `CONFIG_PCI_P2PDMA_CORE` split out provider lookup for platforms without ZONE_DEVICE. RDMA devices themselves can now export dma-bufs of their device memory.

**Removal.** Provider removal must wait until every mapping is gone: page references drop to zero (the pagemap's `percpu_ref`), or dma-buf importers have been invalidated. `pci_p2pdma_unmap_mappings()` zaps userspace mappings of p2pmem on unbind.

## Key Data Structures

**`struct pci_p2pdma`** (`p2pdma.c`) — per provider device: `pool` (gen_pool of P2P memory), `map_types` (xarray cache of per-client decisions), `p2pmem_published`, per-BAR `mem[]` providers.

**`struct p2pdma_provider`** (`include/linux/pci-p2pdma.h`) — `owner` (providing device), `bus_offset` (CPU physical → PCI bus address delta).

**`struct pci_p2pdma_pagemap`** — `dev_pagemap` + provider: ZONE_DEVICE pages for a BAR.

**`enum pci_p2pdma_map_type`** — `UNKNOWN`, `NONE`, `NOT_SUPPORTED`, `BUS_ADDR`, `THRU_HOST_BRIDGE`.

**`struct pci_p2pdma_map_state`** — `{mem, map}`, the per-mapping-loop cache used by `pci_p2pdma_state()`.

## Key Functions / Entry Points

- **`pci_p2pdma_add_resource()` / `pcim_p2pdma_provider()` / `pci_p2pmem_publish()`** — provider setup
- **`pci_p2pdma_distance_many()` / `pci_p2pmem_find_many()`** — orchestrator selection
- **`pci_alloc_p2pmem()` / `pci_p2pmem_alloc_sgl()` / `pci_free_p2pmem()` / `pci_p2pmem_virt_to_bus()`** — allocation
- **`calc_map_type_and_dist()` / `pci_p2pdma_map_type()`** — topology routing decision
- **`pci_p2pdma_state()` / `pci_p2pdma_bus_addr_map()`** — used inside DMA mapping loops
- **`p2pmem_alloc_mmap()`** — userspace mapping of published p2pmem
- **`pci_p2pdma_enable_store()`** — configfs helper (nvmet)

## Important Flags & Config Options

- `CONFIG_PCI_P2PDMA` (needs `ZONE_DEVICE`), `CONFIG_PCI_P2PDMA_CORE` (2026 provider-only core)
- `FOLL_PCI_P2PDMA` — GUP opt-in for P2P pages; `FOLL_LONGTERM` is rejected
- `BLK_FEAT_PCI_P2PDMA` — block queue can accept P2P pages
- sysfs `/sys/bus/pci/devices/<bdf>/p2pmem/{size,available,published,allocate}`
- nvmet configfs `namespaces/<n>/p2pmem` (`auto`, `0`/`1`, or a PCI device name)
- ACS settings (`pci=disable_acs_redir=` kernel parameter) — affect whether switch-local routing is possible

## Interactions with Other Subsystems

- **↑ Userspace**: p2pmem mmap + `O_DIRECT` (including io_uring) since 6.2; VFIO dma-buf export and mmap; RDMA `ibv_reg_dmabuf_mr` on exported device memory
- **→ mm**: ZONE_DEVICE pages (`memremap_pages`), GUP gating via `FOLL_PCI_P2PDMA` ([[get-user-pages-and-pinning]])
- **→ DMA mapping / IOMMU**: bus-address vs IOVA decision, `sg_dma_mark_bus_address`, DMA IOVA API ([[dma-mapping-api]])
- **→ block layer**: P2P-capable queues, NVMe CMB ([[bio-layer]], [[blk-mq]])
- **← RDMA**: NICs as clients (NVMe-oF target), dma-buf importers and (2026) exporters ([[rdma]], [[memory-registration-and-ib-umem]])
- **← dma-buf**: P2P-aware exporters and importers (`allow_peer2peer`) ([[dma-buf-sharing]])
- **Compared with devmem TCP / io_uring zcrx**: those put *network* payloads into device memory via dma-buf and the NIC's page pool. P2PDMA is the PCIe routing and addressing layer underneath any such device-to-device flow ([[devmem-tcp]])

## Design Decisions & Tradeoffs

- **Struct pages for MMIO.** Reusing ZONE_DEVICE pages let P2P memory travel through bio, sg and GUP with small changes, and that is why P2PDMA landed in 4.20. It also means special-casing everywhere (no CPU memcpy, no LONGTERM pins, gated GUP), and a long-running push ("Removing struct page from P2PDMA", LWN 791676) towards page-less representations. The 2025–26 `p2pdma_provider` and dma-buf work is that direction materializing.
- **Conservative routing policy.** Crossing the host bridge is denied unless the CPU is known-good, because many root complexes silently drop or mishandle P2P TLPs. This avoids data corruption but frustrates users on unlisted platforms.
- **Bus address vs IOVA split.** Correctly addressing switch-local transfers requires bypassing the IOMMU for those segments, which complicates the DMA API (mixed scatterlists) and reduces IOMMU protection for P2P traffic.
- **Orchestrator in the kernel for NVMe-oF, dma-buf for everything else.** In-kernel users can reason about topology themselves. Cross-driver and userspace-driven sharing is better expressed as dma-buf with revocation.

## How It Has Evolved

- **2012–2017** — out-of-tree P2P work around NVMe, RDMA and NVMe-oF (Stephen Bates, Logan Gunthorpe; Eideticom/Microsemi)
- **4.20 (2018)** — P2PDMA merged (Logan Gunthorpe, with Christoph Hellwig and Steve Wise); nvmet `p2pmem`; RDMA `rdma_rw` handles P2P pages
- **5.x** — host-bridge allowlist growth; map-type caching; `dma_map_sg` P2P support moved into dma-direct and IOMMU (5.18–6.0)
- **6.2 (2022)** — userspace p2pmem `mmap()` and `O_DIRECT` via `FOLL_PCI_P2PDMA`
- **6.x** — Arm64 support; IOMMU no longer needs disabling; blk-mq `BLK_FEAT_PCI_P2PDMA`
- **6.19 (2025)** — `struct p2pdma_provider`; VFIO PCI MMIO export through dma-buf (Leon Romanovsky, Jason Gunthorpe, Vivek Kasireddy)
- **2026** — VFIO dma-buf `mmap()` (Matt Evans), `CONFIG_PCI_P2PDMA_CORE`, dma-buf lifecycle fixes; LSFMM "device-initiated I/O" direction (accelerators issuing NVMe commands themselves)

## Further Reading

- kernel.org — [PCI Peer-to-Peer DMA Support](https://www.kernel.org/doc/html/latest/driver-api/pci/p2pdma.html)
- LWN — [Device-to-device memory-transfer offload with P2PDMA](https://lwn.net/Articles/767281/) (2018)
- LWN — [Copy Offload in NVMe Fabrics with P2P PCI Memory](https://lwn.net/Articles/764716/)
- LWN — [Controlling device peer-to-peer access from user space](https://lwn.net/Articles/782489/) (2019)
- LWN — [Removing struct page from P2PDMA](https://lwn.net/Articles/791676/)
- LWN — [Peer-to-peer DMA (LSFMM 2023)](https://lwn.net/Articles/931668/); [Device-initiated I/O (LSFMM 2025)](https://lwn.net/Articles/1022718/)
- LWN — [vfio/pci: Allow MMIO regions to be exported through dma-buf](https://lwn.net/Articles/1032302/); [vfio/pci: Add mmap() for DMABUFs](https://lwn.net/Articles/1080798/)
- Related: [[dma-mapping-api]], [[dma-buf-sharing]], [[memory-registration-and-ib-umem]], [[nvme-over-fabrics-rdma-and-tcp]], [[devmem-tcp]]

## LKML Highlights

- **"PCI/P2PDMA: Support peer-to-peer memory" (Logan Gunthorpe, 2018, v4.20)** — introduced ZONE_DEVICE P2P pages, the provider/client/orchestrator model and nvmet `p2pmem`. The review turned on routing safety: the default "only below a common switch" rule and the host-bridge allowlist came out of it. (Message-id unavailable: lore was unreachable this session.)
- **`<20251120-dmabuf-vfio-v9-0-d7f71607f371@nvidia.com>`** — "vfio/pci: Allow MMIO regions to be exported through dma-buf" v9 (Leon Romanovsky). Extracted `p2pdma_provider` (owner + bus offset) from the pagemap so page-less exporters can compute P2P DMA addresses. Merged in 6.19.
- **`<20260701171245.90111-1-matt@ozlabs.org>`** — "vfio/pci: Add mmap() for DMABUFs" (Matt Evans, 2026). Isolated, revocable BAR sub-range mappings for subordinate processes, plus `CONFIG_PCI_P2PDMA_CORE` to avoid requiring ZONE_DEVICE.
