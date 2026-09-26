---
title: "netmem and net_iov — Explained"
category: explained
original: "[[netmem-and-net-iov-abstraction]]"
subsystem: net
tags: [explained, networking, netmem, page-pool, zero-copy]
converted: 2026-09-26
---

# netmem and net_iov, explained

> Plain-language companion to [[netmem-and-net-iov-abstraction|the technical note]]. Same facts, fewer identifiers.

## The problem

For decades the network stack assumed every packet buffer was an ordinary memory **page**: drivers got pages from the page pool, packet fragments pointed at pages, TCP copied from pages, and freeing meant dropping a page reference. Two new ideas broke that assumption: receiving directly into **GPU memory** (a dma-buf, which has no page structures) and into a **user-registered io_uring area** (where a buffer's lifetime depends on user space handing it back, not page reference counts). The stack needed a way to carry "a network buffer" without knowing whether it's a real page.

## The idea in one paragraph

A **netmem** handle is a **tagged claim ticket**. Most tickets are for ordinary luggage (pages): the stack can open them, look inside and discard them by the usual rules. Some tickets, marked by a tag in the lowest bit, are for **sealed crates stored off-site** (**net_iov**): the stack can track, count and pass them along, and hand them back to their owner (a **memory provider**), but it **can't open them**, because the bytes may live in GPU memory. Code that must look inside (checksums, copying to users, BPF reading packets) asks "is this readable?" first; everything else, like TCP reassembly, reference counting and recycling, works the same for both. One driver implementation then serves normal traffic, devmem TCP and io_uring zero-copy receive.

## Step by step

### Step 1: The handle
A netmem is a pointer-sized value. If the lowest bit is clear, it's a page; if set, clearing it gives a net_iov. Pages are always aligned, so that bit is free. Helper functions convert between them, and the value is marked so static checking catches accidental use as a plain pointer. Most code never converts at all: the page pool and packet-fragment interfaces take netmem directly.

### Step 2: Shared metadata that looks the same for both
This is the key step. The page pool keeps per-buffer bookkeeping: which pool owns it, a signature, its DMA address, and a pool reference count. For pages, that bookkeeping lives *inside* the page structure. Since 6.17 (Byungchul Park) it's formalised as its own descriptor, laid out at exactly the same offsets as in the page structure (checked at compile time). A net_iov **starts** with that same descriptor, so page-pool code reads owner, DMA address and reference count the same way whether it has a page or a net_iov, with no type check on the hot path. It's the page pool's part of memory management's long-term plan to shrink the page structure to a pointer, alongside folios and slabs.

### Step 3: net_iovs and areas
A net_iov is that descriptor plus a type (dma-buf for devmem TCP, or io_uring for zero-copy receive) and a pointer to its owning **area**, an array of net_iovs covering one chunk of memory. A net_iov's position in its area is how a provider maps it back to "offset N in the user's buffer" when reporting to user space. Net_iovs have no normal page reference count; their lifetime follows the pool's count plus provider-specific references, such as io_uring user references or devmem socket tokens.

### Step 4: Memory providers
Normally the page pool allocates from the page allocator. If a **memory provider** is bound to the receive queue, allocation and release go to the provider instead: it hands out buffers, takes them back, sets up and validates the pool (DMA direction, sizes), reports the binding over netdev netlink, and cleans up when the queue or device disappears. Providers stamp buffers with their pool and DMA addresses. Binding a provider restarts the queue so its pool is rebuilt with the provider.

### Step 5: Carrying bytes you can't read
GPU-backed net_iovs can't be read by the CPU, so a packet that has such a fragment is marked **unreadable**, and every path that would touch payload checks: copying and checksum helpers fail or skip, TCP won't merge readable and unreadable packets, normal receive refuses unreadable data unless the socket asked for devmem delivery, and XDP and BPF see only the readable (header) part. Routing, GRO, netfilter and TC work on headers, which live in ordinary pages thanks to **header split**. Asking for a net_iov's address returns nothing, and drivers must handle that.

### Step 6: What drivers must do
To receive: use the page pool; support TCP header/data split so headers land in readable memory; use the netmem interfaces instead of page pointers; let the pool do DMA mapping and syncing (only it knows whether a provider's memory needs it); allow unreadable memory exactly when header split is on; never assume memory is readable; and avoid private recycling schemes built on page structures. To transmit devmem data: don't DMA-unmap provider-owned addresses (use netmem-aware helpers) and declare that the device supports netmem transmit. Drivers supporting this include bnxt, mlx5, gve, fbnic, idpf and ice.

## The picture

```text
 netmem value:  …page address…0  → ordinary page (open, copy, checksum)
                …net_iov addr…1  → provider-owned (GPU dma-buf / io_uring area): sealed
 page:    [ … | pool | signature | DMA addr | pool refcount | … ]
 net_iov: [ pool | signature | DMA addr | pool refcount ] + type + area
            ▲ same offsets → page pool code doesn't care which
 packet: header in page (readable) + payload frags in net_iov (unreadable → skb marked)
```

## Tradeoffs

- **What it gives you:** one driver code path for ordinary, devmem TCP and io_uring zero-copy traffic; GPU memory flowing through the normal stack with no special fast path for plain pages.
- **What it costs / requires:** type safety relies on helpers and static checking rather than the compiler's type system, and every "open the buffer" site had to be audited; drivers must be converted to netmem interfaces and header split.
- **Where it bites:** making "unreadable" a first-class packet property, with headers still readable, is what made devmem TCP acceptable to network maintainers, who reject TCP-offload designs. They also required one mechanism shared by devmem and io_uring rather than two, which delayed both. The early plan to make net_iovs impersonate pages was dropped.

## How it got here

- **Late 2023:** Mina Almasry's "abstract page from net stack" and devmem TCP proposals, starting as a no-op wrapper for gradual conversion.
- **6.10 (2024):** netmem handles merged; page pool and packet fragments converted.
- **6.12:** net_iov, memory providers, unreadable packets and devmem TCP receive.
- **6.14–6.15:** generalised provider operations; io_uring zero-copy receive as a second provider.
- **6.15–6.16:** devmem transmit and netmem transmit helpers.
- **6.17 (2025):** the separate descriptor split from the page structure (Byungchul Park).
- **2025–26:** more drivers and larger receive buffer sizes for providers.

## Related

- Technical version: [[netmem-and-net-iov-abstraction]]
- [[page-pool-explained|Page pool]], [[devmem-tcp-explained|devmem TCP]], [[devmem-tcp-rx-dmabuf-binding-and-token-recycling-explained|devmem RX binding]], [[devmem-tcp-tx-explained|devmem TX]], [[zero-copy-rx-zcrx|io_uring zcrx]], [[netdev-queue-management-api-explained|Queue management API]]
- [[sk-buff-explained|sk_buff]], [[tcp-ip-stack-explained|TCP/IP stack]], [[folio-explained|Folio]]
