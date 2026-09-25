---
title: "Netfilter Hook Framework — Explained"
category: explained
original: "[[netfilter-hook-framework]]"
subsystem: netfilter
tags: [explained, netfilter, hooks, rcu, priorities]
converted: 2026-09-25
---

# The netfilter hook framework, explained

> Plain-language companion to [[netfilter-hook-framework|the technical note]]. Same facts, fewer identifiers.

## The problem

Firewalls, NAT, connection tracking and security modules all need to look at (and sometimes change or drop) packets at particular moments in the IP stack. If each one patched its own calls into the stack, they'd be tightly tied to it, would step on each other, and there'd be no sane way to decide who goes first. The stack needs one shared set of interception points, with a clean way to register at them and a clear running order.

## The idea in one paragraph

The hook framework is a **priority queue of security gates at five motorway on-ramps**. At five fixed junctions in the IP path (before routing, on delivery to the local machine, at the forwarding crossroads, when a local socket sends, and just before transmission), each packet is held and passed through every installed gate in **priority order**. One gate saying "no" is enough to stop it; all must say "pass" for it to continue. The framework holds no policy of its own; it only runs the gates.

## Step by step

### Step 1: Register a gate
At load time, a module registers one or more hooks for a network namespace. Each names:
- a callback that returns a verdict
- a protocol family (IPv4, IPv6, ARP, per-device…)
- which of the five junctions
- a **priority**, where lower runs earlier: connection-tracking defragmentation at −400, connection tracking at −200, filtering at 0, source NAT at +100
- optionally, a single device it applies to

### Step 2: Keep the list sorted
Each junction keeps an array of its hooks **sorted by priority**, rebuilt whenever something registers. Sorting at registration keeps the per-packet path to a plain walk through an array, with no sorting and good cache behaviour.

### Step 3: Run the gates at a junction
This is the key step. The stack has a hook call at each junction: in IPv4, on arrival, on local delivery, when forwarding, on local output, and before final transmission. The call first checks whether **any** hooks are registered for this family and junction. If none are, it goes straight on to the next stage, at essentially no cost. Otherwise it walks the sorted array, calling each hook with the packet and a context describing it: incoming and outgoing devices, namespace, owning socket, and a "carry on" function.
- if a hook returns anything other than accept, the walk stops and that verdict applies: **drop** frees the packet, **queue** sends it to user space for a decision, **stolen** means the hook has taken it over
- if every hook accepts, the "carry on" function continues normal processing

### Step 4: Remove gates safely
Unregistering rebuilds the array without the removed hooks and publishes it under RCU. The old array is freed only after a grace period, so packets being processed against it finish safely. Hooks can come and go while traffic flows, without stopping anything.

### Step 5: Why these five junctions
They bracket every meaningful decision: before routing, then the local-versus-forward split, then output. Anything earlier, like acting in the driver before an skb exists, is XDP's job; anything that needs to understand application protocols is delegated to connection-tracking helpers.

## The picture

```text
 junction: PREROUTING (IPv4)            sorted hook array
   packet ─▶ any hooks? ── no ──▶ continue (≈ free)
                 │ yes
                 ▼
   [−400 defrag] → [−200 conntrack] → [0 filter] → [+100 NAT]
        accept         accept            DROP ✗ → stop, free packet
   all accept → "carry on" → routing

 unregister: build new array → publish (RCU) → wait grace period → free old array
```

## Tradeoffs

- **What it gives you:** one shared set of interception points; predictable ordering between modules that know nothing about each other; near-zero cost where nothing is registered; safe hot removal.
- **What it costs / requires:** module authors must pick priorities that put them correctly relative to connection tracking and filtering; each registered hook adds an indirect call per packet.
- **Where it bites:** a wrongly chosen priority causes subtle ordering bugs (NAT before connection tracking, say). The fastest packet paths (XDP, traffic-control BPF) run outside these hooks entirely.

## How it got here

- **2.4:** netfilter hooks replace the ipchains mechanism (Rusty Russell), as the minimal shared plumbing every firewall module could use.
- **2.6.20:** hooks became network-namespace aware.
- **4.14:** the sorted array replaced the older linked list, after a 2017 discussion on faster hook iteration.
- **5.13:** BPF programs can register as netfilter hooks.

## Related

- Technical version: [[netfilter-hook-framework]]
- [[netfilter-explained|Netfilter]], [[connection-tracking-explained|Connection tracking]], [[netfilter-nat-explained|NAT]], [[netfilter-flowtable-explained|Flowtable]], [[iptables-explained|iptables]], [[nftables-explained|nftables]]
- [[net-explained|Networking stack]], [[xdp-explained|XDP]], [[rcu-read-copy-update-explained|RCU]], [[bpf-explained|BPF]]
