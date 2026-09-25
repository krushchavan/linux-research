---
title: "DMA Mapping API — Explained"
category: explained
original: "[[dma-mapping-api]]"
subsystem: dma
tags: [explained, dma, iommu, swiotlb, drivers]
converted: 2026-09-25
---

# The DMA mapping API, explained

> Plain-language companion to [[dma-mapping-api|the technical note]]. Same facts, fewer identifiers.

## The problem

Devices such as disks and network cards move data by **DMA**: they read and write memory directly, without the CPU copying each byte. That sounds simple, but the address a device uses is often not the CPU's physical address:
- an **IOMMU** (an address translator for devices) may sit in between
- a bus may add an offset
- the device may only reach the low 4 GiB of memory
- on many ARM and RISC-V systems, CPU caches aren't kept in sync with device writes, so the CPU can read stale cached data, or the device can read memory the CPU hasn't written back yet

If each driver handled all of that itself, every driver would need per-platform code, and most would get it wrong. The result would be silent data corruption.

## The idea in one paragraph

One portable contract for every driver. A DMA mapping is **issuing a visitor badge**. The device can't wander physical memory on its own; the driver asks the DMA API for a badge to specific rooms for a specific purpose (read-only, write-only, or both). The API may give the device room numbers in its own numbering (IOMMU addresses). If a room is out of reach, it copies the contents to a reachable room and back (bounce buffers). Before either side enters, it tidies the room so nobody sees stale contents (cache maintenance). When the visit ends, the badge is revoked. Only the current owner, CPU or device, may touch the room.

## Step by step

### Step 1: Declare what the device can reach
When a driver starts up, it declares how many address bits the device can use (for example 32, 40 or 64). This fails if the platform can't satisfy it, and the driver must not do DMA until it succeeds. Everything else uses this limit to decide whether memory is directly reachable.

### Step 2: The platform picks a back end
Each device gets one of two main implementations, based on firmware and bus setup:
- **Direct:** no IOMMU. The device address is the physical address plus any bus offset. Memory the device can't reach is bounced.
- **IOMMU:** the device sits behind an IOMMU. Mapping reserves a range of device-side addresses (IOVAs), programs the IOMMU's page tables, and returns the IOVA. This also **isolates** the device: it can reach only what was mapped, which is a security property as well as a translation.

Since roughly 5.x most architectures share these two implementations (consolidated by Christoph Hellwig) instead of each having its own.

### Step 3: Long-lived shared memory: coherent mappings
For structures both CPU and device touch constantly (descriptor rings, completion queues, mailboxes), the driver allocates **coherent** memory: it gets a CPU pointer and a device address, and writes by either side are visible to the other with no extra steps. On coherent platforms (x86, most servers) that's ordinary memory. On non-coherent ones it's mapped uncached, which is slow for bulk data. So coherent memory is for control structures, not payloads. Pools can carve many small coherent blocks from it.

### Step 4: Per-I/O buffers: streaming mappings
For buffers that already exist (a page-cache page being written to disk, a network packet, a page-pool page) the driver maps them for each operation, one buffer or a scatter list of pieces. The block layer does exactly this for each request.

The **direction** matters. It tells the platform what cache work to do and lets the IOMMU set read-only or write-only permissions. On a non-coherent CPU:
- mapping *to* the device writes dirty cache lines back to memory, so the device reads current data
- mapping *from* the device discards those cache lines, so the CPU won't later read stale cached data instead of what the device wrote

Mapping hands **ownership** to the device. The driver must check for failure (IOMMU address space or bounce slots can run out). With an IOMMU, a scatter list may come back merged into fewer pieces, and the driver must program the device with the returned list, not the original.

### Step 5: Hand ownership back and forth without unmapping
This is the key discipline. Drivers that reuse a buffer, such as network receive rings, don't unmap and remap every time. Before the CPU reads what the device wrote, the driver syncs "for CPU". Before giving the buffer back, it syncs "for device". In between, only the owner may touch it.

On coherent hardware without bouncing these syncs do nothing, and drivers can check that cheaply. The page pool goes further: it skips syncing at map time and later syncs only the bytes the device could actually have written, because syncing a whole page every time wastes work.

### Step 6: Unmapping, and the IOMMU flush cost
Unmapping returns ownership to the CPU: final cache work, copying bounce buffers back, and removing IOMMU entries. Removing IOMMU entries requires invalidating the IOMMU's translation cache, which is expensive.
- In **strict** mode it happens on every unmap.
- In the default **lazy** mode, freed addresses are queued and invalidated in batches, accepting a short window in which the device could still reach them, in exchange for throughput.

This per-unmap cost is exactly why networking keeps pages mapped for their whole life in the page pool.

### Step 7: The slow path: bounce buffers
If a buffer is beyond the device's reach, or the machine forces bouncing because it's a confidential-computing guest (AMD SEV, Intel TDX) whose private memory the host's devices can't read, the direct back end copies the data through a pre-allocated, reachable pool (**swiotlb**). It copies in when mapping to the device and back out when syncing or unmapping from it. It's correct, but costs a copy per I/O and the pool can run out under load; a boot parameter sets its size.

### Step 8: Common bugs, and the debugging aid
Typical mistakes:
- mapping stack or vmalloc memory, which isn't physically contiguous and may share cache lines
- touching a buffer while the device owns it
- DMA buffers sharing a cache line with CPU-written data on non-coherent systems (hence minimum-alignment rules)
- not checking for mapping failure
- unmapping with a different size or direction

A debug option tracks every mapping and warns about these, and about leaks when a driver detaches.

### Step 9: The newer two-step API (6.16)
Scatter lists force conversions (block request → scatter list → device addresses) and depend on the kernel's per-page descriptors, which device memory often lacks. Leon Romanovsky's series, with Christoph Hellwig and Jason Gunthorpe, lets a caller reserve an IOVA range once, link physical ranges into it directly, flush once, and later unlink and release it. With no IOMMU, the reservation fails and the caller falls back to mapping piece by piece. Robin Murphy objected that it pushes low-level IOMMU knowledge into drivers; it merged after showing gains in VFIO, NVMe, RDMA and HMM. A follow-up moves the core API toward plain physical addresses.

## The picture

```text
 driver: "device may read these pages"  (direction: to device)
            │
            ▼
      DMA mapping API
   ┌────────┴──────────────────────────────┐
 direct (no IOMMU)                     IOMMU
 reachable? → phys + offset            reserve IOVA, program page tables
 not reachable / confidential VM          → device sees only mapped pages
   → copy via bounce pool (swiotlb)
   └────────┬──────────────────────────────┘
            │ non-coherent CPU: write back / discard cache lines
            ▼
     device address ──▶ device does DMA
            │
  sync for CPU ⇄ sync for device (reuse without unmapping)
            │
          unmap: final cache work, copy back, IOMMU invalidation (strict or batched)
```

## Tradeoffs

- **What it gives you:** one driver that works on coherent x86 and non-coherent ARM, with IOMMU isolation and bounce buffering handled underneath.
- **What it costs / requires:** strict ownership discipline in drivers; uncached coherent memory is slow; IOMMU invalidations and bounce copies cost real time.
- **Where it bites:** ownership bugs often show up only on non-coherent machines, as rare silent corruption. Isolation versus speed is a constant trade: lazy invalidation, long-lived mappings and IOMMU passthrough mode (no translation, faster, less isolation) all give up some protection.

## How it got here

- **2.4:** a PCI-specific mapping interface.
- **2.6:** the generic API on any device; bounce buffering adopted from IA-64 for x86-64; later (2.6.30) the debug option.
- **4.x–5.x:** consolidation into common direct and IOMMU back ends; x86 moved to the common IOMMU back end (5.13); the old PCI wrappers deleted (5.18).
- **5.x–6.x:** restricted bounce pools and forced bouncing for confidential VMs; cacheable non-coherent allocations; better IOMMU flush queues.
- **6.16 (2025):** the two-step IOVA API, now used by NVMe, RDMA, VFIO and HMM.
- **2025–2026:** migration toward a physical-address-based mapping API, motivated by device-to-device and device-memory users like devmem TCP.

## Related

- Technical version: [[dma-mapping-api]]
- [[blk-mq-explained|blk-mq]]: maps each block request for the device
- [[page-pool|Page pool]]: keeps network pages mapped for life
- [[get-user-pages-and-pinning|Page pinning]]: how user memory is pinned before mapping
- [[buddy-allocator-explained|Buddy allocator]]: backing memory for coherent allocations
- [[devmem-tcp|Device-memory TCP]]: a driver of the move away from per-page descriptors
