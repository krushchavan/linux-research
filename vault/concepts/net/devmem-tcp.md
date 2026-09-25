---
title: "Device Memory TCP (devmem TCP)"
category: concept
tags: [networking, devmem, zero-copy, dma-buf, netmem, gpu]
subsystem: net
kernel_version: "6.12"
researched: 2026-09-25
status: complete
explained: "[[devmem-tcp-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/networking/devmem.html
  - https://www.kernel.org/doc/html/latest/networking/netmem.html
  - https://lwn.net/Articles/937882/
  - https://lwn.net/Articles/979549/
  - https://lwn.net/Articles/955144/
  - https://lwn.net/Articles/1025247/
  - https://lwn.net/Articles/992404/
---

# Device Memory TCP (devmem TCP)

> 📘 Plain-language version: [[devmem-tcp-explained]]

## Purpose

Distributed ML training and inference move huge tensors between accelerators on different machines. Without help, each transfer goes GPU → host RAM (copy over PCIe) → NIC → network → NIC → host RAM → GPU (another PCIe copy). That burns host memory bandwidth and PCIe bandwidth, and the data crosses the root complex twice even though the host CPU never needs to look at it. RDMA/GPUDirect avoids this but needs special fabrics and bypasses TCP. Devmem TCP, by Mina Almasry and colleagues at Google, merged for RX in **6.12**, lets an ordinary kernel TCP socket receive payloads *directly into device memory* exported as a dma-buf, and later send from it. Headers still go through the normal TCP/IP stack in host memory.

## Mental Model

It's **mail for a sealed vault**. The post office (the kernel TCP stack) still reads every envelope (the header), tracks deliveries, sends receipts and resends lost letters. But the letter contents go straight into a vault (GPU memory) whose inside the post office never sees. The recipient gets a slip saying "your letter is in vault 7, shelf 1234, length 4096" (a cmsg with a dma-buf offset), and hands the slip back when they've emptied that shelf (a token release).

## How It Works

**Preconditions on the NIC.** Three NIC features make it possible to put *only* the right payloads in device memory. They are the same ones [[io-uring-zero-copy-networking|io_uring zcrx]] needs:
- *Header/data split* (`ethtool -G … tcp-data-split on`): the NIC writes each packet's headers into one buffer and its payload into another.
- *Flow steering* (`ethtool -N` n-tuple rules): the application's flows go to a chosen RX queue.
- *RSS reconfiguration* (`ethtool -X`): nothing else lands on that queue.

**Binding device memory to a queue.** The application (or its runtime) exports accelerator memory as a **dma-buf**, the kernel's cross-device buffer-sharing object. In tests `udmabuf` fakes one from host memory. Over the netdev generic-netlink family it sends `bind-rx` (`NETDEV_CMD_BIND_RX`) with the dma-buf fd, ifindex and RX queue ids. The kernel then:
- creates a `net_devmem_dmabuf_binding`
- attaches and maps the dma-buf for the NIC, which yields a scatter-gather table of DMA addresses
- carves those DMA ranges into `net_iov`s, small descriptors each standing for one page-sized chunk of device memory, kept in a genpool allocator
- installs the binding as the queue's [[page-pool]] **memory provider** and restarts the RX queue through the queue-management API (`netdev_rx_queue_restart()` → the driver's `ndo_queue_mem_alloc`/`ndo_queue_start`)

The binding's lifetime is tied to the netlink socket, so if the process dies the queue is automatically unbound. It returns a `dmabuf_id`.

**Why `net_iov` instead of `struct page`.** Device memory has no `struct page`: it isn't system RAM, and GPU drivers deliberately don't create pages for it. The networking stack, however, was built on pages. The solution was the **netmem** abstraction. `netmem_ref` is a tagged pointer that is either a page or a `net_iov`, and the page pool, skb fragments and TCP receive paths were converted to carry `netmem_ref`. A `net_iov` mirrors the fields the page pool needs (pool pointer, DMA address, refcount) without pretending to be a page.

**Receiving.** The driver refills its descriptors from the page pool as usual, but the pool now hands out `net_iov`s from the dma-buf. The NIC DMAs each payload straight into GPU memory, and the header into a normal host page. The driver builds an skb whose linear part holds the header and whose frags reference `net_iov`s. The skb is marked **unreadable** (`skb->unreadable`), and this is a hard rule for the rest of the stack: nothing may touch the payload bytes. So:
- no software checksum (the NIC must have validated it)
- no copying to userspace
- no `skb_pull` into the payload
- loopback, tcpdump payload capture and BPF payload access are impossible for these flows
- GRO and coalescing only merge frags of the same kind

TCP processes sequence numbers, ACKs, windows and retransmits normally, because those live in headers.

**Delivering to the application.** The application calls `recvmsg()` with `MSG_SOCK_DEVMEM`. Instead of copying bytes, `tcp_recvmsg_dmabuf()` walks the receive queue and emits control messages:
- **`SCM_DEVMEM_DMABUF`**: a `struct dmabuf_cmsg` with `frag_offset` (where in the dma-buf the data sits), `frag_size`, `dmabuf_id`, and a `frag_token` identifying this reference.
- **`SCM_DEVMEM_LINEAR`**: this part landed in host memory (e.g. header split didn't separate it). The data is copied into the iov as normal.

The kernel keeps a user reference on each delivered `net_iov`, tracked per socket in an xarray keyed by token, so the NIC can't overwrite data the application hasn't consumed yet. The application runs its GPU kernels on the data at those offsets.

**Returning buffers.** When done, the application calls `setsockopt(SO_DEVMEM_DONTNEED)` with an array of token ranges. That drops the user references, and the `net_iov`s return to the page pool for the NIC to refill. The amount per call is bounded (the docs cite 128 tokens and 1024 frags). Applications that hold tokens too long starve the queue and cause drops. That is the main operational hazard.

**Transmit (later).** TX support uses `bind-tx` to map a dma-buf for the NIC's transmit direction, then `sendmsg()` with `MSG_ZEROCOPY` and a `SCM_DEVMEM_DMABUF` cmsg. The iov now holds *offsets into the dma-buf*, not user pointers. The NIC DMAs payload straight from device memory, and completion notifications arrive on the error queue as for regular `MSG_ZEROCOPY`. Before transmit, `validate_xmit_unreadable_skb()` checks that the packet is leaving through the device the dma-buf was bound to.

**Failure path.** If a flow isn't steered to the bound queue, its data arrives in host memory and is reported as `SCM_DEVMEM_LINEAR`, which is correct but slower. If the provider runs out of `net_iov`s, the NIC drops packets and TCP retransmits. If the device can't checksum or split headers, binding is refused. Unbinding restarts the queue back onto ordinary pages.

## Key Data Structures

**`struct net_iov`** (`include/net/netmem.h`) — a chunk of non-page memory: owner area, `pp`, `dma_addr`, `pp_ref_count` (the netmem-desc fields shared with `struct page`).

**`netmem_ref`** — tagged handle, page or net_iov; the currency of the page pool and skb frags.

**`struct net_devmem_dmabuf_binding`** (`net/core/devmem.h`) — dma-buf attachment, SG table, genpool of net_iovs, bound queues, id, TX vector.

**`struct dmabuf_cmsg`** (uapi) — `frag_offset`, `frag_size`, `frag_token`, `dmabuf_id`.

**`struct dmabuf_token`** (uapi) — `token_start`, `token_count` for `SO_DEVMEM_DONTNEED`.

## Key Functions / Entry Points

**`netdev_nl_bind_rx_doit()` / `net_devmem_bind_dmabuf()`** (`net/core/netdev-genl.c`, `net/core/devmem.c`) — bind a dma-buf to queues.
**`netdev_rx_queue_restart()`** — swap a queue's memory provider.
**`mp_dmabuf_devmem_alloc_netmems()`** — page-pool provider allocation from the genpool.
**`tcp_recvmsg_dmabuf()`** (`net/ipv4/tcp.c`) — cmsg-based receive.
**`sock_devmem_dontneed()`** — token release.
**`validate_xmit_unreadable_skb()`** — TX safety check.

## Important Flags & Config Options

- `MSG_SOCK_DEVMEM` (recvmsg), `SO_DEVMEM_DONTNEED`, `SCM_DEVMEM_DMABUF`, `SCM_DEVMEM_LINEAR`.
- Netlink `bind-rx` / `bind-tx` (`tools/net/ynl`).
- `PP_FLAG_ALLOW_UNREADABLE_NETMEM` — the driver's page pool can accept unreadable memory.
- `ethtool` header split, n-tuple steering and RSS indirection settings.
- `CONFIG_NET_DEVMEM`, `CONFIG_DMA_SHARED_BUFFER`.
- Driver support: Google gve first, then mlx5, bnxt and others (shared with io_uring zcrx).

## Interactions with Other Subsystems

- **↑ Userspace**: ML runtimes and collective-communication libraries (NCCL-style plugins), with `ncdevmem` as the reference and test tool.
- **→ [[page-pool]]**: devmem is a page-pool memory provider handing out `net_iov`s.
- **→ dma-buf / [[dma-mapping-api]]**: attaches the accelerator's buffer and maps it for the NIC.
- **→ [[network-device-and-napi]]**: queue restart API; drivers must support header split and unreadable netmem.
- **→ [[sk-buff]] / [[tcp-ip-stack]]**: unreadable frags; TCP runs unchanged on headers.
- **↔ [[io-uring-zero-copy-networking]]**: zcrx is a sibling provider using the same netmem/queue infrastructure but user memory and io_uring completions.

## Design Decisions & Tradeoffs

- **Keep TCP in the kernel.** Unlike RDMA or GPUDirect-style bypass, congestion control, retransmission and firewalling stay in-kernel, so any TCP peer works. The cost is that the NIC must do header split, checksumming and steering, and the host CPU still processes every header.
- **Unreadable skbs as a first-class concept.** Letting the stack carry data it cannot read required auditing every path that might touch payload bytes (checksums, copies, loopback, BPF, GRO). Features that need payload access are simply unavailable on those flows.
- **No `struct page` for device memory.** Mainline MM and GPU developers (notably Christoph Hellwig and Jason Gunthorpe in review) resisted fake pages or ZONE_DEVICE shortcuts for networking. That forced the netmem/net_iov abstraction, which took many revisions (v14+ by mid-2024) but gave the kernel a general mechanism that io_uring zcrx then reused.
- **Tokens and explicit release.** Giving userspace references to NIC buffers avoids copies but makes buffer lifetime the application's problem. Slow consumers cause drops rather than backpressure within TCP.
- **dma-buf as the interface.** It reuses the kernel's existing cross-driver sharing object instead of a GPU-specific API, so any exporter (GPU, accelerator, udmabuf) works in principle.

## How It Has Evolved

- **2022–2023** — proposals from Google (LPC 2022; RFC 2023); "Abstract page from net stack" groundwork.
- **6.10–6.11** — `netmem_ref`, memory-provider hooks, queue-management API.
- **6.12 (2024)** — devmem TCP RX merged (gve).
- **6.15** — io_uring zcrx reuses the same provider infrastructure; more drivers (mlx5, bnxt).
- **2025** — devmem TX (`bind-tx`, dma-buf `sendmsg`); `netmem_desc` split from `struct page`.
- **2026** — continued driver enablement, autorelease and token-handling refinements, io_uring device-memory TX prototypes building on the same validation (`validate_xmit_unreadable_skb()`).

## Further Reading

1. [Direct-to-device networking — LWN (2024)](https://lwn.net/Articles/979549/)
2. [Device Memory TCP — LWN patch posting (2023)](https://lwn.net/Articles/937882/)
3. [Abstract page from net stack — LWN](https://lwn.net/Articles/955144/)
4. [Device Memory TCP — kernel.org](https://www.kernel.org/doc/html/latest/networking/devmem.html)
5. [Netmem — kernel.org](https://www.kernel.org/doc/html/latest/networking/netmem.html)
6. [net/mlx5e: devmem and io_uring zero-copy — LWN patch posting](https://lwn.net/Articles/1025247/)

## LKML Highlights

> The LKML search tool was unreachable during this run; highlights are drawn from LWN's coverage of the postings.

- **"Device Memory TCP" (Mina Almasry, v1 2023 → merged 6.12)** — the RX series. Review centred on how to represent device memory without `struct page`, which produced the netmem/net_iov design and the unreadable-skb rules.
- **"Abstract page from net stack" (Mina Almasry, late 2023)** — the preparatory conversion of skb frags and the page pool to `netmem_ref`, the enabling refactor for both devmem and io_uring zcrx.
- **"net/mlx5e: Add support for devmem and io_uring TCP zero-copy" (2025)** — showed one driver implementation serving both providers, validating the shared-abstraction approach.
