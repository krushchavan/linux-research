---
title: "Netfilter Flowtable — Explained"
category: explained
original: "[[netfilter-flowtable]]"
subsystem: netfilter
tags: [explained, netfilter, flowtable, fast-path, hardware-offload]
converted: 2026-09-25
---

# The netfilter flowtable, explained

> Plain-language companion to [[netfilter-flowtable|the technical note]]. Same facts, fewer identifiers.

## The problem

On a Linux router, every packet of every forwarded flow normally goes through all of [[netfilter-explained|netfilter]]: the hook framework, a connection-tracking lookup, filter chains and NAT. For a router carrying millions of flows at 10 Gb/s or more, that per-packet work on long-established TCP sessions becomes the dominant cost, even though the decision for such a flow was made long ago and won't change.

## The idea in one paragraph

The flowtable is an **express lane** beside the security checkpoint. A flow's first packets go through the full checkpoint (connection tracking, filter, NAT). Once the flow is established and trusted, later packets get an **express pass**, a flowtable entry, and use a separate lane that only checks the pass and forwards at once. The pass carries the NAT rewrite, so translation still happens, but the policy checks are skipped. TCP packets that end a connection (RST, FIN) are sent back through the normal checkpoint so the flow closes cleanly.

## Step by step

### Step 1: Opt in explicitly
Nothing is offloaded automatically. The administrator declares a flowtable (which devices it covers) and adds a rule in the forward chain such as "for established TCP and UDP, add the flow to this flowtable". When that rule fires for an assured connection, a compact entry is created and queued for insertion into the flowtable's hash table, and pushed to the card as well if hardware offload is enabled.

### Step 2: Get in first
The flowtable registers its own hook at priority −201, one step ahead of connection tracking's −200. This ordering is essential: if the flowtable recognises the packet, it forwards it and reports it as **stolen**, so connection tracking and everything after it never see it.

### Step 3: The fast path
This is the key step. For each arriving packet, the hook:
1. builds a key from the link-layer encapsulation, addresses, ports and incoming interface
2. looks it up in the hash table under RCU
3. **on a hit** (and not marked dying or being torn down): applies the cached NAT rewrite, decrements the TTL, fills in the next hop's link address, sends the packet straight out of the egress interface, and reports it stolen
4. **on a miss:** lets it continue normally through connection tracking and the filters

TCP RST and FIN packets are deliberately not fast-pathed, so teardown goes through connection tracking; otherwise the tracked entry would linger as "established" until timeout.

### Step 4: NAT keeps working
When a flow is offloaded, its NAT parameters (including TCP sequence adjustments, for helpers that change packet lengths) are copied into the entry. The fast path applies them itself, without calling the NAT module, so SNAT and DNAT run at full speed.

### Step 5: Hardware offload
If the card supports flow offload, the entry (addresses, ports, NAT rewrite, egress port) is programmed into the card's own flow table. Matching packets are then switched entirely inside the card, with no kernel CPU time per packet. The driver reports back when flows expire or need refreshing. The connection-tracking entry stays alive and is shown as hardware-offloaded. Rather than inventing a new driver interface, this reuses the traffic-control offload machinery drivers already implement.

### Step 6: Stale next hops
The fast path caches the next hop's link-layer (ARP or neighbour-discovery) entry. If the route or the neighbour's address changes, the stale entry is noticed, the flow is torn down, and it returns to the normal path, which does a fresh routing lookup.

### Step 7: Graceful expiry
An entry that sees no packets for its timeout (30 seconds by default for TCP and for UDP) is garbage-collected. Its connection-tracking entry is **not** deleted: the next packet misses the flowtable, falls through to connection tracking (which still knows the flow), is handled normally, and can be offloaded again.

## The picture

```text
 packet ─▶ flowtable hook (−201): key lookup
   hit, not TCP RST/FIN ─▶ apply cached NAT ─▶ TTL−1 ─▶ neighbour MAC ─▶ transmit (stolen)
   miss or RST/FIN      ─▶ conntrack (−200) ─▶ filter ─▶ NAT ─▶ routing … (normal path)
                              └ rule "flow add @ft" on established flows → new flowtable entry
 hardware offload: entry programmed into the card ─▶ switched in hardware, 0 CPU per packet
 idle 30 s ─▶ entry removed, conntrack entry kept ─▶ next packet takes the normal path
```

## Tradeoffs

- **What it gives you:** much cheaper forwarding for established flows, NAT included, and line-rate hardware switching where cards support it.
- **What it costs / requires:** explicit rules to opt flows in; filter rules no longer see packets of offloaded flows; hardware offload needs driver support.
- **Where it bites:** policies that expect to inspect every packet of an established flow won't, which is exactly why offload is opt-in and visible. Stale neighbours and idle timeouts send flows back to the slow path.

## How it got here

- **4.16 (2018):** software flowtable for IPv4 TCP and UDP forwarding (Pablo Neira Ayuso). The debate over automatic versus explicit offload was settled in favour of explicit, for debuggability and backward compatibility.
- **5.0 (2019):** IPv6 support.
- **5.3 (2019):** hardware offload, with the first drivers from Mediatek and Netronome.
- **5.6 (2020):** PPPoE and VLAN encapsulation in entries, for broadband routers.
- **5.13 (2021):** IPsec support, so offloaded flows can use hardware crypto.

## Related

- Technical version: [[netfilter-flowtable]]
- [[netfilter-explained|Netfilter]], [[connection-tracking-explained|Connection tracking]], [[netfilter-nat|NAT]], [[netfilter-hook-framework|Hook framework]], [[nftables|nftables]]
- [[ip-routing-explained|IP routing]], [[traffic-control-qdisc-explained|Traffic control]], [[net-explained|Networking stack]]
