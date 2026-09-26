---
title: "Devmem TCP TX: Sending from Device Memory"
category: concept
tags: [net, devmem, tcp, msg-zerocopy, dma-buf, netmem]
subsystem: net
kernel_version: "6.16 (devmem TX); 2025–26 (virtual-device / netkit TX via leased queues, unprivileged bind-tx)"
researched: 2026-09-26
status: complete
sources:
  - https://docs.kernel.org/networking/devmem.html
  - https://github.com/torvalds/linux/blob/master/net/core/netdev-genl.c
  - https://github.com/torvalds/linux/blob/master/net/core/devmem.c
  - https://github.com/torvalds/linux/blob/master/net/core/datagram.c
  - https://github.com/torvalds/linux/blob/master/net/core/dev.c
  - https://github.com/torvalds/linux/blob/master/net/ipv4/tcp.c
  - https://lore.gnuweeb.org/io-uring/20250508004830.4100853-1-almasrymina@google.com/
  - https://lkml.indiana.edu/2504.3/03625.html
  - https://lore.kernel.org/lkml/20250227041209.2031104-5-almasrymina@google.com/
---

# Devmem TCP TX: Sending from Device Memory

## Purpose

[[devmem-tcp]] RX lets a TCP socket receive payload straight into accelerator memory. **Devmem TX** is the mirror image: a TCP socket **sends payload straight out of a dma-buf** (GPU memory), so a tensor never gets staged in host RAM on the sending side. The NIC DMAs the payload from device memory, while the kernel builds headers in host memory and runs the full TCP state machine: segmentation, ACKs, retransmission, congestion control. Where RDMA GPUDirect RDMA achieves the same end-to-end GPU→GPU path with a hardware transport, devmem TX+RX does it with ordinary kernel TCP and any TCP peer.

## Mental Model

Devmem TX is **`MSG_ZEROCOPY` with a map instead of an address**. With ordinary `MSG_ZEROCOPY` you hand the kernel a *pointer* to your memory, the kernel pins those pages and attaches them to skbs, and it tells you later (error-queue notification) when the NIC and TCP no longer need them. With devmem TX the "pointer" in your iovec is really an **offset into a pre-registered dma-buf** named by a cmsg. The kernel looks up the pre-mapped chunks (net_iovs) covering that offset and attaches *them* to skbs. Same completion protocol, different memory.

## How It Works

**Step 1 — bind-tx.** The application sends netdev netlink `bind-tx {ifindex, fd}` ([[netdev-netlink-family]]). Unlike `bind-rx`, **`bind-tx` is intentionally unprivileged**: it doesn't reconfigure shared NIC queues, it only DMA-maps the caller's own dma-buf for transmit. `netdev_nl_bind_tx_doit()`:
- requires the device to be present and to declare netmem TX support: `netdev->netmem_tx` must be `NETMEM_TX_DMA` (a physical device that DMAs) or `NETMEM_TX_NO_DMA` (a virtual or passthrough device)
- resolves the **DMA-capable device**: for a physical NIC it's the NIC itself. For a virtual device such as **netkit** (container networking), `netdev_find_netmem_tx_dev()` walks the virtual device's **leased RX queues** to find the underlying physical NIC with `NETMEM_TX_DMA` ([[netdev-queue-management-api]])
- gets the TX DMA device (`netdev_queue_get_dma_dev(bind_dev, 0, NETDEV_QUEUE_TYPE_TX)`)
- calls `net_devmem_bind_dmabuf(bind_dev, vdev, dma_dev, DMA_TO_DEVICE, fd, PAGE_SHIFT, ...)`. The dma-buf size must be a multiple of PAGE_SIZE. The binding carves the mapping into page-sized `net_iov`s as for RX, plus a **`tx_vec`** array indexed by `offset / PAGE_SIZE` so an iovec offset maps to its net_iov in O(1). `vdev` records the virtual device the user bound through, as an opaque cookie.
- replies with the binding `id`.

As with RX, the binding lives as long as the netlink socket that created it.

**Step 2 — socket setup.** `setsockopt(SO_ZEROCOPY, 1)` is required, because devmem memory can't be copied by the kernel, so only zero-copy sends are possible. Binding the socket to the same interface (`SO_BINDTODEVICE`) is recommended so routing can't pick another egress device.

**Step 3 — sendmsg.** The application builds a `msghdr` whose **`iov_base` values are byte offsets into the dma-buf** (not pointers) and `iov_len` the lengths, adds an `SCM_DEVMEM_DMABUF` cmsg carrying the `u32` dmabuf id, and calls `sendmsg(fd, &msg, MSG_ZEROCOPY)`. In `tcp_sendmsg_locked()`:
1. `sock_cmsg_send()` parses the cmsg into `sockc.dmabuf_id`.
2. With `MSG_ZEROCOPY` and `SOCK_ZEROCOPY`, `msg_zerocopy_realloc(..., devmem = true)` gets a `ubuf_info` for completion tracking (devmem sends are never merged into a non-devmem zerocopy notification).
3. **`net_devmem_get_binding(sk, dmabuf_id)`** looks up the binding (must have a `tx_vec`, i.e. be a TX binding) and **checks the route**: the socket's current `dst` (rebuilt if it expired) must egress through `binding->dev` or `binding->vdev`. The DMA addresses in the binding are only valid for that device, so a send routed elsewhere fails with `-ENODEV`, and an unroutable one with `-EHOSTUNREACH`.
4. A `dmabuf_id` without `MSG_ZEROCOPY` (or without a valid binding) is `-EINVAL`.

Then the normal TCP send loop runs. When it needs to add payload to an skb, `skb_zerocopy_iter_stream()` → `__zerocopy_sg_from_iter()` uses **`zerocopy_fill_skb_from_devmem()`** instead of pinning user pages:
- only `ITER_IOVEC`/`ITER_UBUF` iterators are accepted (the "addresses" are offsets)
- an skb that already has readable frags can't take devmem frags (no mixing)
- for each iovec segment, `net_devmem_get_niov_at(binding, offset)` returns the net_iov and in-page offset, `get_netmem()` takes a reference, and `skb_add_rx_frag_netmem()` attaches it as a frag, making the skb **unreadable**. It stops at `MAX_SKB_FRAGS` (`-EMSGSIZE`).

Because the payload is unreadable, the stack can't checksum it, so TX requires **hardware checksum offload**. TSO/GSO segmentation works because it only splits frag descriptors and rewrites headers.

**Step 4 — transmit validation.** Just before handing the skb to the driver, `validate_xmit_skb()` calls **`validate_xmit_unreadable_skb(skb, dev)`**:
- readable skbs, and devices declaring `NETMEM_TX_NO_DMA`, pass through
- devices with `NETMEM_TX_NONE` get the skb **dropped** (they'd try to DMA-map or read net_iovs)
- otherwise, if the first frag is a devmem net_iov whose binding's `dev` isn't this device, drop it. A packet redirected (by routing changes, tc, bonding) to a device the dma-buf isn't mapped for must never reach its DMA engine.

**Step 5 — driver.** A netmem-TX driver posts frags using `skb_frag_dma_map()`, which for net_iovs returns the pre-mapped address, and on completion unmaps with `netmem_dma_unmap_page_attrs()`, which skips unmapping for provider memory ([[netmem-and-net-iov-abstraction]]). Drivers advertise support via `netdev->netmem_tx`.

**Step 6 — completion and buffer reuse.** As with `MSG_ZEROCOPY`, TCP keeps the skbs (and therefore net_iov references) until the data is ACKed, and retransmits resend from the same device memory. When the last skb referencing the `ubuf_info` is freed, the kernel queues a completion notification on the socket's **error queue** (`recvmsg(MSG_ERRQUEUE)`, a `sock_extended_err` with `SO_EE_ORIGIN_ZEROCOPY` and a `[lo, hi]` range of send sequence numbers). Only then may the application overwrite those dma-buf regions. net_iovs stuck in the TX path (e.g. awaiting retransmit after unbind) keep the binding's percpu ref alive, so the mapping outlives the netlink socket if needed.

**Unbinding.** Closing the netlink socket drops the user ref. The binding frees (unmap, detach, put) once every in-flight skb has released its net_iovs.

## Key Data Structures

**`struct net_devmem_dmabuf_binding`** (`net/core/devmem.h`) — as for RX, plus `direction = DMA_TO_DEVICE`, `tx_vec[]` (offset → net_iov), `vdev` (virtual device cookie).

**`struct sockcm_cookie.dmabuf_id`** — parsed from the `SCM_DEVMEM_DMABUF` cmsg.

**`netdev->netmem_tx`** — `NETMEM_TX_NONE`, `NETMEM_TX_DMA`, `NETMEM_TX_NO_DMA`.

**`struct ubuf_info` / `ubuf_info_msgzc`** — `MSG_ZEROCOPY` completion tracking, reused unchanged.

## Key Functions / Entry Points

- **`netdev_nl_bind_tx_doit()` / `netdev_find_netmem_tx_dev()`** (`net/core/netdev-genl.c`)
- **`net_devmem_bind_dmabuf()` (TX branch)** / **`net_devmem_get_niov_at()`** (`net/core/devmem.c`)
- **`net_devmem_get_binding()`** — binding lookup + route/device check
- **`tcp_sendmsg_locked()`** (`net/ipv4/tcp.c`) — cmsg + `MSG_ZEROCOPY` handling
- **`zerocopy_fill_skb_from_devmem()`** (`net/core/datagram.c`) — offsets → net_iov frags
- **`validate_xmit_unreadable_skb()`** (`net/core/dev.c`) — last-chance device check
- **`netmem_dma_unmap_page_attrs()`** — driver completion helper

## Important Flags & Config Options

- `CONFIG_NET_DEVMEM`
- netlink `bind-tx` (`ifindex`, `fd` → `id`), unprivileged
- `SO_ZEROCOPY` + `MSG_ZEROCOPY` (mandatory), `SCM_DEVMEM_DMABUF` cmsg (u32 id), `SO_BINDTODEVICE` (recommended)
- `MSG_ERRQUEUE` completions, as in `MSG_ZEROCOPY`
- NIC: hardware checksum offload, SG; driver `netmem_tx` declaration

## Interactions with Other Subsystems

- **↑ Userspace**: YNL `netdev_bind_tx()`, `sendmsg` with offset iovecs, error-queue completion handling (see `ncdevmem` `do_client`)
- **→ MSG_ZEROCOPY infrastructure**: `ubuf_info`, error-queue notifications, skb frag lifetime
- **→ routing**: `net_devmem_get_binding()` ties sends to the bound egress device ([[ip-routing]])
- **→ dma-buf**: `DMA_TO_DEVICE` mapping of the exporter's memory ([[dma-buf-sharing]])
- **→ drivers / netmem**: netmem-aware TX DMA handling ([[netmem-and-net-iov-abstraction]])
- **→ netkit / leased queues**: containerized senders reach the physical NIC's DMA via queue leasing ([[netdev-queue-management-api]])
- **Compared with io_uring SEND_ZC**: io_uring zero-copy send uses the same `ubuf_info` machinery but with CQE notifications instead of the error queue, and registered *host* buffers. Mainline io_uring doesn't yet send from dma-bufs ([[io-uring-zero-copy-networking]])
- **Compared with RDMA**: GPUDirect RDMA registers the same kind of dma-buf as an MR and the NIC's transport handles reliability. Devmem TX keeps TCP in the kernel and requires only a netmem-capable Ethernet NIC ([[memory-registration-and-ib-umem]])

## Design Decisions & Tradeoffs

- **Piggyback on MSG_ZEROCOPY.** The TX series is small because buffer lifetime, notifications and retransmission semantics were already solved for user pages. The cost is inheriting MSG_ZEROCOPY's clunky error-queue completion API.
- **Offsets in iovecs.** Reusing `struct iovec` avoids a new send API, but the "pointer" fields are really offsets, which is surprising and restricted to IOVEC/UBUF iterators.
- **Device pinning by route check + xmit validation.** DMA addresses are device-specific, so the kernel checks the route at send time *and* validates at xmit time, catching redirects that happen after sendmsg (tc, bonding, route changes). Mismatched packets are dropped rather than risking wild DMA.
- **Unprivileged bind-tx vs privileged bind-rx.** TX mapping only affects the caller's own sends, whereas RX binding reconfigures shared queues. Making TX unprivileged lets ordinary (containerized) workloads use it, with netkit leasing for the virtual-device case.
- **No kernel-side copy fallback.** Unlike RX's `SCM_DEVMEM_LINEAR`, there is no way to copy device memory, so misconfiguration fails loudly (`-ENODEV`, `-EINVAL`, drops).

## How It Has Evolved

- **RFC v1 (2023)** — TX included in the original devmem series, then dropped to land RX first
- **2025 (v1–v14, Mina Almasry)** — TX rebased on net_iov/netmem; `bind-tx`, `tx_vec`, `SCM_DEVMEM_DMABUF` on sendmsg, `validate_xmit_unreadable_skb()`; fixes for dma-buf unmapping in invalid (atomic) contexts; merged for **6.16**
- **2025–26** — `netmem_tx` modes including `NETMEM_TX_NO_DMA` for virtual devices; netkit support by resolving the physical device through leased RX queues; bind-tx made explicitly unprivileged; more drivers (gve, mlx5, bnxt, fbnic)

## Further Reading

- kernel.org — [Device Memory TCP: TX Interface](https://docs.kernel.org/networking/devmem.html)
- Patch series — [Device memory TCP TX v14](https://lore.gnuweeb.org/io-uring/20250508004830.4100853-1-almasrymina@google.com/); [v12 cover](https://lkml.indiana.edu/2504.3/03625.html); [TX documentation patch](https://lore.kernel.org/lkml/20250227041209.2031104-5-almasrymina@google.com/)
- Selftest — `tools/testing/selftests/drivers/net/hw/ncdevmem.c` (`do_client`)
- Related: [[devmem-tcp]], [[devmem-tcp-rx-dmabuf-binding-and-token-recycling]], [[netmem-and-net-iov-abstraction]], [[io-uring-zero-copy-networking]]

## LKML Highlights

- **`<20250508004830.4100853-1-almasrymina@google.com>`** — "Device memory TCP TX" v14 (Mina Almasry). The TX path "largely piggybacks on the existing MSG_ZEROCOPY implementation": bind-tx via netlink, offsets in iovecs plus the dmabuf-id cmsg, and binding lifetime tied to the netlink socket so crashes auto-unbind.
- **`<20250227041209.2031104-5-almasrymina@google.com>`** — the TX documentation patch that defines the userspace contract (SO_ZEROCOPY required, SO_BINDTODEVICE recommended, error-queue completions, don't modify buffers in flight).
- **Later v1x revisions (2025)** — fixed dma-buf unmapping from invalid (atomic) context when the last TX skb is freed, by deferring binding release to a workqueue (`unbind_w` / `__net_devmem_dmabuf_binding_free`).
