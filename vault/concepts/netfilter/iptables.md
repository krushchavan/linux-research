---
title: "iptables"
category: concept
tags: [netfilter, iptables, firewall, packet-filtering, chains, tables, nat]
subsystem: netfilter
kernel_version: "2.4"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/net/netfilter/
  - https://kernel-internals.org/net/nftables-iptables/
  - https://lwn.net/Articles/867185/
---

# iptables

## Purpose

iptables is the classic Linux packet-filtering framework. It provides a userspace interface for defining stateless and stateful firewall rules organised into tables and chains, and a kernel-side evaluation engine that runs those rules at netfilter hook points. iptables was the primary Linux firewall mechanism from kernel 2.4 (2001) until nftables began replacing it in the 2.14+ distributions era, and it remains widely deployed.

## Mental Model

Think of iptables as a **sorting office**: packets arriving in the kernel are passed through a sequence of sorting desks (chains), each of which checks a set of criteria (match extensions) and decides what to do (target). The sorting desks are grouped into departments (tables) that have authority at different stages of the packet journey. The filter department handles allow/deny decisions; the nat department handles address rewriting; the mangle department handles metadata tagging.

## How It Works

When a packet enters the network stack and reaches a netfilter hook point, the kernel calls `ipt_do_table()`, the iptables hook callback. The table in question was registered at module init by `ipt_register_table()`, which installed the `ipt_do_table` callback for each hook point the table operates at.

Inside `ipt_do_table()`, the packet is evaluated against the **rule blob** — a flat byte array of back-to-back `struct ipt_entry` records representing the chain's rules. Each entry has:

1. **`struct ipt_ip`** — header match criteria: source/destination IP address with masks, ingress/egress interface name patterns (with wildcards), protocol number. The function `ip_packet_match()` tests the packet against these fields. If the packet doesn't match, the entry is skipped and the pointer advances by `next_offset` bytes.

2. **Match extensions** — zero or more variable-length `struct xt_entry_match` blobs that follow the `ipt_entry` header. Extensions like `xt_tcp`, `xt_conntrack`, `xt_multiport` each provide a `match()` function pointer. All extension matches must return true for the rule to fire.

3. **Target** — a `struct xt_entry_target` at offset `target_offset` within the entry. The target's `target()` function is called when all matches succeed. Built-in targets (`ACCEPT`, `DROP`, `RETURN`, `QUEUE`) return a netfilter verdict. Extension targets (`DNAT`, `LOG`, `MARK`) may modify the packet and then return a verdict.

If the target is a **jump** (`-j USERCHAIN`), the evaluator pushes the current position onto a stack and starts scanning the user chain. A `RETURN` target pops the stack and resumes at the rule after the jump. This gives iptables its chain-call tree structure.

If the evaluator reaches the end of a chain without a terminal verdict, it applies the **policy** — the default target (ACCEPT or DROP) set by `iptables -P`.

### Tables and Hook Points

| Table | Hook Points | Purpose |
|-------|-------------|---------|
| `raw` | PREROUTING, OUTPUT | First table, before conntrack; used for `NOTRACK` exemptions |
| `mangle` | All five | Packet marking (MARK, TOS, TTL modification) |
| `nat` | PREROUTING, INPUT, OUTPUT, POSTROUTING | Address rewriting (DNAT, SNAT, MASQUERADE, REDIRECT) |
| `filter` | INPUT, FORWARD, OUTPUT | Primary allow/deny decisions |
| `security` | INPUT, FORWARD, OUTPUT | SELinux SECMARK labeling |

Tables at the same hook point run in the order listed above, controlled by their registered `priority` values.

### Atomic Updates

Userspace modifies rules via `setsockopt(SOX_RAW, IPT_SO_SET_REPLACE)`, passing a complete new rule blob. The kernel validates the blob's integrity, then swaps the old blob for the new one under a per-table spinlock. In-flight calls to `ipt_do_table()` may be running against the old blob concurrently — the kernel uses a reference count (`xt_table.use`) to defer freeing the old blob until all in-flight evaluations complete.

This **full-replace model** is the key weakness of iptables: even adding one rule requires marshalling the entire ruleset to userspace, modifying it, and uploading the complete new blob. On firewalls with thousands of rules this can create a multi-second window where a new packet sees a partially-applied state if the process is interrupted — a significant motivation for nftables' atomic transaction model.

## Key Data Structures

**`struct ipt_entry`** (`include/uapi/linux/netfilter_ipv4/ip_tables.h`) — one rule in the chain blob
- `ip` — `struct ipt_ip`: src/dst addr+mask, in/out ifname, protocol, flags
- `nfcache` — cache validity flags (tells netfilter which header fields this rule references)
- `target_offset` — byte offset from start of entry to the `xt_entry_target`
- `next_offset` — byte offset to the next `ipt_entry` (entries are variable-length)
- `comefrom` — used for loop detection during rule validation
- `counters` — 64-bit packet and byte match counters

**`struct xt_table`** (`include/linux/netfilter/x_tables.h`) — in-kernel table descriptor
- `valid_hooks` — bitmask of hook points this table operates at
- `private` — `struct xt_table_info *`: points to the current live rule blob
- `af` — address family (AF_INET for iptables, AF_INET6 for ip6tables)

**`struct xt_entry_match`** (`include/uapi/linux/netfilter/x_tables.h`) — match extension header
- `match_size` — total size including trailing data
- `name` — ASCII name used to find the `xt_match` struct at load time
- `revision` — allows multiple ABI versions of the same match extension

## Key Functions / Entry Points

**`ipt_do_table()`** (`net/ipv4/netfilter/ip_tables.c`) — main hook callback; iterates the chain blob calling match extensions and targets

**`ipt_register_table()`** — registers a table with the netfilter hook framework for a given network namespace; installs `ipt_do_table` as the callback for all of the table's hook points

**`ip_packet_match()`** — checks the basic `ipt_ip` header criteria against the current packet; fast-path rejection before invoking extension matches

**`xt_register_match()`** / **`xt_register_target()`** (`net/netfilter/x_tables.c`) — register match and target extensions (called from extension module init functions)

## Important Flags & Config Options

- `CONFIG_IP_NF_IPTABLES` — base iptables support (required for all tables)
- `CONFIG_IP_NF_FILTER` — filter table (INPUT/FORWARD/OUTPUT)
- `CONFIG_IP_NF_NAT` — nat table (DNAT/SNAT/MASQUERADE/REDIRECT targets)
- `CONFIG_IP_NF_MANGLE` — mangle table
- `CONFIG_IP_NF_RAW` — raw table (enables NOTRACK/CT targets)
- `CONFIG_IP_NF_SECURITY` — security table for SELinux SECMARK

## Interactions with Other Subsystems

- **↑ Userspace**: `libiptc` (used by the `iptables` command) issues `getsockopt`/`setsockopt` on a raw IPv4 socket to read and replace the rule blob; `iptables-restore` pipelines full-blob replacement for batch updates
- **→ [[netfilter-hook-framework]]**: iptables registers `ipt_do_table` as its hook callback; the framework calls it in priority order among all registered hooks
- **→ [[connection-tracking]]**: the `xt_conntrack` match extension reads `nf_conn` state from `skb->_nfct`; the `CT` target in the raw table calls `nf_ct_set_notrack()` to exempt packets from tracking
- **→ [[netfilter-nat]]**: the nat table's DNAT/SNAT targets call into `nf_nat_setup_info()` to store rewrite parameters in the `nf_conn`

## Design Decisions & Tradeoffs

**Linear chain scan** — iptables evaluates rules sequentially, giving O(n) cost per packet. This was acceptable for small rulesets but becomes a bottleneck at scale (thousands of rules, millions of packets/second). The `ipset` extension was later developed to allow set lookups within iptables, but it required an external tool and separate kernel module.

**Protocol-specific tools** — Because iptables is IPv4-only, separate tools (`ip6tables`, `arptables`, `ebtables`) were developed for other protocol families. Each is a near-copy of the iptables code, creating a maintenance burden. nftables solved this with a single unified kernel module.

**Full-replace updates** — The decision to replace the entire rule blob atomically (rather than per-rule) simplified the kernel-side data structure (a flat byte array) but created userspace complexity and update latency for large rulesets.

## How It Has Evolved

- **Linux 2.4 (2001)**: iptables replaces ipchains; introduces the table/chain/target architecture and match extensions
- **Linux 2.6 (2003)**: `x_tables` shared infrastructure extracted so IPv4 and IPv6 firewalling can share match/target extensions
- **Linux 3.13 (2014)**: nftables merged as the intended long-term replacement
- **iptables-nft (~2018)**: The `iptables` userspace command gained an `iptables-nft` backend that translates iptables syntax into nftables VM bytecode, enabling gradual migration
- **Current status**: iptables kernel modules receive security fixes but few new features; major distributions default to nftables with iptables-nft compatibility

## Further Reading

1. [Nftables reaches 1.0 (LWN, 2021)](https://lwn.net/Articles/867185/) — marks the transition and discusses iptables' trajectory
2. [nftables vs iptables (kernel-internals.org)](https://kernel-internals.org/net/nftables-iptables/) — architectural comparison
3. `net/ipv4/netfilter/ip_tables.c` — kernel-side rule evaluation and table management
4. `net/netfilter/x_tables.c` — shared extension registration infrastructure

## LKML Highlights

- The original iptables submission (Rusty Russell, ~2000) argued that the table/chain model made complex firewalling policies expressible without needing kernel changes for each new policy type — only new match/target modules.
- A recurring LKML debate in the 2010s concerned whether iptables' O(n) scan was a fundamental problem or merely a configuration one; the consensus was that it was fundamental for large rulesets, which ultimately drove nftables adoption.
