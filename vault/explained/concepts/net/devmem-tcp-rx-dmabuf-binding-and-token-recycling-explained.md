---
title: "Devmem TCP RX: dma-buf Binding and Token Recycling — Explained"
category: explained
original: "[[devmem-tcp-rx-dmabuf-binding-and-token-recycling]]"
subsystem: net
tags: [explained, networking, devmem-tcp, dma-buf, zero-copy]
converted: 2026-09-26
---

# Devmem TCP receive: binding and tokens, explained

> Plain-language companion to [[devmem-tcp-rx-dmabuf-binding-and-token-recycling|the technical note]]. Same facts, fewer identifiers.

## The problem

Devmem TCP lets a TCP socket's payload land directly in accelerator (GPU) memory. Mechanically that comes down to two ownership problems:
1. **Binding:** turning a dma-buf (an opaque list of device-memory DMA ranges) into a pool of fixed-size buffers that a card's receive queues can fill, and tearing it all down safely whoever disappears first.
2. **Token recycling:** telling the application which buffers now hold its data, without copying, and getting them back so the card can reuse them, while a buggy or malicious application can't forge, double-free or leak buffers beyond its own socket.

## The idea in one paragraph

The binding is a **warehouse lease**. The dma-buf is floor space in another company's building (GPU memory). Binding leases it, divides it into numbered **bays** (net_iovs) handed out by a bay allocator, and gives the delivery trucks (the card's receive queues) the right to fill bays. When a truck fills a bay for your TCP stream, your socket gets a **claim-ticket number** (a token). You hand tickets back in bulk, up to 128 slips and 1024 bays at a time. The lease isn't cancelled until the last bay is empty, even if you've already said you're leaving, and the landlord (the GPU driver) sees the space in use until then.

## Step by step

### Step 1: Ask to bind
The application sends a netdev netlink **bind-rx** request naming the interface, the dma-buf file, which receive queues to use, and optionally a larger buffer size. It needs network-admin rights. The binding's lifetime is tied to **that netlink socket**: close it (or exit) and everything unbinds automatically. Each queue is checked and refused, with an explanatory message, if header split is off, the header-split threshold isn't 0, XDP is attached, the queue already has a memory provider or AF_XDP socket, the index is invalid, or the queue is leased to a virtual device. All queues must share one DMA device. The reply carries a **binding ID**, which reappears in every delivery message.

### Step 2: Build the binding
The kernel takes a reference to the dma-buf, attaches it **statically** (the GPU driver keeps it pinned for the binding's whole life) and maps it for receiving. It then carves each DMA segment into equal buffers, rejecting segments that aren't aligned to the buffer size, and records each segment's offset within the dma-buf. Each buffer gets its DMA address filled in, so the page pool and driver can program the card without knowing it isn't a page. The binding goes into a global table and onto the netlink socket's list.

### Step 3: Attach to queues
For each queue, the kernel records the binding as that queue's **memory provider** and **restarts just that queue**. The driver builds a new page pool for it; the pool sees the provider, which takes a reference on the binding and checks the pool maps for receiving at the right buffer size and allows unreadable memory. The card starts receiving into GPU memory.

### Step 4: Supply buffers
When the driver refills its receive descriptors, the pool asks the provider, which hands out one buffer from the allocator. The card writes payload into GPU memory and headers into ordinary pages (header split), and the packet is marked unreadable.

### Step 5: Deliver tokens
This is the key step. The application receives with a devmem flag. For each packet:
- any **linear** bytes that landed in host memory (headers the card didn't split, or small packets) are *copied* to the application and reported with a "linear" message giving just the size
- for each **fragment**, the kernel checks it really is a devmem buffer (anything else fails, rather than leaking another provider's memory), works out its **offset within the dma-buf** (which the application can use directly in GPU code), creates a **token**, and sends a message with offset, size, token and binding ID. It takes a pool reference on the buffer so the packet can be freed while the buffer stays alive for the application.

Tokens are entries in a per-socket table, so the application can only name buffers the kernel put in *its own* socket's table. To avoid taking the table's lock per fragment, the kernel reserves a batch of IDs up front, fills in the used ones, and releases the rest.

### Step 6: Return tokens
The application returns tokens with a socket option taking ranges: at most 128 ranges and 1024 buffers per call. Each token is erased from the socket's table under its lock; a token that's missing (already returned, or never issued) is silently skipped, so **double-frees are impossible**. The buffers' pool references are dropped in batches of 16 outside the lock. The call returns how many were freed, and the application loops if it had more.

### Step 7: Recycle
When a buffer's pool count falls back to baseline, the pool either reuses it for the next receive descriptor (fast path) or, if the pool is being destroyed, returns it to the binding's allocator; the pool never tries to free it as a page. When a socket closes, every outstanding token's buffer is released, so a crashed application can't leak GPU memory beyond its socket's life.

### Step 8: Teardown
Unbinding removes the binding from the global table and restarts each queue with ordinary pages. But the old page pools keep their references to the binding until every buffer they handed out has come back, and buffers still held by sockets or packets also pin it. Only when the last reference drops does the kernel unmap and detach the dma-buf, release it and destroy the allocator, so the GPU memory is guaranteed idle from the card's side before its owner can reuse it. Netlink queries report which binding is attached to which queue or pool, and a selftest (`ncdevmem`) exercises the whole flow.

## The picture

```text
 bind-rx(eth0, dma-buf fd, queues 8-15) ─▶ binding #3 (lives as long as the netlink socket)
   static attach + map → carve into buffers (bays) → restart queues 8-15 with provider
 NIC: headers → host pages;  payload → bay 42 in GPU memory  (packet unreadable)
 recvmsg(DEVMEM) ─▶ copies linear bytes;  msg {offset 0x2A000, size 4096, token 17, binding 3}
 GPU kernel reads offset 0x2A000 …
 setsockopt(DONTNEED, [17..40]) ─▶ erase tokens → bays back to pool → reused by NIC
 unbind: queues restart on pages; binding freed only after last bay returns
```

## Tradeoffs

- **What it gives you:** TCP payload straight into GPU memory with the kernel's TCP stack intact; tokens that can't be forged or double-freed; automatic cleanup on process death.
- **What it costs / requires:** orchestrators must keep the netlink socket open as long as the binding is needed. The static attach means GPU memory can't be evicted while bound; revocable dynamic attach is future work. Exporters must supply aligned segments. Returns cost a system call per batch, within the 128/1024 limits.
- **Where it bites:** returning tokens slowly starves the queue of buffers and causes drops. Applications must handle two kinds of delivery message (linear copies and device fragments). Setup needs header split, flow steering onto the bound queues, RSS excluding them, and no XDP.

## How it got here

- **2023:** proposals by Mina Almasry and debate over page structures versus a new memory type. Reviewers pushed for socket-scoped binding lifetime, socket-local tokens instead of user-named offsets, and the return limits.
- **6.12 (2024):** devmem receive merged, with gve support.
- **6.13–6.15:** providers generalised alongside io_uring zero-copy receive; mlx5, bnxt and fbnic support; batched token allocation (a measurable win above 100G).
- **6.16:** devmem transmit.
- **2025–26:** larger device buffer sizes; binding through virtual devices such as netkit for containers; per-queue DMA device lookup.

## Related

- Technical version: [[devmem-tcp-rx-dmabuf-binding-and-token-recycling]]
- [[devmem-tcp-explained|devmem TCP]], [[devmem-tcp-tx-explained|devmem TX]], [[netmem-and-net-iov-abstraction-explained|netmem and net_iov]], [[netdev-queue-management-api|Queue management API]], [[header-split-and-flow-steering-for-zero-copy-rx|Header split and steering]], [[netdev-netlink-family|netdev netlink]], [[zero-copy-rx-zcrx|io_uring zcrx]]
- [[dma-buf-sharing|dma-buf sharing]], [[page-pool-explained|Page pool]], [[tcp-ip-stack-explained|TCP/IP stack]], [[sk-buff-explained|sk_buff]], [[memory-registration-and-ib-umem-explained|RDMA memory registration]]
