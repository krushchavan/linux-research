---
title: "RDMA R/W API (rdma_rw) — Explained"
category: explained
original: "[[rdma-rw-api]]"
subsystem: rdma
tags: [explained, rdma, rdma-rw, storage-targets]
converted: 2026-09-26
---

# The RDMA rw helper, explained

> Plain-language companion to [[rdma-rw-api|the technical note]]. Same facts, fewer identifiers.

## The problem

Every RDMA **storage target** (NVMe-oF, iSER, SRP, the NFS server, SMB Direct in ksmbd) does the same job. A client sends a command naming its buffers as "remote address, remote key, length". The target then moves data with an **RDMA write** (when the client reads) or an **RDMA read** (when the client writes) between those remote buffers and local pages. Doing it correctly means respecting device limits (how many memory pieces fit in one request, which differ for reads), transport quirks (iWARP needs the local destination of a read to be a registered region), optional data-integrity offload, and memory-region pools. Before 2016, every target reimplemented this with subtly different bugs.

## The idea in one paragraph

The helper is a **freight broker** for one transfer. You hand it the cargo (local memory, as a scatter list or block-layer page vectors), the destination dock (remote address and key) and the direction. It checks the carrier's rules and picks the cheapest compliant plan: one truck (a single request), a convoy (several chained requests, each within the piece limit), one truck after repacking the cargo into a single contiguous virtual container (an IOMMU mapping), or a registered container with its own key (fast registration, the heaviest option). It gives back ready-to-post paperwork (a chain of work requests), and cleans up afterwards.

## Step by step

### Step 1: Size the queue up front
When the target creates its queue pair, it says how many transfers may be in flight. The helper enlarges the send queue to cover the worst case (registration, transfer and invalidation requests for each) and pre-fills per-queue pools of memory regions, including integrity regions, so nothing is allocated per I/O.

### Step 2: Choose a strategy
Given a scatter list, the helper DMA-maps it, then decides:
1. **Register memory** when the rules require it: iWARP with an RDMA read (the read's destination must have a key with remote-write rights), the device hinting that reads with this many pieces work better registered, or a debug option forcing it. It takes regions from the pool, builds for each chunk an optional invalidate (if the region's old key is still live), a **register** request with a fresh key (so a stale key can't be reused), and the transfer itself. On iWARP, reads use a variant that invalidates the region automatically when the read completes. If the pool is empty and registration was only an optimisation, it falls back to plain pieces.
2. **Several chained requests**, each with at most the device's piece limit, advancing the remote address as it goes.
3. **A single request** for a one-piece transfer, needing no allocation at all.

### Step 3: Block-layer input and one contiguous mapping
This is the key recent step. Block targets hold page vectors, not scatter lists, and since 2025–26 the helper takes those directly. On a system with an IOMMU it first tries to reserve **one contiguous IO-virtual range** for the whole transfer and link each page into it. However fragmented the pages, the transfer becomes a **single piece** in a single request, with no registration and no splitting. It uses the new two-step DMA IOVA API (6.16+) and isn't available for software devices, which fall back to per-page mapping.

### Step 4: Integrity offload
For T10 protection information, the helper registers an **integrity region** describing data and protection information and their formats on the wire and in memory, so the card inserts, strips or checks the protection bytes in flight. NVMe-oF and iSER use it for end-to-end integrity.

### Step 5: Post in one go
The helper returns the chain with the target's completion callback on the **last** request only, and can append the target's own request. The NVMe-oF target chains its response message right behind the data write, so data and response go out with one post and one doorbell. It relies on reliable-connection ordering: the write lands before the message is delivered. The helper also reports how many send-queue slots the transfer uses, for the target's own accounting.

### Step 6: Clean up
After completion, the helper returns regions to the pool (to be invalidated on next use if needed), frees any arrays, and DMA-unmaps, releasing the contiguous IOMMU range on that path.

## The picture

```text
 client: "write 1 MB to me at addr A, key K"
 target: rw_init(local pages, A, K, direction = write-to-remote)
   iWARP read?  device prefers registration?  → REGISTER (+ invalidate, fresh key) + transfer
   IOMMU + page vectors?                        → one contiguous IOVA → 1 piece, 1 request
   ≤ piece limit?                               → single request
   else                                         → chain of requests within the limit
 post: [RDMA WRITE ...][RDMA WRITE (signalled)] + [SEND response]  ← one doorbell
 done: regions back to pool, unmap
```

## Tradeoffs

- **What it gives you:** one correct implementation for every target, with iWARP support and integrity offload for free, no per-I/O allocation, and a single doorbell for data plus response.
- **What it costs / requires:** queues reserve pooled regions whether or not they're used (a sizing helper lets targets tune this); the choice between pieces and registration depends partly on vendor hints, so it's somewhat opaque.
- **Where it bites:** the contiguous-IOVA path turns a fragmented transfer into one piece but needs an IOMMU in translating mode and adds IOTLB pressure; registration still wins for iWARP reads and integrity offload.

## How it got here

- **4.7 (2016):** introduced by Christoph Hellwig alongside the NVMe-oF target; iSER and SRP targets converted. Review (Sagi Grimberg, Steve Wise) focused on iWARP's self-invalidating read and pool sizing.
- **4.x:** integrity contexts; the NFS server converted (Chuck Lever).
- **5.x:** sizing helpers; a dedicated integrity region type (5.3).
- **2025–26:** block-layer page-vector input, the single-IOVA strategy, and falling back from optional registration when the pool runs dry.

## Related

- Technical version: [[rdma-rw-api]]
- [[rdma-explained|RDMA subsystem]], [[memory-registration-and-ib-umem-explained|Memory registration]], [[queue-pairs-and-completion-queues-explained|Queue pairs and CQs]], [[iwarp-transport-explained|iWARP]], [[nvme-over-fabrics-rdma-and-tcp|NVMe over Fabrics]], [[nfs-over-rdma-svcrdma-xprtrdma|NFS over RDMA]]
- [[bio-layer-explained|bio layer]], [[dma-mapping-api|DMA mapping]]
