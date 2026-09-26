---
title: "dma-buf: Cross-Device Buffer Sharing"
category: concept
tags: [dma, dma-buf, dma-fence, dma-resv, zero-copy, p2p]
subsystem: dma
kernel_version: "3.3 (dma-buf); 5.5–5.7 (dynamic attach, move_notify); 7.x/2026 (invalidate_mappings, revocation)"
researched: 2026-09-26
status: complete
explained: "[[dma-buf-sharing-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/driver-api/dma-buf.html
  - https://github.com/torvalds/linux/blob/master/include/linux/dma-buf.h
  - https://github.com/torvalds/linux/blob/master/drivers/dma-buf/dma-buf.c
  - https://github.com/torvalds/linux/blob/master/drivers/dma-buf/dma-buf-mapping.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/umem_dmabuf.c
  - https://github.com/torvalds/linux/blob/master/net/core/devmem.c
  - https://github.com/torvalds/linux/blob/master/io_uring/zcrx.c
  - https://lists.linaro.org/archives/list/linaro-mm-sig@lists.linaro.org/thread/X6FFLMHK4FWAABD3LGNXATDVH7IOVGYQ/
  - https://github.com/NVIDIA/NV-Kernels/pull/618
  - https://lwn.net/Articles/836484/
  - https://lwn.net/Articles/1056826/
  - https://lwn.net/Articles/1032302/
---

# dma-buf: Cross-Device Buffer Sharing

> 📘 Plain-language version: [[dma-buf-sharing-explained]]

## Purpose

Devices increasingly need to work on *the same memory* without copying: a camera writes frames a GPU renders and a display scans out, a GPU's VRAM is the target of an RDMA transfer, a NIC receives packets straight into accelerator memory. Each driver has its own allocator and its own idea of where the buffer lives (system RAM, VRAM, a BAR, carve-outs), and they can't just pass `struct page` pointers around, because device memory often has no struct pages, may move, and needs cache and IOMMU handling per device. **dma-buf** is the kernel's generic **buffer-sharing contract**: one driver (the *exporter*) owns and allocates a buffer and wraps it as a **file descriptor**. Any other driver (an *importer*) can take that fd, *attach* its device, and ask for a **DMA mapping for that specific device**. Companion primitives **dma-fence** (completion signals) and **dma-resv** (per-buffer fence sets) coordinate *when* each device may touch the buffer. It started in graphics and media (3.3, 2012), and is now the plumbing behind GPU↔NIC zero-copy: RDMA dma-buf MRs, [[devmem-tcp]], io_uring zero-copy receive into device memory, and VFIO device-memory export.

## Mental Model

A dma-buf is a **shared storage locker with a building manager**. The exporter is the manager: it knows where the locker physically is and may relocate it. Importers get a **key card** (the fd). To use the locker, an importer *registers its device* (attach) and asks the manager for **directions from its device's point of view** (a scatterlist of DMA addresses for that device, with IOMMU and P2P routing already applied). A *static* importer insists the locker never moves while it holds directions (pinning). A *dynamic* importer agrees to throw its directions away when the manager says "we're moving" (`invalidate_mappings`) and to ask again. The **dma-resv** is the sign-out sheet on the locker door, listing which devices are still working inside (fences), so the next user or the mover can wait until they're done.

## How It Works

**Exporting.** A driver fills `struct dma_buf_export_info` (size, flags, its `const struct dma_buf_ops *`, a private pointer, optionally a shared `dma_resv`) and calls `dma_buf_export()`. That creates a `struct dma_buf` backed by an anonymous file. `dma_buf_fd()` installs it in the caller's fd table so userspace can pass it across processes (Unix sockets) or into other drivers' ioctls. Typical exporters:
- GPU drivers (DRM PRIME, `DRM_IOCTL_PRIME_HANDLE_TO_FD`)
- **dma-heaps** (`/dev/dma_heap/system`, `/dev/dma_heap/cma`), generic allocators for userspace
- **udmabuf** (wraps memfd pages as a dma-buf)
- V4L2 and media drivers
- (6.19+) **VFIO PCI** device BAR ranges
- (2026) **RDMA devices** exporting device memory and UAR pages ([[rdma]])

**Importing and attaching.** The importer gets the buffer with `dma_buf_get(fd)` (a reference), then attaches its `struct device`:
- **`dma_buf_attach(dmabuf, dev)`** — a *static* importer. The framework pins the buffer through the exporter's `pin` op for as long as mappings exist, so the exporter may not move it.
- **`dma_buf_dynamic_attach(dmabuf, dev, importer_ops, priv)`** — a *dynamic* importer. `struct dma_buf_attach_ops` declares `allow_peer2peer` (can I handle P2P addresses without struct pages?) and **`invalidate_mappings`** (called when the exporter moves or revokes the buffer; renamed from `move_notify` in 2026). The exporter's `attach` op can reject the device, e.g. if P2P routing isn't possible for it ([[p2pdma-peer-to-peer-dma]]).

**Mapping.** `dma_buf_map_attachment(attach, dir)`, called with the buffer's `dma_resv` lock held (or the `_unlocked` variant), calls the exporter's `map_dma_buf`, which returns an **`sg_table` of DMA addresses valid for that device**. It may be backed by the exporter's pages, mapped with the device's IOMMU. For device memory it is often a scatterlist **with no CPU pages at all**: `dma_buf_phys_vec_to_sgt()` (`dma-buf-mapping.c`) builds one from physical ranges using the DMA IOVA API or P2P bus addresses and deliberately sets `sg_page = NULL`, so importers can't sneak CPU access. Importers program their hardware from the DMA addresses and must never assume pages. `dma_buf_unmap_attachment()` releases the mapping, and `dma_buf_detach()` + `dma_buf_put()` end the relationship.

**Synchronization: dma-fence and dma-resv.** GPUs and other asynchronous engines don't finish work when the submit ioctl returns. A **`dma_fence`** is a one-shot completion object (signalled by the driver's IRQ handler) with callbacks and waits. Each dma-buf has a **`dma_resv`** (reservation object, a ww_mutex plus a set of fences tagged by usage `KERNEL < WRITE < READ < BOOKKEEP`). Producers add their fence with `dma_resv_add_fence(..., DMA_RESV_USAGE_WRITE)`, and consumers wait on `dma_resv_usage_rw()` fences before reading. That is **implicit synchronization**, the traditional Linux graphics model. **Explicit sync** (Android, Vulkan) passes fences as `sync_file` fds instead. Userspace mmap access is bracketed by `DMA_BUF_IOCTL_SYNC` for cache maintenance.

**Moving and revoking (dynamic importers).** When an exporter must relocate a buffer (e.g. evict VRAM to system RAM under memory pressure), it takes the resv lock and calls **`dma_buf_invalidate_mappings(dmabuf)`**, which calls every dynamic importer's `invalidate_mappings`. The kernel-doc sets the contract:
1. After the call, importers may still access memory **until the fences in the resv retire** (the exporter waits with `dma_resv_wait_timeout()`).
2. Until the importer calls **unmap**, it may still *speculatively read and discard*, but not write.

An exporter that wants access *fully* stopped must wait for both. Importers with `invalidate_mappings` must unmap in **bounded time**. They may re-map right away and get the new location. For **pinned** importers, an invalidate means *permanent revocation*. This is how VFIO revokes a device BAR when the device is reset or reassigned. **`dma_buf_attach_revocable(attach)`** (2026) lets exporters refuse importers that can't honour bounded revocation. The RDMA side answered with `ib_umem_dmabuf_get_pinned_revocable_and_lock()` and a driver `pinned_revoke` callback, so NICs can be revoked too ([[memory-registration-and-ib-umem]]).

**Importers in the networking and RDMA stack.**
- **RDMA MRs** (`umem_dmabuf.c`): dynamic attach with `allow_peer2peer` for ODP-capable NICs, which rebuild NIC translations after `invalidate_mappings` and wait on resv fences before loading new addresses; pinned (and 2026: pinned-revocable) attach for other NICs ([[on-demand-paging-odp]]).
- **devmem TCP** (`net/core/devmem.c`): binds a dma-buf to NIC RX queues with a *static* `dma_buf_attach()` and maps it for `DMA_FROM_DEVICE`. The NIC's page pool then hands out `net_iov` chunks of that mapping as receive buffers, so payloads land in GPU memory ([[devmem-tcp]], [[page-pool]]).
- **io_uring zcrx** (`io_uring/zcrx.c`): a zero-copy receive area can be a dma-buf (`dma_buf_get` → `dma_buf_attach` → `dma_buf_map_attachment_unlocked`) as well as user memory ([[io-uring-zero-copy-networking]]).
- **iommufd / VFIO**: import dma-bufs to map device memory into guest IOVA space (2026, `dma_buf_pin` for iommufd).

## Key Data Structures

**`struct dma_buf`** (`include/linux/dma-buf.h`) — `size`, `file`, `attachments` (list), `ops`, `resv`, `priv`, `exp_name`, `vmap_ptr`.

**`struct dma_buf_ops`** — exporter vtable: `attach`, `detach`, `pin`, `unpin`, `map_dma_buf`, `unmap_dma_buf`, `release`, `begin_cpu_access`, `end_cpu_access`, `mmap`, `vmap`, `vunmap`.

**`struct dma_buf_attachment`** — `dmabuf`, `dev`, `node`, `peer2peer`, `importer_ops`, `importer_priv`.

**`struct dma_buf_attach_ops`** — importer side: `allow_peer2peer`, `invalidate_mappings`.

**`struct dma_resv`** (`include/linux/dma-resv.h`) — ww_mutex `lock` + `fences` list with usage levels.

**`struct dma_fence`** (`include/linux/dma-fence.h`) — `ops`, `context`, `seqno`, `flags` (signalled), `cb_list`, `timestamp`.

## Key Functions / Entry Points

- **`dma_buf_export()` / `dma_buf_fd()` / `dma_buf_get()` / `dma_buf_put()`**
- **`dma_buf_attach()` / `dma_buf_dynamic_attach()` / `dma_buf_detach()`**
- **`dma_buf_pin()` / `dma_buf_unpin()`**
- **`dma_buf_map_attachment()` / `_unlocked()` / `dma_buf_unmap_attachment()`**
- **`dma_buf_invalidate_mappings()` / `dma_buf_attach_revocable()`** (2026 names)
- **`dma_buf_phys_vec_to_sgt()` / `dma_buf_free_sgt()`** (`dma-buf-mapping.c`) — page-less sg tables for MMIO/P2P exporters
- **`dma_resv_add_fence()` / `dma_resv_wait_timeout()` / `dma_resv_usage_rw()`**
- **`dma_buf_begin_cpu_access()` / `dma_buf_vmap()` / `dma_buf_mmap()`** — CPU access

## Important Flags & Config Options

- `CONFIG_DMA_SHARED_BUFFER`; `CONFIG_DMABUF_HEAPS`, `CONFIG_DMABUF_HEAPS_SYSTEM`, `CONFIG_DMABUF_HEAPS_CMA`; `CONFIG_UDMABUF`; `CONFIG_SYNC_FILE`
- `CONFIG_DMABUF_MOVE_NOTIFY` — historically gated dynamic importers; made always-on in the 2026 revoke series
- Symbols exported in the `"DMA_BUF"` namespace (`MODULE_IMPORT_NS("DMA_BUF")` required)
- `DMA_BUF_IOCTL_SYNC`, `DMA_BUF_SET_NAME`, `DMA_BUF_IOCTL_EXPORT_SYNC_FILE` / `IMPORT_SYNC_FILE` (userspace)
- debugfs `/sys/kernel/debug/dma_buf/bufinfo`; per-process fdinfo shows exporter name and size

## Interactions with Other Subsystems

- **↑ Userspace**: fds from DRM PRIME, dma-heaps, udmabuf, V4L2, VFIO; passed into RDMA (`ibv_reg_dmabuf_mr`), netdev netlink (devmem bind), io_uring (zcrx area), KMS, media
- **→ DMA mapping / IOMMU / P2PDMA**: exporters compute per-device DMA addresses, including P2P bus addresses ([[dma-mapping-api]], [[p2pdma-peer-to-peer-dma]])
- **→ mm**: page-backed exporters (heaps, udmabuf) pin pages; mmap goes through exporter ops
- **← RDMA**: importer (MRs) and exporter (device memory) ([[memory-registration-and-ib-umem]])
- **← networking**: devmem TCP RX/TX bindings; io_uring zcrx ([[devmem-tcp]], [[io-uring-zero-copy-networking]])
- **← VFIO / iommufd**: device BAR export (6.19) and import into IOAS

## Design Decisions & Tradeoffs

- **fd-based handles.** File descriptors give lifetime (refcount), cross-process passing and a uniform userspace currency, reusing VFS and SCM_RIGHTS. The cost is some overhead and the need for namespaced exports to avoid misuse.
- **Per-attachment mapping.** Only the exporter knows how to reach its memory from a given device (IOMMU groups, P2P routes, bounce limits), so mapping is per device, which means N mappings for N importers.
- **Static vs dynamic importers.** Pinning is simple and works for any hardware, but blocks VRAM eviction. Dynamic import allows eviction, but importers must support invalidation and re-fault, which for NICs means ODP-class hardware. The 2026 revocation work formalizes the middle ground: pinned but revocable within bounded time.
- **Page-less scatterlists.** Abusing `sg_table` to carry only DMA addresses avoids inventing a new container, but demands discipline (never touch `sg_page`). `dma_buf_phys_vec_to_sgt()` enforces it by leaving pages NULL.
- **Implicit vs explicit sync.** Implicit resv fences make naïve sharing "just work" but serialize more than necessary. Explicit `sync_file` fences give control. Both coexist through sync_file import/export ioctls.

## How It Has Evolved

- **3.3 (2012)** — dma-buf (Sumit Semwal, Linaro) for graphics and media sharing
- **3.x–4.x** — dma-fence and reservation objects (Maarten Lankhorst); sync_file (Android explicit sync)
- **5.3–5.7** — dynamic importers, `pin`/`unpin`, `move_notify`, P2P (`allow_peer2peer`) (Christian König, AMD)
- **5.6** — dma-heaps replace Android ION; **5.12** — RDMA dma-buf MRs
- **6.x** — devmem TCP binds dma-bufs to NIC queues (6.12); io_uring zcrx gains dma-buf areas; `DMA_RESV_USAGE_*` levels; dma-buf export/import sync_file ioctls
- **6.19 (2025)** — VFIO PCI MMIO export via dma-buf; page-less mapping helpers
- **2026** — revoke series (Leon Romanovsky): `move_notify` → `invalidate_mappings`, `dma_buf_move_notify()` → `dma_buf_invalidate_mappings()`, `dma_buf_attach_revocable()`, always-on move notify, VFIO waits for importers, `dma_buf_pin` for iommufd; RDMA dma-buf export and pinned-revocable import; documentation of the mapping contract

## Further Reading

- kernel.org — [Buffer Sharing and Synchronization (dma-buf)](https://www.kernel.org/doc/html/latest/driver-api/dma-buf.html)
- linaro-mm-sig — [dma-buf: Use revoke mechanism to invalidate shared buffers (v6)](https://lists.linaro.org/archives/list/linaro-mm-sig@lists.linaro.org/thread/X6FFLMHK4FWAABD3LGNXATDVH7IOVGYQ/)
- LWN — [RDMA: Add dma-buf support](https://lwn.net/Articles/836484/); [RDMA: dma-buf export](https://lwn.net/Articles/1056826/); [vfio/pci dma-buf export](https://lwn.net/Articles/1032302/)
- Related: [[p2pdma-peer-to-peer-dma]], [[dma-mapping-api]], [[memory-registration-and-ib-umem]], [[devmem-tcp]], [[io-uring-zero-copy-networking]], [[page-pool]]

## LKML Highlights

- **"dma-buf: Use revoke mechanism to invalidate shared buffers" v6 (Leon Romanovsky, Jan 2026)** — renamed `move_notify` to `invalidate_mappings`, added `dma_buf_attach_revocable()`, and documented the two-wait revoke contract. It surfaced a real conflict: RDMA's pinned importers couldn't promise bounded revocation, forcing either breaking those flows or blocking such importer/exporter combinations, which led to the RDMA pinned-revocable umem API.
- **`<1604616489-69267-1-git-send-email-jianxin.xiong@intel.com>`** — RDMA as a *dynamic* dma-buf importer (5.12), the first non-graphics dynamic importer, reusing ODP invalidation for `move_notify`.
- **"dma-buf: add dynamic DMA-buf handling v15" (Christian König, 2019)** — introduced dynamic attachments, pin/unpin and move notification so GPU drivers could evict shared buffers. It went through many revisions over locking (resv held across map) and P2P semantics. (Message-id unavailable: lore was unreachable this session.)
