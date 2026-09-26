---
title: "Devmem TCP TX — Explained"
category: explained
original: "[[devmem-tcp-tx]]"
subsystem: net
tags: [explained, networking, devmem-tcp, zero-copy, gpu]
converted: 2026-09-26
---

# Devmem TCP transmit, explained

> Plain-language companion to [[devmem-tcp-tx|the technical note]]. Same facts, fewer identifiers.

## The problem

Devmem TCP receive lets a socket's payload land straight in GPU memory. The sending side has the mirror problem: a tensor sitting in GPU memory would normally be copied into host RAM before a TCP socket could send it. **Devmem transmit** lets a TCP socket **send payload straight out of a dma-buf**: the card DMAs the payload from device memory, while the kernel builds headers in host memory and runs full TCP (segmentation, acknowledgements, retransmission, congestion control). GPUDirect RDMA achieves a similar GPU-to-GPU path with a hardware transport; devmem transmit and receive do it with ordinary kernel TCP and any TCP peer.

## The idea in one paragraph

Devmem transmit is **zero-copy send with a map instead of an address**. With ordinary zero-copy send, you give the kernel a *pointer* to your memory; it pins those pages, attaches them to packets, and tells you later (through the socket's error queue) when TCP and the card no longer need them. With devmem transmit, the "pointer" you pass is really an **offset into a pre-registered dma-buf**, named by a control message. The kernel looks up the pre-mapped chunks covering that offset and attaches *them* to packets. Same completion protocol, different memory.

## Step by step

### Step 1: Bind for transmit
The application sends a netdev netlink **bind-tx** request naming the interface and dma-buf. Unlike receive binding, this is **unprivileged**, because it only DMA-maps the caller's own buffer for sending and doesn't reconfigure shared queues. The device must declare support for this kind of transmit: either it DMAs itself, or it's a virtual/passthrough device. For a virtual device such as **netkit** (container networking), the kernel finds the underlying physical card through the queues leased to the virtual device. The kernel maps the dma-buf for transmit, carves it into page-sized chunks, and builds a lookup table from offset to chunk. The binding lasts as long as the netlink socket that created it.

### Step 2: Set up the socket
Zero-copy must be enabled on the socket, because the kernel can't copy device memory. Binding the socket to the same interface is recommended so routing can't pick another one.

### Step 3: Send
The application builds a message whose buffer "addresses" are **byte offsets into the dma-buf**, adds a control message carrying the binding ID, and sends with the zero-copy flag. The kernel sets up completion tracking, finds the binding, and **checks the route**: the socket's egress device must be the bound device (or the virtual device it was bound through), because the mapped DMA addresses are only valid for that device. A send routed elsewhere fails with "no device", an unroutable one with "host unreachable", and a binding ID without zero-copy is invalid.

### Step 4: Build packets from chunks
As TCP fills packets, instead of pinning user pages it looks up the chunk at each offset, takes a reference, and attaches it as a fragment, which makes the packet **unreadable**. Only plain buffer-list iterators are accepted, since the "addresses" are offsets; a packet that already has readable fragments can't take device ones; and it stops at the per-packet fragment limit. Because the kernel can't read the payload, **hardware checksum offload is required**. Segmentation offload still works, since it only splits fragment descriptors and rewrites headers.

### Step 5: Last check before the card
This is the key step for safety. Just before a packet reaches a driver, the kernel checks unreadable packets: devices that don't support device-memory transmit get them **dropped** (they'd try to map or read them), and if the first fragment belongs to a binding for a *different* device, it's dropped too. A packet redirected after sending (by routing changes, traffic control, bonding) to a device the dma-buf isn't mapped for must never reach that device's DMA engine.

### Step 6: The driver
A supporting driver posts fragments using their pre-mapped DMA addresses and, on completion, uses a helper that skips unmapping provider-owned memory.

### Step 7: Completion
As with ordinary zero-copy send, TCP keeps the packets (and their chunk references) until the data is acknowledged, and retransmissions resend from the same device memory. When the last packet is freed, a completion notice (a range of send sequence numbers) arrives on the socket's **error queue**, and only then may the application overwrite those regions. Chunks still in flight keep the binding alive even after the netlink socket closes; the binding is freed (unmapped, detached, released) once every in-flight packet lets go.

## The picture

```text
 bind-tx(eth0, dma-buf fd) ─▶ binding #5: pages of GPU memory mapped for TX, offset→chunk table
 sendmsg(iov = [{offset 0x10000, len 64K}], cmsg binding=5, MSG_ZEROCOPY)
   route check: egress == eth0 ✓
   TCP segments: header (host page) + frags → chunks at 0x10000… (unreadable, HW checksum)
 xmit check: device supports devmem TX & matches binding? else DROP
 NIC DMAs payload from GPU memory …  ACK  … error queue: "sends 12–14 complete" → reuse buffer
```

## Tradeoffs

- **What it gives you:** GPU-to-network sending with no host staging, kernel TCP intact, any TCP peer, and ordinary Ethernet cards that support netmem transmit; unprivileged use, including from containers.
- **What it costs / requires:** reusing zero-copy send kept the series small but inherits its clunky error-queue completions; buffer "pointers" that are really offsets are surprising; hardware checksumming is mandatory.
- **Where it bites:** there's no copy fallback (unlike receive's linear path), so misconfiguration fails loudly with errors or drops. DMA addresses are device-specific, which is why the kernel checks both at send time and again just before transmit.

## How it got here

- **2023:** transmit was in the original devmem proposal, then dropped to land receive first.
- **2025 (14 revisions, Mina Almasry):** rebuilt on netmem/net_iov with bind-tx, the offset table, the binding control message and the transmit-time check; freeing the binding was deferred to a workqueue after finding it could be triggered from atomic context. Merged for **6.16**.
- **2025–26:** transmit modes for virtual devices, netkit support through leased queues, bind-tx explicitly unprivileged, more drivers (gve, mlx5, bnxt, fbnic).

## Related

- Technical version: [[devmem-tcp-tx]]
- [[devmem-tcp-explained|devmem TCP]], [[devmem-tcp-rx-dmabuf-binding-and-token-recycling-explained|devmem RX binding]], [[netmem-and-net-iov-abstraction-explained|netmem and net_iov]], [[netdev-netlink-family|netdev netlink]], [[netdev-queue-management-api-explained|Queue management API]]
- [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]], [[ip-routing-explained|IP routing]], [[dma-buf-sharing|dma-buf sharing]], [[memory-registration-and-ib-umem-explained|RDMA memory registration]]
