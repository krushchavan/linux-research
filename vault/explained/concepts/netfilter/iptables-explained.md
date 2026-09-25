---
title: "iptables — Explained"
category: explained
original: "[[iptables]]"
subsystem: netfilter
tags: [explained, netfilter, iptables, firewall]
converted: 2026-09-25
---

# iptables, explained

> Plain-language companion to [[iptables|the technical note]]. Same facts, fewer identifiers.

## The problem

Administrators need to write firewall policy (what to allow, what to drop, what to rewrite, what to label) without changing the kernel each time. The policy must run at the right points in the packet's journey through [[netfilter-explained|netfilter]]'s hooks, be updatable while traffic flows, and be extensible with new kinds of matches and actions.

## The idea in one paragraph

iptables works like a **sorting office**. Packets pass a series of sorting desks (**chains**); each desk checks packets against a list of criteria (**matches**) and says what to do (a **target**). Desks are grouped into departments (**tables**) with authority at different stages of the journey: filter decides allow or deny, nat rewrites addresses, mangle attaches marks and tweaks header fields. Each chain is a simple list, read top to bottom until a rule decides.

## Step by step

### Step 1: Tables at hook points
Each table registers a callback at the netfilter junctions where it works, and at a shared junction the tables run in a fixed order set by their priorities:
- **raw** (prerouting, output): runs before connection tracking, so it can exempt flows from tracking
- **mangle** (all five): marks, type-of-service and TTL changes
- **nat** (prerouting, input, output, postrouting): DNAT, SNAT, masquerade, redirect
- **filter** (input, forward, output): the main allow and deny decisions
- **security** (input, forward, output): SELinux labelling

### Step 2: A chain is a flat list of rules
Each chain's rules sit back to back in one **flat block of memory**. Each rule has:
1. **basic header criteria:** source and destination address with masks, incoming and outgoing interface names (wildcards allowed), protocol. These are checked first, so non-matching rules are skipped cheaply.
2. **match extensions:** zero or more add-on tests (TCP ports, connection state, multiple ports…). All must pass.
3. **a target:** run when everything matches. Built-in targets return a verdict (accept, drop, return, queue to user space); extension targets such as DNAT, LOG or MARK may change the packet first.

Each rule also keeps packet and byte counters.

### Step 3: Walk the chain
This is the key step. The packet is tested against each rule **in order**, and the first rule whose criteria all match decides. A **jump** to a user-defined chain pushes the current position onto a stack and scans that chain; **return** pops back to the rule after the jump. If a built-in chain ends without a decision, its **policy** (accept or drop) applies. The cost grows linearly with the number of rules.

### Step 4: Replacing rules
To change rules, the user-space tool downloads the **whole** table, edits it, and uploads a complete new block. The kernel checks it, swaps it in under a per-table lock, and keeps the old block until every evaluation still using it has finished. Swapping the whole block keeps the kernel simple, but even a one-rule change means rewriting the entire ruleset. On firewalls with thousands of rules, updates are slow, and an interrupted update can leave a window of partial state. This was a major reason for nftables' transactions.

## The picture

```text
 packet at FORWARD hook ─▶ table "filter", chain FORWARD
   rule 1: -i eth1 -p tcp --dport 22   → ACCEPT     ✗ no match, skip
   rule 2: -m conntrack --ctstate EST  → ACCEPT     ✗
   rule 3: -s 10.0.0.0/8               → jump LAN    ✓ push position
        LAN: rule a … → RETURN        ↩ pop, continue at rule 4
   rule 4: …
   end of chain → policy DROP
 update: download whole table → edit → upload whole table → swap
```

## Tradeoffs

- **What it gives you:** a clear, flexible model of tables, chains, matches and targets; new behaviour through extension modules instead of kernel changes; per-rule counters.
- **What it costs / requires:** linear scanning, which becomes a bottleneck with thousands of rules at millions of packets a second (ipset later added set lookups, as a separate tool and module); whole-table replacement on every change.
- **Where it bites:** separate near-duplicate tools for IPv6, ARP and bridging (ip6tables, arptables, ebtables) are a maintenance burden and confuse administrators. Large rulesets make updates slow and risky.

## How it got here

- **2.4 (2001):** iptables replaces ipchains (Rusty Russell), with tables, chains, targets and match extensions, so new policies need only new modules.
- **2.6 (2003):** shared extension infrastructure, so IPv4 and IPv6 firewalls can share matches and targets.
- **3.13 (2014):** nftables merged as the long-term replacement. Debate through the 2010s concluded that linear scanning was a fundamental limit for large rulesets, not just a configuration problem.
- **~2018:** an iptables front end that translates iptables syntax into nftables bytecode, for gradual migration.
- **Now:** iptables' kernel modules get security fixes but few new features; distributions default to nftables with the compatibility front end.

## Related

- Technical version: [[iptables]]
- [[netfilter-explained|Netfilter]], [[nftables|nftables]], [[netfilter-hook-framework|Hook framework]], [[connection-tracking-explained|Connection tracking]], [[netfilter-nat|NAT]]
