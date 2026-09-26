---
title: "Memory Pinning and Registration Strategies — Explained"
category: explained
original: "[[memory-pinning-and-registration-strategies]]"
subsystem: comparisons
tags: [explained, comparison, pinning, rdma, io_uring]
converted: 2026-09-26
---

# Memory pinning and registration strategies, explained

> Plain-language companion to [[memory-pinning-and-registration-strategies|the technical note]]. Same facts, fewer identifiers.

## The problem

A device such as a network card, an SSD controller or an RDMA NIC reads and writes memory directly, using **bus addresses**. Those addresses have to stay valid for as long as the device might use them.

Ordinary process memory breaks that promise all the time. The kernel may swap a page out, move it to defragment memory or balance NUMA nodes, merge identical pages, split or merge huge pages, or swap in a fresh copy after `fork()` (copy-on-write). If a device is halfway through writing to a page when the kernel moves it, the data lands in memory that now belongs to something else.

So every zero-copy interface has to answer three questions before any data moves:
1. **Stability**: how do we stop the page from moving, or find out when it does?
2. **Translation**: when do we turn virtual addresses into device addresses (through the IOMMU, or into the device's own translation table)?
3. **Accounting**: whose limit does this unmovable memory count against?

## The idea in one paragraph

Think of lending a parking space to a delivery company (the device). You can **reserve it for one delivery** and release it afterwards. That is cheap to arrange but costs something every time. You can **sign a lease**: the space can't be towed or repainted and it counts against your quota, but every later delivery is free. You can **skip the lease, provided the city phones the company before moving your space**, so the company updates its map and asks again next time. Or the space can **belong to another landlord** (a GPU driver) who grants a permit that is fixed, movable-with-notice, or revocable. Linux uses all four approaches, and each interface picks one.

## Step by step

### Step 1: The foundation, marking a page as "a device is using this"
Anything that uses ordinary user memory goes through the kernel's **get-user-pages** machinery ([[get-user-pages-and-pinning-explained|get_user_pages and pinning]]). The kernel's own documentation names four cases:
- short pins for **direct I/O**
- long-lived pins for **RDMA**
- **no pin at all** when the driver instead listens for notifications that the page is about to change
- plain references when the caller only needs to look at the page's bookkeeping, not its data.

What makes a **pin** different from an ordinary reference is that the memory manager can *tell* the difference. A pinned page is counted in a distinctive way, so code doing writeback, migration or `fork()` can ask "might a device be writing here?" and act safely. Since the 5.18–5.19 fixes, pinning an anonymous page first makes it exclusive to one process. That ended a long-standing bug where a `fork()` could swap in a new copy while the device kept writing to the old one. RDMA users used to need a special workaround for this.

### Step 2: Long-term pins carry extra rules
A pin that may last hours (an RDMA region, an io_uring buffer) is flagged **long-term**. Two things follow.
- The page is **moved out of the memory zones that promise movability** before it is pinned. Those zones exist so memory can be hot-unplugged or contiguous ranges allocated, and a permanent pin would break that promise.
- **Most file-backed pages are refused.** A filesystem can't truncate or reallocate blocks while a device may be writing to them indefinitely. That is why long-term interfaces accept anonymous memory, shared memory or hugetlbfs, but not ordinary files.

### Step 3: Per-I/O pinning (direct I/O, MSG_ZEROCOPY)
**Direct I/O** pins the user buffer for each request and releases it on completion. Converting the block layer to real pins took years and was finished around 6.3–6.5. The device address mapping is also done per request, when the block driver dispatches the I/O.

**Zero-copy send (`MSG_ZEROCOPY`)** pins the pages for each send and holds them until the data is acknowledged. That memory counts against the locked-memory limit in the meantime.

The upside is no setup and no long-lived unmovable memory. The downside is that the page-table walk, the reference counting and the IOMMU work are repeated **on every operation**, which dominates at high rates or small sizes.

### Step 4: io_uring registered buffers, pin once and map per I/O
Registering buffers with io_uring pins them once, long-term, and charges them to the locked-memory limit ([[registered-resources-explained|registered resources]]). Since 6.12, pages that belong to one huge page are grouped into a single entry.

The important detail is that registration **does not** set up device addresses. Each read, write or zero-copy send still has its addresses mapped by the driver per request. So registered buffers remove the *pinning* cost but not the *IOMMU* cost. A 2022 proposal to pre-map them for NVMe was not merged.

Two newer variants: buffer tables can be **cloned** between rings by reference (about 17 µs instead of about 1 s to re-pin gigabytes). And a driver such as ublk can place **its own pages** into a ring's buffer table, so nothing gets pinned at all ([[ublk-zero-copy-explained|ublk zero copy]]).

### Step 5: RDMA memory regions, pin, map and program the NIC once
Registering an RDMA **memory region** is the heaviest and most complete option ([[memory-registration-and-ib-umem-explained|memory registration]]):
1. check and charge the locked-memory limit
2. pin long-term
3. merge contiguous pages
4. map them through the IOMMU **once**
5. write the translation into the **NIC's own table**, using the largest page size the NIC supports.

The result is a key that lets the NIC, or a *remote* machine, access the memory with no kernel involvement per operation.

The costs are registration time (hundreds of microseconds to milliseconds), pressure on the NIC's translation cache, and the pinned memory itself. Libraries such as MPI and UCX hide the cost with **registration caches**, which need their own notifications to spot freed memory. Kernel users skip this path entirely: they register short-lived regions per I/O with a special work request posted in line with the data ("fast registration").

### Step 6: On-demand paging, no pin at all
This is the key alternative. With **on-demand paging (ODP)** ([[on-demand-paging-odp-explained|ODP]]) nothing is pinned and no locked memory is charged. Instead, the region is registered with a **change notifier**.
- **When the NIC needs a page** it has no translation for, it raises a *network page fault*. The driver faults the page in the same way the CPU would, maps it, and loads it into the NIC. Remote senders are told to retry in the meantime.
- **When the kernel wants a page back** (reclaim, migration, unmap), the notifier runs *first*. The driver removes the NIC's translation, marks the page dirty if needed, and only then does the kernel proceed.

The trade is the mirror image of pinning. Memory stays fully managed (swappable, movable, huge-page friendly) and registration is nearly free, but each fault costs tens to hundreds of microseconds, and the NIC must support restartable faults. **Implicit ODP** even registers a whole address space under one key. A prefetch hint can pre-fault ranges to hide the latency.

### Step 7: dma-buf, memory owned by someone else
GPU memory and device memory have no ordinary page structure, so they can't be pinned the usual way. The **dma-buf** framework ([[dma-buf-sharing-explained|dma-buf]]) lets the owner (the *exporter*) hand out attachments to other devices. Three modes matter here:
- **Static**: the exporter keeps the buffer in place for as long as it is mapped. Devmem TCP and non-ODP RDMA NICs use this.
- **Dynamic**: the exporter may move the buffer (for example, evict it from GPU memory) after calling the importer, which must unmap promptly and re-map. This is ODP in another form, so RDMA only allows it on NICs that can take faults.
- **Pinned but revocable** (2026): fixed in place, but the exporter can cancel it permanently (after a GPU reset, or when a device is reassigned to a virtual machine). RDMA added a callback that fences the NIC off the region.

dma-buf memory isn't charged to the process's locked-memory limit. The exporter and its own controls account for it.

### Step 8: Receive areas for zero-copy networking
Zero-copy receive needs memory the NIC can write into at any moment. So both designs pin long-term *and* map once when they are set up.
- **AF_XDP's UMEM** is pinned, charged to the user's locked-memory limit, and has device addresses **pre-computed for every page** when a socket binds, so per-packet allocation is a lookup ([[af-xdp-explained|AF_XDP]]). An "unaligned" mode is usually combined with huge pages. Fixes as recent as 2026 repaired accounting leaks here.
- **io_uring zcrx areas** are either pinned user memory or a dma-buf. The whole area is mapped once and cut into buffers, which can be larger than a page if the memory is contiguous ([[zero-copy-rx-zcrx-explained|zcrx]]).
- **Devmem TCP** is the dma-buf-only sibling ([[devmem-tcp-rx-dmabuf-binding-and-token-recycling-explained|devmem RX]]).

## The picture

```text
              how the page stays put           when device addresses are made
 per-I/O pin   pin ─ I/O ─ unpin                every I/O
 io_uring buf  pin once (long-term)             every I/O          ← saves pinning only
 RDMA region   pin once (long-term)             once + NIC table   ← saves everything per op
 AF_XDP / zcrx pin once (long-term)             once at bind
 ODP           no pin; notifier before change   on fault, dropped on change
 dma-buf       exporter decides: fixed / movable-with-notice / revocable

 quota:  locked-memory limit (user memory)   vs   exporter's accounting (dma-buf)
```

## Tradeoffs

- **What it gives you:** a choice along the spectrum from "cheap setup, pay per operation" to "expensive setup, free operations", plus an unpinned option (ODP, dynamic dma-buf) for devices that can take faults.
- **What it costs / requires:** pins fragment memory (no migration or compaction, no huge-page merging), use up locked-memory quota and conflict with filesystems. Notifier-based schemes need smarter hardware and add fault latency.
- **Where it bites:** the locked-memory limit (`ulimit -l`) is the most common reason registration fails. And the kernel has no single answer to "how much memory has this process made unmovable". Different interfaces charge different counters, and dma-buf is accounted separately.

## How it got here

- **2.6 era:** RDMA regions pin with the old page-reference call, and `fork()` needs a workaround.
- **3.x–4.x:** a separate "pinned" counter; ODP on Mellanox NICs; AF_XDP's UMEM (4.18); zero-copy send (4.14).
- **5.1–5.8:** io_uring registered buffers; true pins and long-term migration rules.
- **5.12–5.19:** dma-buf memory for RDMA; the copy-on-write fix makes the `fork()` workaround unnecessary.
- **6.3–6.15:** direct I/O moves to real pins; io_uring buffer cloning and huge-page grouping; devmem TCP; zcrx areas; driver-supplied io_uring buffers.
- **2026:** one registration descriptor for "user address or dma-buf" in RDMA; revocable dma-buf pins; AF_XDP accounting fixes; multiple zcrx areas.

## Related

- Technical version: [[memory-pinning-and-registration-strategies]]
- [[zero-copy-buffer-ownership-and-return-protocols-explained|Zero-copy buffer ownership]] (who owns a buffer when)
- [[get-user-pages-and-pinning-explained|get_user_pages and pinning]], [[registered-resources-explained|io_uring registered resources]], [[memory-registration-and-ib-umem-explained|RDMA memory registration]], [[on-demand-paging-odp-explained|ODP]], [[dma-buf-sharing-explained|dma-buf]], [[dma-mapping-api-explained|DMA mapping]]
- [[af-xdp-explained|AF_XDP]], [[zero-copy-rx-zcrx-explained|io_uring zcrx]], [[p2pdma-peer-to-peer-dma-explained|P2PDMA]]
