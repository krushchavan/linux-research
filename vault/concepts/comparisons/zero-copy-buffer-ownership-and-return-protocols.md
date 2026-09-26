---
title: "Zero-Copy Buffer Ownership and Return Protocols: AF_XDP, zcrx, Devmem TCP, Provided Buffer Rings, RDMA SRQ and Zero-Copy Send"
category: concept
tags: [comparison, zero-copy, af_xdp, io_uring, devmem, rdma]
subsystem: comparisons
kernel_version: "RDMA SRQ (IB verbs, 2.6); MSG_ZEROCOPY 4.14; AF_XDP 4.18; provided buffer rings 5.19; io_uring SEND_ZC 6.0; devmem RX 6.12 / TX 6.14; io_uring zcrx 6.15"
researched: 2026-09-26
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/networking/af_xdp.html
  - https://www.kernel.org/doc/html/latest/networking/msg_zerocopy.html
  - https://www.kernel.org/doc/html/latest/networking/devmem.html
  - https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html
  - https://man7.org/linux/man-pages/man3/ibv_modify_srq.3.html
  - https://lwn.net/Articles/900083/
  - https://lwn.net/Articles/1004591/
  - https://lwn.net/Articles/1051215/
  - https://lwn.net/Articles/962809/
  - https://docs.nvidia.com/networking/display/RDMAAwareProgrammingv17/Key+Concepts
  - https://doc.dpdk.org/guides-20.08/nics/mlx5.html
  - https://www.spinics.net/lists/linux-rdma/msg55779.html
---

# Zero-Copy Buffer Ownership and Return Protocols

> Comparison note under `comparisons/`. Complements [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk]], [[devmem-tcp-vs-rdma-gpudirect-vs-io-uring-zcrx]], [[io-uring-vs-rdma]] and [[polling-vs-interrupts-io-uring-napi-rdma-cq]]. The memory side (pinning, registration, DMA mapping) is covered separately by the queued comparison on memory pinning and registration strategies.

## Purpose

Copying is simple because ownership is simple: after `recv()` returns, the kernel's buffer and yours are separate, and each side frees its own. **Zero-copy makes ownership shared.** On receive, the NIC writes into memory the application will read in place, so someone must hand *empty* buffers to the NIC before data arrives, and the application must hand *used* buffers back when it's finished. On send, the application lends pages to the stack, which may keep them until the data is ACKed or retransmitted, so the application needs a second signal telling it when the buffer is its own again.

Every zero-copy interface in Linux is, underneath, a **buffer ownership protocol**: a set of rules for who may touch which buffer when, how ownership moves, how the kernel defends itself against a buggy or hostile application, and what happens when the supply of free buffers runs out. This note lines up the five receive-side protocols (AF_XDP FILL ring, io_uring zcrx refill ring, devmem TCP tokens, io_uring provided buffer rings, RDMA receive queues and SRQs) and the send-side notification protocols (`MSG_ZEROCOPY`, io_uring `SEND_ZC`, devmem TX, AF_XDP COMPLETION ring, RDMA send CQEs).

## Mental Model

Think of a **pallet pool** shared between a warehouse (the application) and a trucking company (kernel plus NIC).

- **Supply**: the warehouse must leave *empty* pallets at the dock before trucks arrive. Too few and trucks turn away (drops, `-ENOBUFS`, RNR NAK).
- **Delivery**: the trucker says "your goods are on pallet 17". Pallet 17 is now **checked out** to the warehouse.
- **Return**: when the warehouse has unloaded pallet 17, it hands it back. The styles differ: a slip in a return box (shared-memory ring), a claim ticket handed over at a counter (a syscall with a token), or simply putting it back on the empty-pallet stack (re-posting it).
- **Audit**: the trucker must never accept a pallet number the warehouse was not given, or two returns of the same pallet. Otherwise the warehouse could make the NIC overwrite memory still in use.
- **Eviction**: if the warehouse goes bankrupt (the process exits or the socket closes), someone must reclaim every pallet it still held.

Outbound, the warehouse *lends* a loaded pallet to the trucker, gets a receipt at pickup ("queued"), and a separate note when the pallet is back ("ACKed, you may reuse it").

Each mechanism below answers the same five questions: **who supplies, how is delivery reported, how are buffers returned, how does the kernel validate returns, and what happens on starvation and teardown?**

## How It Works

### 1. AF_XDP: FILL ring in, RX ring out (the pure address-passing model)

AF_XDP is the most literal ownership protocol: **only UMEM addresses move, and every address belongs to exactly one side at a time.** The application registers a **UMEM** (one contiguous area cut into equal chunks, or arbitrary offsets in *unaligned chunk mode*) and gets four single-producer/single-consumer rings ([[af-xdp]]).

- **Supply**: userspace produces UMEM addresses into the **FILL ring**. Ownership passes to the kernel at the producer-index store. In aligned mode the kernel masks the low log2(chunk_size) bits. In unaligned mode the address is used as given.
- **Delivery**: in zero-copy mode the driver's NAPI refill calls `xsk_buff_alloc()`/`xsk_buff_alloc_batch()`, which pops FILL entries into `struct xdp_buff_xsk`s whose DMA addresses were precomputed at bind time (`xp_dma_map()`). The NIC DMAs straight into the chunk. The XDP program redirects to the XSKMAP, and the kernel posts an **RX descriptor** `{addr, len, options}` (with `XDP_PKT_CONTD` for multi-buffer frames). Ownership is back with userspace.
- **Return**: there is **no separate return step**. A used RX buffer is simply produced back into the FILL ring. Return and supply are the same operation, and the application chooses freely which chunk to recycle.
- **Validation**: FILL addresses are bounds-checked against the UMEM. The kernel does *not* track which addresses userspace currently holds. It cannot detect the same chunk being posted twice or posted while userspace is still reading it. The docs are blunt: feeding one buffer into multiple rings at once causes corruption. The protection boundary is "you can only corrupt your own UMEM", not "you can only return what you were given".
- **Starvation**: an empty FILL ring means no RX descriptors appear. Packets are dropped and counted in `rx_fill_ring_empty_descs`. With `XDP_USE_NEED_WAKEUP`, the kernel sets a flag on the FILL ring asking userspace to `poll()` so the driver resumes refilling.
- **Teardown**: closing the socket unbinds the queue from zero-copy mode (`xp_clear_dev()`). Since UMEM is the application's own memory, nothing needs to be "given back". The pages are unpinned when the last user drops the pool.
- **Copy mode**: the driver owns its own [[page-pool]] pages, and `__xsk_rcv()` `memcpy()`s into a FILL-supplied chunk. The protocol is identical, only the copy differs. This is why AF_XDP apps work unchanged on any NIC.

**Why this design**: AF_XDP came from the DPDK world, where the application is trusted with its own packet memory. Tracking per-chunk ownership in the kernel would cost cache lines per packet. Instead the kernel only guarantees isolation *between* UMEMs.

### 2. io_uring provided buffer rings: supply-only, the kernel picks late

A **provided buffer ring** ([[provided-buffer-rings]]) is not zero-copy in the DMA sense. Data is still copied from skbs into the buffer. But it solves the same *supply* problem: the application should not have to commit a buffer per socket before data arrives. With thousands of idle connections, per-socket buffers waste memory.

- **Supply**: userspace writes `struct io_uring_buf {addr, len, bid}` entries into a shared ring and bumps `tail`. The kernel consumes from `head` when a `recv` with `IOSQE_BUFFER_SELECT` actually has data (**late binding**). The group is named by `bgid`.
- **Delivery**: the CQE carries `IORING_CQE_F_BUFFER` and the buffer id in `flags >> IORING_CQE_BUFFER_SHIFT`. With **bundles** (6.10) one CQE covers a run of consecutive bids. With **incremental consumption** (`IOU_PBUF_RING_INC`, 6.12) a large buffer is carved across several CQEs, and `IORING_CQE_F_BUF_MORE` means the kernel still owns the tail of that bid.
- **Return**: re-add the entry to the ring (the same operation as supply, as in AF_XDP).
- **Validation**: largely unnecessary. The kernel *copies* into `addr` via `copy_to_user`, so a bad or duplicate address only harms the application.
- **Starvation**: `head == tail` makes the request fail with `-ENOBUFS`. For multishot recv this is a terminal CQE, and the app must refill and re-arm. This is deliberate backpressure. `IORING_REGISTER_PBUF_STATUS` exposes the kernel head.
- **Variations**: provided buffers for **send** (6.10, [LWN](https://lwn.net/Articles/962809/)) turn the same ring into an ordered send queue. **Kernel-managed buffer rings** (`IOBL_KERNEL_MANAGED`, proposed for FUSE-over-io_uring zero-copy, Dec 2025) invert supply: the kernel allocates the ring's memory and recycles buffers itself, so userspace only reads.

### 3. io_uring zcrx: refill ring with per-buffer user refcounts

**zcrx** ([[zero-copy-rx-zcrx]]) keeps the kernel TCP stack in charge while landing payload in a user-registered **area**. Unlike AF_XDP, the kernel must defend against the application, because the same buffers are also referenced by kernel skbs, TCP's receive queue and the page pool.

- **Supply**: the application doesn't supply buffers explicitly. At registration the area is cut into `net_iov`s ([[netmem-and-net-iov-abstraction]]), and io_uring installs itself as the queue's **page-pool memory provider**. When the driver refills RX descriptors, the page pool calls `io_pp_zc_alloc_netmems()`. Supply is therefore **kernel-pulled** from a pool the app pre-donated.
- **Delivery**: `IORING_OP_RECV_ZC` walks skb frags. For a frag that is one of this ifq's `net_iov`s, it takes a **user ref** (`io_zcrx_get_niov_uref()`) and a page-pool ref, then posts a 32-byte CQE whose extension holds `off = area id | niov offset + frag offset`. Frags from other queues, and linear header data, are **copied** into a fallback niov, with the same CQE format and a `ZCRX_EVENT_COPY` event, so the app's return logic is uniform.
- **Return**: userspace writes `struct io_uring_zcrx_rqe {off, len}` into the **refill ring** and advances its tail. No syscall. The kernel drains it lazily, the next time the page pool needs buffers (`io_zcrx_ring_refill()`).
- **Validation**: this is the key difference from AF_XDP. Each niov has a **user refcount** in a kernel-private array (`area->user_refs[]`). `io_parse_rqe()` validates area id and offset, and `io_zcrx_put_niov_uref()` is a cmpxchg loop that **refuses to decrement below zero**. A double return or a never-delivered offset is a no-op, not a corruption. Only when the user ref *and* the page-pool ref reach zero is the niov reusable. Kernel holders (retransmit queues, skbs still in flight) can't be overridden by userspace.
- **Starvation**: the NIC's page pool finds nothing to allocate and the driver drops packets. `ZCRX_EVENT_ALLOC_FAIL` (2026) posts a one-shot auxiliary CQE, re-armed with `ZCRX_CTRL_ARM_EVENT`, so a drought is visible without flooding the CQ.
- **Teardown**: `io_zcrx_scrub()` atomically takes every outstanding user ref (`atomic_xchg(..., 0)`) and returns the niovs. **Revocation** is explicit. The ifq's `refs` keep area memory pinned until the last in-flight skb is freed.
- **Sharing**: ifqs can be exported as fds and imported by other rings (2025–26), which then share one refill ring. Coordinating that ring between threads is userspace's job, since it is single-producer.

### 4. Devmem TCP RX: socket-local tokens and a return syscall

**Devmem TCP** ([[devmem-tcp-rx-dmabuf-binding-and-token-recycling]]) uses the same page-pool memory-provider hooks as zcrx, but the memory is a **dma-buf** (often GPU memory the CPU can't read), and the API is plain sockets.

- **Supply**: kernel-pulled, as with zcrx. `mp_dmabuf_devmem_alloc_netmems()` hands out niov-sized ranges from the binding's genpool.
- **Delivery**: `recvmsg(MSG_SOCK_DEVMEM)` → `tcp_recvmsg_dmabuf()` returns `SCM_DEVMEM_DMABUF` cmsgs `{frag_offset, frag_size, frag_token, dmabuf_id}`. The **token** is an index into the socket's `sk->sk_user_frags` xarray, which maps it to the `netmem_ref`. The kernel takes a page-pool ref for the user's hold. Allocation is batched (`tcp_xa_pool_refill()`/`commit()`).
- **Return**: `setsockopt(SO_DEVMEM_DONTNEED)` with up to 128 `{token_start, token_count}` ranges and 1024 frags per call. `sock_devmem_dontneed()` erases each token and puts the netmem. **One syscall per batch.**
- **Validation**: tokens are **unforgeable and socket-local**. Userspace can only name xarray entries the kernel put in *its* socket, and a missing entry (double return, garbage) is silently skipped. This is stronger than an offset scheme: the application never names memory, only handles.
- **Starvation**: slow `DONTNEED`s drain the genpool and the NIC drops. There's no in-band event; operators watch page-pool and driver drop stats.
- **Teardown**: `tcp_release_user_frags()` on socket destroy puts every outstanding token. The binding (and the dma-buf mapping) lives until the last niov ref is gone, even after the netlink socket that created it closes.

### 5. RDMA receive queues and SRQ: pre-posted work requests, no return step

RDMA's two-sided `SEND`/`RECV` model ([[queue-pairs-and-completion-queues]]) predates all of the above and is the hardware-native version of the protocol.

- **Supply**: the application posts `struct ib_recv_wr`s (`ibv_post_recv()`) whose scatter-gather entries `{addr, length, lkey}` point into a **registered memory region** ([[memory-registration-and-ib-umem]]). Each incoming SEND consumes **exactly one** receive WQE, in order, regardless of size. The WQE must be big enough for the largest possible message.
- **Delivery**: a CQE with `wr_id` (the app's own tag, typically a buffer index) and `byte_len`. Ownership returns to the app.
- **Return**: re-post a receive WR. As in AF_XDP, supply and return are the same.
- **Validation**: done by the **NIC**, via the lkey and MR bounds. There's no per-buffer ownership tracking. A WR re-posted while the app still reads it will be overwritten, which is the app's bug.
- **Starvation**: an empty RQ makes the responder answer **RNR NAK** (Receiver Not Ready) on reliable-connected QPs. The sender backs off and retries up to `rnr_retry` times (7 = infinite), then fails the QP with `IBV_WC_RNR_RETRY_EXC_ERR`. This is transport-level backpressure, unlike the silent drops of Ethernet-based schemes. On UD/UC the message is dropped.
- **SRQ (Shared Receive Queue)**: with thousands of connected QPs, per-QP receive rings multiply memory (QPs × depth × max message size). `ib_create_srq()`/`ibv_create_srq()` gives many QPs one receive pool, the RDMA equivalent of provided buffer rings' "don't commit buffers per connection". Refill is driven by a **low-watermark event**: setting `srq_limit` via `ibv_modify_srq()` arms a **one-shot** `IBV_EVENT_SRQ_LIMIT_REACHED` async event that fires when the posted count falls below the limit, and must be re-armed each time. That's the same one-shot pattern zcrx adopted for `ZCRX_EVENT_ALLOC_FAIL`. **XRC SRQs** extend sharing across processes on a node.
- **Multi-packet RQ (striding RQ)**: mlx5 lets one large receive WQE be split into fixed **strides**, one packet per stride, so a single post supplies buffers for many messages. It is the hardware analogue of `IOU_PBUF_RING_INC`: one buffer, many completions, returned only when fully consumed.
- **One-sided ops need no receive protocol at all.** `RDMA_WRITE`/`READ` target memory named by the peer's `rkey`. Ownership is negotiated by the application protocol (credits, "done" messages), which is why RDMA ULPs such as NVMe-oF and RDS pair a small SEND/RECV control channel with one-sided bulk data.

### 6. Send side: lending buffers and learning when they come back

On transmit the direction flips: the application **lends** a buffer, and the question is how it learns the loan is over. Because TCP may retransmit, "sent" is not "done". The buffer is free only after the data is ACKed and the last skb referencing it is freed.

- **`MSG_ZEROCOPY`** (4.14, TCP/UDP/vsock): `send(MSG_ZEROCOPY)` on a socket with `SO_ZEROCOPY` pins the user pages and attaches them as skb frags, with a `ubuf_info` that every skb references. When the last reference drops, a notification lands on the **socket error queue**: `recvmsg(MSG_ERRQUEUE)` returns `sock_extended_err` with `ee_origin = SO_EE_ORIGIN_ZEROCOPY` and an **inclusive range** `[ee_info, ee_data]` of per-socket send sequence numbers. Consecutive notifications are coalesced (for TCP, at most one outstanding). `SO_EE_CODE_ZEROCOPY_COPIED` says the kernel fell back to copying, which it always does for loopback and devices without scatter-gather. Failure modes: `ENOBUFS` when optmem or `RLIMIT_MEMLOCK` is exceeded.
- **io_uring `SEND_ZC`/`SENDMSG_ZC`** (6.0/6.1, [[io-uring-zero-copy-networking]]): same `ubuf_info` machinery (embedded in an `io_notif`), but completion is **two CQEs** on the ring: the first (`IORING_CQE_F_MORE`) says "queued", and the second (`IORING_CQE_F_NOTIF`, same `user_data`) says "buffer free". `IORING_SEND_ZC_REPORT_USAGE` reports copy fallback. With `IORING_RECVSEND_FIXED_BUF`, a [[registered-resources|registered buffer]] avoids per-send page pinning. The original 2022 design ([LWN](https://lwn.net/Articles/900083/)) had registered **notification slots** that userspace flushed explicitly, letting many sends share one notification. That was simplified before merge ([LWN](https://lwn.net/Articles/906803/)) to per-request notifications, with batching later added via linked notifications.
- **Devmem TX** (6.14, [[devmem-tcp-tx]]): `MSG_ZEROCOPY` where the iovec "address" is an **offset into a TX-bound dma-buf** named by cmsg. `net_devmem_get_niov_at()` finds pre-mapped niovs. Completion is the same error-queue range protocol.
- **AF_XDP TX**: userspace posts TX descriptors. After the NIC's DMA completes (zero-copy) or the skb is freed (copy mode), the kernel produces the address into the **COMPLETION ring**. There's no ACK and no retransmit, so completion means "the NIC is done", not "the peer got it". The docs note a completion does not guarantee successful transmission. Invalid descriptors are also completed, so userspace always gets its chunk back.
- **RDMA send**: `ibv_post_send()` with `IBV_SEND_SIGNALED` produces a CQE once the WQE completes. For RC this is after the **transport ACK**, so the buffer is truly free. Unsignaled sends (`sq_sig_type`) let the app take one CQE per N WRs, which implicitly completes all earlier WRs on that SQ, the hardware form of notification coalescing. `IBV_SEND_INLINE` copies small payloads into the WQE so the buffer is free immediately, a deliberate "copy is cheaper than tracking" choice mirroring the ~10 KB threshold below which `SEND_ZC` doesn't pay.

### 7. Side-by-side

**Receive**

| | AF_XDP (ZC) | Provided buf ring | io_uring zcrx | Devmem TCP RX | RDMA RQ / SRQ |
|---|---|---|---|---|---|
| Memory | UMEM (user pages) | any user memory | registered area (user pages or dma-buf) | dma-buf (device memory) | registered MR |
| Who supplies to device | app → FILL ring | app → buf ring (kernel picks at recv) | kernel page pool pulls from donated area | kernel page pool pulls from genpool | app → post_recv / post_srq_recv |
| Delivery handle | RX desc `{addr,len}` | CQE bid | CQE `off` (area + offset) | cmsg token + dma-buf offset | CQE `wr_id` |
| Return path | re-post to FILL ring (shm) | re-add to buf ring (shm) | refill ring RQE (shm) | `SO_DEVMEM_DONTNEED` (syscall, batched) | re-post WR (doorbell) |
| Kernel tracks user holds? | no | no (copy) | yes: per-niov `user_refs` | yes: per-socket token xarray | no (NIC checks lkey bounds) |
| Double return | corrupts own UMEM | harmless | no-op (floor at 0) | no-op (token gone) | overwrites own buffer |
| Starvation | drop + `fill_ring_empty` stat; need_wakeup | `-ENOBUFS`, multishot terminates | drop; `ZCRX_EVENT_ALLOC_FAIL` (one-shot) | drop | RNR NAK → retry (RC); `SRQ_LIMIT_REACHED` (one-shot) |
| Teardown | unbind queue, unpin UMEM | drop ring | scrub user refs, wait for skbs | release socket tokens, binding outlives netlink sk | destroy QP/SRQ, flush WRs with error CQEs |
| Stack | none (XDP only) | full kernel stack (copy) | full kernel TCP | full kernel TCP | hardware transport |

**Send**

| | Completion signal | Means | Coalescing | Copy-fallback signal |
|---|---|---|---|---|
| `MSG_ZEROCOPY` | error queue, `[lo,hi]` range | last skb freed (TCP: ACKed) | range merging | `SO_EE_CODE_ZEROCOPY_COPIED` |
| io_uring `SEND_ZC` | 2nd CQE `F_NOTIF` | last skb freed | linked notifs | `IORING_NOTIF_USAGE_ZC_COPIED` |
| Devmem TX | error queue range | last skb freed | range merging | n/a (always ZC) |
| AF_XDP TX | COMPLETION ring addr | NIC DMA done / skb freed | batch per ring pass | n/a (mode is fixed at bind) |
| RDMA SEND/WRITE | signaled CQE | transport ACK (RC) / sent (UD) | unsignaled WRs | `SEND_INLINE` is explicit copy |

## Key Data Structures

**`struct xdp_desc`** / FILL & COMPLETION `u64` entries (`include/uapi/linux/if_xdp.h`) — AF_XDP ring payloads; `addr`, `len`, `options` (`XDP_PKT_CONTD`).

**`struct io_uring_buf`** (`include/uapi/linux/io_uring.h`) — provided buffer ring entry: `addr`, `len`, `bid`; ring `tail` overlays entry 0's `resv`.

**`struct io_uring_zcrx_rqe`** — zcrx refill entry: `off` (area id in top bits | offset), `len`.

**`struct io_zcrx_area`** — `nia.niovs[]`, `user_refs[]` (the userspace-hold ledger), freelist.

**`struct dmabuf_cmsg`** / **`struct dmabuf_token`** — devmem delivery `{frag_offset, frag_size, frag_token, dmabuf_id}` and return `{token_start, token_count}`.

**`sk->sk_user_frags`** — per-socket xarray, devmem token → `netmem_ref`.

**`struct ubuf_info`** (`include/linux/skbuff.h`) — the send-side loan tracker shared by `MSG_ZEROCOPY`, io_uring `SEND_ZC` (`io_notif_data`) and devmem TX; its refcount is held by every skb referencing the lent pages, and its callback fires the notification.

**`struct ib_srq`** / **`struct ib_srq_attr`** — `max_wr`, `max_sge`, `srq_limit` (low-watermark arming).

## Key Functions / Entry Points

- **`xsk_buff_alloc_batch()`** (`net/xdp/xsk_buff_pool.c`) — driver pulls FILL entries.
- **`io_ring_buffer_select()` / `io_buffers_select()`** (`io_uring/kbuf.c`) — late-binding pick from a provided buffer ring.
- **`io_pp_zc_alloc_netmems()` → `io_zcrx_ring_refill()`**, **`io_zcrx_put_niov_uref()`**, **`io_zcrx_scrub()`** (`io_uring/zcrx.c`) — zcrx supply, validated return, revocation.
- **`tcp_recvmsg_dmabuf()`** (`net/ipv4/tcp.c`), **`sock_devmem_dontneed()`** (`net/core/sock.c`) — devmem token issue/return.
- **`ib_post_srq_recv()`**, **`ib_modify_srq(IB_SRQ_LIMIT)`** (`include/rdma/ib_verbs.h`) — SRQ supply and watermark arming.
- **`msg_zerocopy_realloc()`**, **`skb_zerocopy_iter_stream()`**, **`io_tx_ubuf_complete()`** — send-side loan creation and completion.

## Important Flags & Config Options

- **AF_XDP**: `XDP_ZEROCOPY`/`XDP_COPY`, `XDP_USE_NEED_WAKEUP`, `XDP_UMEM_UNALIGNED_CHUNK_FLAG`, `XDP_SHARED_UMEM`.
- **Provided buffers**: `IOSQE_BUFFER_SELECT`, `IORING_RECVSEND_BUNDLE`, `IOU_PBUF_RING_INC`, `IOU_PBUF_RING_MMAP`.
- **zcrx**: `IORING_SETUP_DEFER_TASKRUN` + `CQE32`/`CQE_MIXED` (required), `rx_buf_len`, `ZCRX_CTRL_FLUSH_RQ`/`ARM_EVENT`/`EXPORT`.
- **Devmem**: `MSG_SOCK_DEVMEM`, `SO_DEVMEM_DONTNEED`; `MAX_DONTNEED_TOKENS` = 128, `MAX_DONTNEED_FRAGS` = 1024.
- **Send ZC**: `SO_ZEROCOPY`, `MSG_ZEROCOPY`, `net.core.optmem_max`, `RLIMIT_MEMLOCK`; `IORING_SEND_ZC_REPORT_USAGE`, `IORING_RECVSEND_FIXED_BUF`.
- **RDMA**: `rnr_retry`/`min_rnr_timer` (QP attrs), `srq_limit`, `IBV_SEND_SIGNALED`, `IBV_SEND_INLINE`, `sq_sig_type`.

## Interactions with Other Subsystems

- **↑ Userspace**: libxdp/xsk helpers, liburing (`io_uring_buf_ring_*`, zcrx helpers), YNL for devmem binding, libibverbs. Every library's core job is to hide the return protocol.
- **→ Page pool / netmem**: zcrx and devmem plug in as memory providers ([[page-pool]], [[netmem-and-net-iov-abstraction]]). The page pool's `pp_ref_count` is the kernel-side half of their two-refcount scheme.
- **→ TCP / skb**: receive-side providers depend on header split and flow steering ([[header-split-and-flow-steering-for-zero-copy-rx]]). Send-side loans ride on skb frag refcounting and `ubuf_info` ([[sk-buff]], [[tcp-ip-stack]]).
- **→ mm**: every protocol assumes pinned, DMA-mapped memory ([[get-user-pages-and-pinning]]). RDMA [[on-demand-paging-odp]] is the exception that lets the NIC fault.
- **← Device drivers**: must implement XSK zero-copy or queue-management ops (`netdev_queue_mgmt_ops`) to host these providers ([[netdev-queue-management-api]]).

## Design Decisions & Tradeoffs

- **Trust the app (AF_XDP, RDMA) vs audit the app (zcrx, devmem).** When the kernel stack never touches the buffer after handing it over, as in AF_XDP (XDP only) and RDMA (hardware only), a bad return can only hurt the application, so no ledger is kept. zcrx and devmem buffers are *also* referenced by kernel TCP (retransmit queues, out-of-order queues), so a forged or duplicate return could hand the NIC memory the kernel still reads. Hence the separate user-hold ledgers (`user_refs[]`, `sk_user_frags`) on top of the page-pool refcount.
- **Offsets vs tokens.** zcrx lets userspace name buffers by *offset* and validates it against the ledger. Devmem hands out *opaque tokens*. Offsets let returns be written into shared memory with no syscall. Tokens make the socket the unit of isolation but cost a `setsockopt` per batch, capped at 128 ranges and 1024 frags. Devmem reviewers chose tokens as a defence against misuse. zcrx, living inside a single-issuer ring, could afford an offset ledger.
- **Supply is return (AF_XDP, RDMA, buffer rings) vs kernel-pulled supply (zcrx, devmem).** When the app posts buffers directly, it controls placement and can prioritise. When the page pool pulls from a donated area, drivers need no new code (the memory-provider abstraction), at the cost of the app not choosing which buffer is filled next.
- **Starvation semantics.** RDMA RC is the only one with *lossless* backpressure (RNR NAK plus retry). Everything on Ethernet drops, and provided buffer rings fail the request. Watermark events (`SRQ_LIMIT_REACHED`, `ZCRX_EVENT_ALLOC_FAIL`) are one-shot by design, so a sustained drought produces one event, not a storm.
- **Send notifications: error queue vs CQ vs ring.** `MSG_ZEROCOPY`'s error queue reused an existing socket channel but needs an extra syscall and range bookkeeping. io_uring folded it into the CQ as a second CQE. AF_XDP and RDMA had completion rings from the start. All converge on **coalescing** (ranges, linked notifs, unsignaled WRs), because one notification per send costs more than the copy for small messages.
- **Copy fallback must be transparent.** zcrx copy-fallback CQEs, `SO_EE_CODE_ZEROCOPY_COPIED` and `IORING_NOTIF_USAGE_ZC_COPIED` all keep the ownership protocol identical when the fast path isn't available. The app's code doesn't fork, and the reporting makes silent degradation observable.

## How It Has Evolved

- **2000s — RDMA verbs**: RQ/SRQ with lkey-protected pre-posted WRs; SRQ low-watermark events; XRC later extends sharing across processes; mlx5 multi-packet (striding) RQ (~2017).
- **4.14 (2017) — `MSG_ZEROCOPY`** (Willem de Bruijn): send-side loans with error-queue range notifications.
- **4.18 (2018) — AF_XDP**: FILL/COMPLETION address rings; 5.4 need_wakeup; 5.10 shared UMEM across queues; 6.6 multi-buffer.
- **5.7 / 5.19 — io_uring provided buffers**: SQE-based `PROVIDE_BUFFERS` (5.7), replaced in practice by shared-memory buffer rings (5.19); bundles (6.10); incremental consumption (6.12).
- **6.0–6.2 — io_uring `SEND_ZC`**: notification slots simplified into per-request `F_NOTIF` CQEs; usage reporting.
- **6.12 — devmem TCP RX**: tokens + `SO_DEVMEM_DONTNEED`; 6.14 devmem TX over `MSG_ZEROCOPY`.
- **6.15 — io_uring zcrx**: refill ring with user refcounts; 2025–26 ifq sharing, events, multiple areas, dma-buf areas.
- **Late 2025 — kernel-managed buffer rings** proposed for FUSE-over-io_uring, inverting the provided-ring supply direction.

## Further Reading

1. [LWN: io_uring zero copy rx](https://lwn.net/Articles/1004591/) — the zcrx series cover letter
2. [LWN: io_uring zerocopy send](https://lwn.net/Articles/900083/) and [simplified API](https://lwn.net/Articles/906803/)
3. [LWN: provided buffers for send](https://lwn.net/Articles/962809/); [kernel-managed buffer rings for FUSE](https://lwn.net/Articles/1051215/)
4. [kernel.org: AF_XDP](https://www.kernel.org/doc/html/latest/networking/af_xdp.html), [MSG_ZEROCOPY](https://www.kernel.org/doc/html/latest/networking/msg_zerocopy.html), [Devmem TCP](https://www.kernel.org/doc/html/latest/networking/devmem.html), [io_uring zcrx](https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html)
5. [ibv_modify_srq(3)](https://man7.org/linux/man-pages/man3/ibv_modify_srq.3.html); NVIDIA [RDMA Aware Programming: Key Concepts](https://docs.nvidia.com/networking/display/RDMAAwareProgrammingv17/Key+Concepts)
6. [DPDK mlx5 guide: Multi-Packet RQ](https://doc.dpdk.org/guides-20.08/nics/mlx5.html); [IB/mlx5 multi-packet RQ patch](https://www.spinics.net/lists/linux-rdma/msg55779.html)
7. Vault deep dives: [[af-xdp]], [[provided-buffer-rings]], [[zero-copy-rx-zcrx]], [[devmem-tcp-rx-dmabuf-binding-and-token-recycling]], [[devmem-tcp-tx]], [[io-uring-zero-copy-networking]], [[queue-pairs-and-completion-queues]]

## LKML Highlights

- **`<20241016185252.3746190-1-dw@davidwei.uk>`** — io_uring zcrx v6 (David Wei, Pavel Begunkov). Settled on per-niov user refcounts plus a refill ring rather than trusting userspace offsets outright, and on copy fallback so the return protocol is uniform.
- **"Device Memory TCP" RX series (Mina Almasry, 2023–24)** — reviewers pushed socket-local unforgeable tokens and hard `DONTNEED` caps instead of letting userspace name dma-buf offsets, trading a syscall per batch for isolation.
- **"io_uring zerocopy send" (Pavel Begunkov, 2022)** — debated user-flushed notification slots vs per-request notifications. The simpler per-request `F_NOTIF` model won, and batching came back later via linked notifications.
