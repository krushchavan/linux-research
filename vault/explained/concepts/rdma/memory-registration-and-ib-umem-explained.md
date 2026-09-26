---
title: "Memory Registration and ib_umem — Explained"
category: explained
original: "[[memory-registration-and-ib-umem]]"
subsystem: rdma
tags: [explained, rdma, memory-registration, pinning, dma-buf]
converted: 2026-09-26
---

# RDMA memory registration, explained

> Plain-language companion to [[memory-registration-and-ib-umem|the technical note]]. Same facts, fewer identifiers.

## The problem

An RDMA card reads and writes application memory by itself, often for a *remote* peer, with no CPU involved. To do that it needs its own table translating application addresses into bus (DMA) addresses, and a permission check on every access. Without that, a card could either DMA anywhere (no isolation) or would need the kernel to translate every request (no bypass). And the memory must not move while the card might touch it, which puts RDMA in conflict with everything memory management wants to do.

## The idea in one paragraph

Registration is **issuing a keycard for a storage unit**. You tell the facility (the kernel) which units you want (an address range) and what the card may do (local write, remote read, write or atomics). The facility **bolts those units in place** (pins the pages), writes their physical locations into the loading robot's map (the card's translation table), and gives you a card number: a **local key** for your own requests and a **remote key** you can hand to peers. Anyone holding the remote key can direct the robot to that unit and only that unit, with only the rights granted. The bolting is the catch: while the card is valid, the facility can't rearrange its space, and that tension drives the history of on-demand paging, dma-buf and the kernel's pinning API.

## Step by step

### Step 1: Ask
An application registers a range with access rights. The kernel checks them (remote write or atomics require local write, since the card will modify the pages) and calls the driver, which calls back into the core to acquire the memory. Since 2026, a single **buffer descriptor** can name either an address range or a dma-buf file, so every verb that takes memory, including queue buffers, can accept GPU memory as well as host memory.

### Step 2: Rule out impossible cases
The request is rejected if the range overflows, if on-demand paging was requested (that has its own path), or in confidential-computing guests that need bounce buffers (pinned registered memory can't be bounced).

### Step 3: Account
Locking memory must be allowed at all, and the page count is added to the process's **pinned-memory** total and checked against the locked-memory limit, unless the process has the lock-memory capability. Pages pinned more than once are counted each time, a deliberate overestimate. "Registration fails with out-of-memory" is most often just `ulimit -l`.

### Step 4: Pin for the long term
This is the key step. Pages are pinned with the kernel's **long-term pin** API, in batches. A pin is distinct from an ordinary reference, so memory-management code (writeback, migration, copy-on-write at fork) can tell "DMA may be in flight here" from a passing reference. Because the pin lasts indefinitely, the kernel first **moves** pages out of zones that promise movability (movable memory and CMA), and refuses file pages on DAX filesystems, which may need to truncate them.

### Step 5: Map
Physically contiguous pages are merged into large scatter-gather entries; huge pages and transparent huge pages collapse into very few. The list is DMA-mapped through the IOMMU, optionally with **relaxed ordering**, which on some platforms lets PCIe reorder the card's writes for bandwidth.

### Step 6: Choose the card's page size
Translation tables are expensive on-chip resources, so the driver picks the **largest page size** the hardware supports for which every block lines up with the device-visible address: a 1 GB huge-page buffer can take one entry instead of 262,144. The driver writes the blocks into the card's table. The device-visible address doesn't have to equal the application's own; applications can register at a chosen address, useful for zero-based offsets.

### Step 7: Release
Deregistering DMA-unmaps, unpins while marking writable pages dirty (the card may have written them), subtracts the pinned count, and drops the reference that kept the memory-map structure alive for accounting (without keeping the address space itself alive).

### Step 8: Memory with no page structures: dma-buf
GPU VRAM, accelerator memory and device BARs have no ordinary page structures, so they can't be pinned the usual way. Since 5.12 (Jianxin Xiong, Intel) they can be registered through **dma-buf**:
- **dynamic** attach: the exporter may move the buffer (say, evicting VRAM to system RAM) and notifies the importer, so the card must be able to drop and re-fault mappings; in practice that means on-demand-paging cards. Mapping waits for the exporter's fences so the card never sees a half-moved buffer.
- **pinned** attach: the exporter keeps the memory in place, for cards without on-demand paging.
- **revocable pinned** (2026): pinned, but the exporter can still pull the plug (on GPU reset or device teardown), and the driver fences its hardware off the region.

### Step 9: Kernel users register in line
Kernel consumers (storage and file protocols) already hold DMA-able pages, so they use **fast registration** instead: pre-allocate regions, map a scatter list into one, and post a *registration work request* on the queue pair, so registration happens in line with I/O at work-request cost, with no system call or firmware command. It's invalidated afterwards locally or by the peer. Per-queue pools keep stocks ready, and integrity regions add T10 protection-information offload.

### Step 10: Windows, the global key, and fork
**Memory windows** grant a narrower, revocable remote window into an existing region without re-registering. A protection domain can be created with a remote key covering **all** physical memory for legacy kernel users; it's named "unsafe" on purpose and warns. Historically, a process that registered memory then forked could have copy-on-write replace pinned pages in the *parent*, leaving the card writing to pages the parent no longer used; libraries worked around it by marking regions "don't fork". Since 5.9–5.12 the kernel copies pinned anonymous pages early at fork, so the workaround is unneeded.

## The picture

```text
 register(buf, 1 GB huge pages, REMOTE_WRITE)
   check rights → charge pinned count vs ulimit -l
   long-term pin (move out of movable/CMA first; refuse DAX)
   merge contiguous → DMA map (IOMMU) → best page size = 1 GB → 1 table entry
   ─▶ lkey (local), rkey (hand to peer)
 GPU memory: dma-buf ─ dynamic (needs ODP) | pinned | revocable pinned
 kernel users: "register" work request posted in line with I/O
```

## Tradeoffs

- **What it gives you:** line-rate address translation with no faults, hardware-enforced isolation per key, huge-page efficiency, and GPU/accelerator memory as a first-class RDMA target.
- **What it costs / requires:** pinned memory is held hostage from reclaim, compaction, NUMA balancing, memory hot-remove and filesystem truncation. Dynamic dma-buf respects GPU memory management but needs fault-capable cards; pinned dma-buf works everywhere but can block GPU memory reclaim.
- **Where it bites:** the long argument over RDMA and DAX truncation ended with long-term pins of DAX pages simply **refused**, rather than adding a lease-break protocol; on-demand paging is the supported way to RDMA into DAX. Registration failures are most often the locked-memory limit.

## How it got here

- **2.6.11:** registration with the older page-reference API and locked-memory accounting.
- **3.x:** a separate pinned-memory counter, split from the mlock counter. **3.19:** on-demand-paging regions.
- **5.2–5.6:** conversion to long-term pinning, then the dedicated pin API (John Hubbard), with RDMA as its reference user.
- **5.9–5.12:** early copy of pinned pages at fork. **5.12:** dma-buf regions (dynamic). **~5.15:** pinned dma-buf.
- **6.2:** flush rights for persistent-memory RDMA.
- **2026:** revocable pinned dma-buf, unified buffer descriptors, fast-registration pools, erdma dma-buf support, and dma-buf *export* from RDMA devices.

## Related

- Technical version: [[memory-registration-and-ib-umem]]
- [[rdma-explained|RDMA subsystem]], [[on-demand-paging-odp-explained|On-demand paging]], [[dma-buf-sharing|dma-buf sharing]], [[queue-pairs-and-completion-queues-explained|Queue pairs and CQs]], [[rdma-rw-api|rw API]]
- [[get-user-pages-and-pinning-explained|Page pinning]], [[dma-mapping-api|DMA mapping]], [[registered-resources-explained|io_uring registered resources]]
