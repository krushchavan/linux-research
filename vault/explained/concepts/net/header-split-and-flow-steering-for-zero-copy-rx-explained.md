---
title: "Header Split and Flow Steering for Zero-Copy RX — Explained"
category: explained
original: "[[header-split-and-flow-steering-for-zero-copy-rx]]"
subsystem: net
tags: [explained, networking, header-split, rss, zero-copy]
converted: 2026-09-26
---

# Header split and flow steering for zero-copy receive, explained

> Plain-language companion to [[header-split-and-flow-steering-for-zero-copy-rx|the technical note]]. Same facts, fewer identifiers.

## The problem

Both zero-copy receive mechanisms that keep the kernel's TCP stack, devmem TCP and io_uring zero-copy receive, depend on two card features:
1. **Header/data split:** the card writes each packet's **headers** into ordinary kernel memory the stack can read, and its **payload** into the zero-copy buffer (GPU memory or a user area). Without it, headers would land where the kernel can't read them, or payloads would have to be copied out of kernel pages.
2. **Flow steering and RSS isolation:** the TCP flows the application wants must land on the receive queue bound to its memory, and **nothing else** may land there, because every buffer that queue fills belongs to the application.

The kernel has to expose these settings uniformly and, crucially, refuse changes that would break a bound queue.

## The idea in one paragraph

A zero-copy receive queue is a **private loading dock** for one tenant. **Header split** is the rule that the paperwork (headers) always goes to the building's front office (kernel memory) while the cargo (payload) goes straight to the tenant's dock. **RSS isolation** takes the dock out of the general rotation so random deliveries don't show up there. **Flow-steering rules** are the tenant's standing order: "trucks from this sender, for this port, go to dock 7". The building manager (the kernel) refuses reorganisations that would dump strangers' cargo on the tenant or send the tenant's paperwork to the dock.

## Step by step

### Step 1: Turn on header split
ethtool turns TCP data split on and sets a **split threshold**: packets smaller than it arrive whole in the header buffer ("copybreak"; bnxt defaults to 256 bytes). Drivers declare whether they support these settings and the maximum threshold, and unsupported requests are rejected with a message. Since 6.14 (Taehee Yoo, bnxt) the kernel remembers the *user's* requested settings separately from driver defaults, so it can enforce rules regardless of driver state. Cards usually split at the TCP header, sending headers to a small buffer from the normal page pool and payload to a buffer from the queue's pool, which is the memory provider when one is bound. mlx5 splits every packet size and has no threshold, so it reports 0 for both.

### Step 2: Threshold zero is mandatory
This is the key step. A memory provider needs split **on** and a threshold of **zero**. With any threshold, small packets would put their *payload* into the header buffer and the provider would never see it: the application would get copied "linear" data (devmem) or copy-fallback completions (io_uring). Drivers must allow unreadable memory exactly when split is on.

### Step 3: Guards the kernel enforces
- **Binding** a provider to a queue fails if split is off, the threshold isn't zero, any XDP program is attached (it could read or redirect unreadable payload), a requested buffer size isn't supported, the queue already has a provider or AF_XDP socket, or the queue is leased to a virtual device.
- **Ring changes:** while any queue has a provider, split can't be turned off and the threshold can't be raised. Separately, split can't be enabled with single-buffer XDP, which needs each packet in one buffer.
- **Channel changes:** reducing the number of queues below the highest provider-bound queue fails, just as it does for RSS tables and steering rules that reference queues.

### Step 4: Keep other traffic off the queue
RSS hashes each flow into an **indirection table** of queues. The simplest isolation spreads RSS over only the first N queues, leaving higher ones out (the io_uring documentation's recipe: two queues, RSS over one, zero-copy on the other). **RSS contexts** add extra indirection tables, so steering rules can target a *group* of provider-bound queues, spreading zero-copy flows across several while keeping them out of the default table. Contexts still used by rules can't be deleted.

### Step 5: Steer the chosen flows
A **flow-steering rule** (an n-tuple rule, matched before RSS) sends, say, TCP traffic to a given port or from a given peer to a queue or context. Accelerated RFS doesn't suit zero-copy queues, because it follows the CPU where the consuming thread runs, not the provider binding. Some setups use a hardware-offloaded traffic-control rule instead.

### Step 6: When steering is wrong
Correctness holds either way. A zero-copy flow landing on a normal queue arrives in kernel pages and is copied (devmem's linear messages, io_uring's copy events). Other traffic landing on a provider queue uses up provider buffers: for devmem, the other socket can't read it and the data is dropped or errors; io_uring copies it out for non-owners. Either way buffers are wasted, hence isolation. Configuration happens out of band: the kernel doesn't install rules for the application, a known usability gap.

## The picture

```text
 ethtool -L eth0 combined 16
 ethtool -G eth0 tcp-data-split on hds-thresh 0
 ethtool -X eth0 equal 15                          # RSS over queues 0-14 only
 ethtool -N eth0 flow-type tcp6 dst-port 5201 action 15
 bind devmem / io_uring zcrx to queue 15
   packet for :5201 → queue 15 → headers → kernel page | payload → GPU / user area
 blocked while bound: split off, threshold > 0, XDP, fewer than 16 queues
```

## Tradeoffs

- **What it gives you:** zero-copy placement with standard TCP, and a checked configuration: an administrator can't silently break a bound queue with ethtool.
- **What it costs / requires:** because the card can't know which *application buffer* a byte belongs to, only which queue, queues must be dedicated, costing RSS parallelism for everyone else plus setup work. A zero threshold means every packet uses two buffers, even tiny ones.
- **Where it bites:** steering stays manual; proposals for automatic steering keep coming up. By contrast, RDMA cards need none of this, because the transport knows each message's destination buffer from its key or posted receive.

## How it got here

- **Before 6.7:** drivers had ad-hoc split settings; n-tuple rules since 2.6.3x; RSS contexts via ioctl in 4.x.
- **6.7 (2024):** TCP data split in ethtool's netlink ring settings.
- **6.12:** devmem TCP adds binding preconditions (split on, no XDP).
- **6.14 (2025):** split threshold and remembered user intent (Taehee Yoo), with provider guards and the single-buffer-XDP exclusion.
- **6.1x:** RSS contexts over netlink; channel checks for providers.
- **2026:** mlx5 reports a zero threshold; buffer-size capability checks; AF_XDP/provider exclusion and leased-queue checks.

## Related

- Technical version: [[header-split-and-flow-steering-for-zero-copy-rx]]
- [[devmem-tcp-explained|devmem TCP]], [[devmem-tcp-rx-dmabuf-binding-and-token-recycling-explained|devmem RX binding]], [[zero-copy-rx-zcrx|io_uring zcrx]], [[netdev-queue-management-api-explained|Queue management API]], [[netmem-and-net-iov-abstraction-explained|netmem and net_iov]]
- [[xdp-explained|XDP]], [[af-xdp-explained|AF_XDP]], [[network-device-and-napi-explained|NAPI]], [[page-pool-explained|Page pool]], [[rdma-explained|RDMA]]
