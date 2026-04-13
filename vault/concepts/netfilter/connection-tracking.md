---
title: "Connection Tracking (conntrack)"
category: concept
tags: [netfilter, conntrack, stateful-firewall, nat, nf_conn, connection-state]
subsystem: netfilter
kernel_version: "2.6.14"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/net/conntrack/
  - https://kernel-internals.org/net/netfilter/
  - https://docs.kernel.org/networking/nf_conntrack-sysctl.html
  - https://lwn.net/Articles/370152/
  - https://lwn.net/Articles/814061/
---

# Connection Tracking (conntrack)

## Purpose

Connection tracking maintains a per-network-namespace hash table of every active network flow so that firewall rules can match on connection state (NEW, ESTABLISHED, RELATED, INVALID) rather than on raw packet headers alone. Without conntrack, a stateful firewall rule — "allow established TCP connections but reject unsolicited inbound SYNs" — would require the administrator to enumerate all possible reply addresses, which is impossible for dynamic clients. conntrack also serves as the foundation for NAT: it stores per-flow address rewrite parameters so that NAT can be applied consistently to every packet in both directions without re-evaluating rules.

## Mental Model

Think of conntrack as the kernel's **passport control desk**: every new packet that wants to enter or traverse the system must be checked against an existing "passport" (the conntrack entry). If a passport exists and the packet is consistent with it (right direction, right state), it gets a fast stamp and moves on. If no passport exists, the desk creates a provisional one (unconfirmed entry) and checks whether the packet is legitimate before filing the passport permanently. Expired passports are garbage-collected. Application-layer helpers at the desk can also pre-register expectations for secondary connections (like FTP data channels), allowing those connections to arrive with a pre-approved visitor visa (RELATED state).

## How It Works

### Hook Registration and Entry Point

The conntrack module registers at two hook points with priority `NF_IP_PRI_CONNTRACK = −200`, ensuring it runs before any filter or NAT rule. The primary entry point is `nf_conntrack_in()`, registered at `NF_INET_PRE_ROUTING` and `NF_INET_LOCAL_OUT`.

When `nf_conntrack_in()` receives an `sk_buff`, it first calls the appropriate **layer-4 protocol tracker** (registered via `struct nf_conntrack_l4proto`) to extract the **tuple** — a 5-tuple of protocol, source IP, source port, destination IP, destination port. For ICMP the "port" fields are replaced by the ICMP type/code and ID.

### Tuple Lookup and Entry Creation

With the tuple in hand, `nf_conntrack_find_get()` hashes it and looks it up in `nf_conntrack_hash` — a per-network-namespace hash table protected by RCU. If a matching `struct nf_conn` exists, its pointer is stored in `skb->_nfct` and the function returns; subsequent hook callbacks can retrieve the connection state with `nf_ct_get()`.

On a miss — the packet is the **first in a new flow** — `nf_conntrack_in()` allocates a new `struct nf_conn` via `nf_conntrack_alloc()`. This allocation also pre-computes the **reply tuple** (source and destination swapped, adjusted for any expected NAT) and stores both tuples as `tuplehash` entries inside the `nf_conn`. But the entry is **not yet inserted into the main hash table**. Instead it's added to the per-CPU `unconfirmed` list and tagged with `IPS_CONFIRMED = 0`.

This two-phase design is deliberate: if a filter chain subsequently drops the packet, the conntrack entry is silently freed without ever polluting the main table. Only when the packet successfully reaches egress — at `NF_INET_POST_ROUTING` or `NF_INET_LOCAL_IN` — does `nf_conntrack_confirm()` move the entry from the unconfirmed list to the main hash table under a spinlock, setting `IPS_CONFIRMED`.

### State Transitions

After the first packet confirms, subsequent packets in the same flow hit the hash table on the first lookup. Each matching packet:
1. Updates the entry's `timeout` (resets the expiry timer)
2. Invokes the L4 protocol tracker's `packet()` callback to update per-protocol state

For TCP, the tracker maintains a simplified state machine:
- Seeing a SYN sets state to `TCP_CONNTRACK_SYN_SENT`
- Seeing a SYN-ACK (reply direction) transitions to `TCP_CONNTRACK_SYN_RECV`
- Seeing an ACK in the original direction transitions to `TCP_CONNTRACK_ESTABLISHED` and sets `IPS_ASSURED`
- FIN/RST packets move toward `TCP_CONNTRACK_CLOSE`

`IPS_ASSURED` is important: during memory pressure the garbage collector skips ASSURED entries. Only non-ASSURED entries (half-open connections, UDP flows without a reply) are evicted first.

### Connection State for Firewalling

From firewall rules, the relevant abstraction is the `ctinfo` state, accessible from the `nf_conn`:
- `IP_CT_NEW` — first packet of a flow (unconfirmed, no reply seen)
- `IP_CT_ESTABLISHED` — `IPS_SEEN_REPLY` is set (traffic in both directions observed)
- `IP_CT_RELATED` — matched via a conntrack expectation (secondary connection, e.g. FTP data)
- `IP_CT_INVALID` — packet is inconsistent with any tracked flow

### Conntrack Helpers and Expectations

Some protocols embed IP addresses and ports in their application-layer payload (FTP `PORT`/`PASV` commands, SIP `Contact` headers, H.323 signaling). These secondary connections would otherwise appear as NEW, unrelated flows and be blocked by a stateful firewall.

Conntrack **helpers** solve this by parsing the payload of control connections and calling `nf_ct_expect_alloc()` + `nf_ct_expect_insert()` to create an `nf_conntrack_expect`: a tuple template that pre-registers the expected secondary connection. When that secondary connection's first packet arrives and conntrack looks it up, the expectation matches and the new `nf_conn` is tagged with `IPS_EXPECTED`, making the connection appear as RELATED.

### Garbage Collection and Memory Pressure

Conntrack entries expire when their `timeout` fires. The timeout is managed by `nf_ct_ent_dying()`, a timer callback that removes the entry from the hash table. Protocol-specific defaults: TCP established = 5 days; UDP stream = 180s; generic = 600s. All tunable via sysctl.

If `nf_conntrack_count` reaches `nf_conntrack_max`, new connection tracking is refused and the packet is dropped. The kernel also performs early GC via `nf_conntrack_find_get()`'s `nf_ct_gc_expire()` path, evicting soon-to-expire unassured entries before the table fills.

## Key Data Structures

**`struct nf_conn`** (`include/net/netfilter/nf_conntrack.h`) — one tracked connection
- `tuplehash[IP_CT_DIR_ORIGINAL]` / `tuplehash[IP_CT_DIR_REPLY]` — the two `hlist_node` entries keyed by their respective 5-tuples; these are what's hashed into `nf_conntrack_hash`
- `status` — `IPS_*` bitmask: `IPS_CONFIRMED`, `IPS_SEEN_REPLY`, `IPS_ASSURED`, `IPS_SRC_NAT`, `IPS_DST_NAT`, `IPS_EXPECTED`, `IPS_DYING`
- `timeout` — expiry timer (`timer_list`)
- `ct_net` — pointer to the owning network namespace
- `proto` — union of L4-specific state (`tcp.state`, `udp.stream_timeout`, etc.)
- `mark` — 32-bit opaque mark (set by MARK target, matched in rules)
- `secmark` — 32-bit SELinux security mark
- `ext` — `struct nf_ct_ext *`: flexible array of extensions; extensions are named blobs appended to the struct (NAT info, accounting counters, timestamps, connlabels, conntrack zones)

**`struct nf_conntrack_tuple`** (`include/net/netfilter/nf_conntrack_tuple.h`) — the 5-tuple uniquely identifying one direction of a flow
- `src.u3` — source address (`__be32` for IPv4, `struct in6_addr` for IPv6)
- `dst.u3` — destination address
- `src.u` — source port/ICMP id
- `dst.u` — destination port/ICMP type+code
- `dst.protonum` — IP protocol (6=TCP, 17=UDP, 1=ICMP…)
- `src.l3num` — address family (AF_INET / AF_INET6)

**`struct nf_conntrack_expect`** (`include/net/netfilter/nf_conntrack_expect.h`)
- `tuple` — the tuple template to match against new connections
- `mask` — wildcards in the tuple (helpers may not know the ephemeral source port)
- `master` — `nf_conn *` for the control connection this expectation belongs to
- `timeout` — expiry timer for the expectation itself

## Key Functions / Entry Points

**`nf_conntrack_in()`** (`net/netfilter/nf_conntrack_core.c`) — hook callback; extracts tuple, looks up or creates `nf_conn`, attaches to `skb->_nfct`

**`nf_conntrack_confirm()`** — moves entry from per-CPU unconfirmed list to main hash table; called at egress hook points

**`nf_conntrack_find_get()`** — hashes a tuple and does an RCU lookup in `nf_conntrack_hash`; returns the `nf_conn *` with a reference

**`nf_ct_get()`** — fast inline to retrieve `nf_conn *` and `ctinfo` from `skb->_nfct`

**`nf_ct_expect_alloc()` / `nf_ct_expect_insert()`** — allocate and register a conntrack expectation from a helper

**`nf_conntrack_helper_register()`** — registers an application-layer helper (FTP, SIP, etc.)

## Important Flags & Config Options

- `CONFIG_NF_CONNTRACK` — core conntrack (required by conntrack-dependent NAT and helpers)
- `/proc/sys/net/netfilter/nf_conntrack_max` — maximum concurrent tracked flows; reaching this causes drops. Check `nf_conntrack_count` to see current usage
- `/proc/sys/net/netfilter/nf_conntrack_buckets` — hash table size (set at module load; larger = fewer collisions, more memory)
- `/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established` — default 432000 s; reduce to 3600–7200 on busy internet-facing hosts
- `/proc/sys/net/netfilter/nf_conntrack_acct` — enable 64-bit byte/packet counters per flow (memory overhead: ~80 bytes/flow)
- `/proc/sys/net/netfilter/nf_conntrack_events` — enable ctnetlink event delivery (`auto` by default); disable if no conntrackd/firewall sync is needed
- `CONFIG_NF_CONNTRACK_ZONES` — enables conntrack zones so the same tuple can exist in multiple namespace contexts (needed for VPNs / overlapping address spaces)

## Interactions with Other Subsystems

- **↑ Userspace**: `conntrack` CLI reads state via the `nfnetlink_conntrack` subsystem (`NFNLGRP_CONNTRACK_*`); `conntrackd` uses conntrack events for HA failover
- **→ [[netfilter-hook-framework]]**: conntrack registers at priority −200 at PRE_ROUTING and LOCAL_OUT; confirms at POST_ROUTING and LOCAL_IN
- **→ [[netfilter-nat]]**: NAT stores rewrite parameters in the `nf_conn`'s NAT extension; conntrack provides the infrastructure, NAT provides the policy
- **→ [[netfilter-flowtable]]**: flowtable entries hold a back-reference to `nf_conn`; when a flow is offloaded, packets bypass conntrack lookup but the `nf_conn` remains alive and its timeout is refreshed by software-path stragglers
- **→ [[security]]**: `nf_conn.secmark` is set by the iptables SECMARK target and read by SELinux at socket receive; this wires packet flow decisions into the MAC policy

## Design Decisions & Tradeoffs

**Two-phase confirm** — Deferring hash table insertion until egress prevents half-dropped packets (those filtered mid-path) from leaking conntrack state. The cost is per-CPU unconfirmed lists and an extra step at egress. An alternative would have been to insert immediately and remove on drop, but that requires lookup-under-lock on the drop path, adding lock contention.

**Extensions as flexible arrays** — Rather than embedding every possible feature (NAT info, accounting, zones, labels) in every `nf_conn`, extensions are opt-in blobs allocated at the end of the struct. This keeps the base struct at ~300 bytes instead of ~800 bytes, which matters at millions of concurrent connections.

**Protocol helpers as loadable modules** — Application-layer helpers (FTP, SIP, H.323, TFTP) are separate modules rather than compiled into conntrack. This prevents bloat for deployments that don't need them and allows helpers to be updated independently. The downside is that helpers must be explicitly loaded/configured and may not activate automatically on unusual ports without explicit rules.

**Hash table vs. per-CPU tables** — conntrack uses a global hash table with per-bucket locking (via RCU + spinlock on mutation). Per-CPU tables would eliminate cross-CPU lock contention but would require either table replication (memory cost) or cross-CPU lookups for reply-direction packets (complexity). The global table with RCU is a reasonable compromise up to ~10M connections.

## How It Has Evolved

- **Linux 2.4**: `ip_conntrack` — IPv4-only, compiled into the kernel
- **Linux 2.6.14 (2005)**: Refactored as `nf_conntrack`: protocol-family-agnostic; IPv6 conntrack added
- **Linux 2.6.20**: Network namespace isolation for conntrack tables
- **Linux 3.12 (2013)**: Conntrack zones (per-zone state isolation for overlapping addresses)
- **Linux 4.14 (2017)**: Conntrack GC improved to avoid scanning the entire table on every timer tick
- **Linux 5.3 (2019)**: Hardware offload support; conntrack entries can be pushed to NIC hardware via flowtable

## Further Reading

1. [Connection tracking offload (LWN, 2020)](https://lwn.net/Articles/814061/) — hardware flowtable and conntrack offload design
2. [RFC: conntrack zones (LWN, 2010)](https://lwn.net/Articles/370152/) — zone isolation design for overlapping address spaces
3. [kernel.org: nf_conntrack sysctl reference](https://docs.kernel.org/networking/nf_conntrack-sysctl.html) — all tunable parameters
4. `net/netfilter/nf_conntrack_core.c` — lookup, confirm, GC
5. `include/net/netfilter/nf_conntrack.h` — `struct nf_conn` definition

## LKML Highlights

- The conntrack refactor from `ip_conntrack` to `nf_conntrack` (2005) was a multi-month effort to factor out all IPv4 assumptions; the thread debated whether the abstraction cost was worth it — justified by IPv6 conntrack and NAT arriving immediately afterward.
- The conntrack zones RFC (2010) introduced the concept of per-zone isolation; the debate centred on whether zones should be per-device or per-routing-mark — per-mark won as it's more expressive for tunnel scenarios.
