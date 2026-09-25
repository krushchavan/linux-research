---
title: "blk-mq (Multi-Queue Block Layer) — Explained"
category: explained
original: "[[blk-mq]]"
subsystem: block
tags: [explained, block, blk-mq, storage]
converted: 2026-09-25
---

# blk-mq (the multi-queue block layer), explained

> Plain-language companion to [[blk-mq|the technical note]]. Same facts, fewer identifiers.

## The problem

Until 2014, every storage device in Linux had one request queue protected by one lock. Every CPU submitting I/O and every completion interrupt had to take that lock. For spinning disks doing a few hundred operations per second that didn't matter.

Flash changed that. Early NVMe testing topped out around 700,000 operations per second, and the limit wasn't the drive. It was CPUs fighting over that lock and bouncing its cache line between cores. Meanwhile NVMe drives offer many independent hardware queues that the kernel could only use one of. The storage bottleneck had moved from the device into the operating system.

## The idea in one paragraph

Give every CPU its own place to put requests, so CPUs never contend with each other. Map those per-CPU queues onto the device's real hardware queues, ideally one per CPU, so each CPU talks to "its" queue and gets its completions back on the same CPU. Pre-allocate every request slot and identify each in-flight request by a small number, a *tag*, so no memory allocation or searching happens on the hot path. That combination lets the kernel keep up with millions of operations per second per device.

## Step by step

### Step 1: The driver describes the hardware
When a storage driver starts up, it tells the block layer how many hardware queues the device has, how deep each one is, and how much private space it needs per request. The block layer then **pre-allocates every request** for every queue. This matters because it means the hot path never calls the memory allocator.

It also decides which CPUs feed which hardware queue, usually by following which CPU each queue's interrupt is delivered to. Separate queues can be set aside for reads or for polled I/O.

### Step 2: A request arrives and may merge
A filesystem or direct-I/O path submits a request ("write these pages to these sectors"). The first thing blk-mq tries is **merging**: if it's adjacent to a request already waiting, the two become one. One large request is much cheaper to issue than many small ones.

### Step 3: Getting a slot (a tag)
If there's no merge, the request needs one of the pre-allocated slots, identified by a tag. Tags are handed out by a bitmap designed so different CPUs usually look at different parts of it, which avoids fighting over the same memory.

This is also where back-pressure lives: **if every tag is in use, the submitter waits.** When a scheduler is in use there are two kinds of tag: one for "the scheduler is holding this request" and one for "this request has a real hardware slot". The second is only taken at the moment of dispatch.

### Step 4: Batching with a plug
If the submitter opened a *plug* to batch its work, requests collect on a private list. When the plug closes, or the task goes to sleep, the batch is sorted by hardware queue. Drivers that support it get the whole batch in one call and notify the hardware once per batch, not once per request.

### Step 5: Straight through, or via a scheduler
With no scheduler (the NVMe default), blk-mq tries to hand the request directly to the driver from the submitting CPU. That's the lowest-latency path. With a scheduler (mq-deadline, BFQ or Kyber), the request waits in the scheduler, which decides when it goes.

### Step 6: Dispatch to the driver
When a hardware queue runs, it takes work in priority order:
1. requests the driver previously refused
2. then whatever the scheduler releases
3. or, with no scheduler, the per-CPU queues

Each request is handed to the driver, which turns it into a device command and marks it started. That also starts its timeout clock. The driver is told whether more requests are coming, so it can delay the doorbell until the last one.

### Step 7: When the device is full
If the driver says "no room right now", the request goes back to the front of the line and the queue is marked to be re-run when something completes and frees space. A short delayed re-run also guarantees nothing gets stuck. Drivers can also push a request back deliberately, for example after switching to a different path to the device.

### Step 8: Completion comes home
The device signals completion by interrupt, or through polling. The driver turns the device's tag into the request instantly, with no search. By default the kernel then finishes the request **on or near the CPU that submitted it**, sending a cross-CPU nudge if the interrupt arrived elsewhere, because that CPU's caches still hold the request's data. The submitter is told the I/O is done and the tag is freed.

Completions are also batched: when many finish together, they're wrapped up in one pass.

### Step 9: Polling instead of interrupts
For the lowest latency, a request can go to a queue with no interrupt at all. The submitter keeps checking the device's completion queue directly. That spends CPU time to save interrupt overhead, and io_uring uses it when asked to.

### Step 10: When things go wrong: timeouts
A timer regularly checks started requests. If one has run too long, the driver is asked what to do: reset the controller and fail the request, or give it more time. Each request carries a state that prevents a late completion and a timeout from both acting on it.

### Step 11: Stopping the queue safely
There are two different ways to pause, and the difference matters:
- **Quiesce** stops *dispatch*. Requests can still queue up, but nothing is sent to the driver. Drivers use this during a controller reset.
- **Freeze** stops *new requests from entering* and waits until every in-flight one finishes. It's used when changing queue settings, switching schedulers or changing the number of hardware queues.

## The picture

```text
 CPU0        CPU1        CPU2        CPU3        ← submitters
  │           │           │           │
 [staging]   [staging]   [staging]   [staging]   ← per-CPU queues (no sharing)
   \           /           \           /
    ▼         ▼             ▼         ▼
   (optional scheduler: reorder / hold)
      │                        │
 [hardware queue 0]      [hardware queue 1]      ← match the device's real queues
   tags 0..N-1              tags 0..N-1          ← pre-allocated request slots
      │                        │
      ▼                        ▼
   driver ──▶ device ──▶ completion "tag 17 done"
                               │
            finish on the submitting CPU (cache-warm)
```

## Tradeoffs

- **What it gives you:** submission that scales with core count and with the device's parallelism. Modern NVMe reaches millions of operations per second, limited by PCIe rather than kernel locks.
- **What it costs:** memory and structure. Every request is pre-allocated, and every CPU/queue pair has state. Queue depth is a fixed maximum, and running out of tags is where submitters stall.
- **Where it bites:** schedulers. Reordering helps spinning disks and fairness but wastes CPU on NVMe, hence `none` as the NVMe default. Cross-CPU completion nudges also cost something unless queues line up one-to-one with CPUs.

## How it got here

- **3.13 (2014):** multi-queue merged, designed by Jens Axboe with Matias Bjørling. Schedulers were deliberately left out at first.
- **3.17–4.0:** SCSI and NVMe move onto it.
- **4.11–4.12:** schedulers return as opt-in: mq-deadline, then BFQ and Kyber.
- **5.0 (2019):** the old single-queue path is deleted, leaving one code path.
- **5.16–5.17:** big per-I/O overhead cuts (request caching in plugs, batched completion, batched submission to drivers), pushing past 10 million operations per second per core.

## Related

- Technical version: [[blk-mq]]
- [[block-explained|The block layer]]: the subsystem this sits in
- [[io_uring-explained|io_uring]]: the async interface that uses plugging, batching and polling
- [[ublk]]: a driver whose "hardware" is a userspace program
- [[dma-mapping-api-explained|DMA mapping]]: how drivers make request memory reachable by the device
