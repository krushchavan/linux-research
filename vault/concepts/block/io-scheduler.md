---
title: "I/O Schedulers (the blk-mq Elevator: mq-deadline, BFQ, Kyber, none)"
category: concept
tags: [block, io-scheduler, elevator, mq-deadline, bfq, kyber]
subsystem: block
kernel_version: "4.11"
researched: 2026-09-25
status: complete
sources:
  - https://kernel-internals.org/block/io-schedulers/
  - https://www.kernel.org/doc/html/latest/block/bfq-iosched.html
  - https://www.kernel.org/doc/html/latest/block/deadline-iosched.html
  - https://www.kernel.org/doc/html/latest/block/kyber-iosched.html
  - https://lwn.net/Articles/708465/
  - https://lwn.net/Articles/720675/
  - https://lwn.net/Articles/720071/
  - https://lwn.net/Articles/767987/
  - https://lwn.net/Articles/784267/
  - https://lwn.net/Articles/738449/
  - https://raw.githubusercontent.com/torvalds/linux/master/block/elevator.h
  - https://raw.githubusercontent.com/torvalds/linux/master/block/elevator.c
  - https://raw.githubusercontent.com/torvalds/linux/master/block/mq-deadline.c
  - https://raw.githubusercontent.com/torvalds/linux/master/block/kyber-iosched.c
---

# I/O Schedulers (the blk-mq Elevator: mq-deadline, BFQ, Kyber, none)

## Purpose

A storage device can only work on so many requests at once, and the order in which it receives them matters. On a spinning disk, sending requests in sector order saves milliseconds of seek time per request. On any device, one process streaming writes can bury another process's latency-critical reads. The *I/O scheduler* (historically the "elevator") is the optional stage in [[blk-mq]] that holds requests before they are dispatched to the driver. It reorders them, merges them, throttles them and shares the device between them. Without it, dispatch order is whatever order submitters happened to use. That is ideal for NVMe, which has no seek cost and deep hardware queues, and poor for HDDs, SD cards and mixed interactive and bulk workloads.

## Mental Model

Think of a busy restaurant kitchen's pass (the counter where finished dishes wait). The **none** scheduler has no pass: orders go straight from the waiter to the cooks, which is fastest when the kitchen is huge and never falls behind. **mq-deadline** is an expediter who groups orders by table (sector order) for efficiency, but checks the ticket timestamps and serves any order that has waited too long. **BFQ** is a maître d' who gives each party a turn at the kitchen in proportion to its reservation weight and pushes the regular who only wants a quick coffee to the front. **Kyber** doesn't reorder anything. It watches how long dishes take to come out and limits how many tickets of each type (read, write, discard) can be in the kitchen at once, so the kitchen never gets so overloaded that a simple order takes forever.

## How It Works

**Where the scheduler sits.** A filesystem's bio goes through the [[bio-layer]] into `blk_mq_submit_bio()`. With no scheduler attached (`q->elevator == NULL`), blk-mq either issues the request directly to the driver or parks it on a per-CPU software queue. When an elevator is attached, three things change. Merging goes through the scheduler (`blk_mq_sched_bio_merge()` → `ops.bio_merge`). New requests are *inserted* into the scheduler's private queues (`ops.insert_requests`) instead of going to the driver. When the hardware context is run, `blk_mq_sched_dispatch_requests()` asks the scheduler for the next request (`ops.dispatch_request`) one at a time, only while the driver has capacity. The scheduler therefore controls *which* request goes next and *when*, but it never talks to hardware.

**Two tag spaces.** A request held by the scheduler isn't using a hardware slot yet, so blk-mq keeps two tag sets per hctx. `sched_tags` has depth `nr_requests` (tunable in sysfs, often larger than the device queue) and is taken when the request is allocated. A real *driver tag* is taken only at dispatch. This split is what lets a scheduler hold a large pool of requests to sort and choose from while the device queue stays shallow. It began as the "shadow request" idea in Jens Axboe's original 2016 framework. Since 2025 the tags live in a `struct elevator_tags` (`nr_hw_queues`, `nr_requests`, `tags[]`) allocated *before* the queue is frozen for a switch. This fixed lockdep splats and deadlocks caused by allocating memory while the queue was frozen.

**The plug-in interface.** Each scheduler is a `struct elevator_type` (`block/elevator.h`). It carries a name and alias, sysfs attributes (`elevator_attrs`, which appear under `/sys/block/<dev>/queue/iosched/`), an optional per-task `io_cq` cache (`icq_size`, used by BFQ to attach per-process state to `io_context`), and `struct elevator_mq_ops`. The main hooks are:
- `init_sched`/`exit_sched`/`init_hctx` — set up the private data stored in `elevator_queue->elevator_data`
- `limit_depth` — called at allocation time so a scheduler can make async I/O use only part of the tag space
- `prepare_request`/`finish_request` — per-request setup and teardown (BFQ attaches the `bfq_queue` here)
- `bio_merge`, `request_merge`, `request_merged`, `requests_merged` — merge participation
- `insert_requests`, `dispatch_request`, `has_work` — the core queue
- `completed_request` — completion-time latency feedback (Kyber)
- `depth_updated` — `nr_requests` changed

The per-queue instance is `struct elevator_queue`: `type`, `et` (tags), `elevator_data`, a sysfs `kobj`, flags (`ELEVATOR_FLAG_REGISTERED`, `_DYING`) and a hash table.

**Merging.** Before a scheduler-specific search, the generic `elv_merge()` tries, in order: the one-hit cache `q->last_merge`, then a hash table keyed by each request's *end* sector (`rq_hash_key()` = pos + sectors, maintained by `elv_rqhash_add()`/`_del()`). That table finds back-merge candidates in O(1). If both fail it calls `ops.request_merge`, where mq-deadline looks up its sector rb-tree for a *front* merge. `nomerges` in sysfs switches these stages off. After a merge, `elv_attempt_insert_merge()` can also coalesce two whole requests.

**Choosing and switching.** At queue registration `elevator_set_default()` picks mq-deadline only if the device has a single hardware queue *or* shared tags, and the driver didn't set `BLK_MQ_F_NO_SCHED_BY_DEFAULT`. Everything else (most NVMe) gets `none`. The old `elevator=` boot parameter now does nothing except print a warning. Distributions set policy with udev rules that write `/sys/block/<dev>/queue/scheduler`. A write there calls `elevator_change()`. It loads the module first (`elv_iosched_load_module()` → `request_module("%s-iosched")`), because reading a module from disk while the queue is frozen could deadlock. It then freezes the queue (`blk_mq_freeze_queue()` drains in-flight I/O) and calls `elevator_switch()`, which quiesces dispatch, calls `elevator_exit()` on the old scheduler and `blk_mq_init_sched()` on the new one. Because a switch tears down the structures that in-flight paths use, it has been a steady source of use-after-free and lock-ordering bugs. That is why the switch is now serialised by `q->elevator_lock` and a `update_nr_hwq_lock` rwsem. `blk_mq_update_nr_hw_queues()` also forces a detach and re-attach through `elv_update_nr_hw_queues()`.

### mq-deadline

mq-deadline is the default for single-queue devices (SATA/SAS HDDs and SSDs, eMMC, many virtual disks). It is a forward port of the legacy `deadline` scheduler (4.11). Its state is `struct deadline_data`. It keeps one `struct dd_per_prio` for each I/O priority class (RT, BE, IDLE), and each of those holds, per direction (read/write), a **sector-sorted rb-tree** (`sort_list[]`) and a **FIFO** in deadline order (`fifo_list[]`). On insert (`dd_insert_request()`), a request gets `deadline = now + fifo_expire[dir]` (500 ms for reads, 5 s for writes) and goes on both structures.

`dd_dispatch_request()` walks the priority levels from RT to IDLE and takes the first that has work. As an anti-starvation measure it first calls `dd_dispatch_prio_aged_requests()`, which serves lower-priority requests that have waited longer than `prio_aging_expire` (10 s). Inside `__dd_dispatch_request()` the logic is the classic deadline algorithm:
1. **Continue the batch.** If the current direction still has a next-in-sector-order request and fewer than `fifo_batch` (16) requests have been sent in this batch, send it. Sequential sweeps are what make HDDs fast.
2. **Pick a direction.** Prefer reads, because a read usually has a process blocked on it while writes are usually buffered writeback. But if writes are pending and reads have already won `writes_starved` (2) times in a row, switch to writes.
3. **Pick a starting point.** If the FIFO head of that direction has passed its deadline, start the new batch there (jumping back in LBA order). Otherwise continue from the next request after the last dispatched sector.

The "deadline" is a *soft* guarantee. It only decides where the next batch starts, so worst-case latency is roughly the expiry plus a batch.

`dd_limit_depth()` limits async requests to `async_depth` tags, so a flood of buffered writeback cannot use every scheduler tag and block synchronous reads at allocation time. Until 6.10, mq-deadline also carried *zone write locking* so that sequential-write-required zones on SMR/ZNS devices received writes in order. That is why zoned HDDs had to use mq-deadline. Zone write plugging in the block core (6.10, Damien Le Moal) replaced it, and mq-deadline no longer contains any zoned code.

### BFQ (Budget Fair Queueing)

BFQ (4.12, Paolo Valente and Arianna Avanzini, descended from CFQ) is a proportional-share scheduler aimed at responsiveness on slow devices. Every process (more precisely, every `io_context`, tracked through the `io_cq` that BFQ embeds as `bfq_io_cq`) gets a `struct bfq_queue`. Instead of time slices, a queue that is chosen for service gets **exclusive access to the device for a budget measured in sectors**. It keeps the device until the budget runs out, the queue empties, or a budget timeout (`timeout_sync`) fires. The timeout stops a random-I/O process from holding the device for a long time while moving few sectors. Budgets are fed back per queue (`max_budget` is auto-tuned by default), so a queue that used its whole budget gets a larger one next time.

The choice of which queue is served next is **B-WF2Q+**, a weighted fair-queueing variant. Each `bfq_entity` (embedded in queues and groups) has a virtual start and finish time. Service trees (`bfq_service_tree`, augmented rb-trees) select the eligible entity with the smallest finish time in O(log N). The result is that over any interval each queue receives service in proportion to its `weight`, with a tight bound on how far it can fall behind an ideal fair schedule. Entities nest, so `bfq_group`s (with `CONFIG_BFQ_GROUP_IOSCHED`) apply the same algorithm hierarchically to cgroups via `io.bfq.weight` (1–1000, default 100). This is the proportional *weight* controller for cgroup v2 `io`. The other `io` controllers, throttling limits and io.cost/io.latency, work separately in the rq-qos layer.

The expensive part, and the reason BFQ exists, is **device idling**. When a synchronous queue empties, BFQ can leave the device idle for `slice_idle` (8 ms by default) and wait for that process's next request instead of switching to another queue. On an HDD this preserves sequential locality. On any device it is what makes fairness guarantees hold: without idling, a process that issues reads one at a time would lose its turn after every request. Idling wastes throughput with random or parallel workloads, so BFQ has a large set of heuristics for deciding when *not* to idle. **Injection** (reworked in 5.2) dispatches other queues' I/O into an idling window when that won't hurt the waiting queue's service time. **Early queue merging** (EQM) detects processes whose I/O interleaves into one sequential stream and merges their `bfq_queue`s.

On top of fairness, **low_latency** mode (on by default) applies *weight raising*. Queues that look **interactive** (a newly started process doing short bursts of I/O, such as an application loading) or **soft real-time** (periodic small I/O, such as media playback) temporarily get their weight multiplied. That is how BFQ keeps application start-up times low while a large copy runs in the background. The cost is CPU: about 1.9 µs per request originally, about 0.6 µs after the 2019 optimisations (mq-deadline is about 0.2 µs). Sustained throughput tops out around 300–400 KIOPS per device, which is fine for HDDs, SD cards and SATA SSDs but a bottleneck for NVMe. `strict_guarantees` forces a single outstanding request for predictable fairness at a large throughput cost.

### Kyber

Kyber (4.12, Omar Sandoval) is built for fast multi-queue SSDs. It is under 1,000 lines and does **no reordering at all**. Its insight is that on NVMe, read latency under load is caused by *queueing inside the device*, not by bad ordering. So Kyber limits how much work is in flight. Requests are sorted into four **scheduling domains**: `KYBER_READ`, `KYBER_WRITE`, `KYBER_DISCARD` and `KYBER_OTHER`. Each domain has an `sbitmap_queue` of *tokens* whose maximum depths are 256/128/64/16. A request needs a domain token (in addition to a driver tag) before it can be dispatched. Requests are inserted into per-CPU, per-domain lists (`kyber_ctx_queue`), and `kyber_dispatch_request()` round-robins across domains, sending up to a batch of 16 reads, 8 writes, 1 discard or 1 other before moving on.

The control loop runs from completions. `kyber_completed_request()` records each request's latency into per-CPU histograms with 8 buckets, each ¼ of the domain's target latency wide, so 4 buckets are "good" and 4 are "bad". Targets are `read_lat_nsec` 2 ms, `write_lat_nsec` 10 ms and discard 5 s. `kyber_timer_fn()` runs after 500 samples or one second. If any domain's p90 is over target, the device is congested. The domains that are missing their targets then have their token depth scaled linearly by p99/target (`depth = orig * (p99_bucket + 1) >> 2`). This shrinks the queues of whichever domain is hurting others, typically writes, until reads meet their target again. As with mq-deadline, `kyber_limit_depth()` reserves 25% of tags for synchronous I/O. Kyber never became a default anywhere. For most NVMe workloads `none` plus device-internal scheduling was good enough, and Kyber has had little development since.

### none

`none` means `q->elevator == NULL`: no insert or dispatch hooks, no scheduler tags, and blk-mq can issue directly from the submitter's context. It remains the right choice whenever the device reorders internally and its per-request CPU budget is only a few microseconds.

## Key Data Structures

**`struct elevator_type`** (`block/elevator.h`) — a registered scheduler (`elv_register()`).
- `ops` — `struct elevator_mq_ops` hook table
- `elevator_name`, `elevator_alias` — the sysfs name ("mq-deadline", alias "deadline")
- `elevator_attrs` — tunables under `queue/iosched/`
- `icq_size`, `icq_align`, `icq_cache` — per-io_context private data (BFQ)

**`struct elevator_queue`** — one attached scheduler instance per `request_queue`.
- `type`, `elevator_data` (e.g. `struct deadline_data *`), `et` (`struct elevator_tags`), `hash` (back-merge table), `flags`

**`struct deadline_data`** (`block/mq-deadline.c`)
- `per_prio[DD_PRIO_COUNT]` — `dd_per_prio` { `sort_list[2]` rb-trees, `fifo_list[2]`, `latest_pos[2]`, `stats` }
- `last_dir`, `batching`, `starved` — batch state
- `fifo_expire[2]`, `fifo_batch`, `writes_starved`, `front_merges`, `prio_aging_expire`, `async_depth`

**`struct bfq_queue` / `struct bfq_entity`** (`block/bfq-iosched.h`)
- `entity.weight`, `entity.start`, `entity.finish`, `entity.budget` — B-WF2Q+ state
- `wr_coeff`, `wr_cur_max_time` — weight-raising multiplier and duration
- `new_bfqq` — early-merge target; `bic` — owning `bfq_io_cq`

**`struct kyber_queue_data`** (`block/kyber-iosched.c`)
- `domain_tokens[KYBER_NUM_DOMAINS]` — `sbitmap_queue` token pools
- `latency_targets[]`, `cpu_latency` (per-CPU histograms), `timer`

## Key Functions / Entry Points

**`blk_mq_sched_bio_merge()`** (`block/blk-mq-sched.c`) — submit-time merge attempt; calls `ops.bio_merge`.
**`blk_mq_sched_dispatch_requests()`** (`block/blk-mq-sched.c`) — called from `blk_mq_run_hw_queue()`; drains `hctx->dispatch`, then loops `ops.dispatch_request` while the driver accepts.
**`elv_merge()` / `elv_rqhash_find()`** (`block/elevator.c`) — generic merge lookup.
**`elevator_set_default()`** — picks mq-deadline or none at queue registration.
**`elevator_change()` → `elevator_switch()`** — sysfs-driven switch: freeze, quiesce, exit old, `blk_mq_init_sched()` new.
**`dd_insert_request()` / `__dd_dispatch_request()`** — mq-deadline core.
**`bfq_insert_request()` / `bfq_dispatch_request()` / `bfq_select_queue()` / `bfq_bfqq_expire()`** — BFQ service loop.
**`kyber_completed_request()` / `kyber_timer_fn()`** — Kyber feedback loop.

## Important Flags & Config Options

- `CONFIG_MQ_IOSCHED_DEADLINE`, `CONFIG_MQ_IOSCHED_KYBER`, `CONFIG_IOSCHED_BFQ`, `CONFIG_BFQ_GROUP_IOSCHED`, `CONFIG_BFQ_CGROUP_DEBUG` (costs about 25% of peak IOPS).
- `/sys/block/<dev>/queue/scheduler` — select, e.g. `echo bfq > …`; the current one is shown in `[brackets]`.
- `/sys/block/<dev>/queue/nr_requests` — scheduler tag depth.
- `/sys/block/<dev>/queue/nomerges` — 0/1/2: all merges / only the simple one-hit cache / none.
- mq-deadline `iosched/`: `read_expire` (500), `write_expire` (5000), `fifo_batch` (16; 1 approximates FIFO for latency), `writes_starved` (2), `front_merges` (1), `async_depth`, `prio_aging_expire` (10000 ms).
- BFQ `iosched/`: `low_latency` (1), `slice_idle`/`slice_idle_us` (8 ms; 0 disables idling and most guarantees, often right for SSDs), `strict_guarantees` (0), `timeout_sync`, `max_budget` (0 = auto), `back_seek_max`, `back_seek_penalty` (2), `fifo_expire_sync` (125 ms), `fifo_expire_async` (250 ms); cgroup file `io.bfq.weight`.
- Kyber `iosched/`: `read_lat_nsec` (2 ms), `write_lat_nsec` (10 ms).
- `BLK_MQ_F_NO_SCHED` (driver forbids any elevator, e.g. admin queues), `BLK_MQ_F_NO_SCHED_BY_DEFAULT` (default to none even for single-queue).
- `ioprio_set()` / `ionice` classes (RT/BE/IDLE) are honoured by mq-deadline and BFQ, but not by Kyber or none.

## Interactions with Other Subsystems

- **↑ Userspace**: udev rules or admins pick schedulers per device; `ionice`/`ioprio_set()` and cgroup `io.bfq.weight` feed priorities and weights; `iosched/` tunables.
- **→ [[blk-mq]]**: the elevator is a set of hooks inside blk-mq's submit/insert/dispatch path; it depends on blk-mq's `sched_tags`, freeze/quiesce, and hctx run/restart.
- **← [[bio-layer]]**: bios arrive already split; the scheduler sees their `bi_opf` (sync/meta/prio flags) and `bi_ioprio`.
- **↔ [[cgroups]]**: BFQ implements hierarchical proportional weights for the `io` controller; the rq-qos policies (throttling, iocost, iolatency, wbt) run before the elevator and are independent of it.
- **← Filesystems / writeback**: `REQ_SYNC`/`REQ_META` flags and plugging decide which requests the scheduler treats as latency-critical; async writeback is what `limit_depth` holds back.
- **→ [[zoned-block-devices]]**: until 6.10, mq-deadline's zone write lock was the only thing guaranteeing in-order writes to sequential zones; zone write plugging now does this below the scheduler.

## Design Decisions & Tradeoffs

- **Scheduler optional, `none` default on multi-queue.** blk-mq (3.13) shipped with no schedulers at all. Per-CPU submission queues made a single global sorted queue impossible without bringing back the lock blk-mq was built to remove. Flash didn't need sorting anyway. Schedulers returned (4.11/4.12) as opt-in hooks, with the extra `sched_tags` to give them requests to choose from. The cost is that a scheduler reintroduces a per-device lock (mq-deadline's `dd->lock`, BFQ's `bfqd->lock`), so they don't scale to NVMe rates.
- **Kernel defaults vs. udev.** Jens Axboe's position was that policy belongs in userspace ("done with udev rules… distros would lead the way"). Linus Walleij, Paolo Valente and Mark Brown argued for BFQ as the in-kernel default for slow single-queue devices, because embedded systems often have no udev. The kernel kept mq-deadline/none, and the `elevator=` boot parameter was eventually made a no-op. Most desktop distributions now ship udev rules choosing BFQ for rotational and MMC devices.
- **Reorder vs. throttle.** mq-deadline and BFQ improve latency by *choosing* the next request. Kyber improves it by *limiting how much is outstanding* and leaving ordering to the device. Queue-depth control turned out to be the more general idea: it reappears in blk-wbt and iocost, which work without an elevator.
- **Fairness through idling.** BFQ's guarantees depend on sometimes leaving the device idle. That is the correct trade-off on an HDD, but on SSDs it costs throughput. Much of BFQ's complexity (injection, idling heuristics, weight raising) exists to win back throughput without giving up the guarantee.
- **Deadline is soft.** mq-deadline prefers batching throughput to hard latency bounds. Setting `fifo_batch=1` and small expiry values moves that trade-off towards latency.

## How It Has Evolved

- **2.5/2.6** — legacy elevators: noop, deadline, anticipatory (removed in 2.6.33), CFQ (default from 2.6.18).
- **3.13 (2014)** — blk-mq merged with no scheduling.
- **4.11 (2017)** — multi-queue scheduler framework (`blk-mq-sched.c`, `elevator_mq_ops`, sched tags) and mq-deadline.
- **4.12** — BFQ and Kyber merged.
- **5.0 (2019)** — legacy single-queue path deleted, along with CFQ, deadline and noop; `none`/mq-deadline/bfq/kyber remain. 5.2: BFQ injection and overhead improvements.
- **5.14–6.0** — mq-deadline gains I/O-priority classes (`dd_per_prio`), per-priority statistics and priority aging.
- **6.10** — zone write plugging removes mq-deadline's zone write locking; any scheduler can drive zoned devices.
- **2025 (6.1x)** — elevator switching reworked. Sched tags are pre-allocated into `struct elevator_tags` outside the freeze, `elv_change_ctx` is added, and new `elevator_lock`/`update_nr_hwq_lock` fix long-standing lockdep and deadlock reports around switching and `nr_hw_queues` updates. `async_depth` handling moves toward the `request_queue`.

## Further Reading

1. LWN — "blk-mq scheduling framework" (2016): https://lwn.net/Articles/708465/
2. LWN — "Two new block I/O schedulers for 4.12": https://lwn.net/Articles/720675/
3. LWN — "I/O scheduling for single-queue devices" (the defaults debate): https://lwn.net/Articles/767987/
4. LWN — "Improving the performance of the BFQ I/O scheduler": https://lwn.net/Articles/784267/
5. LWN — "Block layer introduction part 2: the request layer": https://lwn.net/Articles/738449/
6. kernel.org — BFQ documentation: https://www.kernel.org/doc/html/latest/block/bfq-iosched.html
7. kernel.org — deadline and Kyber tunables: https://www.kernel.org/doc/html/latest/block/deadline-iosched.html, https://www.kernel.org/doc/html/latest/block/kyber-iosched.html
8. kernel-internals.org — I/O schedulers: https://kernel-internals.org/block/io-schedulers/
9. Paolo Valente's BFQ papers and benchmark suite (algodev-github/S)

## LKML Highlights

*(lore.kernel.org search was unavailable during this research session (SSL verification failure); these threads are summarised from LWN coverage.)*

- **"blk-mq-sched: multiqueue I/O scheduler framework" (Jens Axboe, Dec 2016)** — introduced "shadow" scheduler requests (later sched tags) and ported deadline. It settled the argument about whether blk-mq could ever support scheduling: yes, as opt-in hooks with a separate tag space.
- **"blk-mq: Kyber multiqueue I/O scheduler" (Omar Sandoval, Apr 2017)** — argued that for fast SSDs latency control by limiting queue depth beats reordering. It reused sbitmap and the blk-stats latency API.
- **"block: use BFQ as default for single-queue devices" (Linus Walleij, Oct 2018)** — the kernel-default vs. udev policy debate. Axboe preferred udev. Damien Le Moal raised BFQ's lack of zoned-write ordering, and Bart Van Assche questioned its performance on fast SATA. It was never merged.
