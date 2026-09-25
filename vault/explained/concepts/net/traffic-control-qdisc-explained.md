---
title: "Traffic Control & qdisc — Explained"
category: explained
original: "[[traffic-control-qdisc]]"
subsystem: net
tags: [explained, networking, qdisc, bufferbloat, pacing]
converted: 2026-09-25
---

# Traffic control and qdiscs, explained

> Plain-language companion to [[traffic-control-qdisc|the technical note]]. Same facts, fewer identifiers.

## The problem

Many programs send through the same network card at once. Left alone, a bulk download can hog the link while an SSH session or video call waits behind it; a customer on a shared uplink can take more than their share; and big buffers let queues grow until every packet sits for hundreds of milliseconds (**bufferbloat**). Administrators need to rate-limit, prioritise and share fairly, without applications having to know about each other.

## The idea in one paragraph

Every outgoing device has a **queueing discipline (qdisc)**, like a **traffic officer at a motorway on-ramp**. Packets from many lanes want to merge onto the motorway (the card's transmit ring); the officer decides who goes next, stops any lane from hogging the ramp, and can hold back cars that arrive too fast. A simple FIFO lets everyone through in arrival order. HTB checks that each lane gets its guaranteed share and no more than its ceiling. FQ gives each flow its own little lane and meters them individually.

## Step by step

### Step 1: Where the qdisc sits
Each transmit queue has a qdisc. Sending a packet **enqueues** it into the qdisc; a run loop then **dequeues** the next packet the qdisc chooses and hands it to the driver. If the card's ring is full, the packet goes back into the qdisc to wait. The qdisc is per device, not per socket: every socket using an interface is under the same policy, and the qdisc sees only packets and their metadata, not what applications intend.

### Step 2: The default: three priority bands
With no configuration, **pfifo_fast** keeps three FIFO bands, choosing one from the packet's type-of-service field. It always serves the lowest-numbered non-empty band first: band 0 for interactive traffic, band 2 for bulk. Simple priority, no rate limits.

### Step 3: Rate limits in a hierarchy (HTB)
**HTB**, the usual choice for rate limiting (for example, on an ISP's access links), arranges **classes** in a tree: the root is the total bandwidth, the leaves are customers or traffic kinds. Each class has a guaranteed **rate** and a **ceiling**:
- each class has a **token bucket** filling at its rate; sending a packet spends tokens equal to its length
- with no tokens, the class waits, and a timer wakes it when tokens are back
- spare tokens from a parent can be lent to children, up to their ceilings

So leaves get their guaranteed share and can burst up to the ceiling when the parent has capacity. Very small rates run into timer granularity limits.

### Step 4: Fair queueing with pacing (FQ)
**FQ**, recommended for internet-facing servers, keeps a separate queue per flow (by socket or address hash) and serves flows in turn, so one bulk flow can't starve interactive ones. It also **paces**: if a socket has a pacing rate (TCP BBR sets one, or an application can set a maximum), FQ spaces its packets to that rate, holding early packets back with a high-resolution timer. This is the key point: pacing here, right where the card takes packets, is more accurate than pacing in TCP, whose segments might otherwise still queue behind other traffic. The cost is per-flow state for every socket.

### Step 5: Fighting bufferbloat (CoDel)
Dropping only when the queue is full lets queues, and latency, grow huge. **CoDel** watches how long each packet **waited** instead of how many are queued. If waiting times stay above a target (5 ms) for a sustained interval (100 ms), it drops or ECN-marks packets to tell senders to slow down, before the queue fills. Time spent waiting measures the actual latency cost directly, and costs one timestamp per packet. **fq_codel**, per-flow fair queueing combined with CoDel, is the default on most modern distributions.

### Step 6: Programmable classification
Since 4.1, eBPF programs can act as **classifiers** at this layer: they see the packet, can read and rewrite headers and consult maps, and return a class (for HTB) or a verdict: drop, redirect to another interface, or pass. For many software-defined networking setups this has replaced elaborate qdisc hierarchies.

### Step 7: Configuring it
The `tc` tool sends netlink messages to add, change or delete qdiscs, classes and filters. Changes apply to new packets immediately; packets already queued are dequeued by the old setup.

## The picture

```text
 sockets ─▶ enqueue ─▶ [ qdisc ] ─▶ dequeue ─▶ driver ─▶ transmit ring
 pfifo_fast: band0 ▶ band1 ▶ band2 (strict priority)
 HTB:        root 1 Gb ─┬─ A: rate 300 Mb, ceil 800 Mb  (token buckets, borrow from parent)
                        └─ B: rate 700 Mb, ceil 1 Gb
 FQ:         flow1 │ flow2 │ flow3 … round-robin, each paced to its rate
 CoDel:      packet waited > 5 ms for > 100 ms? → drop / ECN-mark
```

## Tradeoffs

- **What it gives you:** priority, hierarchical rate limits with bursting, per-flow fairness, accurate pacing and low queueing delay, all configured centrally per device.
- **What it costs / requires:** per-flow state (FQ), timers (HTB, FQ), and knowledge to configure hierarchies; the qdisc can't see application intent.
- **Where it bites:** the kernel's built-in default (pfifo_fast) is not what most distributions actually use, and many administrators never touch `tc` at all, which is why shipping good defaults (fq_codel) matters.

## How it got here

- **2.4 (2001):** traffic control (Alexey Kuznetsov) with HTB and other classic qdiscs.
- **2.6.14 (2005):** netem, for emulating delay, loss and reordering in tests.
- **3.3 (2012):** CoDel and fq_codel (Eric Dumazet, Dave Täht), and FQ with pacing, in response to bufferbloat. The debate over whether queue management belonged in the kernel ended with "ship sane defaults".
- **4.1 (2015):** eBPF classifiers (Daniel Borkmann), a separate classifier rather than an extension of the old one.
- **4.13 (2017):** TCP pacing integrated with FQ, which BBR relies on. **5.7 (2020):** BPF redirects at ingress and egress.

## Related

- Technical version: [[traffic-control-qdisc]]
- [[net-explained|Networking stack]], [[network-device-and-napi-explained|Devices and NAPI]], [[tcp-ip-stack-explained|TCP/IP (BBR pacing)]]
- [[bpf-explained|BPF]], [[cgroup-bpf-explained|cgroup BPF]]
