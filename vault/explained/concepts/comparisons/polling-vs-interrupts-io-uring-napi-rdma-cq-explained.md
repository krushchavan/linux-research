---
title: "Polling vs Interrupts: io_uring SQPOLL/IOPOLL, NAPI Busy-Poll and RDMA CQ Polling — Explained"
category: explained
original: "[[polling-vs-interrupts-io-uring-napi-rdma-cq]]"
subsystem: comparisons
tags: [explained, comparison, polling, interrupts, napi, io_uring]
converted: 2026-09-26
---

# Polling vs interrupts, explained

> Plain-language companion to [[polling-vs-interrupts-io-uring-napi-rdma-cq|the technical note]]. Same facts, fewer identifiers.

## The problem

At microsecond timescales, **how you find out that work is done** dominates latency. An interrupt costs a few microseconds: interrupt entry, deferred processing, a wakeup, the scheduler, a context switch and cache disruption. At millions of operations per second, interrupt storms also waste CPU. **Polling**, spinning on the place where a completion will appear, removes that latency and overhead but burns a core whether or not work arrives. Linux has grown a family of mechanisms at different points between the two. They cover **submission** (who notices new work) and **completion** (who notices finished work), in storage, networking and RDMA.

## The idea in one paragraph

Think about waiting for a delivery. **Interrupts** are the **doorbell**: you get on with your day and it rings, which is efficient, but every ring means a trip to the door, and you might be in the shower (scheduling delay). **Pure polling** is **standing at the window**: you see the courier the moment they arrive, but you get nothing else done. **Hybrid** strategies are the clever middle: you know deliveries take about ten minutes, so you **nap for five and then watch**; or you watch while deliveries keep coming and **switch the doorbell back on when the street goes quiet**; or you **hire someone to watch for you** from another room (another core). Every mechanism below is one of these strategies applied to a particular queue.

## Step by step

### Step 1: Storage completions, from interrupts to polling to hybrid
By default, an NVMe completion raises an interrupt, the block layer completes the request (maybe signalling the CPU that submitted it), and the task is woken, adding a few microseconds per I/O. An NVMe driver option creates **poll queues with no interrupts at all**, and I/O marked as polled is sent there ([[blk-mq-explained|blk-mq]]). An io_uring ring set up for **polled I/O** never waits for interrupts: when the application asks for completions (or the kernel polling thread runs), it spins on the device's queues. That gives interrupt-free completion for direct I/O and NVMe passthrough ([[uring-cmd-passthrough-explained|passthrough]]). Since 6.13, **hybrid polled I/O** first sleeps for about half the *observed* completion time and then polls, keeping most of the latency benefit for a fraction of the CPU. SPDK always polls from dedicated user-space threads; a 2025 study measured about 85% of those polling cycles wasted at moderate load, the textbook cost of always polling.

### Step 2: io_uring submission, system call or polling thread
Normally the application batches requests and makes one system call per batch. With **SQPOLL**, a kernel thread watches the submission ring, so submitting is a plain memory write. After an idle period it goes to sleep and raises a "needs wakeup" flag, and only then does the application make a system call to wake it ([[sqpoll-explained|SQPOLL]]). **SQPOLL plus polled I/O** is io_uring's fully system-call-free, interrupt-free setup, used for top NVMe benchmarks (passthrough measured within 9–16% of SPDK). The same thread can also busy-poll the network card, so one kernel thread watches both the ring and the card.

### Step 3: Network receive, NAPI and its descendants
This is the key step, because networking shows the whole evolution from binary choice to adaptive switching.
- **NAPI (2003):** the first packet's interrupt schedules a poll; the poll turns the interrupt off, drains packets up to a budget and turns it back on when the queue is empty. That's interrupt-driven at low load and polled at high load ([[network-device-and-napi-explained|NAPI]]).
- **Interrupt deferral:** keep interrupts masked for a number of empty polls or a timeout, so steady traffic generates fewer interrupts (per device since 5.10, per NAPI instance through netlink since 6.12).
- **Socket busy polling (3.11):** a thread about to block in receive, poll or epoll first spins on its socket's NAPI instance for up to some microseconds before sleeping.
- **Preferred busy polling (5.11):** while the application busy-polls, the kernel keeps its own deferred packet processing out of the way, so receive work happens *on the application's core*. This matters for AF_XDP ([[af-xdp-explained|AF_XDP]]). Since 6.9, epoll instances can carry their own busy-poll settings.
- **Interrupt suspension (6.13):** as long as epoll keeps finding events, card interrupts stay **suspended** and the application drives NAPI; when epoll finds nothing, normal deferral and interrupts resume, with a timeout as a safety net if the application stalls. With memcached at 200K queries per second, it reached about 126 µs 95th-percentile latency at 30% CPU, beating both pure deferral and full busy polling on latency per CPU.
- **Threaded NAPI (5.12)** runs NAPI polls in schedulable, pinnable kernel threads, and **threaded busy polling** (2025) makes that thread **poll continuously** on a dedicated core, the network analogue of SQPOLL. AF_XDP 99th-percentile latency dropped from about 21 µs with interrupts to about 13 µs, roughly 1–1.5 µs better than user-space busy polling on a separate core.
- **io_uring NAPI busy polling (6.9):** each ring tracks the NAPI instances of its sockets (automatically, with expiry of stale entries, or from an explicit list since 6.13), and while it waits for completions it spins on them until events arrive or a timeout expires. Ping-pong latency went from about 37 µs to about 29.8 µs.

### Step 4: RDMA completions, arm-and-sleep or spin
In user space, polling an RDMA completion queue means reading ownership bits in mapped memory, with **no system call and no kernel**, so latency-critical applications (MPI, key-value stores, NCCL proxy threads) spin on it, as DPDK and SPDK do ([[queue-pairs-and-completion-queues-explained|queue pairs and CQs]]). The event-driven alternative **arms** the queue with a doorbell write; the next completion raises an interrupt that wakes the application through a file descriptor. The race between checking and arming is handled by a "report missed events" option and a poll-arm-poll pattern. Kernel users choose a polling context when they create a queue: a NAPI-like budgeted poll with the interrupt masked, polling from a workqueue, or no interrupts at all (the caller polls). **Dynamic interrupt moderation** adapts the interrupt rate to traffic. NVMe-oF over RDMA offers poll queues, so io_uring polled I/O on a remote namespace polls the RDMA completion queue directly, giving an interrupt-free path end to end on the host ([[nvme-over-fabrics-rdma-and-tcp-explained|NVMe over Fabrics]]).

### Step 5: Choosing
- **Low, bursty load:** interrupts, with moderation. Polling wastes cores.
- **Latency-critical at moderate load:** hybrids: hybrid polled I/O for storage, interrupt suspension or short busy polling for networking, poll-then-arm for RDMA.
- **Saturated, dedicated cores:** continuous polling (SQPOLL with polled I/O, threaded NAPI busy polling, SPDK or DPDK, spinning on RDMA queues).
- **Where the work runs matters:** preferred busy polling and interrupt suspension keep receive work on the application's core (cache locality, no hand-off between cores). Dedicated pollers move it to another core, which gives better tail latency when you can spare that core.

## The picture

```text
                 interrupt        moderated          hybrid                app polls           dedicated poller
 NVMe/block      IRQ per I/O      (device coalesce)  hybrid polled I/O     polled I/O          SQPOLL+polled I/O, SPDK
 io_uring submit syscall/batch    —                  SQPOLL sleeps→wakeup  —                   SQPOLL thread
 NIC receive     IRQ → NAPI       deferral, DIM      IRQ suspension        socket/epoll/ring   threaded NAPI busy-poll, DPDK
                                                                           busy poll
 RDMA CQ         armed + channel  RDMA DIM           poll-then-arm         spin on CQ          app proxy threads
         ◀── cheaper on CPU ───────────────────────────────────────────────────── lower latency ──▶
```

## Tradeoffs

- **What it gives you:** the whole range, from interrupt efficiency at low load to microsecond latency under polling. The ten-year trend (NAPI, busy polling, preferred busy polling, interrupt suspension, hybrid polled I/O, dynamic moderation) is toward mechanisms that **switch automatically** based on observed load or completion time, recovering most of polling's latency without dedicating cores.
- **What it costs / requires:** polling defeats CPU idle states, which is the argument for hybrids. Pollers compete for CPU, so core isolation and pinning matter for SQPOLL, threaded NAPI and SPDK or DPDK cores ([[preemption-model-explained|preemption model]]). Interrupt affinity decides where interrupt-driven completions land ([[interrupt-handling-explained|interrupt handling]]), and per-NAPI settings live in netlink ([[netdev-netlink-family-explained|netdev netlink]]).
- **Where it bites:** *who* polls. Polling in the application's context keeps work on the consuming core but steals the application's cycles; kernel poller threads offload it at the cost of a core and cross-core cache traffic, and measurements show dedicated in-kernel pollers can win on tail latency. RDMA, DPDK and SPDK poll in user space because their data path already bypasses the kernel; io_uring and NAPI keep the kernel in the path but let it poll on the application's behalf. Every hybrid has a timeout so a stalled application can't leave a device with no interrupts or a core spinning forever.

## How it got here

- **2003 (2.6):** NAPI, interrupt-then-poll for network cards. **2013 (3.11):** socket busy polling.
- **4.x–5.0:** block-layer polling and NVMe poll queues (an older hybrid block-polling mode was later removed). **2019 (5.1):** io_uring with SQPOLL and polled I/O.
- **5.4–5.12:** RDMA dynamic interrupt moderation; per-device interrupt deferral; preferred busy polling (5.11); threaded NAPI (5.12).
- **2024 (6.9–6.13):** io_uring NAPI busy polling and epoll busy-poll settings; per-NAPI netlink configuration; interrupt suspension; hybrid polled I/O; explicit NAPI lists for io_uring.
- **2025–2026:** threaded NAPI busy polling; continued power-efficiency work, including research on SPDK and hybrid modes in more drivers.

## Related

- Technical version: [[polling-vs-interrupts-io-uring-napi-rdma-cq]]
- [[io-uring-vs-rdma-explained|io_uring vs RDMA]], [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk-explained|Kernel-bypass comparison]]
- [[sqpoll-explained|SQPOLL]], [[network-device-and-napi-explained|NAPI]], [[af-xdp-explained|AF_XDP]], [[queue-pairs-and-completion-queues-explained|Queue pairs and CQs]], [[blk-mq-explained|blk-mq]]
- [[interrupt-handling-explained|Interrupt handling]], [[netdev-netlink-family-explained|netdev netlink]], [[preemption-model-explained|Preemption model]]
