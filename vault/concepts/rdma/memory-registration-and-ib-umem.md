---
title: "Memory Registration and ib_umem"
category: concept
tags: [rdma, memory-registration, pinning, gup, dma-buf, mm]
subsystem: rdma
kernel_version: "2.6.11 (FOLL_LONGTERM pinning: 5.2+; dma-buf umem: 5.12)"
researched: 2026-09-26
status: complete
sources:
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/umem.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/umem_dmabuf.c
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_umem.h
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_verbs.h
  - https://github.com/torvalds/linux/blob/master/include/uapi/rdma/ib_user_ioctl_verbs.h
  - https://www.kernel.org/doc/html/latest/infiniband/user_verbs.html
  - https://lwn.net/Articles/836484/
  - https://lwn.net/Articles/1078512/
  - https://lwn.net/Articles/795971/
  - https://lwn.net/Articles/1046788/
---

# Memory Registration and ib_umem

## Purpose

An RDMA NIC reads and writes application memory by itself, often on behalf of a *remote* peer, with no CPU involved. To do that it needs its own translation table from the addresses applications use to bus (DMA) addresses, plus an access-control check on every access. **Memory registration** builds that translation and permission record, the **Memory Region (MR)**, and returns two keys: an `lkey` for local work requests and an `rkey` that can be handed to peers. `ib_umem` is the core helper that turns a user virtual range, or a dma-buf, into a pinned, DMA-mapped scatterlist a driver can load into the NIC. Without registration, a NIC could either DMA anywhere (no isolation) or would need the kernel to translate every request (no bypass).

## Mental Model

Registration is **issuing a keycard for a storage unit**. You tell the facility (the kernel) which units you want (a VA range) and what the card may do (local write, remote read/write/atomic). The facility bolts those units in place (pins the pages, so they can't be moved or swapped), writes their physical locations into the loading robot's map (the NIC's MTT, memory translation table), and gives you a card number (lkey/rkey). Anyone holding the rkey can direct the robot to that unit and only that unit, with only the rights you granted. The bolting is the problem: as long as the card is valid, the facility can't rearrange its space. That tension with memory management drives the ODP, dma-buf and pinning-API history.

## How It Works

**Entry.** A userspace `ibv_reg_mr(pd, addr, len, access)` becomes the uverbs `MR_REG` (or legacy `REG_MR`) command. The core validates `access`: remote write or atomic requires local write, because the NIC will modify the pages. It then calls the driver's `reg_user_mr(pd, start, length, iova, access, udata)`. The driver calls back into the core to acquire the memory, with `ib_umem_get_va(device, addr, size, access)` (or the 2026 unified form, `ib_umem_get_desc()`, which takes a `struct ib_uverbs_buffer_desc` naming either a VA range or a dma-buf fd and offset, so every verb that consumes memory, including CQ and QP buffers, can accept GPU memory as well as host memory).

**Pinning a VA range (`__ib_umem_get_va`, `umem.c`).** The steps are ordered deliberately:
1. **Reject impossible cases**: address or length overflow; `IB_ACCESS_ON_DEMAND` (ODP takes its own path); CoCo guests with `cc_dma_bounce` (pinned registered memory can't be bounce-buffered).
2. **Permission and accounting**: `can_do_mlock()` must allow locking at all. The page count is atomically added to `mm->pinned_vm` and compared against `RLIMIT_MEMLOCK` unless the caller has `CAP_IPC_LOCK`. As the kernel docs warn, pages pinned several times are counted each time, so `pinned_vm` can overestimate. This is the most common "why does ibv_reg_mr fail with ENOMEM" answer: `ulimit -l`.
3. **Pin**: in chunks of one page of `struct page *` pointers, call `pin_user_pages_fast(addr, n, FOLL_LONGTERM | [FOLL_WRITE], pages)`. `FOLL_PIN` (implied by `pin_user_pages`) marks the folio pinned, distinct from an ordinary reference, so mm code (writeback, migration, fork COW) can tell "DMA may be in flight here" from a transient reference. `FOLL_LONGTERM` states that the pin lasts indefinitely. mm therefore first **migrates** the pages out of `ZONE_MOVABLE` and CMA areas (which promise movability), and refuses FS-DAX file pages that the filesystem may need to truncate. See [[get-user-pages-and-pinning]].
4. **Build the scatterlist**: `sg_alloc_append_table_from_pages()` merges physically contiguous pages into large SG entries, up to `ib_dma_max_seg_size()`. Huge pages and THP collapse into very few entries.
5. **DMA-map**: `ib_dma_map_sgtable_attrs(..., DMA_BIDIRECTIONAL, attrs)` goes through the [[dma-mapping-api]] and the IOMMU. The attributes include `DMA_ATTR_REQUIRE_COHERENT`, plus `DMA_ATTR_WEAK_ORDERING` when the user passed `IB_ACCESS_RELAXED_ORDERING`, which lets the PCIe root complex reorder the NIC's writes for bandwidth on some platforms.

**Choosing the NIC page size.** NIC translation tables are expensive on-chip resources, so the driver calls `ib_umem_find_best_pgsz(umem, pgsz_bitmap, iova)` to get the largest page size the hardware supports (e.g. 4K…2G for mlx5) such that every DMA block boundary lines up with the IOVA. A 1 GiB hugetlbfs buffer can then be described by one entry instead of 262,144. The driver iterates blocks with `rdma_umem_for_each_dma_block()` and writes them into the MTT through a firmware command or UMR WQE.

**The IOVA.** The MR's `iova` (the address peers use together with the rkey) need not equal the user VA. `ibv_reg_mr_iova()` lets an application register at a chosen IOVA, which is useful for zero-based offsets in shared-memory protocols.

**Release.** `ib_umem_release()` DMA-unmaps, calls `unpin_user_pages_dirty_lock()` (marking pages dirty if writable, since the NIC may have written them), subtracts from `pinned_vm`, and drops the mm reference. That is `mmgrab`, not `mmget`: the umem keeps the `mm_struct` alive for accounting but doesn't prevent address-space teardown.

**Registering memory without struct pages: dma-buf.** GPU VRAM, accelerator HBM and device BARs have no `struct page`, so GUP can't pin them. Since 5.12 (Jianxin Xiong, Intel), `ibv_reg_dmabuf_mr(pd, offset, len, iova, fd, access)` reaches the driver's `reg_user_mr_dmabuf`, which calls one of:
- **`ib_umem_dmabuf_get()`**: *dynamic* attach (`dma_buf_dynamic_attach` with `allow_peer2peer = true`). The exporter may move the buffer, for example evict VRAM to system RAM, and tells the importer through the attachment's invalidate callback. The NIC must then be able to drop and re-fault mappings, so this path is **ODP-only** in practice (mlx5). `ib_umem_dmabuf_map_pages()` maps under the reservation lock and waits on `dma_resv` fences so the data has finished moving before the NIC sees the new address.
- **`ib_umem_dmabuf_get_pinned()`**: calls `dma_buf_pin()` so the exporter keeps the memory in place, for NICs without ODP (bnxt_re, irdma, efa, erdma ...).
- **`ib_umem_dmabuf_get_pinned_revocable_and_lock()`** (2026): pinned, but the exporter can still *revoke* (on GPU reset or VFIO device teardown). The driver registers a `pinned_revoke` callback that fences its hardware off the MR, and the umem is marked `revoked`.

**Kernel ULP registration: fast registration.** Kernel consumers already hold DMA-mappable pages (bio pages, NFS buffers), so they don't use umem. Instead they:
1. pre-allocate MRs with `ib_alloc_mr(pd, IB_MR_TYPE_MEM_REG, max_sg)`
2. map an SG list into one with `ib_map_mr_sg()`
3. post an `IB_WR_REG_MR` work request on the QP, so registration happens *in line* with I/O and costs no syscall or firmware command
4. invalidate it with `IB_WR_LOCAL_INV` or with the peer's `SEND_WITH_INV` when done.

`ib_mr_pool` (and, from 2026, FRMR pools) keeps per-QP stocks of these. `IB_MR_TYPE_INTEGRITY` MRs add T10-PI signature offload for NVMe-oF and iSER. `rdma_rw` chooses between plain SGEs and FRMRs automatically.

**Windows and the global rkey.** *Memory Windows* (`IB_ACCESS_MW_BIND`) let a process grant a narrower, revocable remote window into an existing MR without re-registering. `ib_alloc_pd(pd, IB_PD_UNSAFE_GLOBAL_RKEY)` creates an rkey that covers **all** of physical memory for legacy ULPs. It is named "unsafe" on purpose and prints a warning.

**The fork problem (historical).** Before 5.9–5.12, a process that registered memory and then `fork()`ed could have its pinned pages replaced by COW in the *parent*, so the NIC kept writing into pages the parent no longer mapped. rdma-core's `ibv_fork_init()` papered over this with `MADV_DONTFORK`. mm now copies pinned anonymous pages early at fork time, and `ibv_is_fork_initialized()` reports `IBV_FORK_UNNEEDED` on modern kernels.

## Key Data Structures

**`struct ib_umem`** (`include/rdma/ib_umem.h`)
- `ibdev` — device whose DMA mapping this is
- `owning_mm` — mm charged in `pinned_vm`
- `address`, `length`, `iova` — user VA, size, device-visible IOVA
- `writable`, `is_odp`, `is_dmabuf` — flavour flags
- `dma_attrs` — DMA mapping attributes
- `sgt_append` — the DMA-mapped scatterlist

**`struct ib_umem_dmabuf`** — embeds `ib_umem`; adds `attach`, `sgt`, first/last SG trimming for sub-buffer offsets, `pinned`, `revoked`, `pinned_revoke`/`private`.

**`struct ib_mr`** (`include/rdma/ib_verbs.h`) — `lkey`, `rkey`, `iova`, `length`, `page_size`, `type` (`IB_MR_TYPE_USER`, `MEM_REG`, `SG_GAPS`, `DMA`, `DM`, `INTEGRITY`), `need_inval`, `pd` (can change with rereg), `frmr` pool linkage.

**`struct ib_uverbs_buffer_desc`** (`include/uapi/rdma/ib_user_ioctl_verbs.h`, 2026) — `{type: DMABUF|VA, fd, flags, optional_flags, addr, length}`: the unified "memory argument" for any uverbs method.

## Key Functions / Entry Points

- **`ib_umem_get_va()` / `ib_umem_get_desc()`** (`umem.c`) — pin and map user memory; called from drivers' `reg_user_mr` and from CQ/QP buffer setup
- **`ib_umem_find_best_pgsz()`** (`umem.c`) — pick the largest usable NIC page size
- **`rdma_umem_for_each_dma_block()`** (`ib_umem.h`) — iterate blocks for MTT programming
- **`ib_umem_release()`** (`umem.c`) — unmap, unpin (dirty), unaccount
- **`ib_umem_dmabuf_get()` / `_get_pinned()` / `_get_pinned_revocable_and_lock()`** (`umem_dmabuf.c`) — dma-buf-backed umems
- **`ib_alloc_mr()` / `ib_map_mr_sg()` / `IB_WR_REG_MR`** (`verbs.c`) — kernel fast registration
- **`ib_mr_pool_init()` / `ib_mr_pool_get()`** (`mr_pool.c`) — per-QP MR pools

## Important Flags & Config Options

- `IB_ACCESS_LOCAL_WRITE`, `IB_ACCESS_REMOTE_READ`, `IB_ACCESS_REMOTE_WRITE`, `IB_ACCESS_REMOTE_ATOMIC` — rights granted to lkey/rkey holders
- `IB_ACCESS_ON_DEMAND` — use ODP instead of pinning ([[on-demand-paging-odp]])
- `IB_ACCESS_RELAXED_ORDERING` — PCIe relaxed ordering for NIC writes (an optional flag; ignored if unsupported)
- `IB_ACCESS_HUGETLB` — legacy hint; the core detects contiguity itself now
- `IB_ACCESS_FLUSH_GLOBAL` / `IB_ACCESS_FLUSH_PERSISTENT` — allow the RDMA FLUSH operation (persistent memory, 6.2)
- `RLIMIT_MEMLOCK` / `CAP_IPC_LOCK` — limit and exemption for pinned pages
- `CONFIG_INFINIBAND_USER_MEM`

## Interactions with Other Subsystems

- **↑ Userspace**: `ibv_reg_mr`, `ibv_reg_mr_iova`, `ibv_reg_dmabuf_mr`, `ibv_rereg_mr`, `ibv_dereg_mr`, `ibv_alloc_mw`/`ibv_bind_mw`
- **→ mm**: `pin_user_pages_fast(FOLL_LONGTERM)`, `pinned_vm`, `can_do_mlock`; migration out of movable zones; DAX refusal ([[get-user-pages-and-pinning]])
- **→ DMA/IOMMU**: `ib_dma_map_sgtable_attrs` ([[dma-mapping-api]]); P2P mappings for dma-buf
- **→ dma-buf**: importer with dynamic or pinned attach; `dma_resv` fences for move synchronization
- **← ODP**: shares `ib_umem` as its base type ([[on-demand-paging-odp]])
- **Compared with io_uring**: io_uring's registered buffers (`IORING_REGISTER_BUFFERS`) are the same idea (long-term pin, pre-built `bio_vec` table, charged to `RLIMIT_MEMLOCK`). The purpose is to skip per-I/O GUP, not to give a device an independent translation. See [[registered-resources]].

## Design Decisions & Tradeoffs

- **Pin-for-lifetime.** It is simple and allows line-rate translation with no faults, but it holds memory hostage from reclaim, compaction, NUMA balancing, memory hot-remove and filesystem truncation. The years-long "RDMA vs DAX truncate" argument (LWN 795971) ended with `FOLL_LONGTERM` being *refused* on FS-DAX instead of being given a lease-break protocol.
- **Accounting against `RLIMIT_MEMLOCK` in `pinned_vm`.** A separate counter from `locked_vm` (mlock), introduced after it became clear pins and mlocks overlap. The double-counting of repeatedly pinned pages is accepted as a safe overestimate.
- **Driver-chosen page size.** Large pages dramatically reduce NIC translation cache misses. The core gives drivers the tool (`find_best_pgsz`) rather than fixing a size.
- **Dynamic vs pinned dma-buf.** Dynamic attach respects GPU memory management (eviction) but needs fault-capable NICs. Pinned attach works on every NIC but can block GPU memory reclaim. Revocable-pinned (2026) is the compromise: the exporter can pull the plug and the NIC fences off.
- **Fast registration in the send queue.** For kernel ULPs this puts registration on the data path at WR cost, avoiding firmware round-trips per I/O.

## How It Has Evolved

- **2.6.11** — `ib_umem_get()` with `get_user_pages()` and `locked_vm` accounting
- **3.x** — `pinned_vm` split from `locked_vm`
- **3.19** — ODP umems
- **5.2–5.6** — conversion to `FOLL_LONGTERM` (5.2) and then `pin_user_pages()`/`FOLL_PIN` (5.6, John Hubbard), making RDMA the reference user of the new pin API
- **5.9–5.12** — early COW of pinned pages at fork; `ibv_fork_init` no longer needed
- **5.12** — dma-buf MRs (dynamic attach)
- **5.15-ish** — pinned dma-buf attach for non-ODP NICs
- **6.2** — FLUSH access flags for persistent-memory RDMA
- **2026** — revocable pinned dma-buf, unified buffer descriptors (`ib_umem_get_desc`), FRMR pools, erdma dma-buf MRs, dma-buf *export* from RDMA devices

## Further Reading

- LWN — [RDMA: Add dma-buf support](https://lwn.net/Articles/836484/)
- LWN — [RDMA/erdma: Add DMA-BUF memory registration](https://lwn.net/Articles/1078512/) (2026)
- LWN — [RDMA/FS DAX truncate proposal](https://lwn.net/Articles/795971/)
- LWN — [RDMA/core: Introduce FRMR pools infrastructure](https://lwn.net/Articles/1046788/)
- kernel.org — [Userspace verbs access](https://www.kernel.org/doc/html/latest/infiniband/user_verbs.html) (pinning and `RLIMIT_MEMLOCK`)
- Related: [[get-user-pages-and-pinning]], [[on-demand-paging-odp]], [[dma-buf-sharing]], [[dma-mapping-api]], [[registered-resources]]

## LKML Highlights

- **`<1604616489-69267-1-git-send-email-jianxin.xiong@intel.com>`** — RDMA dma-buf support. Settled on dynamic attach plus ODP-style invalidation, and waiting on `dma_resv` fences before reprogramming the NIC, so the NIC never sees a half-moved buffer.
- **RDMA/FS-DAX truncate (Ira Weiny, 2019; LWN 795971)** — proposed file "layout leases" so filesystems could revoke RDMA pins. It was rejected as too complex. The outcome was that long-term pins of DAX pages fail with `-EOPNOTSUPP`, and ODP is the supported way to RDMA into DAX.
- **pin_user_pages / FOLL_PIN (John Hubbard, 2019–20)** — used RDMA umem as a primary motivating case: mm needed to distinguish DMA pins from ordinary page references to handle writeback of pinned file pages correctly.
