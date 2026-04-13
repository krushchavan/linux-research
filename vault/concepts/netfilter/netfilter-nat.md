---
title: "Netfilter NAT"
category: concept
tags: [netfilter, nat, snat, dnat, masquerade, port-forwarding, conntrack]
subsystem: netfilter
kernel_version: "2.4"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/net/netfilter/
  - https://kernel-internals.org/net/nftables-iptables/
  - https://lwn.net/Articles/564095/
---

# Netfilter NAT

## Purpose

NAT (Network Address Translation) rewrites IP addresses and/or transport-layer ports in packet headers to allow multiple internal hosts to share a single public IP (SNAT/masquerade) or to redirect inbound connections to internal servers (DNAT/port forwarding). Without NAT, every host on a private network would need a globally routable address — impractical given IPv4 exhaustion. The kernel's NAT implementation is deliberately built on top of conntrack so that the inverse rewrite (server-to-client direction) is applied automatically without administrator-specified reverse rules.

## Mental Model

NAT is a **post-it note** attached to a conntrack entry. The first time a packet matches a NAT rule, the rule writes the desired address translation onto the conntrack entry's post-it. Every subsequent packet in that flow (in both directions) reads from the post-it and applies the rewrite, without consulting firewall rules again. When the conntrack entry expires, the post-it is discarded with it. The key insight is that NAT does not exist independently of conntrack — it is an extension of the connection state machine.

## How It Works

### First Packet: Setting Up the NAT Rewrite

The first packet of a flow arrives at `NF_INET_PRE_ROUTING` and goes through conntrack (priority −200), which creates an unconfirmed `nf_conn`. Control then passes to the NAT hook, registered at priority +100 (after the filter chains at 0).

If the packet matches a DNAT rule (e.g., `iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 192.168.1.10:8080`), the target calls `nf_nat_setup_info()`:

```c
/* net/netfilter/nf_nat_core.c (simplified) */
unsigned int nf_nat_setup_info(struct nf_conn *ct,
                               const struct nf_nat_range2 *range,
                               enum nf_nat_manip_type maniptype)
{
    /* 1. Apply range constraints to pick exact new addr/port */
    get_unique_tuple(&new_tuple, &orig_tuple, range, ct, maniptype);
    /* 2. Store the rewrite in ct's NAT extension */
    nf_ct_set_nat_info(ct, &new_tuple, maniptype);
    /* 3. Update ct's reply tuple to reflect the inverse rewrite */
    nf_conntrack_alter_reply(ct, &reply_tuple_after_nat);
    /* 4. Mark ct so NAT hooks apply rewrites to future packets */
    ct->status |= IPS_DST_NAT;   /* or IPS_SRC_NAT for SNAT */
}
```

Step 3 is critical: updating the reply tuple means that when the server's reply packet arrives with destination = 192.168.1.10:8080, conntrack's hash lookup (on the reply tuple) still finds the correct `nf_conn` and the inverse DNAT rewrite (changing destination back to the original client's view) is automatically applied.

After `nf_nat_setup_info()` returns, the packet's header is immediately rewritten by `nf_nat_packet()` before it continues.

### Subsequent Packets: Applying the Stored Rewrite

For the second and later packets in the same flow, the NAT hook callback (`nf_nat_ipv4_pre_routing()` etc.) calls `nf_nat_packet()`:

```c
unsigned int nf_nat_packet(struct nf_conn *ct, enum ip_conntrack_info ctinfo,
                            unsigned int hooknum, struct sk_buff *skb)
{
    /* Determine which manip to apply based on direction + hooknum */
    manip = nf_nat_manip_type(ct, ctinfo, hooknum);
    /* Apply stored rewrite to packet headers */
    if (ct->status & IPS_SRC_NAT || ct->status & IPS_DST_NAT)
        nf_nat_mangle_packet(skb, ct, manip);
}
```

`nf_nat_mangle_packet()` calls the L3 mangler (`nf_nat_ipv4_manip_pkt()`) and L4 mangler (TCP/UDP checksum fixup) to rewrite headers. L4 checksum updates are done incrementally via the `csum_replace4()` helper — recomputing the full checksum is not needed.

### SNAT and Masquerade

SNAT runs at `NF_INET_POST_ROUTING` (after routing has chosen the egress interface). The source address is rewritten to a configured IP or range. **Masquerade** is a variant that dynamically queries the egress interface's primary address at the time the first packet passes:

```c
/* nf_nat_masquerade_ipv4() */
newsrc = inet_select_addr(dev, 0, RT_SCOPE_UNIVERSE);
```

If the interface's address changes (e.g., DHCP renewal), masquerade automatically uses the new address for new flows; existing flows continue with the old address until they expire.

### Connection Tracking Interplay

Because the reply tuple is updated when NAT is configured (step 3 above), conntrack lookups for reply packets find the correct `nf_conn` even though the packet's addresses have been rewritten by the network. The invariant is: **conntrack hashes always reflect what the kernel will see on the wire, not what the original sender intended**. This is enforced by `nf_conntrack_alter_reply()`.

### Protocol Helpers and NAT

For protocols that embed addresses in payloads (FTP, SIP), NAT alone is insufficient — the payload must also be rewritten. NAT helpers (e.g., `nf_nat_ftp`) hook into the conntrack helper infrastructure: when the FTP helper creates an expectation for a data connection, the NAT FTP helper also rewrites the embedded address/port in the control channel payload so the remote peer connects to the correct (NATed) address.

## Key Data Structures

**`struct nf_nat_range2`** (`include/uapi/linux/netfilter/nf_nat.h`) — describes a NAT address/port rewrite
- `flags` — `NF_NAT_RANGE_MAP_IPS` (address translation active), `NF_NAT_RANGE_PROTO_SPECIFIED` (port range active), `NF_NAT_RANGE_PERSISTENT` (same source always maps to same target, for load balancing consistency)
- `min_addr` / `max_addr` — address range (SNAT pool range or DNAT target)
- `min_proto` / `max_proto` — port/ID range
- `base_proto` — used with port randomisation

**`struct nf_nat_l3proto`** (`include/net/netfilter/nf_nat_l3proto.h`) — protocol family operations for NAT
- `manip_pkt()` — rewrites packet headers for a given manip type (SRC or DST)
- `in_range()` — checks if a translated address falls within the configured range
- `unique_tuple()` — selects a unique (address, port) pair from the range that doesn't conflict with existing conntrack entries

## Key Functions / Entry Points

**`nf_nat_setup_info()`** (`net/netfilter/nf_nat_core.c`) — stores NAT parameters in `nf_conn` extension and updates reply tuple; called from NAT targets when first packet matches

**`nf_nat_packet()`** — applies stored rewrite to packet headers; called from NAT hook callbacks for every packet

**`nf_nat_masquerade_ipv4()`** / **`nf_nat_masquerade_ipv6()`** — special-case SNAT with dynamic address lookup

**`nf_conntrack_alter_reply()`** — updates the reply tuple in `nf_conn` to reflect NAT rewrites; ensures bidirectional lookup consistency

## Important Flags & Config Options

- `CONFIG_NF_NAT` — core NAT module (depends on `CONFIG_NF_CONNTRACK`)
- `CONFIG_IP_NF_TARGET_MASQUERADE` — MASQUERADE target for iptables
- `CONFIG_NFT_NAT` — nft_nat expression for nftables
- `CONFIG_NF_NAT_FTP` / `CONFIG_NF_NAT_SIP` / `CONFIG_NF_NAT_TFTP` — payload-rewriting NAT helpers
- `IPS_SRC_NAT` / `IPS_DST_NAT` — conntrack status flags indicating which direction rewriting is active
- `IPS_SAME_CT` — set on expectations to indicate they should inherit the master's NAT configuration

## Interactions with Other Subsystems

- **↑ Userspace**: DNAT/SNAT targets configured via `iptables -t nat` or `nft ... nat dnat`/`snat`; masquerade rules are the most common for home-router setups
- **→ [[connection-tracking]]**: NAT is an extension of conntrack; `nf_nat_setup_info()` writes into the `nf_conn`'s NAT extension and modifies the reply tuple; every subsequent packet lookup goes through conntrack to retrieve the stored rewrite
- **→ [[netfilter-hook-framework]]**: NAT registers at hook priority +100 (POST_ROUTING for SNAT, PRE_ROUTING for DNAT), ensuring filter chains at 0 run before address rewriting
- **→ [[netfilter-flowtable]]**: flowtable entries cache NAT parameters from the `nf_conn`; hardware-offloaded flows apply NAT at line rate in the NIC without any kernel involvement per packet

## Design Decisions & Tradeoffs

**NAT as conntrack extension** — Making NAT depend on conntrack rather than implementing it independently was a key design decision in netfilter (made at the Linux 2.4 transition). The alternative was a separate stateful NAT table. Conntrack-based NAT means the reply translation is guaranteed to be consistent (it's computed from the same entry that tracked the connection) and the NAT state is automatically cleaned up when the connection expires.

**Port allocation from a range** — When multiple internal hosts share a single public IP (SNAT pool), the kernel must allocate unique source ports to distinguish flows. `get_unique_tuple()` scans the configured port range and rejects ports that would create a collision with an existing conntrack entry (same 5-tuple). For large numbers of simultaneous connections this can be a bottleneck, which is why SNAT pool ranges should be generous.

**Incremental checksum updates** — Recomputing the full L4 checksum on every NATed packet would be expensive. Instead, the kernel uses incremental checksum update formulas (RFC 3022): only the changed bytes are folded into the existing checksum. This makes NAT per-packet overhead nearly constant regardless of packet size.

## How It Has Evolved

- **Linux 2.4 (2001)**: NAT rewritten on top of the new conntrack infrastructure; masquerade becomes a conntrack extension
- **Linux 3.7 (2012)**: IPv6 NAT support added (NPTv6, DNAT/SNAT for IPv6)
- **Linux 4.18 (2018)**: NAT port selection redesigned for better scalability under high connection rates
- **Linux 5.3 (2019)**: Hardware flowtable with NAT parameters cached in the flowtable entry

## Further Reading

1. [The return of nftables (LWN, 2013)](https://lwn.net/Articles/564095/) — includes a section on how nftables handles NAT as a native expression type
2. `net/netfilter/nf_nat_core.c` — `nf_nat_setup_info()`, `nf_nat_packet()`, port allocation
3. `include/uapi/linux/netfilter/nf_nat.h` — `struct nf_nat_range2` and flag definitions
4. RFC 3022 — Traditional IP Network Address Translator (NAT) — explains the algorithmic basis for incremental checksum update

## LKML Highlights

- The IPv6 NAT patchset (2012) sparked debate about whether NAT was even appropriate for IPv6 (which was meant to give every device a public address). The consensus was that NPTv6 (prefix translation) and DNAT were sometimes unavoidable for operational reasons, so the code was merged despite philosophical objections.
- Port exhaustion under NAT is a recurring LKML topic for providers running carrier-grade NAT (CGN); patches for faster port recycling and larger port ranges appear regularly.
