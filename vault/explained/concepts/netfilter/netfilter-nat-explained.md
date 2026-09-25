---
title: "Netfilter NAT — Explained"
category: explained
original: "[[netfilter-nat]]"
subsystem: netfilter
tags: [explained, netfilter, nat, masquerade, conntrack]
converted: 2026-09-25
---

# Netfilter NAT, explained

> Plain-language companion to [[netfilter-nat|the technical note]]. Same facts, fewer identifiers.

## The problem

With IPv4 addresses scarce, a home or office network usually shares a single public address among many machines, and servers behind it need incoming connections forwarded to them. That means rewriting addresses and ports in packet headers: **SNAT** (and its dynamic form, **masquerade**) for outgoing traffic, **DNAT** (port forwarding) for incoming.

The hard part is the return journey. Replies arrive addressed to the rewritten address and must be translated back, exactly and consistently, for every packet of the flow, without the administrator writing matching reverse rules.

## The idea in one paragraph

NAT is a **sticky note on a connection-tracking entry**. The first time a packet matches a NAT rule, the rule writes the chosen translation on the note attached to that flow's [[connection-tracking-explained|conntrack]] entry. Every later packet in the flow, in **both** directions, just reads the note and applies it, without looking at the rules again. When the conntrack entry expires, the note goes with it. NAT doesn't exist on its own: it's an extension of connection tracking.

## Step by step

### Step 1: The first packet creates the entry
A new flow's first packet arrives; connection tracking (priority −200) creates a provisional entry. Then the NAT hook runs, at priority +100, after the filter chains at 0.

### Step 2: A NAT rule decides the translation
Say a DNAT rule sends TCP port 80 to 192.168.1.10:8080. The kernel:
1. picks the exact new address and port from the rule's range, making sure the result doesn't collide with an existing tracked flow
2. stores the rewrite in the entry's NAT extension
3. **updates the entry's reply tuple** to what replies will actually look like after the rewrite
4. marks the entry as destination-NATed (or source-NATed)

The packet's headers are rewritten immediately.

### Step 3: Why the reply tuple matters
This is the key step. The server's reply comes back from 192.168.1.10:8080. Because the reply tuple was updated, the conntrack lookup for that reply still finds the same entry, and the inverse rewrite is applied automatically, so the client sees the address it originally used. The rule of thumb: **conntrack always hashes what the kernel will actually see on the wire**, not what the original sender intended.

### Step 4: Every later packet
For the rest of the flow, the NAT hooks look up the entry and apply the stored rewrite in the right direction. Addresses and ports are changed, and the TCP/UDP checksum is fixed up **incrementally**: only the changed bytes are folded in, rather than recomputing the whole sum, so the per-packet cost is nearly constant whatever the packet size.

### Step 5: SNAT and masquerade
**DNAT** runs before routing, so routing sees the new destination and delivers to the right internal host. **SNAT** runs after routing, once the outgoing interface is known, rewriting the source to a configured address or range. **Masquerade** is SNAT that asks the outgoing interface for its current address when a flow's first packet passes. If the address changes (a DHCP renewal, say), new flows use the new one and existing flows keep the old one until they expire.

When many internal hosts share one public address, the kernel must hand out distinct source ports so flows stay distinguishable. It searches the configured port range for one that doesn't clash with an existing flow, which is why SNAT port ranges should be generous.

### Step 6: Addresses inside payloads
Some protocols (FTP, SIP) carry addresses inside the payload itself. Header rewriting alone isn't enough: **NAT helpers** work with the connection-tracking helpers, rewriting the embedded address and port in the control connection so the other side connects to the correct translated address. Expected secondary connections inherit their parent's NAT setup.

## The picture

```text
 client 203.0.113.7:51000 ─▶ public 198.51.100.1:80
   conntrack: new entry {orig: 203.0.113.7:51000 → 198.51.100.1:80}
   DNAT rule → rewrite dst → 192.168.1.10:8080
      entry.reply = 192.168.1.10:8080 → 203.0.113.7:51000     (what replies really look like)
 server reply 192.168.1.10:8080 → 203.0.113.7:51000
   lookup by reply tuple ✓ → inverse rewrite src → 198.51.100.1:80 → client happy
```

## Tradeoffs

- **What it gives you:** address sharing and port forwarding with automatic, consistent reverse translation, state cleaned up with the connection, near-constant per-packet cost, and helper support for awkward protocols.
- **What it costs / requires:** connection tracking for every NATed flow; unique-port searches for shared source addresses; helpers for payload-embedded addresses.
- **Where it bites:** port exhaustion under heavy carrier-grade NAT, a recurring topic with regular patches for faster port reuse and bigger ranges. Helpers must be loaded, or protocols like FTP break behind NAT.

## How it got here

- **2.4 (2001):** NAT rebuilt on the new connection tracking; masquerade becomes a conntrack extension, not a separate stateful table.
- **3.7 (2012):** IPv6 NAT (prefix translation, DNAT and SNAT), merged despite philosophical objections that IPv6 shouldn't need NAT, because operators sometimes can't avoid it.
- **4.18 (2018):** port selection redesigned for high connection rates.
- **5.3 (2019):** NAT parameters cached in hardware-offloaded flowtable entries.

## Related

- Technical version: [[netfilter-nat]]
- [[netfilter-explained|Netfilter]], [[connection-tracking-explained|Connection tracking]], [[netfilter-hook-framework-explained|Hook framework]], [[netfilter-flowtable-explained|Flowtable]], [[iptables-explained|iptables]], [[nftables|nftables]]
- [[ip-routing-explained|IP routing]]
