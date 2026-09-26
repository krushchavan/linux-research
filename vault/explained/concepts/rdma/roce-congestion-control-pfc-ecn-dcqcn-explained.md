---
title: "RoCE Congestion Control: PFC, ECN and DCQCN — Explained"
category: explained
original: "[[roce-congestion-control-pfc-ecn-dcqcn]]"
subsystem: rdma
tags: [explained, rdma, roce, congestion-control, pfc, ecn]
converted: 2026-09-26
---

# RoCE congestion control, explained

> Plain-language companion to [[roce-congestion-control-pfc-ecn-dcqcn|the technical note]]. Same facts, fewer identifiers.

## The problem

RoCE borrows InfiniBand's transport, which was built for a **lossless** network: InfiniBand switches use credits and never drop packets for congestion, so its reliable transport recovers from loss crudely, resending everything from the lost packet onward after a timeout. Ordinary Ethernet switches drop packets when buffers overflow, and even small loss rates collapse RoCE throughput. Making RoCE work takes two things together: a way to make RoCE's traffic class **lossless**, and a way to slow senders **before** that emergency brake is needed, because the brake has nasty side effects.

Almost all of this runs in card firmware and switches. The kernel's part is **configuration and observability**.

## The idea in one paragraph

Think of a **highway with on-ramp metering**. **PFC** (priority flow control) is a traffic officer at each interchange who holds up a hand, "stop, lane 3 only", when the road ahead is full. Nothing crashes (no drops), but a jam in one place backs up through every interchange behind it, even for cars going elsewhere, and if officers end up waiting on each other in a circle, traffic freezes for good. **ECN plus DCQCN** is on-ramp metering: congested road sections paint a mark on passing cars (the ECN bit), the destination posts a card back to the car's owner (a congestion notification packet, CNP), and the owner's card slows that car's on-ramp rate, then gradually speeds it back up. Good metering means the officers rarely raise their hands.

## Step by step

### Step 1: Put RoCE in its own class
Ethernet has 8 priorities (bits in the VLAN tag), and equipment can also classify by **DSCP** in the IP header, which is preferred for RoCE v2 because it survives routing and needs no VLANs. RoCE traffic gets a DSCP (commonly 26) mapped to a priority (commonly 3) that is protected; congestion notifications get their own high priority (commonly DSCP 48) so feedback isn't itself stuck in congestion. In Linux, RDMA connections take their type-of-service from the connection manager's settings or configured defaults (raw verbs users set it per queue pair), and the card is told to **trust DSCP** and given the DSCP-to-priority map through DCB netlink (the `dcb` tool).

### Step 2: Make that class lossless (PFC)
DCB netlink also carries:
- **PFC:** which priorities are protected, cable/PHY delay, and counters of pause frames sent and received
- **ETS:** bandwidth shares, so RoCE gets a guaranteed slice
- **buffers:** receive buffer sizes and which priority uses which

When a protected receive buffer crosses its "stop" threshold, the port sends a **pause** for that priority upstream; the neighbour stops sending that priority (others keep flowing) until "resume". The port needs **headroom** to absorb bytes still on the wire after it says stop, which is why cable length matters. Switches must be configured to match exactly.

### Step 3: Slow sources early (ECN + DCQCN)
This is the key step. DCQCN (SIGCOMM 2015, Microsoft and Mellanox) has three roles:
- **Switch (congestion point):** as a queue grows between a low and high threshold, it marks packets as "congestion experienced" with rising probability. Marking starts well **below** the pause threshold.
- **Receiver card (notification point):** when marked packets arrive for a flow, it sends a CNP back to the sender, at most one per flow per short interval (e.g. 50 µs), on the CNP's own priority.
- **Sender card (reaction point):** each queue pair has a rate limiter with a current rate, a target rate and a congestion estimate. On a CNP, the target becomes the current rate, the current rate is cut in proportion to the estimate, and the estimate rises. Without CNPs the estimate decays, and the rate **recovers** in phases, driven by a timer and a byte counter: fast recovery (halfway back to the target each step), then additive increase, then hyper increase, all within minimum and maximum clamps.

It's **rate-based** rather than window-based because RDMA cards pace at line rate in hardware without per-packet acknowledgement clocking. Its roots are the Ethernet QCN standard, moved to IP ECN so it works across routers.

### Step 4: Tuning and watching in Linux
On mlx5, the DCQCN parameters (about 15 of them, for the reaction and notification points plus a DSCP for round-trip probes) are exposed in debugfs and applied through firmware commands. Congestion **counters** (marked packets received, CNPs sent, CNPs handled or ignored, slow restarts, and per-queue-pair CNP counts) appear in `rdma statistic` and sysfs. Other vendors (bnxt_re, irdma) have their own DCQCN variants and knobs.

### Step 5: When things go wrong
- **Congestion spreading:** a pause stops a whole priority on a link, so flows not headed for the hotspot stall too ("victim flows"). Early marking is the mitigation.
- **PFC deadlock:** circular buffer dependencies, from routing loops, flooding or routing-rule violations after link failures, freeze a priority permanently.
- **Pause storms:** a host whose card can't drain its buffer (a hung driver, stuck PCIe) sends pauses forever, freezing its switch port and spreading upstream. Switches run a **PFC watchdog** that drops or disables PFC on a stuck queue; cards have **stall prevention**, an ethtool setting after which the card stops sending pauses. In 2026 that setting was documented to cover plain (global) pause storms too, and ethtool gained a pause-storm event counter (fbnic, mlx5).

### Step 6: Beyond DCQCN
- **TIMELY** (2015) and **Swift** (2020), both from Google, are delay-based, using hardware timestamps to measure round-trip time.
- **HPCC** (Alibaba, 2019) uses switch telemetry for exact link load, reporting up to 95% better flow completion times than DCQCN and TIMELY, and avoiding DCQCN's many knobs.
- **Resilient/lossy RoCE** runs ECN-based control *without* PFC, plus card-side selective retransmission, so an occasional drop costs one packet rather than a window.
- **Programmable congestion control and Ultra Ethernet:** newer cards offer programmable engines and packet spraying, and the Ultra Ethernet transport standardises congestion control for AI fabrics.

## The picture

```text
 sender NIC ──RoCE v2 (DSCP 26 → prio 3, ECN-capable)──▶ switch queue ──▶ receiver NIC
                                                           │ depth > Kmin: mark CE (prob ↑)
                                                           │ depth > XOFF: PAUSE prio 3 upstream
 sender NIC ◀──────────── CNP (DSCP 48, ≤1 per flow per 50 µs) ── receiver sees CE
 rate: cut on CNP → fast recovery → additive → hyper increase
 guards: switch PFC watchdog; NIC pfc-prevention-tout; pause-storm counters
```

## Tradeoffs

- **What it gives you:** RDMA over Ethernet at line rate, with sender reaction in hardware and no host CPU; a lossless class that keeps the simple transport working.
- **What it costs / requires:** fabric operations become complex: headroom, matching switch and host configuration, deadlock avoidance, storm protection, and DCQCN's many knobs whose right values depend on round-trip times, buffer sizes and incast. Knobs are vendor-specific (debugfs, out-of-tree sysfs) and observability is uneven, though recent upstream work is standardising it.
- **Where it bites:** the design intent is "congestion control first, PFC as the safety net"; mis-set thresholds give either chronic pausing or wasted bandwidth. The industry has since swung toward smarter card transports (selective repeat, lossy RoCE), converging on iWARP's original premise of tolerating loss.

## How it got here

- **2011–2012:** DCB netlink (PFC, ETS, application priorities) in Linux for FCoE and iSCSI, later reused by RoCE.
- **2015:** DCQCN and TIMELY published; Mellanox ships DCQCN; mlx5 congestion parameters and counters upstream (4.x).
- **2016:** Microsoft's "RDMA over Commodity Ethernet at Scale" documents PFC deadlocks and pause storms, motivating watchdogs.
- **2017–2018:** card stall prevention through ethtool; DSCP trust and buffer configuration in DCB netlink (Huy Nguyen).
- **2019–2020:** HPCC and Swift; Resilient RoCE widely deployed.
- **2023–2026:** AI fabrics, programmable congestion control, packet spraying, Ultra Ethernet; per-queue-pair CNP counters; pause-storm statistics (Mohsin Bashir, 2026).

## Related

- Technical version: [[roce-congestion-control-pfc-ecn-dcqcn]]
- [[roce-v1-and-v2-explained|RoCE v1 and v2]], [[rdma-explained|RDMA subsystem]], [[rdma-cm-connection-manager-explained|Connection manager]], [[iwarp-transport-explained|iWARP]]
- [[traffic-control-qdisc-explained|Traffic control]], [[tcp-ip-stack-explained|TCP/IP stack]]
