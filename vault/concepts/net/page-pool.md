---
title: "Page Pool"
category: concept
tags: [networking, page-pool, memory-allocation, dma, xdp, netmem]
subsystem: net
kernel_version: "4.18"
researched: 2026-09-24
status: complete
explained: "[[page-pool-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/networking/page_pool.html
  - https://www.kernel.org/doc/html/latest/networking/netmem.html
  - https://raw.githubusercontent.com/torvalds/linux/master/include/net/page_pool/types.h
  - https://raw.githubusercontent.com/torvalds/linux/master/net/core/page_pool.c
  - https://lwn.net/Articles/717387/
  - https://lwn.net/Articles/858414/
  - https://lwn.net/Articles/930158/
  - https://lwn.net/Articles/948718/
  - https://lwn.net/Articles/948381/
  - https://lwn.net/Articles/1031554/
  - https://www.openwall.com/lists/kernel-hardening/2025/03/20/1
  - https://ratatoskr.run/lkml/2026/08/17381509/t
  - https://github.com/torvalds/linux/blob/master/io_uring/zcrx.c
---

# Page Pool

> 📘 Plain-language version: [[page-pool-explained]]

## Purpose

A NIC receive queue consumes and refills buffers at line rate: about 15 million packets per second on 10 GbE, which leaves only around 200 CPU cycles per packet. Asking the page allocator for a page and DMA-mapping it (often an IOMMU operation) for every packet is too expensive, so every high-performance driver used to invent its own page-recycling trick. The page pool, `net/core/page_pool.c`, replaces those tricks with one generic allocator. It hands out pages that are already DMA-mapped, recycles them without locks when they come back in the same NAPI context, and keeps them mapped for their whole life in the pool. It has since become the foundation for XDP memory models, skb recycling, and the `netmem` abstraction that lets receive queues use non-host memory (devmem TCP, io_uring zero-copy receive).

## Mental Model

A page pool is **a per-queue returnable-crate system**. Each receive queue owns a stack of crates (pages) already labelled for its truck (DMA-mapped for its device). When the queue needs a crate, it takes one from the stack right beside it (the lockless *alloc cache*). Crates coming back from the same loading dock go straight onto that stack. Crates returned from elsewhere go into a shared return bin (the *ptr_ring*), from which the dock refills in bulk. Only when both are empty does anyone order new crates from the warehouse (the buddy allocator), and those get labelled once. Crates are relabelled only if they leave the system entirely.

## How It Works

**Creating a pool.** A driver creates one pool per RX queue, and in any case one per NAPI context, because the lockless fast path depends on a single consumer. It calls `page_pool_create()` (or `page_pool_create_percpu()`) with a `struct page_pool_params`: `order` (page size 2^order), `pool_size` (ring capacity, typically the RX ring size), `nid`, `dev` (the DMA device), `napi`, `dma_dir`, `offset`/`max_len` (the part of each buffer the device writes, used for syncing), `netdev`/`queue_idx` (for introspection and memory-provider binding), and `flags`. The flags `PP_FLAG_DMA_MAP` and `PP_FLAG_DMA_SYNC_DEV` make the pool own DMA mapping and device syncing. Drivers are strongly encouraged to set both, and netmem-capable drivers must. `page_pool_init()` validates these, sets up a `ptr_ring` (default 1024 entries, maximum 16384), allocates per-CPU recycle statistics, and checks whether the queue has a *memory provider* bound to it (see below). The pool is also registered with `xdp_rxq_info` as `MEM_TYPE_PAGE_POOL`, so XDP frames know how to return their pages.

**Fast-path allocation.** In NAPI poll, the driver refills its RX descriptors with `page_pool_dev_alloc_pages()` (full pages), `page_pool_dev_alloc_frag()` (sub-page fragments) or `page_pool_dev_alloc()` (picks one based on size). All funnel into `page_pool_alloc_netmems()`. The first stop is `__page_pool_get_cached()`, which pops from `pool->alloc.cache[]`, a small plain array (`PP_ALLOC_CACHE_SIZE` = 2 × `PP_ALLOC_CACHE_REFILL`, which is 64 entries with 4K pages). No lock and no atomic are needed because only this NAPI instance ever touches it. The page is already DMA-mapped, and its bus address is stored in the page (netmem) itself.

**Refill from the ring.** If the alloc cache is empty, `page_pool_refill_alloc_cache()` pulls up to `PP_ALLOC_CACHE_REFILL` entries from the `ptr_ring`, where pages returned from other contexts wait. Pages from the wrong NUMA node (`netmem_is_pref_nid()` fails) are released rather than cached, so a queue whose IRQ affinity moved doesn't keep serving remote memory forever. `page_pool_update_nid()` lets a driver change the preferred node.

**Slow path.** If the ring is empty too, `__page_pool_alloc_netmems_slow()` bulk-allocates from the buddy allocator. For order-0 it uses `alloc_pages_bulk_node()` to grab a whole refill's worth at once. Each new page is mapped with `page_pool_dma_map()` → `dma_map_page_attrs(…, DMA_ATTR_SKIP_CPU_SYNC | DMA_ATTR_WEAK_ORDERING)`. The CPU sync is skipped because the device writes first and the pool syncs only the region the device may touch. Each mapping is also recorded in the pool's `dma_mapped` [[xarray]] (6.15+) so it can be undone later even if the page is still somewhere else. `pages_state_hold_cnt` is incremented for every page that enters circulation. When `PP_FLAG_DMA_SYNC_DEV` is set, `page_pool_dma_sync_for_device()` syncs `offset`…`offset + max_len` (or the driver-supplied `dma_sync_size`) before handing the page out, so recycled pages are always device-coherent without the driver thinking about it.

**Fragments.** A 1500-byte MTU frame doesn't need a 4K page, let alone the 64K pages found on some architectures. `page_pool_alloc_frag_netmem()` carves a page into pieces, tracking `frag_page`, `frag_offset` and `frag_users` in the pool. Rather than an atomic increment per fragment, it pre-charges the page's `pp_ref_count` with a large bias (`BIAS_MAX`) when the page is started and subtracts the unused part (`BIAS_MAX - frag_users`) when moving to the next page (`page_pool_drain_frag()`). Each fragment's return decrements the count, and only the last one recycles the page. The cost of this is cache-line contention on the shared count when fragments are freed on different CPUs, which the docs flag as a tradeoff.

**Return: the recycling decision.** Pages come back in three ways:
- Explicitly, via `page_pool_put_page()`/`page_pool_put_full_page()` when a driver drops an XDP frame or a descriptor.
- In bulk, via `page_pool_put_netmem_bulk()` from `xdp_return_frame_bulk()` and XDP_REDIRECT paths.
- Implicitly, from the network stack when an skb built on pool pages is freed. The driver calls `skb_mark_for_recycle()`, which sets `skb->pp_recycle`. `skb_free_head()`/`skb_release_data()` then detect pool pages (formerly via a `pp_magic` signature in `struct page`, now via a dedicated page type or the netmem `pp` pointer) and route them to `page_pool_put_netmem()` instead of `put_page()`.

In `__page_pool_put_page()`, a page can be recycled only if the pool holds the sole reference (refcount 1) and it isn't a `pfmemalloc` emergency page (`__page_pool_page_can_be_recycled()`). If it can, `page_pool_napi_local()` decides *where* it goes. If we're in softirq, not on PREEMPT_RT, and running on the CPU that owns the pool's NAPI (`pool->cpuid` or `napi->list_owner`), the page goes straight back into the lockless alloc cache (`allow_direct`). Otherwise it is produced into the `ptr_ring` under the ring's producer lock (`page_pool_recycle_in_ring()`), and in bulk mode many pages go in with one lock hold. If the ring is full, or the page has extra references (for example it was spliced into a socket's page frags or cloned), `page_pool_return_netmem()` gives it back: memory providers get `mp_ops->release_netmem()`, host pages are DMA-unmapped, `pages_state_release_cnt` is incremented, and the page goes back to the buddy allocator via `put_page()`.

**Failure and teardown path.** When the interface goes down or a queue is reconfigured, the driver calls `page_pool_destroy()`. That is not immediate, because pages may still be in flight inside sockets, TCP retransmit queues, or other devices after XDP_REDIRECT. The pool first calls `page_pool_disable_direct_recycling()` so nothing new enters the lockless cache. It frees its partial fragment page and runs `page_pool_release()`: empty the cache and ring, then compute inflight = `hold_cnt − release_cnt`. If pages remain, the pool stays alive and `page_pool_release_retry()` reruns on a delayed work item every `DEFER_TIME` (1 s), with a warning every `DEFER_WARN_INTERVAL` (60 s). Before 6.15 this left a real hazard: a late-returning page would be unmapped against a device whose driver had already unbound, which crashes with an IOMMU. Toke Høiland-Jørgensen's fix tracks every mapping in the `dma_mapped` xarray, so `page_pool_scrub()` can disable syncing, `synchronize_net()`, and unmap *all* outstanding mappings at destroy time. Pages returned later are simply freed. Races between scrub and concurrent returns on other CPUs continued to produce fixes into mid-2026 (for example, caching the DMA address before `xa_cmpxchg()` and a UAF fix in the return path). Jesper Brouer has argued that "inflight" warnings produce many false positives (legitimately long-lived skbs), and that real leak detection belongs in MM debug code.

**Memory providers and netmem (6.10–6.15).** Pages aren't the only memory a receive queue might want. Devmem TCP wants packet payloads to land directly in GPU memory (a dma-buf), and io_uring zero-copy receive wants them in user-registered memory (see [[io-uring-zero-copy-networking]]). To let the same pool serve both, the pool now traffics in `netmem_ref`, an opaque handle that is either a `struct page` or a `struct net_iov` (a small descriptor for a chunk of non-page memory). If a memory provider is bound to the queue, installed through the netdev queue-management API (`ndo_queue_mem_alloc` and friends) restarting the queue, `pool->mp_ops`/`mp_priv` are set. Allocation then goes to `mp_ops->alloc_netmems()` and release to `mp_ops->release_netmem()`, gated by a static branch so ordinary pools pay nothing. Such memory may be *unreadable* by the CPU, so drivers must opt in with `PP_FLAG_ALLOW_UNREADABLE_NETMEM` and use header/data split so headers still land in readable pages. They also must not peek at payloads or implement their own recycling on netmem.

## Key Data Structures

**`struct page_pool`** (`include/net/page_pool/types.h`)
- `alloc` — `struct pp_alloc_cache {count, cache[]}`, the lockless per-NAPI stack
- `ring` — `ptr_ring` for returns from other contexts
- `p` — copy of `page_pool_params`
- `cpuid`, `napi` — used by `page_pool_napi_local()` to authorise direct recycling
- `frag_page`, `frag_offset`, `frag_users` — current fragment page
- `pages_state_hold_cnt` / `pages_state_release_cnt` — inflight accounting
- `dma_mapped` — xarray of live DMA mappings (unmapped on destroy)
- `mp_ops`, `mp_priv` — bound memory provider
- `recycle_stats` (per-CPU), `alloc_stats` — `CONFIG_PAGE_POOL_STATS`
- `user.id`, `user.list`, `user.detach_time` — netlink introspection identity
- `release_dw`, `defer_start`, `defer_warn` — deferred-destroy state

**`struct page_pool_params`** — `order`, `pool_size`, `nid`, `dev`, `napi`, `dma_dir`, `max_len`, `offset`, `netdev`, `queue_idx`, `flags`.

**`netmem_ref` / `struct net_iov`** (`include/net/netmem.h`) — the tagged handle and the non-page descriptor. A net_iov carries `pp`, `dma_addr`, `pp_ref_count` and its owning area, and mirrors the page-pool fields of `struct page` (grouped as `struct netmem_desc`).

## Key Functions / Entry Points

**`page_pool_create()` / `page_pool_create_percpu()`** (`net/core/page_pool.c`) — called by drivers at queue setup.
**`page_pool_dev_alloc_pages()` / `_frag()` / `page_pool_dev_alloc()`** (`include/net/page_pool/helpers.h`) — RX refill in NAPI.
**`page_pool_alloc_netmems()`** — cache → ring → slow path/provider.
**`page_pool_put_page()` / `page_pool_put_full_page()` / `page_pool_recycle_direct()`** — explicit return.
**`page_pool_put_netmem_bulk()`** — bulk return from XDP.
**`skb_mark_for_recycle()`** — opt an skb's pages into recycling on free.
**`page_pool_destroy()` → `page_pool_release()` / `page_pool_release_retry()` / `page_pool_scrub()`** — teardown.
**`page_pool_get_stats()`** — driver ethtool stats export.

## Important Flags & Config Options

- `PP_FLAG_DMA_MAP` — pool maps/unmaps pages; required for recycling to save IOMMU work.
- `PP_FLAG_DMA_SYNC_DEV` — pool syncs `offset..offset+max_len` for device on allocation/recycle.
- `PP_FLAG_ALLOW_UNREADABLE_NETMEM` — driver can handle net_iov (devmem/zcrx) buffers.
- `PP_FLAG_SYSTEM_POOL` — the per-CPU system page pools used by generic paths (e.g. veth and generic XDP) that have no driver pool.
- `CONFIG_PAGE_POOL` — selected by drivers that use it.
- `CONFIG_PAGE_POOL_STATS` — per-pool allocation/recycle counters (fast, slow, empty, refill, waive; cached, cache_full, ring, ring_full, released_refcnt).
- Netlink (`ynl --family netdev --dump page-pool-get`) — lists pools, their netdev/NAPI, inflight pages and bytes, and detach time, including zombie pools kept alive by in-flight pages.

## Interactions with Other Subsystems

- **↑ Userspace**: indirect. Visible through netdev netlink introspection and ethtool stats. io_uring zcrx and devmem TCP bind memory providers to queues from userspace.
- **← [[network-device-and-napi]]**: drivers allocate in NAPI poll. The pool's lockless path relies on NAPI's single-CPU execution guarantee.
- **→ [[buddy-allocator]]**: slow path bulk-allocates pages, and returns pages on overflow or destroy.
- **→ [[dma-mapping-api]]**: long-lived streaming mappings, sync-for-device on reuse, unmap on release or destroy.
- **← [[sk-buff]]**: `skb->pp_recycle` routes freed skb pages back to the pool.
- **← [[xdp]]**: `MEM_TYPE_PAGE_POOL` memory model. XDP_DROP/TX/REDIRECT return pages directly or in bulk.
- **← [[io-uring-zero-copy-networking]] / [[devmem-tcp]]**: memory providers supply `net_iov` buffers through `mp_ops`.
- **→ [[xarray]]**: tracks DMA-mapped pages for safe teardown.

## Design Decisions & Tradeoffs

- **One pool per NAPI, lockless cache plus locked ring.** The common case, where a page is freed in the same softirq that will reuse it (XDP_DROP, local skb free), costs almost nothing. Cross-CPU returns pay a spinlock on the ring. The rule "pools must match NAPI contexts" is what makes the fast path safe, and it's why direct recycling is disabled on PREEMPT_RT and during destroy.
- **Keep pages DMA-mapped for life.** This avoids per-packet IOMMU map/unmap, which is often the single biggest RX cost, but it means pool pages pin IOMMU mappings and must be tracked across device unbind. That was ignored until the 6.15 xarray tracking made teardown safe.
- **Recycling via `struct page` fields.** Identifying pool pages required stealing space in `struct page` (`pp_magic`, `pp`, `dma_addr`, `pp_ref_count`), which drew scrutiny from MM maintainers (Matthew Wilcox's pfmemalloc and aliasing concerns in 2021). As MM moves toward memdescs, these fields became `netmem_desc`, and `pp_magic` gave way to a page type (`PGTY_netpp`, Byungchul Park 2025).
- **Only recycle when the pool holds the sole reference.** This is simple and safe. Pages with elevated refcounts (e.g. spliced to userspace) fall back to the allocator, which can lower recycle rates for some TCP workloads.
- **Fragment bias counting.** This saves an atomic per fragment but creates cache-line sharing when fragments are freed on other CPUs, and it complicates netmem refcount semantics.
- **Delayed destroy instead of blocking.** Driver teardown can't wait for sockets to drop pages, so the pool outlives the driver as a "zombie" visible via netlink. The cost is a class of warning messages (and occasional bugs) around late returns.

## How It Has Evolved

- **2016–2017** — Jesper Dangaard Brouer proposes a per-device DMA-mapped page allocator (netdev/LSF-MM), arguing every fast driver reinvents recycling.
- **4.18 (2018)** — `page_pool` merged with XDP memory models (`xdp_rxq_info_reg_mem_model()`); mlx5 first user.
- **5.x** — pool DMA mapping (`PP_FLAG_DMA_MAP`), then `PP_FLAG_DMA_SYNC_DEV` (Lorenzo Bianconi, 5.7); inflight accounting and deferred release; NUMA node updates.
- **5.14** — skb recycling (`skb_mark_for_recycle`, `pp_magic`) by Ilias Apalodimas and Matteo Croce, after seven revisions.
- **5.15–5.17** — fragment support (Yunsheng Lin).
- **5.18** — `CONFIG_PAGE_POOL_STATS` (Joe Damato).
- **6.6–6.7** — headers split into `include/net/page_pool/{types,helpers}.h`; `page_pool_alloc()` family with automatic frag/page choice (Yunsheng Lin).
- **6.8** — netlink introspection of pools, including zombie ones (Jakub Kicinski).
- **6.9** — per-CPU system page pools (`page_pool_create_percpu`, `PP_FLAG_SYSTEM_POOL`).
- **6.10–6.12** — `netmem_ref` abstraction and memory-provider hooks (Mina Almasry); devmem TCP with `PP_FLAG_ALLOW_UNREADABLE_NETMEM`.
- **6.15** — io_uring zero-copy receive memory provider; DMA-mapping tracking and unmap-on-destroy (Toke Høiland-Jørgensen).
- **2025–2026** — `netmem_desc` split and `PGTY_netpp` page type replacing `pp_magic`; large (>4K) RX buffers for zcrx; a stream of teardown race fixes (UAF on return, DMA index handling) and GFP zone-flag cleanup.

## Further Reading

1. [page_pool: recycle buffers — LWN (2021)](https://lwn.net/Articles/858414/) — skb recycling design.
2. [Kernel development — LWN (2017)](https://lwn.net/Articles/717387/) — Brouer's original case for a DMA-mapped page allocator.
3. [page_pool: new approach for leak detection and shutdown phase — LWN](https://lwn.net/Articles/930158/)
4. [net: page_pool: add netlink-based introspection — LWN](https://lwn.net/Articles/948718/)
5. [introduce page_pool_alloc() related API — LWN](https://lwn.net/Articles/948381/)
6. [mm, page_pool: introduce a new page type for page pool — LWN](https://lwn.net/Articles/1031554/)
7. [Page Pool API — kernel.org](https://www.kernel.org/doc/html/latest/networking/page_pool.html)
8. [Netmem — kernel.org](https://www.kernel.org/doc/html/latest/networking/netmem.html)

## LKML Highlights

- **"page_pool: recycle buffers" (Matteo Croce / Ilias Apalodimas, 2021)** — added `skb->pp_recycle` and a `struct page` signature. Review with Matthew Wilcox moved the signature to avoid aliasing `page->mapping` and fixed pfmemalloc handling.
- **"page_pool: Track DMA-mapped pages and unmap them when destroying the pool" (Toke Høiland-Jørgensen, Mar 2025)** — solved IOMMU crashes from pages returned after driver unbind by recording every mapping in an xarray. It followed Yunsheng Lin's rejected alternatives, which would have kept per-pool page lists.
- **"net: page_pool: fix UAF in …" (v1–v5, Jul–Aug 2026)** — race between `page_pool_scrub()` on destroy and concurrent `page_pool_put_netmem()` on another CPU. It shows the teardown path is still the pool's sharpest edge.
