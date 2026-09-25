---
title: "DMA Mapping API"
category: concept
tags: [dma, iommu, swiotlb, device-drivers, cache-coherency]
subsystem: dma
kernel_version: "2.6"
researched: 2026-09-25
status: complete
explained: "[[dma-mapping-api-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/core-api/dma-api-howto.html
  - https://lwn.net/Articles/1020437/
  - https://lwn.net/Articles/997563/
  - https://lwn.net/Articles/990085/
  - https://lwn.net/Articles/1036434/
  - https://lkml.org/lkml/2025/2/5/1005
---

# DMA Mapping API

> 📘 Plain-language version: [[dma-mapping-api-explained]]

## Purpose

Devices read and write memory by DMA, but the address a device uses is often not the CPU's physical address. An IOMMU may translate it, a bus may offset it, the device may only reach the low 4 GiB, and on many ARM/RISC-V systems the CPU caches are not kept coherent with device writes. If drivers handled all of this themselves, every driver would need per-platform code and most would get it wrong, with silent corruption as the result. The DMA mapping API (`include/linux/dma-mapping.h`, `kernel/dma/`) is the single portable contract. A driver describes *what* it wants the device to access and in which direction, and gets back a device-usable address. The platform layer (direct mapping, IOMMU, or bounce buffering) handles translation, isolation and cache maintenance.

## Mental Model

A DMA mapping is **issuing a visitor badge**. The device can't wander the building (physical memory) on its own. The driver asks reception (the DMA API) for a badge to specific rooms for a specific purpose: read-only, write-only, or both. Reception may give the device a room number in its own numbering scheme (an IOVA via the IOMMU). If the room is out of reach, reception copies its contents to a reachable room and back (a swiotlb bounce buffer). Before either party enters, reception tidies the room so neither sees stale contents (cache sync). When the visit ends, the badge is revoked (unmap). Ownership of the room passes back and forth, and only the current owner may touch it.

## How It Works

**Declaring what the device can reach.** At probe time the driver calls `dma_set_mask_and_coherent(dev, DMA_BIT_MASK(64))` (or 32, 40…). This records the device's addressing limit in `dev->dma_mask`/`coherent_dma_mask` and fails if the platform can't satisfy it. Everything else uses this to decide whether memory is directly reachable. The driver must not do DMA until this succeeds.

**Choosing the backend.** Each device has a set of DMA ops chosen by firmware and bus setup (`dev->dma_ops`, or none):
- **dma-direct** (`kernel/dma/direct.c`): no IOMMU. The DMA address is the physical address plus any bus offset (`phys_to_dma()`). Unreachable memory gets bounced through **swiotlb**.
- **iommu-dma** (`drivers/iommu/dma-iommu.c`): the device sits behind an IOMMU. Mapping allocates an IOVA range from a per-domain allocator (`iommu_dma_alloc_iova()`), programs IOMMU page tables, and returns the IOVA. This also *isolates* the device, which can only reach what was mapped, and that is a security property as well as a translation.

Since roughly 5.x most architectures share these two implementations (Christoph Hellwig's consolidation) instead of each carrying its own `dma_map_ops`.

**Coherent (consistent) mappings.** For long-lived structures that both CPU and device access continuously, such as descriptor rings, completion queues and mailbox memory, the driver calls `dma_alloc_coherent(dev, size, &dma_handle, gfp)`. It gets a CPU pointer and a DMA address to memory where writes by either side are visible to the other without explicit syncs. On coherent platforms (x86, most servers) that's ordinary memory. On non-coherent ones the memory is remapped uncached or write-combined, which makes it slow for bulk data. That is why coherent memory is for control structures and not payloads. `dma_pool_create()` sub-allocates small coherent blocks. `dma_alloc_noncoherent()` or `dma_alloc_pages()` give cacheable memory with explicit syncs.

**Streaming mappings (the hot path).** For I/O buffers that already exist, such as a page cache page for a disk write, an skb's data, or a [[page-pool]] page, the driver maps them per operation:
- `dma_map_single(dev, cpu_addr, size, dir)` / `dma_map_page(dev, page, off, size, dir)` for one contiguous buffer
- `dma_map_sg(dev, sgl, nents, dir)` for a scatterlist (this is how the [[blk-mq]] path maps a request: `blk_rq_map_sg()` then `dma_map_sg()`)

The **direction** (`DMA_TO_DEVICE`, `DMA_FROM_DEVICE`, `DMA_BIDIRECTIONAL`) tells the platform which cache operations are needed and lets the IOMMU set read-only or write-only permissions. Mapping transfers *ownership* to the device. On a non-coherent CPU:
- mapping `TO_DEVICE` cleans (writes back) the cache lines so the device reads current data
- mapping `FROM_DEVICE` invalidates them so the CPU won't later read stale cached data over the device's writes

The driver must check the result with `dma_mapping_error()`: IOVA space or swiotlb slots can run out. With an IOMMU, `dma_map_sg()` may merge entries, and the driver must program the device with the returned count and the `sg_dma_address()`/`sg_dma_len()` values, not the originals.

**Ownership handoffs and syncs.** A driver that reuses a mapping (RX rings, page pool) doesn't unmap and remap each time. Before the CPU reads what the device wrote, it calls `dma_sync_single_for_cpu()`. Before giving the buffer back to the device, `dma_sync_single_for_device()`. Between those calls the CPU owns the buffer and the device must not touch it, and vice versa. These syncs are no-ops on coherent hardware without bouncing, and the API lets drivers skip them cheaply (`dma_need_sync()`). The page pool uses `DMA_ATTR_SKIP_CPU_SYNC` at map time and then syncs only the bytes the device may have written (`offset`…`max_len`), because a full-page sync would waste time.

**Unmapping.** `dma_unmap_single()`/`_page()`/`_sg()` return ownership to the CPU. They perform the final cache maintenance, copy back bounce buffers for `FROM_DEVICE`, and tear down IOMMU entries. With an IOMMU, unmapping also requires an IOTLB invalidation, which is expensive. In **strict** mode (`iommu.strict=1`) it happens synchronously on every unmap. In the default **lazy** mode IOVAs are parked in a flush queue and invalidated in batches, trading a short window of stale device access for throughput. The per-unmap cost is exactly why networking keeps pages mapped for their whole life in the page pool.

**Slow path: bounce buffers (swiotlb).** If a buffer is beyond the device's mask, or the system forces bouncing because it is a confidential-computing guest (AMD SEV, Intel TDX) whose private memory the host device can't read, dma-direct maps it by copying into a preallocated, device-reachable **swiotlb** slot. `swiotlb_tbl_map_single()` copies on map for `TO_DEVICE`, and on sync or unmap back to the original for `FROM_DEVICE`. It is correct but costs a memcpy per I/O and can run out of slots under load (the `swiotlb=` boot parameter sizes it).

**Failure and debugging.** Common bugs include:
- mapping stack or vmalloc memory (not physically contiguous, and may share cache lines)
- touching a buffer while the device owns it
- DMA buffers sharing a cache line with CPU-written data on non-coherent systems (hence `ARCH_DMA_MINALIGN`/`kmalloc` alignment rules)
- forgetting `dma_mapping_error()`
- unmapping with a different size or direction

`CONFIG_DMA_API_DEBUG` tracks every mapping and warns on mismatched unmaps, missing error checks, and leaks at driver unbind.

**The two-step IOVA API (6.16).** Scatterlists force conversions: bio → sg table → DMA addresses. They depend on `struct page` (which P2P device memory and dma-buf often lack) and have been bent for non-standard uses. Leon Romanovsky's series, with Christoph Hellwig and Jason Gunthorpe, lets a caller:
1. reserve an IOVA range once with `dma_iova_try_alloc()`
2. link physical ranges into it with `dma_iova_link()`, directly from a bio_vec or a user page list
3. flush once with `dma_iova_sync()`
4. later `dma_iova_unlink()`/`dma_iova_destroy()`

If there is no IOMMU the try-alloc fails and the caller falls back to per-range mapping. It was contested: Robin Murphy objected that it pushes low-level IOMMU knowledge into drivers. It was merged via Marek Szyprowski's tree after demonstrating wins in VFIO, NVMe, RDMA and HMM. A follow-up series moves the core API toward physical addresses (`dma_map_phys()`), removing the `struct page` requirement.

## Key Data Structures

**`struct scatterlist`** (`include/linux/scatterlist.h`) — page, offset, length (CPU view) plus `dma_address`, `dma_length` (device view after mapping). **`struct sg_table`** wraps a list and its mapped count (`sgt->nents` vs `orig_nents`).

**`struct device`** DMA fields — `dma_mask`, `coherent_dma_mask`, `bus_dma_limit`, `dma_range_map` (bus offsets), `dma_ops`, `dma_io_tlb_mem` (swiotlb pool), `dma_coherent`.

**`struct dma_iova_state`** — the reserved IOVA range and its size for the two-step API.

**`enum dma_data_direction`** — `DMA_BIDIRECTIONAL`, `DMA_TO_DEVICE`, `DMA_FROM_DEVICE`, `DMA_NONE`.

## Key Functions / Entry Points

**`dma_set_mask_and_coherent()`** — declare addressing capability.
**`dma_alloc_coherent()` / `dma_free_coherent()`**, **`dma_pool_*()`** — coherent memory.
**`dma_map_single()` / `dma_map_page()` / `dma_map_sg()` / `dma_map_sgtable()`** — streaming maps.
**`dma_sync_single_for_cpu()` / `_for_device()`**, **`dma_sync_sg_*()`** — ownership handoffs.
**`dma_mapping_error()`** — must check.
**`dma_unmap_*()`** — release.
**`dma_iova_try_alloc()` / `dma_iova_link()` / `dma_iova_sync()` / `dma_iova_destroy()`** — two-step API.
**`swiotlb_tbl_map_single()`** (`kernel/dma/swiotlb.c`), **`iommu_dma_map_page()`** (`drivers/iommu/dma-iommu.c`), **`dma_direct_map_page()`** — backends.

## Important Flags & Config Options

- `DMA_ATTR_SKIP_CPU_SYNC` — skip cache maintenance at map/unmap; caller syncs precisely (page pool, RDMA).
- `DMA_ATTR_WEAK_ORDERING`, `DMA_ATTR_WRITE_COMBINE`, `DMA_ATTR_NO_KERNEL_MAPPING`, `DMA_ATTR_ALLOC_SINGLE_PAGES`.
- `iommu.strict=`, `iommu.passthrough=` / `iommu=pt` — IOTLB flush policy and identity mapping (no translation, less isolation, faster).
- `swiotlb=<slabs>[,force]` — bounce-buffer pool size or forcing.
- `CONFIG_DMA_API_DEBUG`, `CONFIG_SWIOTLB`, `CONFIG_IOMMU_DMA`, `CONFIG_DMA_CMA` (contiguous allocations via CMA).

## Interactions with Other Subsystems

- **↑ Userspace**: none directly. VFIO and RDMA pin user memory and map it for devices on userspace's behalf ([[get-user-pages-and-pinning]]).
- **← Drivers**: every DMA-capable driver: NVMe/[[blk-mq]] via scatterlists, NICs via [[page-pool]] and skb mapping, GPUs via dma-buf.
- **→ IOMMU subsystem**: IOVA allocation, page tables, IOTLB invalidation, device isolation.
- **→ [[buddy-allocator]] / CMA**: backing memory for coherent and contiguous allocations.
- **↔ [[devmem-tcp]] / dma-buf**: dma-buf attachments hand out already-mapped sg tables; P2P DMA maps device BARs between devices.
- **→ Confidential computing**: swiotlb bouncing for SEV/TDX guests (the "restricted DMA" pools).

## Design Decisions & Tradeoffs

- **Explicit ownership instead of hardware coherence.** Making drivers call map/sync/unmap lets Linux run the same driver on coherent x86 and non-coherent ARM. The cost is API discipline, and a whole class of bugs (touching owned buffers) appears only on non-coherent machines.
- **Coherent vs streaming split.** Uncached coherent memory is simple but slow, while streaming mappings are fast but need syncs. Offering both lets drivers use each where it fits.
- **IOMMU as translation *and* protection.** Mapping per I/O narrows what a malicious or buggy device can touch, but unmap-time IOTLB flushes are costly. Lazy flush queues, long-lived mappings (page pool) and passthrough mode each trade isolation for speed.
- **Scatterlist-centric API.** A universal currency made driver code uniform but forced conversions and tied DMA to `struct page`. The 2025 two-step IOVA API and physical-address API are the long-awaited departure, accepted despite maintainer pushback because P2P, dma-buf and VFIO needed it.
- **Bounce buffering as a safety net.** swiotlb keeps weakly addressing devices and confidential guests working without driver changes, at the cost of copies and a fixed-size pool that can be exhausted.

## How It Has Evolved

- **2.4** — PCI-specific `pci_map_single()` family; `Documentation/DMA-mapping.txt`.
- **2.6** — generic `dma_*` API on `struct device`; swiotlb adopted from IA-64 for x86-64.
- **2.6.30** — `CONFIG_DMA_API_DEBUG`.
- **4.x–5.x** — consolidation into common dma-direct and iommu-dma (Christoph Hellwig); arch-specific `dma_map_ops` removed; x86 moved to iommu-dma (5.13); `pci_*` DMA wrappers deleted (5.18).
- **5.x–6.x** — restricted DMA pools and forced bouncing for confidential VMs; `dma_alloc_noncoherent()`/`dma_alloc_pages()`; IOMMU flush-queue improvements.
- **6.16 (2025)** — two-step IOVA API (Leon Romanovsky), used by NVMe PCI, RDMA, VFIO, HMM.
- **2025–2026** — migration to a physical-address-based mapping API (`dma_map_phys()`), reducing dependence on `struct page` and scatterlists.

## Further Reading

1. [A new DMA-mapping API — LWN (2025)](https://lwn.net/Articles/1020437/)
2. [Dancing the DMA two-step — LWN (2024)](https://lwn.net/Articles/997563/)
3. [dma-mapping: migrate to physical address-based API — LWN](https://lwn.net/Articles/1036434/)
4. [Dynamic DMA mapping Guide — kernel.org](https://www.kernel.org/doc/html/latest/core-api/dma-api-howto.html)
5. [DMA API reference — kernel.org](https://www.kernel.org/doc/html/latest/core-api/dma-api.html)

## LKML Highlights

- **"Provide a new two step DMA mapping API" (Leon Romanovsky, v1–v10, 2024–2025; e.g. `cover.1731244445.git.leon@kernel.org`)** — IOVA alloc/link/sync. Robin Murphy's rejection and the ensuing debate about how much IOMMU knowledge consumers should have were resolved by merging via the dma-mapping tree for 6.16.
- **"[PATCH v7 05/17] dma-mapping: Provide an interface to allow allocate IOVA" (Feb 2025)** — the core `dma_iova_try_alloc()` design with its no-IOMMU fallback contract.
- **"dma-mapping: migrate to physical address-based API" (2025)** — begins removing `struct page` from the mapping interface, motivated by P2P and device-memory users like [[devmem-tcp]].
