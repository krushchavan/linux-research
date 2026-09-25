---
title: "Page Pool — Explained"
category: explained
original: "[[page-pool]]"
subsystem: net
tags: [explained, networking, page-pool, dma, recycling]
converted: 2026-09-25
---

# The page pool, explained

> Plain-language companion to [[page-pool|the technical note]]. Same facts, fewer identifiers.

## The problem

A network card's receive queue uses up and refills buffers at line rate: about 15 million packets a second on 10 GbE, leaving roughly 200 CPU cycles per packet. Asking the page allocator for a fresh page and **DMA-mapping** it for the card (often an IOMMU operation) for every packet is far too slow. So every high-performance driver invented its own page-recycling trick, each subtly different.

Recycling has its own dangers. Pages leave the driver: they travel up into sockets, sit in TCP retransmit queues, or get redirected to other devices, and come back later, from other CPUs, sometimes after the driver has gone.

## The idea in one paragraph

The page pool is a **per-queue returnable-crate system**. Each receive queue owns a stack of crates (pages) already labelled for its lorry (DMA-mapped for its device). The queue takes crates from the stack right beside it, a **lock-free cache**. Crates returned at the same loading dock go straight back on that stack. Crates returned from elsewhere go into a shared **return bin** (a ring), which refills the stack in bulk. Only when both are empty are new crates ordered from the warehouse (the page allocator), and each is labelled once. Crates are unlabelled only when they leave the system for good.

## Step by step

### Step 1: One pool per queue
A driver creates one pool per receive queue (strictly, per NAPI context), giving it the page size, capacity, NUMA node, DMA device and direction, which part of each buffer the device writes, and flags. Drivers are strongly encouraged to let the pool **own DMA mapping and device syncing**. The single-consumer rule is what makes the fast path safe. The pool also registers as the memory model for XDP frames, so they know how to return their pages.

### Step 2: The fast path
During NAPI polling, the driver refills its descriptors from the pool: whole pages, sub-page fragments, or "whichever fits". The first place looked is the lock-free cache, a small array (64 entries with 4 KB pages) only this NAPI instance ever touches, so it needs no lock and no atomic. The page comes out already DMA-mapped, with its bus address stored in the page itself.

### Step 3: Refill from the ring, then the allocator
If the cache is empty, it pulls a batch from the ring of pages returned from other contexts. Pages from the wrong NUMA node are released rather than reused, so a queue whose interrupt moved doesn't keep serving remote memory forever. If the ring is empty too, it allocates a batch from the page allocator in one go, maps each page once (skipping a CPU sync, since the device writes first), and records the mapping. Whenever pages are handed out, the pool syncs just the region the device may write, so recycled pages are always ready for the device without the driver thinking about it.

### Step 4: Fragments for small packets
A 1,500-byte frame doesn't need a 4 KB page, let alone the 64 KB pages some architectures use. The pool can carve a page into fragments. Instead of an atomic increment per fragment, it pre-charges the page's reference count with a large bias and subtracts the unused part when it moves to the next page; the last fragment to come back recycles the page. The trade-off is contention on that shared count when fragments are freed on different CPUs.

### Step 5: Pages coming back
Pages return explicitly (a driver drops an XDP frame), in bulk (from XDP redirect paths), or implicitly: a driver marks an skb for recycling, and when the stack frees it, its pool pages go back to the pool instead of the page allocator.

This is the key step. A page can be recycled only if the pool holds the **only** reference and it isn't an emergency reserve page. Then:
- if we're in soft-interrupt context on the CPU that owns the pool's NAPI (and not on a real-time kernel), it goes **straight back into the lock-free cache**
- otherwise it goes into the ring under the ring's lock (bulk returns take the lock once for many pages)
- if the ring is full, or someone else still holds the page (say it was spliced into a socket), it's unmapped and returned to the page allocator

### Step 6: Tearing down
When a queue goes away, pages may still be in flight in sockets, retransmit queues, or other devices. So destruction isn't immediate: direct recycling is switched off, the cache and ring are emptied, and the pool counts pages still out. If any remain, it stays alive as a **zombie**, retrying every second and warning every 60 seconds.

Before 6.15 this was dangerous: a late page would be unmapped against a device whose driver was already gone, crashing systems with an IOMMU. Now every mapping is tracked, so at destroy time the pool can unmap **all** outstanding mappings, and pages returned later are simply freed. Races on this path were still being fixed in 2026.

### Step 7: Memory that isn't pages
[[devmem-tcp-explained|Device-memory TCP]] wants payloads to land in GPU memory, and [[io-uring-zero-copy-networking-explained|io_uring zero-copy receive]] wants them in user-registered memory. So the pool now deals in **netmem** handles, each either a real page or a small descriptor for a chunk of other memory. If a **memory provider** is bound to the queue, allocation and release go through it (ordinary pools pay nothing for this check). Such memory may be unreadable by the CPU, so drivers must opt in and use header/data split, so headers still land in normal pages.

## The picture

```text
 NAPI refill:  lock-free cache ──empty?──▶ return ring ──empty?──▶ page allocator (map once)
                  ▲                            ▲
 page returned:   │ same CPU, softirq          │ other CPU (ring lock)
                  └────────────────────────────┘
                  only the pool holds it? else → unmap → page allocator

 destroy:  stop direct recycling → drain → pages still out? zombie pool, retry every 1 s
           (6.15+) unmap every tracked mapping so late returns are safe
```

## Tradeoffs

- **What it gives you:** near-free buffer reuse on the common path, DMA mapping once per page lifetime instead of per packet, and one shared mechanism for XDP, skb recycling and non-page memory providers.
- **What it costs / requires:** strict one-pool-per-NAPI discipline; long-lived IOMMU mappings that must be tracked across device removal; fields borrowed inside the page structure, which drew memory-management scrutiny.
- **Where it bites:** pages with extra references (spliced to user space) fall back to the allocator, lowering recycle rates for some TCP workloads. Teardown with pages in flight has been the pool's sharpest edge, and "in-flight" warnings are often false positives from legitimately long-lived skbs.

## How it got here

- **2016–2017:** Jesper Dangaard Brouer argues for a shared DMA-mapped page allocator. **4.18 (2018):** the page pool merged with XDP memory models; mlx5 is the first user.
- **5.x:** the pool owns DMA mapping, then device syncing (5.7); in-flight accounting and deferred release.
- **5.14:** skb recycling (Ilias Apalodimas, Matteo Croce), after review moved the recycling marker so it wouldn't alias other page fields. **5.15–5.17:** fragments. **5.18:** statistics.
- **6.6–6.9:** API reorganisation, netlink introspection of pools (including zombies), and per-CPU system pools for generic paths.
- **6.10–6.12:** netmem and memory providers (Mina Almasry), and device-memory TCP. **6.15:** io_uring zero-copy provider; mapping tracking and unmap-on-destroy (Toke Høiland-Jørgensen).
- **2025–2026:** netmem descriptors split out, a dedicated page type replacing the recycling marker, larger receive buffers, and a run of teardown race fixes.

## Related

- Technical version: [[page-pool]]
- [[net-explained|Networking stack]], [[network-device-and-napi-explained|Devices and NAPI]], [[sk-buff-explained|skb]], [[xdp|XDP]]
- [[devmem-tcp-explained|Device-memory TCP]], [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]]
- [[buddy-allocator-explained|Buddy allocator]], [[dma-mapping-api-explained|DMA mapping]], [[xarray-explained|XArray]]
