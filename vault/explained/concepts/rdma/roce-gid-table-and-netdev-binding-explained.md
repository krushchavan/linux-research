---
title: "RoCE GID Table and Netdev Binding — Explained"
category: explained
original: "[[roce-gid-table-and-netdev-binding]]"
subsystem: rdma
tags: [explained, rdma, roce, gid, networking]
converted: 2026-09-26
---

# The RoCE address table, explained

> Plain-language companion to [[roce-gid-table-and-netdev-binding|the technical note]]. Same facts, fewer identifiers.

## The problem

Every RDMA packet names its source and destination with a 128-bit **GID**. On InfiniBand, a subnet manager hands them out. On **RoCE** there is no subnet manager: the GIDs have to *be* the host's Ethernet/IP identity: IPv6 addresses, IPv4 addresses written in IPv6-mapped form, and a link-local address derived from the MAC, each tied to a particular network interface, VLAN and network namespace. The kernel keeps a per-port **GID table**, mirrored into the card, and must keep it in step with the network stack through every IP change, new VLAN and bond failover. If it goes stale, connections go out from addresses the host no longer owns, on the wrong VLAN, or bypassing a bond's active link.

## The idea in one paragraph

The GID table is **the RDMA port's stack of return-address cards**, each saying "IP X, on interface Y (VLAN Z), speaking RoCE v1 or v2". The network layer is the authority on which addresses exist, and a **clerk subscribed to network notifications** rewrites the cards whenever that authority changes. When the connection manager or an application sends, it picks a card by index, and the card tells the card hardware which source IP and MAC to use, which VLAN tag to add, and which encapsulation to use.

## Step by step

### Step 1: The table
When a device registers, each port gets a table sized to the hardware's capacity (often 255 entries or more). Each entry holds the GID, its type, the owning network interface (safely reference-counted), its index and port. Readers take a read lock; writers may sleep, because adding an entry means programming the card's table with a firmware command.

### Step 2: One entry per address per RoCE flavour
Each address gets an entry for every RoCE version the port supports: **v1** (directly over Ethernet, not routable) and **v2** (inside UDP/IP on port 4791, routable). One IPv4 address on a dual-mode port therefore uses two slots, which is why listings show each IP twice.

### Step 3: Default entries
Each port always has a **link-local** GID derived from the interface's MAC address, one per type, in reserved low slots, replaced (not deleted) if the MAC changes.

### Step 4: Fill it at registration
When a RoCE device registers, the kernel walks each port's bound interface, adding its IPv4 addresses (in mapped form) and IPv6 addresses, and also walks **upper devices** (VLAN interfaces, macvlan, bond masters). So `eth0.100`'s address becomes a GID owned by `eth0.100`, and its traffic is tagged with VLAN 100.

### Step 5: Keep it live
This is the key step. The kernel subscribes to interface events (up, down, register, unregister, MAC change, VLAN or bond linking, bond failover) and to IPv4 and IPv6 address add/remove events. These notifications arrive in contexts that must not call firmware, so each is packaged as deferred work: up to three commands, each with a **filter** deciding which RDMA ports it applies to:
- the event's interface *is* the port's interface
- the event's interface is *above* the port's (a VLAN on top of it)
- bond slaves: only the **active** slave's RDMA port should carry the bond's addresses
- the event's interface is a bond master above this port

### Step 6: Bonding
When a port's interface joins a bond, the handler removes the slave's own entries (it no longer owns addresses), adds the bond master's default entries, then adds the bond's IP entries. On an active-backup failover, entries move from the old active port to the new one. Cards with **RoCE LAG** support (mlx5 with two ports on one adapter) instead present a single RDMA device over the bond, and the hardware spreads traffic across both ports.

### Step 7: Delete safely
An entry used by live queue pairs or address handles can't be freed out from under them. Users hold **references**; deletion marks the entry "pending delete" (invisible to lookups but still allocated) and frees the hardware slot only when the last reference goes. The interface pointer is released after an RCU grace period, so readers never see a freed interface. Before this rework (4.19), queue pairs held just an index, and deleting and re-adding an address could silently repoint a live connection to a different IP or VLAN.

### Step 8: Who looks things up
- the **connection manager** resolves the destination to an outgoing interface, then picks the local entry whose address matches the source IP, whose interface matches (so VLAN and namespace are right), and whose type is the configured default
- **address handles and queue-pair paths** keep a reference to their entry, and the driver reads the VLAN ID and source MAC from it when building packets
- **user space** queries entries (including the interface index) through verbs or sysfs
- entries whose interface belongs to another **network namespace** are hidden from lookups, so containers only see their own addresses

Every change raises a "GID changed" event on the port, so users can re-resolve.

## The picture

```text
 ip addr add 10.0.0.5/24 dev eth0.100  ──notifier──▶ deferred work (filters: VLAN above eth0)
   ▼
 port 1 GID table
   [0] fe80::…(MAC)     v1  eth0          (default)
   [1] fe80::…(MAC)     v2  eth0          (default)
   [4] ::ffff:10.0.0.5  v1  eth0.100
   [5] ::ffff:10.0.0.5  v2  eth0.100      ◀── rdma_cm picks this (v2 default) → VLAN 100, src MAC
 bond failover: entries move from old active slave's port to new one
```

## Tradeoffs

- **What it gives you:** RDMA addressing derived from ordinary IP configuration, so `ip addr`, NetworkManager, VLANs and bonding work for RDMA without separate administration; correct VLAN and namespace isolation because the interface is part of each entry's identity.
- **What it costs / requires:** a tricky synchronisation engine with bond, VLAN and macvlan special cases, and races between notification order and deferred work. One entry per address per type doubles table use, and hosts with many VLANs and addresses can run out of hardware slots.
- **Where it bites:** picking the wrong entry index by hand (for example perftest's GID-index option) is a common cause of "wrong VLAN" problems.

## How it got here

- **2.6.37 (2010):** RoCE (then "IBoE") in mlx4, with MAC-based GIDs.
- **4.1–4.5:** central IP-based management (Matan Barak), with firmware writes deferred to a workqueue; RoCE v2 types.
- **4.10–4.14:** bonding filters, LAG, defaults per type.
- **4.19:** reference-counted entries and pending-delete state (Parav Pandit), stored in queue pairs and address handles.
- **5.x:** RCU-protected interface pointers, namespace filtering, and a user-space call returning the whole table with interface indexes (5.9).

## Related

- Technical version: [[roce-gid-table-and-netdev-binding]]
- [[roce-v1-and-v2-explained|RoCE v1 and v2]], [[rdma-cm-connection-manager-explained|Connection manager]], [[ib-device-and-client-model-explained|Device and client model]], [[queue-pairs-and-completion-queues-explained|Queue pairs and CQs]], [[rdma-explained|RDMA subsystem]]
- [[network-device-and-napi-explained|Network devices]], [[network-namespaces-explained|Network namespaces]]
