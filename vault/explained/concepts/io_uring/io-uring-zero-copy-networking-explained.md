---
title: "io_uring Zero-Copy Networking — Explained"
category: explained
original: "[[io-uring-zero-copy-networking]]"
subsystem: io_uring
tags: [explained, io_uring, zero-copy, networking]
converted: 2026-09-25
---

# io_uring zero-copy networking, explained

> Plain-language companion to [[io-uring-zero-copy-networking|the technical note]]. Same facts, fewer identifiers.

## The problem

In a normal TCP send or receive, every byte is copied between your application's memory and the kernel's socket buffers. At 100–400 Gbit/s per network card that copying is often the single biggest CPU cost in a network server.

Linux had older zero-copy options, but they were awkward. The send side reported "your buffer is free again" through a side channel on the socket. The receive side required remapping pages into your address space, which is expensive and fussy about alignment. io_uring offers zero-copy in both directions while keeping the kernel's normal TCP stack in charge. This is **not** kernel bypass like DPDK: the kernel still runs TCP, firewalling and congestion control, and only the payload bytes skip the copy.

The two directions have very different problems:
- **Sending:** the kernel returns before your data is actually on the wire, so it has to tell you when your buffer is safe to reuse.
- **Receiving:** the network card writes a packet into memory *before anyone knows which application it belongs to*. You can't let it write arbitrary traffic into one program's memory.

## The idea in one paragraph

For sending, you **lend** the kernel your buffer instead of letting it copy the data, and you get two receipts: "queued" and later "done with your pages". For receiving, you **dedicate a network card receive queue to your traffic** and make your own memory that queue's buffer supply. The card then writes payloads straight into your memory, the kernel processes the headers as usual, and you are told *where* the data landed rather than being handed a copy.

## Step by step: sending

### Step 1: Submit a zero-copy send
You queue a zero-copy send request pointing at your buffer. If the buffer was registered with io_uring in advance, its memory is already pinned (locked in place), so nothing has to be pinned per send.

### Step 2: Your pages go straight into packets
Instead of copying your bytes into kernel buffers, the TCP stack attaches your actual memory pages to the outgoing packets. A small tracking object rides along with every packet that references your pages. It counts how many packets still point at them.

### Step 3: First completion: "queued"
As soon as the data is accepted into the socket, you get a completion saying how many bytes were queued, with a flag saying another completion will follow. **Your buffer is still in use at this point.** TCP may need it again to retransmit a lost segment.

### Step 4: Second completion: "your buffer is free"
When the last packet referencing your pages is gone (acknowledged by the peer, or finished by the network card), the tracking object's count drops to zero and io_uring posts a second, *notification* completion. Only now can you safely reuse or free the buffer.

### Step 5: Fallback when zero-copy isn't possible
Some paths can't do zero-copy, for example loopback or a network card that can't gather data from scattered pages. The kernel then quietly copies instead. You can ask for the notification to tell you whether a copy happened.

**When it pays:** pinning and the extra completion have a fixed cost. As a rough guide, plain sends win below ~10 KB, you should benchmark between 10 and 100 KB, and zero-copy consistently wins above ~100 KB.

## Step by step: receiving (zcrx)

### Step 1: Split each packet in two
The network card is configured for **header/data split**. For each packet it writes the headers (Ethernet, IP, TCP) into one buffer and the payload into another. The kernel needs the headers to run TCP. Only you need the payload. So the two can live in different memory.

### Step 2: Dedicate a receive queue to your flows
Network cards have many receive queues. You pick one and configure **flow steering** rules so your connections' packets always land on it, and adjust **RSS** (the card's spreading of traffic across queues) so nothing else does. Everything arriving on that queue is now yours, and that is what makes it safe to aim the card at your memory.

### Step 3: Give the kernel your memory
You allocate a large region, the **area**, where payloads will land, plus a small shared **refill ring** for handing buffers back. You register both with io_uring, naming the network interface and queue. The kernel pins the area, maps it so the card can DMA (directly write) into it, and slices it into page-sized chunks.

### Step 4: Swap the queue's buffer supply
This is the key step. Network drivers don't pick receive buffers themselves. They take them from a per-queue recycling allocator called the **page pool**. The page pool lets a **memory provider** plug in and supply buffers. io_uring registers itself as the provider for your queue, and the queue is restarted. From now on, whenever the driver refills its receive slots, it gets chunks of *your* area and doesn't know the difference. The same mechanism powers device-memory TCP, which receives straight into GPU memory, so drivers support both with one implementation.

### Step 5: Packets arrive
The card writes a payload directly into a chunk of your area and the headers into an ordinary kernel page. The driver builds a normal kernel packet buffer whose header part is in kernel memory and whose data points at your chunks. TCP does everything it always does (sequence numbers, ACKs, reordering, congestion control) using only the headers. It never needs to read the payload.

### Step 6: You're told where the data is, not given a copy
You post one long-lived *multishot* receive request, which keeps producing completions until you cancel it. When data is ready, io_uring walks the socket's queue. For each piece that lives in your area it takes a reference on that chunk and posts a completion containing **an offset into your area and a length**. No bytes are copied. You read the payload in place.

### Step 7: Hand buffers back without a system call
When you're done with some data, you write its offset and length into the refill ring, which is plain shared memory. The next time the driver needs buffers, io_uring's provider drains the ring, drops your references, and gives those chunks back to the card.

### Step 8: Fallback copy keeps it correct
Sometimes data arrives in normal kernel memory instead: a packet from before setup finished, a flow that wasn't steered correctly, or your area running out of free chunks. zcrx then copies that data into a free chunk of your area and reports it with the same kind of completion. Misconfiguration costs speed, never correctness.

### Step 9: Ring restrictions
Receive rings must be single-issuer (one thread submits) and must deliver completions only when that thread asks. That removes locking between the refill ring, the page pool and completion posting. The cost is that it suits event-loop programs with one thread per ring. Later kernels let several rings in one process share a queue binding.

## The picture

```text
SEND
  app buffer ──(pages attached, not copied)──▶ TCP packets ──▶ NIC
     ▲                                             │
     │  completion 1: "N bytes queued" (more coming)│
     └── completion 2: "your buffer is free" ◀──────┘ (last packet freed)

RECEIVE (zcrx)
            ┌──────── NIC: header/data split, dedicated steered queue ────────┐
 packet ──▶ │ headers ─▶ kernel page          payload ─▶ chunk of YOUR area  │
            └──────────────────────────────────────────────────────────────────┘
                   │                                          ▲
            TCP runs normally                                 │ page pool refills from
            on the headers                                    │ io_uring (memory provider)
                   │                                          │
      completion: "len N at offset X"               refill ring: app returns
                   │                                 offset,len when done
            app reads in place ───────────────────────────────┘
```

## Tradeoffs

- **What it gives you:** no payload copies in either direction, fewer system calls, and the kernel's full TCP stack and security model. The upstream receive patches reported about 116 Gbit/s versus 82 Gbit/s for epoll on a 200G card (+41%), and +29% with the app and network processing on the same core.
- **What it costs / requires:** sends need two completions and careful buffer bookkeeping. Receives need a card with header split and flow steering, a driver that supports memory providers (bnxt, mlx5, gve and others), a receive queue dedicated to your flows, and a single-issuer ring.
- **Where it bites:** on the send side, reusing a buffer after the first completion corrupts data that may be retransmitted. On the receive side, holding chunks too long starves the card of buffers, causing drops and TCP retransmits.

## How it got here

- **2021–2022:** zero-copy send designed by Pavel Begunkov, with notification completions instead of the socket side channel; merged in 6.0 (with a message-based variant in 6.1).
- **6.2:** option to report whether a send really went zero-copy.
- **2022–2024:** several zero-copy receive designs converged on the page-pool memory-provider approach shared with device-memory TCP. The networking maintainers insisted on that shared abstraction.
- **6.15:** zero-copy receive (zcrx) merged, by David Wei and Pavel Begunkov.
- **6.16 onward:** receiving into GPU/device memory, larger chunks, more drivers; 2025–2026 queue sharing across rings.

## Related

- Technical version: [[io-uring-zero-copy-networking]]
- [[page-pool|Page pool]]: the buffer recycler zcrx plugs into
- [[devmem-tcp|Device-memory TCP]]: the sibling feature using the same provider mechanism
- [[registered-resources-explained|Registered buffers]]: pre-pinned buffers for zero-copy send
- [[io-uring-task-work-explained|io_uring task work]]: how completions get posted
