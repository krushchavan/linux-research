---
title: "nftables — Explained"
category: explained
original: "[[nftables]]"
subsystem: netfilter
tags: [explained, netfilter, nftables, bytecode-vm, sets]
converted: 2026-09-25
---

# nftables, explained

> Plain-language companion to [[nftables|the technical note]]. Same facts, fewer identifiers.

## The problem

[[iptables-explained|iptables]] had three deep weaknesses. It was **fragmented**: separate near-identical tools and kernel code for IPv4, IPv6, ARP and bridging. It was **linear**: each packet was checked against rules one by one, so thousands of rules meant thousands of comparisons. And updates weren't truly **atomic**: changing one rule meant replacing the whole table, leaving a window where packets could see a half-applied state.

## The idea in one paragraph

Turn the kernel into a **simple bytecode interpreter**. Instead of kernel modules that know about TCP ports or IP addresses, the kernel only knows how to load bytes from a packet, do arithmetic, compare values, look things up in tables and return a verdict. All the protocol knowledge (what to load, how to compare, what a port range is) lives in the user-space `nft` compiler, which turns rules into bytecode. New protocol support then needs no kernel changes, one engine serves every address family, fast **set** lookups replace long rule lists, and changes arrive as all-or-nothing **transactions**.

## Step by step

### Step 1: The data model
- **Table:** a namespace for one address family (`ip`, `ip6`, `inet` for both IPv4 and IPv6, `arp`, `bridge`, `netdev`). It just groups chains.
- **Base chain:** attached to a netfilter hook with a priority and a default policy; creating one registers a hook with the [[netfilter-hook-framework-explained|hook framework]]. **Regular chains** have no hook and are reached only by jump or goto.
- **Rule:** a sequence of **expressions** stored inline.
- **Expression:** the VM's basic instruction: load packet bytes into a register, compare, look up a set, count, or emit a verdict (accept, drop, jump, goto, return, continue).

### Step 2: Run the bytecode
When a packet reaches a base chain, the interpreter walks the chain's rules, running each rule's expressions in turn. It has 16 registers, each 16 bytes wide (big enough for an IPv6 address). A comparison that fails sets "break", skipping to the next rule; a verdict such as drop ends the chain immediately.

### Step 3: Sets and maps
This is the key step. A **set** is a named collection (addresses, ports, MACs, prefixes), and a single lookup expression checks membership in one step instead of one rule per element. Backends suit different data:
- **hash:** exact matches, constant time
- **red-black tree:** ranges and intervals, logarithmic time
- **bitmap:** small integers such as ports
- **pipapo:** matching several fields at once (say source prefix *and* destination port range), done as a series of bit-vector stages

A **map** attaches a value or verdict to each element, so one lookup can also return per-address rate limits, per-service routing decisions, and so on. Elements can time out automatically. This is why the early worry that an interpreter would be slower than iptables' native code proved unfounded: set lookups replace long linear chains.

### Step 4: Atomic transactions
User space sends a whole batch of changes in one netlink message. The kernel validates every operation, then applies the entire batch or rejects it. Each rule carries a small **generation** marker. At commit, the kernel flips the active generation: packets already in flight finish under the old rules, and later packets see the new ones. There's never a half-applied state. The price is a generation check per rule and careful bookkeeping when committing.

### Step 5: Connecting to the rest of netfilter
Expressions can read and write connection-tracking state (state, mark, label, zone), set up NAT, and add established flows to a flowtable for the fast path.

## The picture

```text
 rule "ip saddr @blocklist tcp dport 22 drop" compiled by nft into:
   load  [network header, src addr]   → reg1
   lookup reg1 in set "blocklist"      ✗ → break (next rule)
   load  [transport header, dst port] → reg2
   cmp   reg2 == 22                    ✗ → break
   verdict drop
 set "blocklist": hash of 50,000 addresses → one lookup, not 50,000 rules
 update: batch {add rule, delete rule, add element} → validate all → flip generation
```

## Tradeoffs

- **What it gives you:** one engine for every address family, set and map lookups instead of linear scans, genuinely atomic updates, and new protocol support without kernel changes.
- **What it costs / requires:** a generation check per rule; what you can express is limited by what the `nft` compiler supports (truly unusual logic may need a new expression module).
- **Where it bites:** the step from iptables' familiar model to tables, chains and sets you define yourself takes relearning; the compatibility front end helps, but mixing both styles on one system gets confusing.

## How it got here

- **3.13 (2014):** first merge, with the `inet` family, basic expressions and hash sets. Pablo Neira Ayuso's 2013 RFC had been heavily debated as possible over-engineering; unified protocol handling and atomic updates won the argument.
- **4.1 (2015):** tree-based interval sets and element timeouts.
- **4.16 (2018):** per-device ingress and egress hooks; sets updated dynamically from rules.
- **5.6 (2020):** the pipapo backend, benchmarked as orders of magnitude faster than equivalent iptables ipset setups for combined address-and-port matching.
- **5.13 (2021):** BPF programs usable as base-chain callbacks. **6.4 (2023):** parallel evaluation of independent chains.
- **2021:** nftables reached 1.0.

## Related

- Technical version: [[nftables]]
- [[netfilter-explained|Netfilter]], [[iptables-explained|iptables]], [[netfilter-hook-framework-explained|Hook framework]], [[connection-tracking-explained|Connection tracking]], [[netfilter-nat-explained|NAT]], [[netfilter-flowtable-explained|Flowtable]]
- [[bpf-explained|BPF]]
