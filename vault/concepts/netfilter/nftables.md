---
title: "nftables"
category: concept
tags: [netfilter, nftables, firewall, packet-filtering, virtual-machine, sets, atomic-updates]
subsystem: netfilter
kernel_version: "3.13"
researched: 2026-04-13
status: complete
explained: "[[nftables-explained]]"
sources:
  - https://kernel-internals.org/net/nftables-iptables/
  - https://kernel-internals.org/net/netfilter/
  - https://lwn.net/Articles/564095/
  - https://lwn.net/Articles/867185/
  - https://wiki.nftables.org/wiki-nftables/index.php/Portal:DeveloperDocs/nftables_internals
---

# nftables

> 📘 Plain-language version: [[nftables-explained]]

## Purpose

nftables is the modern Linux packet-filtering framework that replaces the fragmented iptables/ip6tables/arptables/ebtables family with a single unified kernel module (`nf_tables`) and a bytecode virtual machine. It solves iptables' three critical weaknesses: protocol fragmentation (one tool per address family), O(n) linear rule evaluation (no native set matching), and non-atomic rule updates (full-blob replacement with a race window).

## Mental Model

Where iptables hard-codes protocol knowledge into kernel modules (each match extension understands TCP headers or IP addresses), nftables treats the kernel as a **dumb bytecode interpreter**: it knows only how to load bytes from a packet, apply arithmetic, compare values, look up tables, and emit a verdict. All the intelligence — what to load, how to compare, what constitutes a port range — is encoded in bytecode compiled by the userspace `nft` tool and sent to the kernel. This separation means new protocol support needs no kernel patch, only new expression types in the userspace compiler.

## How It Works

### Tables, Chains, Rules, and Expressions

The nftables data model has four levels:

1. **Table** — a namespace scoped to an address family (`ip`, `ip6`, `inet`, `arp`, `bridge`, `netdev`). Tables have no policy; they just group chains.

2. **Base chain** — attaches to a netfilter hook point with a specified hook number, priority, and policy (accept/drop). Installing a base chain causes `nf_tables` to register an `nf_hook_ops` callback with the hook framework. **Regular chains** have no hook attachment and are only reachable by `jump`/`goto` from other chains.

3. **Rule** — a sequence of **expressions** stored as an inline byte array in the rule. Each expression is a `struct nft_expr` with an ops pointer:
   - `nft_expr_ops.eval()` — called during packet evaluation; reads/writes VM registers
   - `nft_expr_ops.init()` — called at rule creation to validate and serialise the expression data

4. **Expression** — the atomic unit of the VM. Examples:
   - `nft_payload` — loads N bytes from a packet offset (L2/L3/L4/raw) into a register
   - `nft_cmp` — compares a register value against a constant; aborts the rule if not equal
   - `nft_lookup` — looks up a register value in a named set; updates a verdict register or writes mapped data
   - `nft_counter` — increments a packet/byte counter
   - `nft_verdict` — emits a final verdict (`accept`, `drop`, `jump`, `goto`, `return`, `continue`)

### The nftables VM Execution Loop

When a packet arrives at a base chain's hook callback (`nf_tables_ipv4_input()` etc.), it calls `nft_do_chain()`:

```c
/* net/netfilter/nf_tables_core.c (simplified) */
unsigned int nft_do_chain(struct nft_pktinfo *pkt, void *priv)
{
    struct nft_regs regs = {};    /* 16 × 16-byte general-purpose registers */
    
    list_for_each_entry_rcu(rule, &chain->rules, list) {
        nft_rule_for_each_expr(expr, last, rule) {
            expr->ops->eval(expr, &regs, pkt);
            if (regs.verdict.code != NFT_CONTINUE)
                goto done;
        }
    }
done:
    return regs.verdict.code;
}
```

The VM has 16 general-purpose registers (each 16 bytes wide, matching IPv6 address size). Expressions read from and write to these registers. A `cmp` expression that finds a mismatch writes `NFT_BREAK` to the verdict register, causing the loop to skip to the next rule. A `verdict` expression writing `NF_DROP` causes the chain to return immediately.

### Sets and Maps

Sets are the killer feature of nftables. An `nft_set` stores a collection of elements and is queried by the `nft_lookup` expression in O(1) (hash) or O(log n) (rbtree/pipapo). Available backends:

| Backend | Use Case | Complexity |
|---------|----------|------------|
| `nft_hash` | Exact match, unordered | O(1) |
| `nft_rbtree` | Ordered ranges, intervals | O(log n) |
| `nft_bitmap` | Port sets (small integers) | O(1) |
| `nft_pipapo` | Concatenated field matching (IP+port) | O(field count) |

A **map** extends a set: each element maps to a verdict or data value. `nft_lookup` can write the mapped value into a register, enabling per-IP rate limits, per-service routing, or per-connection state in a single lookup.

### Atomic Transactions

All rule modifications go through `nf_tables_commit()`. Userspace assembles changes as a batch of netlink messages (`NFTA_*` attributes) and sends them in one `sendmsg()`. The kernel processes the batch, validates each operation, and either commits the entire batch atomically or rejects it. Atomicity is implemented via a **generation counter**: rules carry a generation bitmask, and the kernel flips the active generation at commit time. In-flight packets see the old generation until the flip; new packets after the flip see the new generation.

## Key Data Structures

**`struct nft_rule`** (`include/net/netfilter/nf_tables.h`)
- `list` — RCU list node linking the rule into its chain
- `handle` — unique 64-bit ID; used in update/delete operations to identify a specific rule
- `genmask` — 2-bit generation mask controlling rule visibility during atomic commits
- `dlen` — byte length of the inline expression data
- `data[]` — serialised `nft_expr` records forming the VM program for this rule

**`struct nft_expr`** (`include/net/netfilter/nf_tables.h`) — one VM expression
- `ops` — `struct nft_expr_ops *`: vtable with `eval()`, `init()`, `dump()`, `destroy()`
- `data[]` — expression-specific data (e.g., for `nft_payload`: offset, length, destination register)

**`struct nft_set`** (`include/net/netfilter/nf_tables.h`)
- `ops` — backend operations (hash, rbtree, bitmap, pipapo)
- `ktype` — key data type descriptor (determines comparison and hashing)
- `dtype` — value/data type descriptor (for maps)
- `timeout` — default element expiry (0 = persistent)
- `gc_seq` — garbage collection sequence for timed elements

**`struct nft_regs`** (`include/net/netfilter/nf_tables.h`) — the VM register file
- `verdict` — `struct nft_verdict`: current chain verdict, updated by expressions
- `data[]` — array of 16 `nft_data` (each 16 bytes) for general-purpose use

## Key Functions / Entry Points

**`nft_do_chain()`** (`net/netfilter/nf_tables_core.c`) — main VM evaluation loop; iterates rules and their expressions

**`nf_tables_commit()`** (`net/netfilter/nf_tables_api.c`) — applies a complete transaction atomically; flips the generation counter after validation

**`nft_lookup_eval()`** — evaluates a set lookup expression; performs the backend-specific search and writes result to register

**`nf_tables_newchain()`** / **`nf_tables_newrule()`** — netlink handlers for creating chains and rules within a transaction

## Important Flags & Config Options

- `CONFIG_NF_TABLES` — enables the nf_tables kernel module
- `CONFIG_NF_TABLES_INET` — `inet` family: unified IPv4+IPv6 tables in one ruleset
- `CONFIG_NF_TABLES_NETDEV` — `netdev` family: hook at ingress/egress of a specific device
- `CONFIG_NFT_SET_HASH` / `CONFIG_NFT_SET_RBTREE` / `CONFIG_NFT_SET_PIPAPO` — set backend modules
- `CONFIG_NFT_COUNTER` / `CONFIG_NFT_CT` / `CONFIG_NFT_NAT` — expression/module enables

## Interactions with Other Subsystems

- **↑ Userspace**: `nft` tool communicates via the `nfnetlink` subsystem (NETLINK_NETFILTER); the kernel's `nf_tables_api.c` handles `NFNL_SUBSYS_NFTABLES` messages
- **→ [[netfilter-hook-framework]]**: base chains register `nf_hook_ops` at creation; the hook framework calls `nft_do_chain()` for every packet at the hook point
- **→ [[connection-tracking]]**: the `nft_ct` expression reads and writes conntrack state from `skb->_nfct`; nftables can match on `ct state`, `ct mark`, `ct label`, and `ct zone`
- **→ [[netfilter-nat]]**: the `nft_nat` expression calls `nf_nat_setup_info()` to configure address rewriting on the `nf_conn`
- **→ [[netfilter-flowtable]]**: the `flow add @flowtable_name` nftables statement triggers `nf_flow_table_offload_add_cb()` to offload an established flow

## Design Decisions & Tradeoffs

**VM over native C** — The concern at design time was that a bytecode interpreter would be slower than iptables' native C match extensions. In practice nftables performs comparably or better because set lookups replace long linear chains of individual rules — the O(1) set lookup amortises the interpreter overhead.

**Userspace compilation** — Keeping all protocol knowledge in userspace (the `nft` compiler) means the kernel module is stable and rarely needs to change. The downside is that rule complexity is bounded by what the `nft` tool can express; very unusual packet-processing logic may require writing a custom expression module.

**Generation counter for atomicity** — Using a per-rule 2-bit generation mask (rather than per-chain or per-table) allows in-flight packets to complete using old rules while new rules become visible atomically. The cost is a bit-check per rule evaluation and careful generation management in the commit path.

**Pipapo for concatenated fields** — Classic approaches (hash on single fields, rbtree for ranges) cannot efficiently match `(src_ip ∈ prefix_set) AND (dst_port ∈ port_range)` in a single lookup. The pipapo (Piece-wise Independent Optimised Packet Processing) algorithm represents concatenated-field sets as a sequence of bit-vector stages, achieving near-O(1) for common patterns while supporting arbitrary combinations.

## How It Has Evolved

- **Linux 3.13 (2014)**: Initial merge; `inet` family, basic expressions, hash sets
- **Linux 4.1 (2015)**: rbtree and interval set support; element timeout
- **Linux 4.16 (2018)**: `netdev` family ingress/egress hooks; dynamic set updates from rules
- **Linux 5.6 (2020)**: Pipapo set backend for concatenated-field matching
- **Linux 5.13 (2021)**: BPF programs loadable as nftables base chain callbacks
- **Linux 6.4 (2023)**: Parallel chain evaluation for independent rule groups

## Further Reading

1. [The return of nftables (LWN, 2013)](https://lwn.net/Articles/564095/) — best explanation of the VM design philosophy
2. [Nftables reaches 1.0 (LWN, 2021)](https://lwn.net/Articles/867185/) — production milestone and iptables transition
3. [nftables Developer Internals Wiki](https://wiki.nftables.org/wiki-nftables/index.php/Portal:DeveloperDocs/nftables_internals) — expression bytecode format and set backend internals
4. `net/netfilter/nf_tables_core.c` — `nft_do_chain()`, the VM evaluation loop
5. `net/netfilter/nf_tables_api.c` — transaction commit, netlink handlers

## LKML Highlights

- Pablo Neira Ayuso's initial nf_tables RFC (2013) was debated heavily on whether the VM approach was over-engineering; the counter-argument that unified protocol handling and atomic updates justified the complexity eventually prevailed.
- The pipapo set backend patchset (2020) included detailed benchmarks showing that concatenated-field matching in large IP+port sets was orders of magnitude faster than equivalent iptables ipset configurations.
