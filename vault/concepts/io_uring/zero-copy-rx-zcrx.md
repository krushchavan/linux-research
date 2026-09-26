---
title: "io_uring Zero-Copy Receive (zcrx) Internals"
category: concept
tags: [io_uring, zcrx, zero-copy, page-pool, net-iov, memory-provider]
subsystem: io_uring
kernel_version: "6.15 (zcrx); 6.16+ (dma-buf areas, rx_buf_len); 2025–26 (ifq export/import, events, multi-area, NODEV)"
researched: 2026-09-26
status: complete
sources:
  - https://github.com/torvalds/linux/blob/master/io_uring/zcrx.c
  - https://github.com/torvalds/linux/blob/master/io_uring/zcrx.h
  - https://github.com/torvalds/linux/blob/master/include/uapi/linux/io_uring/zcrx.h
  - https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html
  - https://lwn.net/Articles/994603/
  - https://lwn.net/Articles/1043867/
  - https://lwn.net/Articles/1025247/
  - https://netdevconf.info/0x17/sessions/talk/zero-copy-receive-using-io_uring.html
---

# io_uring Zero-Copy Receive (zcrx) Internals

> Companion to the broader [[io-uring-zero-copy-networking]] note (SEND_ZC + zcrx overview). This note goes deeper on zcrx's buffer lifecycle, reference counting, provider hooks and the 2025–26 control-plane additions.

## Purpose

zcrx lets a TCP application receive payload bytes **without any copy**: the NIC DMAs packet payloads directly into memory the application registered (host memory or a dma-buf such as GPU memory), the kernel still runs the full TCP/IP stack on the headers, and the application gets completion entries pointing at the bytes in place. The hard problems aren't the fast path but **ownership**. A receive buffer passes between four parties (the NIC's RX ring, the page pool, the TCP socket's skb frags, and userspace), and may be referenced by several at once. It must never be recycled to the NIC while userspace still reads it, and must never leak when any party disappears (process exit, queue reset, device unplug). zcrx's design is mostly a careful answer to that.

## Mental Model

Picture a **library with reading rooms**. The *area* is the library's shelf space, cut into equal **slots** (`net_iov`s). The NIC is the delivery service that fills empty slots. The page pool is the librarian who hands empty slots to delivery. TCP is the catalogue that tracks which slots hold which parts of which stream. When the application is told "your data is in slot 17, offset 300", it has **checked out** slot 17 (a *user reference*). Returning it means writing "17" on a slip in the **return box** (refill ring). The librarian empties the return box whenever delivery asks for more slots, and only re-shelves a slot when *every* checkout on it has been returned and the catalogue has let go too. If the reader leaves town (ring closed), the librarian **scrubs**: forcibly takes back every slot that reader still held.

## How It Works

**Registration (`io_register_zcrx()`).** Preconditions: the ring uses `IORING_SETUP_DEFER_TASKRUN` (all completion work runs in the submitting task, so refill and CQE posting need no cross-task locking) and 32-byte CQEs (`CQE32` or `CQE_MIXED`) to fit the zcrx CQE extension. The user passes `struct io_uring_zcrx_ifq_reg`: `if_idx`/`if_rxq` (which NIC queue), `rq_entries` and `region_ptr` (the refill ring's memory region), `area_ptr` → `struct io_uring_zcrx_area_reg`, optional `rx_buf_len`, optional `event_desc`, and `flags`. The kernel:
1. allocates `struct io_zcrx_ifq` (refcounted: `refs` for kernel users such as page pools, `user_refs` for rings and exported fds)
2. maps the **refill ring** region (`io_allocate_rbuf_ring()`), with head, tail and an array of `struct io_uring_zcrx_rqe {off, len}`, and returns offsets in `reg.offsets`
3. **binds the netdev** (`zcrx_register_netdev()`): looks up the device in the caller's netns under the instance lock, finds the queue's DMA device (`netdev_queue_get_dma_dev()`, which may differ per queue on multi-function devices), creates the area, and calls **`netif_mp_open_rxq(netdev, rxq, {mp_ops = &io_uring_pp_zc_ops, mp_priv = ifq})`**. That installs io_uring as the **memory provider** for that RX queue and restarts the queue through the queue-management API, so the driver builds a new page pool that asks io_uring for buffers ([[page-pool]], [[netdev-queue-management-api]]).

**Areas and `net_iov`s (`__zcrx_create_area()`).** An area is either:
- **user memory** (`io_import_umem()`): pinned with GUP, charged to the user's locked memory (`io_count_account_pages()` counts compound pages once), DMA-mapped for the NIC. The kernel can read it (`kern_readable`), which the copy fallback requires.
- **a dma-buf** (`IORING_ZCRX_AREA_DMABUF`, `io_import_dmabuf()`): `dma_buf_get()` → `dma_buf_attach()` → `dma_buf_map_attachment_unlocked(DMA_FROM_DEVICE)`. Payloads land in GPU or accelerator memory. The kernel can't read it, so no copy fallback ([[dma-buf-sharing]]).

The area is chopped into `net_iov`s of `1 << niov_shift` bytes: PAGE_SIZE by default, larger if `rx_buf_len` is requested and the memory is physically contiguous enough (`io_area_max_shift()`, `ZCRX_FEATURE_RX_PAGE_SIZE`), in which case the page pool is told `rx_page_size` so the driver posts large RX buffers. Each `net_iov` gets its DMA address (`io_populate_area_dma()`) and a slot in the area's `user_refs[]` array, and all start on the area's **freelist**. An ifq can have **multiple areas** (`ZCRX_CTRL_ADD_AREA`, 2026), each identified by an area id encoded in the top 16 bits of offsets (`IORING_ZCRX_AREA_SHIFT` = 48).

**Buffer supply: the provider hooks.** The driver's NAPI poll refills its RX descriptors from its page pool, and when the pool's cache is empty it calls the provider's `alloc_netmems` → **`io_pp_zc_alloc_netmems()`**:
1. **Fast path: drain the refill ring** (`io_zcrx_ring_refill()`, under `rq.lock`). For each RQE the application wrote, `io_parse_rqe()` validates the area id and offset, then `zcrx_put_refill_niov()` drops that many **user refs** (`io_zcrx_put_niov_uref()`, a cmpxchg loop that refuses to go below zero, so a buggy or malicious app returning a buffer twice can't underflow) and then the matching **page-pool refs** (`page_pool_unref_netmem()`). Only when the pool ref reaches zero does the `net_iov` become allocatable again. Consecutive RQEs for the same niov are batched into one decrement. Finally the consumed head is published with `smp_store_release()`.
2. **Slow path: the freelist** (`io_zcrx_refill_slow()`, under `alloc_lock`) walks areas for never-used or scrubbed niovs and binds them to this pool (`net_mp_niov_set_page_pool()`).
3. **Out of buffers**: fire `ZCRX_EVENT_ALLOC_FAIL` (below) and return 0. The driver drops packets or stalls that queue until the app returns buffers, and backpressure is visible to TCP as loss.

Returned buffers are synced for device (`zcrx_sync_for_device()`) before the NIC reuses them. `io_pp_zc_release_netmem()` handles buffers the pool gives up (queue teardown) by putting them back on the freelist. `io_pp_zc_init()` refuses pools that don't match: wrong DMA device, not DMA-mapping, wrong order vs `niov_shift`, or not `DMA_FROM_DEVICE`.

**Receiving (`io_zcrx_recv()`).** `IORING_OP_RECV_ZC` (multishot) on a socket whose flow is steered to the queue runs `tcp_read_sock()` with an actor (`io_zcrx_recv_skb()`). For each skb frag:
- if it's a `net_iov` belonging to *this* ifq (checked via `netmem_is_net_iov` and the pool's `mp_priv`), take a **user ref** (`io_zcrx_get_niov_uref()`), take a page-pool frag ref, and post a CQE with `io_zcrx_queue_cqe()`: `res = len`, `IORING_CQE_F_MORE`, and in the 16-byte extension `off = area token | (niov index << niov_shift) + frag offset`. The application reads at `area_base + (off & ~IORING_ZCRX_AREA_MASK)`.
- if it's an ordinary page (the packet arrived on another queue, or the linear head part of the skb), **copy** it into a fallback niov (`io_alloc_fallback_niov()` from the freelist, `io_zcrx_copy_chunk()`/`io_copy_page()`) and post the same CQE format. That fires `ZCRX_EVENT_COPY` and bumps `zcrx_stats.copy_count`/`copy_bytes`. Correctness never depends on steering, and the stats make silent degradation observable.

CQEs are posted with `io_defer_get_uncommited_cqe()`, which is cheap because DEFER_TASKRUN guarantees single-task posting.

**Events (2026).** `zcrx_event_desc` in registration names a `user_data` and a mask of event types (`ZCRX_EVENT_ALLOC_FAIL`, `ZCRX_EVENT_COPY`), plus an optional stats area in the refill region. `zcrx_send_notif()` allocates a bare request and queues task_work to post an auxiliary CQE on the ifq's `master_ctx`. Each event fires **once** until re-armed with `ZCRX_CTRL_ARM_EVENT`, so a buffer drought doesn't flood the CQ.

**Sharing and control (`IORING_REGISTER_ZCRX_CTRL`, 2025–26).**
- **Export / import**: `ZCRX_CTRL_EXPORT` wraps the ifq in an anonymous `"[zcrx]"` file and returns an fd. Another ring (in any process the fd reaches) registers with `ZCRX_REG_IMPORT`, passing that fd in `if_idx`, and gets its own `zcrx_id` for the same ifq. Several rings (e.g. per-thread event loops) can then share one hardware queue binding and area. Refill-ring coordination between them is userspace's job.
- **`ZCRX_REG_NODEV`**: an ifq with no netdev. All data is copied into the area, which gives the zcrx API and buffer-return semantics on any socket (for testing, or uniform application code). Refill entries may need explicit `ZCRX_CTRL_FLUSH_RQ`.
- **`ZCRX_CTRL_FLUSH_RQ`** consumes pending refill entries outside the allocation path. **`ZCRX_CTRL_ADD_AREA`** grows the buffer space.

**Teardown.** Unregistering (ring exit, or the last user ref dropping) runs:
1. **`io_close_queue()`**: under the netdev instance lock, `netif_mp_close_rxq()` uninstalls the provider and restarts the queue with ordinary pages, and the areas are DMA-unmapped (`io_zcrx_unmap_areas()`) while the device is still guaranteed present.
2. **`io_zcrx_scrub()`**: for every niov whose `user_refs` is non-zero, atomically take all of them (`atomic_xchg(..., 0)`), drop the matching page-pool refs, and return the niov if nothing else holds it. The application's outstanding buffers are revoked.
3. Refcounts on the ifq (page pools hold `refs` via `io_pp_zc_init`/`destroy`) keep the structure alive until the last in-flight skb referencing a niov is freed. Only then is area memory unpinned or the dma-buf detached.

If the netdev goes away first, the core calls the provider's `uninstall` (`io_pp_uninstall()`) and zcrx drops its binding. The netlink `queue-get` output shows io_uring as the provider (`io_pp_nl_fill()`).

## Key Data Structures

**`struct io_zcrx_ifq`** (`io_uring/zcrx.h`)
- `areas`, `nr_areas`, `niov_shift` — buffer space and chunk size
- `kern_readable` — copy fallback possible (false for dma-buf)
- `rq` (`struct zcrx_rq`: ring pointer, `rqes`, `cached_head`, `lock`) — the refill ring
- `alloc_lock` — freelist allocation
- `if_rxq`, `dev`, `netdev`, `netdev_tracker` — binding
- `refs` (kernel users incl. page pools) / `user_refs` (rings, exported fds)
- `pp_lock` — page pool and net configuration
- `master_ctx`, `allowed_notif_mask`, `fired_notifs`, `notif_data`, `notif_stats` — events

**`struct io_zcrx_area`** — `nia` (`net_iov_area`: `niovs[]`, `num_niovs`), `user_refs[]` (per-niov userspace checkout counts), freelist, `mem` (`io_zcrx_mem`: pages or dma-buf attachment and sgt), `area_id`.

**`struct net_iov`** (`include/net/netmem.h`) — the buffer handle: owning `net_iov_area`, `desc.pp` (page pool), pp refcount, DMA address ([[netmem-and-net-iov-abstraction]]).

**UAPI** (`include/uapi/linux/io_uring/zcrx.h`) — `io_uring_zcrx_ifq_reg`, `io_uring_zcrx_area_reg`, `io_uring_zcrx_rqe`, `io_uring_zcrx_cqe`, `zcrx_event_desc`, `zcrx_stats`, `zcrx_ctrl` + `enum zcrx_ctrl_op`.

## Key Functions / Entry Points

- **`io_register_zcrx()`** → `zcrx_register_netdev()` → `io_zcrx_create_area()` → `netif_mp_open_rxq()`
- **`io_import_umem()` / `io_import_dmabuf()`** — area backing
- **`io_pp_zc_alloc_netmems()` → `io_zcrx_ring_refill()` / `io_zcrx_refill_slow()`** — buffer supply to the NIC
- **`io_pp_zc_release_netmem()` / `io_pp_zc_init()` / `io_pp_zc_destroy()` / `io_pp_uninstall()`** — `memory_provider_ops`
- **`io_zcrx_recv()` → `io_zcrx_recv_skb()` → `io_zcrx_queue_cqe()` / `io_zcrx_copy_chunk()`** — delivery
- **`zcrx_send_notif()`**, **`io_zcrx_ctrl()`** (`FLUSH_RQ`, `EXPORT`, `ARM_EVENT`, `ADD_AREA`), **`import_zcrx()`**
- **`io_close_queue()` / `io_zcrx_scrub()` / `io_unregister_zcrx()`** — teardown

## Important Flags & Config Options

- `CONFIG_IO_URING_ZCRX` (depends on page-pool memory providers)
- Ring setup: `IORING_SETUP_DEFER_TASKRUN` + (`IORING_SETUP_CQE32` | `IORING_SETUP_CQE_MIXED`); `SINGLE_ISSUER` in practice
- `IORING_REGISTER_ZCRX_IFQ`, `IORING_REGISTER_ZCRX_CTRL`; `IORING_OP_RECV_ZC` (+ multishot)
- Area flags: `IORING_ZCRX_AREA_DMABUF`; registration flags `ZCRX_REG_IMPORT`, `ZCRX_REG_NODEV`
- Features: `ZCRX_FEATURE_RX_PAGE_SIZE`, `ZCRX_FEATURE_EVENT`
- NIC prerequisites: `ethtool -G <if> tcp-data-split on`, flow steering (`ethtool -N ... action <rxq>`), RSS excluding the queue ([[header-split-and-flow-steering-for-zero-copy-rx]])

## Interactions with Other Subsystems

- **↑ Userspace**: liburing zcrx helpers; the application manages the area, refill ring and event CQEs
- **→ page pool / memory providers**: `io_uring_pp_zc_ops` implements `alloc_netmems`, `release_netmem`, `init`, `destroy`, `nl_fill`, `uninstall` ([[page-pool]])
- **→ netdev queue management**: `netif_mp_open_rxq()` / `netif_mp_close_rxq()` restart a single RX queue ([[netdev-queue-management-api]])
- **→ netmem**: `net_iov` buffers and netmem refcounting ([[netmem-and-net-iov-abstraction]])
- **→ TCP**: `tcp_read_sock()` actor; the TCP state machine is unchanged ([[tcp-ip-stack]])
- **→ dma-buf**: device-memory areas ([[dma-buf-sharing]])
- **→ mm / accounting**: GUP pinning and locked-memory accounting for user areas
- **Siblings**: [[devmem-tcp]] uses the same provider hooks with a netlink-bound dma-buf and socket-level token returns. RDMA achieves direct placement with hardware transport instead of kernel TCP ([[rdma]])

## Design Decisions & Tradeoffs

- **Two refcounts per buffer.** `user_refs` (userspace checkouts, in a separate array writable only through validated RQEs) and the page-pool ref (kernel holders: skbs, pool) are separate, so a misbehaving application can only return what it was given, and kernel references can't be dropped by userspace. Scrub can revoke user refs wholesale at teardown.
- **Refill ring instead of a syscall per return.** Returns cost a shared-memory write, and the kernel consumes them lazily when the NIC needs buffers. The flip side is that buffer availability depends on the app returning promptly, hence the alloc-fail event.
- **Copy fallback, now observable.** Keeps correctness under bad steering or linear skb heads. The 2026 `ZCRX_EVENT_COPY` and `zcrx_stats` address the "silently slow" risk.
- **One hardware queue per ifq, shareable via export/import.** Dedication simplifies ownership (the provider owns every buffer in that queue). Sharing across rings came later with fd-based export rather than implicit global state.
- **DEFER_TASKRUN requirement.** All CQE posting and most bookkeeping run in one task context, avoiding locks on the completion side, at the cost of restricting zcrx to event-loop-style rings.
- **Kernel TCP retained.** Unlike RDMA or DPDK, security, firewalling and congestion control stay in the kernel, and only the payload copy is eliminated. The price is NIC feature dependence (header split, steering) and per-flow queue setup.

## How It Has Evolved

- **2022–2024** — RFCs (David Wei, Pavel Begunkov) converge with devmem TCP on page-pool memory providers and `net_iov`
- **6.15** — zcrx merged: single area of user memory, `RECV_ZC`, refill ring, copy fallback (bnxt first)
- **6.16–6.18** — dma-buf areas; `rx_buf_len` large chunks; `CQE_MIXED`; mlx5 and gve support
- **2025** — ifq sharing (export/import), per-queue DMA device lookup
- **2026** — `IORING_REGISTER_ZCRX_CTRL` (flush, export, arm event, add area), events with stats, `ZCRX_REG_NODEV`, multiple areas

## Further Reading

- kernel.org — [io_uring zero copy Rx](https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html)
- LWN — [io_uring zero copy rx v6](https://lwn.net/Articles/994603/) (2024); [zcrx ifq sharing](https://lwn.net/Articles/1043867/) (2025); [mlx5e devmem and io_uring zero-copy](https://lwn.net/Articles/1025247/)
- netdevconf 0x17 — [Zero Copy Receive using io_uring](https://netdevconf.info/0x17/sessions/talk/zero-copy-receive-using-io_uring.html)
- Related: [[io-uring-zero-copy-networking]], [[devmem-tcp]], [[page-pool]], [[netmem-and-net-iov-abstraction]], [[netdev-queue-management-api]], [[dma-buf-sharing]]

## LKML Highlights

- **`<20241016185252.3746190-1-dw@davidwei.uk>`** — zcrx v6 (David Wei, Pavel Begunkov). Established the provider-based design, net_iov user refcounting, refill ring and copy fallback, with a +41% throughput gain over epoll at 200 Gbit/s.
- **`<20251028174639.1244592-1-dw@davidwei.uk>`** — ifq sharing. Refcounted ifqs (`refs` vs `user_refs`) exported as fds so multiple rings can consume one queue.
- **zcrx control and events series (Pavel Begunkov, 2026)** — added `IORING_REGISTER_ZCRX_CTRL`, one-shot armed events for allocation failure and copy fallback with cumulative stats, NODEV instances and multi-area support. (Message-ids unavailable: lore was unreachable this session.)
