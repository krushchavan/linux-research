---
title: "XDP (eXpress Data Path) — Explained"
category: explained
original: "[[xdp]]"
subsystem: net
tags: [explained, networking, xdp, bpf, fast-path]
converted: 2026-09-25
---

# XDP (eXpress Data Path), explained

> Plain-language companion to [[xdp|the technical note]]. Same facts, fewer identifiers.

## The problem

The normal receive path allocates an skb, parses headers, and runs the firewall, routing and socket lookup for every packet. That costs microseconds per packet and caps a core at a few million packets per second. DDoS scrubbers, load balancers and forwarding appliances need 10 to 25 million or more per core, which pushed people towards kernel-bypass stacks like DPDK. Those take the card away from the kernel entirely and burn dedicated CPUs polling it, losing the kernel's TCP stack, security model and tools for everything else.

## The idea in one paragraph

XDP runs a small, verified **BPF program inside the driver's receive loop**, on the raw packet buffer, **before any skb exists**. Think of a **bouncer at the loading dock, before goods reach the warehouse**. The warehouse (the normal stack) has clerks, paperwork and shelving. The bouncer looks at each box straight off the lorry and can throw it away, put it straight back on the lorry, send it to another dock or a specific worker, let it into the warehouse, or throw it away and file an incident report. Anything rejected at the dock costs the warehouse nothing.

## Step by step

### Step 1: Attach a program
User space loads an XDP program and attaches it to an interface. A driver with native support typically reshapes its receive rings: 256 bytes of headroom in front of each buffer, one packet per page or fragment, buffers from a [[page-pool-explained|page pool]] registered as the queue's memory model, and separate transmit queues for XDP so its sends don't fight the normal stack's locks. Three modes:
- **native:** in the driver, the fast path
- **generic:** runs on an already-built skb, works on any device, but only for portability and testing, with no speed gain
- **offload:** compiled for the card itself (in practice, only Netronome cards supported it)

Since 6.3, drivers advertise which XDP features they support.

### Step 2: Run on the raw buffer
During NAPI polling, instead of building an skb, the driver fills a tiny on-stack context: where the buffer starts (with headroom), where the packet starts and ends, an optional metadata area just before the packet, the receive queue's details, and the buffer size. Then it runs the compiled program. The verifier proved at load time that every packet access is checked against the end pointer, so there are **no runtime bounds checks**. The program can grow or shrink the packet at either end (to add or strip encapsulation), reserve metadata, look things up in BPF maps (blocklists, counters, forwarding tables), ask the kernel's routing and neighbour tables, and (since 6.3) read hardware hints such as the flow hash, timestamp or VLAN tag.

### Step 3: Act on the verdict
This is the key step:
- **drop:** the buffer goes straight back to the page pool's lock-free cache, so a dropped packet costs little more than the program itself. That's where the headline numbers come from: about 24 to 26 million drops per second per core in the 2018 CoNEXT paper.
- **pass:** the driver builds an skb around the **same** buffer (using the reserved headroom, so no copy) and continues up the normal stack; metadata can be handed to later traffic-control programs.
- **tx:** the buffer is queued on the same device's XDP transmit ring, batched, and sent back out, handy for load balancers that rewrite headers and bounce packets.
- **redirect:** see next step.
- **aborted:** dropped, with a trace event fired; this signals a program error rather than policy.

### Step 4: Redirect
The program names a target in a map and returns "redirect". Depending on the map type, the frame goes to:
- **another device:** queued per destination and sent in batches through that device's XDP transmit hook
- **another CPU:** placed on a ring for that CPU, whose thread builds the skb and runs the stack there (software RSS for cards that spread flows badly), optionally running a second XDP program first
- **an AF_XDP socket:** delivered to user space; with zero-copy drivers, the packet was already written straight into the socket's memory, so only a descriptor is posted

Before leaving, the buffer is turned into a compact **frame** descriptor stored in the packet's own headroom. It remembers which memory pool it came from, so whoever finally frees it (on another device or CPU) returns the page to the right pool. At the end of each poll, all batches are flushed. Batching is why redirect forwarding gets close to drop-level speeds.

### Step 5: Big packets (multi-buffer)
Originally each packet had to fit in one page, ruling out jumbo frames and large receive buffers. Since 5.18, a large packet is a head buffer plus fragments. Programs must declare they can handle fragments, and use helper functions to read or write data beyond the first part. AF_XDP gained matching support in 6.6.

### Step 6: When things fail
A full redirect queue, or a target without an XDP transmit hook, frees the frame back to its pool and fires an error trace. An exhausted page pool means the driver can't refill receive descriptors, so the hardware drops packets, visible in the card's statistics. Out-of-bounds programs never get this far: the verifier rejects them at load time.

## The picture

```text
 NIC DMA ─▶ buffer (256 B headroom | packet) ─▶ XDP program (no skb yet)
   drop     ─▶ back to page-pool cache                 (~24–26 Mpps/core)
   tx       ─▶ same device's XDP transmit ring
   redirect ─▶ other device │ other CPU │ AF_XDP socket   (batched, flushed per poll)
   pass     ─▶ skb built around same buffer ─▶ normal stack
   aborted  ─▶ drop + trace event
```

## Tradeoffs

- **What it gives you:** near-bypass speeds while keeping the card shared with the kernel, no dedicated polling cores, and unhandled traffic passed to the normal stack with its security model and tools.
- **What it costs / requires:** per-driver implementation (ring layout, headroom, transmit queues, memory model), so feature support varies by driver; roughly 10 to 20% lower peak throughput than a tuned bypass stack, accepted as the price of integration.
- **Where it bites:** programs see raw bytes with minimal metadata (no checksum, hash or timestamp unless asked for through hints). Multi-buffer requires explicit opt-in, and generic mode gives no speed benefit.

## How it got here

- **4.8 (2016):** XDP with drop, pass and tx (mlx4 first). **4.12:** generic XDP.
- **4.14–4.15:** redirect through device maps (John Fastabend), then CPU maps (Jesper Dangaard Brouer).
- **4.16–4.18:** frame descriptors and the memory-return API (which led to the page pool), and AF_XDP sockets (Björn Töpel, Magnus Karlsson).
- **5.3–5.13:** more zero-copy drivers, programs on map entries, BPF links, and broadcast redirect.
- **5.18:** multi-buffer (Lorenzo Bianconi, Eelco Chaudron). **6.3:** feature advertisement and hardware hints (Stanislav Fomichev). **6.6:** AF_XDP multi-buffer.
- **6.11:** redirect state moved from per-CPU to per-task, so XDP works on real-time kernels. **2024–2026:** AF_XDP transmit metadata (checksum offload, launch time), and XDP on Windows (2022).

## Related

- Technical version: [[xdp]]
- [[net-explained|Networking stack]], [[network-device-and-napi-explained|Devices and NAPI]], [[page-pool-explained|Page pool]], [[sk-buff-explained|skb]]
- [[bpf-explained|BPF]], [[bpf-program-types-explained|BPF program types]], [[bpf-maps-explained|BPF maps]], [[bpf-helpers-and-kfuncs-explained|Helpers and kfuncs]]
- [[traffic-control-qdisc-explained|Traffic control]], [[netfilter-explained|Netfilter]]
