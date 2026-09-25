---
title: "Netfilter Flowtable"
category: concept
tags: [netfilter, flowtable, flow-offload, fastpath, hardware-offload, conntrack]
subsystem: netfilter
kernel_version: "4.16"
researched: 2026-04-13
status: complete
explained: "[[netfilter-flowtable-explained]]"
sources:
  - https://docs.kernel.org/networking/nf_flowtable.html
  - https://kernel-internals.org/net/netfilter/
  - https://lwn.net/Articles/814061/
---

# Netfilter Flowtable

> 📘 Plain-language version: [[netfilter-flowtable-explained]]

## Purpose

The flowtable provides a fastpath that bypasses the full netfilter hook stack for established, ASSURED flows. Without it, every packet in a long-lived forwarded flow must traverse the hook framework, conntrack lookup, filter chains, and NAT tables — CPU work that adds latency and limits forwarding throughput. For a Linux router carrying millions of flows at 10+ Gbps, the netfilter overhead on established TCP sessions is the dominant cost. The flowtable short-circuits this by caching just enough state to forward packets directly via `neigh_xmit()`, skipping all hook evaluation.

## Mental Model

Think of the flowtable as an **express lane** alongside the normal security checkpoint line. The first packet of a flow goes through the full checkpoint (conntrack, filter, NAT). Once the flow is established and trusted, subsequent packets are issued an express pass (flowtable entry) and routed through a separate lane that only checks the pass and forwards immediately. The express lane still knows about NAT (the pass includes the rewrite parameters) but skips all the policy checks. TCP RST and FIN packets are deliberately diverted from the express lane back to the normal checkpoint, so the flow closes cleanly.

## How It Works

### Opt-In Offload

The flowtable does not automatically offload all established flows. An administrator must write an explicit ruleset action: in nftables, `flow add @<flowtable_name>` in a forward chain rule:

```
table inet filter {
    flowtable ft {
        hook ingress priority 0;
        devices = { eth0, eth1 };
    }
    chain forward {
        type filter hook forward priority 0;
        ip protocol { tcp, udp } ct state established flow add @ft;
    }
}
```

When this action fires for an ASSURED conntrack entry, `nf_flow_offload_tuple()` allocates a `struct flow_offload` and calls `flow_offload_work_add()` to queue the entry for insertion into the flowtable's hash table. For hardware offload, `nf_flow_table_offload_add_cb()` additionally pushes the entry to the driver.

### Software Fastpath

The flowtable module registers a pre-routing hook at priority `NF_IP_PRI_CONNTRACK − 1 = −201` — one tick ahead of conntrack's −200. This placement is essential: the flowtable hook runs first; if it finds a matching entry it forwards the packet and returns `NF_STOLEN`, preventing conntrack from even seeing the packet.

The hook callback `nf_flow_offload_inet_hook()`:

1. Extracts an n-tuple from the packet (L2 encapsulation, L3 addresses, L4 ports, ingress interface)
2. Hashes the tuple and looks it up in `flow_table->rhashtable` under RCU
3. On a hit: checks `FLOW_OFFLOAD_DYING` / `FLOW_OFFLOAD_TEARDOWN` flags; if clean, applies cached NAT rewrite, decrements TTL, updates `neigh` entry MAC, calls `neigh_xmit()` to send the packet directly to the egress interface, and returns `NF_STOLEN`
4. On a miss: returns `NF_ACCEPT` immediately, letting conntrack and filter run normally

TCP RST and FIN packets are specifically excluded from the fastpath (the hook checks TCP flags) to ensure flow teardown is handled correctly by conntrack.

### NAT on the Fastpath

The `flow_offload` entry caches the NAT rewrite parameters extracted from the `nf_conn`'s NAT extension at offload time. The fastpath applies these rewrites inline before forwarding — so SNAT/DNAT continues to function at full speed without touching the NAT module.

### Hardware Offload

If the NIC driver implements `ndo_flow_offload` (via `struct flow_offload_driver_ops`), the flowtable can push entries to hardware:

1. The kernel calls `driver->flow_add(flow_offload)`, passing the 5-tuple, NAT parameters, and egress port
2. The NIC programs its hardware flow table (TCAM, SRAM, or equivalent)
3. Subsequent packets matching the hardware entry are switched entirely in the NIC — zero kernel CPU per packet
4. The driver signals back via `flow_offload_driver_cb()` when the flow expires or should be refreshed

In hardware offload mode the kernel flowtable entry is marked `FLOW_OFFLOAD_HW`. The connection is still visible in `conntrack -L` (the `nf_conn` remains alive), tagged with `[HW_OFFLOAD]` in the status flags.

### Graceful Teardown

When a flowtable entry expires (no matching packet refreshed it within the timeout), `nf_flow_offload_work_gc()` removes it from the hash table. The corresponding `nf_conn` is *not* immediately deleted — it migrates back to the normal conntrack path. The next packet in that flow will miss the flowtable, fall through to conntrack (which still has the entry), and be processed normally. This migration allows long-idle flows to re-establish before completely timing out.

## Key Data Structures

**`struct flow_offload`** (`include/net/netfilter/nf_flow_table.h`)
- `tuplehash[FLOW_OFFLOAD_DIR_ORIGINAL]` / `tuplehash[FLOW_OFFLOAD_DIR_REPLY]` — `struct flow_offload_tuple_rhash` nodes in the rhashtable, keyed by their respective n-tuples
- `flags` — `FLOW_OFFLOAD_HW` (hardware-accelerated), `FLOW_OFFLOAD_DYING` (marked for GC), `FLOW_OFFLOAD_TEARDOWN` (TCP RST/FIN seen)
- `timeout` — jiffies-based expiry; refreshed by software-path packets
- `nf_ct` pointer — back-reference to the conntrack entry for timeout coordination

**`struct flow_offload_tuple`** (`include/net/netfilter/nf_flow_table.h`) — the lookup key for one direction
- `src_v4` / `dst_v4` (or v6 equivalents) — L3 addresses
- `src_port` / `dst_port` — L4 ports
- `iifidx` — ingress interface index
- `l3proto` / `l4proto` — address family and transport protocol
- `encap[]` — up to two levels of L2 encapsulation (VLAN, PPPoE) for DSL/broadband scenarios
- `xmit_type` — how to forward: `FLOW_OFFLOAD_XMIT_NEIGH` (neighbour lookup), `FLOW_OFFLOAD_XMIT_XFRM` (IPsec), `FLOW_OFFLOAD_XMIT_DIRECT` (cached `neigh` pointer)
- `nat_seq[]` — TCP sequence number delta for NAT (used when NAT changes packet length, e.g. FTP helper rewrites)

**`struct nf_flowtable`** (`include/net/netfilter/nf_flow_table.h`)
- `rhashtable` — the resizable hash table storing `flow_offload_tuple_rhash` entries
- `flags` — `NF_FLOWTABLE_HW_OFFLOAD` (hardware offload enabled for this table)
- `gc_work` — delayed work for garbage collection of expired entries
- `flow_block` — used to program hardware flow tables via the TC block infrastructure

## Key Functions / Entry Points

**`nf_flow_offload_inet_hook()`** (`net/netfilter/nf_flow_table_ip.c`) — the pre-routing hook; performs fastpath lookup and forwarding

**`nf_flow_table_offload_add_cb()`** (`net/netfilter/nf_flow_table_offload.c`) — queues hardware offload to the driver via TC block callbacks

**`flow_offload_work_add()`** — work queue handler that inserts a new flowtable entry after allocation

**`nf_flow_offload_work_gc()`** — garbage-collects expired entries; migrates flows back to the normal conntrack path

## Important Flags & Config Options

- `CONFIG_NF_FLOW_TABLE` — software flowtable support
- `CONFIG_NF_FLOW_TABLE_HW` — hardware offload infrastructure (requires driver support)
- `/proc/sys/net/netfilter/nf_flowtable_tcp_timeout` — idle timeout for TCP flows in the flowtable (default: 30s; after expiry the flow returns to normal conntrack path)
- `/proc/sys/net/netfilter/nf_flowtable_udp_timeout` — idle timeout for UDP flows (default: 30s)
- Flowtable hook priority is `NF_IP_PRI_CONNTRACK − 1 = −201`, hardcoded in the implementation

## Interactions with Other Subsystems

- **→ [[connection-tracking]]**: flowtable entries are created from ASSURED `nf_conn` entries and hold a reference to them; the `nf_conn` remains alive while the flow is offloaded
- **→ [[netfilter-hook-framework]]**: the flowtable registers a pre-routing hook at −201; if it matches, it returns `NF_STOLEN` before conntrack at −200 can run
- **→ [[netfilter-nat]]**: NAT parameters are cached in `flow_offload_tuple.nat_*` fields at offload time; the fastpath applies them without touching the NAT module
- **→ [[net]]**: forwarding uses `neigh_xmit()` or a pre-cached `dst_entry` — the flowtable effectively implements a specialised software switching path that bypasses the routing subsystem for known flows

## Design Decisions & Tradeoffs

**Explicit opt-in vs. automatic offload** — Automatically offloading all ASSURED flows would maximise performance but make debugging difficult (administrators could not easily tell why a flow bypasses filter chains) and would surprise setups that use filter rules on established connections. Explicit opt-in via ruleset keeps the fastpath transparent and predictable.

**Cached neigh vs. routing lookup per packet** — The fastpath caches the `neigh` entry (ARP/NDP neighbour) at offload time. If the next-hop MAC changes (route change, ARP expiry), the cached entry becomes stale. The flowtable handles this by checking `neigh->nud_state`; stale neighbours trigger a flowtable teardown and flow migration back to the normal path, which performs a fresh routing lookup.

**TCP RST/FIN bypass** — Excluding RST and FIN from the fastpath ensures the connection teardown goes through conntrack. If RST were forwarded via the fastpath, the conntrack entry would remain ESTABLISHED until timeout, wasting table space and potentially confusing firewalls.

**Hardware offload via TC block** — Rather than inventing a new driver API, hardware offload reuses the TC (Traffic Control) block infrastructure, which already has a well-defined callback model for offloading flow actions to hardware. This avoided duplicating a new kernel-hardware ABI.

## How It Has Evolved

- **Linux 4.16 (2018)**: Software flowtable introduced; IPv4 TCP/UDP forwarding bypass
- **Linux 5.0 (2019)**: IPv6 flowtable support
- **Linux 5.3 (2019)**: Hardware offload via `ndo_flow_offload`; first drivers (Mediatek, Netronome)
- **Linux 5.6 (2020)**: PPPoE and VLAN encapsulation support in flowtable tuple
- **Linux 5.13 (2021)**: IPsec (XFRM) support in flowtable — offloaded flows can use hardware crypto

## Further Reading

1. [Connection tracking offload (LWN, 2020)](https://lwn.net/Articles/814061/) — design and driver interface for hardware flowtable offload
2. [kernel.org: Netfilter flowtable](https://docs.kernel.org/networking/nf_flowtable.html) — official architecture overview and configuration example
3. `net/netfilter/nf_flow_table_core.c` — entry lifecycle management
4. `net/netfilter/nf_flow_table_ip.c` — software fastpath hook for IPv4/IPv6
5. `net/netfilter/nf_flow_table_offload.c` — hardware offload via TC block

## LKML Highlights

- The flowtable patchset (Pablo Neira Ayuso, 2018) was debated on whether explicit opt-in was the right model or whether the kernel should automatically offload ASSURED flows. Opt-in won on debuggability and backward-compatibility grounds.
- Hardware offload design discussions (2019) focused on driver API choice: reusing TC block callbacks vs. a new `ndo_flow_offload` hybrid. The hybrid approach was chosen to allow drivers that already implement TC offload to add flowtable support with minimal new code.
