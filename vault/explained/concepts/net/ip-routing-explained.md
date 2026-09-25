---
title: "IP Routing & FIB — Explained"
category: explained
original: "[[ip-routing]]"
subsystem: net
tags: [explained, networking, routing, fib, ecmp]
converted: 2026-09-25
---

# IP routing and the FIB, explained

> Plain-language companion to [[ip-routing|the technical note]]. Same facts, fewer identifiers.

## The problem

Every IP packet raises one question: where next? Deliver it to a local socket, forward it to another machine through a particular interface and gateway, or throw it away as unreachable. A router asks this millions of times a second, so the answer has to be fast. The rules can also be subtle: the most specific matching route wins, different traffic may need different tables (VPNs, VRFs, multi-homed servers), and several equally good paths may need to share the load without scrambling packet order.

## The idea in one paragraph

The **FIB** (forwarding information base) is a **postal sorting machine**. The destination address is the postcode; the machine is a tree of bins, from very specific prefixes down to the catch-all default route, and it finds the deepest matching bin quickly. The result is a pre-printed **routing label** (a cached route) naming the output chute and the next stop. The packet carries that label through the rest of the stack, so nothing has to consult the sorting machine again.

## Step by step

### Step 1: Arrival
The IP receive code checks the header (version, length, checksum, TTL), then runs the firewall's **prerouting** hook, where destination NAT may rewrite the destination address. Only then is the route looked up, so the lookup sees the post-NAT address.

### Step 2: Pick a table (policy routing)
The lookup key summarises the packet: source, destination, type of service, incoming interface and firewall mark. First, the **rules** list is checked in order; each rule can match any of those fields and names a routing table. There can be up to 255 tables (253 is "default", 254 "main", 255 "local"). Most systems have one default rule pointing at the main table; policy routing is what enables VPN split routing, per-user routes and multi-homed servers.

### Step 3: Walk the trie
This is the key step. Inside the chosen table, IPv4 routes live in an **LC-trie** (level-compressed trie), a compressed tree walked bit by bit along the destination address until it reaches a leaf. The leaf holds the matching route entries, and the first whose type of service and scope fit supplies the **next hop(s)**: output device, gateway and flags. A plain hash table can't do this, because it only does exact matches, not longest-prefix matches. Inserting routes means restructuring trie nodes, which is costlier than a hash insert, but routes change rarely compared with how often they're looked up. (IPv6 uses its own tree structure.)

### Step 4: Stamp the label onto the packet
The result becomes a **cached route** attached to the packet, with a function pointer set to what happens next:
- local delivery
- forwarding
- broadcast or multicast handling
- blackhole: discard

Every later stage just calls "deliver according to the label", with no second lookup and no "local or forwarded?" check on every packet.

### Step 5: Forwarding
The forward path decrements the TTL (sending an ICMP "time exceeded" and dropping at zero), updates the header checksum incrementally, runs the firewall's **forward** hook, and sends the packet out, fragmenting it if it's bigger than the outgoing link's MTU.

### Step 6: Find the next hop's link address
Before sending, the **neighbour cache** (ARP for IPv4) turns the next hop's IP address into a link-layer address. If there's a reachable or recently seen entry, the cached address is copied into the frame and it's queued for transmission. Otherwise a new entry is created as "incomplete", the packet waits, and an ARP request goes out; the reply marks the entry reachable and releases the waiting packet.

### Step 7: Spreading load (ECMP)
When several routes to the same destination are equally good, they're stored as multiple next hops. Each flow's addresses and protocol (and optionally ports) are **hashed** to pick one, so one flow always takes the same path and its packets aren't reordered. **Resilient** groups (5.10) keep an explicit map of hash buckets to next hops, so when one next hop fails, only its buckets move; the other flows, and their TCP sessions, are untouched.

## The picture

```text
 packet dst 10.1.2.3
   prerouting hook (maybe DNAT)
   rules: fwmark 1 → table 100 · otherwise → main
   trie walk: 0.0.0.0/0 ─ 10.0.0.0/8 ─ 10.1.0.0/16 ✓ (longest match)
   label: { forward, dev eth1, gateway 192.168.0.1 }
   forward: TTL−1 → forward hook → MTU check → neighbour lookup (ARP) → transmit queue
 ECMP: hash(src, dst, proto[, ports]) → next hop A or B (same flow, same choice)
```

## Tradeoffs

- **What it gives you:** fast longest-prefix matching, one lookup per packet with the decision carried along, flexible policy routing, and order-preserving load spreading that can survive link failures.
- **What it costs / requires:** trie restructuring on route changes; care with cached routes that go stale when routes are flushed.
- **Where it bites:** reverse-path filtering (drop packets whose source isn't reachable back through the arrival interface) can silently drop traffic on asymmetric or multi-homed setups. Forgetting to enable forwarding makes a would-be router drop everything.

## How it got here

- **2.1 (1996):** policy routing and multiple tables.
- **2.6.39 (2011):** the trie fully replaced the hash-based routing table.
- **3.6 (2012):** the per-flow route cache removed (Eric Dumazet). Crafted source addresses could flood it (a DoS vector), it hogged memory with many flows, and its contention hurt NUMA machines. A trie walk per packet (typically 10 to 50 ns) proved fast enough.
- **4.4 (2016):** multipath hashing can include ports. **5.2 (2019):** next hops became first-class kernel objects. **5.10 (2020):** resilient ECMP.

## Related

- Technical version: [[ip-routing]]
- [[net-explained|Networking stack]], [[network-device-and-napi|Devices and NAPI]], [[network-namespaces|Network namespaces (per-namespace tables)]], [[tcp-ip-stack|TCP/IP]]
- [[netfilter|Netfilter]], [[netfilter-nat|NAT]]
