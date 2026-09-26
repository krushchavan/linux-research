---
title: "netmem and net_iov: Non-Page Memory in the Network Stack"
category: concept
tags: [net, netmem, net-iov, page-pool, devmem, zero-copy]
subsystem: net
kernel_version: "6.10 (netmem_ref); 6.12 (net_iov, unreadable skbs, devmem TCP); 6.17 (netmem_desc split)"
researched: 2026-09-26
status: complete
sources:
  - https://github.com/torvalds/linux/blob/master/include/net/netmem.h
  - https://github.com/torvalds/linux/blob/master/include/net/page_pool/memory_provider.h
  - https://github.com/torvalds/linux/blob/master/Documentation/networking/netmem.rst
  - https://github.com/torvalds/linux/blob/master/include/linux/skbuff.h
  - https://lwn.net/Articles/955144/
  - https://lwn.net/Articles/954102/
  - https://lwn.net/Articles/1032095/
  - https://lkml.org/lkml/2025/7/14/691
  - https://lwn.net/Articles/1004591/
---

# netmem and net_iov: Non-Page Memory in the Network Stack

## Purpose

For decades the Linux network stack assumed every packet buffer was a **`struct page`**: drivers allocate pages from the page pool, skb frags (`skb_frag_t`) point at pages, TCP copies from pages, and freeing means `put_page()`. Zero-copy receive into **GPU memory** (a dma-buf with no struct pages) or into a **user-registered io_uring area** (where the buffer's lifetime is governed by userspace returns, not page refcounts) breaks that assumption. **netmem** is the abstraction that lets the stack carry "a network buffer" without knowing whether it is a real page or something else. **`net_iov`** is the "something else": a small descriptor for a chunk of memory owned by a **memory provider** (devmem TCP's dma-buf binding, or io_uring zcrx). With these, one driver implementation of page-pool RX serves ordinary traffic, [[devmem-tcp]] and [[zero-copy-rx-zcrx|io_uring zcrx]].

## Mental Model

`netmem_ref` is a **tagged claim ticket**. Most tickets are for ordinary luggage (pages): the stack can open them, weigh them (`page_address`), and throw them away with the normal rules. Some tickets, marked with a small tag in the low bit, are for **sealed crates stored off-site** (`net_iov`): the stack can track them, count them, pass them along and hand them back to their owner (the memory provider), but it **cannot open them** because the bytes may be in GPU memory. Code that must look inside (checksum, copy to user, BPF reading packet data) checks "is this readable?" first. Everything else, such as TCP reassembly, reference counting and recycling, works the same for both kinds.

## How It Works

**The handle: `netmem_ref`.** `typedef unsigned long __bitwise netmem_ref`. If the low bit (`NET_IOV` = `0x01`) is clear, it's a `struct page *`. If set, clearing it gives a `struct net_iov *`. Pages are at least word-aligned, so the bit is free. Conversions: `page_to_netmem()`, `net_iov_to_netmem()`, `netmem_to_page()` (warns on a net_iov), `netmem_to_net_iov()`, `netmem_is_net_iov()`. `__bitwise` makes sparse flag accidental use as a pointer. Most code never converts: the page pool and skb APIs take `netmem_ref` directly (`page_pool_alloc_netmem()`, `page_pool_put_netmem()`, `page_pool_get_dma_addr_netmem()`, `skb_add_rx_frag_netmem()`), and `skb_frag_t` stores a netmem.

**The shared layout: `struct netmem_desc`.** The page pool keeps per-buffer metadata: owning pool `pp`, `pp_magic` signature, `dma_addr`, `pp_ref_count`. For pages this metadata lives *inside struct page*, overlaying fields the page pool may use. Since 6.17 (Byungchul Park's "Split netmem from struct page") that overlay is formalized as **`struct netmem_desc`**, with `static_assert`s pinning each field to the same offset as in `struct page`, and bounded to end before `_refcount`. It is the page pool's own "memdesc", following the pattern of folios and slabs as part of mm's long-term plan to shrink `struct page` to a pointer. `struct net_iov` *starts* with a `netmem_desc`, so page-pool code can read `pp`, `dma_addr` and `pp_ref_count` through the same accessors whether the netmem is a page or a net_iov. There is no type switch on the hot path.

**`struct net_iov` and areas.** A net_iov is `{ struct netmem_desc desc; enum net_iov_type type; struct net_iov_area *owner; }`, where `type` is `NET_IOV_DMABUF` (devmem) or `NET_IOV_IOURING` (zcrx). Net_iovs come in arrays inside a **`struct net_iov_area`** (`niovs[]`, `num_niovs`, `base_virtual` = offset of this chunk within the dma-buf). `net_iov_idx()` gives a niov's index, which is how providers map a niov back to "offset N in the user's buffer" for CQEs or tokens. A net_iov has **no normal refcount**: `netmem_ref_count()` returns 1. Lifetime is governed by the page-pool refcount (`pp_ref_count`) plus provider-specific references such as zcrx user refs or devmem socket tokens.

**Where net_iovs come from: memory providers.** A page pool normally allocates pages from the buddy allocator. If its RX queue has a **memory provider** bound (`pp->mp_ops`), allocation and release are delegated through `struct memory_provider_ops`:
- `alloc_netmems(pool, gfp)` — return a netmem (fill the pool's alloc cache)
- `release_netmem(pool, netmem)` — take back a buffer the pool is done with
- `init` / `destroy` — pool lifecycle, where providers validate the pool (DMA direction, order)
- `nl_fill` — report the binding in netdev netlink `queue-get`
- `uninstall` — called when the queue or device goes away

Providers stamp buffers with `net_mp_niov_set_page_pool()` / `net_mp_niov_clear_page_pool()` and set DMA addresses with `net_mp_niov_set_dma_addr()`. Binding a provider to a queue happens through the netdev queue-management API, which restarts the queue so its page pool is rebuilt with the provider ([[netdev-queue-management-api]], [[page-pool]]).

**Readable vs unreadable.** A net_iov backed by a dma-buf can't be read by the CPU. The stack models this at skb level: when a frag with unreadable netmem is attached, `skb->unreadable` is set, and `skb_frags_readable(skb)` returns false. Every path that would touch payload bytes checks it:
- `skb_copy_bits`, checksum helpers and `skb_linearize` fail or skip
- TCP won't coalesce readable and unreadable skbs, so ranges stay homogeneous
- `tcp_recvmsg` refuses unreadable data unless the socket asked for `MSG_SOCK_DEVMEM`
- XDP and BPF packet access see only the readable (header) part
- GRO, netfilter and TC work on headers, which live in ordinary pages thanks to header split.

`netmem_address()` returns NULL for net_iovs, and drivers must handle that (`Documentation/networking/netmem.rst`). io_uring areas of *host* memory are technically readable and zcrx marks its ifq `kern_readable` for copy fallback, but the stack still treats net_iov frags opaquely and hands them to the owning provider.

**Driver requirements (RX).** Per `netmem.rst`, a netmem-capable driver must: use the page pool; support `tcp-data-split` (so headers go to readable memory); use the netmem page-pool APIs and track `netmem_ref`s rather than `struct page *`; set `PP_FLAG_DMA_MAP` and `PP_FLAG_DMA_SYNC_DEV` (only the pool knows whether a provider's memory needs mapping or syncing); set `PP_FLAG_ALLOW_UNREADABLE_NETMEM` exactly when header split is on; never assume readable memory; use `page_pool_dma_sync_netmem_for_cpu()`; and avoid private recycling schemes that hold struct pages. Supporting drivers include bnxt, mlx5, gve, fbnic, idpf, ice and others.

**Driver requirements (TX).** For devmem TX, skbs carry net_iov frags whose DMA addresses came from a dma-buf mapping, so drivers must not pass them to `dma_unmap_page()`. They use `netmem_dma_unmap_page_attrs()` / `netmem_dma_unmap_addr_set()`, which skip unmapping for provider-owned addresses, and declare `netdev->netmem_tx = NETMEM_TX_DMA` (or `NETMEM_TX_NO_DMA` for virtual devices) ([[devmem-tcp-tx]]).

## Key Data Structures

**`netmem_ref`** (`include/net/netmem.h`) — tagged `unsigned long`: page pointer, or net_iov pointer | `NET_IOV`.

**`struct netmem_desc`** — `_flags`, `pp_magic`, `pp`, `_pp_mapping_pad`, `dma_addr`, `pp_ref_count`, laid out to overlay `struct page`.

**`struct net_iov`** — `desc` (netmem_desc), `type` (`NET_IOV_DMABUF` / `NET_IOV_IOURING`), `owner` (area).

**`struct net_iov_area`** — `niovs[]`, `num_niovs`, `base_virtual`.

**`struct memory_provider_ops`** (`include/net/page_pool/memory_provider.h`) — `alloc_netmems`, `release_netmem`, `init`, `destroy`, `nl_fill`, `uninstall`.

**`struct sk_buff` field `unreadable`** — at least one frag is unreadable netmem.

## Key Functions / Entry Points

- **`page_to_netmem()` / `net_iov_to_netmem()` / `netmem_to_page()` / `netmem_to_net_iov()` / `netmem_is_net_iov()`**
- **`netmem_address()` / `netmem_get_dma_addr()` / `netmem_is_pfmemalloc()`** — safe accessors
- **`page_pool_alloc_netmem()` / `page_pool_put_netmem()` / `page_pool_ref_netmem()` / `page_pool_unref_netmem()` / `page_pool_fragment_netmem()`**
- **`skb_add_rx_frag_netmem()` / `skb_frags_readable()`**
- **`net_mp_niov_set_page_pool()` / `net_mp_niov_clear_page_pool()` / `net_mp_niov_set_dma_addr()`** — provider helpers
- **`netmem_dma_unmap_page_attrs()`** — TX unmap that respects provider memory

## Important Flags & Config Options

- `CONFIG_PAGE_POOL`; static key `page_pool_mem_providers` (enabled when any provider is bound, so the non-provider fast path costs nothing)
- `PP_FLAG_ALLOW_UNREADABLE_NETMEM`, `PP_FLAG_DMA_MAP`, `PP_FLAG_DMA_SYNC_DEV`
- `netdev->netmem_tx`: `NETMEM_TX_DMA` / `NETMEM_TX_NO_DMA`
- ethtool `tcp-data-split` (prerequisite for unreadable RX)

## Interactions with Other Subsystems

- **→ mm**: `netmem_desc` is the page pool's memdesc, part of the struct-page diet (folio, slab, ptdesc …) led by Matthew Wilcox's memdesc plan ([[folio]])
- **→ page pool**: providers plug into allocation and release; netmem APIs throughout ([[page-pool]])
- **→ skb / TCP**: unreadable frags, coalescing rules, `MSG_SOCK_DEVMEM` ([[sk-buff]], [[tcp-ip-stack]])
- **← devmem TCP**: `NET_IOV_DMABUF` provider backed by a dma-buf binding ([[devmem-tcp]], [[devmem-tcp-rx-dmabuf-binding-and-token-recycling]])
- **← io_uring zcrx**: `NET_IOV_IOURING` provider backed by user or dma-buf areas ([[zero-copy-rx-zcrx]])
- **← drivers**: conversion to netmem APIs is the gate for both features

## Design Decisions & Tradeoffs

- **Tagged handle over a new container type.** A pointer-sized tagged value keeps `skb_frag_t` and page-pool arrays the same size and makes the common page case a no-op conversion. The cost is that type safety relies on `__bitwise` and helpers rather than the compiler's type system, and every "open the buffer" site must be audited.
- **Unreadability as a first-class skb property.** Rather than forbidding GPU memory from entering the stack, the stack learned to carry bytes it can't read, with header split guaranteeing that protocol processing still has readable headers. This was the key insight that made devmem TCP acceptable to netdev maintainers, versus a TOE-style offload.
- **Shared provider interface for devmem and io_uring.** Netdev maintainers required one mechanism, not two, which delayed both features but gave drivers a single conversion.
- **Page-pool metadata as its own descriptor.** Splitting `netmem_desc` from `struct page` aligns networking with mm's memdesc direction and lets net_iov share accessors without faking pages. The early RFC plan of making net_iovs look like struct pages was dropped.

## How It Has Evolved

- **Late 2023** — Mina Almasry's "Abstract page from net stack" RFC and devmem TCP RFCs; `page_pool_iov` as the first non-page type
- **6.10 (2024)** — `netmem_ref` merged; page pool and skb frags converted
- **6.12 (2024)** — `net_iov`, memory providers, unreadable skbs, devmem TCP RX
- **6.14–6.15** — provider ops generalized (`nl_fill`, `uninstall`); io_uring zcrx as a second provider
- **6.15–6.16** — devmem TX; `netmem_tx` driver declaration; netmem TX DMA helpers
- **6.17 (2025)** — `struct netmem_desc` split from struct page (Byungchul Park); drivers access `pp` through netmem_desc
- **2025–26** — more drivers converted; larger `rx_page_size` for providers; continued memdesc work in mm

## Further Reading

- kernel.org source — [`Documentation/networking/netmem.rst`](https://github.com/torvalds/linux/blob/master/Documentation/networking/netmem.rst) (driver requirements)
- LWN — [Abstract page from net stack](https://lwn.net/Articles/955144/) (2023)
- LWN — [Device Memory TCP](https://lwn.net/Articles/954102/) (2023)
- LWN — [The rest of the 6.17 merge window](https://lwn.net/Articles/1032095/) (netmem_desc)
- LKML — [Split netmem from struct page v10](https://lkml.org/lkml/2025/7/14/691)
- Related: [[page-pool]], [[devmem-tcp]], [[zero-copy-rx-zcrx]], [[sk-buff]], [[folio]]

## LKML Highlights

- **`<20231214020530.2267499-1-almasrymina@google.com>`** — "Abstract page from net stack" RFC (Mina Almasry). Argued that drivers, page pool and `skb_frag_t` must stop assuming struct page before non-page memory can flow. It began as a no-op wrapper to allow gradual conversion.
- **"Split netmem from struct page" v10–v12 (Byungchul Park, July 2025)** — introduced `struct netmem_desc` mirroring the page-pool fields of `struct page` and converted drivers (mlx4, mlx5, idpf, iavf, mt76, netdevsim …) to access `pp` through it. Framed as the page pool's step in the mm memdesc effort that Matthew Wilcox had begun earlier.
- **Devmem TCP v1x series (Mina Almasry, 2024)** — added `net_iov`, memory-provider hooks and `skb->unreadable`. Reviews centred on making unreadable frags safe everywhere payload might be touched.
