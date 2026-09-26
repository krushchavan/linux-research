---
title: "Zero-Copy Buffer Ownership and Return Protocols — Explained"
category: explained
original: "[[zero-copy-buffer-ownership-and-return-protocols]]"
subsystem: comparisons
tags: [explained, comparison, zero-copy, af_xdp, io_uring]
converted: 2026-09-26
---

# Zero-copy buffer ownership and return protocols, explained

> Plain-language companion to [[zero-copy-buffer-ownership-and-return-protocols|the technical note]]. Same facts, fewer identifiers.

## The problem

Copying data is simple because **ownership is simple**. When an ordinary receive returns, the kernel's buffer and yours are separate, and each side frees its own.

Zero-copy makes ownership **shared**. On receive, the network card writes straight into memory the application will read in place. So *someone* must hand the card empty buffers before data arrives, and the application must hand used buffers back when it's finished. On send, the application lends its pages to the network stack, which may keep them until the data is acknowledged or even resent. So the application needs a *second* signal telling it when the buffer is its own again.

Underneath, every zero-copy interface in Linux is a **buffer ownership protocol**. It has to answer five questions:
- Who supplies empty buffers?
- How is the application told that data has arrived?
- How are buffers returned?
- How does the kernel stop a buggy or hostile application from returning buffers it doesn't own?
- What happens when buffers run out, or when the application goes away?

## The idea in one paragraph

Think of a **pool of pallets** shared between a warehouse (the application) and a trucking company (the kernel and the network card). The warehouse must leave *empty* pallets at the dock before trucks arrive, and if there are too few, trucks turn away. When goods arrive, the trucker says "your goods are on pallet 17", and pallet 17 is now checked out to the warehouse. When the warehouse has unloaded it, pallet 17 goes back. That can happen by a slip in a return box (a shared-memory ring), by handing in a claim ticket at a counter (a system call with a token), or by putting it back on the empty stack. The trucker must never accept a pallet number it didn't hand out, or the same pallet twice, and if the warehouse goes bankrupt, someone has to reclaim every pallet it still held. Outbound, the warehouse *lends* a loaded pallet: it gets a receipt at pickup and a separate note when the pallet is back.

## Step by step

### Step 1: AF_XDP, pure address passing
AF_XDP is the most literal version ([[af-xdp-explained|AF_XDP]]). The application registers one memory area cut into equal chunks, and gets four shared rings. **Only chunk addresses move, and every chunk belongs to exactly one side at a time.**
- **Supply:** the application puts free chunk addresses on the **fill ring**. The driver takes them when refilling the card, and the card writes packets straight into them.
- **Delivery:** the kernel posts a descriptor (address and length) on the receive ring, and the chunk belongs to the application again.
- **Return:** there is no separate step. A used chunk goes back onto the fill ring, so supply and return are the same action.
- **Checking:** the kernel only checks that an address lies inside the application's own area. It does **not** track which chunks the application currently holds, so posting the same chunk twice silently corrupts data. The protection is "you can only damage your own memory".
- **Running out:** an empty fill ring means packets are dropped and counted. An optional flag asks the application to wake the kernel when it has refilled.

This works because, in AF_XDP, the kernel's networking stack never touches the buffer after handing it over, so trusting the application costs nothing.

### Step 2: io_uring provided buffer rings, supply only
Provided buffer rings ([[provided-buffer-rings-explained|provided buffer rings]]) aren't zero-copy in the device sense, because data is still copied in. But they solve the same *supply* problem: with thousands of idle connections, you don't want to commit a buffer to every socket in advance.
- The application puts buffer descriptions on a shared ring, and the kernel picks one **only when data actually arrives** (late binding). The completion says which buffer was used.
- Returning a buffer means putting it back on the ring. Because the kernel *copies* into the buffer, a bad address only hurts the application.
- If the ring is empty the receive fails, and a repeating receive stops until the application refills it. That is deliberate backpressure.
- Newer options let one completion cover several small buffers, or let one large buffer be used in pieces across several completions. A 2025 proposal for FUSE flips the direction: the kernel owns and recycles the buffers itself.

### Step 3: io_uring zero-copy receive, a ledger of user holdings
This is the key step. **zcrx** ([[zero-copy-rx-zcrx-explained|zcrx]]) keeps the kernel's TCP stack in charge while landing payload in memory the application registered. Unlike AF_XDP, **the kernel must defend itself here**, because the same buffers are also referenced by kernel network buffers and TCP's retransmit and reordering queues.
- **Supply:** the application donates an area up front. io_uring plugs into the card's buffer allocator (the *page pool*), and the driver *pulls* buffers from that area when it needs them.
- **Delivery:** for each chunk of received data in a donated buffer, the kernel records one **user hold** and posts a completion giving the location. Data that arrived somewhere else (another queue, or packet headers) is **copied** into a spare buffer with the same kind of completion, so the application's code doesn't change, and a counter shows it happened.
- **Return:** the application writes the location into a **refill ring** in shared memory, with no system call. The kernel reads the ring lazily, the next time the card needs buffers.
- **Checking:** each buffer's user holds are counted in a table only the kernel can write, and a return can **never push the count below zero**. A double return or a made-up location does nothing. A buffer is reused only when both the user holds *and* the kernel's own references reach zero.
- **Running out:** the card drops packets, and a **one-shot** event tells the application, re-armed on request, so a drought doesn't flood it with events.
- **Teardown:** the kernel takes back every user hold at once, and waits for in-flight network buffers before releasing the memory.

### Step 4: Devmem TCP, tokens and a return system call
**Devmem TCP** ([[devmem-tcp-rx-dmabuf-binding-and-token-recycling-explained|devmem TCP RX]]) uses the same page-pool plug-in as zcrx, but the memory is usually GPU memory that the CPU can't read, and the interface is ordinary sockets.
- **Delivery:** receiving returns small control messages, each with an offset into the GPU buffer and a **token**, a number that only means something within this socket.
- **Return:** the application hands tokens back in batches with a socket option call (up to 128 ranges and 1024 buffers per call).
- **Checking:** tokens can't be forged. The application can only return entries the kernel created for *its* socket, and returning one twice is ignored. This is stronger than naming memory locations, at the cost of a system call per batch.
- **Teardown:** closing the socket releases every outstanding token, and the GPU memory stays mapped until the last buffer is free.

### Step 5: RDMA receive queues and shared receive queues
RDMA's send/receive model predates all of these and is the hardware-native version ([[queue-pairs-and-completion-queues-explained|queue pairs and CQs]]).
- **Supply:** the application posts receive requests pointing into registered memory. Each incoming message consumes **exactly one**, in order, so each must be big enough for the largest message.
- **Delivery and return:** a completion carries the application's own tag for the buffer, and returning it means posting it again. As with AF_XDP, the kernel doesn't track holdings: the card checks memory keys and bounds, and re-posting a buffer still in use is the application's bug.
- **Running out:** on reliable connections the receiver answers **"receiver not ready"**, and the sender backs off and retries, up to a limit or forever. This is the only scheme here where running out causes a pause rather than a drop.
- **Shared receive queues:** with thousands of connections, per-connection receive queues waste memory. A **shared receive queue** lets many connections draw from one pool. It is refilled when a **one-shot low-watermark event** fires, which must be re-armed each time (the same pattern zcrx adopted).
- **Striding receive queues** (on Mellanox cards) split one large buffer into slots, one packet each, so one post supplies many messages.
- One-sided RDMA reads and writes need no receive protocol at all. The applications agree on ownership themselves, which is why storage protocols pair a small message channel with one-sided bulk transfers.

### Step 6: The send side, lending a buffer and learning when it's back
On send the application **lends** a buffer. Because TCP may resend, "sent" isn't "done": the buffer is free only when the last network buffer referencing it is released, usually after acknowledgement.
- **`MSG_ZEROCOPY`** (4.14): the kernel pins the pages and later puts a notification on the socket's **error queue**, covering a *range* of sends at once. A flag says if the kernel fell back to copying, which it always does for local traffic.
- **io_uring zero-copy send** (6.0): the same machinery, but with **two completions**, "queued" and later "buffer free", on the normal completion ring. A flag reports copy fallback, and registered buffers avoid pinning per send. An early design with shared notification slots was simplified before merging.
- **Devmem send:** zero-copy send where the "address" is an offset into a GPU buffer. It uses the same error-queue notifications.
- **AF_XDP send:** the kernel returns the chunk on a **completion ring** when the card is done. There's no acknowledgement or resend, so "complete" means "the card has finished", not "the peer received it".
- **RDMA send:** a completion arrives after the peer's acknowledgement on reliable connections. Applications can ask for a completion only every N sends, which implicitly completes the earlier ones. Small sends can be copied into the request itself, so the buffer is free at once, the same "copying is cheaper for small data" rule as io_uring's roughly 10 KB threshold.

## The picture

```text
 RECEIVE                supply              return                 kernel tracks what app holds?
 AF_XDP                 app → fill ring     same ring              no  (bad return = own damage)
 provided buffer ring   app → buffer ring   same ring              no  (data is copied anyway)
 io_uring zcrx          kernel pulls from   refill ring (shared    yes: per-buffer count,
                        donated area        memory, no syscall)    can't go below zero
 devmem TCP             kernel pulls from   socket option call     yes: per-socket tokens
                        GPU buffer          with tokens
 RDMA RQ / shared RQ    app posts requests  post again             no  (card checks keys)

 SEND: lend buffer ──► "queued" ──► ... ACK / card done ... ──► "buffer free"
        error queue (MSG_ZEROCOPY, devmem) | 2nd completion (io_uring) | completion ring (AF_XDP) | CQ (RDMA)
```

## Tradeoffs

- **What it gives you:** zero-copy data paths with a range of trust models, from "trust the application completely" (AF_XDP, RDMA) to "audit every return" (zcrx, devmem), and several ways to return buffers without a system call.
- **What it costs / requires:** the application must return buffers promptly, because slow returns starve the card and cause drops, or on RDMA, retries. Send-side zero-copy adds a second notification to track, which only pays off for larger messages.
- **Where it bites:** the choice to keep a ledger follows one rule. If the kernel's own stack keeps using the buffer (TCP in zcrx and devmem), a forged return could hand the card memory the kernel is still reading, so the kernel must keep a separate record of user holdings. If the kernel never touches the buffer again (AF_XDP, RDMA), no ledger is needed. Only RDMA reliable connections turn buffer starvation into a pause. Everything on Ethernet drops, and provided buffer rings fail the request.

## How it got here

- **2000s:** RDMA receive queues, shared receive queues and low-watermark events; striding receive queues around 2017.
- **2017–2018:** `MSG_ZEROCOPY` (4.14) and AF_XDP (4.18).
- **2022:** io_uring provided buffer rings (5.19) and zero-copy send (6.0), after the notification design was simplified.
- **2024:** devmem TCP receive with tokens (6.12), then devmem send.
- **2025:** io_uring zero-copy receive (6.15) with the refill ring and user-hold counts; later sharing between rings, events and multiple areas; kernel-managed buffer rings proposed for FUSE.

## Related

- Technical version: [[zero-copy-buffer-ownership-and-return-protocols]]
- [[memory-pinning-and-registration-strategies-explained|Memory pinning and registration]] (how memory becomes usable by a device)
- [[af-xdp-explained|AF_XDP]], [[provided-buffer-rings-explained|Provided buffer rings]], [[zero-copy-rx-zcrx-explained|io_uring zcrx]], [[devmem-tcp-rx-dmabuf-binding-and-token-recycling-explained|Devmem TCP RX]], [[devmem-tcp-tx-explained|Devmem TCP TX]], [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]]
- [[queue-pairs-and-completion-queues-explained|RDMA queue pairs]], [[page-pool-explained|Page pool]], [[netmem-and-net-iov-abstraction-explained|netmem]]
- [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk-explained|Kernel bypass comparison]], [[devmem-tcp-vs-rdma-gpudirect-vs-io-uring-zcrx-explained|Devmem vs GPUDirect vs zcrx]]
