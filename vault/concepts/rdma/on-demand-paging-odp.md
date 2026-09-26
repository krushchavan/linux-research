---
title: "On-Demand Paging (ODP)"
category: concept
tags: [rdma, odp, hmm, mmu-notifier, page-fault, pinning]
subsystem: rdma
kernel_version: "3.19 (mlx5 explicit ODP); 4.x implicit ODP; 5.5 mmu_interval_notifier; 6.2+ rxe ODP"
researched: 2026-09-26
status: complete
sources:
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/umem_odp.c
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_umem_odp.h
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/sw/rxe/rxe_odp.c
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_verbs.h
  - https://lwn.net/Articles/914607/
  - https://lkml.iu.edu/hypermail/linux/kernel/1409.0/02130.html
  - https://linux-rdma.vger.kernel.narkive.com/xrVJP9c7/rfc-00-20-on-demand-paging
  - https://patchwork.kernel.org/project/linux-rdma/patch/20190129165839.4127-2-jglisse@redhat.com/
  - https://arxiv.org/pdf/2310.11062
  - https://lwn.net/Articles/836484/
---

# On-Demand Paging (ODP)

## Purpose

Classic memory registration pins every page of an MR for as long as the MR exists (see [[memory-registration-and-ib-umem]]). That costs physical memory, blocks migration, compaction, NUMA balancing and swap, forbids registering sparse or huge address ranges, and doesn't work with file-backed memory the filesystem needs to manipulate (DAX). **On-Demand Paging** removes the pin. The NIC's translation table is filled lazily, when the NIC takes a *network page fault*, and emptied whenever the kernel's mm wants a page back. The NIC's page table becomes a secondary MMU kept coherent with the CPU's, the same model as a GPU under HMM.

## Mental Model

Pinned registration is a **printed map** handed to the NIC: accurate only because the city (memory) promises never to change. ODP is **a GPS with live updates**. The NIC starts with a blank map. When it needs a street it doesn't have, it asks and waits (network page fault → kernel fills the entry). When the city demolishes or moves a building (reclaim, migration, munmap), the city first tells the GPS to erase that entry (mmu-notifier invalidation) and waits for confirmation before touching the building. As long as every change goes through "erase first, then change", the NIC can never write to a page the process no longer owns.

## How It Works

**Registration.** An application passes `IB_ACCESS_ON_DEMAND` to `ibv_reg_mr()`. The capability is advertised in `ib_device_attr.odp_caps`: `general_caps` (`IB_ODP_SUPPORT`, `IB_ODP_SUPPORT_IMPLICIT`) plus a per-transport bitmask of which opcodes may fault (`IB_ODP_SUPPORT_SEND/RECV/WRITE/READ/ATOMIC/SRQ_RECV/FLUSH/ATOMIC_WRITE` for RC, UC, UD and XRC). The ordinary `__ib_umem_get_va()` path refuses the flag, and the driver calls `ib_umem_odp_get(device, addr, size, access, ops)` instead. That function:
- allocates `struct ib_umem_odp`, which embeds a normal `ib_umem` (so drivers keep one pointer type)
- records the owning `tgid` and mm
- sets `page_shift` (the ODP granularity: PAGE_SIZE, or huge-page size when the VMA is hugetlb)
- allocates a `struct hmm_dma_map`, a per-page array of PFNs plus flag bits (`HMM_PFN_VALID`, `HMM_PFN_WRITE`, `HMM_PFN_DMA_MAPPED`) that can also hold a DMA IOVA state
- registers an **`mmu_interval_notifier`** over `[addr, addr+size)` with the driver's `invalidate` callback.

**Nothing is pinned, nothing is DMA-mapped, and `RLIMIT_MEMLOCK` isn't charged.** The driver creates the MR with its translation entries marked *not present*.

**Prefetch (optional).** Because faults are expensive, often hundreds of microseconds, userspace can call `ibv_advise_mr(IBV_ADVISE_MR_ADVICE_PREFETCH[_WRITE|_NO_FAULT])`. That becomes `advise_mr` in the driver, which faults ranges in ahead of time from a workqueue.

**The network page fault (fast path → slow path).** When a WQE or an incoming packet references an MR page whose NIC translation isn't present:
1. **Hardware** (mlx5) suspends that QP's processing and raises a page-fault event on an event queue, describing the QP, the MR (key) and the address range. For *requester* faults (local SGE) the NIC stalls its own send queue. For *responder* faults (a remote peer's RDMA WRITE or READ hits our ODP MR) the NIC sends an **RNR NAK** to the peer, which retries after the RNR timer. That is how "wait for the page" is expressed on the wire.
2. **The driver's fault handler** (mlx5: `mlx5_ib_eqe_pf_action()` → work item → `pagefault_single_data_segment()`) resolves the key to the MR and calls **`ib_umem_odp_map_dma_and_lock(umem_odp, va, bcnt, access_mask, fault=true)`**.
3. **The core** takes a sequence count with `mmu_interval_read_begin()` and calls **`hmm_range_fault()`** on the owning mm with `HMM_PFN_REQ_FAULT` (plus `REQ_WRITE` if the access needs it). HMM walks the CPU page tables and runs `handle_mm_fault()` for missing pages, doing exactly what a CPU fault would do (allocate anonymous page, read file page, break COW). It returns PFNs.
4. The core takes `umem_mutex`, then checks **`mmu_interval_read_retry()`**. If an invalidation ran while HMM was faulting, the PFNs may be stale and the whole thing loops. Otherwise it DMA-maps each newly valid page (`hmm_dma_map_pfn()`), records `HMM_PFN_DMA_MAPPED`, and returns **with `umem_mutex` held**.
5. **The driver** writes the new DMA addresses into the NIC's MTT (for mlx5, by posting a UMR WQE), drops `umem_mutex`, and resumes the QP. Holding the mutex across the NIC update is essential: it stops an invalidation from slipping in between "computed DMA address" and "NIC loaded it".

**Invalidation (the page-out path).** When mm changes a PTE in the range (munmap, `madvise(DONTNEED)`, migration, THP split or collapse, reclaim, COW on fork, NUMA balancing), it calls the interval notifier's `invalidate(mni, range, cur_seq)` **before** freeing or moving the page. The driver:
- takes `umem_mutex`, sets the notifier sequence (`mmu_interval_set_seq`) so in-flight faults will retry
- zaps the NIC translation entries for the range (mlx5: UMR to mark entries not present, then a fence so in-flight DMA completes)
- calls `ib_umem_odp_unmap_dma_pages()`, which DMA-unmaps and, for pages that were writable, calls `set_page_dirty()` because the NIC may have written them
- clears the PFN flags.

Only after this returns does mm proceed. That ordering is the whole correctness argument: the NIC can't hold a DMA address for a page mm has taken back. Invalidation for a non-blockable range (from the OOM reaper) returns `false` if the mutex can't be taken.

**Implicit ODP.** With `IB_ODP_SUPPORT_IMPLICIT`, an application can register `addr=0, length=SIZE_MAX`, i.e. *its entire address space*, with a single lkey/rkey. `ib_umem_odp_alloc_implicit()` creates a zero-length anchor (`is_implicit_odp`) that can't itself be DMA-mapped. The driver creates **child MRs** of fixed size (mlx5: 1 GiB chunks) on demand with `ib_umem_odp_alloc_child()` when a fault lands in a region with no child yet, and destroys idle children after invalidation. This is how MPI libraries, UCX and PGAS runtimes avoid registration caches entirely.

**dma-buf reuse of the same machinery.** Dynamic dma-buf MRs (5.12) are ODP in another form. The exporter (a GPU driver) calls the importer's invalidate op instead of an mmu notifier, and the NIC must stop using the old addresses and re-fault. That's why dynamic dma-buf MRs require an ODP-capable NIC (see [[memory-registration-and-ib-umem]], [[dma-buf-sharing]]).

**Software ODP in rxe.** In 2022 Daisuke Matsuda (Fujitsu) posted ODP for Soft-RoCE, motivated by RDMA into persistent memory while filesystem metadata changes. rxe has no hardware MTT: its requester, responder and completer "look up" pages in software. So it checks `HMM_PFN_VALID` itself (`rxe_check_pagefault()`), calls `ib_umem_odp_map_dma_and_lock()` inline, and copies data with the mutex held. This required converting rxe's tasklets to workqueues, because faulting can sleep. rxe ODP later gained atomic, flush and atomic-write support and prefetch through `advise_mr`.

## Key Data Structures

**`struct ib_umem_odp`** (`include/rdma/ib_umem_odp.h`)
- `umem` — embedded base `ib_umem` (`is_odp = 1`)
- `notifier` — `mmu_interval_notifier` over the MR range
- `tgid` — owning process, used for the mm lookup during faults
- `map` — `struct hmm_dma_map`: PFN list with VALID/WRITE/DMA_MAPPED bits and DMA addresses
- `umem_mutex` — serializes fault-in against invalidation; held across the driver's NIC table update
- `npages`, `page_shift` — ODP granularity
- `is_implicit_odp` — whole-address-space anchor
- `private` — driver back-pointer (e.g. the mlx5 MR)

**`struct ib_odp_caps`** (`include/rdma/ib_verbs.h`) — `general_caps` plus `per_transport_caps.{rc,uc,ud,xrc}_odp_caps` bitmasks.

## Key Functions / Entry Points

- **`ib_umem_odp_get()`** (`umem_odp.c`) — explicit ODP registration; called from driver `reg_user_mr`
- **`ib_umem_odp_alloc_implicit()` / `ib_umem_odp_alloc_child()`** — implicit ODP anchor and on-demand children
- **`ib_umem_odp_map_dma_and_lock()`** — HMM fault plus DMA map; returns holding `umem_mutex`
- **`ib_umem_odp_unmap_dma_pages()`** — invalidate path: DMA-unmap and dirty pages
- **`ib_umem_odp_release()`** — unregister notifier, free map
- **`mlx5_ib_invalidate_range()` / `mlx5_ib_eqe_pf_action()`** (`drivers/infiniband/hw/mlx5/odp.c`) — reference hardware implementation
- **`rxe_odp_mr_init_user()` / `rxe_odp_mr_copy()` / `rxe_ib_invalidate_range()`** (`sw/rxe/rxe_odp.c`) — software implementation
- **`ib_advise_mr()` → driver `advise_mr`** — prefetch

## Important Flags & Config Options

- `CONFIG_INFINIBAND_ON_DEMAND_PAGING` — depends on `CONFIG_MMU_NOTIFIER` and `CONFIG_HMM_MIRROR`
- `IB_ACCESS_ON_DEMAND` — request ODP at registration
- `IBV_ADVISE_MR_ADVICE_PREFETCH`, `_PREFETCH_WRITE`, `_PREFETCH_NO_FAULT` — prefetch hints
- `rnr_retry` / `min_rnr_timer` on the *peer's* QP — how responder-side faults are tolerated; `rnr_retry=7` (infinite) is typical with ODP
- mlx5 `odp` counters in `rdma statistic` (page faults, invalidations, prefetches)

## Interactions with Other Subsystems

- **↑ Userspace**: `ibv_reg_mr(IBV_ACCESS_ON_DEMAND)`, `ibv_reg_mr(pd, NULL, SIZE_MAX, ...)` for implicit, `ibv_advise_mr()`, `ibv_query_device_ex()` for `odp_caps`
- **→ mm / HMM**: `hmm_range_fault()` to populate; `mmu_interval_notifier` for invalidation. This is the same infrastructure used by GPU drivers (amdgpu, nouveau) and vfio SVA
- **→ DMA**: `hmm_dma_map_*` helpers (DMA IOVA-API based) map faulted pages
- **→ filesystems**: ODP is the supported way to RDMA into FS-DAX files, since long-term pins are refused there
- **← dma-buf**: dynamic importers reuse ODP invalidate and refault semantics

## Design Decisions & Tradeoffs

- **Correctness via "invalidate before change".** No page is ever freed or moved while the NIC has its address, and there are no pins, no `RLIMIT_MEMLOCK` and no migration blockers. The cost is that every fault is a round trip through firmware, event queue, workqueue, HMM, DMA map and a UMR update: tens to hundreds of microseconds against sub-microsecond RDMA. Remote-side faults stall a peer via RNR NAK retries, so ODP pushes latency spikes onto *other* hosts.
- **Hardware support required.** The NIC must be able to suspend a QP mid-message and resume it. For years only mlx5 (ConnectX-4+) could. The NP-RDMA paper (2023) explores emulating unpinned RDMA on commodity NICs instead.
- **Prefetch and implicit ODP as mitigations.** Prefetch hides fault latency for known working sets. Implicit ODP trades per-MR setup cost for a one-time registration and lazy child MRs.
- **Moving from bespoke notifier code to HMM.** The original 2014 code had its own interval tree over `mmu_notifier` ranges and its own `get_user_pages()` fault path, with subtle races. Jérôme Glisse's 2019 RFC and Jason Gunthorpe's `mmu_interval_notifier` (5.5) moved ODP onto shared mm infrastructure, and later `hmm_range_fault()` replaced GUP. The result is that ODP, GPU SVM and other mirrors share one well-tested sequence-count protocol.

## How It Has Evolved

- **2014 (3.19)** — Haggai Eran (Mellanox) merges ODP for mlx5: explicit ODP, RC transport, network page faults via event queue, custom interval tree over mmu notifiers
- **4.x** — implicit ODP (Artemy Kovalyov, 4.12-ish); prefetch via `advise_mr` (5.0)
- **5.5** — `mmu_interval_notifier` introduced largely *for* RDMA ODP (Jason Gunthorpe); the per-umem notifier replaces the per-mm tree
- **5.10-ish** — ODP converted to `hmm_range_fault()` (Yishai Hadas), dropping its GUP-based fault path
- **5.12** — dma-buf dynamic MRs piggyback on ODP invalidation
- **6.2–6.x** — ODP for rxe (Daisuke Matsuda, Fujitsu); later extended with atomics, flush, atomic write and prefetch
- **6.16+** — ODP maps through `struct hmm_dma_map` / DMA IOVA API (Leon Romanovsky), cutting per-page DMA mapping costs with IOMMU

## Further Reading

- LWN — [On-Demand Paging on SoftRoCE](https://lwn.net/Articles/914607/) (2022)
- LKML — [On demand paging v1 cover letter](https://lkml.iu.edu/hypermail/linux/kernel/1409.0/02130.html) (Haggai Eran, 2014)
- narkive — [RFC 00/20 On demand paging](https://linux-rdma.vger.kernel.narkive.com/xrVJP9c7/rfc-00-20-on-demand-paging)
- patchwork — [RDMA/odp: convert to use HMM for ODP](https://patchwork.kernel.org/project/linux-rdma/patch/20190129165839.4127-2-jglisse@redhat.com/)
- Paper — [NP-RDMA: Using Commodity RDMA without Pinning Memory](https://arxiv.org/pdf/2310.11062)
- Related: [[memory-registration-and-ib-umem]], [[get-user-pages-and-pinning]], [[page-fault-handler]], [[dma-buf-sharing]]

## LKML Highlights

- **"On demand paging" v1 (Haggai Eran, Sept 2014)** — introduced `ib_umem_odp`, notifier-driven invalidation and mlx5 network page faults. The discussion centred on races between fault-in and invalidation, resolved with notifier sequence counters, the ancestor of today's `mmu_interval_read_retry()` pattern.
- **`<20190129165839.4127-2-jglisse@redhat.com>`** — Jérôme Glisse, "RDMA/odp: convert to use HMM for ODP". It argued that ODP's private mirroring code duplicated HMM and got corner cases wrong. That set up the 5.5 `mmu_interval_notifier` rework.
- **`<cover.1668157436.git.matsuda-daisuke@fujitsu.com>`** — ODP on SoftRoCE. It showed ODP working without hardware faults and converted rxe's tasklets to workqueues so page faults can sleep.
