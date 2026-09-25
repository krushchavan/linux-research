---
title: "AF_XDP (XDP Sockets)"
category: concept
tags: [networking, af-xdp, xdp, zero-copy, kernel-bypass, bpf]
subsystem: net
kernel_version: "4.18"
researched: 2026-09-25
status: complete
explained: "[[af-xdp-explained]]"
sources:
  - https://kernel-internals.org/net/af-xdp/
  - https://www.kernel.org/doc/html/latest/networking/af_xdp.html
  - https://www.kernel.org/doc/html/latest/networking/xsk-tx-metadata.html
  - https://lwn.net/Articles/750845/
  - https://lwn.net/Articles/745934/
  - https://lwn.net/Articles/737947/
  - https://lwn.net/Articles/754659/
  - https://lwn.net/Articles/756549/
  - https://lwn.net/Articles/819423/
  - https://lwn.net/Articles/909449/
  - https://lwn.net/Articles/937525/
  - https://patchwork.ozlabs.org/project/netdev/cover/20171031124145.9667-1-bjorn.topel@gmail.com/
  - https://patchwork.ozlabs.org/project/netdev/cover/20180131135356.19134-1-bjorn.topel@gmail.com/
  - https://patchwork.ozlabs.org/project/netdev/cover/20180502110136.3738-1-bjorn.topel@gmail.com/
  - https://www.spinics.net/lists/netdev/msg467170.html
  - https://archive.fosdem.org/2018/schedule/event/af_xdp/
  - https://doc.dpdk.org/guides/nics/af_xdp.html
---

# AF_XDP (XDP Sockets)

> 📘 Plain-language version: [[af-xdp-explained]]

## Purpose

AF_XDP is an address family (`socket(AF_XDP, SOCK_RAW, 0)`) that lets an [[xdp]] program hand raw frames straight to a userspace application — and lets that application transmit raw frames — without allocating an [[sk-buff]] or traversing the network stack. It exists because the most demanding packet-processing workloads (NFV, load balancers, packet capture, DPDK-style applications) were otherwise pushed to full kernel-bypass frameworks that take the NIC away from the kernel entirely. AF_XDP delivers near-DPDK throughput while the kernel keeps owning the device, the driver, and the security model: you can steer *some* traffic to userspace and let the rest flow through the normal stack.

## Mental Model

Think of a loading dock shared between a warehouse (userspace) and a delivery company (the kernel/NIC). The warehouse owns all the pallets (**UMEM** frames). It leaves empty pallets on a "please fill" conveyor (**FILL ring**); the delivery company loads packets onto them and pushes them back on a "delivered" conveyor (**RX ring**). For outbound goods, the warehouse loads pallets onto a "ship this" conveyor (**TX ring**) and gets the empty pallets back on a "shipped" conveyor (**COMPLETION ring**). Nobody moves goods between pallets — only *pallet numbers* travel on the conveyors — and in zero-copy mode the NIC's DMA engine loads the pallets directly. The kernel's only job is to check that every pallet number the warehouse hands it is actually one of the warehouse's pallets.

## How It Works

### Setup: UMEM, rings, and bind

The application starts by allocating a chunk of its own virtual memory — ideally with `MAP_HUGETLB` to reduce IOTLB/TLB pressure — and registering it with `setsockopt(XDP_UMEM_REG)`, passing a `struct xdp_umem_reg` (`addr`, `len`, `chunk_size`, `headroom`, `flags`, and since 6.8 `tx_metadata_len`). In the kernel, `xdp_umem_reg()` in `net/xdp/xdp_umem.c` validates the geometry and pins the pages with `pin_user_pages()` (see [[get-user-pages-and-pinning]]), charging them against `RLIMIT_MEMLOCK`. The result is a **`struct xdp_umem`**: the pinned page array (`pgs`, `npgs`), `chunk_size`, `headroom`, and a refcount (`users`) because multiple sockets may share one UMEM. The pinning is the whole point — the NIC is going to DMA into these pages, so they can never be reclaimed or migrated while the socket lives.

By default the UMEM is split into equal **chunks** (2 KiB or 4 KiB historically; since 6.6, larger than `PAGE_SIZE` when backed by hugepages). In *aligned* mode the kernel masks any address the user gives it down to a chunk boundary, so a frame is simply "chunk N". **Unaligned chunk mode** (`XDP_UMEM_UNALIGNED_CHUNK_FLAG`, 5.4) lets addresses point anywhere, which the DPDK AF_XDP PMD needed to map its own mbuf layout onto the UMEM; the kernel then encodes an offset in the upper 16 bits of the 64-bit address.

Next the application sizes the four rings with `XDP_RX_RING`, `XDP_TX_RING`, `XDP_UMEM_FILL_RING`, and `XDP_UMEM_COMPLETION_RING`, queries `XDP_MMAP_OFFSETS`, and `mmap()`s each ring at a fixed page offset (`XDP_PGOFF_RX_RING`, `XDP_PGOFF_TX_RING`, `XDP_UMEM_PGOFF_FILL_RING`, `XDP_UMEM_PGOFF_COMPLETION_RING`). Each ring is a **`struct xdp_ring`** header — `producer` and `consumer` indices on separate cache lines plus a `flags` word — followed by a power-of-two array of entries. FILL and COMPLETION entries are bare `u64` UMEM addresses; RX and TX entries are **`struct xdp_desc`** (`addr`, `len`, `options`). Kernel-side each ring is wrapped by a **`struct xsk_queue`** (`net/xdp/xsk_queue.h`), which keeps *cached* copies of the producer/consumer indices (`cached_prod`, `cached_cons`) so the hot path touches the shared cache line only when the local cache runs dry — the same trick as [[io_uring]]'s SQ/CQ. Every ring is strictly single-producer/single-consumer, which is why no locks or atomics beyond acquire/release barriers are needed.

Finally `bind()` with a `struct sockaddr_xdp` names an `ifindex`, a `queue_id`, and flags. `xsk_bind()` looks up or creates a **`struct xsk_buff_pool`** (`net/xdp/xsk_buff_pool.c`) for that (device, queue) pair and calls `xp_assign_dev()`, which asks the driver — via `ndo_bpf(XDP_SETUP_XSK_POOL)` — to take over that hardware queue in zero-copy mode. The binding is **per queue**, not per device: an AF_XDP socket only ever sees traffic the NIC steered to its queue. If the driver can't do zero-copy (or `XDP_COPY` was requested) the socket falls back to copy mode; `XDP_ZEROCOPY` makes the fallback an error instead. The kernel-side socket is a **`struct xdp_sock`** (`include/net/xdp_sock.h`) holding the `rx` and `tx` queues, the `pool`, the bound `dev`/`queue_id`, a `zc` flag, and the list of XSKMAPs it's inserted into.

The last piece is steering. An XDP program attached to the device must `bpf_redirect_map(&xsks_map, ctx->rx_queue_index, XDP_PASS)` into a **`BPF_MAP_TYPE_XSKMAP`** ([[bpf-maps]]) whose slots hold AF_XDP socket fds. The fallback action lets unmatched traffic (or queues with no socket) continue into the normal stack — this is what makes AF_XDP a *partial* bypass rather than a device takeover.

### RX fast path (zero-copy)

The application pre-posts free chunk addresses to the FILL ring. The zero-copy driver, when refilling its RX descriptor ring in NAPI context ([[network-device-and-napi]]), calls `xsk_buff_alloc()` / `xsk_buff_alloc_batch()`, which pull addresses from the pool's view of the FILL ring (`pool->fq`) and return a **`struct xdp_buff_xsk`** — an `xdp_buff` wrapped with the chunk's DMA address and original UMEM address. The pool pre-computed DMA addresses for every UMEM page at bind time (`xp_dma_map()`, using the [[dma-mapping-api]]), so allocation is just an index lookup; no mapping happens per packet.

The NIC DMAs a frame directly into that chunk. The driver runs the XDP program on the `xdp_buff`; on `XDP_REDIRECT` to an XSKMAP, `__xsk_map_redirect()` → `xsk_rcv_zc()` does almost nothing: it validates that the socket is bound to *this* device and queue (a mismatch is a drop — the frame physically lives in a different UMEM), then writes a descriptor `{addr, len}` into the socket's RX ring without publishing it. At the end of the NAPI poll, `xdp_do_flush()` → `__xsk_map_flush()` publishes the batch with one release-store of the producer index and wakes the socket. The packet bytes never moved; only an 8-byte address and a length were written. If the program instead returns `XDP_PASS` on a zero-copy queue, the driver must copy the frame into a freshly allocated skb (`xdp_build_skb_from_zc()` in newer kernels) and recycle the chunk — so zero-copy is fast for AF_XDP traffic and *slower* for traffic that falls back to the stack.

The application reads RX descriptors (acquire-load of the producer), processes packets in place in UMEM, and returns the chunks to the FILL ring. In the steady state no system calls happen at all.

### RX slow path (copy mode)

In copy mode — any driver with native XDP, or generic/skb-mode XDP on any device — the frame lives in driver-owned memory (typically a [[page-pool]] page). `xsk_rcv()` → `__xsk_rcv()` takes a chunk from the FILL ring, `memcpy()`s the frame (and metadata) into it, posts an RX descriptor, and lets the driver recycle its own buffer. This costs one copy per packet but works everywhere and is still far cheaper than the socket stack. If the FILL ring is empty or the RX ring full, the packet is dropped and `rx_dropped` / `rx_ring_full` / `rx_fill_ring_empty_descs` counters (exposed via `getsockopt(XDP_STATISTICS)` into `struct xdp_statistics`) record why.

### TX path

The application writes `struct xdp_desc` entries to the TX ring pointing at UMEM chunks it has filled, then kicks the kernel with `sendto()` (or `sendmsg()`/`poll()`).

In **copy mode**, `xsk_sendmsg()` → `xsk_generic_xmit()` walks the TX ring, validating each descriptor with `xp_validate_desc()` — the kernel never trusts a user-supplied address or length; invalid ones increment `tx_invalid_descs` and are skipped. For each valid packet `xsk_build_skb()` builds an skb (attaching UMEM pages as frags where possible) and hands it to the driver via `__dev_direct_xmit()`, bypassing the qdisc layer ([[traffic-control-qdisc]]). When the skb is freed, its destructor posts the address to the COMPLETION ring. A per-call budget (`XDP_MAX_TX_SKB_BUDGET` sockopt, range 32..ring size, in recent kernels) bounds how much one syscall processes.

In **zero-copy mode**, `sendto()` just calls the driver's `ndo_xsk_wakeup()` to schedule NAPI. The driver's NAPI poll then pulls descriptors itself with `xsk_tx_peek_desc()` / `xsk_tx_peek_release_desc_batch()`, translates addresses to pre-mapped DMA addresses with `xsk_buff_raw_get_dma()`, posts them to hardware, and on TX-completion interrupt calls `xsk_tx_completed()` to publish completions. The payload is DMA'd straight out of UMEM.

### need_wakeup: removing the remaining syscalls

The original design made applications call `sendto()`/`poll()` every batch to guarantee the kernel would make progress, which cost a syscall even when the driver was already busy-polling the rings. `XDP_USE_NEED_WAKEUP` (5.3) adds `XDP_RING_NEED_WAKEUP` to the FILL and TX ring `flags`. The driver sets it (`xsk_set_rx_need_wakeup()` / `xsk_set_tx_need_wakeup()`) only when it has run out of work and gone idle, and clears it while it's actively processing. The application checks the flag and issues a syscall only if it's set. This is especially important when application and NAPI run on the *same* core, where an unconditional syscall could starve the softirq or vice versa.

### Busy polling

Since 5.11, `SO_PREFER_BUSY_POLL` together with `SO_BUSY_POLL` and `SO_BUSY_POLL_BUDGET` lets an AF_XDP application drive the NAPI loop from its own syscalls, with hard IRQs deferred via the per-device `napi_defer_hard_irqs` and `gro_flush_timeout`. The whole RX→process→TX pipeline then runs on one core with no interrupts and no context switches — the configuration DPDK's AF_XDP PMD uses when `busy_budget` is set.

### Sharing a UMEM

With `XDP_SHARED_UMEM` a second socket binds by referring to a first socket's fd and reuses its UMEM. Sockets on the *same* (device, queue) share one FILL/COMPLETION pair and one pool; the XDP program chooses among them via XSKMAP index. Since 5.10 (when `xsk_buff_pool` was split out of `xdp_umem`), sockets on *different* queues or devices can share a UMEM too, each (device, queue) getting its own pool and its own FILL/COMPLETION rings. Because rings are single-producer/single-consumer, userspace must ensure only one thread touches each FILL/COMPLETION ring, and must never post the same chunk to two rings at once — that's the documented source of "mysterious" packet corruption.

### Multi-buffer

Originally one packet had to fit in one chunk, ruling out jumbo frames. With `XDP_USE_SG` (6.6), a packet can span several descriptors: every descriptor except the last carries `XDP_PKT_CONTD` in `options`. On RX the kernel guarantees atomicity — if the RX ring can't take all fragments, the whole packet is dropped. On TX an invalid fragment invalidates the entire packet, and all its chunks are returned via COMPLETION. Copy mode supports up to `MAX_SKB_FRAGS + 1` fragments; zero-copy limits come from the NIC (reported via the netdev netlink `xdp-zc-max-segs` attribute).

### TX metadata offloads

AF_XDP TX originally could not ask the NIC for anything beyond "send these bytes". Since 6.8 an application can reserve `tx_metadata_len` bytes of headroom (flag `XDP_UMEM_TX_METADATA_LEN`) and, per packet, set `XDP_TX_METADATA` in the descriptor `options`. The kernel then reads a **`struct xsk_tx_metadata`** placed immediately before the payload: requests for L4 checksum offload (`XDP_TXMD_FLAGS_CHECKSUM` with `csum_start`/`csum_offset`), a hardware TX timestamp returned in `completion.tx_timestamp` (`XDP_TXMD_FLAGS_TIMESTAMP`), and — added in 6.15 for stmmac and igc — scheduled transmission (`XDP_TXMD_FLAGS_LAUNCH_TIME`). Drivers implement a small `struct xsk_tx_metadata_ops`; supported features are advertised via netdev netlink `xsk-features`. For multi-buffer packets only the first fragment carries metadata.

### Teardown

Closing the socket removes it from XSKMAPs, calls `xp_clear_dev()` to tell the driver to release the queue from zero-copy mode (drivers typically reconfigure the ring, briefly disrupting that queue), drops the pool and UMEM references, and unpins the pages when the last user goes away. A device unregister forcibly unbinds every socket (`xsk_notifier()`), leaving them in an unbound state where the rings return errors.

## Key Data Structures

**`struct xdp_sock`** (`include/net/xdp_sock.h`) — the kernel socket.
- `rx`, `tx` — `struct xsk_queue` for the RX/TX rings.
- `pool` — the `xsk_buff_pool` for the bound (dev, queue).
- `dev`, `queue_id`, `zc` — binding and mode.
- `map_list` — XSKMAPs referencing this socket (for removal on close).
- `tx_list` — link on the pool's list of TX sockets sharing it.

**`struct xdp_umem`** (`include/net/xdp_sock.h`) — the registered memory region.
- `addr`, `size`, `chunk_size`, `headroom`, `tx_metadata_len`
- `pgs`, `npgs` — pinned pages.
- `users` — refcount across sharing sockets; `flags` — e.g. unaligned mode.

**`struct xsk_buff_pool`** (`include/net/xsk_buff_pool.h`) — per (device, queue) allocator view of a UMEM.
- `fq`, `cq` — FILL and COMPLETION queues.
- `heads`, `free_heads_cnt`, `free_list` — pre-allocated `xdp_buff_xsk` objects.
- `dma_pages`, `dev` — pre-computed DMA addresses for every UMEM page.
- `xsk_tx_list` — sockets whose TX rings drain through this pool.
- `uses_need_wakeup`, `unaligned`, `tx_metadata_len`

**`struct xdp_buff_xsk`** (`include/net/xsk_buff_pool.h`) — an `xdp_buff` plus `dma`, `orig_addr`, and back-pointer to the `pool`.

**`struct xsk_queue`** (`net/xdp/xsk_queue.h`) — kernel view of one ring: `ring_mask`, `nentries`, `cached_prod`, `cached_cons`, `ring` (the shared `struct xdp_ring`), `invalid_descs`, `queue_empty_descs`.

**`struct xdp_desc`** (`include/uapi/linux/if_xdp.h`) — `addr` (UMEM offset), `len`, `options` (`XDP_PKT_CONTD`, `XDP_TX_METADATA`).

## Key Functions / Entry Points

**`xsk_create()`** (`net/xdp/xsk.c`) — `socket(AF_XDP)` handler; requires `CAP_NET_RAW`.
**`xsk_setsockopt()`** (`net/xdp/xsk.c`) — UMEM registration and ring creation.
**`xsk_bind()`** (`net/xdp/xsk.c`) — attaches to (dev, queue), creates/shares the pool, picks copy vs zero-copy.
**`xp_assign_dev()`** (`net/xdp/xsk_buff_pool.c`) — asks driver to enable zero-copy on a queue via `XDP_SETUP_XSK_POOL`.
**`xdp_umem_reg()`** (`net/xdp/xdp_umem.c`) — validates and pins the UMEM.
**`__xsk_map_redirect()`** / **`xsk_rcv_zc()`** / **`__xsk_rcv()`** (`net/xdp/xsk.c`) — RX delivery, zero-copy and copy.
**`__xsk_map_flush()`** (`net/xdp/xsk.c`) — publishes batched RX descriptors at NAPI end.
**`xsk_sendmsg()`** → **`xsk_generic_xmit()`** (`net/xdp/xsk.c`) — copy-mode TX.
**`xsk_buff_alloc()`**, **`xsk_buff_alloc_batch()`**, **`xsk_buff_free()`**, **`xsk_buff_dma_sync_for_cpu()`** (`include/net/xdp_sock_drv.h`) — driver RX buffer API.
**`xsk_tx_peek_desc()`**, **`xsk_tx_peek_release_desc_batch()`**, **`xsk_tx_completed()`** (`net/xdp/xsk.c`) — driver zero-copy TX API.
**`xsk_poll()`** (`net/xdp/xsk.c`) — `poll()` support; also triggers wakeup.
**`xsk_map_update_elem()`** (`net/xdp/xskmap.c`) — inserts sockets into an XSKMAP.

## Important Flags & Config Options

- `CONFIG_XDP_SOCKETS` — enables AF_XDP; `CONFIG_XDP_SOCKETS_DIAG` — `ss`/sock_diag support.
- **Bind flags**: `XDP_COPY`, `XDP_ZEROCOPY` (force mode), `XDP_USE_NEED_WAKEUP`, `XDP_SHARED_UMEM`, `XDP_USE_SG` (multi-buffer).
- **UMEM flags**: `XDP_UMEM_UNALIGNED_CHUNK_FLAG`, `XDP_UMEM_TX_SW_CSUM` (software checksum fallback for testing), `XDP_UMEM_TX_METADATA_LEN`.
- **Sockopts**: `XDP_STATISTICS`, `XDP_OPTIONS` (reports `XDP_OPTIONS_ZEROCOPY`), `XDP_MMAP_OFFSETS`, `XDP_MAX_TX_SKB_BUDGET`.
- **Busy poll**: `SO_PREFER_BUSY_POLL`, `SO_BUSY_POLL`, `SO_BUSY_POLL_BUDGET`; `/sys/class/net/<dev>/napi_defer_hard_irqs`, `gro_flush_timeout`; `net.core.busy_poll`.
- `RLIMIT_MEMLOCK` — bounds how much UMEM an unprivileged-memlock process can pin.
- **NIC steering**: `ethtool -L <dev> combined N` and `ethtool -N` flow rules decide which queue (and therefore which socket) sees which traffic.

## Interactions with Other Subsystems

- **↑ Userspace**: libxdp (`xsk_umem__create()`, `xsk_socket__create()`; moved out of libbpf in libbpf 1.0 — see [[libbpf-and-toolchain]]), DPDK's `net_af_xdp` PMD, VPP, Suricata, OVS AF_XDP netdev, and custom NFV/load-balancer apps.
- **→ [[xdp]]**: AF_XDP has no receive path of its own; an XDP program must redirect into an XSKMAP.
- **→ [[bpf-maps]]**: `BPF_MAP_TYPE_XSKMAP` holds socket references.
- **→ [[network-device-and-napi]]**: zero-copy RX/TX runs in the driver's NAPI poll; `ndo_xsk_wakeup` schedules it; busy polling drives it from userspace.
- **→ [[dma-mapping-api]]**: pools pre-map the whole UMEM once at bind time.
- **→ [[get-user-pages-and-pinning]]** / **[[huge-pages-hugetlbfs]]**: UMEM pages are long-term pinned; hugepages reduce TLB/IOMMU cost and enable large chunks.
- **← [[page-pool]]**: in copy mode, the driver's page-pool buffers are the copy source and are recycled immediately.
- **→ [[sk-buff]]**: only on the slow paths — copy-mode TX builds skbs, and `XDP_PASS` on a zero-copy queue must copy into one.

## Design Decisions & Tradeoffs

**A new address family, not AF_PACKET V4.** Björn Töpel and Magnus Karlsson first posted this in October 2017 as "AF_PACKET V4" — a new TPACKET version with zero-copy rings. Netdev review (and the NetDev 2.2 talk in Seoul) pushed back: AF_PACKET already carried three ring versions of compatibility baggage and taps packets *after* skb allocation. The consensus was a fresh address family hooked to XDP instead; names floated included AF_CAPTURE, AF_CHANNEL, AF_ZEROCOPY and AF_XDP, and Jesper Dangaard Brouer's preference for AF_XDP won. Hooking at XDP is what makes skb-less delivery possible.

**Per-queue binding and XDP steering, not device takeover.** Unlike DPDK/netmap, AF_XDP binds a single hardware queue and relies on an XDP program plus NIC flow steering to choose what reaches userspace. The kernel keeps the device, ARP/SSH/management traffic keeps working, and several applications can share a NIC. The price is configuration complexity: users frequently bind to queue 0 and see no traffic because RSS put it on queue 3.

**Userspace owns the memory; the kernel validates addresses.** Letting the application allocate UMEM means packet buffers are ordinary process memory — no special allocator, no mmap of kernel buffers. Safety comes from pinning plus validating every address/length the application posts (`xp_validate_desc()`, `xp_aligned_validate_desc()`), so a buggy or malicious app can corrupt only its own packets. Socket creation requires `CAP_NET_RAW`, as with raw sockets.

**Copy mode as a universal fallback.** Zero-copy needs substantial driver work (dedicated XSK RX/TX paths), so a copy mode that works on any XDP — even generic XDP — driver guarantees portability. The cost is that applications see very different performance per NIC, and the "same API" can hide a 2–3× gap.

**Single-producer/single-consumer rings.** Lockless SPSC rings with cached indices keep the fast path to a few cache-line transfers, but push all concurrency into the application: one thread per FILL/COMPLETION ring, one per RX/TX ring.

**Zero-copy slows down the non-AF_XDP path.** On a zero-copy queue every `XDP_PASS` packet must be copied out of UMEM into an skb, because UMEM chunks belong to userspace and cannot be lent to the stack. Mixed workloads therefore often dedicate queues to AF_XDP via flow steering.

## How It Has Evolved

- **4.18 (2018)** — AF_XDP merged: UMEM, four rings, XSKMAP, copy mode (Björn Töpel, Magnus Karlsson).
- **4.19–4.20** — zero-copy RX/TX framework and first driver (i40e); `MEM_TYPE_ZERO_COPY`.
- **5.x early** — ixgbe, mlx5 zero-copy; libbpf gains `xsk.h` helpers.
- **5.3** — `XDP_USE_NEED_WAKEUP`; `XDP_OPTIONS` sockopt.
- **5.4** — unaligned chunk mode (driven by DPDK's AF_XDP PMD); XSKMAP lookups from BPF.
- **5.8** — buffer allocation API (`xsk_buff_alloc()`/`xsk_buff_free()`, `MEM_TYPE_XSK_BUFF_POOL`), deleting ~1,265 lines of per-driver code and improving performance 5–10%; driver adoption accelerates.
- **5.10** — `xsk_buff_pool` split from `xdp_umem`: shared UMEM across devices and queues.
- **5.11** — `SO_PREFER_BUSY_POLL` / `SO_BUSY_POLL_BUDGET` for single-core busy-polling pipelines.
- **5.x–6.x** — batched allocation (`xsk_buff_alloc_batch()`) and batched TX descriptor release; more zero-copy drivers (ice, igc, stmmac, dpaa2, bnxt, virtio-net, and others).
- **libbpf 1.0 (2022)** — AF_XDP userspace helpers move from libbpf to libxdp.
- **6.6 (2023)** — multi-buffer (`XDP_USE_SG`, `XDP_PKT_CONTD`); UMEM chunks larger than `PAGE_SIZE` with hugepages.
- **6.8 (2024)** — TX metadata: checksum offload and TX timestamps (Stanislav Fomichev); netdev netlink `xsk-features`.
- **6.15 (2025)** — TX launch-time offload for igc and stmmac.
- **2025–2026** — TX-side tuning (`XDP_MAX_TX_SKB_BUDGET`), copy-mode TX performance work, and ongoing driver coverage.

## Further Reading

1. [Accelerating networking with AF_XDP — LWN (2018)](https://lwn.net/Articles/750845/) — the canonical design overview.
2. [Introducing AF_PACKET V4 support — LWN (2017)](https://lwn.net/Articles/737947/) — the pre-AF_XDP proposal.
3. [Introducing AF_XDP support — LWN (2018)](https://lwn.net/Articles/745934/) — RFC cover letter with performance comparisons.
4. [AF_XDP, zero-copy support — LWN (2018)](https://lwn.net/Articles/754659/) and [AF_XDP: introducing zero-copy support](https://lwn.net/Articles/756549/).
5. [Introduce AF_XDP buffer allocation API — LWN (2020)](https://lwn.net/Articles/819423/).
6. [xsk: multi-buffer support — LWN (2023)](https://lwn.net/Articles/937525/).
7. [AF_XDP — kernel.org documentation](https://www.kernel.org/doc/html/latest/networking/af_xdp.html) — the authoritative API reference and FAQ.
8. [AF_XDP TX metadata — kernel.org](https://www.kernel.org/doc/html/latest/networking/xsk-tx-metadata.html).
9. [AF_XDP — kernel-internals.org](https://kernel-internals.org/net/af-xdp/).
10. [Fast Packet Processing in Linux with AF_XDP — FOSDEM 2018](https://archive.fosdem.org/2018/schedule/event/af_xdp/).
11. [DPDK AF_XDP PMD guide](https://doc.dpdk.org/guides/nics/af_xdp.html) — practical busy-poll and shared-UMEM configuration.

## LKML Highlights

> Live lore.kernel.org search was unavailable during this research run (TLS verification failure); threads below were located via patchwork and mailing-list archives.

- **"[RFC PATCH 00/14] Introducing AF_PACKET V4 support"** (Oct 2017, `20171031124145.9667-1-bjorn.topel@gmail.com`) — the original zero-copy AF_PACKET proposal; review, including the "AF_XDP or AF_CHANNEL?" sub-thread, led to abandoning AF_PACKET in favour of a new XDP-hooked address family.
- **"[RFC PATCH 00/24] Introducing AF_XDP support"** (Jan 2018, `20180131135356.19134-1-bjorn.topel@gmail.com`) — the first AF_XDP posting, reframing the design around UMEM, four rings and XSKMAP redirect; merged after the v3 series (`20180502110136.3738-1-bjorn.topel@gmail.com`) for 4.18.
- **"xsk: multi-buffer support"** (2023, see [LWN](https://lwn.net/Articles/937525/)) — debated how to keep RX atomic at packet granularity and how TX should treat a partially invalid fragment chain, settling on all-or-nothing semantics with `XDP_PKT_CONTD`.
