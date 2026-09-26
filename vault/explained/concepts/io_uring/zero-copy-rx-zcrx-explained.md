---
title: "io_uring Zero-Copy Receive (zcrx) Internals — Explained"
category: explained
original: "[[zero-copy-rx-zcrx]]"
subsystem: io_uring
tags: [explained, io_uring, zero-copy, networking, page-pool]
converted: 2026-09-26
---

# io_uring zero-copy receive internals, explained

> Plain-language companion to [[zero-copy-rx-zcrx|the technical note]]. Same facts, fewer identifiers.

## The problem

zcrx lets a TCP application receive payload bytes **without any copy**: the card DMAs payloads straight into memory the application registered (host memory, or a dma-buf such as GPU memory), the kernel still runs full TCP/IP on the headers, and completions point at the bytes where they landed. The fast path isn't the hard part; **ownership** is. A receive buffer passes between four parties (the card's receive ring, the page pool, TCP's packet fragments, and the application), sometimes held by several at once. It must never go back to the card while the application is still reading it, and must never leak when any party disappears (process exit, queue reset, device unplug).

## The idea in one paragraph

Picture a **library with reading rooms**. The *area* is the shelf space, cut into equal **slots**. The card is the delivery service that fills empty slots; the page pool is the librarian who hands empty slots to delivery; TCP is the catalogue tracking which slot holds which part of which stream. When the application is told "your data is in slot 17, offset 300", it has **checked out** slot 17. Returning it means writing "17" on a slip in the **return box** (the refill ring). The librarian empties the box whenever delivery wants more slots, and only re-shelves a slot when *every* checkout has been returned and the catalogue has let go too. If a reader leaves town, the librarian **scrubs**: forcibly takes back every slot that reader still held.

## Step by step

### Step 1: Register
The ring must run completion work only in the submitting task (so refills and completions need no cross-task locking) and use 32-byte completion entries to fit zcrx's extra fields. The application names a card and receive queue, the memory for the refill ring, and an area (plus optional buffer size and event settings). The kernel creates a reference-counted zcrx object (separate counts for kernel users like page pools and for user-side holders like rings and exported files), maps the refill ring, and binds to the card: it finds the queue's DMA device (which can differ per queue) and installs io_uring as that queue's **memory provider**, restarting just that queue so its page pool now asks io_uring for buffers.

### Step 2: The area
An area is either **user memory**, pinned, charged to locked memory (huge pages counted once) and DMA-mapped (the kernel can read it, which the copy fallback needs), or a **dma-buf**, attached and mapped for receiving so payloads land in GPU memory (the kernel can't read it, so no copy fallback). It's cut into equal buffers, page-sized by default, or larger if requested and the memory is contiguous enough, in which case the card is told to post larger receive buffers. Each buffer gets its DMA address and a **user checkout counter**, and all start on a free list. Since 2026 there can be several areas, identified by the top bits of each offset.

### Step 3: Supplying the card
This is the key step. When the driver's page pool runs out, it asks io_uring:
1. **fast path, drain the return box:** for each slip, check the area and offset, drop that many **user checkouts** (a loop that refuses to go below zero, so returning a buffer twice can't do damage), then drop the matching **page-pool** references. A buffer becomes available again only when its pool count reaches zero. Repeated slips for one buffer are batched, and the new read position is published.
2. **slow path, the free list:** hand out never-used or scrubbed buffers.
3. **out of buffers:** fire an allocation-failure event and hand out nothing. The card drops packets for that queue until the application returns buffers, which TCP sees as loss.

Returned buffers are synced for the device before reuse; buffers the pool gives up (queue teardown) go back on the free list; and the provider refuses pools with the wrong DMA device, direction or buffer size.

### Step 4: Receiving
A multishot zero-copy receive on a socket whose flow is steered to the queue walks the socket's incoming data. For each fragment:
- if it's a buffer from **this** zcrx instance, take a user checkout and a pool reference and post a completion with the length and an **offset** (area plus buffer index plus position); the application reads at area base plus offset
- if it's an ordinary page (the packet arrived on another queue, or it's the packet's head), **copy** it into a spare buffer from the free list and post the same kind of completion, firing a copy event and bumping copy statistics

So correctness never depends on steering, and silent slowdowns are visible.

### Step 5: Events (2026)
Registration can name events to watch (allocation failure, copy fallback) and a statistics area. An event posts one extra completion and then stays quiet until the application **re-arms** it, so a buffer drought doesn't flood the completion queue.

### Step 6: Sharing and control (2025–26)
A control interface can **export** a zcrx instance as a file; another ring, even in another process, can **import** it, so several event-loop threads share one hardware queue and area (coordinating the refill ring among themselves). An instance can also have **no device**: all data is copied into the area, giving the same API and buffer-return model on any socket. Other controls flush pending returns outside the allocation path and add areas.

### Step 7: Teardown
When the last user goes away: under the device lock, the provider is removed and the queue restarted on ordinary pages, and areas are DMA-unmapped while the device is still certainly present. Then **scrub**: every buffer with outstanding user checkouts has them all taken back at once, with matching pool references dropped, revoking whatever the application still held. Reference counts keep the zcrx object alive until the last in-flight packet using one of its buffers is freed; only then is memory unpinned or the dma-buf detached. If the device disappears first, the core tells the provider to drop its binding. Netlink queue listings show io_uring as the provider.

## The picture

```text
 area: [buf0][buf1]…[buf17]…  (user memory or GPU dma-buf)
 NIC ─payload─▶ buf17   headers ─▶ kernel pages → TCP
 recv_zc completion: {len 1448, offset area|17<<12|300}  (user checkout 17 += 1)
 app reads in place → writes {17} into refill ring
 page pool needs buffers → drain refill ring: checkout 17 -1, pool ref -1 → 0? back to NIC
 wrong queue / packet head → copy into spare buffer + COPY event
 teardown: queue restart → unmap → scrub all outstanding checkouts
```

## Tradeoffs

- **What it gives you:** copy-free TCP receive into host or GPU memory, with the kernel's TCP, firewalling and congestion control intact (about 41% more throughput than epoll at 200 Gbit/s in the original results); cheap buffer returns by shared-memory write; safe revocation at teardown.
- **What it costs / requires:** card features (header split, flow steering) and per-flow queue setup; event-loop-style rings; buffer availability depends on the application returning buffers promptly, hence the allocation-failure event.
- **Where it bites:** two separate reference counts per buffer mean the application can only return what it was given and can't drop kernel references, but the design is intricate. The copy fallback preserves correctness but used to degrade silently, which the 2026 copy event and statistics address. One hardware queue per instance keeps ownership simple; sharing came later through explicit file export rather than hidden global state.

## How it got here

- **2022–2024:** proposals by David Wei and Pavel Begunkov, converging with devmem TCP on page-pool memory providers and net_iov buffers.
- **6.15:** merged with one user-memory area, zero-copy receive, the refill ring and copy fallback (bnxt first).
- **6.16–6.18:** dma-buf areas, large buffers, mixed-size completions, mlx5 and gve support.
- **2025:** sharing through export/import; per-queue DMA device lookup.
- **2026:** the control interface, events with statistics, device-less instances, multiple areas.

## Related

- Technical version: [[zero-copy-rx-zcrx]]
- [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]], [[devmem-tcp-explained|devmem TCP]], [[netmem-and-net-iov-abstraction-explained|netmem and net_iov]], [[netdev-queue-management-api-explained|Queue management API]], [[header-split-and-flow-steering-for-zero-copy-rx-explained|Header split and steering]]
- [[page-pool-explained|Page pool]], [[dma-buf-sharing-explained|dma-buf sharing]], [[tcp-ip-stack-explained|TCP/IP stack]], [[rdma-explained|RDMA]]
