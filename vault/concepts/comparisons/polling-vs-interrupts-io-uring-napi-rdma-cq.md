---
title: "Polling vs Interrupts: io_uring SQPOLL/IOPOLL, NAPI Busy-Poll and RDMA CQ Polling"
category: concept
tags: [comparison, polling, interrupts, io_uring, napi, rdma]
subsystem: comparisons
kernel_version: "NAPI 2.6; busy-poll 3.11; SQPOLL/IOPOLL 5.1; preferred busy-poll 5.11; io_uring NAPI 6.9; hybrid IOPOLL + IRQ suspension 6.13; threaded busy-poll 2025"
researched: 2026-09-26
status: complete
explained: "[[polling-vs-interrupts-io-uring-napi-rdma-cq-explained]]"
sources:
  - https://lwn.net/Articles/997491/
  - https://lwn.net/Articles/1034942/
  - https://lwn.net/Articles/961189/
  - https://lwn.net/Articles/887237/
  - https://lwn.net/Articles/837010/
  - https://lwn.net/Articles/833840/
  - https://man7.org/linux/man-pages/man2/io_uring_setup.2.html
  - https://man.archlinux.org/man/extra/liburing/io_uring_register_napi.3.en
  - https://github.com/torvalds/linux/blob/master/io_uring/napi.c
  - https://github.com/torvalds/linux/blob/master/io_uring/rw.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/cq.c
  - https://spdk.io/doc/userspace.html
  - https://muratkarslioglu.com/blog/io-uring-spdk-kernel-bypass/
---

# Polling vs Interrupts: io_uring SQPOLL/IOPOLL, NAPI Busy-Poll and RDMA CQ Polling

> 📘 Plain-language version: [[polling-vs-interrupts-io-uring-napi-rdma-cq-explained]]

> Comparison note under `comparisons/`. Complements [[io-uring-vs-rdma]] and [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk]].

## Purpose

At microsecond timescales, **how you find out that work is done** dominates latency. An interrupt costs a few microseconds: IRQ entry, softirq, wakeup, scheduler, context switch and cache disruption. At millions of operations per second, interrupt storms also waste CPU. **Polling** (spinning on a completion location) removes that latency and overhead but burns a core whether or not work arrives. Linux has grown a family of mechanisms that sit at different points between the two, for **submission** (who notices new work) and **completion** (who notices finished work), across storage (blk-mq, NVMe), networking (NAPI) and RDMA (CQs). This note lines them up.

## Mental Model

Waiting for a delivery:
- **Interrupts**: you go about your day and the **doorbell** rings. That's efficient, but each ring costs you a trip to the door, and you might be in the shower (scheduling latency).
- **Pure polling**: you **stand at the window** watching the street. You see the courier the instant they arrive, but you get nothing else done.
- **Hybrid**: you know deliveries take about 10 minutes, so you **nap for 5, then watch**. Or you watch while deliveries keep coming, and switch the doorbell back on when the street goes quiet (IRQ suspension). Or you hire someone to watch for you on another core (SQPOLL, threaded NAPI busy-poll).

Every mechanism below is one of these strategies, applied to a specific queue.

## How It Works

### 1. Storage completions: interrupts → IOPOLL → hybrid

- **Default**: NVMe completion → MSI-X interrupt → `nvme_irq` → blk-mq completion (possibly IPI to the submitting CPU) → wake the task. Adds a few µs per I/O.
- **Polled queues**: `nvme.poll_queues=N` creates NVMe queues **without interrupts**. blk-mq maps `HCTX_TYPE_POLL` to them, and I/O flagged `REQ_POLLED` (`RWF_HIPRI`, io_uring IOPOLL) goes there ([[blk-mq]]).
- **io_uring `IORING_SETUP_IOPOLL`**: the ring doesn't wait for interrupts. `io_do_iopoll()` calls `->iopoll()` (block `bio_poll()`, or `uring_cmd_iopoll` for NVMe passthrough) from `io_uring_enter(GETEVENTS)` or from SQPOLL. **Interrupt-free completion** for O_DIRECT files and passthrough ([[uring-cmd-passthrough]]).
- **`IORING_SETUP_HYBRID_IOPOLL` (6.13)**: before spinning, sleep for about half the *observed* completion time (`io_hybrid_iopoll_delay()`, tracking the minimum `hybrid_poll_time`), then poll. It keeps most of IOPOLL's latency benefit at a fraction of the CPU. This is the block-layer equivalent of the old `io_poll_delay` sysfs hybrid mode.
- **SPDK**: always polls from dedicated userspace threads, with no interrupts at all. HotStorage '25 ("SPDK+") measured ~85% of polling cycles wasted at moderate load, the canonical cost of always-poll.

### 2. io_uring submission: syscall vs SQPOLL

- **Default**: userspace batches SQEs and calls `io_uring_enter()`, one syscall per batch.
- **`IORING_SETUP_SQPOLL`**: a kernel thread (`io_sq_thread()`) polls the SQ tail, so userspace submits with a memory store. After `sq_thread_idle` ms without work it sleeps and sets `IORING_SQ_NEED_WAKEUP`. Userspace checks the flag and calls `io_uring_enter(IORING_ENTER_SQ_WAKEUP)` only then ([[sqpoll]]). **SQPOLL + IOPOLL** is the fully syscall-free, interrupt-free io_uring configuration used for top NVMe benchmarks (io_uring passthrough measured within 9–16% of SPDK, FAST '24).
- SQPOLL can also drive **NAPI busy-polling** (`io_napi_sqpoll_busy_poll()`), so one kernel thread polls both the submission ring and the NIC.

### 3. Network receive: NAPI and busy-poll

- **NAPI baseline**: the first packet's interrupt schedules the NAPI poll (softirq), which disables the device IRQ, polls up to a budget, and re-enables the IRQ when empty. It's interrupt-driven at low load and polled at high load ([[network-device-and-napi]]).
- **Interrupt deferral**: `napi_defer_hard_irqs` + `gro_flush_timeout` (per device since 5.10, per NAPI via netlink `napi-set` since 6.12) keep IRQs masked for N empty polls or a timeout, which reduces interrupts under steady traffic.
- **Socket busy-poll (3.11)**: `net.core.busy_read`/`busy_poll` sysctls or `SO_BUSY_POLL`. A thread blocking in `recv`/`poll`/`epoll_wait` first spins calling the socket's NAPI poll (`napi_busy_loop()`, found via the skb's `napi_id`) for up to N µs before sleeping.
- **Preferred busy-poll (5.11, Björn Töpel)**: `SO_PREFER_BUSY_POLL` + `SO_BUSY_POLL_BUDGET`. While the application busy-polls, softirq NAPI processing is kept out of the way (IRQs deferred), so RX processing happens *in the application's context* on its core. That is critical for AF_XDP ([[af-xdp]]).
- **epoll busy-poll parameters (6.9)**: `EPIOCSPARAMS` sets `busy_poll_usecs`, `busy_poll_budget` and `prefer_busy_poll` per epoll instance.
- **IRQ suspension (6.13, Martin Karsten & Joe Damato)**: a per-NAPI `irq_suspend_timeout`. With `prefer_busy_poll`, as long as `epoll_wait` keeps finding events, device IRQs stay **suspended** and the application drives NAPI. When `epoll_wait` finds nothing, normal deferral (`defer_hard_irqs`/`gro_flush_timeout`) and interrupts resume, and the timeout is a safety net if the app stalls. memcached at 200K QPS: ~126 µs p95 at 30% CPU, beating both pure deferral and full busy-poll on the latency/CPU tradeoff.
- **Threaded NAPI (5.12)** runs NAPI polls in per-NAPI kthreads instead of softirq, which makes them schedulable and pinnable. **Threaded busy-poll** (Samiullah Khawaja, Google, 2025; netlink `napi-threaded: busy-poll`) makes that kthread **poll continuously** on a dedicated core, the network analogue of SQPOLL. AF_XDP `xdp_rr` P99 dropped from ~21 µs (interrupts) to ~13 µs, about 1–1.5 µs better than userspace busy-polling on a separate core.
- **io_uring NAPI busy-poll (6.9, Stefan Roesch / Jens Axboe)**: `io_uring_register_napi()` (`IORING_REGISTER_NAPI`) sets `busy_poll_to` and `prefer_busy_poll` per ring. The ring tracks NAPI ids of its sockets (**dynamic** tracking, with stale-entry expiry) or an explicit list (**static** tracking, 6.13). When `io_uring_enter()` waits for CQEs, `io_napi_blocking_busy_loop()` spins on those NAPI instances (`napi_busy_loop_rcu()`) until events arrive or the timeout expires. Ping-pong latency went from ~37 µs to ~29.8 µs in the posting.

### 4. RDMA completions: arm-and-sleep vs spin

- **Userspace busy-poll**: `ibv_poll_cq()` reads CQE ownership bits in mapped memory, with **no syscall and no kernel**. Latency-critical RDMA apps (MPI, key-value stores, NCCL proxies) spin on CQs, like DPDK and SPDK ([[queue-pairs-and-completion-queues]]).
- **Event-driven**: `ibv_req_notify_cq()` (a doorbell write) arms the CQ. The next CQE raises an MSI-X interrupt → driver → completion channel fd → `read()`/`epoll` wakes the app. The race is solved by `IB_CQ_REPORT_MISSED_EVENTS` and the poll-arm-poll pattern.
- **Kernel ULPs** (`ib_alloc_cq(poll_ctx)`): `IB_POLL_SOFTIRQ` uses the **irq_poll** library (a NAPI-like budgeted poll with the IRQ masked, budget 256), `IB_POLL_WORKQUEUE` polls in process context, and `IB_POLL_DIRECT` has no interrupts at all (the caller polls). **RDMA DIM** adapts CQ interrupt moderation to traffic, the RDMA sibling of NIC interrupt coalescing. NVMe-oF RDMA exposes **poll queues** so io_uring IOPOLL over a remote namespace polls the RDMA CQ directly (`nvme_rdma_poll()` → `ib_process_cq_direct()`), giving an interrupt-free path end to end on the host ([[nvme-over-fabrics-rdma-and-tcp]]).

### 5. Side-by-side

| Layer | Pure interrupt | Deferred / moderated | Hybrid (sleep-then-poll / suspend) | App-driven poll | Dedicated poller thread |
|---|---|---|---|---|---|
| NVMe / block | IRQ per CQE (coalescing via NVMe features) | — | `HYBRID_IOPOLL` (6.13) | IOPOLL from `io_uring_enter` | SQPOLL+IOPOLL; SPDK threads |
| io_uring submit | `io_uring_enter` per batch | — | SQPOLL idle → NEED_WAKEUP | — | SQPOLL kthread |
| NIC RX (NAPI) | IRQ → softirq NAPI | `defer_hard_irqs`, `gro_flush_timeout`, DIM | IRQ suspension (6.13) | `SO_BUSY_POLL`, epoll busy-poll, `SO_PREFER_BUSY_POLL`, io_uring NAPI | threaded NAPI busy-poll (2025); DPDK lcores |
| AF_XDP | wakeup via `poll()` | `need_wakeup` | preferred busy-poll + deferral | busy-poll syscalls | threaded NAPI busy-poll |
| RDMA CQ | armed CQ + completion channel | RDMA DIM | poll-then-arm loops | `ibv_poll_cq` spin | app proxy threads (NCCL) |

### 6. Choosing

- **Low, bursty load**: interrupts (with moderation). Polling wastes cores.
- **Latency-critical at moderate load**: hybrid, i.e. `HYBRID_IOPOLL` for storage, IRQ suspension or busy-poll with a short timeout for networking, poll-then-arm for RDMA.
- **Saturated, dedicated cores**: continuous polling (SQPOLL+IOPOLL, threaded NAPI busy-poll, SPDK/DPDK, spinning RDMA CQs).
- **Co-location matters**: preferred busy-poll and IRQ suspension put RX work on the application's core (cache locality, no cross-core handoff). Dedicated pollers (SQPOLL, threaded busy-poll) move it to another core, which gives better tail latency when you can spare the core.

## Key Data Structures

- `struct io_ring_ctx`: `napi_list`, `napi_busy_poll_dt`, `napi_prefer_busy_poll`, `napi_track_mode`, `hybrid_poll_time`
- `struct io_sq_data` (SQPOLL thread, `sq_thread_idle`)
- `struct napi_struct`: `defer_hard_irqs`, `gro_flush_timeout`, `irq_suspend_timeout`, threaded state
- `struct blk_mq_hw_ctx` with `HCTX_TYPE_POLL`
- `struct ib_cq`: `poll_ctx`, `iop` (irq_poll), `dim`, `comp_vector`

## Key Functions / Entry Points

- io_uring: `io_do_iopoll()`, `io_uring_hybrid_poll()`, `io_sq_thread()`, `io_napi_blocking_busy_loop()`, `io_napi_sqpoll_busy_poll()`, `io_register_napi()`
- net: `napi_busy_loop()` / `napi_busy_loop_rcu()`, `napi_schedule()`, `napi_complete_done()` (honours `defer_hard_irqs`), epoll `ep_busy_loop()`
- block: `bio_poll()`, `blk_mq_poll()`, NVMe `nvme_poll()`
- RDMA: `ib_poll_cq()`, `ib_req_notify_cq()`, `ib_process_cq_direct()`, `ib_poll_handler()` (irq_poll)

## Important Flags & Config Options

- io_uring: `IORING_SETUP_SQPOLL` (+`sq_thread_idle`, `sq_thread_cpu`), `IORING_SETUP_IOPOLL`, `IORING_SETUP_HYBRID_IOPOLL`, `IORING_REGISTER_NAPI` (`busy_poll_to`, `prefer_busy_poll`, tracking mode)
- block/NVMe: `nvme.poll_queues`, `RWF_HIPRI`, `/sys/block/<dev>/queue/io_poll`
- net: `net.core.busy_read`, `net.core.busy_poll`, `SO_BUSY_POLL`, `SO_PREFER_BUSY_POLL`, `SO_BUSY_POLL_BUDGET`, `EPIOCSPARAMS`, netlink `napi-set` (`defer-hard-irqs`, `gro-flush-timeout`, `irq-suspend-timeout`, `threaded`: disabled/enabled/busy-poll), `/sys/class/net/<dev>/threaded`
- RDMA: `ibv_req_notify_cq`, completion channels, `ib_alloc_cq` poll contexts, `rdma dev set <dev> adaptive-moderation on`

## Interactions with Other Subsystems

- **Scheduler**: pollers compete for CPU. `isolcpus`/`nohz_full` and pinning matter for SQPOLL, threaded NAPI and SPDK/DPDK cores ([[preemption-model]])
- **IRQ subsystem**: MSI-X affinity decides where interrupt-driven completions land ([[interrupt-handling]])
- **netdev netlink**: per-NAPI configuration via `napi-set` ([[netdev-netlink-family]])
- **blk-mq / NVMe**: poll queues ([[blk-mq]]); **RDMA core**: CQ API ([[queue-pairs-and-completion-queues]])
- **Power management**: polling defeats C-states, which is the argument for hybrid modes

## Design Decisions & Tradeoffs

- **Adaptive over binary.** Early Linux offered "interrupts" or "spin". The decade-long trend (NAPI, busy-poll, preferred busy-poll, IRQ suspension, hybrid IOPOLL, DIM) is towards mechanisms that *switch automatically* based on observed load or completion time, reclaiming most of polling's latency without dedicating cores.
- **Who polls.** App-context polling (busy-poll, IOPOLL from `io_uring_enter`) keeps work on the consuming core but steals app cycles. Kernel poller threads (SQPOLL, threaded NAPI) offload it but cost a core and cross-core cache traffic. Measurements (threaded busy-poll vs userspace busy-poll) show dedicated in-kernel pollers can win on P99.
- **Kernel vs userspace polling.** RDMA, DPDK and SPDK poll in userspace because the data path already bypasses the kernel. io_uring and NAPI keep the kernel in the path but let it poll on the app's behalf, preserving kernel semantics.
- **Safety nets.** Every hybrid mechanism has a timeout (`sq_thread_idle`, `irq_suspend_timeout`, busy-poll µs, hybrid sleep bound) so a stalled application doesn't leave a device without interrupts or a core spinning forever.

## How It Has Evolved

- **2.6 (2003)** — NAPI: interrupt-then-poll for NICs
- **3.11 (2013)** — socket busy-poll (`SO_BUSY_POLL`, Eliezer Tamir)
- **4.x** — blk-mq polling, NVMe poll queues (5.0), classic hybrid block polling (later removed)
- **5.1 (2019)** — io_uring with SQPOLL and IOPOLL
- **5.4–5.10** — RDMA DIM; per-device `napi_defer_hard_irqs`
- **5.11 (2021)** — preferred busy-poll (Björn Töpel); **5.12** — threaded NAPI (Wei Wang et al.)
- **6.9 (2024)** — io_uring NAPI busy-poll (Stefan Roesch, Jens Axboe); epoll `EPIOCSPARAMS`
- **6.12–6.13 (2024)** — per-NAPI config via netlink; IRQ suspension (Karsten, Damato); io_uring hybrid IOPOLL; io_uring static NAPI tracking
- **2025** — threaded NAPI busy-poll (Samiullah Khawaja); per-NAPI `threaded` in `napi-set`
- **2026** — continued power-efficiency work (SPDK+ research; hybrid modes in more drivers)

## Further Reading

- LWN — [Suspend IRQs during application busy periods](https://lwn.net/Articles/997491/) (2024)
- LWN — [Add support to do threaded napi busy poll](https://lwn.net/Articles/1034942/) (2025)
- LWN — [io_uring: add napi busy polling support](https://lwn.net/Articles/961189/) (2024); [io_uring: Add support for napi_busy_poll](https://lwn.net/Articles/887237/) (2022)
- LWN — [Introduce preferred busy-polling](https://lwn.net/Articles/837010/) (2020); [NAPI polling in kernel threads](https://lwn.net/Articles/833840/) (2020)
- man — [io_uring_setup(2)](https://man7.org/linux/man-pages/man2/io_uring_setup.2.html) (SQPOLL, IOPOLL, HYBRID_IOPOLL); [io_uring_register_napi(3)](https://man.archlinux.org/man/extra/liburing/io_uring_register_napi.3.en)
- SPDK — [Why polling](https://spdk.io/doc/userspace.html)
- Related: [[sqpoll]], [[network-device-and-napi]], [[af-xdp]], [[queue-pairs-and-completion-queues]], [[blk-mq]], [[io-uring-vs-rdma]]

## LKML Highlights

- **`<20241108023912.98416-1-jdamato@fastly.com>`** — "Suspend IRQs during application busy periods" (Martin Karsten, Joe Damato). A per-NAPI `irq_suspend_timeout` with epoll `prefer_busy_poll`: IRQs stay off while the app keeps finding events, and normal deferral resumes when idle. It beat both deferral and full busy-poll on memcached latency per CPU.
- **`<20250824215418.257588-1-skhawaja@google.com>`** — "Add support to do threaded napi busy poll" (Samiullah Khawaja). Continuous polling in per-NAPI kthreads configured via netlink. AF_XDP P99 improved about 1–1.5 µs over userspace busy-polling on a separate core.
- **`<20240206163422.646218-1-axboe@kernel.dk>`** — io_uring per-ring NAPI busy polling (Jens Axboe, building on Stefan Roesch's v15). Socket NAPI-id tracking and SQPOLL integration, with ping-pong average latency ~37 → ~29.8 µs.
