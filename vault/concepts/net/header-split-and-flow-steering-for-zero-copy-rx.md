---
title: "Header Split and Flow Steering for Zero-Copy RX"
category: concept
tags: [net, ethtool, header-split, rss, flow-steering, zero-copy]
subsystem: net
kernel_version: "6.7 (tcp-data-split netlink); 6.14 (hds-thresh, hds_config); 6.12+ (memory-provider guards)"
researched: 2026-09-26
status: complete
explained: "[[header-split-and-flow-steering-for-zero-copy-rx-explained]]"
sources:
  - https://github.com/torvalds/linux/blob/master/net/ethtool/rings.c
  - https://github.com/torvalds/linux/blob/master/net/ethtool/common.c
  - https://github.com/torvalds/linux/blob/master/net/core/netdev_rx_queue.c
  - https://github.com/torvalds/linux/blob/master/include/linux/ethtool.h
  - https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html
  - https://docs.kernel.org/networking/devmem.html
  - https://github.com/torvalds/linux/blob/master/Documentation/networking/netmem.rst
  - https://lwn.net/Articles/1002730/
  - https://lwn.net/Articles/959905/
  - https://lkml.rescloud.iu.edu/2603.2/07047.html
  - https://static.lwn.net/kerneldoc/networking/ethtool-netlink.html
---

# Header Split and Flow Steering for Zero-Copy RX

> 📘 Plain-language version: [[header-split-and-flow-steering-for-zero-copy-rx-explained]]

## Purpose

Both zero-copy receive mechanisms that keep the kernel TCP stack, [[devmem-tcp]] and [[zero-copy-rx-zcrx|io_uring zcrx]], rest on two NIC capabilities configured through ethtool:
1. **Header/data split (HDS)**: the NIC writes each packet's **headers** into one buffer (ordinary kernel memory the stack can read) and its **payload** into another (the zero-copy buffer: device memory or a user area). Without it, headers would land in memory the kernel can't read (GPU) or would require copying payloads out of kernel pages.
2. **Flow steering + RSS isolation**: the specific TCP flows the application wants zero-copy must land on the RX queue(s) bound to the memory provider, and *no other traffic* may land there, because every buffer that queue receives into belongs to the application.

The kernel's job is to expose these knobs uniformly (ethtool netlink), and, crucially, to **refuse configurations that would break a bound provider**: disabling HDS, raising the split threshold, attaching incompatible XDP, or shrinking channel counts below a bound queue.

## Mental Model

A zero-copy RX queue is a **private loading dock** for one tenant. **Header split** is the rule that the paperwork (headers) always goes to the building's front office (kernel memory) while the cargo (payload) goes straight to the tenant's dock. **RSS isolation** takes the dock off the general round-robin rotation so random deliveries don't show up there. **Flow steering rules** are the tenant's standing order: "trucks from this sender, for this port, go to dock 7". The building manager (the kernel) now refuses to let anyone reorganize the docks in ways that would dump strangers' cargo on the tenant or send the tenant's paperwork to the dock.

## How It Works

**Header/data split.**
- **Configuration**: `ethtool -G <if> tcp-data-split on` sets `ETHTOOL_A_RINGS_TCP_DATA_SPLIT` (`UNKNOWN`/`DISABLED`/`ENABLED`), and `ethtool -G <if> hds-thresh N` sets `ETHTOOL_A_RINGS_HDS_THRESH`: the packet size above which headers and data are split (smaller packets arrive whole in the header buffer, the classic "copybreak" behaviour; bnxt defaults to 256). Drivers opt in through `supported_ring_params` (`ETHTOOL_RING_USE_TCP_DATA_SPLIT`, `ETHTOOL_RING_USE_HDS_THRS`) and report `hds_thresh_max`. `ethnl_set_rings()` rejects unsupported attributes with extack messages.
- **State**: the requested setting is remembered in the netdev's config (`dev->cfg->hds_config`, `dev->cfg->hds_thresh`), introduced by Taehee Yoo (bnxt, 6.14), so the core can tell "user asked for HDS" from "driver defaulted it", and can enforce invariants independent of driver state.
- **How NICs split**: typically at the L4 header boundary for TCP (and UDP on some NICs), writing headers to a small buffer from the regular page pool and payload to the "data" ring's buffer from the queue's page pool, which is the memory provider when bound. mlx5 splits packets of all sizes with no configurable threshold, so in 2026 it reports `hds-thresh = hds-thresh-max = 0`.
- **Zero-copy requirement**: a memory provider needs **HDS enabled and `hds-thresh == 0`**. With a threshold, small packets would put *payload* into the header buffer, and the provider would never see it. The application would get `SCM_DEVMEM_LINEAR` data (devmem) or copy-fallback CQEs (zcrx). Drivers must also set `PP_FLAG_ALLOW_UNREADABLE_NETMEM` exactly when HDS is on ([[netmem-and-net-iov-abstraction]]).

**Guards the kernel enforces.**
- **Binding** (`netif_mp_open_rxq()`, `net/core/netdev_rx_queue.c`) fails if `hds_config != ENABLED` ("tcp-data-split is disabled"), `hds_thresh != 0`, any XDP program is attached (XDP could read or redirect unreadable payload), the device lacks `rx_page_size` support when requested, the queue already has a provider or an AF_XDP socket, or the queue is leased to a virtual netdev.
- **Ring changes** (`ethnl_set_rings()`): while any queue has a provider (`dev_get_min_mp_channel_count()`), you "can't disable tcp-data-split while device has memory provider enabled" and "can't set non-zero hds_thresh". Independently, "tcp-data-split can not be enabled with single buffer XDP" (single-buffer XDP needs the whole packet in one linear buffer).
- **Channel changes** (`ethtool_check_max_channel()`): reducing `combined`/`rx` channels below the highest provider-bound queue fails with "requested channel counts are too low for existing memory provider setting", in the same way as for RSS indirection tables and n-tuple rules that reference queues.

**RSS isolation.** RSS hashes each flow's 4-tuple into an **indirection table** of RX queues. To keep unrelated traffic off the zero-copy queues:
- simplest: `ethtool -X <if> equal N` spreads RSS over queues `0..N-1` only, leaving higher queues out of the default table (the zcrx docs' recipe: `ethtool -L <if> combined 2`, `ethtool -X <if> equal 1`, zero-copy on queue 1)
- **RSS contexts** (`ethtool -X <if> context new start K equal M`, ethtool netlink `ETHTOOL_MSG_RSS_CREATE_ACT` in 6.1x) create additional indirection tables. Flow rules can target a *context* rather than a single queue, which spreads zero-copy flows across several provider-bound queues while keeping them out of the default context. The core tracks contexts (`ethtool_rxfh_ctx_alloc()`) and refuses deleting ones still referenced by rules (`ethtool_check_rss_ctx_busy()`).

**Flow steering.** `ethtool -N <if> flow-type tcp6 dst-ip <addr> dst-port <p> action <q>` (or `context <ctx>`) installs an **n-tuple rule** (`ETHTOOL_SRXCLSRLINS` ioctl) that the NIC matches before RSS. Rules are usually keyed on the local port or the peer address of the application's listening socket. Alternatives: **aRFS** (accelerated RFS, `ndo_rx_flow_steer`) steers flows to the queue of the CPU where the consuming thread runs, but it follows CPUs, not provider bindings, so it's unsuitable for zero-copy queues. Some deployments use a TC flower `skip_sw` rule with a `hw_tc`/queue mapping instead.

**What happens when steering is wrong.** Correctness is preserved either way. A zero-copy flow that lands on a normal queue arrives in kernel pages: devmem reports it via `SCM_DEVMEM_LINEAR` (copy), zcrx copies it into the area (`ZCRX_EVENT_COPY`). Stranger traffic that lands on a provider queue consumes provider buffers. For devmem, the stranger's socket can't read it (`tcp_recvmsg` refuses unreadable data without `MSG_SOCK_DEVMEM`) and the data is dropped or errors out, and zcrx copies it out for non-owners. Either way it's wasted buffers, hence isolation.

**Operational recipe (both features).**
```
ethtool -L eth0 combined 16                 # enough queues
ethtool -G eth0 tcp-data-split on hds-thresh 0
ethtool -X eth0 equal 15                    # queues 0-14 for general RSS
ethtool -N eth0 flow-type tcp6 dst-port 5201 action 15   # steer ZC flow to 15
# then: netdev bind-rx (devmem) or IORING_REGISTER_ZCRX_IFQ on queue 15
```
Configuration is out-of-band: the kernel doesn't install rules on the application's behalf, which is a known usability gap.

## Key Data Structures

**`struct kernel_ethtool_ringparam`** (`include/linux/ethtool.h`) — `tcp_data_split`, `hds_thresh`, `hds_thresh_max`, `rx_buf_len`, `cqe_size`, `tx_push` ….

**`dev->cfg` (`struct netdev_config`)** — persisted `hds_config`, `hds_thresh` (user intent, checked by the provider code).

**`struct ethtool_rx_flow_spec`** — n-tuple rule: `flow_type`, header match fields and masks, `ring_cookie` (queue or drop), `location`; with `FLOW_RSS` + `rss_context`.

**`struct ethtool_rxfh_context`** — an extra RSS indirection table and key.

**`struct netdev_rx_queue.mp_params`** — the provider bound to a queue.

## Key Functions / Entry Points

- **`ethnl_set_rings()`** (`net/ethtool/rings.c`) — HDS and threshold changes with XDP and provider guards
- **`netif_mp_open_rxq()` / `netif_mp_close_rxq()`** (`net/core/netdev_rx_queue.c`) — provider binding preconditions
- **`ethtool_check_max_channel()` / `dev_get_min_mp_channel_count()`** (`net/ethtool/common.c`) — channel-count guard
- **`ethtool_rxfh_ctx_alloc()` / `ethtool_check_rss_ctx_busy()`** — RSS contexts
- Driver ops: `get_ringparam`/`set_ringparam`, `get_rxnfc`/`set_rxnfc` (n-tuple), `get_rxfh`/`set_rxfh` (+ context create/modify/remove)

## Important Flags & Config Options

- ethtool: `-G tcp-data-split on|off|auto`, `-G hds-thresh N`, `-X equal N`, `-X context new ...`, `-N flow-type ... action Q|context C`, `-L combined N`, `-K ntuple on`
- Netlink: `ETHTOOL_A_RINGS_TCP_DATA_SPLIT`, `ETHTOOL_A_RINGS_HDS_THRESH(_MAX)`, RSS context messages
- Driver capability bits: `ETHTOOL_RING_USE_TCP_DATA_SPLIT`, `ETHTOOL_RING_USE_HDS_THRS`; page-pool flag `PP_FLAG_ALLOW_UNREADABLE_NETMEM`
- Kernel prerequisites for binding: HDS enabled, `hds_thresh == 0`, no XDP, queue free of AF_XDP and providers

## Interactions with Other Subsystems

- **↑ Userspace**: ethtool (netlink), YNL; orchestration scripts or agents configure queues before binding
- **→ drivers**: HDS implementation, n-tuple tables, RSS contexts, queue-management ops
- **→ XDP / AF_XDP**: mutually exclusive with provider-bound queues ([[xdp]], [[af-xdp]])
- **← devmem / zcrx**: rely on these guarantees ([[devmem-tcp-rx-dmabuf-binding-and-token-recycling]], [[zero-copy-rx-zcrx]])
- **← queue management API**: binding goes through per-queue restart ([[netdev-queue-management-api]])
- **Compared with RDMA**: RDMA NICs don't need header split or steering for zero-copy, because the transport knows each message's destination buffer from the rkey or posted receive. TCP-based zero-copy must *infer* placement from the queue a flow hashes to, which is why this machinery exists ([[rdma]])

## Design Decisions & Tradeoffs

- **Placement by queue, not by message.** Keeping standard TCP means the NIC can't know which *application buffer* a byte belongs to, only which queue. Dedicating queues is the price: less RSS parallelism for everyone else and more operational setup.
- **Kernel-enforced invariants.** Remembering user intent in `dev->cfg` and blocking conflicting changes turned zero-copy from "fragile if an admin touches ethtool" into a checked configuration. The cost is extra coupling between ethtool, XDP and the provider code.
- **Threshold of zero.** Mandatory for providers so no payload ever lands in header buffers. It costs efficiency for tiny packets (every packet uses two buffers).
- **Out-of-band steering.** The kernel doesn't auto-install rules for bound sockets, which keeps policy in userspace but leaves a usability gap; proposals for automatic steering recur on netdev.

## How It Has Evolved

- **pre-6.7** — HDS existed in drivers (e.g. for GRO-friendly buffers) with ad-hoc knobs; `ethtool -N` n-tuple since 2.6.3x; RSS contexts via ioctl (4.x)
- **6.7 (2024)** — `tcp-data-split` in ethtool netlink ring params (ethtool 6.7 userspace)
- **6.12** — devmem TCP adds provider-binding preconditions (HDS on, no XDP)
- **6.14 (2025)** — `hds-thresh` and `hds_config` (Taehee Yoo, bnxt), provider guards in `ethnl_set_rings()`, single-buffer-XDP exclusion
- **6.1x** — RSS context management via netlink; channel checks for memory providers
- **2026** — mlx5 reports `hds-thresh` (always 0); `rx_page_size` capability checks; AF_XDP and provider mutual exclusion and leased-queue checks

## Further Reading

- kernel.org — [io_uring zero copy Rx: NIC configuration](https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html)
- kernel.org — [Device Memory TCP](https://docs.kernel.org/networking/devmem.html)
- kernel.org — [Netlink interface for ethtool](https://static.lwn.net/kerneldoc/networking/ethtool-netlink.html) (RINGS_SET, RSS)
- LWN — [bnxt_en: implement tcp-data-split and thresh option](https://lwn.net/Articles/1002730/)
- Related: [[devmem-tcp]], [[zero-copy-rx-zcrx]], [[netdev-queue-management-api]], [[network-device-and-napi]], [[page-pool]]

## LKML Highlights

- **`<20241218144530.2963326-1-ap420073@gmail.com>`** — "bnxt_en: implement tcp-data-split and thresh option" (Taehee Yoo). Added `hds-thresh` and `hds_config`, auto-disables HDS when single-buffer XDP attaches, and makes devmem setup fail on HDS off or a non-zero threshold, with the settings frozen while devmem runs.
- **"net/mlx5e: Add hds-thresh query support via ethtool" (March 2026)** — mlx5 splits all packet sizes, so it reports `hds-thresh`/`hds-thresh-max` as 0, clarifying the semantics of "no configurable threshold".
- **Memory-provider guards in ethtool (2025)** — channel-count, HDS and threshold checks against `dev_get_min_mp_channel_count()`, so admin changes can't silently break zcrx or devmem bindings. (Message-id unavailable: lore was unreachable this session.)
