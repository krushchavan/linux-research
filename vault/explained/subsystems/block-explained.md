---
title: "Block Layer — Explained"
category: explained
original: "[[block]]"
subsystem: block
tags: [explained, block, storage, blk-mq]
converted: 2026-09-25
---

# The block layer, explained

> Plain-language companion to [[block|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Filesystems, databases doing direct I/O, and virtual devices like encrypted or mirrored volumes all need to read and write blocks of storage. Underneath them sits a zoo of hardware: spinning disks, SATA SSDs, NVMe drives with dozens of queues, network block devices, and stacks of virtual devices. Without a common layer in between, every filesystem would need to know every device's quirks, and every device would have to cope with every filesystem's access patterns.

The block layer is that middle layer. It gives everything above it one way to say "read or write these sectors, from or into these memory pages". It then does the plumbing: batching, merging neighbouring requests, optionally reordering them, spreading them across the device's hardware queues, and reporting completions back.

The hard part is speed. Disks once managed a few hundred operations per second. NVMe drives do millions. The original block layer funnelled every request on every CPU through one lock, which became the bottleneck. Most of the modern design exists to get rid of that.

## The big picture

```text
 Filesystem / direct I/O / virtual devices
                │  "I/O request" (list of pages + target sectors)
                ▼
      per-task batching (plugging)
                │
                ▼
      per-CPU staging queues ──▶ optional scheduler (reorder / merge)
                │
                ▼
      hardware queues (one per device submission queue)
                │
                ▼
        device driver ──▶ storage device
                ▲                  │
                └─ completion ◀────┘  (interrupt or polling)
                │
                ▼
      filesystem is told "done"
```

## The pieces

### The I/O request unit (the "bio")
Everything starts with a small descriptor, called a **bio**: "this operation (read, write, flush, discard) on this device, starting at this sector, using these pages of memory". A bio can point at many scattered pages, so one request can gather data from all over memory. If a request is too big for a device, the block layer splits it into chained pieces.

Virtual devices (encryption, RAID, device-mapper) take a bio and submit new bios to the devices underneath. To stop deep stacks of virtual devices from overflowing the kernel stack, nested submissions are queued and processed after the outer one returns, instead of recursing.

### Batching ("plugging")
A task that is about to submit many requests can open a *plug*. Requests collect on a private list and are pushed down together when the plug closes, or automatically if the task goes to sleep. This lets neighbouring requests be merged and lets drivers notify the hardware once per batch instead of once per request.

### The multi-queue core ([[blk-mq-explained|blk-mq]])
This is what replaced the single global lock. It has two tiers:
1. **Per-CPU staging queues.** Each CPU has its own, so CPUs never contend with each other when submitting.
2. **Hardware queues.** One per submission queue the device actually has: 32 or more for NVMe, one for a simple SATA disk. Staging queues are mapped onto hardware queues.

Every in-flight request gets a small number called a **tag**. When the device reports "tag 17 is done", the kernel finds the request instantly instead of searching a list.

### I/O schedulers
Optional reordering stages that sit between the staging and hardware queues:
- **mq-deadline** gives reads and writes expiry deadlines so neither starves. It's the usual choice for spinning disks.
- **BFQ** shares disk time fairly between processes or groups, which suits interactive desktops.
- **Kyber** is a lightweight scheduler for fast devices that caps read and write latency separately.
- **none** means no reordering at all. It's the default for NVMe, because on a device that answers in tens of microseconds, reordering costs more CPU than it saves.

### Polling
For the lowest latency, a submitter can skip the completion interrupt entirely and repeatedly check the device's completion queue. An interrupt adds roughly 10–20 µs of overhead on very fast NVMe. io_uring can use this path.

## A request's journey

### Step 1: The filesystem builds a request
A filesystem flushing dirty cached pages builds a bio listing those pages and the target sectors, and submits it.

### Step 2: It's batched and staged
With a plug open, the request collects with its neighbours. When the plug closes, the batch goes to the submitting CPU's staging queue, where adjacent requests can merge into one larger one.

### Step 3: Scheduling (or not)
If a scheduler is configured, it decides when each request may proceed, for example keeping writes inside their latency budget. With `none`, requests go straight on.

### Step 4: Hand-off to the driver
The request moves to a hardware queue and the driver turns it into a device command. An NVMe driver, for example, writes a command into the controller's submission queue and rings its doorbell.

### Step 5: Completion
The device signals completion, usually with an interrupt, or the submitter's polling picks it up. The driver uses the tag to find the request and tells the block layer it's done.

### Step 6: The filesystem is told
The block layer calls the bio's completion callback, which wakes the writeback thread or whoever was waiting.

## Tradeoffs

- **What it gives you:** one uniform interface over every kind of storage, and a submission path that scales with CPU count and with the device's own parallelism. Before multi-queue, a 32-core machine with fast NVMe spent much of its time fighting over one lock.
- **What it costs:** more machinery (per-CPU and per-hardware-queue state, pre-allocated requests) and a fixed maximum number of in-flight requests per queue.
- **Where it bites:** choosing the wrong scheduler. Reordering helps spinning disks and fairness-sensitive workloads but just burns CPU on NVMe, which is why `none` is the NVMe default.

## How it got here

- **2001–2003:** deadline and anticipatory schedulers, then CFQ for per-process fairness, all built for spinning disks.
- **3.13 (2014):** the multi-queue design merged. The benchmark data, around 10× throughput on 32-core systems with SSDs, settled a long debate about whether the complexity was worth it.
- **4.12 (2017):** BFQ and Kyber arrive as multi-queue schedulers.
- **5.0 (2019):** the old single-queue path is deleted after around 50 drivers were ported.
- **Recent:** tighter io_uring integration (polling, passthrough commands straight to NVMe), and "zone append" for zoned storage, where the device picks the write position.

## Related

- Technical version: [[block]]
- [[blk-mq-explained|The multi-queue core]]: the scalable submission and dispatch engine
- [[io_uring-explained|io_uring]]: the async interface that drives polling and passthrough
- [[device-mapper-explained|Device mapper]]: stacked virtual block devices
- [[ublk-explained|ublk]]: block devices implemented by userspace programs
