---
title: "AF_XDP (XDP Sockets) — Explained"
category: explained
original: "[[af-xdp]]"
subsystem: net
tags: [explained, networking, af-xdp, xdp, zero-copy]
converted: 2026-09-25
---

# AF_XDP, explained

> Plain-language companion to [[af-xdp|the technical note]]. Same facts, fewer identifiers.

## The problem

Some applications (packet capture, load balancers, network functions, DPDK-style packet processors) need millions of raw packets per second. The normal network stack gives every packet a socket buffer, walks it through protocol layers and copies it to user space, which is far too slow for them. The usual escape was full **kernel bypass**: frameworks that take the network card away from the kernel entirely. That's fast, but the kernel loses the device, its driver and its security model, and ordinary traffic like SSH or ARP stops working on that card.

AF_XDP aims for near-bypass speed while the kernel **keeps** the device, sending only *some* traffic straight to user space and letting the rest flow through the normal stack.

## The idea in one paragraph

Picture a **loading dock shared between a warehouse (the application) and a delivery company (the kernel and network card)**. The warehouse owns all the pallets: a chunk of its own memory, the **UMEM**, divided into frames. It leaves empty pallets on a "please fill" conveyor; the delivery company loads packets onto them and sends them back on a "delivered" conveyor. For outgoing goods, the warehouse puts loaded pallets on a "ship this" conveyor and gets the empties back on a "shipped" conveyor. Only **pallet numbers** travel on the conveyors, never the goods themselves, and in zero-copy mode the card's DMA engine loads the pallets directly. The kernel's only job is checking that every pallet number really belongs to this warehouse.

## Step by step

### Step 1: Register the memory
The application allocates a region of its own memory (ideally huge pages, to ease TLB and IOMMU pressure) and registers it as the UMEM. The kernel checks the layout and **pins** the pages, counting them against the locked-memory limit, because the network card will write into them directly and they must never be moved or reclaimed. The UMEM is divided into equal chunks. By default an address is rounded down to its chunk; **unaligned mode** (5.4) lets addresses point anywhere, which DPDK needed to map its own buffer layout onto the UMEM. Several sockets can share one UMEM.

### Step 2: Create the four rings
The application sizes and memory-maps four rings:
- **fill:** empty chunk addresses handed to the kernel for receiving
- **RX:** descriptors of received packets (address and length)
- **TX:** descriptors of packets to send
- **completion:** addresses of chunks whose transmission has finished

Each ring has exactly **one producer and one consumer**, and producer and consumer positions sit on separate cache lines. The kernel keeps private cached copies of those positions and touches the shared ones only when its cache runs dry, as io_uring does. No locks are needed, only memory-ordering barriers.

### Step 3: Bind to one queue, and steer traffic
The socket binds to a device **and a single hardware queue**. The kernel sets up a buffer pool for that queue and asks the driver to switch it to **zero-copy** mode; if the driver can't, it falls back to copy mode (or fails, if zero-copy was required). An **XDP program** on the device must then redirect packets into a special BPF map of AF_XDP sockets, usually indexed by queue number. Packets it doesn't redirect continue into the normal stack, which is what makes AF_XDP a *partial* bypass. Only traffic the card steers to that queue can reach the socket, so card flow rules and queue settings matter.

### Step 4: Receive, zero-copy
This is the key step. The application pre-loads the fill ring with free chunk addresses. When the driver refills its receive ring, it takes addresses from the fill ring; their DMA addresses were all calculated **once at bind time**, so this is only a table lookup. The card writes the packet straight into the chunk. The XDP program redirects it, and the kernel checks the socket is bound to *this* device and queue (otherwise the packet sits in the wrong UMEM and is dropped). The kernel then writes an 8-byte address plus a length into the RX ring, and publishes the whole batch at the end of the poll with one store, waking the application. **The packet bytes never moved.** The application processes the packet where it lies and returns the chunk to the fill ring; in steady state no system calls happen at all.

One catch: on a zero-copy queue, packets the XDP program passes to the normal stack must be **copied** into a regular socket buffer, because the chunks belong to user space. So zero-copy speeds up AF_XDP traffic but slows down everything else on that queue.

### Step 5: Receive, copy mode
Any driver with XDP support, even the slower generic XDP on any device, can do **copy mode**. The packet lands in the driver's own buffers; the kernel takes a chunk from the fill ring, copies the packet in, posts a descriptor and lets the driver recycle its buffer. That's one copy per packet, but it works everywhere and is still much cheaper than the normal stack. If the fill ring is empty or the RX ring is full, the packet is dropped and counted in statistics the application can read.

### Step 6: Transmit
The application fills chunks, writes descriptors to the TX ring, and kicks the kernel with a system call.
- **Copy mode:** the kernel walks the TX ring, **validating every address and length** (it never trusts user input; bad descriptors are counted and skipped), builds a socket buffer for each valid packet (attaching UMEM pages where it can) and hands it straight to the driver, skipping the traffic-control queueing layer. When the buffer is freed, the chunk address goes to the completion ring. A budget limits the work per call.
- **Zero-copy mode:** the call only wakes the driver, whose poll loop pulls descriptors itself, turns addresses into pre-computed DMA addresses, sends them from UMEM, and posts completions when the hardware finishes.

### Step 7: Fewer system calls
Originally the application had to make a system call every batch to guarantee progress. With **need-wakeup** (5.3), the driver sets a flag on the fill or TX ring only when it has run out of work and gone idle, and the application calls in only when that flag is set. This matters most when the application and the driver's polling share one core. **Preferred busy polling** (5.11) goes further: the application drives the driver's polling from its own calls, with hardware interrupts deferred, so receive, process and transmit all run on one core with no interrupts or context switches.

### Step 8: Sharing, big packets and offloads
- **Shared UMEM:** a second socket can reuse another's UMEM. Sockets on the same queue share one fill/completion pair; since 5.10, sockets on different queues or devices can share too, each with its own pair. The application must keep one thread per ring, and never post the same chunk to two rings, a documented source of "mysterious" corruption.
- **Multi-buffer** (6.6): a packet can span several chunks, with every descriptor but the last marked "continues". Receiving is all-or-nothing per packet, and on send an invalid fragment invalidates the whole packet.
- **TX metadata** (6.8): the application can reserve space before each packet for requests to the card, such as a checksum offload or a hardware transmit timestamp returned at completion, plus scheduled launch time on some cards (6.15).

### Step 9: Teardown
Closing the socket removes it from the BPF map, tells the driver to release the queue from zero-copy mode (usually a brief disruption on that queue), drops the pool and UMEM references, and unpins the pages when the last user leaves. If the device disappears, every socket is forcibly unbound.

## The picture

```text
 application (owns UMEM chunks 0..N)
   fill ring ──addrs──▶ driver takes chunk ─▶ NIC DMAs packet into it
                                              │ XDP program: redirect to socket map
   RX ring  ◀──{addr,len}── kernel (checks queue/UMEM, publishes batch)
   process in place ─▶ back to fill ring

   TX ring ──{addr,len}──▶ (copy) validate → build buffer → driver
                           (zero-copy) wake driver → NIC DMAs from UMEM
   completion ring ◀──addr── transmit finished
 unredirected traffic ─▶ normal network stack (copied out of UMEM on zero-copy queues)
```

## Tradeoffs

- **What it gives you:** near kernel-bypass throughput while the kernel keeps the device and its security model; ordinary traffic keeps working; several applications can share a card; packet buffers are plain process memory.
- **What it costs / requires:** creating the socket needs raw-network privilege; pinned memory counts against the lock limit. Single-producer rings push all concurrency to the application. Copy mode works everywhere, but the "same API" can hide a 2–3× performance gap between cards with and without zero-copy.
- **Where it bites:** binding to the wrong queue is the classic mistake: users bind to queue 0 and see nothing because the card's hashing sent their flow to queue 3. On zero-copy queues, normal-stack traffic gets slower because it must be copied out, so mixed workloads often dedicate queues to AF_XDP with flow rules.

## How it got here

- **2017:** proposed by Björn Töpel and Magnus Karlsson as "AF_PACKET V4", a new zero-copy ring version for the existing packet socket. Reviewers objected that AF_PACKET already carried three ring versions of compatibility baggage and taps packets *after* socket buffers are allocated. A new address family hooked to XDP was chosen instead; Jesper Dangaard Brouer's preferred name, AF_XDP, won over AF_CAPTURE, AF_CHANNEL and AF_ZEROCOPY.
- **4.18 (2018):** merged with UMEM, the four rings, the socket map and copy mode. **4.19–4.20:** the zero-copy framework and the first driver (i40e).
- **5.3:** need-wakeup. **5.4:** unaligned chunks. **5.8:** a common buffer-allocation interface that deleted about 1,265 lines of per-driver code and gained 5–10% performance. **5.10:** shared UMEM across queues and devices. **5.11:** preferred busy polling.
- **libbpf 1.0 (2022):** user-space helpers moved to libxdp.
- **6.6:** multi-buffer packets and chunks larger than a page. **6.8:** TX metadata offloads (Stanislav Fomichev). **6.15:** launch-time offload.
- **2025–2026:** TX budget tuning, copy-mode TX performance and more drivers.

## Related

- Technical version: [[af-xdp]]
- [[xdp-explained|XDP]], [[bpf-maps-explained|BPF maps]], [[network-device-and-napi-explained|NAPI]], [[page-pool-explained|Page pool]], [[sk-buff-explained|sk_buff]], [[traffic-control-qdisc-explained|Traffic control]]
- [[get-user-pages-and-pinning-explained|Page pinning]], [[huge-pages-hugetlbfs-explained|Huge pages]], [[dma-mapping-api-explained|DMA mapping]], [[io_uring-explained|io_uring]], [[libbpf-and-toolchain-explained|libbpf]]
