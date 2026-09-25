---
title: "Netfilter — Explained"
category: explained
original: "[[netfilter]]"
subsystem: netfilter
tags: [explained, netfilter, firewall, nat, conntrack]
converted: 2026-09-25
---

# Netfilter, explained

> Plain-language companion to [[netfilter|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Linux has to act as a firewall, a NAT router, and a stateful gateway: drop unwanted packets, let replies to allowed connections back in, share one public IP among many machines, forward ports to internal servers, and understand protocols like FTP that open extra connections. These policies differ wildly from one machine to the next and change constantly. Hard-coding them into the IP stack would be hopeless; the stack needs a way to let separate modules inspect and modify packets at the right moments, in a well-defined order.

## The big picture

Netfilter is a **checkpoint system on a motorway interchange**. The motorway is the network stack. At five fixed junctions (before routing, on delivery to the local machine, when forwarding, when locally generated packets leave, and just before packets go out), every packet passes a queue of registered inspectors. Each returns a verdict: **accept**, **drop**, **queue** to user space for a decision, or **stolen** (taken over for later). A packet carries on only if every inspector accepts it.

```text
 in ─▶ PREROUTING ─▶ routing ─┬─ local ─▶ LOCAL_IN ─▶ socket ─▶ LOCAL_OUT ─┐
      (conntrack, DNAT)        └─ forward ─▶ FORWARD ─────────────────────┤
                                                                         ▼
                                                   POSTROUTING (SNAT, masquerade) ─▶ out
 at each junction, inspectors run in priority order:
   conntrack (−200) → filter (0) → NAT (+100)
 established flows may skip it all via the flowtable fast path
```

The framework itself contains **no policy**: it only runs hooks and applies verdicts. Every rule, translation and state machine lives in modules that register at these points.

## The pieces

### The hook framework
A module registers a set of hooks, each naming a protocol family, a junction, a **priority** and a callback. Each junction keeps, per network namespace, an array of hooks sorted by priority, rebuilt on every registration. At each junction the stack calls the hooks in order; the first drop or steal stops the run, otherwise the packet continues. Removal uses RCU so it's safe while packets are flowing. Even an empty junction costs something, which is why the fastest paths (XDP, traffic-control BPF) skip netfilter entirely. See [[netfilter-hook-framework-explained|the hook framework]].

### iptables (the classic)
iptables organises rules into **tables** (filter, nat, mangle, raw, security), each hooked at particular junctions, and tables into **chains**. Each chain is walked **linearly**, testing every rule's match against the packet; the first match's target runs: accept, drop, return, jump to another chain, or an extension such as DNAT or LOG. The user-space tool replaces a whole table at once, so even a one-rule change rewrites the entire table, leaving a race window on busy systems. Rules in the raw table run before connection tracking, so they can exempt flows from it. See [[iptables-explained|iptables]].

### nftables (the replacement)
nftables replaces iptables' separate per-protocol code (for IPv4, IPv6, ARP and bridging) with **one engine**: a small **bytecode virtual machine**. Rules are compiled in user space into simple instructions (load a packet field into a register, compare, look up a set, emit a verdict); the kernel module only interprets them and knows nothing about ports or addresses itself.

This is the key design change. Its real speed comes from **sets**: named collections of addresses, ports, MACs or prefixes stored as hash tables, trees or specialised structures, so one lookup replaces thousands of rule comparisons. Updates are **atomic transactions**: a whole batch applies or none of it does, with packets in flight seeing the old version until the commit completes. The early worry that an interpreter would be slower than iptables' native code proved unfounded. See [[nftables|nftables]].

### Connection tracking
**Conntrack** keeps a table of every flow, so rules can match on state (new, established, related, invalid) and NAT can reverse-translate replies automatically. It runs first, at priority −200, when packets arrive and when local packets leave.

The first packet of a flow creates an entry holding **two** tuples, the original direction and the pre-computed reply direction, but only as **unconfirmed**. It's inserted into the main table only when the packet actually makes it through (at the final junction). Packets dropped by the firewall never pollute the table. Later packets in either direction find the entry by hashing their tuple, refreshing its timeout. Protocol trackers refine the state (TCP follows SYN, ACK, FIN and RST). **Helpers** parse protocols that carry addresses in their payload (FTP passive mode, SIP) and create **expectations**, so the follow-on connection is recognised as related. See [[connection-tracking-explained|connection tracking]].

### NAT
NAT is an extension of conntrack. The first time a NAT rule matches a flow, the chosen rewrite is stored in its conntrack entry; after that, every packet of the flow, in both directions, is rewritten from the stored state without re-evaluating rules.
- **DNAT** (destination NAT, for port forwarding) happens before routing, so routing sees the new destination.
- **SNAT** (source NAT) happens after routing, once the outgoing interface is known. **Masquerade** is SNAT that uses whatever address the outgoing interface currently has.

The reverse translation for replies is worked out once and stored in the entry's reply tuple. See [[netfilter-nat-explained|NAT]].

### The flowtable fast path
Once a flow is established, a rule can explicitly **offload** it to a flowtable: a hash table of compact entries (addresses, ports, link-layer details and incoming interface). Later packets are caught by a hook just ahead of conntrack, at −201, looked up, rewritten from cached NAT state if needed, and sent straight to the neighbour, skipping routing, filter chains and NAT hooks. If the card supports it, entries can be pushed into **hardware**, forwarding at line rate with no kernel CPU per packet. Offload is explicit, so administrators can always see which flows bypass the rules. See [[netfilter-flowtable-explained|the flowtable]].

## A request's journey

The first packet of a new inbound TCP connection to a port-forwarded service:

1. **Arrival.** The packet reaches the prerouting junction.
2. **Conntrack (−200).** No existing flow, so an unconfirmed entry is created with state "new".
3. **DNAT (+100).** A port-forward rule matches; the rewrite is stored in the entry and the destination rewritten.
4. **Routing.** Routing sees the rewritten destination and chooses local delivery.
5. **Filter.** The input chain's "allow new connections to this port" rule accepts it.
6. **Confirm and deliver.** This is the key moment: conntrack confirms the entry into the main table, and the packet reaches the socket. Replies will now match the stored reply tuple and be reverse-translated automatically, and later packets can be offloaded to a flowtable to skip all this.

## Tradeoffs

- **What it gives you:** stateful firewalling, NAT in both directions without reverse rules, protocol helpers, atomic rule updates, set-based matching, and optional software or hardware fast paths.
- **What it costs / requires:** per-packet hook traversal (non-zero even when empty), a conntrack entry per flow, and careful priority ordering among modules.
- **Where it bites:** the conntrack table can fill (at its maximum, new flows are dropped), and the default established-TCP timeout is five days, which needs tuning on busy servers. Historically five separate frameworks (iptables, ip6tables, arptables, ebtables, nftables) had to be maintained side by side.

## How it got here

- **2.4 (2001):** netfilter hooks and iptables replace ipfwadm and ipchains.
- **2.6.14 (2005):** conntrack made protocol-generic, with IPv6 tracking.
- **3.13 (2014):** nftables merged, unifying IPv4, IPv6, ARP and bridging in one VM.
- **4.1 (2015):** a specialised set structure for interval and concatenated lookups.
- **4.16 (2018):** the flowtable software fast path. **5.3 (2019):** hardware flow offload.
- **5.13 (2021):** BPF programs attachable as netfilter hooks. **6.4 (2023):** better ruleset scalability.
- **Now:** most distributions default to nftables and ship an iptables front end that compiles to it; iptables' own kernel modules are slowly being de-prioritised.

## Related

- Technical version: [[netfilter]]
- [[netfilter-hook-framework-explained|Hook framework]], [[iptables-explained|iptables]], [[nftables|nftables]], [[connection-tracking-explained|Connection tracking]], [[netfilter-nat-explained|NAT]], [[netfilter-flowtable-explained|Flowtable]]
- [[net-explained|Networking stack]], [[ip-routing-explained|IP routing]], [[network-namespaces-explained|Network namespaces]], [[xdp-explained|XDP]], [[bpf-explained|BPF]], [[security|Security]]
