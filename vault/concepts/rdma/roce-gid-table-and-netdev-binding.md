---
title: "RoCE GID Table and Netdev Binding"
category: concept
tags: [rdma, roce, gid, netdev, bonding, vlan]
subsystem: rdma
kernel_version: "4.5 (RoCE v2 GID types and roce_gid_mgmt); 4.19 (gid_attr ndev/refcount rework)"
researched: 2026-09-26
status: complete
sources:
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/roce_gid_mgmt.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/cache.c
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_verbs.h
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_cache.h
  - https://www.kernel.org/doc/html/latest/infiniband/sysfs.html
---

# RoCE GID Table and Netdev Binding

## Purpose

Every RDMA packet names its source and destination with a 128-bit **GID** (Global Identifier). On InfiniBand, GIDs come from the port GUID and a subnet prefix assigned by the subnet manager. On **RoCE** there is no subnet manager. The GIDs have to *be* the host's Ethernet/IP identity: IPv6 addresses, IPv4-mapped addresses (`::ffff:a.b.c.d`) and a MAC-derived link-local address, each tied to a specific `net_device`, VLAN and network namespace. The **GID table** is a per-port, hardware-mirrored array of these entries, and `roce_gid_mgmt.c` keeps it synchronized with the networking stack: every IP added or removed, every VLAN created, every bond failover. If it goes stale, connections originate from addresses the host no longer owns, go out on the wrong VLAN, or bypass a bond's active slave.

## Mental Model

The GID table is **the RDMA port's list of "return addresses"**, each one a card saying "IP X, on netdev Y (VLAN Z), speaking RoCE v1 or v2". The netdev layer is the authority on which addresses exist. `roce_gid_mgmt` is a **clerk subscribed to the netdev and IP address notifiers** who rewrites the cards whenever the authority changes. When the CM or an application wants to send, it picks a card by index (the `sgid_index`). The card tells the NIC which source IP and MAC to write, which VLAN tag to add, and which UDP encapsulation to use.

## How It Works

**Table shape.** At device registration, `ib_cache_setup_one()` allocates a `struct ib_gid_table` per port, sized to the hardware's `gid_tbl_len` (mlx5: typically 255 or more). Each slot points to a `struct ib_gid_table_entry` holding a `struct ib_gid_attr`: the `gid`, `gid_type`, the owning `ndev` (RCU-protected, reference counted), `index` and `port_num`. Readers take `rwlock`. Writers hold the table `mutex` plus the write side of `rwlock` and must be able to sleep, because adding a GID calls the driver's `add_gid()` op, which programs the NIC's hardware GID table through a firmware command.

**GID types.** For each address, one entry is created *per supported RoCE flavour*. `roce_gid_type_mask_support()` checks `rdma_protocol_roce_eth_encap()` (RoCE v1, `IB_GID_TYPE_ROCE`: GRH directly over Ethernet, ethertype 0x8915, L2-only) and `rdma_protocol_roce_udp_encap()` (RoCE v2, `IB_GID_TYPE_ROCE_UDP_ENCAP`: IP/UDP destination port `ROCE_V2_UDP_DPORT` = 4791, routable). One IPv4 address on a dual-mode port therefore occupies two slots, which is why `show_gids` output lists each IP twice (see [[roce-v1-and-v2]]).

**Default GIDs.** Each port always has a link-local GID derived from the netdev MAC, in modified EUI-64 form under `fe80::/64` (`make_default_gid()`), one per GID type. These occupy reserved low indices recorded in `default_gid_indices` and are replaced rather than deleted when the MAC changes.

**Populating at registration.** When a RoCE device registers, `rdma_roce_rescan_device()` walks its ports. For each port's bound netdev (set by the driver through `ib_device_set_netdev()`), it enumerates IPv4 addresses (`enum_netdev_ipv4_ips()` walks the `in_device` ifa list and converts each to a v4-mapped GID) and IPv6 addresses (`enum_netdev_ipv6_ips()`). It also walks **upper devices**, using `netdev_walk_all_upper_dev_rcu()`: VLAN interfaces, macvlan, bond masters, so `eth0.100`'s address becomes a GID whose `ndev` is `eth0.100` and whose traffic is tagged with VLAN 100.

**Keeping it live: notifiers.** `roce_gid_mgmt_init()` registers three notifiers:
- **netdevice notifier**: `NETDEV_UP`, `DOWN`, `REGISTER`, `UNREGISTER`, `CHANGEADDR` (MAC change → new default GIDs), `CHANGEUPPER` (VLAN or bond linking), `BONDING_FAILOVER`
- **inetaddr notifier**: IPv4 address add/remove
- **inet6addr notifier**: IPv6 address add/remove

Notifier callbacks run in atomic or RTNL context and must not call into firmware, so each event is packaged as a `struct netdev_event_work` holding up to three `netdev_event_work_cmd`s (a callback plus a *filter* that selects which RDMA ports it applies to) and queued on `gid_cache_wq`. `netdevice_event_work_handler()` later iterates all RoCE ports with `ib_enum_all_roce_netdevs(filter, ...)` and applies the command where the filter matches. Filters encode the relationship rules:
- `pass_all_filter` — the event netdev is the port's netdev
- `upper_device_filter` — the event netdev is an *upper* of the port's netdev (a VLAN on top of it)
- `is_eth_port_of_netdev_filter` — handles bond slaves: only the **active** slave's RDMA port should carry the bond's IPs
- `is_upper_ndev_bond_master_filter` — the event netdev is a bond master above this port

**Bonding.** When a port's netdev is enslaved to a bond (`CHANGEUPPER`), the handler runs a three-step command list: delete the slave's own default GIDs and IP GIDs (the slave no longer owns addresses), add the bond master's default GIDs, then add the bond's IP GIDs. On active-backup failover (`BONDING_FAILOVER`), GIDs move from the old active slave's RDMA port to the new one. Drivers with **RoCE LAG** support (mlx5 with two ports of one adapter) instead expose a *single* RDMA device over the bond (`lag.c`), and the hardware steers across both ports. `is_eth_active_slave_of_bonding_rcu()` decides who owns what.

**Deleting safely.** A GID in use by live QPs and address handles can't be freed out from under them. Consumers hold references with `rdma_get_gid_attr()`/`rdma_hold_gid_attr()`, and `ib_qp.av_sgid_attr` keeps one for the life of the QP path. Deletion marks the entry `GID_TABLE_ENTRY_PENDING_DEL`, so it is invisible to lookups but still allocated, and queues `del_work`. The hardware slot is released only when the last reference is put (`kref`). The netdev pointer is dropped in an RCU callback (`roce_gid_ndev_storage`), so `rdma_read_gid_attr_ndev_rcu()` readers never see a freed netdev.

**Lookups by consumers.**
- **rdma_cm** resolves the destination IP to a netdev, then calls `rdma_find_gid_by_port()`/`rdma_find_gid_by_filter()` to get the local entry whose `gid` matches the source IP, whose `ndev` matches the egress netdev (so VLAN and netns are right), and whose type is the configured default (v1 or v2). See [[rdma-cm-connection-manager]].
- **Address handles and QP paths** carry `sgid_attr`. The driver reads VLAN ID and source MAC from it with `rdma_read_gid_l2_fields()` when building packets.
- **Userspace** gets GID entries through `ibv_query_gid_ex()`/`ibv_query_gid_table()` (uverbs `QUERY_GID_TABLE`, which reports `netdev_ifindex`) or sysfs.
- **Network namespaces**: GID entries whose `ndev` belongs to another netns are filtered out of rdma_cm lookups, so containers with macvlan or ipvlan-on-VF only see their own addresses.

**Change events.** Every table change dispatches `IB_EVENT_GID_CHANGE` on the port, so ULPs (and userspace through the async fd) can re-resolve.

## Key Data Structures

**`struct ib_gid_attr`** (`include/rdma/ib_verbs.h`) — one GID entry as consumers see it.
- `gid` — 128-bit address (v4-mapped for IPv4)
- `gid_type` — `IB_GID_TYPE_IB`, `IB_GID_TYPE_ROCE` (v1), `IB_GID_TYPE_ROCE_UDP_ENCAP` (v2)
- `ndev` — RCU pointer to the owning netdev (VLAN/bond/physical)
- `index`, `port_num`, `device`

**`struct ib_gid_table`** (`cache.c`) — `sz`, `lock` (writers), `rwlock` (readers), `default_gid_indices`, `data_vec[]`.

**`struct ib_gid_table_entry`** (`cache.c`) — `kref`, `del_work`, `attr`, driver `context`, `state` (INVALID/VALID/PENDING_DEL), `ndev_storage`.

**`struct netdev_event_work_cmd`** (`roce_gid_mgmt.c`) — `{cb, filter, ndev, filter_ndev}`: one deferred GID operation and its port-selection rule.

## Key Functions / Entry Points

- **`roce_gid_mgmt_init()`** — registers netdev, inetaddr and inet6addr notifiers
- **`netdevice_event()` / `addr_event()`** → **`netdevice_queue_work()`** → **`netdevice_event_work_handler()`**
- **`rdma_roce_rescan_device()` / `rdma_roce_rescan_port()`** — full resync (registration, netdev rebind)
- **`ib_cache_gid_add()` / `ib_cache_gid_del()` / `ib_cache_gid_del_all_netdev_gids()`** (`cache.c`)
- **`ib_cache_gid_set_default_gid()`** — maintain MAC-derived link-local entries
- **`rdma_find_gid_by_port()` / `rdma_find_gid_by_filter()` / `rdma_get_gid_attr()` / `rdma_put_gid_attr()`**
- **`rdma_read_gid_l2_fields()`** — VLAN ID and MAC for packet construction
- **driver `add_gid()` / `del_gid()`** ops — program the hardware table

## Important Flags & Config Options

- sysfs `/sys/class/infiniband/<dev>/ports/<n>/gids/<idx>`, `gid_attrs/types/<idx>` ("IB/RoCE v1" or "RoCE v2") and `gid_attrs/ndevs/<idx>`
- configfs `/sys/kernel/config/rdma_cm/<dev>/ports/<n>/default_roce_mode` — which GID type rdma_cm selects
- `rdma link show` — port-to-netdev binding
- The `show_gids` script (from vendor OFED) is a convenient dump of index, GID, IP, type and netdev
- `IB_EVENT_GID_CHANGE` — async event on any modification

## Interactions with Other Subsystems

- **↑ Userspace**: `ibv_query_gid_ex`, `ibv_query_gid_table`; perftest's `-x <gid_index>` picks the source GID (a common source of "wrong VLAN" mistakes); `ibv_create_ah` with a `sgid_index`
- **→ net**: netdevice and address notifiers; upper/lower device walks (VLAN, bond, macvlan); bonding's active-slave query; RTNL-context constraints force the deferred workqueue design
- **→ drivers**: `add_gid`/`del_gid` hardware programming; LAG
- **← rdma_cm**: source GID selection for connections ([[rdma-cm-connection-manager]])
- **← QP/AH creation**: `sgid_attr` references pin entries ([[queue-pairs-and-completion-queues]])
- **← containers**: netns filtering of GIDs

## Design Decisions & Tradeoffs

- **Derive, don't configure.** RoCE GIDs are computed from IP configuration rather than administered separately, so standard tools (`ip addr`, NetworkManager, bonding) "just work" for RDMA. The cost is a tricky synchronization engine with bond, VLAN and macvlan special cases, and races between notifier ordering and deferred work.
- **One entry per (address, RoCE type).** Keeps v1 and v2 selectable per connection but doubles table use. Large-VLAN, many-IP hosts can exhaust hardware tables.
- **Reference-counted entries with deferred delete (4.19 rework, Parav Pandit).** Before it, QPs held only a GID *index*. Deleting and re-adding an address could silently repoint a live QP to a different IP or VLAN. Holding `ib_gid_attr` references means a slot is never reused while anything uses it.
- **Netdev as part of GID identity.** The same IP on two VLANs is two distinct GIDs, and matching on `ndev` rather than just the address is what makes VLAN and netns isolation correct.

## How It Has Evolved

- **2.6.37 (2010)** — RoCE (then "IBoE") in mlx4 with MAC-based GIDs
- **4.1–4.5** — `roce_gid_mgmt` (Matan Barak) centralizes IP-based GID population; RoCE v2 GID types; per-type duplication
- **4.10–4.14** — bonding filters and LAG support; default GIDs per type
- **4.19** — GID attribute references (`rdma_get_gid_attr`), `PENDING_DEL` state, `sgid_attr` stored in QPs and AHs
- **5.x** — RCU-protected `ndev` with `roce_gid_ndev_storage`; netns filtering; `QUERY_GID_TABLE` uverbs method (5.9) exposing `netdev_ifindex` to userspace

## Further Reading

- kernel.org — [InfiniBand sysfs files](https://www.kernel.org/doc/html/latest/infiniband/sysfs.html)
- Source — `drivers/infiniband/core/roce_gid_mgmt.c`, `cache.c`
- NVIDIA/Mellanox community docs — "RoCE v2 GID table" and `show_gids` usage
- Related: [[roce-v1-and-v2]], [[rdma-cm-connection-manager]], [[ib-device-and-client-model]], [[network-device-and-napi]], [[network-namespaces]]

## LKML Highlights

- **"IB/core: RoCE GID management" (Matan Barak, Mellanox, 2015)** — moved per-driver IP-to-GID code into the core with netdev notifiers and filters. The debate was about doing firmware writes from notifier context, and settled on the deferred `gid_cache_wq`.
- **"IB/core: Make gid_attr reference counted" (Parav Pandit, 2018, 4.19)** — fixed stale-index use-after-free and wrong-source-address bugs by making QPs and AHs hold GID entry references.
- **Bonding and LAG GID handling (2016–17)** — bond-master and active-slave filters so only one physical RDMA port advertises a bond's IPs, avoiding asymmetric routing and duplicate GIDs. (Message-ids unavailable this session.)
