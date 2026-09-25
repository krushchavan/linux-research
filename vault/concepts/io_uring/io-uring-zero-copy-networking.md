---
title: "io_uring Zero-Copy Networking"
category: concept
tags: [io_uring, zero-copy, networking, zcrx, send-zc, page-pool]
subsystem: io_uring
kernel_version: "6.0"
researched: 2026-09-24
status: complete
explained: "[[io-uring-zero-copy-networking-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html
  - https://kernel-internals.org/io-uring/networking/
  - https://lwn.net/Articles/879724/
  - https://lwn.net/Articles/877167/
  - https://lwn.net/Articles/994603/
  - https://lwn.net/Articles/1043867/
  - https://lwn.net/Articles/1025247/
  - https://kernelnewbies.org/Linux_6.15
  - https://netdevconf.info/0x17/sessions/talk/zero-copy-receive-using-io_uring.html
---

# io_uring Zero-Copy Networking

> 📘 Plain-language version: [[io-uring-zero-copy-networking-explained]]

## Purpose

At 100–400 Gbit/s per NIC, copying payload between user memory and kernel socket buffers is often the single largest CPU cost in a network server. Linux already had `MSG_ZEROCOPY` for sending and `TCP_ZEROCOPY_RECEIVE` (mmap of received pages) for receiving, but both are awkward: completion notifications come through the socket error queue, and mmap-based receive needs page-aligned data and costly `mmap`/`munmap` churn. io_uring offers zero-copy on both paths while keeping the normal kernel TCP/IP stack in charge, so it isn't kernel bypass like DPDK. Notifications and buffer recycling are integrated into the ring.

## Mental Model

Zero-copy **send** is **lending the kernel your buffer instead of photocopying it**. You get an immediate receipt ("I've queued your data") and later a second note ("I'm done with your pages, you can reuse them"). Zero-copy **receive** is **having the delivery truck unload straight into your warehouse**. The NIC writes payloads directly into memory you registered, the kernel still reads the packing slips (headers) and runs TCP, and you hand emptied shelves back through a return chute (the refill ring).

## How It Works

### Transmit: SEND_ZC

**Issue.** `IORING_OP_SEND_ZC` (6.0) and `IORING_OP_SENDMSG_ZC` (6.1) look like ordinary sends. `io_send_zc_prep()` allocates a *notification* request, an `io_notif` (a stripped-down `io_kiocb`) that embeds a `struct ubuf_info` (`io_notif_data`). At issue time `io_send_zc()` builds an `iov_iter` over the user buffer. With `IORING_RECVSEND_FIXED_BUF` it uses a [[registered-resources|registered buffer]]'s pre-pinned bvec, avoiding even per-send pinning. It calls `sock_sendmsg()` with `MSG_ZEROCOPY` semantics and the `ubuf_info` attached via `msg_ubuf`. The TCP stack then attaches the user pages to skbs as frags (`skb_zerocopy_iter_stream()`) rather than copying them, and every skb referencing those pages holds a reference on the `ubuf_info`.

**Two CQEs.** When `sendmsg` returns, the request posts its first CQE: `res` is bytes queued, and `IORING_CQE_F_MORE` says another CQE is coming. The pages are still in use at this point. They may sit in the send queue or be retransmitted. When the last skb referencing them is freed (after ACK, or when the NIC's DMA completes for non-TCP), the `ubuf_info` refcount drops to zero and its callback `io_tx_ubuf_complete()` queues task_work that posts the *notification* CQE, carrying the same `user_data` and `IORING_CQE_F_NOTIF`. Only then may the application reuse the buffer.

**Batching and reporting.** Several sends can share one notification. `IORING_SEND_ZC_REPORT_USAGE` (6.2) makes the notification report, in `res`, whether the data really went zero-copy or the stack fell back to copying (`IORING_NOTIF_USAGE_ZC_COPIED`). That happens, for instance, with loopback or devices without scatter-gather. Later kernels link notifications for vectored/bundled sends so one CQE covers several requests.

**When it pays.** Pinning pages and managing notifications has a fixed cost. kernel-internals.org's guidance: under ~10 KB use plain `SEND`, 10–100 KB benchmark it, above ~100 KB `SEND_ZC` consistently wins.

### Receive: zcrx

**Hardware prerequisites.** Zero-copy receive (6.15, David Wei and Pavel Begunkov) needs a NIC with three features:
- *header/data split*, so headers land in kernel memory and payloads in user memory
- *flow steering*, to direct the application's flows to a specific RX queue
- *RSS* configured to keep all other traffic off that queue

The queue is effectively dedicated to one io_uring interface queue.

**Registration.** The ring must use `IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN` and 32-byte CQEs (`CQE32` or `CQE_MIXED`). The application `mmap`s an anonymous *area* for payloads and a *refill ring* region. It then calls `io_uring_register(IORING_REGISTER_ZCRX_IFQ)` with a `struct io_uring_zcrx_ifq_reg` naming the ifindex, RX queue id, refill-ring size, and area descriptor. `io_register_zcrx_ifq()` creates a `struct io_zcrx_ifq` and an `io_zcrx_area`, pins and DMA-maps the area's pages for the NIC, and chops them into `net_iov` chunks (page-sized by default, larger via `rx_buf_len` if physically contiguous). It then installs io_uring as the **page-pool memory provider** for that queue and restarts the queue. From then on, when the driver refills RX descriptors from its page pool, it gets io_uring's `net_iov`s instead of kernel pages. This provider abstraction (`struct memory_provider_ops`, net_iov) is shared with devmem TCP. That sharing is how zcrx got into the networking tree without special-casing drivers.

**Receiving.** The application submits `IORING_OP_RECV_ZC` with `IORING_RECV_MULTISHOT` on a TCP socket whose flow is steered to the queue. When data arrives, TCP processes headers normally. The payload frags point at `net_iov`s in the user area. `io_recvzc()` walks the socket's receive queue with a custom `read_sock` actor (`io_zcrx_recv_skb()`). For each frag backed by the ifq's own memory it takes a user reference on that `net_iov` and posts a CQE. The CQE's `res` is the length, and the extended `struct io_uring_zcrx_cqe` holds an offset into the area (area id in the high bits, `IORING_ZCRX_AREA_SHIFT`). No bytes are copied. The application reads the payload directly at `area_base + (off & ~AREA_MASK)`.

**Returning buffers.** When done, the application writes `struct io_uring_zcrx_rqe {off, len}` entries into the refill ring and advances its tail. The next time the page pool needs buffers, io_uring's provider (`io_pp_zc_alloc_netmems()`) drains the refill ring, drops the user references, and recycles those `net_iov`s back to the NIC. There is no syscall per buffer.

**Fallback copy.** If a frag isn't backed by zcrx memory, perhaps because the flow wasn't steered correctly or the packet arrived before setup, or if the area runs dry, zcrx copies into a free chunk of the area (`io_zcrx_copy_chunk()`). The application still sees the same CQE format, so correctness never depends on perfect steering.

**Performance.** The v6 posting reported ~116 Gbit/s vs ~82 Gbit/s for epoll on a 200G Broadcom NIC with application and softirq on different cores (+41%), and +29% on the same core.

## Key Data Structures

**`struct io_notif_data`** (`io_uring/notif.h`) — zero-copy send notification.
- `uarg` — embedded `struct ubuf_info` attached to skbs
- `account_pages` — pages charged to the user
- `zc_report`, `zc_used`, `zc_copied` — usage reporting
- `next`/`head` — linking for shared notifications

**`struct io_zcrx_ifq`** (`io_uring/zcrx.h`) — one ring↔RX-queue binding.
- `netdev`, `if_rxq` — bound device and queue
- `area` — registered `io_zcrx_area` (its `nia.niovs[]` array of `net_iov`s, freelist, user refcounts)
- `rq_ring`, `rqes`, `cached_rq_head` — the refill ring
- `dev` — DMA device

**UAPI** — `struct io_uring_zcrx_ifq_reg`, `struct io_uring_zcrx_area_reg`, `struct io_uring_zcrx_rqe`, `struct io_uring_zcrx_cqe` (`include/uapi/linux/io_uring.h`).

## Key Functions / Entry Points

**`io_send_zc_prep()` / `io_send_zc()` / `io_sendmsg_zc()`** (`io_uring/net.c`) — zero-copy send.

**`io_tx_ubuf_complete()`** (`io_uring/notif.c`) — `ubuf_info` callback; queues the notification CQE.

**`io_register_zcrx_ifq()`** (`io_uring/zcrx.c`) — bind an ifq to a NIC RX queue and install the memory provider.

**`io_recvzc()` / `io_zcrx_recv()`** — `RECV_ZC` issue; walks the receive queue and posts CQEs.

**`io_pp_zc_alloc_netmems()`** — page-pool provider allocation; drains the refill ring.

**`io_zcrx_copy_chunk()`** — copy fallback.

## Important Flags & Config Options

- **`IORING_OP_SEND_ZC`, `IORING_OP_SENDMSG_ZC`**; **`IORING_RECVSEND_FIXED_BUF`**; **`IORING_SEND_ZC_REPORT_USAGE`**; CQE flag **`IORING_CQE_F_NOTIF`**.
- **`IORING_REGISTER_ZCRX_IFQ`**, **`IORING_OP_RECV_ZC`** + **`IORING_RECV_MULTISHOT`**.
- Required setup for zcrx: **`IORING_SETUP_SINGLE_ISSUER`**, **`IORING_SETUP_DEFER_TASKRUN`**, **`IORING_SETUP_CQE32`** or **`IORING_SETUP_CQE_MIXED`**.
- NIC configuration via ethtool: `tcp-data-split on`, RSS/`ethtool -X` to exclude the queue, `ethtool -N` flow rules.
- **`CONFIG_PAGE_POOL`** memory providers; driver support currently bnxt, mlx5, gve and others.

## Interactions with Other Subsystems

- **↑ Userspace**: liburing `io_uring_prep_send_zc()`, `io_uring_prep_send_zc_fixed()`, zcrx examples in liburing; applications must track two CQEs per ZC send.
- **→ [[net]]**: uses `MSG_ZEROCOPY` infrastructure (`ubuf_info`, `skb_zerocopy_iter_stream()`) for TX, and `tcp_read_sock()`-style receive-queue walking for RX. TCP state machines are untouched.
- **→ [[page-pool]]**: zcrx is a page-pool memory provider handing out `net_iov`s instead of pages.
- **→ [[network-device-and-napi]]**: RX queue restart and memory-provider binding (`netdev_rx_queue_restart()`), with NAPI polling filling descriptors from the provider.
- **→ mm / DMA**: pins and DMA-maps the user area; optional DMA-buf areas (6.16) let payloads land in device memory such as GPUs.
- **→ [[io-uring-task-work]]**: notifications and RX completions are posted from task context; DEFER_TASKRUN is mandatory for zcrx.

## Design Decisions & Tradeoffs

**Keep the kernel stack, drop the copy.** Unlike kernel-bypass stacks, zcrx keeps TCP, firewalling and congestion control in the kernel, and only the payload bytes skip the copy. That preserves the kernel's security and management model but ties zero-copy to NIC features (header split, steering) and to per-queue dedication.

**Two-phase completion for send.** Returning as soon as data is queued keeps latency low, but the buffer lifetime then extends past the operation. The notification CQE makes that lifetime explicit. The cost is extra CQEs and more complex application bookkeeping; `MSG_ZEROCOPY`'s error-queue design was rejected as too clunky for a ring API.

**Shared page-pool provider abstraction.** Rather than a private io_uring hook in each driver, zcrx and devmem TCP share the netmem/net_iov and memory-provider infrastructure. It took longer to land (the networking maintainers insisted on it) but means drivers support both with one implementation.

**Always-correct fallback.** The copy fallback means misconfigured steering degrades performance rather than correctness. That was important for making the feature deployable.

**Single-issuer, deferred-completion rings only.** Requiring `SINGLE_ISSUER` + `DEFER_TASKRUN` removes locking between the refill ring, the page pool and completion posting. It limits zcrx to event-loop-style applications with one thread per ring. Ifq sharing (2025–26) partially lifts this by letting several rings in one process share a queue.

## How It Has Evolved

- **2021–2022** — zero-copy send designed by Pavel Begunkov; merged as `SEND_ZC` in 6.0, `SENDMSG_ZC` in 6.1.
- **6.2** — `IORING_SEND_ZC_REPORT_USAGE`.
- **2022–2024** — several zcrx designs (2022 RFC; 2023 netdevconf talk; devmem TCP collaboration) converge on page-pool memory providers and `net_iov`.
- **6.15** — zcrx merged: `IORING_REGISTER_ZCRX_IFQ`, `IORING_OP_RECV_ZC`, bnxt support.
- **6.16+** — DMA-buf areas, larger chunks via `rx_buf_len`, `CQE_MIXED` rings, more drivers (mlx5, gve).
- **2025–2026** — ifq sharing across rings; ongoing driver enablement.

## Further Reading

1. [io_uring zero copy Rx — kernel.org docs](https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html)
2. [Zero-copy network transmission with io_uring — LWN (2022)](https://lwn.net/Articles/879724/)
3. [io_uring zero copy rx v6 — patch posting (2024)](https://lwn.net/Articles/994603/)
4. [Zero Copy Receive using io_uring — netdevconf 0x17](https://netdevconf.info/0x17/sessions/talk/zero-copy-receive-using-io_uring.html)
5. [io_uring zcrx ifq sharing — patch posting (2025)](https://lwn.net/Articles/1043867/)
6. [net/mlx5e: devmem and io_uring TCP zero-copy — patch posting](https://lwn.net/Articles/1025247/)
7. [kernel-internals.org — Networking with io_uring](https://kernel-internals.org/io-uring/networking/)

## LKML Highlights

> lore.kernel.org was unreachable from this run; message-ids come from LWN's mirrors.

- **`<20241016185252.3746190-1-dw@davidwei.uk>`** — zero-copy RX v6 (David Wei and Pavel Begunkov, Oct 2024). It builds on the page-pool memory-provider hooks shared with devmem TCP, adds net_iov lifetime refcounting, the refill queue and copy fallback, and reports a +41% throughput gain over epoll at 200 Gbit/s.
- **`<20251028174639.1244592-1-dw@davidwei.uk>`** — ifq sharing (David Wei, Oct 2025). It lets several rings share one hardware RX queue binding by refcounting ifqs, with refill-ring synchronisation left to userspace threads in the same address space.
- **"io_uring zerocopy send" (Pavel Begunkov, 2021–22)** — introduces notification CQEs in place of `MSG_ZEROCOPY`'s error-queue signalling. The design debate was about how to batch notifications without making buffer lifetime ambiguous.
