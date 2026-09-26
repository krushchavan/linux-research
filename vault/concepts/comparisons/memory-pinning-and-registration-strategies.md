---
title: "Memory Pinning and Registration Strategies: GUP, io_uring Registered Buffers, RDMA MRs, ODP, dma-buf, zcrx Areas and AF_XDP UMEM"
category: concept
tags: [comparison, gup, pinning, rdma, io_uring, dma-buf]
subsystem: comparisons
kernel_version: "RDMA MR (2.6); FOLL_PIN 5.6; FOLL_LONGTERM migration 5.7+; io_uring registered buffers 5.1; AF_XDP UMEM 4.18; RDMA ODP 4.x; dma-buf RDMA MRs 5.12; devmem 6.12; zcrx 6.15"
researched: 2026-09-26
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/core-api/pin_user_pages.html
  - https://lwn.net/Articles/886139/
  - https://lwn.net/Articles/922548/
  - https://lwn.net/Articles/932694/
  - https://lwn.net/Articles/791691/
  - https://docs.kernel.org/networking/af_xdp.html
  - https://ratatoskr.run/bpf/2026/07/17350248/t
  - https://ratatoskr.run/netdev/2026/07/17343650/t
  - https://www.kernel.org/doc/html/latest/networking/msg_zerocopy.html
---

# Memory Pinning and Registration Strategies

> Comparison note under `comparisons/`. Companion to [[zero-copy-buffer-ownership-and-return-protocols]] (which covers *who owns a buffer when*). This note covers *how memory becomes usable by a device in the first place*. Deep dives: [[get-user-pages-and-pinning]], [[registered-resources]], [[memory-registration-and-ib-umem]], [[on-demand-paging-odp]], [[dma-buf-sharing]], [[dma-mapping-api]].

## Purpose

A device can only DMA to a **bus address** that stays valid for as long as the device might use it. Ordinary process memory breaks that assumption: the kernel is free to swap it out, migrate it for compaction or NUMA balancing, merge it (KSM), split or collapse huge pages, or replace it on copy-on-write after `fork()`. Every zero-copy interface therefore has to answer three questions before a single byte moves:

1. **Stability**: how do we stop the physical page from changing under the device, or learn when it does?
2. **Translation**: when and where is the virtual range turned into DMA addresses (IOMMU mapping, NIC translation tables)?
3. **Accounting**: whose limit does the unswappable memory count against?

Linux has converged on a small set of answers, **per-I/O pin**, **long-term pin**, **notifier-driven (unpinned) mapping** and **exporter-owned memory (dma-buf)**, and each interface picks one, sometimes several. This note lines them up.

## Mental Model

Renting a **parking space** to a delivery company (the device):

- **Per-I/O pin**: reserve the space for one delivery and release it right after. Cheap to reserve, but you pay the reservation fee every time (direct I/O, `MSG_ZEROCOPY`).
- **Long-term pin (registration)**: sign a lease. The space is yours, the city can't tow or repaint it (no migration or swap), and it counts against your lease quota (`RLIMIT_MEMLOCK`). Deliveries are free after that (io_uring registered buffers, RDMA MRs, AF_XDP UMEM, zcrx areas).
- **Notifier-driven (ODP/HMM)**: no lease. The city may move your space at any time but **phones the delivery company first**. The company stops, updates its map, and faults the new address in when it next needs it. There's no quota, but each "where did it go?" costs a round trip.
- **dma-buf**: the space belongs to **another landlord** (a GPU driver, a heap, VFIO). You get a permit (attachment). A *static* permit makes the landlord promise not to move it (pin). A *dynamic* permit means the landlord may move it after calling you (invalidate). A *revocable* permit means the landlord can cancel it outright.

## How It Works

### 1. The foundation: GUP, FOLL_PIN and FOLL_LONGTERM

Everything that uses *anonymous or file-backed user memory* goes through **get_user_pages (GUP)** ([[get-user-pages-and-pinning]]). The kernel's `pin_user_pages` document distinguishes four cases, which map directly onto the strategies below:

- **Case 1, Direct I/O**: `FOLL_PIN`, short-term. The pin lasts one I/O.
- **Case 2, RDMA**: `FOLL_PIN | FOLL_LONGTERM`. The pin lasts until deregistration.
- **Case 3, MMU notifiers**: no pin at all. The driver stops using the page and unmaps it when notified (ODP, HMM, SVA).
- **Case 4, struct page only**: plain `FOLL_GET`, for metadata access without touching data.

`FOLL_PIN` differs from an ordinary reference because mm must be able to *tell* that DMA may be in flight. Order-0 folios get `GUP_PIN_COUNTING_BIAS` (1024) added to `_refcount`, and large folios use a dedicated `_pincount`. `folio_maybe_dma_pinned()` then lets writeback, migration and fork make safe decisions. Since the `PG_anon_exclusive` rework (5.18–5.19), pinning an anonymous page makes it exclusive first, so a later COW can never silently swap the page the device writes to. This ended the historical `fork()` corruption that forced RDMA users to call `ibv_fork_init()`/`MADV_DONTFORK`.

`FOLL_LONGTERM` adds two rules because the pin may last hours. First, the page is **migrated out of `ZONE_MOVABLE` and CMA** before pinning, since those regions promise the page can always be moved (memory hot-unplug, contiguous allocations). Second, **FS-DAX and most file-backed pages are refused**, because a filesystem can't truncate or reallocate blocks that a device may be writing to indefinitely. The long-running "GUP + file-backed memory" problem is why every long-term interface below either rejects page-cache memory or restricts it to anonymous, shmem or hugetlbfs.

### 2. Per-I/O pinning: direct I/O and MSG_ZEROCOPY

**Direct I/O** pins the user buffer for each request. Historically it used `iov_iter_get_pages()` (a `FOLL_GET` reference). A multi-year effort by John Hubbard and David Howells converted the block layer to `FOLL_PIN` via **`iov_iter_extract_pages()`** (6.3–6.5, [LWN](https://lwn.net/Articles/922548/), [LWN](https://lwn.net/Articles/932694/)), which pins user-backed iterators (`iov_iter_extract_will_pin()`) and merely lists pages for kernel-backed ones (bvec, kvec). bio completion then calls `unpin_user_page()`. The DMA mapping is also per I/O: blk-mq maps the bio's segments when the request is dispatched to the driver.

**`MSG_ZEROCOPY`** pins user pages per `send()` and attaches them to skbs. The pages are charged to `RLIMIT_MEMLOCK` (`mm_account_pinned_pages()`) for as long as any skb holds them, which can be until the data is ACKed. Exceeding optmem or `RLIMIT_MEMLOCK` gives `ENOBUFS`. The NIC driver DMA-maps each frag at transmit time.

**Tradeoff**: no setup and no long-lived unswappable memory, but the page-table walk, refcount atomics and IOMMU map/unmap are paid on *every* operation. At high IOPS or small sizes that overhead is a large part of the cost, which is why the registration schemes exist.

### 3. io_uring registered (fixed) buffers: pin once, map per I/O

`IORING_REGISTER_BUFFERS[2]` ([[registered-resources]]) calls `pin_user_pages_fast(FOLL_WRITE | FOLL_PIN | FOLL_LONGTERM)` once, charges the memory via `io_account_mem()` (to the user's `locked_vm` and the ring's `mm->pinned_vm`) against `RLIMIT_MEMLOCK`, and stores a `bio_vec` array in `struct io_mapped_ubuf`. Since 6.12, pages from the same huge folio are **coalesced into one bvec**. File-backed memory is rejected except for shmem and hugetlbfs.

What it does *not* do is DMA-map. A `READ_FIXED`/`WRITE_FIXED` or a `SEND_ZC` with `IORING_RECVSEND_FIXED_BUF` skips pinning and builds an `ITER_BVEC` directly, but the block or network driver still maps the pages for each request. So registered buffers remove the **GUP cost**, not the **IOMMU cost**. DMA pre-mapping of registered buffers for NVMe (Keith Busch, 2022) was proposed and not merged. The DMA IOVA-link API work (2025) is the modern route to amortising that cost.

Two newer variants change who supplies the pages:
- **`IORING_REGISTER_CLONE_BUFFERS`** (6.12) shares an existing table between rings by reference (~17 µs instead of ~1 s to re-pin gigabytes).
- **Kernel-registered buffers** (`io_buffer_register_bvec()`, 6.15) let a driver such as ublk place *its own* request pages into a slot, so the "registration" pins nothing at all ([[ublk-zero-copy]]).

### 4. RDMA memory regions: pin, map and program the NIC once

`ibv_reg_mr()` ([[memory-registration-and-ib-umem]]) is the most heavyweight and most complete registration. `__ib_umem_get_va()`:
1. checks `can_do_mlock()` and charges `mm->pinned_vm` against `RLIMIT_MEMLOCK` (unless `CAP_IPC_LOCK`)
2. pins with `pin_user_pages_fast(FOLL_LONGTERM | [FOLL_WRITE])`
3. merges contiguous pages into a scatterlist
4. **DMA-maps it once** (`ib_dma_map_sgtable_attrs`, optionally with relaxed ordering)
5. the driver then picks the largest supported NIC page size (`ib_umem_find_best_pgsz()`) and writes the translation into the NIC's **MTT**.

The result is an lkey/rkey that lets the NIC, or a *remote* peer, access the memory with no kernel involvement per operation. The costs are registration latency (hundreds of µs to ms for large regions), NIC translation-cache pressure, and the pinned memory itself. Applications and middleware such as UCX and MPI hide this with **registration caches**, which in turn need mm notifiers to detect `munmap`. That complexity is what ODP removes.

**Kernel ULPs** skip umem entirely. Their pages are already kernel-owned, so they use **fast registration** (`IB_WR_REG_MR` posted inline with I/O, from pre-allocated MR pools) to map scatterlists per I/O without a firmware command. That is RDMA's version of per-I/O mapping.

### 5. ODP / HMM: no pin, notifier-driven

**On-Demand Paging** ([[on-demand-paging-odp]]) registers the range with an `mmu_interval_notifier` and pins **nothing**. `RLIMIT_MEMLOCK` isn't charged. When the NIC touches a missing translation, it raises a **network page fault**: the driver calls `hmm_range_fault()`, DMA-maps the resulting pages and loads them into the MTT (the NIC sends RNR NAKs to remote peers meanwhile). When mm wants a page back (reclaim, migration, `munmap`, THP changes, COW), the notifier's `invalidate` runs *first*. The driver zaps the NIC entries, unmaps and dirties the pages, and only then does mm proceed.

**Implicit ODP** registers an entire address space with one key and creates 1 GiB child MRs on demand. It removes registration caches from MPI/UCX-style runtimes altogether.

The tradeoff is the inverse of pinning: registration is nearly free and memory stays swappable, THP-friendly and migratable, but a fault costs tens to hundreds of µs, and correctness rests on the NIC supporting precise, replayable faults (mlx5, rxe in software). `ibv_advise_mr(PREFETCH)` pre-faults ranges to hide that latency. The same pattern underlies GPU SVM and IOMMU SVA with PRI, which is Case 3 in the `pin_user_pages` document.

### 6. dma-buf: memory owned by someone else

Device memory (GPU VRAM, accelerator HBM, PCI BARs) has no `struct page` for GUP to pin. **dma-buf** ([[dma-buf-sharing]]) is the kernel's contract for sharing it: the exporter owns the memory, and each importer attaches its device and gets an `sg_table` of DMA addresses from `map_dma_buf` (often P2P bus addresses with `sg_page = NULL`, [[p2pdma-peer-to-peer-dma]]). Three attachment modes matter for zero-copy:

- **Static attach (`dma_buf_attach`)**: the exporter **pins** the buffer for the lifetime of the mapping. It is simple, and it is what **devmem TCP** uses (bind-rx / bind-tx map the dma-buf once and carve it into `net_iov`s) and what non-ODP RDMA NICs use via `ib_umem_dmabuf_get_pinned()`.
- **Dynamic attach (`dma_buf_dynamic_attach` + `invalidate_mappings`)**: the exporter may **move** the buffer (e.g. evict VRAM) after calling the importer, who must unmap in bounded time and re-map, waiting on `dma_resv` fences. It is ODP in another form, so RDMA restricts it to ODP-capable NICs (`ib_umem_dmabuf_get()`).
- **Pinned-revocable (2026)**: pinned, but the exporter can **revoke** permanently (GPU reset, VFIO device reassignment). `dma_buf_attach_revocable()` lets exporters refuse importers that can't honour it, and RDMA added `ib_umem_dmabuf_get_pinned_revocable_and_lock()` with a `pinned_revoke` callback.

Accounting is the exporter's business. dma-buf memory isn't charged to `RLIMIT_MEMLOCK`, because it isn't the process's page-cache or anonymous memory. GPU drivers and cgroups (the dmem controller) handle it instead.

### 7. Networking areas: AF_XDP UMEM and io_uring zcrx

Receive-side zero-copy needs memory the **NIC** can DMA into at any moment, so both designs use long-term pin plus a DMA map at bind time, plus a pool abstraction.

**AF_XDP UMEM** ([[af-xdp]]): `XDP_UMEM_REG` calls `xdp_umem_pin_pages()` → `pin_user_pages(FOLL_WRITE | FOLL_LONGTERM)` and charges `user->locked_vm` against `RLIMIT_MEMLOCK`. Binding a socket in zero-copy mode creates an `xsk_buff_pool` and **pre-computes DMA addresses for every UMEM page** (`xp_dma_map()`), so per-packet allocation is an index lookup. With `XDP_SHARED_UMEM` across devices, each device gets its own DMA mapping of the same pinned pages. **Unaligned chunk mode** ([LWN](https://lwn.net/Articles/791691/)) is typically used with hugepages so that frames can straddle 4K boundaries while staying physically contiguous. Accounting has had bugs: 2026 fixes addressed a `locked_vm` leak on partial pins and ring memory that was never charged ([netdev](https://ratatoskr.run/netdev/2026/07/17343650/t), [bpf](https://ratatoskr.run/bpf/2026/07/17350248/t)).

**io_uring zcrx area** ([[zero-copy-rx-zcrx]]): the area is either **user memory** (`pin_user_pages(FOLL_LONGTERM)`, `io_account_mem()`) or a **dma-buf** (`dma_buf_get` → static `dma_buf_attach` → map). The kernel DMA-maps the whole area for the NIC once (`io_populate_area_dma()`) and cuts it into `net_iov`s. With `rx_buf_len`, if the area is physically contiguous enough (hugepages), niovs larger than PAGE_SIZE are used so the NIC posts larger RX buffers. Multiple areas per ifq arrived in 2026.

**Devmem TCP** is the dma-buf-only sibling: no GUP, a static attach, and a genpool of niovs over the mapping ([[devmem-tcp-rx-dmabuf-binding-and-token-recycling]]).

### 8. Side-by-side

| Interface | Stability mechanism | Pin lifetime | DMA mapped | Device translation | Accounting | File-backed memory | Device memory |
|---|---|---|---|---|---|---|---|
| Direct I/O | `FOLL_PIN` | one I/O | per I/O (blk-mq) | IOMMU only | none (short-term) | yes (short pin) | via P2PDMA (NVMe CMB) |
| `MSG_ZEROCOPY` | GUP ref/pin | until ACK | per skb frag | IOMMU only | `RLIMIT_MEMLOCK` | yes | devmem TX instead |
| io_uring fixed buffers | `FOLL_PIN\|LONGTERM` | until unregister | **per I/O** | IOMMU only | `RLIMIT_MEMLOCK` | shmem/hugetlbfs only | kernel bvec (ublk), not dma-buf |
| RDMA MR | `FOLL_PIN\|LONGTERM` | until dereg | **once** | NIC MTT + IOMMU | `pinned_vm` vs `RLIMIT_MEMLOCK` | rejected (DAX, most FS) | dma-buf MR |
| RDMA ODP | mmu notifier (no pin) | none | on fault | NIC MTT, faultable | none | yes | dynamic dma-buf |
| dma-buf static | exporter pin | until detach | once (exporter) | importer's | exporter / dmem cgroup | n/a | yes (the point) |
| dma-buf dynamic | invalidate callback | none | per (re)map | importer's | exporter | n/a | yes |
| AF_XDP UMEM | `FOLL_PIN\|LONGTERM` | until close | **once per device** | IOMMU | `locked_vm` | no | no |
| zcrx area | `FOLL_LONGTERM` or dma-buf | until ifq close | **once** | IOMMU | `RLIMIT_MEMLOCK` (user mem) | no | yes (dma-buf area) |
| devmem TCP | dma-buf static | until unbind + last niov | once | IOMMU / P2P | exporter | n/a | yes |

## Key Data Structures

**`struct folio`** — `_refcount` (with `GUP_PIN_COUNTING_BIAS`) and `_pincount` mark DMA pins; `PG_anon_exclusive` guards COW.

**`struct io_mapped_ubuf`** (`io_uring/rsrc.h`) — pinned bvec array for a registered buffer; `folio_shift` for coalesced huge pages; `acct_pages`.

**`struct ib_umem` / `struct ib_umem_odp` / `struct ib_umem_dmabuf`** (`include/rdma/`) — pinned, notifier-driven and dma-buf-backed RDMA memory; `sgt_append`, `hmm_dma_map`/`notifier`, `attach`/`pinned`/`revoked`.

**`struct xdp_umem`** / **`struct xsk_buff_pool`** (`include/net/xdp_sock.h`, `xsk_buff_pool.h`) — pinned `pgs[]`, `npgs`, `user` (for `locked_vm`); per-device `dma_pages[]`.

**`struct io_zcrx_area`** — `mem` (`io_zcrx_mem`: pinned pages or dma-buf attachment + sgt), `nia.niovs[]`.

**`struct dma_buf_attachment`** — `importer_ops` (dynamic: `invalidate_mappings`, `allow_peer2peer`), `sgt`.

## Key Functions / Entry Points

- **`pin_user_pages_fast()` / `unpin_user_pages_dirty_lock()`** (`mm/gup.c`) — the pin/unpin pair all long-term users share.
- **`iov_iter_extract_pages()`** (`lib/iov_iter.c`) — per-I/O pin-or-list used by direct I/O.
- **`io_sqe_buffer_register()`** / **`io_account_mem()`** (`io_uring/rsrc.c`) — fixed buffer pinning and accounting.
- **`__ib_umem_get_va()`**, **`ib_umem_odp_get()`**, **`ib_umem_dmabuf_get[_pinned]()`** (`drivers/infiniband/core/`) — the three RDMA registration flavours.
- **`hmm_range_fault()`** + **`mmu_interval_notifier`** — the unpinned path.
- **`xdp_umem_pin_pages()`**, **`xp_dma_map()`** (`net/xdp/`) — UMEM pin and per-device map.
- **`io_import_umem()` / `io_import_dmabuf()`**, **`io_populate_area_dma()`** (`io_uring/zcrx.c`) — zcrx area import and mapping.
- **`dma_buf_attach()` / `dma_buf_dynamic_attach()` / `dma_buf_map_attachment()`** (`drivers/dma-buf/dma-buf.c`).

## Important Flags & Config Options

- **`RLIMIT_MEMLOCK`** (`ulimit -l`) — the limit for all long-term pins of user memory; `CAP_IPC_LOCK` bypasses it. Charged to `mm->pinned_vm` (RDMA), `user->locked_vm` (AF_XDP) or both (io_uring). The split between these two counters is a long-standing inconsistency.
- **`FOLL_LONGTERM`** — forces migration out of `ZONE_MOVABLE`/CMA (`movablecore=`/`kernelcore=`, `CONFIG_CMA` affect how much memory is eligible).
- **`IB_ACCESS_ON_DEMAND`**, **`IB_ACCESS_RELAXED_ORDERING`**; `ibv_advise_mr()` prefetch.
- **`XDP_UMEM_UNALIGNED_CHUNK_FLAG`**; hugepage-backed UMEM.
- **`IORING_REGISTER_BUFFERS2`**, **`IORING_REGISTER_CLONE_BUFFERS`**, zcrx `rx_buf_len`, `IORING_ZCRX_AREA_DMABUF`.
- **`CONFIG_DMABUF_MOVE_NOTIFY`** — historically gated dynamic dma-buf importers; `CONFIG_PCI_P2PDMA` for P2P mappings.

## Interactions with Other Subsystems

- **↑ Userspace**: `ulimit -l` and `CAP_IPC_LOCK` are the operator-facing knobs; hugepages (hugetlbfs, THP) cut pin, SG and translation-table overhead for every scheme.
- **→ mm**: GUP, migration (`ZONE_MOVABLE`/CMA), COW/`PG_anon_exclusive`, mmu notifiers, HMM, reclaim ([[get-user-pages-and-pinning]], [[page-reclaim]], [[transparent-huge-pages]]).
- **→ DMA / IOMMU**: every scheme ends in `dma_map_*` ([[dma-mapping-api]]); P2P for device memory ([[p2pdma-peer-to-peer-dma]]).
- **→ Filesystems**: long-term pins of page-cache pages conflict with writeback and truncate; DAX pages are refused.
- **← GPU / accelerator drivers**: dma-buf exporters decide pin, move and revoke policy ([[dma-buf-sharing]]).

## Design Decisions & Tradeoffs

- **Pin vs notify.** Pinning is simple and universally supported, but it fragments memory (no migration, no compaction, no THP collapse), consumes locked-memory quota, and fights filesystems. Notifier-driven mapping (ODP, dynamic dma-buf) keeps memory fully managed but demands device support for precise, restartable faults and adds fault latency. Linux supports both and lets devices choose.
- **Where to amortise the DMA map.** io_uring fixed buffers amortise only GUP. RDMA MRs, AF_XDP and zcrx also amortise the IOMMU mapping and device translation. The difference is historical: block drivers own their DMA mapping per request, while RDMA and XDP designs exposed the mapping as part of the registration object.
- **`FOLL_PIN` as a separate refcount.** Making pins detectable (`folio_maybe_dma_pinned()`) rather than indistinguishable from references was the prerequisite for fixing the fork/COW corruption, allowing safe migration decisions, and eventually letting filesystems reason about DMA-pinned page-cache pages.
- **Refusing long-term pins of file pages** (DAX, most filesystems) trades generality for safety: a device writing to blocks the filesystem believes free is data corruption. Anonymous, shmem and hugetlbfs memory, or dma-buf, is the supported path.
- **dma-buf revocation.** Static pinning of device memory was too strong for VFIO and GPU-reset scenarios. Revocable pins (2026) re-introduce an escape hatch without requiring full ODP.
- **Accounting fragmentation.** `pinned_vm` vs `locked_vm`, per-mm vs per-user, and dma-buf's separate world mean there is no single answer to "how much memory has this process made unmovable". AF_XDP's 2026 accounting fixes are a recent symptom.

## How It Has Evolved

- **2.6 era** — RDMA MRs pin with `get_user_pages()` and charge `locked_vm`; the fork problem is handled by `MADV_DONTFORK`.
- **3.x–4.x** — `mm->pinned_vm` introduced to separate pinned from mlocked memory; ODP (mlx5, ~3.19); AF_XDP UMEM (4.18); `MSG_ZEROCOPY` (4.14).
- **5.1** — io_uring registered buffers.
- **5.6–5.8** — `FOLL_PIN`/`pin_user_pages()` (John Hubbard); `FOLL_LONGTERM` migration from CMA/movable.
- **5.12** — dma-buf MRs for RDMA (dynamic for ODP NICs, pinned later for others).
- **5.18–5.19** — `PG_anon_exclusive` fixes GUP vs COW; `ibv_fork_init()` becomes unnecessary.
- **6.3–6.5** — `iov_iter_extract_pages()`; direct I/O moves to `FOLL_PIN`.
- **6.12** — io_uring huge-page bvec coalescing and buffer cloning; devmem TCP (dma-buf static attach).
- **6.15** — zcrx areas (user memory; dma-buf areas shortly after); io_uring kernel-registered buffers.
- **2026** — unified `ib_umem_get_desc()` (VA or dma-buf for any verb buffer); pinned-revocable dma-buf attach; AF_XDP accounting fixes; multiple zcrx areas.

## Further Reading

1. [LWN: block, fs: convert Direct IO to FOLL_PIN](https://lwn.net/Articles/886139/); [iov_iter: improve page extraction](https://lwn.net/Articles/922548/); [block: use page pinning](https://lwn.net/Articles/932694/)
2. [LWN: XDP unaligned chunk placement](https://lwn.net/Articles/791691/)
3. [kernel.org: pin_user_pages() and related calls](https://www.kernel.org/doc/html/latest/core-api/pin_user_pages.html)
4. [kernel.org: AF_XDP](https://docs.kernel.org/networking/af_xdp.html); [MSG_ZEROCOPY](https://www.kernel.org/doc/html/latest/networking/msg_zerocopy.html)
5. Vault deep dives: [[get-user-pages-and-pinning]], [[registered-resources]], [[memory-registration-and-ib-umem]], [[on-demand-paging-odp]], [[dma-buf-sharing]], [[zero-copy-rx-zcrx]], [[af-xdp]]

## LKML Highlights

- **"bio: Direct IO: convert to pin_user_pages_fast()" (John Hubbard, 2020)** — established that every DIO path must use `FOLL_PIN` and `unpin_user_page()` so mm can detect DMA pins; it took until 6.5 and David Howells' `iov_iter_extract_pages()` to finish.
- **"xsk: account uncharged ring memory" / "xsk: fix locked_vm leak on short pin" (2026)** — AF_XDP accounting fixes showing how easily per-interface pin accounting drifts.
- **Pinned-revocable dma-buf attach for RDMA (2026)** — exporters (VFIO, GPUs) must be able to revoke device memory even from importers that can't take faults; RDMA answered with a `pinned_revoke` callback that fences the NIC off the MR.
