---
title: "XDP (eXpress Data Path)"
category: concept
tags: [networking, xdp, bpf, fast-path, packet-processing]
subsystem: net
kernel_version: "4.8"
researched: 2026-09-25
status: complete
explained: "[[xdp-explained]]"
sources:
  - https://kernel-internals.org/net/xdp/
  - https://kernel-internals.org/bpf/
  - https://www.kernel.org/doc/html/latest/networking/xdp-rx-metadata.html
  - https://en.wikipedia.org/wiki/Express_Data_Path
  - https://lwn.net/Articles/728146/
  - https://lwn.net/Articles/736336/
  - https://lwn.net/Articles/749975/
  - https://lwn.net/Articles/815327/
  - https://lwn.net/Articles/825372/
  - https://lwn.net/Articles/937525/
  - https://lwn.net/Articles/919932/
---

# XDP (eXpress Data Path)

> 📘 Plain-language version: [[xdp-explained]]

## Purpose

The normal Linux receive path allocates an `sk_buff`, parses headers, runs netfilter, routing and socket lookup for every packet. That costs microseconds per packet and caps a core at a few million packets per second. DDoS scrubbing, load balancers and forwarding appliances need 10–25+ Mpps per core, which pushed people to kernel-bypass stacks like DPDK. Those take the NIC away from the kernel and burn dedicated polling CPUs. XDP (4.8, 2016) is the in-kernel answer. It runs a verified [[bpf-program-types|BPF program]] inside the NIC driver's receive loop, on the raw DMA buffer, *before* any skb exists. The program decides the packet's fate in tens of nanoseconds: drop it, bounce it back out, redirect it elsewhere, or pass it on to the normal stack. It keeps the kernel's security model, tooling and TCP stack for everything it passes.

## Mental Model

XDP is **a bouncer standing at the loading dock, before the goods reach the warehouse**. The normal stack is the warehouse, with receiving clerks, paperwork (skb metadata), inventory systems and shelving. The bouncer looks at each box straight off the truck and has five options: throw it away (DROP), put it straight back on the truck (TX), send it to another dock or a specific worker (REDIRECT), let it into the warehouse (PASS), or throw it away while writing an incident report (ABORTED). Anything rejected at the dock never costs the warehouse any paperwork.

## How It Works

**Attaching.** Userspace loads a `BPF_PROG_TYPE_XDP` program and attaches it to an interface via netlink (`IFLA_XDP`) or a BPF link (`bpf_link_create(… BPF_XDP …)`). The core calls the driver's `ndo_bpf(XDP_SETUP_PROG)`. A native-XDP driver typically reconfigures its RX rings: it reserves `XDP_PACKET_HEADROOM` (256 bytes) in front of each buffer, uses one packet per page or fragment, and switches its buffers to a [[page-pool]] registered as the queue's memory model with `xdp_rxq_info_reg_mem_model(MEM_TYPE_PAGE_POOL)`. It also allocates XDP transmit queues so `XDP_TX` and redirects don't contend with the normal stack's TX locks. Three modes exist:
- **Native** (`XDP_FLAGS_DRV_MODE`): in the driver; the fast path.
- **Generic** (`XDP_FLAGS_SKB_MODE`, 4.12): runs from `netif_receive_skb` on an already-built skb (`do_xdp_generic()`), for any device. It exists for portability and testing and brings no speed advantage.
- **Offload** (`XDP_FLAGS_HW_MODE`): the program is JIT-compiled for the NIC itself. In practice only Netronome nfp supported it.

Since 6.3, drivers advertise what they support (basic, redirect, ndo_xmit, zero-copy, multi-buffer, RX metadata) through `xdp_features`, visible via the netdev netlink family.

**The per-packet fast path.** In its [[network-device-and-napi|NAPI]] poll, the driver takes a completed RX descriptor and, instead of building an skb, fills a stack-allocated `struct xdp_buff` using `xdp_init_buff()`/`xdp_prepare_buff()`:
- `data_hard_start` → start of the buffer (including headroom)
- `data` → first byte of the packet
- `data_end` → one past the last byte
- `data_meta` → start of an optional metadata area just before `data`
- `rxq` → the `xdp_rxq_info` (ifindex, queue, memory model)
- `frame_sz` → total buffer size, so programs can grow the packet safely

It calls `bpf_prog_run_xdp(prog, &xdp)`, which runs the JITed program. The verifier has already proven that every packet access is bounds-checked against `data_end`, so the program runs with no further runtime checks. Programs can:
- move `data` with `bpf_xdp_adjust_head()` (push or pop an encapsulation header)
- trim or extend with `bpf_xdp_adjust_tail()`
- reserve metadata with `bpf_xdp_adjust_meta()`
- look up [[bpf-maps]] (blocklists, counters, forwarding tables)
- call `bpf_fib_lookup()` to consult the kernel's routing and neighbour tables
- call RX-metadata kfuncs (6.3+) such as `bpf_xdp_metadata_rx_hash()`, `bpf_xdp_metadata_rx_timestamp()` and `bpf_xdp_metadata_rx_vlan_tag()` to read what the NIC descriptor reported

**Acting on the verdict.** The driver switches on the return value:
- **`XDP_DROP`**: the buffer goes straight back to the RX ring's page pool (`page_pool_recycle_direct()`), usually into the lockless cache, so a dropped packet costs almost nothing but the program's run time. This is where the headline numbers come from: about 24–26 Mpps per core for drops in the CoNEXT 2018 paper.
- **`XDP_PASS`**: the driver builds an skb around the same buffer (`build_skb()`/`napi_build_skb()` using the reserved headroom, so no copy) and continues with `napi_gro_receive()`. The skb is marked for page-pool recycling. Custom metadata can be passed to TC programs via `data_meta`.
- **`XDP_TX`**: the buffer is converted to a TX descriptor on the *same* device's XDP TX ring, typically batched and flushed at the end of the poll. Useful for load balancers that rewrite headers and bounce packets back out.
- **`XDP_REDIRECT`**: covered next.
- **`XDP_ABORTED`**: dropped, with the `xdp:xdp_exception` tracepoint fired. It signals a program error, not a policy drop.

**Redirect (4.14+).** A program calls `bpf_redirect_map(&map, key, flags)` (or `bpf_redirect(ifindex)`), which stores the target in the per-task redirect state (`struct bpf_redirect_info`, in `bpf_net_ctx` since 6.11) and returns `XDP_REDIRECT`. The driver then calls `xdp_do_redirect()`, which dispatches on the map type:
- **`DEVMAP`/`DEVMAP_HASH`**: transmit via another device's `ndo_xdp_xmit()`. Frames are queued per destination in a bulk queue and sent in batches.
- **`CPUMAP`** (4.15): enqueue the frame to a ptr_ring for another CPU, whose kthread builds the skb and runs the stack there. It is software RSS for NICs that spread flows poorly and can itself run a second XDP program (5.9).
- **`XSKMAP`** (4.18): deliver to an AF_XDP socket in userspace. With zero-copy drivers the packet was DMA'd directly into the socket's UMEM, so the kernel just posts a descriptor.

Before redirecting, the `xdp_buff` is converted to an `xdp_frame` (`xdp_convert_buff_to_frame()`), a compact descriptor stored in the packet's own headroom. It remembers the memory model, so whoever finally frees it calls `xdp_return_frame()` (or the bulk variant), and the page returns to the originating page pool even from another device or CPU. At the end of the NAPI poll the driver calls `xdp_do_flush()` to push all bulk queues out. Batching is why redirect forwarding approaches drop-level rates.

**Multi-buffer (5.18).** Originally XDP required each packet to fit in one page, which ruled out jumbo frames and LRO/GRO-sized buffers. With multi-buffer support, a large packet is a head buffer plus fragments recorded in the `skb_shared_info` at the end of the head page (`xdp_buff->flags & XDP_FLAGS_HAS_FRAGS`). Programs must be loaded as frags-aware (`BPF_F_XDP_HAS_FRAGS`, section `xdp.frags`) and use `bpf_xdp_load_bytes()`/`bpf_xdp_store_bytes()` for data beyond the linear part. AF_XDP gained the matching `XDP_PKT_CONTD` descriptor flag (6.6).

**Failure paths.** If a redirect target's queue is full or the device lacks `ndo_xdp_xmit`, the frame is freed back to its pool and `xdp:xdp_redirect_err` fires. If the program exceeds its bounds, the verifier rejected it at load time, so there is no per-packet check. If the page pool is exhausted, the driver can't refill RX descriptors and drops at the hardware level, which is visible in `ethtool -S` counters such as `rx_xdp_drop`, `rx_xdp_redirect` and `rx_xdp_tx_errors`.

## Key Data Structures

**`struct xdp_buff`** (`include/net/xdp.h`) — per-packet context during the program run.
- `data`, `data_end`, `data_meta`, `data_hard_start` — packet bounds
- `rxq` — `struct xdp_rxq_info` (dev, queue_index, mem model)
- `frame_sz`, `flags` (`XDP_FLAGS_HAS_FRAGS`, `XDP_FLAGS_FRAGS_PF_MEMALLOC`)

**`struct xdp_frame`** — persistent form of a packet for redirect or TX, stored in the headroom: `data`, `len`, `headroom`, `metasize`, `frame_sz`, `mem_type`, `dev_rx`, `flags`.

**`struct xdp_rxq_info`** — per-RX-queue registration: `dev`, `queue_index`, `napi_id`, `mem` (type + page pool).

**`struct xdp_md`** (uapi) — the BPF-visible context: `data`, `data_end`, `data_meta`, `ingress_ifindex`, `rx_queue_index`, `egress_ifindex`.

## Key Functions / Entry Points

**`bpf_prog_run_xdp()`** (`include/net/xdp.h`) — driver runs the program.
**`xdp_init_buff()` / `xdp_prepare_buff()`** — driver fills the context.
**`xdp_do_redirect()` / `xdp_do_flush()`** (`net/core/filter.c`) — redirect dispatch and batch flush.
**`xdp_convert_buff_to_frame()`, `xdp_return_frame()` / `xdp_return_frame_bulk()`** (`net/core/xdp.c`) — frame lifetime.
**`xdp_rxq_info_reg()` / `xdp_rxq_info_reg_mem_model()`** — queue registration.
**`do_xdp_generic()`** (`net/core/dev.c`) — generic XDP.
**`dev_xdp_attach()`** / `ndo_bpf` / `ndo_xdp_xmit` — attach and transmit hooks.

## Important Flags & Config Options

- Attach flags: `XDP_FLAGS_DRV_MODE`, `XDP_FLAGS_SKB_MODE`, `XDP_FLAGS_HW_MODE`, `XDP_FLAGS_UPDATE_IF_NOEXIST`, `XDP_FLAGS_REPLACE`.
- `BPF_F_XDP_HAS_FRAGS` — multi-buffer-aware program.
- `BPF_F_BROADCAST`, `BPF_F_EXCLUDE_INGRESS` — devmap broadcast redirect (5.13).
- Map types `BPF_MAP_TYPE_DEVMAP(_HASH)`, `CPUMAP`, `XSKMAP`.
- `CONFIG_XDP_SOCKETS` — AF_XDP.
- `ip link set dev X xdp{,generic,drv,offload} obj prog.o`, `bpftool net`, `xdp-loader` (xdp-tools, supports multiple programs via libxdp dispatcher).

## Interactions with Other Subsystems

- **↑ Userspace**: libbpf/libxdp loaders, `bpftool`, and AF_XDP applications (DPDK's AF_XDP PMD, Suricata, load balancers such as Katran and Cilium).
- **← [[network-device-and-napi]]**: runs inside the driver's NAPI poll, once per received buffer.
- **→ [[page-pool]]**: the standard memory model; DROP/TX/REDIRECT recycling relies on it.
- **→ [[sk-buff]]**: XDP_PASS builds skbs around XDP buffers without copying.
- **→ [[bpf-maps]] / [[bpf-helpers-and-kfuncs]]**: redirect maps, lookup tables, `bpf_fib_lookup()`, RX metadata kfuncs.
- **→ [[af-xdp]]**: XSKMAP redirect delivers to userspace sockets.
- **↔ [[netfilter]] / TC**: XDP runs before both. TC BPF (`sch_clsact`) is the skb-level complement for egress and for work needing skb metadata.

## Design Decisions & Tradeoffs

- **In the driver, before the skb.** Avoiding skb allocation and the stack is where the speed comes from, but every driver must implement XDP itself (ring layout, headroom, TX queues, memory model). Feature coverage across drivers has always been uneven, which `xdp_features` now at least makes visible.
- **Programmable, not bypass.** Unlike DPDK, XDP keeps the NIC shared with the kernel, needs no dedicated polling cores, and passes unhandled traffic to the normal stack. The cost is roughly 10–20% lower peak throughput than a tuned bypass stack, which the CoNEXT paper accepted as the price of integration.
- **One page per packet (originally).** This simplified bounds reasoning and recycling but wasted memory for small packets and excluded jumbo frames until multi-buffer arrived (5.18), which in turn forced programs to opt in explicitly.
- **Memory-model-aware frames.** Making `xdp_frame` carry its memory type let redirects cross devices and CPUs while still returning pages to the right pool. That was one of the original motivations for [[page-pool]].
- **Minimal metadata by default.** An `xdp_buff` carries no checksum, hash or timestamp, to stay cheap. Kfunc-based metadata (6.3) exposes hardware hints on demand instead of paying for them per packet.
- **Per-CPU redirect state vs PREEMPT_RT.** The original per-CPU `bpf_redirect_info` assumed NAPI couldn't be preempted. Moving it into a per-task `bpf_net_ctx` (6.11) made XDP work on real-time kernels.

## How It Has Evolved

- **4.8 (2016)** — XDP introduced (mlx4 first): DROP, PASS, TX.
- **4.12** — generic XDP.
- **4.14** — `XDP_REDIRECT` with devmap (John Fastabend); 4.15 cpumap (Jesper Dangaard Brouer).
- **4.16–4.18** — `xdp_rxq_info`, memory return API and `xdp_frame`, page-pool integration; AF_XDP sockets (Björn Töpel, Magnus Karlsson).
- **5.3–5.4** — AF_XDP zero-copy in more drivers; need_wakeup.
- **5.8–5.9** — programs attached to devmap and cpumap entries; BPF links for XDP.
- **5.13** — devmap broadcast.
- **5.18** — XDP multi-buffer (Lorenzo Bianconi, Eelco Chaudron).
- **6.3** — `xdp_features` netlink advertisement; RX metadata kfuncs (Stanislav Fomichev).
- **6.6** — AF_XDP multi-buffer.
- **6.11** — `bpf_net_ctx` redirect state for PREEMPT_RT.
- **2024–2026** — AF_XDP TX metadata (checksum offload, launch time), more drivers with multi-buffer and metadata support, cross-OS spread (XDP for Windows, 2022).

## Further Reading

1. [Implement XDP bpf_redirect — LWN](https://lwn.net/Articles/728146/)
2. [New bpf cpumap type for XDP_REDIRECT — LWN](https://lwn.net/Articles/736336/)
3. [XDP redirect memory return API — LWN](https://lwn.net/Articles/749975/)
4. [XDP extend with knowledge of frame size — LWN](https://lwn.net/Articles/815327/)
5. [xsk: multi-buffer support — LWN](https://lwn.net/Articles/937525/)
6. [XDP RX metadata — kernel.org](https://www.kernel.org/doc/html/latest/networking/xdp-rx-metadata.html)
7. [kernel-internals.org — XDP](https://kernel-internals.org/net/xdp/)
8. *The eXpress Data Path: Fast Programmable Packet Processing in the Operating System Kernel* — Høiland-Jørgensen et al., CoNEXT 2018.

## LKML Highlights

> The LKML search tool was unreachable during this run; highlights are drawn from LWN patch coverage.

- **"Implement XDP bpf_redirect" (John Fastabend, 2017)** — introduced devmap and `bpf_redirect_map()`. The design choice to redirect through a map rather than a raw ifindex enabled batching and safe device teardown.
- **"XDP redirect memory return API" (Jesper Dangaard Brouer, 2018)** — created `xdp_frame` and per-queue memory models so frames can be freed correctly after crossing devices. It led directly to [[page-pool]].
- **"xsk: multi-buffer support" (2023)** — extended AF_XDP with `XDP_PKT_CONTD` to match 5.18's XDP multi-buffer, finishing jumbo-frame support end to end.
