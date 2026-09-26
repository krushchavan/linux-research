---
title: "On-Demand Paging (ODP) — Explained"
category: explained
original: "[[on-demand-paging-odp]]"
subsystem: rdma
tags: [explained, rdma, odp, hmm, mmu-notifier]
converted: 2026-09-26
---

# On-demand paging for RDMA, explained

> Plain-language companion to [[on-demand-paging-odp|the technical note]]. Same facts, fewer identifiers.

## The problem

Classic RDMA registration pins every page of a memory region for as long as the region exists. That ties up physical memory, blocks migration, compaction, NUMA balancing and swap, rules out registering huge or sparse address ranges, and doesn't work with file memory the filesystem needs to change (DAX). **On-demand paging (ODP)** removes the pin: the card's translation table is filled lazily, when the card hits a missing page, and emptied whenever memory management wants a page back. The card's table becomes a second MMU kept in step with the CPU's, the same model GPUs use.

## The idea in one paragraph

Pinned registration hands the card a **printed map**, accurate only because the city (memory) promises never to change. ODP gives it **a GPS with live updates**. The card starts with a blank map; when it needs a street it doesn't know, it asks and waits (a **network page fault**, which the kernel fills in). When the city demolishes or moves a building (reclaim, migration, unmapping), it first tells the GPS to erase that entry and waits for confirmation before touching the building. As long as every change goes "erase first, then change", the card can never write to a page the process no longer owns.

## Step by step

### Step 1: Register without pinning
The application asks for on-demand access. The card advertises what it supports: whether it can do ODP at all, whole-address-space ODP, and, per transport, which operations may fault. The kernel records the owning process, the granularity (normal or huge pages), and a per-page table of physical frames with valid, writable and DMA-mapped bits, then registers an **mmu interval notifier** over the range. **Nothing is pinned, nothing is DMA-mapped, and the locked-memory limit isn't charged.** The card's translation entries start as "not present".

### Step 2: Optional prefetch
Faults are expensive, often hundreds of microseconds, so the application can advise the driver to fault ranges in ahead of time.

### Step 3: The card hits a missing page
When a work request or an incoming packet touches a page without a translation, the card pauses that queue pair and reports a page-fault event naming the queue, the region and the address range. If the fault is on our own side, the card just stalls its send queue. If a **remote** peer's write or read hits our region, the card sends a "receiver not ready" reply, and the peer retries after its timer: that's how "wait for the page" is expressed on the wire.

### Step 4: Fault the pages in
The driver's fault handler finds the region and asks the core to map the range. The core takes a sequence snapshot, then asks the kernel's **heterogeneous-memory** helper to walk the process's page tables and fault in missing pages exactly as a CPU fault would (allocate an anonymous page, read a file page, break copy-on-write).

### Step 5: Check for races, then load the card
This is the key step. The core takes the region's mutex and checks whether an invalidation happened while pages were being faulted in. If so, the results may be stale and it starts over. If not, it DMA-maps the new pages and returns **still holding the mutex**. The driver loads the new addresses into the card, then releases the mutex and resumes the queue. Holding the mutex across the card update stops an invalidation slipping in between "computed the address" and "the card has it".

### Step 6: Invalidation: the page-out path
Before memory management changes a mapping in the range (unmapping, discarding, migration, splitting or collapsing huge pages, reclaim, copy-on-write at fork, NUMA balancing), it calls the notifier **first**. The driver takes the mutex, bumps the sequence so in-flight faults retry, removes the card's entries for the range and waits for DMA in flight to finish, DMA-unmaps the pages and marks writable ones dirty (the card may have written them), and clears the bits. Only then does memory management go ahead. If the out-of-memory reaper calls in a context that can't block and the mutex is busy, the notifier refuses.

### Step 7: Implicit ODP
A card that supports it can register the application's **entire address space** with one key pair. The kernel creates an empty anchor, and the driver creates fixed-size child regions (1 GB chunks on mlx5) when a fault lands somewhere new, destroying idle ones after invalidation. MPI libraries, UCX and PGAS runtimes use this to avoid registration caches altogether.

### Step 8: Reused for dma-buf, and in software
Dynamic dma-buf registrations are ODP in another form: the GPU driver calls the importer's invalidate hook instead of an mmu notifier, and the card must re-fault, which is why they need ODP-capable cards. **Soft-RoCE** (rxe) gained ODP too: with no hardware table, it checks the valid bits itself, faults inline and copies data under the mutex. That required moving its processing from tasklets to workqueues, because faulting may sleep.

## The picture

```text
 register(ON_DEMAND): notifier over range, card table = all "not present"
 card touches page P:
   local side → stall send queue       remote side → "not ready" NAK, peer retries
   driver → core: snapshot seq → fault P in (like a CPU fault)
          → lock mutex → seq changed? retry : DMA-map → driver loads card → unlock → resume
 mm wants to move/free P:
   notifier FIRST → lock → bump seq → zap card entry, wait DMA → unmap, mark dirty → mm proceeds
```

## Tradeoffs

- **What it gives you:** no pinning, no locked-memory limit, no blocked migration or reclaim, whole-address-space registration, and RDMA into DAX files (the supported way, since long-term pins are refused there).
- **What it costs / requires:** each fault is a round trip through firmware, event queue, workqueue, page-table walk, DMA mapping and a card-table update, tens to hundreds of microseconds against sub-microsecond RDMA. Remote-side faults push latency spikes onto *other* hosts through retries (peers typically set infinite retries). The card must be able to pause a queue mid-message; for years only mlx5 (ConnectX-4 and later) could, and research (NP-RDMA, 2023) explores emulating it on ordinary cards.
- **Where it bites:** the original 2014 code had its own interval tree and fault path with subtle races; moving onto shared kernel infrastructure (interval notifiers in 5.5, then the shared fault helper) means ODP, GPU memory mirroring and others now share one well-tested sequence-count protocol.

## How it got here

- **3.19 (2014):** Haggai Eran (Mellanox) merged ODP for mlx5, with sequence counters to resolve fault/invalidate races.
- **4.x–5.0:** implicit ODP (Artemy Kovalyov), then prefetch advice.
- **5.5:** mmu interval notifiers, created largely for ODP (Jason Gunthorpe), after Jérôme Glisse argued ODP duplicated the heterogeneous-memory code.
- **~5.10:** ODP switched to the shared page-fault helper (Yishai Hadas). **5.12:** dynamic dma-buf builds on it.
- **6.2–6.x:** ODP for rxe (Daisuke Matsuda, Fujitsu), later with atomics, flush and prefetch.
- **6.16+:** mapping through the DMA IOVA API (Leon Romanovsky), cutting per-page mapping cost with an IOMMU.

## Related

- Technical version: [[on-demand-paging-odp]]
- [[memory-registration-and-ib-umem-explained|Memory registration]], [[rdma-explained|RDMA subsystem]], [[dma-buf-sharing-explained|dma-buf sharing]], [[soft-rdma-rxe-and-siw-explained|rxe and siw]]
- [[get-user-pages-and-pinning-explained|Page pinning]], [[page-fault-handler-explained|Page fault handler]]
