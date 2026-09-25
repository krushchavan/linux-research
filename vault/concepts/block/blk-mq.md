---
title: "blk-mq (Multi-Queue Block Layer)"
category: concept
tags: [block, blk-mq, storage, nvme, tags, scalability]
subsystem: block
kernel_version: "3.13"
researched: 2026-09-25
status: complete
explained: "[[blk-mq-explained]]"
sources:
  - https://kernel-internals.org/block/blk-mq/
  - https://www.kernel.org/doc/html/latest/block/blk-mq.html
  - https://www.kernel.dk/blk-mq.pdf
  - https://lwn.net/Articles/552904/
  - https://lwn.net/Articles/736534/
  - https://lwn.net/Articles/944385/
  - https://lwn.net/Articles/1002722/
---

# blk-mq (Multi-Queue Block Layer)

> 📘 Plain-language version: [[blk-mq-explained]]

## Purpose

Before 3.13 every block device had one `request_queue` protected by one spinlock, and every submitting CPU and every completion interrupt fought over it. That was fine for disks doing a few hundred IOPS. It fell apart with flash: early NVMe testing saturated around 700K IOPS because of lock bouncing, while the hardware could accept millions spread across many hardware queues. blk-mq, designed by Jens Axboe with Matias Bjørling (SYSTOR 2013), replaces the single queue with per-CPU software queues, per-hardware-queue dispatch contexts, and a scalable tag allocator. The kernel's submission path can then scale with core count and with the device's own parallelism. Since 5.0 it is the *only* request-based block path.

## Mental Model

Think of an **airport with per-gate check-in**. Each CPU has its own check-in desk (software queue, `blk_mq_ctx`), so passengers (requests) never queue behind another CPU. Desks feed a small number of boarding gates (hardware contexts, `blk_mq_hw_ctx`), one per device submission queue. Each seat on the plane is a numbered boarding pass (a *tag*). If you hold a tag you are guaranteed a hardware slot, and when the plane lands (completion) the tag number instantly identifies whose bag it is.

## How It Works

**Setting up a device.** A driver describes its hardware in a `struct blk_mq_tag_set`: `nr_hw_queues`, `queue_depth`, `cmd_size` (driver-private bytes appended to every `struct request`), `numa_node`, `flags`, `nr_maps` and the `ops` table (`struct blk_mq_ops`). `blk_mq_alloc_tag_set()` preallocates every request for every hardware queue up front, so the hot path never calls a memory allocator. `blk_mq_alloc_disk()` (formerly `blk_mq_init_queue()`) then creates the `request_queue`, one `blk_mq_ctx` per CPU and one `blk_mq_hw_ctx` per hardware queue. The CPU→hctx mapping comes from `ops->map_queues()` (typically `blk_mq_map_hw_queues()` using the device's MSI-X IRQ affinity), so a CPU submits to the hardware queue whose interrupt is delivered back to it. A tag set can have up to three maps: `HCTX_TYPE_DEFAULT`, `HCTX_TYPE_READ` (dedicated read queues) and `HCTX_TYPE_POLL` (interrupt-less queues for polled I/O).

**Submission: from bio to request.** A filesystem or direct-I/O path calls `submit_bio()`. For blk-mq devices this reaches `blk_mq_submit_bio()`. The first step is merging. If the task has an active *plug* (`blk_start_plug()`, used by filesystems and io_uring around batches), the bio may merge into a request already on the plug list. Otherwise the scheduler, or the software queue with `none`, gets a chance (`blk_mq_sched_bio_merge()`). Merging matters because one 128K request is far cheaper to issue than 32 × 4K ones. If there's no merge, a request is obtained. With a plug, blk-mq pre-allocates a *batch* of requests into `plug->cached_rqs` (5.16+), so subsequent bios take one without touching the allocator. Otherwise `blk_mq_get_new_requests()` → `__blk_mq_alloc_requests()` → `blk_mq_get_tag()`.

**Tags.** The tag allocator is an `sbitmap` (scalable bitmap) in `struct blk_mq_tags`. Bits are spread over cache-line-sized words, and each CPU remembers a hint of where it last found a free bit, so concurrent CPUs rarely touch the same cache line. `sbitmap_queue` adds batched wake-ups for waiters when the queue is full. With an I/O scheduler there are two tag spaces: *scheduler tags* (`sched_tags`, which can be larger, for requests the elevator is holding) and *driver tags* (a real hardware slot, taken only at dispatch). If no tag is available the submitter sleeps in `blk_mq_get_tag()`. That is the block layer's back-pressure. `BLK_MQ_F_TAG_HCTX_SHARED` lets all hctxs of a host share one tag space (SCSI hosts with a single command pool), and fair-sharing logic stops one busy LUN from starving others on a shared tag set.

**Plugging and batching.** With a plug active, new requests go onto the per-task plug list instead of being issued immediately. When the plug is flushed (`blk_finish_plug()`, or automatically when the task schedules out via `blk_flush_plug()`), `blk_mq_flush_plug_list()` sorts requests by hctx. If the driver implements `->queue_rqs()`, it hands the whole list over in one call (5.17+, NVMe and virtio-blk use it to ring the doorbell once per batch). Otherwise requests go through the scheduler insert path or directly to dispatch.

**Direct issue vs. insert.** With the `none` scheduler and no plug, blk-mq tries *direct issue*: `blk_mq_try_issue_directly()` takes a driver tag and calls `->queue_rq()` right away from the submitting context. This is the lowest-latency path for NVMe. With a scheduler (mq-deadline, BFQ, Kyber), the request is inserted into the elevator via `blk_mq_sched_insert_request()` and waits there to be reordered or merged.

**Dispatch.** `blk_mq_run_hw_queue()` runs the hctx, either inline or asynchronously on `kblockd` when called from atomic context or if the driver needs `BLK_MQ_F_BLOCKING`. `blk_mq_sched_dispatch_requests()` pulls work in priority order:
1. `hctx->dispatch`, requests that the driver previously refused
2. then the elevator's `->dispatch_request()`
3. or, with no scheduler, the mapped software queues (`blk_mq_flush_busy_ctxs()`)

`blk_mq_dispatch_rq_list()` gets a driver tag for each request (`blk_mq_get_driver_tag()`) and calls `ops->queue_rq(hctx, bd)`. `bd->last` tells the driver whether more requests follow, so it can delay the doorbell and later receive `->commit_rqs()`. The driver builds its hardware command (for example an NVMe SQE from `blk_rq_map_sg()` or its DMA mapping), marks it started with `blk_mq_start_request()` (which also arms the timeout), and returns `BLK_STS_OK`.

**Slow path: the device is busy.** If `queue_rq()` returns `BLK_STS_RESOURCE` (out of device resources) or `BLK_STS_DEV_RESOURCE`, the request is put back on `hctx->dispatch` and the hctx is marked for restart (`BLK_MQ_S_SCHED_RESTART`). When some other request completes and frees capacity, the queue is re-run. `BLK_STS_DEV_RESOURCE` promises the driver will re-run the queue itself. Otherwise blk-mq also schedules a short delayed re-run so nothing stalls. `blk_mq_requeue_request()` lets a driver push a started request back (for example after a path failover), and the requeue list is processed on kblockd.

**Completion.** The device raises an interrupt, or the submitter polls. The driver maps the hardware completion to a request via the tag (`blk_mq_tag_to_rq(tags, tag)`), which is O(1) with no search. It then calls `blk_mq_complete_request()`. By default blk-mq completes on the *submitting* CPU's cache domain: if the IRQ arrived elsewhere, it sends an IPI (`blk_mq_complete_send_ipi()`) or raises the block softirq so `ops->complete()` runs where the request's data is cache-hot. The `rq_affinity` sysfs knob controls this (0 = off, 1 = same cache group, 2 = exact CPU). The driver's `->complete()` eventually calls `blk_mq_end_request()`, which completes the bios (`bio_endio()`), frees the tag and releases the request. With batched completion (5.16+), polling and interrupt paths collect finished requests in an `io_comp_batch` and end them together (`blk_mq_end_request_batch()`), amortising tag freeing and statistics.

**Polling.** For `HCTX_TYPE_POLL` queues there is no interrupt. io_uring with `IORING_SETUP_IOPOLL`, or `preadv2(RWF_HIPRI)`, submits to a poll queue and then calls `bio_poll()` → `blk_mq_poll()` → `ops->poll()` (e.g. `nvme_poll()`), which reaps the completion queue directly. This trades CPU time for the lowest latency.

**Failure path: timeouts.** A per-queue timer (`blk_mq_timeout_work()`) scans started requests using `blk_mq_queue_tag_busy_iter()`. For an expired one it calls `ops->timeout()`. The driver may reset the controller and complete the request with an error (`BLK_EH_DONE`), or ask for more time (`BLK_EH_RESET_TIMER`). Request state (`MQ_RQ_IDLE/IN_FLIGHT/COMPLETE`) guards against a completion and a timeout racing on the same request.

**Quiesce and freeze.** Two different "stop" mechanisms exist. `blk_mq_quiesce_queue()` stops *dispatch*: requests may still be queued, but `->queue_rq()` won't be called (SRCU/RCU is used to wait for in-progress calls). It's used by drivers during reset, and by ublk while its server is gone. `blk_mq_freeze_queue()` stops *new request entry* by killing a percpu refcount (`q_usage_counter`) and waits until every in-flight request has completed. It's used when changing queue limits, switching schedulers, or updating the number of hardware queues (`blk_mq_update_nr_hw_queues()`).

## Key Data Structures

**`struct blk_mq_tag_set`** (`include/linux/blk-mq.h`) — shared driver description.
- `ops`, `nr_hw_queues`, `queue_depth`, `cmd_size`, `numa_node`
- `map[HCTX_MAX_TYPES]` — CPU→hctx mappings per type
- `flags` — `BLK_MQ_F_BLOCKING`, `BLK_MQ_F_TAG_HCTX_SHARED`, `BLK_MQ_F_NO_SCHED`…
- `tags[]` — per-hctx `blk_mq_tags`

**`struct blk_mq_hw_ctx`** — one hardware queue.
- `dispatch` — requests the driver refused, retried first
- `tags`, `sched_tags` — driver and scheduler tag spaces
- `ctx_map`, `ctxs` — which software queues have pending work
- `cpumask`, `queue_num`, `driver_data`, `state` (`BLK_MQ_S_STOPPED`, `SCHED_RESTART`…)

**`struct blk_mq_ctx`** — per-CPU software queue: `rq_lists[HCTX_MAX_TYPES]`, `lock`, `hctxs[]`.

**`struct request`** (`include/linux/blk-mq.h`) — `tag`, `internal_tag`, `mq_hctx`, `bio`/`biotail`, `__sector`, `__data_len`, `cmd_flags`, `state`, `deadline`, followed by `cmd_size` bytes of driver PDU (`blk_mq_rq_to_pdu()`).

**`struct blk_mq_ops`** — `queue_rq`, `commit_rqs`, `queue_rqs`, `get_budget`/`put_budget` (SCSI device-level limits), `timeout`, `poll`, `complete`, `init_hctx`, `init_request`, `map_queues`.

## Key Functions / Entry Points

**`blk_mq_submit_bio()`** (`block/blk-mq.c`) — bio → request; merge, allocate, plug or issue.
**`blk_mq_flush_plug_list()`** — push a task's batched requests to drivers.
**`blk_mq_run_hw_queue()` → `blk_mq_sched_dispatch_requests()` → `blk_mq_dispatch_rq_list()`** — dispatch loop.
**`blk_mq_start_request()`** — driver marks a request in-flight.
**`blk_mq_complete_request()` / `blk_mq_end_request()`** — completion.
**`blk_mq_get_tag()`** (`block/blk-mq-tag.c`) — sbitmap-based tag allocation.
**`blk_mq_freeze_queue()` / `blk_mq_quiesce_queue()`** — stop entry / stop dispatch.
**`blk_mq_alloc_tag_set()` / `blk_mq_alloc_disk()`** — driver setup.

## Important Flags & Config Options

- `/sys/block/<dev>/queue/scheduler` — `none`, `mq-deadline`, `bfq`, `kyber`. `none` is the default for fast multi-queue devices.
- `/sys/block/<dev>/queue/nr_requests` — scheduler queue depth.
- `/sys/block/<dev>/queue/rq_affinity` — completion steering (0/1/2).
- `/sys/block/<dev>/queue/nomerges` — disable merge attempts (0/1/2).
- `/sys/block/<dev>/queue/io_poll`, `io_poll_delay` — polling.
- `/sys/block/<dev>/mq/<n>/cpu_list` — CPU→hctx mapping; debugfs `/sys/kernel/debug/block/<dev>/` shows tags, dispatch lists and states.
- NVMe `poll_queues`, `write_queues` module parameters — size the POLL/READ maps.
- `BLK_MQ_F_BLOCKING` — driver's `queue_rq` may sleep (nbd, ublk-like drivers); dispatch then runs from kblockd.

## Interactions with Other Subsystems

- **↑ Userspace**: indirectly via read/write/io_uring; sysfs/debugfs knobs; `blktrace`/`bpftrace` tracepoints (`block_rq_issue`, `block_rq_complete`).
- **← [[bio-layer]]**: filesystems, [[device-mapper]] (request-based dm-multipath) and md hand bios to `blk_mq_submit_bio()`.
- **→ [[io-scheduler]]**: `elevator_mq_ops` insert/dispatch hooks.
- **← [[io_uring]]**: plugging, `IOPOLL` via poll queues, and `->queue_rqs()` batching are tuned for io_uring's submission bursts.
- **→ Drivers**: NVMe, SCSI (scsi-mq), virtio-blk, null_blk, loop, nbd, [[ublk]], dm-rq implement `blk_mq_ops`.
- **→ [[interrupt-handling]]**: IRQ affinity drives queue mapping, and completion IPIs/softirq steer work.

## Design Decisions & Tradeoffs

- **Two-level queues.** Per-CPU software queues remove submit-side contention. Hardware contexts match the device. Keeping both levels lets blk-mq serve devices with 1 queue and 128 queues with the same code. The cost is extra structure and memory: every CPU×hctx pair has state, and all requests are preallocated.
- **Tags as identity.** Preallocating requests indexed by tag makes lookup at completion trivial and bounds memory. The cost is a fixed maximum queue depth, and tag exhaustion becomes the place where submitters block.
- **Scheduler optional.** The legacy elevator always ran. In blk-mq the default for NVMe is `none`, because reordering costs more than it gains on flash. Schedulers were re-added as opt-in (mq-deadline 4.11, BFQ and Kyber 4.12) for rotational media, fairness and latency control.
- **Complete near the submitter.** IPI steering improves cache locality at the cost of cross-CPU interrupts. With one hardware queue per CPU and aligned IRQ affinity the IPI disappears entirely, which is why queue mapping follows MSI-X affinity.
- **Removing the legacy path.** Maintaining two request paths doubled testing and blocked new features. Once scsi-mq matured, the single-queue code was deleted in 5.0. Slow devices lost the old CFQ scheduler (BFQ replaced it), a small cost for one code path.

## How It Has Evolved

- **3.13 (2014)** — blk-mq merged; virtio-blk and null_blk first users.
- **3.17–3.19** — scsi-mq (opt-in); NVMe converted (4.0).
- **4.10** — hybrid polling; 4.11 multiqueue scheduler framework and mq-deadline; 4.12 BFQ and Kyber.
- **4.20** — multiple queue maps (`HCTX_TYPE_READ/POLL`).
- **5.0 (2019)** — legacy single-queue block layer and CFQ/deadline/noop removed.
- **5.16** — plug-cached request allocation, batched completion (`io_comp_batch`), bio-based polling rework, major per-I/O overhead cuts (Axboe's 10M+ IOPS per core work).
- **5.17** — `->queue_rqs()` batched issue (NVMe, later virtio-blk).
- **6.x** — `queue_rqs()` optimisation (2023), atomic `queue_limits` updates (6.9–6.11), io_uring passthrough for more drivers (virtio-blk 2024).

## Further Reading

1. [The multiqueue block layer — LWN (2013)](https://lwn.net/Articles/552904/)
2. [A block layer introduction part 2: the request layer — LWN (2017)](https://lwn.net/Articles/736534/)
3. [Linux Block IO: Introducing Multi-queue SSD Access on Multi-core Systems — Bjørling, Axboe et al., SYSTOR 2013](https://www.kernel.dk/blk-mq.pdf)
4. [blk-mq documentation — kernel.org](https://www.kernel.org/doc/html/latest/block/blk-mq.html)
5. [kernel-internals.org — blk-mq](https://kernel-internals.org/block/blk-mq/)
6. [blk-mq: optimize queue_rqs() support — LWN patch posting (2023)](https://lwn.net/Articles/944385/)

## LKML Highlights

> The LKML search tool was unreachable (TLS error) during this run; highlights are drawn from LWN coverage.

- **"blk-mq: new multi-queue block IO queueing mechanism" (Jens Axboe, 2013)** — the original series. The debate centred on whether per-CPU queues would break I/O scheduling for rotational disks, and schedulers were deliberately deferred.
- **"blk-mq: optimize queue_rqs() support" (Sep 2023)** — moves inflight-table handling into the core so drivers implementing `->queue_rqs()` get batching for free. null_blk showed +3.6% IOPS under io_uring.
- **Legacy request path removal (Christoph Hellwig / Jens Axboe, 4.21→5.0 cycle)** — converted the last single-queue drivers and deleted `request_fn`, ending the dual-path era.
