---
title: "Connection Tracking (conntrack) — Explained"
category: explained
original: "[[connection-tracking]]"
subsystem: netfilter
tags: [explained, netfilter, conntrack, stateful-firewall, nat]
converted: 2026-09-25
---

# Connection tracking (conntrack), explained

> Plain-language companion to [[connection-tracking|the technical note]]. Same facts, fewer identifiers.

## The problem

A useful firewall rule sounds like "allow replies to connections we started, but block unsolicited incoming connections". Packet headers alone can't express that: a reply looks like any other packet, and a client's addresses and ports change constantly, so you'd have to list every possible reply in advance. NAT has the same need. Once a flow's addresses are rewritten, every later packet in both directions must be rewritten consistently, without re-deciding each time.

The kernel needs to remember every active flow and its state, cheaply enough to handle millions of flows, without letting junk (dropped packets, half-open connections) fill memory.

## The idea in one paragraph

Conntrack is the kernel's **passport control desk**. Every packet is checked against an existing "passport", the flow's entry. If one exists and the packet fits it, it gets a quick stamp and moves on. If not, the desk makes a **provisional** passport and only files it permanently once the packet has actually made it through. Expired passports are cleared out. Helpers at the desk can also pre-register **expected** secondary connections (like FTP data channels), so they arrive with a pre-approved visa and count as related.

## Step by step

### Step 1: Run first
Conntrack registers at priority −200 on the packet-arrival and local-output junctions, ahead of any filter or NAT rule. For each packet, a per-protocol tracker extracts the **tuple**: protocol, source and destination addresses, source and destination ports (for ICMP, the type, code and ID stand in for ports).

### Step 2: Look it up
The tuple is hashed and looked up, under RCU, in the network namespace's conntrack table. On a hit, the entry is attached to the packet, where later hooks can read its state.

### Step 3: A new flow gets a provisional entry
This is the key step. On a miss (the first packet of a flow), a new entry is allocated holding **two** tuples: the original direction and the **reply** direction (addresses and ports swapped, adjusted for any expected NAT), both of which will be hashed into the table. But the entry is **not** put in the main table yet. It goes on a per-CPU "unconfirmed" list.

Only when the packet successfully reaches the end of its path (on local delivery, or just before it leaves) is the entry **confirmed** and moved into the main table under a lock. If a firewall rule drops the packet part-way, the provisional entry is simply freed, and the table is never polluted by traffic that was blocked.

### Step 4: Follow the state
After confirmation, later packets in either direction find the entry at once. Each refreshes its timeout and lets the protocol tracker update its state. For TCP that's a simplified state machine: SYN seen, then SYN-ACK, then ACK, at which point the connection is **established** and marked **assured**, and later FIN or RST closing it. Assured entries survive memory-pressure clean-up; half-open connections and one-way UDP flows are evicted first.

Firewall rules see one of four states:
- **new:** first packet of a flow, no reply yet
- **established:** traffic has been seen in both directions
- **related:** a secondary connection matching an expectation
- **invalid:** doesn't fit any tracked flow

### Step 5: Helpers and expectations
Some protocols put addresses and ports inside their payloads: FTP's port and passive commands, SIP contact headers, H.323 signalling. The secondary connections they announce would look like unrelated new flows and be blocked. **Helpers** parse the control connection's payload and register an **expectation**: a tuple template (with wildcards for unknown parts such as the client's ephemeral port) linked to the control connection. When the secondary connection's first packet matches it, the new entry is marked as expected and appears as **related**. Helpers are separate modules, loaded only when needed.

### Step 6: Timeouts and a full table
Entries expire when their timer fires: by default 5 days for established TCP, 180 seconds for a UDP stream, 600 seconds for other protocols, all tunable. When the number of entries reaches the configured maximum, new flows are **refused and their packets dropped**. The kernel tries to avoid this by evicting soon-to-expire, unassured entries early.

### Step 7: Optional extras, only where needed
Features like NAT details, byte and packet counters, timestamps, labels and zones are **extensions** appended only when used, keeping the basic entry around 300 bytes instead of 800. That matters with millions of connections. **Zones** let the same tuple exist separately in different contexts, for VPNs and overlapping address spaces.

## The picture

```text
 packet ─▶ tuple (proto, src:port → dst:port) ─▶ hash lookup
   hit  ─▶ attach entry, refresh timeout, update TCP state
   miss ─▶ new entry {original tuple, reply tuple} ─▶ per-CPU unconfirmed list
             ├─ dropped by firewall ─▶ freed (never in the table)
             └─ reaches the end ─▶ confirm ─▶ main hash table
 FTP control: "PASV 10.0.0.5:40001" ─▶ expectation ─▶ data connection = RELATED
```

## Tradeoffs

- **What it gives you:** stateful firewall rules, automatic reply handling for NAT, protocol helpers for tricky protocols, and a table that dropped traffic can't pollute.
- **What it costs / requires:** memory per flow, hashing on every packet, per-CPU unconfirmed bookkeeping, and a global table with per-bucket locking (RCU plus spinlocks), a compromise that works up to about 10 million connections.
- **Where it bites:** a full table drops new connections, and the 5-day established-TCP default is far too long for busy internet-facing hosts (reduce it to about 1 to 2 hours). Helpers must be explicitly loaded and configured, and may not trigger on unusual ports.

## How it got here

- **2.4:** IPv4-only connection tracking built into the kernel.
- **2.6.14 (2005):** refactored to be protocol-family-agnostic, adding IPv6 tracking. The months-long effort was justified by IPv6 tracking and NAT arriving right after.
- **2.6.20:** per-network-namespace conntrack tables.
- **3.12 (2013):** conntrack zones for overlapping address spaces (per-mark rather than per-device, for tunnel scenarios).
- **4.14 (2017):** garbage collection that no longer scans the whole table on every timer tick.
- **5.3 (2019):** entries can be offloaded to network card hardware through the flowtable.

## Related

- Technical version: [[connection-tracking]]
- [[netfilter-explained|Netfilter]], [[netfilter-hook-framework-explained|Hook framework]], [[netfilter-nat|NAT]], [[netfilter-flowtable-explained|Flowtable]], [[nftables|nftables]], [[iptables-explained|iptables]]
- [[network-namespaces-explained|Network namespaces]], [[rcu-read-copy-update-explained|RCU]], [[security|Security (SELinux marks)]]
