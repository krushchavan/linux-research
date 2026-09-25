---
title: "IP Routing & FIB"
category: concept
tags: [networking, routing, fib, ip-forwarding, policy-routing, ecmp]
subsystem: net
kernel_version: "2.6"
researched: 2026-04-14
status: complete
explained: "[[ip-routing-explained]]"
sources:
  - https://kernel-internals.org/net/ip-routing/
  - https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html
---

# IP Routing & FIB

> 📘 Plain-language version: [[ip-routing-explained]]

## Purpose

The IP routing subsystem answers one question for every packet: where does it go next? The answer is: deliver to a local socket, forward to another host via a specific output device and next-hop gateway, or discard as unreachable. The Forwarding Information Base (FIB) stores the routing table as an LC-trie optimised for longest-prefix match lookups, and the routing cache (`dst_entry`) stores the per-packet result so the decision travels with the packet through the stack.

## Mental Model

The FIB is a **postal sorting machine**. A packet's destination IP address is the ZIP code. The machine has a tree of bins organised from the most-specific prefix (longest ZIP code prefix) down to the default route (the universal catch-all bin). The machine finds the deepest matching bin in O(log N / log log N) time. The result (`dst_entry`) is a pre-stamped routing label that names the output chute and the next-stop address — the packet carries this label through the rest of the stack without re-consulting the sorting machine.

## How It Works

**The receive entry point.** On the ingress path, `ip_rcv()` (`net/ipv4/ip_input.c`) validates the IP header (version, header length, checksum, TTL). It then calls `NF_HOOK(NF_INET_PRE_ROUTING)` — netfilter runs DNAT here, potentially rewriting the destination address. After the hook, `ip_rcv_finish()` calls `ip_route_input_noref(skb, daddr, saddr, tos, dev)` to perform the route lookup.

**FIB lookup.** `ip_route_input_noref()` calls `fib_lookup(net, &fl4, &res, 0)`. The `fl4` (flow4) struct summarises the lookup key: source address, destination address, TOS, input interface mark. `fib_lookup()` evaluates the FIB rules list first: each rule (`struct fib_rule`) matches on one or more of {source address, destination address, incoming interface, fwmark, TOS} and selects a routing table number. Most systems have a single default rule pointing to `RT_TABLE_MAIN` (table 254), so `fib_lookup()` goes directly to the main table.

Inside the selected table, the FIB trie walk (`fib_table_lookup()` in `net/ipv4/fib_trie.c`) does a bitwise walk of the destination address through the LC-trie until it reaches a leaf node (`fib_leaf`). Each leaf contains one or more `fib_alias` structs, each representing a route entry with matching TOS and scope. The first matching alias's `fib_info` gives the next-hop(s): output device (`nh_dev`), gateway (`nh_gw`), and flags.

**Result: `dst_entry` and `rtable`.** From the `fib_result`, `ip_mkroute_input()` constructs an `rtable` (the IPv4 flavour of `dst_entry`) and attaches it to the skb via `skb_dst_set(skb, &rt->dst)`. The `dst_entry.input` function pointer is set to the appropriate handler:
- Local delivery → `ip_local_deliver()`
- Forward → `ip_forward()`
- Broadcast/multicast → `ip_mr_input()` or `ip_local_deliver()`
- Black-hole → `dst_discard()` / `dst_blackhole()`

Subsequent stages call `dst_input(skb)` (which dispatches via `skb->dst->input`) without another lookup.

**Forwarding path.** `ip_forward()` decrements TTL (sends ICMP Time Exceeded and drops if TTL hits zero), updates the IP header checksum incrementally, calls `NF_HOOK(NF_INET_FORWARD)`, then calls `ip_output()`. `ip_finish_output()` fragments the packet if `skb->len > dst_mtu(skb->dst)`, then calls `neigh_output()` — the ARP/neighbour subsystem resolves the next-hop gateway IP to a MAC address and fills the L2 header.

**Policy routing.** `CONFIG_IP_MULTIPLE_TABLES` enables up to 255 routing tables (numbered 1–255 plus the special tables: 253 default, 254 main, 255 local). The FIB rules list (`net->ipv4.rules_ops`) is a sorted linked list evaluated left-to-right for each lookup. A rule's `fib_rule_match()` tests the packet's attributes; the first matching rule's `table` number is used. This enables split-horizon DNS routing, VPN routing policies, and multi-homed server configurations.

**ECMP (Equal-Cost Multipath).** When multiple routes have equal metrics to the same destination, the FIB stores them as multiple nexthops under a single `fib_info`. `fib_select_multipath()` hashes the flow (src IP, dst IP, protocol, and optionally ports) to deterministically pick one nexthop for each flow. This distributes load without per-packet reordering within a flow.

**IPv6 routing** follows the same structure but uses `fib6_table` (an rbtree rather than an LC-trie) and `rt6_info` as the dst_entry subtype. IPv6 FIB lookups go through `ip6_route_input()`.

**ARP and neighbour resolution.** The `neigh_output()` call at the end of forwarding consults the neighbour cache (`struct neighbour`, keyed by next-hop IP and output device). If an entry exists and is in state `NUD_REACHABLE` or `NUD_STALE`, it copies the cached L2 address into the skb and calls `dev_queue_xmit()`. On a cache miss, `neigh_create()` allocates a new neighbour in state `NUD_INCOMPLETE`, queues the packet, and sends an ARP request. ARP reply triggers `neigh_update()` → `NUD_REACHABLE` and flushes the queued packet.

## Key Data Structures

**`struct dst_entry`** (`include/net/dst.h`) — the cached routing result that travels with the skb.
- `input` / `output` — function pointers for receive/transmit processing (set once during lookup; dispatched by `dst_input()`/`dst_output()`)
- `dev` — output `net_device`
- `ops` — `struct dst_ops *`: protocol-specific GC and check; different for IPv4 (`ipv4_dst_ops`) and IPv6 (`ip6_dst_ops`)
- `expires` — jiffies-based expiry for route cache invalidation

**`struct rtable`** (`include/net/route.h`) — IPv4 extension of `dst_entry`.
- `rt_gateway` — next-hop IPv4 address (0 = directly connected, deliver via ARP)
- `rt_iif` — input interface index (for reverse path filtering and RPDB lookups)
- `rt_flags` — `RTCF_LOCAL`, `RTCF_BROADCAST`, `RTCF_MULTICAST`, `RTCF_DOREDIRECT`

**`struct fib_result`** (`include/net/ip_fib.h`) — the output of a FIB table lookup.
- `type` — route type: `RTN_UNICAST`, `RTN_LOCAL`, `RTN_BROADCAST`, `RTN_BLACKHOLE`, etc.
- `fi` — `struct fib_info *`: next-hop information
- `table` — which FIB table matched

**`struct fib_nh`** (`include/net/ip_fib.h`) — one nexthop within a `fib_info`.
- `fib_nh_dev` — output device
- `fib_nh_gw4` — gateway address (IPv4)
- `fib_nh_weight` — ECMP weight (for unequal-cost multipath)

## Key Functions / Entry Points

**`ip_route_input_noref()`** (`net/ipv4/route.c`) — ingress route lookup; sets `skb->_skb_refdst`.

**`fib_lookup()`** (`include/net/ip_fib.h`) — consults FIB rules and tables; returns `fib_result`.

**`fib_table_lookup()`** (`net/ipv4/fib_trie.c`) — LC-trie walk for longest-prefix match within one table.

**`ip_forward()`** (`net/ipv4/ip_forward.c`) — forwarding fast path: TTL decrement, fragmentation check, netfilter FORWARD hook.

**`ip_route_output_flow()`** (`net/ipv4/route.c`) — egress route lookup for locally originated packets; called by TCP/UDP when sending.

**`__neigh_lookup()`** (`net/core/neighbour.c`) — neighbour cache lookup; creates entry on miss and triggers ARP.

## Important Flags & Config Options

- `/proc/sys/net/ipv4/ip_forward` — global IP forwarding enable (also settable per-interface via `conf/<dev>/forwarding`)
- `/proc/sys/net/ipv4/conf/<dev>/rp_filter` — reverse path filtering: 0=off, 1=strict, 2=loose; drops packets whose source address is not reachable via the ingress interface
- `/proc/sys/net/ipv4/conf/<dev>/accept_local` — accept packets with source addresses from local interface
- `CONFIG_IP_MULTIPLE_TABLES` — enable policy routing (FIB rules)
- `CONFIG_IP_ROUTE_MULTIPATH` — enable ECMP
- `ip rule add fwmark 0x1 lookup 100` — add a policy routing rule; packets with mark 1 use table 100
- `ip route add default nexthop via 1.2.3.4 weight 1 nexthop via 5.6.7.8 weight 1` — ECMP default route

## Interactions with Other Subsystems

- **↑ Userspace**: `ip route` and `ip rule` commands communicate via `RTNETLINK` netlink; the kernel calls `fib_dump_table()` for `RTM_GETROUTE` dumps
- **→ [[netfilter]]**: `NF_HOOK(NF_INET_PRE_ROUTING)` runs before the routing decision; DNAT may change the destination, so the route lookup sees the post-NAT address
- **→ [[network-device-and-napi]]**: forwarded packets call `dev_queue_xmit()` on the output device; `neigh_output()` resolves the L2 header
- **← [[network-namespaces]]**: each namespace has independent FIB tables (`net->ipv4.fib_main`); `fib_lookup()` takes `net *` as its first argument

## Design Decisions & Tradeoffs

**LC-trie over hash table** — The LC-trie (Level Compressed trie, also called Patricia trie) provides O(1) amortised longest-prefix match, which is what routing requires. A hash table can only do exact matches, not prefix matches. The tradeoff is trie rebalancing on route updates (more expensive than hash insert), but routing table changes are rare relative to the per-packet lookup frequency.

**Route cache removal (3.6)** — Before 3.6, the kernel maintained a per-flow route cache (keyed by src IP, dst IP, TOS, etc.) to avoid FIB lookups on every packet. The cache became a DoS vector (hash collision attacks) and a memory hog under many-flow workloads. After 3.6, every packet does a FIB trie walk. The LC-trie is fast enough (typically 10–50 ns on modern CPUs) that the cache is not missed.

**`dst_entry` function pointers** — Setting `dst->input` to the appropriate handler during lookup avoids a per-packet conditional ("is this local or forwarded?"). The tradeoff is that a NULL or stale `dst_entry` (after route invalidation via `rt_cache_flush()`) must be detected before dispatch.

## How It Has Evolved

| Version | Change |
|---------|--------|
| 2.1 (1996) | Policy routing and multiple tables added (`ip rule`) |
| 2.6.39 (2011) | FIB trie replaced hash-based routing table completely |
| 3.6 (2012) | Per-flow route cache removed; trie walk per packet |
| 4.4 (2016) | Multipath nexthop hashing extended to include L4 ports (avoiding per-flow reordering) |
| 5.2 (2019) | Nexthop objects (`ip nexthop`) abstracted as first-class kernel objects for ECMP and resilient hashing |
| 5.10 (2020) | Resilient ECMP: rebalances nexthop buckets on failure without remapping unaffected flows |

## Further Reading

1. [kernel.org: ip-sysctl reference](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html) — comprehensive sysctl documentation for routing and forwarding
2. [kernel-internals.org: IP Routing](https://kernel-internals.org/net/ip-routing/) — LC-trie design, policy routing, and neighbour resolution
3. *Understanding Linux Network Internals* (Benvenuti) — Chapters 30–36 cover FIB, routing cache, and neighbour

## LKML Highlights

- **Route cache removal (2012)**: Eric Dumazet's series removed the ipv4 route cache entirely. The original motivation was a DoS attack where crafted source IPs could fill the cache. The series demonstrated that the LC-trie walk was fast enough to replace cache hits on modern CPUs, and that the cache's false sharing and lock contention hurt NUMA systems more than it helped.
- **Resilient ECMP (2020)**: The RFC for resilient nexthop groups addressed a long-standing problem: when an ECMP group loses a member (NIC failure), all flows remap to new buckets, breaking TCP sessions. Resilient hashing stores the bucket → nexthop mapping explicitly, so only buckets assigned to the failed nexthop need reassignment.
