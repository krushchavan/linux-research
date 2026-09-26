---
title: "RDMA R/W API (rdma_rw)"
category: concept
tags: [rdma, rdma-rw, storage-targets, memory-registration, dma-iova, nvme-of]
subsystem: rdma
kernel_version: "4.7 (bvec + DMA IOVA paths: 6.x/2026)"
researched: 2026-09-26
status: complete
sources:
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/rw.c
  - https://github.com/torvalds/linux/blob/master/include/rdma/rw.h
  - https://github.com/torvalds/linux/blob/master/drivers/nvme/target/rdma.c
  - https://github.com/torvalds/linux/blob/master/net/sunrpc/xprtrdma/svc_rdma_rw.c
---

# RDMA R/W API (rdma_rw)

## Purpose

Every RDMA *storage target* (NVMe-oF target, iSER target, SRP target, NFS/RDMA server, ksmbd's SMB Direct) does the same thing: the client (initiator) sends a command naming its buffers as `{remote address, rkey, length}`, and the target moves data with **RDMA WRITE** (for client reads) or **RDMA READ** (for client writes) between those remote buffers and local pages. Doing that correctly means respecting device limits (max SGEs per WR, which differ for READ), transport quirks (iWARP requires the local *sink* of an RDMA READ to be a registered MR), T10-PI signature offload, and MR pool management. Before `rdma_rw` (Christoph Hellwig, 2016, 4.7) every target reimplemented this with subtly different bugs. `rdma_rw` is the shared engine: hand it local memory plus a remote key, get back a ready-to-post chain of work requests.

## Mental Model

`rdma_rw` is a **freight broker** for one transfer. You give it the cargo (a local scatterlist or bio_vec array), the destination's dock address (remote addr + rkey) and the direction. It looks at the carrier's rules (device SGE limits, iWARP READ rule, IOMMU availability) and picks the cheapest compliant plan: one truck (single WR), a convoy (several chained WRs, each within the SGE limit), a single truck after first repacking the cargo into one contiguous virtual container (DMA IOVA mapping), or a registered container with its own key (fast-registration MR, the heaviest option). It hands back the paperwork (a WR chain) that you post, and afterwards you ask it to clean up.

## How It Works

**Sizing the QP.** When the ULP creates its QP it calls `rdma_rw_init_qp(dev, &init_attr)` with `init_attr.cap.max_rdma_ctxs` set. The helper enlarges `max_send_wr` to cover the worst case of registration + RDMA + invalidate WRs per context (using `rdma_rw_mr_factor()`). After QP creation, `rdma_rw_init_mrs()` pre-populates the QP's MR pools (`qp->rdma_mrs`, and `qp->sig_mrs` for T10-PI) through `ib_mr_pool_init()`, so no allocation happens per I/O.

**Choosing a strategy (`rdma_rw_ctx_init`).** Given a scatterlist, the function DMA-maps it (`ib_dma_map_sgtable_attrs`), skips to `sg_offset`, and decides:
1. **MR registration (`RDMA_RW_MR`)** if `rdma_rw_io_needs_mr()` says so. That is: iWARP and an RDMA READ (the spec requires the READ sink to be described by an rkey/STag with remote-write rights), or the device advertises `attrs.max_sgl_rd` (its optimal READ SGE count) and this I/O has more entries than that, or the `force_mr` debug parameter is set. `rdma_rw_init_mr_wrs()` takes MRs from the QP pool, maps up to the device's fast-registration page-list length per MR (`rdma_rw_fr_page_list_len()`), and builds for each chunk: an optional `IB_WR_LOCAL_INV` (if the MR's previous key is still valid), an `IB_WR_REG_MR` (with `ib_inc_rkey()` so a stale key can't be reused), and the RDMA READ/WRITE using the MR's lkey. On iWARP, a READ uses `IB_WR_RDMA_READ_WITH_INV` so the MR invalidates itself when the read completes. If the pool is exhausted (`-EAGAIN`) and registration was only an optimization, it falls back to plain SGEs.
2. **Multiple SGE WRs (`RDMA_RW_MULTI_WR`)**: `rdma_rw_init_map_wrs()` splits the SG list into WRs of at most `qp->max_write_sge` or `max_read_sge` entries each, advancing `remote_addr` per WR, and chains them.
3. **Single WR (`RDMA_RW_SINGLE_WR`)** for a one-entry list: no allocation, the SGE and WR live inside the context.

**The bio_vec and IOVA paths (recent).** Block-layer targets hold `bio_vec`s rather than scatterlists. `rdma_rw_ctx_init_bvec()` (2025–26) accepts `bvec` arrays plus a `bvec_iter` directly, avoiding building a scatterlist. On an IOMMU system it first tries **`RDMA_RW_IOVA`**: `rdma_rw_init_iova_wrs_bvec()` calls `dma_iova_try_alloc()` to reserve one contiguous IOVA range for the whole transfer, then `dma_iova_link()` for each bvec's physical range. The result is a *single* SGE covering the entire I/O regardless of how fragmented the pages are, so one WR, no MR and no SGE-limit splitting. This uses the new two-step DMA IOVA API (Leon Romanovsky / Christoph Hellwig, 6.16+). It isn't available for virtual-DMA software devices (`ib_uses_virt_dma`), so those fall back to per-bvec mapping.

**T10-PI signatures (`RDMA_RW_SIG_MR`).** `rdma_rw_ctx_signature_init()` takes data and protection SG lists plus `struct ib_sig_attrs` (the DIF format on the wire and in memory) and registers an `IB_MR_TYPE_INTEGRITY` MR, so the HCA inserts, strips or verifies protection information in flight. `rdma_rw_ctx_destroy_signature()` releases it, and the ULP checks the result with `ib_check_mr_status()`. NVMe-oF and iSER use this for end-to-end data integrity.

**Posting.** `rdma_rw_ctx_wrs(ctx, qp, port, cqe, chain_wr)` returns the head of the WR chain, with the ULP's `ib_cqe` on the *last* WR (signalled) and all earlier WRs unsignalled. It can link the ULP's own WR afterwards. The NVMe-oF target chains the response SEND behind the RDMA WRITE, so data and completion go out in one `ib_post_send()` and one doorbell. `rdma_rw_ctx_post()` is the convenience wrapper. The return value of `ctx_init` tells the ULP how many send-queue slots the operation consumes, for its own SQ-space accounting.

**Cleanup.** After the completion, `rdma_rw_ctx_destroy()` (or `_destroy_bvec`, `_destroy_signature`) returns MRs to the pool (they will be locally invalidated on next use if needed), frees any SGE/WR arrays, and DMA-unmaps: IOVA unlink and free for the IOVA path.

## Key Data Structures

**`struct rdma_rw_ctx`** (`include/rdma/rw.h`) — one transfer.
- `nr_ops` — number of RDMA READ/WRITE WRs (excluding REG/INV)
- `type` — `RDMA_RW_SINGLE_WR`, `MULTI_WR`, `MR`, `SIG_MR`, `IOVA`
- union `single` — one `ib_sge` + one `ib_rdma_wr` inline
- union `map` — arrays of SGEs and WRs
- union `iova` — `dma_iova_state`, one SGE and WR, `mapped_len`
- union `reg` — array of `struct rdma_rw_reg_ctx {sge, wr, reg_wr, inv_wr, mr}`

**`struct ib_qp` fields used**: `rdma_mrs`, `sig_mrs`, `mrs_used`, `mr_lock`, `max_write_sge`, `max_read_sge`.

## Key Functions / Entry Points

- **`rdma_rw_init_qp()` / `rdma_rw_init_mrs()` / `rdma_rw_cleanup_mrs()`** — QP sizing and MR pools
- **`rdma_rw_ctx_init()`** — scatterlist input; picks MR, multi-WR or single-WR
- **`rdma_rw_ctx_init_bvec()`** — bio_vec input; tries IOVA first
- **`rdma_rw_ctx_signature_init()`** — T10-PI
- **`rdma_rw_ctx_wrs()` / `rdma_rw_ctx_post()`** — produce and post the chain
- **`rdma_rw_ctx_destroy()` / `_destroy_bvec()` / `_destroy_signature()`**
- **`rdma_rw_mr_factor()` / `rdma_rw_max_send_wr()`** — sizing helpers for ULPs
- Users: `nvmet_rdma_rw_ctx_init()` (`drivers/nvme/target/rdma.c`), `svc_rdma_rw.c` (NFS server), `isert`, `srpt`, ksmbd

## Important Flags & Config Options

- `ib_core.force_mr` module parameter (rw.c is built into ib_core) — always register; for testing the MR path on IB/RoCE
- `ib_device_attr.max_sgl_rd` — device hint that READs with more SGEs are better done via MR
- `ib_qp_init_attr.cap.max_rdma_ctxs` — how many concurrent rw contexts a QP must support
- `IB_MR_TYPE_INTEGRITY` / `struct ib_sig_attrs` — signature offload

## Interactions with Other Subsystems

- **→ DMA mapping / IOMMU**: scatterlist mapping, and the DMA IOVA API (`dma_iova_try_alloc`, `dma_iova_link`) for single-range mappings ([[dma-mapping-api]])
- **→ QP layer**: builds `ib_rdma_wr`, `ib_reg_wr`, invalidate WRs; relies on selective signalling ([[queue-pairs-and-completion-queues]])
- **→ MR pools**: fast-registration MRs ([[memory-registration-and-ib-umem]])
- **← Block layer**: bvec input comes straight from `struct bio` ([[bio-layer]])
- **← ULPs**: NVMe-oF target ([[nvme-over-fabrics-rdma-and-tcp]]), NFS server ([[nfs-over-rdma-svcrdma-xprtrdma]]), iSER/SRP targets, SMB Direct

## Design Decisions & Tradeoffs

- **The library chooses the strategy.** Centralizing "SGE vs MR" logic means iWARP support and T10-PI come for free to every target, at the cost of a somewhat opaque cost model (e.g. `max_sgl_rd` is a vendor hint).
- **Pre-allocated per-QP MR pools.** Fast-path registration never allocates, but QPs reserve MRs whether or not they're used. `rdma_rw_mr_factor()` lets ULPs size this.
- **Chaining the ULP's WR.** One doorbell for data plus response lowers latency. It relies on RC ordering: the WRITE lands before the SEND is delivered.
- **IOVA over MR for fragmented I/O.** A contiguous IOVA turns an N-page, M-SGE transfer into one SGE with no memory-key traffic. It needs an IOMMU (in DMA-translating mode) and adds IOTLB pressure. MRs still win on iWARP READs and for signatures.

## How It Has Evolved

- **4.7 (2016)** — `rdma_rw` introduced by Christoph Hellwig along with the NVMe-oF target work; iSER and SRP targets converted
- **4.x** — signature (T10-PI) contexts; NFS server (svcrdma) converted (Chuck Lever)
- **5.x** — `rdma_rw_mr_factor()` for sizing; integrity MR type replaces the older signature QP flag (5.3)
- **2025–26** — bio_vec input (`rdma_rw_ctx_init_bvec`) and the DMA IOVA single-SGE strategy; `-EAGAIN` fallback from optional MR use to SGEs

## Further Reading

- Source — `drivers/infiniband/core/rw.c` (well commented), `include/rdma/rw.h`
- Consumers — `drivers/nvme/target/rdma.c`, `net/sunrpc/xprtrdma/svc_rdma_rw.c`
- LWN — coverage of the DMA IOVA API ("dma: Provide an interface for DMA IOVA allocation", 2025)
- Related: [[rdma]], [[memory-registration-and-ib-umem]], [[dma-mapping-api]], [[nvme-over-fabrics-rdma-and-tcp]]

## LKML Highlights

- **"generic RDMA READ/WRITE API" (Christoph Hellwig, Feb–Apr 2016)** — introduced `rdma_rw_ctx` so NVMe-oF, iSER and SRP targets stopped each handling iWARP READ registration and SGE limits themselves. Reviewers (Sagi Grimberg, Steve Wise) focused on iWARP's `READ_WITH_INV` and MR-pool sizing.
- **DMA IOVA API adoption in rdma_rw (2025–26)** — part of the effort to let block and RDMA paths map bio_vecs into one IOVA range without scatterlists, collapsing multi-SGE I/Os into single-SGE WRs. (Lore was unreachable for message-ids this session.)
