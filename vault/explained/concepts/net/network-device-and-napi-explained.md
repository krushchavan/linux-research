---
title: "Network Device & NAPI — Explained"
category: explained
original: "[[network-device-and-napi]]"
subsystem: net
tags: [explained, networking, napi, gro, interrupts]
converted: 2026-09-25
---

# Network devices and NAPI, explained

> Plain-language companion to [[network-device-and-napi|the technical note]]. Same facts, fewer identifiers.

## The problem

The kernel talks to every kind of network interface (Ethernet cards, Wi-Fi, virtual devices, tunnels), so it needs one common shape for all of them. And it has to receive packets efficiently.

The obvious approach, one hardware interrupt per received packet, collapses under load. At high packet rates the CPU spends all its time answering interrupts and never gets round to actually processing the packets, a failure called **receive livelock**. Yet at low rates, interrupts are exactly right: a lone packet should be handled immediately.

## The idea in one paragraph

Every interface is a **network device** with a common table of driver operations. For receiving, **NAPI** works like a **toll plaza with a busy light**. The first car rings the bell (an interrupt); the attendant switches the bell off and works through all waiting cars in a batch; only when the plaza is empty is the bell switched back on. Under light traffic, the bell works as usual (low latency); under heavy traffic, the attendant just keeps polling (high throughput).

## Step by step

### Step 1: Register the device
A driver allocates a network device, fills in its operations table (open, stop, transmit, set address, change MTU, report statistics, attach XDP programs) and registers it. Registration adds it to the device list of its network namespace, gives it an interface index, and creates its sysfs entry. From then on, bringing the link up calls the driver's open.

### Step 2: The first packet: interrupt, then switch off interrupts
The card writes an arriving packet into a pre-allocated ring buffer by DMA and raises an interrupt. The driver's interrupt handler does almost nothing:
1. acknowledges the interrupt
2. marks the queue's NAPI instance as scheduled and raises the network-receive soft interrupt
3. masks further receive interrupts on that queue
4. returns

### Step 3: Poll in a batch
This is the key step. In soft-interrupt context, the kernel calls each scheduled queue's **poll** function with a **budget** (64 packets by default, with an overall cap per round of 300 packets or 2 ms). The driver:
1. reads completed descriptors from the receive ring
2. builds an skb for each packet (often recycling pages through the page pool)
3. passes it up the stack, through GRO
4. refills the ring with fresh DMA-mapped pages

If the ring runs dry before the budget is used, the work is done: the driver marks NAPI complete and **re-enables the interrupt**. If it used the whole budget, there's probably more waiting, so NAPI keeps polling with interrupts still off.

### Step 4: GRO: merge before climbing the stack
**Generic receive offload** holds packets briefly per NAPI instance and merges consecutive TCP segments of the same flow into one large skb, so IP and TCP run once for many packets: 10 to 40 times fewer calls for bulk transfers. Merged packets are handed up when the batch ends or a packet arrives that can't be merged. The cost is a little extra latency for packets waiting to be merged, with a bound on how long they can be held.

### Step 5: Threaded NAPI
In soft-interrupt context, polling borrows time from whatever was running on that CPU, invisibly to the scheduler, which can cause jitter. Since 5.11, a device can opt into **threaded NAPI**: each queue gets its own kernel thread that sleeps until scheduled, then polls in ordinary process context. The scheduler can see it, pin it to CPUs and prioritise it. The price is a context switch per activation, negligible at high packet rates but measurable at low ones. It's opt-in per device, because a thread per queue is wasteful on cards with, say, 128 queues.

### Step 6: Transmitting
A program's send ends up at the device's transmit entry: the packet goes through the queueing discipline (traffic control), then to the driver's transmit function, which places it in the transmit ring and notifies the card. When the card reports completion, the driver frees the skb.

### Step 7: Spreading across CPUs
Modern cards have many receive and transmit queues. **RSS** hashes each flow to a queue in hardware, and each queue's interrupt goes to a different CPU. Without hardware RSS, **RPS** does the same hashing in software after NAPI and hands the packet to the target CPU's backlog. Busy polling lets a latency-sensitive socket spin calling the poll function itself instead of sleeping, trading CPU time for microseconds.

## The picture

```text
 quiet:  packet → interrupt → schedule poll → poll (2 packets, ring empty) → interrupts back on
 busy:   packet → interrupt → schedule poll → interrupts OFF
           poll(budget 64): 64 packets, ring not empty → poll again → … → ring empty → interrupts ON

 poll loop:  ring descriptor → skb → GRO (merge same flow) → IP/TCP → refill ring
 threaded:   same poll loop, but in a per-queue kernel thread the scheduler can see
```

## Tradeoffs

- **What it gives you:** no receive livelock, interrupt-level latency when quiet, batched throughput when busy, far fewer trips up the stack thanks to GRO, and scheduler control with threaded NAPI.
- **What it costs / requires:** every driver must implement polling (drivers that don't fall back to a generic path); the first packet of a burst waits for the soft interrupt.
- **Where it bites:** soft-interrupt polling steals time from unrelated processes, and GRO adds a little latency. The budget, backlog and interrupt-coalescing settings trade latency against CPU use, and wrong values show up as drops or jitter.

## How it got here

- **2.4.20 (2002):** NAPI, after RFCs describing receive livelock and proposing interrupt-then-poll (Jamal Hadi Salim, Jeff Garzik, Alexey Kuznetsov and others).
- **2.6.29 (2009):** GRO, a software counterpart to hardware receive offload.
- **3.11 (2013):** NAPI aware of multiple queues, one instance per receive queue.
- **5.1 (2019):** the page pool for fast buffer recycling.
- **5.11 (2021):** threaded NAPI. **6.0 (2022):** busy-poll improvements for io_uring networking.

## Related

- Technical version: [[network-device-and-napi]]
- [[net-explained|Networking stack]], [[sk-buff-explained|skb]], [[page-pool-explained|Page pool]], [[traffic-control-qdisc-explained|Traffic control]], [[xdp|XDP]]
- [[interrupt-handling-explained|Interrupt handling]], [[dma-mapping-api-explained|DMA mapping]], [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]]
