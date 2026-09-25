---
title: "I/O Schedulers — Explained"
category: explained
original: "[[io-scheduler]]"
subsystem: block
tags: [explained, block, io-scheduler, bfq, mq-deadline]
converted: 2026-09-25
---

# I/O schedulers, explained

> Plain-language companion to [[io-scheduler|the technical note]]. Same facts, fewer identifiers.

## The problem

A storage device can only work on so many requests at once, and the **order** it gets them in matters. On a spinning disk, sending requests in sector order saves milliseconds of seeking each. On any device, one process streaming writes can bury another process's latency-critical reads. But on fast NVMe drives, which have no seek cost, deep internal queues and budgets of a few microseconds per request, any extra kernel work just gets in the way. One policy can't suit every device.

## The idea in one paragraph

The I/O scheduler (historically the "elevator") is an **optional** stage in [[blk-mq-explained|blk-mq]] that holds requests before they go to the driver, and can reorder, merge, throttle and share the device between them. Think of a restaurant kitchen's pass. **none** has no pass: orders go straight to the cooks, best when the kitchen is huge. **mq-deadline** is an expediter who groups orders by table but serves any ticket that has waited too long. **BFQ** is a maître d' giving each party turns in proportion to its reservation, and bumping the regular who only wants a coffee to the front. **Kyber** doesn't reorder; it watches how long dishes take and limits how many tickets of each kind are in the kitchen.

## Step by step

### Step 1: Where it sits
A bio arrives from the [[bio-layer-explained|bio layer]]. With no scheduler, blk-mq sends it straight to the driver or a per-CPU queue. With one attached, merges go through the scheduler, new requests are **inserted** into its private queues, and when the hardware queue runs, blk-mq asks the scheduler for the next request, one at a time, only while the driver has room. The scheduler decides *which* and *when*, but never touches hardware.

### Step 2: Two sets of tickets
This is the key step that made schedulers possible on blk-mq. A request waiting in the scheduler isn't using a hardware slot yet, so there are two tag pools: **scheduler tags** (a larger adjustable pool, taken when the request is created) and **driver tags** (taken only at dispatch). The scheduler gets a big pool to sort and choose from while the device queue stays shallow. Since 2025 the scheduler tags are allocated *before* the queue is frozen for a switch, which fixed deadlocks from allocating memory while frozen.

### Step 3: Merging
Before a scheduler-specific search, generic merging tries a one-entry "last merged" cache, then a hash table keyed by each request's end sector, which finds back-merge candidates instantly. Otherwise the scheduler is asked (mq-deadline looks for front merges in its sorted tree). Merging can be partly or fully switched off.

### Step 4: mq-deadline
The default for single-queue devices (SATA disks and SSDs, eMMC, many virtual disks). For each priority class (real-time, best effort, idle) and each direction it keeps a **sector-sorted tree** and a **FIFO** of deadlines: 500 ms for reads, 5 s for writes. Dispatch:
1. **continue the batch** in sector order, up to 16 requests; sequential sweeps are what make disks fast
2. **pick a direction**, preferring reads (someone is usually waiting on a read, while writes are usually background writeback), unless reads have already won twice in a row while writes waited
3. **pick a start point:** if the oldest request in that direction has passed its deadline, start there; otherwise carry on from the last sector

Higher-priority classes go first, but lower ones waiting more than 10 s are served anyway. The deadline is **soft**: it only chooses where the next batch starts. Async writes are limited to part of the tag pool so writeback can't starve reads. Until 6.10 it also kept writes in order for zoned drives, which is why those had to use it; the block core now does that for any scheduler.

### Step 5: BFQ
BFQ (Budget Fair Queueing) aims at **responsiveness on slow devices**. Each process gets its own queue. A queue chosen for service gets the device to itself for a **budget measured in sectors**, until the budget runs out, the queue empties, or a timeout hits (so random I/O can't hog it while moving little data). Budgets adapt to use. Which queue goes next is chosen by a weighted fair-queueing algorithm, so over any interval each queue gets service in proportion to its weight, with a tight bound on falling behind. Groups nest, which makes BFQ the proportional-weight controller for cgroup I/O.

The key, and costly, trick is **idling**: when a process's queue empties, BFQ may leave the device idle briefly (8 ms by default) waiting for its next request, which preserves locality on disks and makes fairness hold for processes that read one request at a time. Heuristics win back throughput: **injection** slips other I/O into the idle window when harmless, and **queue merging** joins processes whose I/O interleaves into one stream. In low-latency mode (the default), **weight raising** boosts queues that look interactive (an application starting up) or soft real-time (media playback). That's how application start-up stays fast during a big copy. The cost is CPU: about 0.6 µs per request after 2019's optimisations (from 1.9 µs; mq-deadline is about 0.2 µs), topping out around 300–400 thousand IOPS per device. Fine for disks, SD cards and SATA SSDs, a bottleneck on NVMe.

### Step 6: Kyber
Kyber targets fast multi-queue SSDs and **doesn't reorder at all**. Its insight: on NVMe, read latency under load comes from queueing *inside the device*. Requests fall into four domains (read, write, discard, other), each with a pool of tokens; a request needs a token to be dispatched, and dispatch round-robins between domains in small batches. On completion, latencies go into histograms. If reads miss their target (2 ms; 10 ms for writes), Kyber **shrinks the token pool** of whichever domain is hurting them, usually writes, until reads recover. It never became a default anywhere.

### Step 7: none, and choosing
**none** means no scheduler at all: no hooks, no extra tags, direct issue. At registration, the kernel picks mq-deadline only for devices with a single hardware queue or shared tags (unless the driver opts out), and none for everything else, including most NVMe. The old boot option does nothing; distributions choose per device with udev rules, and most desktop ones pick BFQ for rotational and MMC devices. Switching loads the module first, then freezes the queue (draining in-flight I/O), tears down the old scheduler and sets up the new one. Because switching dismantles structures in-flight paths use, it has been a steady source of use-after-free and lock-ordering bugs, now serialised by dedicated locks.

## The picture

```text
 bio ─▶ blk-mq ─┬─ none ─────────────────────────────────▶ driver (direct)
                └─ scheduler (scheduler tags) ─ dispatch when driver has room (driver tag) ─▶ driver
   mq-deadline:  per prio × dir: sorted tree + FIFO → batches of 16, reads first, expired first
   BFQ:          per-process queues, sector budgets, weighted fair order, idle ~8 ms, weight raising
   Kyber:        no reordering; tokens per {read, write, discard, other}, shrink on missed latency
```

## Tradeoffs

- **What it gives you:** the right policy per device: seek-friendly batching with starvation limits, strong fairness and interactivity on slow devices, latency control by depth on fast SSDs, or nothing at all when the hardware knows best.
- **What it costs / requires:** any scheduler brings back a per-device lock, so none of them scale to NVMe rates. That's why blk-mq shipped with none (3.13) and schedulers returned only as opt-in hooks (4.11/4.12). BFQ's fairness relies on idling, which costs throughput on SSDs.
- **Where it bites:** the defaults debate. Linus Walleij, Paolo Valente and Mark Brown argued for BFQ as the kernel default on slow single-queue devices, since embedded systems often lack udev; Jens Axboe held that policy belongs in user space, and the kernel kept mq-deadline/none. Limiting outstanding work, Kyber's approach, proved the more general idea: it reappears in writeback throttling and iocost, which work without any scheduler.

## How it got here

- **2.5/2.6:** legacy elevators: noop, deadline, anticipatory (removed 2.6.33) and CFQ (default from 2.6.18).
- **3.13 (2014):** blk-mq merged with no scheduling.
- **4.11 (2017):** the multi-queue scheduler framework with scheduler tags (from Jens Axboe's 2016 "shadow request" idea), plus mq-deadline.
- **4.12:** BFQ (Paolo Valente, Arianna Avanzini) and Kyber (Omar Sandoval).
- **5.0 (2019):** the legacy path and CFQ removed. **5.2:** BFQ injection and lower overhead.
- **5.14–6.0:** priority classes and priority aging in mq-deadline.
- **6.10:** zone write plugging takes zoned ordering out of mq-deadline.
- **2025:** switching reworked around pre-allocated scheduler tags and new locks, fixing long-standing deadlock reports.

## Related

- Technical version: [[io-scheduler]]
- [[blk-mq-explained|blk-mq]], [[bio-layer-explained|bio layer]], [[block-explained|Block layer]], [[io-controller-explained|I/O controller]], [[cgroups-explained|cgroups]]
- [[writeback-infrastructure-explained|Writeback]], [[io-uring-internals-explained|io_uring internals]]
