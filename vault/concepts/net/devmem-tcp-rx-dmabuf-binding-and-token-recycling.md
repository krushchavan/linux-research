---
title: "Devmem TCP RX: dma-buf Binding and Token Recycling"
category: concept
tags: [net, devmem, dma-buf, page-pool, tcp, zero-copy]
subsystem: net
kernel_version: "6.12 (devmem RX); 2025–26 (rx-page-size, netkit vdev)"
researched: 2026-09-26
status: complete
sources:
  - https://github.com/torvalds/linux/blob/master/net/core/devmem.c
  - https://github.com/torvalds/linux/blob/master/net/core/devmem.h
  - https://github.com/torvalds/linux/blob/master/net/core/netdev-genl.c
  - https://github.com/torvalds/linux/blob/master/net/core/sock.c
  - https://github.com/torvalds/linux/blob/master/net/ipv4/tcp.c
  - https://github.com/torvalds/linux/blob/master/net/ipv4/tcp_ipv4.c
  - https://github.com/torvalds/linux/blob/master/Documentation/netlink/specs/netdev.yaml
  - https://www.kernel.org/doc/html/latest/networking/devmem.html
  - https://lwn.net/Articles/954102/
  - https://lwn.net/Articles/979549/
---

# Devmem TCP RX: dma-buf Binding and Token Recycling

> Deep dive under [[devmem-tcp]] (which gives the feature overview). This note follows the RX path's data structures: how a dma-buf becomes NIC receive buffers, how those buffers reach userspace as tokens, and how every reference is accounted until the memory can be unmapped.

## Purpose

Devmem TCP RX lets a TCP socket's payload land directly in accelerator memory. The mechanics reduce to two ownership problems:
1. **Binding**: turning an opaque dma-buf, a scatterlist of device-memory DMA ranges, into a pool of fixed-size `net_iov` buffers that a NIC's page pool can hand out, attached to specific RX queues, and torn down safely no matter who disappears first.
2. **Token recycling**: giving the application references to buffers the NIC has filled, without copying, and getting them back so the NIC can reuse them, while a buggy or malicious application can't forge, double-free or leak buffers beyond its own socket.

## Mental Model

The binding is a **warehouse lease**. A dma-buf is floor space in another company's building (GPU memory). Binding leases it, divides it into numbered **bays** (net_iovs) with a **bay allocator** (genpool), and gives the delivery trucks (NIC RX queues) the right to fill bays. When a truck fills a bay for your TCP stream, the kernel gives your socket a **claim ticket number** (token). You hand back tickets in bulk (`SO_DEVMEM_DONTNEED`), up to 128 slips and 1024 bays at a time. The lease isn't cancelled until the last bay is empty, even if you've already said you want out. The landlord (dma-buf exporter) sees the space in use until then.

## How It Works

**Step 1 — bind-rx over netlink.** The application sends the **netdev** generic-netlink command `bind-rx` with `ifindex`, `fd` (the dma-buf), a list of `queues` (RX queue ids) and optionally **`rx-page-size`** (a power of two ≥ PAGE_SIZE, telling the NIC to use larger device pages). It requires `CAP_NET_ADMIN` in the netns (`uns-admin-perm`). `netdev_nl_bind_rx_doit()`:
- fetches the per-netlink-socket private state (`genl_sk_priv_get()` → `struct netdev_nl_sock`), because **the binding's lifetime is tied to that netlink socket**: closing it (process exit) unbinds automatically
- locks the netdev (instance lock) and binds each queue through `netif_mp_open_rxq()`, which refuses (with extack messages) when `tcp-data-split` is off, `hds-thresh` isn't 0, an XDP program is attached, the queue already has a memory provider or an AF_XDP socket, the index is out of range, or the queue is leased to a virtual netdev
- finds the DMA device for the queues (`netdev_queue_get_dma_dev()`), which must be the same for all of them
- calls `net_devmem_bind_dmabuf(..., DMA_FROM_DEVICE, fd, niov_shift, priv)` and then `net_devmem_bind_dmabuf_to_queue()` per queue
- replies with the binding `id` (the `dmabuf_id` that will appear in cmsgs).

**Step 2 — building the binding (`net_devmem_bind_dmabuf()`).**
1. `dma_buf_get(fd)`, allocate `struct net_devmem_dmabuf_binding` on the device's NUMA node, init a **`percpu_ref ref`** (released by `net_devmem_dmabuf_binding_release()` → deferred `__net_devmem_dmabuf_binding_free()`).
2. **Attach and map**: a *static* `dma_buf_attach(dmabuf, dma_dev)` (the buffer is pinned by the exporter for the binding's life), then `dma_buf_map_attachment_unlocked(DMA_FROM_DEVICE)` → `binding->sgt` ([[dma-buf-sharing]]).
3. **Carve into net_iovs**: `gen_pool_create(niov_shift)`. For each DMA segment of the sg table, check it's aligned to the niov size (misaligned exporters are rejected with an extack message), allocate a **`struct dmabuf_genpool_chunk_owner`** (`area` = a `net_iov_area` with `base_virtual` = offset of this segment within the dma-buf, `base_dma_addr`, back-pointer to the binding), and add the range to the genpool with `gen_pool_add_owner()`. Allocate the segment's `niovs[]` array and initialize each with `net_iov_init(..., NET_IOV_DMABUF)` and its DMA address (`page_pool_set_dma_addr_netmem()`), so the page pool and driver can program descriptors without knowing it isn't a page ([[netmem-and-net-iov-abstraction]]).
4. Allocate an id in the global `net_devmem_dmabuf_bindings` xarray and add the binding to the netlink socket's list.

**Step 3 — attaching to queues (`net_devmem_bind_dmabuf_to_queue()`).** Builds `pp_memory_provider_params {mp_ops = &dmabuf_devmem_ops, mp_priv = binding, rx_page_size}` and calls **`netif_mp_open_rxq()`**. That records the provider on the `netdev_rx_queue` and **restarts that single queue** through the driver's queue-management ops ([[netdev-queue-management-api]]). The driver allocates a new page pool for the queue, the pool sees `mp_ops` and calls `mp_dmabuf_devmem_init()` (which takes a binding ref and checks the pool is DMA-mapping, `DMA_FROM_DEVICE`, order matches `niov_shift`, and `PP_FLAG_ALLOW_UNREADABLE_NETMEM` is set), and the NIC starts receiving into device memory. The queue is also recorded in `binding->bound_rxqs`.

**Step 4 — buffer supply.** When the driver refills RX descriptors, the page pool calls **`mp_dmabuf_devmem_alloc_netmems()`** → `net_devmem_alloc_dmabuf()`: `gen_pool_alloc_owner()` hands out one niov-sized DMA range plus its chunk owner, the index gives the `net_iov`, and `page_pool_set_pp_info()` stamps the pool. The pool's hold counter increments like for a page. The NIC DMAs payload into device memory and headers into ordinary pages (header split). The driver attaches the net_iov as an skb frag, making the skb `unreadable`.

**Step 5 — delivering tokens (`tcp_recvmsg_dmabuf()`).** `recvmsg(fd, msg, MSG_SOCK_DEVMEM)` calls into `tcp_recvmsg_locked()`, which for unreadable skbs calls `tcp_recvmsg_dmabuf()`. For each skb:
- the **linear part** (bytes that landed in host memory: headers the NIC didn't split, or small packets) is *copied* into the iov and reported with an **`SCM_DEVMEM_LINEAR`** cmsg carrying just `frag_size`
- for each **frag**, it verifies the frag is a devmem net_iov (`net_is_devmem_iov()`; anything else fails with `-ENODEV` rather than leaking another provider's memory), computes `frag_offset = net_iov_virtual_addr(niov) + frag offset` (the byte offset *within the dma-buf*, which the application uses directly in GPU kernels), allocates a **token** and emits an **`SCM_DEVMEM_DMABUF`** cmsg `{frag_offset, frag_size, frag_token, dmabuf_id}`. It then takes a page-pool reference on the net_iov (`pp_ref_count++`), so the skb can be freed while the buffer stays alive for userspace.

**Token allocation, batched.** Tokens are indexes in the socket's **`sk->sk_user_frags`** xarray (`XA_FLAGS_ALLOC1`, initialized in `tcp_init_sock()`). To avoid taking the xarray lock per frag, `tcp_xa_pool_refill()` pre-allocates up to `MAX_SKB_FRAGS` ids as `XA_ZERO_ENTRY` placeholders under one lock. `tcp_xa_pool_commit()` then `__xa_cmpxchg()`es the used ones to the actual `netmem_ref` and erases unused reservations. A token is therefore a socket-local, unforgeable handle: userspace can only name entries the kernel put in *its* socket's xarray.

**Step 6 — returning tokens (`SO_DEVMEM_DONTNEED`).** `setsockopt(fd, SOL_SOCKET, SO_DEVMEM_DONTNEED, tokens, n * sizeof(struct dmabuf_token))` → `sock_devmem_dontneed()`: at most **`MAX_DONTNEED_TOKENS` (128)** `{token_start, token_count}` ranges and **`MAX_DONTNEED_FRAGS` (1024)** frags per call. Under `xa_lock_bh`, each token is `__xa_erase()`d. A missing entry (already returned, never issued) is silently skipped, so double-frees are impossible. Collected netmems are released in batches of 16 *outside* the lock with `napi_pp_put_page()`, dropping the page-pool reference. The return value is the number of frags freed, and the application must loop if it had more.

**Step 7 — recycling to the NIC.** When a net_iov's page-pool refcount reaches the pool's baseline, the pool recycles it into its cache (fast path, reused for the next RX descriptor) or, if the pool is being destroyed, calls **`mp_dmabuf_devmem_release_page()`**, which clears pp info and returns the range to the genpool (`net_devmem_free_dmabuf()`). It returns `false` so the page pool never `put_page()`s a net_iov.

**Socket close.** `tcp_v4_destroy_sock()` → `tcp_release_user_frags()` walks `sk_user_frags` and puts every outstanding token's netmem. An application that dies without returning tokens doesn't leak device memory beyond the socket's lifetime.

**Teardown ordering.** Unbinding (netlink socket closed, or explicit) runs `net_devmem_unbind_dmabuf()`: remove from the global xarray, and for each bound queue `netif_mp_close_rxq()` (restart the queue with ordinary pages). The page pools that used the binding keep their **binding refs** (taken in `mp_dmabuf_devmem_init`) until every net_iov they handed out has come back. net_iovs still held by sockets or stuck in skbs (e.g. awaiting retransmit on TX bindings) also pin the binding via `net_devmem_get_net_iov()`. Only when the percpu ref drops to zero does the deferred free unmap the attachment, detach, `dma_buf_put()`, and destroy the genpool. The GPU memory is guaranteed idle from the NIC's side before the exporter can reuse it.

**Observability.** `netdev` netlink `queue-get` and `page-pool-get` report the `dmabuf` id attached to a queue or pool (`mp_dmabuf_devmem_nl_fill()`), and `ncdevmem` (selftests) exercises the whole flow.

## Key Data Structures

**`struct net_devmem_dmabuf_binding`** (`net/core/devmem.h`)
- `dmabuf`, `attachment`, `sgt` — the imported and mapped dma-buf
- `dev` (physical NIC), `vdev` (opaque cookie for a virtual device such as netkit that bind-tx was called on)
- `chunk_pool` — genpool of niov-sized DMA ranges
- `ref` — percpu ref: user (netlink), each page pool, each in-flight net_iov
- `list`, `bound_rxqs` — netlink socket membership and bound queues
- `id` — `dmabuf_id` reported in cmsgs
- `direction` — `DMA_FROM_DEVICE` (RX) or `DMA_TO_DEVICE` (TX)
- `tx_vec` — TX-only VA→net_iov lookup
- `niov_shift`, `unbind_w`

**`struct dmabuf_genpool_chunk_owner`** — `area` (`net_iov_area`: `niovs[]`, `num_niovs`, `base_virtual`), `binding`, `base_dma_addr`: one sg segment's worth of net_iovs.

**`sk->sk_user_frags`** (`struct sock`) — xarray token → netmem for this socket's outstanding devmem buffers.

**`struct tcp_xa_pool`** (`net/ipv4/tcp.c`) — per-recvmsg batch of reserved tokens and netmems.

**UAPI** — `struct dmabuf_cmsg {frag_offset, frag_size, frag_token, dmabuf_id, flags}`, `struct dmabuf_token {token_start, token_count}`; `SCM_DEVMEM_DMABUF`, `SCM_DEVMEM_LINEAR`, `SO_DEVMEM_DONTNEED`, `MSG_SOCK_DEVMEM`.

## Key Functions / Entry Points

- **`netdev_nl_bind_rx_doit()`** (`net/core/netdev-genl.c`) — netlink entry
- **`net_devmem_bind_dmabuf()` / `net_devmem_bind_dmabuf_to_queue()` / `net_devmem_unbind_dmabuf()`** (`devmem.c`)
- **`mp_dmabuf_devmem_init()` / `_alloc_netmems()` / `_release_page()` / `_destroy()` / `_nl_fill()` / `_uninstall()`** — `dmabuf_devmem_ops` provider
- **`net_devmem_alloc_dmabuf()` / `net_devmem_free_dmabuf()`** — genpool alloc and free
- **`tcp_recvmsg_dmabuf()` / `tcp_xa_pool_refill()` / `tcp_xa_pool_commit()`** (`net/ipv4/tcp.c`)
- **`sock_devmem_dontneed()`** (`net/core/sock.c`)
- **`tcp_release_user_frags()`** (`net/ipv4/tcp_ipv4.c`) — close-time cleanup

## Important Flags & Config Options

- `CONFIG_NET_DEVMEM` (needs `CONFIG_DMA_SHARED_BUFFER`, `CONFIG_GENERIC_ALLOCATOR`, `CONFIG_PAGE_POOL`)
- netlink `bind-rx` attributes: `ifindex`, `fd`, `queues`, `rx-page-size`; reply `id`
- Limits: `MAX_DONTNEED_TOKENS` = 128, `MAX_DONTNEED_FRAGS` = 1024 per `SO_DEVMEM_DONTNEED`
- NIC prerequisites: `ethtool -G tcp-data-split on`, n-tuple steering to bound queues, RSS excluding them ([[header-split-and-flow-steering-for-zero-copy-rx]]); no XDP on the device
- Driver: `PP_FLAG_ALLOW_UNREADABLE_NETMEM`, queue-management ops

## Interactions with Other Subsystems

- **↑ Userspace**: YNL / netlink `bind-rx`; `recvmsg(MSG_SOCK_DEVMEM)` + cmsg parsing; `setsockopt(SO_DEVMEM_DONTNEED)`; GPU runtimes consume `frag_offset`s ([[netdev-netlink-family]])
- **→ dma-buf**: static attach, mapping and pinning for the binding's lifetime ([[dma-buf-sharing]])
- **→ page pool / memory providers / netmem** ([[page-pool]], [[netmem-and-net-iov-abstraction]])
- **→ queue management**: per-queue restart to install and remove the provider ([[netdev-queue-management-api]])
- **→ TCP / sockets**: unreadable skbs, `tcp_recvmsg_dmabuf`, per-socket token xarray ([[tcp-ip-stack]], [[sk-buff]])
- **vs io_uring zcrx**: same provider framework, but zcrx returns buffers through a shared-memory refill ring with per-niov user refcounts, while devmem uses per-socket tokens and a setsockopt ([[zero-copy-rx-zcrx]])
- **vs RDMA GPUDirect**: RDMA registers the dma-buf as an MR and the NIC's transport places data by rkey. Devmem keeps TCP in the kernel and places by RX queue plus header split ([[memory-registration-and-ib-umem]])

## Design Decisions & Tradeoffs

- **Lifetime tied to a netlink socket.** No persistent kernel object survives a crashed process, and unbinding is automatic. Orchestrators must keep that socket open for as long as the binding is needed.
- **Static (pinned) dma-buf attach.** Simple and works with any exporter, but the GPU memory can't be evicted while bound. Dynamic, revocable attach for NIC RX remains future work (see the 2026 dma-buf revoke discussion).
- **genpool of fixed-size chunks.** Cheap O(1)-ish allocation and trivial niov↔offset mapping, but it requires exporters to supply niov-aligned segments. `rx-page-size` lets larger devices pages cut per-packet descriptor overhead.
- **Socket-local tokens instead of offsets.** Userspace can't return buffers it wasn't given, and returns are cheap bulk erases. The cost is a syscall per batch and the 128/1024 caps; slow token returns starve the queue and cause drops.
- **Linear-data fallback via SCM_DEVMEM_LINEAR.** Keeps correctness when header split doesn't separate everything, at the cost of mixed cmsg handling in the application.

## How It Has Evolved

- **2023** — RFCs (Mina Almasry); design debate on struct pages vs a new memory type
- **6.12 (2024)** — devmem RX merged: bind-rx, genpool binding, tokens, `SO_DEVMEM_DONTNEED`, gve support
- **6.13–6.15** — provider ops generalized with io_uring zcrx; mlx5, bnxt, fbnic support; batched token allocation (`tcp_xa_pool`)
- **6.16** — devmem TX (bind-tx, `tx_vec`) ([[devmem-tcp-tx]])
- **2025–26** — `rx-page-size` large device pages; netkit/virtual-device `vdev` binding for containers; per-queue DMA device lookup

## Further Reading

- kernel.org — [Device Memory TCP](https://www.kernel.org/doc/html/latest/networking/devmem.html)
- LWN — [Device Memory TCP](https://lwn.net/Articles/954102/); [Direct-to-device networking](https://lwn.net/Articles/979549/)
- Selftest — `tools/testing/selftests/drivers/net/hw/ncdevmem.c`
- Related: [[devmem-tcp]], [[devmem-tcp-tx]], [[netmem-and-net-iov-abstraction]], [[zero-copy-rx-zcrx]], [[dma-buf-sharing]]

## LKML Highlights

- **"Device Memory TCP" v1x (Mina Almasry, 2023–24)** — the RX series. Reviewers pushed the netlink-socket-scoped binding lifetime, socket-local tokens (instead of letting userspace name offsets) and the dontneed limits as defences against misuse.
- **Batched token allocation (2024–25)** — replaced per-frag `xa_alloc` under lock with the `tcp_xa_pool` reserve-then-commit scheme, a measurable win at 100G+ packet rates.
- **`rx-page-size` for bind-rx (2025–26)** — allowed large device pages, with an extack error for non-power-of-two sizes and misaligned dma-buf segments. (Message-ids unavailable: lore was unreachable this session.)
