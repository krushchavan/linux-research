---
title: "dma-buf: Cross-Device Buffer Sharing — Explained"
category: explained
original: "[[dma-buf-sharing]]"
subsystem: dma
tags: [explained, dma, dma-buf, buffer-sharing, gpu]
converted: 2026-09-26
---

# dma-buf, explained

> Plain-language companion to [[dma-buf-sharing|the technical note]]. Same facts, fewer identifiers.

## The problem

Devices increasingly need to work on *the same memory* without copying: a camera writes frames that a GPU renders and a display shows; GPU memory is the target of an RDMA transfer; a network card receives packets straight into accelerator memory. But each driver has its own allocator and its own idea of where a buffer lives (system RAM, GPU VRAM, a device BAR, reserved regions). They can't pass ordinary page pointers around, because device memory often has no page structures, may move, and needs cache and IOMMU handling per device. And asynchronous engines don't finish work when their submit call returns, so everyone also needs to know *when* the buffer is safe to touch.

## The idea in one paragraph

A dma-buf is a **shared storage locker with a building manager**. The **exporter** is the manager: it owns the buffer, knows where it physically is, and may relocate it. Importers get a **key card**, a file descriptor. To use the locker, an importer registers its device (**attach**) and asks for **directions from its own device's point of view** (a list of DMA addresses for that device, with IOMMU and peer-to-peer routing already worked out). A **static** importer insists the locker never moves while it holds directions. A **dynamic** importer agrees to throw its directions away when the manager announces a move, and ask again. A **sign-out sheet** on the door (the reservation object, listing completion fences) shows which devices are still working inside, so the next user or the mover can wait.

## Step by step

### Step 1: Export
A driver describes the buffer (size, flags, its operations, private data) and exports it, creating a buffer object backed by an anonymous file, then installs a **file descriptor** so user space can pass it between processes or into other drivers. Exporters include GPU drivers, **dma-heaps** (generic allocators), udmabuf (wrapping ordinary memory), media drivers, VFIO for device BARs (6.19), and RDMA devices exporting device memory (2026).

### Step 2: Attach
An importer takes a reference from the descriptor and attaches its device, either **statically** (the exporter pins the buffer while mappings exist) or **dynamically**, declaring whether it can handle peer-to-peer addresses with no page structures and providing an **invalidate** callback for when the exporter moves or revokes the buffer. The exporter may refuse a device, for instance if peer-to-peer routing to it isn't possible.

### Step 3: Map for this device
This is the key step. Mapping asks the exporter for a **scatter list of DMA addresses valid for this specific device**. It may be backed by the exporter's pages mapped through the device's IOMMU. For device memory, it often has **no CPU pages at all**: a helper builds it from physical ranges using the DMA IOVA API or peer-to-peer bus addresses and deliberately leaves the page fields empty, so importers can't sneak CPU access. Importers program their hardware from the DMA addresses only. Unmapping, detaching and dropping the reference end the relationship.

### Step 4: Synchronise with fences
A **fence** is a one-shot "done" signal, fired by a driver's interrupt handler. Each buffer has a **reservation object**: a lock plus a set of fences tagged by purpose (kernel, write, read, bookkeeping). Producers add their fence; consumers wait for the relevant fences before touching the buffer. That's **implicit** synchronisation, the traditional Linux graphics model; **explicit** synchronisation (Android, Vulkan) passes fences as separate files instead, and the two can convert back and forth. CPU access through memory mapping is bracketed by a sync call for cache maintenance.

### Step 5: Moving and revoking
When an exporter must relocate a buffer (say, evicting GPU memory under pressure), it tells every dynamic importer to **invalidate** its mappings. The contract: importers may still access the memory until the fences in the reservation object finish, and until they unmap they may still read speculatively but not write. An exporter wanting access *fully* stopped waits for both. Importers must unmap within **bounded time** and may immediately re-map to get the new location. For **pinned** importers, an invalidate means permanent **revocation**, which is how VFIO pulls a device BAR back when the device is reset or reassigned. Since 2026, exporters can refuse importers that can't promise bounded revocation, and RDMA added a pinned-but-revocable registration so network cards can comply.

### Step 6: Importers in networking and RDMA
- **RDMA memory regions:** dynamic attach for on-demand-paging cards (rebuild translations after an invalidate, waiting for fences first); pinned or pinned-revocable for others.
- **devmem TCP:** binds a dma-buf to receive queues statically, so the page pool hands out chunks of it and payloads land in GPU memory.
- **io_uring zero-copy receive:** its receive area can be a dma-buf as well as user memory.
- **iommufd / VFIO:** import dma-bufs to map device memory into a guest's address space (2026).

## The picture

```text
 GPU driver (exporter) ── export ──▶ fd ──▶ user space ──▶ RDMA / devmem / io_uring (importers)
 importer: attach(dev) ─ static (pinned) | dynamic (invalidate callback, P2P ok?)
           map(dev) ─▶ exporter returns DMA addresses FOR THIS DEVICE (maybe no pages)
 reservation object: [GPU write fence] [NIC read fence] … wait before touching
 exporter moves VRAM: invalidate → importers unmap (bounded time) after fences retire → re-map
```

## Tradeoffs

- **What it gives you:** zero-copy sharing across any drivers, with file descriptors providing lifetime, cross-process passing and a common currency; per-device mappings that respect IOMMU groups and peer-to-peer routes; eviction support for dynamic importers.
- **What it costs / requires:** one mapping per importing device; dynamic import requires hardware that can drop and re-fault mappings (for network cards, on-demand-paging-class hardware); pinning works everywhere but blocks GPU memory eviction.
- **Where it bites:** page-less scatter lists reuse an existing container but demand discipline (never touch the page field). Implicit fences make naive sharing work but serialise more than necessary. The 2026 revocation work exposed a real conflict: RDMA's pinned importers couldn't promise bounded revocation, which led to the pinned-revocable registration API.

## How it got here

- **3.3 (2012):** dma-buf for graphics and media sharing (Sumit Semwal, Linaro).
- **3.x–4.x:** fences and reservation objects (Maarten Lankhorst); sync files for explicit sync.
- **5.3–5.7:** dynamic importers, pin/unpin, move notification and peer-to-peer (Christian König, AMD).
- **5.6:** dma-heaps replace Android's ION. **5.12:** RDMA memory regions from dma-bufs, the first non-graphics dynamic importer.
- **6.x:** devmem TCP (6.12), io_uring dma-buf areas, fence usage levels, sync-file import/export.
- **6.19 (2025):** VFIO device-memory export; page-less mapping helpers.
- **2026:** the revocation series (Leon Romanovsky): "move notify" renamed "invalidate mappings", revocable-attach checks, move notification always on, VFIO waiting for importers; RDMA export and pinned-revocable import.

## Related

- Technical version: [[dma-buf-sharing]]
- [[p2pdma-peer-to-peer-dma|P2PDMA]], [[dma-mapping-api-explained|DMA mapping API]], [[memory-registration-and-ib-umem-explained|RDMA memory registration]], [[on-demand-paging-odp-explained|On-demand paging]], [[rdma-explained|RDMA]]
- [[devmem-tcp-explained|devmem TCP]], [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]], [[page-pool-explained|Page pool]]
