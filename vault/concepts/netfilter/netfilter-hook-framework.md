---
title: "Netfilter Hook Framework"
category: concept
tags: [netfilter, hooks, packet-filtering, kernel-networking, nf_hook_ops]
subsystem: netfilter
kernel_version: "2.4"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/net/netfilter/
  - https://lwn.net/Articles/564095/
  - https://wiki.nftables.org/wiki-nftables/index.php/Portal:DeveloperDocs/nftables_internals
---

# Netfilter Hook Framework

## Purpose

The hook framework is the structural backbone of netfilter: it defines five fixed interception points in the IP packet path and provides a registration API that lets any kernel module install callbacks at those points. Without it, every firewall or NAT module would have to patch itself into the network stack directly — creating tight coupling and ordering conflicts. The hook framework decouples packet-path interception from policy, enabling iptables, nftables, conntrack, and SELinux to coexist without knowing about each other.

## Mental Model

Think of the hook framework as a **priority queue of security gates** installed at five highway on-ramps. The highway is the kernel's IP forwarding code. At five specific junctions — before routing, after routing for local delivery, at the forwarding crossroad, after a local socket generates a packet, and just before transmission — every packet is held and run through all installed gates in priority order. A single gate saying "rejected" is enough to discard the packet. All gates must say "pass" for the packet to continue.

## How It Works

The story begins when a module (say, the nftables filter) calls `nf_register_net_hooks()` at module load time. It passes a pointer to a `struct net` (the network namespace) and an array of `struct nf_hook_ops`:

```c
struct nf_hook_ops {
    nf_hookfn       *hook;       /* callback */
    struct net_device *dev;      /* device filter, or NULL for all */
    void            *priv;       /* passed to hook() as first arg */
    u8               pf;         /* protocol family: NFPROTO_IPV4 / IPV6 / ARP … */
    unsigned int     hooknum;    /* NF_INET_PRE_ROUTING … NF_INET_POST_ROUTING */
    int              priority;   /* lower = earlier; conntrack at −200 */
};
```

Inside `nf_register_net_hooks()` (`net/netfilter/core.c`), the kernel builds or rebuilds the `struct nf_hook_entries` array for the affected hook point. This array stores callbacks sorted ascending by `priority`. Sorting at registration time means the hot path — hook invocation — is a simple linear scan without any sorting overhead.

The actual invocation happens via the `NF_HOOK()` macro, which is embedded directly in the network stack at each of the five hook points:

- `net/ipv4/ip_input.c:ip_rcv()` → `NF_HOOK(NFPROTO_IPV4, NF_INET_PRE_ROUTING, ...)`
- `net/ipv4/ip_input.c:ip_local_deliver()` → `NF_HOOK(..., NF_INET_LOCAL_IN, ...)`
- `net/ipv4/ip_forward.c:ip_forward()` → `NF_HOOK(..., NF_INET_FORWARD, ...)`
- `net/ipv4/ip_output.c:__ip_local_out()` → `NF_HOOK(..., NF_INET_LOCAL_OUT, ...)`
- `net/ipv4/ip_output.c:ip_output()` → `NF_HOOK(..., NF_INET_POST_ROUTING, ...)`

`NF_HOOK()` first checks whether any hooks are registered for this family and hook point. If the `nf_hook_entries` pointer is NULL (no hooks), it falls through immediately to the continuation function — this is the **fast path** and has essentially zero cost. If hooks exist, it calls `nf_hook_slow()`, which iterates the sorted array:

```c
/* Simplified */
for each hook_entry in nf_hook_entries {
    verdict = hook_entry->hook(priv, skb, state);
    if (verdict != NF_ACCEPT) {
        /* NF_DROP: free skb; NF_QUEUE: send to userspace; NF_STOLEN: leave alone */
        return verdict;
    }
}
/* All NF_ACCEPT — continue to next stack stage */
```

The `state` argument carries per-packet context (`struct nf_hook_state`): ingress and egress net devices, the network namespace, the socket (if any), and a `okfn` continuation function pointer that `NF_HOOK()` calls after all hooks return `NF_ACCEPT`.

**Unregistration** uses `nf_unregister_net_hooks()`, which rebuilds the sorted array under RCU. The old array is freed after an RCU grace period, ensuring in-flight packet processing against the old array completes before memory is reclaimed. Hooks never see a torn-down array.

## Key Data Structures

**`struct nf_hook_ops`** (`include/linux/netfilter.h`) — describes a single hook registration
- `hook` — callback function; returns a verdict (`NF_ACCEPT`, `NF_DROP`, `NF_QUEUE`, `NF_STOLEN`, `NF_REPEAT`)
- `pf` — protocol family; `NFPROTO_IPV4=2`, `NFPROTO_IPV6=10`, `NFPROTO_ARP=3`, `NFPROTO_NETDEV=5`
- `hooknum` — which hook point: `NF_INET_PRE_ROUTING=0`, `NF_INET_LOCAL_IN=1`, `NF_INET_FORWARD=2`, `NF_INET_LOCAL_OUT=3`, `NF_INET_POST_ROUTING=4`
- `priority` — execution order within hook point; standard values: `NF_IP_PRI_CONNTRACK_DEFRAG=-400`, `NF_IP_PRI_CONNTRACK=-200`, `NF_IP_PRI_FILTER=0`, `NF_IP_PRI_NAT_SRC=100`

**`struct nf_hook_entries`** (`include/linux/netfilter.h`) — the live sorted array of hooks for one hook point
- `num_hook_entries` — count of entries
- `hooks[]` — array of `nf_hook_entry` (hook + priv), sorted by priority
- `orig_ops[]` — parallel array of `nf_hook_ops *` pointers (for deregistration)

**`struct nf_hook_state`** (`include/linux/netfilter.h`) — per-packet context passed to every callback
- `hook` — the hook number (redundant but convenient inside deeply nested code)
- `pf` — protocol family
- `in` / `out` — ingress / egress `struct net_device *`
- `sk` — the socket, if packet is associated with one
- `net` — the network namespace
- `okfn` — continuation: called after all hooks return `NF_ACCEPT`

## Key Functions / Entry Points

**`nf_register_net_hooks()`** (`net/netfilter/core.c`) — registers an array of `nf_hook_ops` for a network namespace; rebuilds the sorted `nf_hook_entries` array

**`nf_unregister_net_hooks()`** — removes hooks and frees the old array after RCU grace period

**`nf_hook_slow()`** (`net/netfilter/core.c`) — iterates the sorted hook entries and calls each callback; returns the first non-ACCEPT verdict or invokes `okfn` if all accept

**`NF_HOOK()` macro** (`include/linux/netfilter.h`) — the callsite embedded in the network stack; fast-paths to `okfn` if no hooks registered, otherwise calls `nf_hook_slow()`

## Important Flags & Config Options

- `CONFIG_NETFILTER` — master switch; enables the hook framework and all netfilter modules
- `CONFIG_NETFILTER_ADVANCED` — unlocks more advanced match/target Kconfig options
- Priority constants (`NF_IP_PRI_*`) defined in `include/uapi/linux/netfilter_ipv4.h`; custom modules must choose priorities that place them correctly relative to conntrack and filter

## Interactions with Other Subsystems

- **↑ Userspace**: Userspace modules (nfnetlink, iptables, nft) register hooks indirectly through their kernel counterparts; the hook framework has no direct syscall interface
- **→ [[net]]**: Hook invocation sites are scattered through `net/ipv4/`, `net/ipv6/`, `net/bridge/`; the IP stack owns the `NF_HOOK()` call sites
- **→ [[bpf]]**: TC BPF and XDP run outside netfilter hook points; however, since kernel 5.13 BPF programs can be registered *as* netfilter hooks via `CONFIG_NETFILTER_BPF_HOOK`

## Design Decisions & Tradeoffs

**Sorted array vs. linked list** — Early netfilter used a linked list for hooks. The switch to a sorted array at registration time moved the O(n log n) sort cost off the hot packet path and made cache behavior more predictable during iteration.

**RCU for unregistration** — Hook removal could momentarily race with in-flight packet processing. Using RCU (rebuild array, publish pointer, wait for grace period before freeing old array) makes removal safe without stopping packet processing.

**Five fixed hook points** — The five `NF_INET_*` points were chosen to bracket all meaningful network decisions (before routing, after routing for local/forward split, before egress). Anything earlier (e.g., raw driver receive) is handled by XDP; anything more granular requires application-layer inspection that the hook framework delegates to conntrack helpers.

## How It Has Evolved

- **Linux 2.4** — Netfilter hooks introduced, replacing the ipchains mechanism
- **Linux 2.6.20** — Hooks gained network namespace awareness (`struct net` parameter)
- **Linux 4.14** — `nf_hook_entries` sorted array replaces the older linked list, improving cache efficiency on multi-hook configurations
- **Linux 5.13** — BPF programs can register as first-class netfilter hooks

## Further Reading

1. [The return of nftables (LWN, 2013)](https://lwn.net/Articles/564095/) — discusses hook registration in the context of the nftables VM design
2. [nftables internals wiki](https://wiki.nftables.org/wiki-nftables/index.php/Portal:DeveloperDocs/nftables_internals) — developer documentation on base chains and hook attachment
3. `include/linux/netfilter.h` — primary header for hook types and `NF_HOOK()` macro
4. `net/netfilter/core.c` — hook registration, deregistration, and `nf_hook_slow()`

## LKML Highlights

- The original netfilter submission by Rusty Russell (2000) framed the hook framework as the minimal "plumbing" that every firewall module could share, arguing that the alternative (each firewall patching its own callsites into the stack) was unmaintainable.
- A 2017 thread on improving hook iteration performance led to the sorted-array refactor in 4.14, replacing linked-list traversal with a cache-friendly array scan.
