---
title: "Traffic Control & qdisc"
category: concept
tags: [networking, qdisc, traffic-control, htb, fq, packet-scheduling, tc-bpf]
subsystem: net
kernel_version: "2.4"
researched: 2026-04-14
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/networking/index.html
  - https://kernel-internals.org/net/tc-and-qdisc/
---

# Traffic Control & qdisc

## Purpose

Traffic control (tc) is the kernel's egress packet scheduling and shaping framework. It allows administrators to impose rate limits, enforce priority among traffic classes, provide per-flow fairness, and reduce bufferbloat — all without requiring applications to know about each other. The qdisc (queuing discipline) is the per-device algorithm that decides which packet to transmit next and when.

## Mental Model

A qdisc is a **traffic cop at a road on-ramp**. Packets from applications arrive from multiple lanes and want to merge onto the highway (the NIC TX ring). The traffic cop decides which car goes next, ensures no single lane monopolises the ramp, and can hold back fast-arriving cars to comply with rate limits. A simple FIFO qdisc lets everyone through in arrival order. HTB is a sophisticated cop who checks that each lane gets at least its guaranteed share and no more than its ceiling. FQ assigns each flow its own mini-lane and meters them individually.

## How It Works

**How the qdisc integrates with the transmit path.** Every `net_device` has a `txq->qdisc` pointer (one per TX queue). When `dev_queue_xmit()` is called with an skb, it calls `__dev_xmit_skb()`, which calls `qdisc->enqueue(skb, qdisc, &to_free)` to put the packet in the qdisc's internal structure. Then `qdisc_run()` calls `qdisc->dequeue()` to get the next packet and passes it to `dev_hard_start_xmit()` → `ndo_start_xmit()`. If the NIC's TX ring is full (`NETDEV_TX_BUSY`), the packet is re-queued into the qdisc.

**pfifo_fast: the default.** The simplest real qdisc (assigned by default when no tc rules exist) provides three FIFO bands indexed by the IP TOS/DSCP field. A packet's TOS byte is mapped to a band (0–2) via a priority map. `dequeue()` always serves the lowest-numbered non-empty band first. Band 0 is for interactive/low-latency traffic; band 2 for bulk data. This provides simple priority without rate limiting.

**HTB (Hierarchical Token Bucket): rate limiting with hierarchy.** HTB is the standard choice for rate limiting on ISP access links. Classes form a tree: the root class represents total bandwidth; leaf classes represent individual customers or traffic categories. Each class has a `rate` (guaranteed bandwidth, token bucket fills at this speed) and `ceil` (maximum bandwidth, including borrowed tokens from parent).

Token bucket mechanics: each class maintains a `tokens` counter that fills at `rate` bytes/second. When a packet is dequeued, it costs `len` tokens. If the bucket is empty, the class cannot dequeue and HTB schedules a timer (`sch_watchdog`) to wake up when tokens replenish. If a class has excess tokens, it can lend them to children up to `ceil`. This hierarchy ensures leaf classes get their guaranteed share and can burst up to the ceiling when parent capacity is available.

**fq (Fair Queue): per-flow pacing.** The recommended default for internet-facing servers (set via `/proc/sys/net/core/default_qdisc`). fq maintains a separate FIFO per flow (keyed by socket or 5-tuple hash) using a red-black tree of `fq_flow` structs. Round-robin across flows provides isolation: a single bulk flow cannot starve all interactive flows. fq also implements **pacing**: if a socket has a pace rate set (`sk->sk_pacing_rate`, set by TCP BBR or `SO_MAX_PACING_RATE`), fq delays each packet so that the inter-packet gap matches the pace rate, using an `hrtimer`-based watchdog to hold back early packets. This is more accurate than TCP timer-based pacing because it acts at the dequeue point where the NIC is actually consuming packets.

**CoDel and fq_codel: active queue management.** CoDel (Controlled Delay) addresses bufferbloat: instead of dropping packets when the queue is full (tail-drop), it measures how long packets spend in the queue. If a packet's sojourn time exceeds a threshold (`TARGET = 5 ms`) for a sustained interval (`INTERVAL = 100 ms`), CoDel drops (or ECN-marks) packets, signalling congestion to senders before the queue is full. `fq_codel` combines per-flow fair queuing with CoDel's sojourn-time feedback, and is the default qdisc on most modern Linux distributions.

**tc-bpf: programmable classification.** Since Linux 4.1, eBPF programs can be attached as classifiers (`cls_bpf`) at the tc layer. A BPF program receives the skb, can read and modify packet headers, perform map lookups, and return a class ID for HTB or a direct verdict. This replaced complex qdisc hierarchies for many SDN use cases. The `TC_ACT_SHOT` verdict drops the packet; `TC_ACT_REDIRECT` forwards it to another interface; `TC_ACT_OK` lets it through with a modified class ID.

**The `tc` command flow.** Userspace `tc` commands compile down to `RTM_NEWQDISC` / `RTM_NEWTCLASS` / `RTM_NEWTFILTER` netlink messages, handled by `tc_modify_qdisc()`, `tc_ctl_tclass()`, and `tc_ctl_tfilter()` in the kernel. Changes take effect immediately for new packets; in-flight packets see the old qdisc until they're dequeued.

## Key Data Structures

**`struct Qdisc`** (`include/net/sch_generic.h`) — one per device TX queue; the running qdisc instance.
- `ops` — `struct Qdisc_ops *`: the algorithm implementation
- `q` — `struct sk_buff_head`: the packet queue (for simple single-queue qdiscs)
- `qstats` — `struct gnet_stats_queue`: drops, requeues, overlimits statistics
- `rate_est` — bandwidth estimator; updated on each dequeue
- `stab` — size accounting table: maps skb->len to "wire bytes" including L2 overhead
- `limit` — maximum queue length (in packets); tail-drop threshold

**`struct Qdisc_ops`** (`include/net/sch_generic.h`) — the qdisc algorithm vtable.
- `enqueue(skb, sch, to_free)` — add packet; return `NET_XMIT_SUCCESS` or `NET_XMIT_DROP`
- `dequeue(sch)` — return next packet to transmit, or NULL if nothing ready
- `peek(sch)` — non-destructive look at next packet (used by some parent qdiscs)
- `init(sch, opt, extack)` — called on `tc qdisc add`
- `destroy(sch)` — called on `tc qdisc del`
- `change(sch, opt, extack)` — called on `tc qdisc change`

**`struct fq_flow`** (`net/sched/sch_fq.c`) — one per flow in the fq qdisc.
- `head` / `tail` — per-flow packet queue
- `age` — last dequeue time; used to detect idle flows
- `socket` — owning socket (if known); used to read `sk_pacing_rate`

## Key Functions / Entry Points

**`qdisc_enqueue()`** (`include/net/sch_generic.h`) — wrapper around `sch->ops->enqueue()`; handles `to_free` list for over-limit drops.

**`qdisc_dequeue_skb()`** — wrapper around `sch->ops->dequeue()`.

**`dev_queue_xmit()`** (`net/core/dev.c`) — the transmit entry point; calls `__dev_xmit_skb()`.

**`qdisc_run()`** / **`__qdisc_run()`** (`net/sched/sch_generic.c`) — the dequeue + transmit loop; runs until the TX ring is full or the qdisc is empty.

**`tc_modify_qdisc()`** (`net/sched/sch_api.c`) — netlink handler for `tc qdisc add/change/del`.

**`sch_watchdog_schedule_ns()`** — schedules the qdisc's hrtimer for pacing (used by fq and htb).

## Important Flags & Config Options

- `/proc/sys/net/core/default_qdisc` — default qdisc for new devices (most distros: `fq_codel` or `fq`)
- `CONFIG_NET_SCHED` — traffic control infrastructure
- `CONFIG_NET_SCH_HTB` — HTB hierarchical token bucket
- `CONFIG_NET_SCH_FQ` — fair queue with pacing
- `CONFIG_NET_SCH_FQ_CODEL` — fair queue + CoDel active queue management
- `CONFIG_NET_SCH_NETEM` — network emulator (add delay, loss, reorder) for testing
- `tc qdisc add dev eth0 root fq_codel` — attach fq_codel to eth0
- `tc qdisc add dev eth0 root htb default 10` — attach HTB root, default class 10
- `SO_MAX_PACING_RATE` socket option — hint to fq about maximum pacing rate for this socket
- `sk->sk_pacing_status` — `SK_PACING_NONE` / `SK_PACING_NEEDED` / `SK_PACING_FQ`: whether pacing is active

## Interactions with Other Subsystems

- **↑ Userspace**: `tc` command uses RTNETLINK; `SO_MAX_PACING_RATE` sockopt influences per-socket pacing in fq
- **→ [[network-device-and-napi]]**: qdisc sits between `dev_queue_xmit()` and `ndo_start_xmit()`; `qdisc_run()` calls `dev_hard_start_xmit()` which calls the driver
- **→ [[bpf]]**: `cls_bpf` attaches eBPF classifiers; `BPF_PROG_TYPE_SCHED_CLS` and `BPF_PROG_TYPE_SCHED_ACT` are the BPF program types for tc
- **← [[tcp-ip-stack]]**: TCP BBR sets `sk->sk_pacing_rate`; fq reads it when dequeuing to meter packet release; TCP RACK relies on accurate departure timestamps recorded by fq

## Design Decisions & Tradeoffs

**Per-device qdisc vs. per-socket queueing** — The qdisc lives on the device, not the socket. This means all sockets sharing an interface are subject to the same qdisc policy, simplifying administration. The tradeoff is that the qdisc cannot directly observe socket-level application semantics — it sees only packets and their metadata.

**Token buckets at the class level** — HTB's token bucket per class elegantly handles bursty traffic: a bursty client can temporarily exceed its average rate by spending accumulated tokens, without permanently violating its ceiling. The downside is that timer-granularity limits accuracy: a very small `rate` (few bytes/sec) requires timer events that may be coarser than the ideal pacing interval.

**fq pacing accuracy** — Pacing at the qdisc level (just before `ndo_start_xmit()`) is more accurate than pacing in the TCP layer (which only controls when segments are added to the write queue, but those segments may still queue behind other traffic in the qdisc). The tradeoff is that fq must maintain per-flow state for all sockets, which uses memory.

**CoDel sojourn time vs. queue length** — Traditional tail-drop uses queue length as the signal; CoDel uses time in queue. Queue length is a poor signal: a shallow queue with high-latency packets is worse than a deep queue with fast-draining packets. Sojourn time directly measures latency impact. The measurement overhead is negligible (one timestamp per packet enqueue/dequeue).

## How It Has Evolved

| Version | Change |
|---------|--------|
| 2.4 (2001) | Traffic control infrastructure (Alexey Kuznetsov); HTB, CBQ, TBF qdiscs |
| 2.6.14 (2005) | `netem` merged for network emulation in testing |
| 3.3 (2012) | CoDel and fq_codel merged; addressed bufferbloat problem |
| 3.3 (2012) | fq (fair queue with pacing) merged |
| 4.1 (2015) | `cls_bpf` merged; eBPF classifiers at tc layer |
| 4.13 (2017) | TCP pacing integrated with fq; BBR relies on fq for accurate pacing |
| 5.7 (2020) | TC BPF can redirect at ingress (`clsact` qdisc) and egress |

## Further Reading

1. [Bufferbloat: Dark Buffers in the Internet (ACM Queue, 2011)](https://queue.acm.org/detail.cfm?id=2071195) — the original bufferbloat paper motivating CoDel
2. [CoDel and fq_codel (LWN, 2012)](https://lwn.net/Articles/496546/) — CoDel design explained
3. [tc man page](https://man7.org/linux/man-pages/man8/tc.8.html) — command reference
4. [LARTC (Linux Advanced Routing & Traffic Control)](https://lartc.org/howto/) — practical guide to tc and qdisc configuration

## LKML Highlights

- **CoDel merge (2012)**: Eric Dumazet and Dave Täht's CoDel implementation sparked discussion about whether active queue management belonged in the kernel or should be userspace-configurable. The consensus was that the kernel should ship sane defaults (fq_codel) because most administrators never configure tc at all.
- **cls_bpf (2015)**: Daniel Borkmann's patchset enabling eBPF as a tc classifier effectively made tc the BPF attach point for everything between L2 and L4. The design debate was whether to extend cls_u32 or create a new BPF-specific classifier — a separate classifier won for clarity.
