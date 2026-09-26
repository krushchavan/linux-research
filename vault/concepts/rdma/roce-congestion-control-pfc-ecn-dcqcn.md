---
title: "RoCE Congestion Control: PFC, ECN and DCQCN"
category: concept
tags: [rdma, roce, congestion-control, pfc, ecn, dcqcn, dcb]
subsystem: rdma
kernel_version: "3.x (dcbnl PFC); 4.x (mlx5 DCQCN params, CNP counters); 7.x/2026 (pause-storm events)"
researched: 2026-09-26
status: complete
sources:
  - https://conferences.sigcomm.org/sigcomm/2015/pdf/papers/p523.pdf
  - https://www.microsoft.com/en-us/research/publication/congestion-control-for-large-scale-rdma-deployments/
  - https://docs.broadcom.com/doc/NCC-WP1XX
  - https://dl.acm.org/doi/10.1145/3341302.3342085
  - https://dl.acm.org/doi/10.1145/2785956.2787510
  - https://research.google/pubs/swift-delay-is-simple-and-effective-for-congestion-control-in-the-datacenter/
  - https://enterprise-support.nvidia.com/s/article/introduction-to-resilient-roce---faq
  - https://github.com/sonic-net/SONiC/wiki/PFC-Watchdog
  - https://ratatoskr.run/linux-rdma/2026/03/3436619/t
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/hw/mlx5/cong.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/hw/mlx5/counters.c
  - https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/mellanox/mlx5/core/en_dcbnl.c
  - https://github.com/torvalds/linux/blob/master/include/uapi/linux/dcbnl.h
  - https://github.com/torvalds/linux/blob/master/include/uapi/linux/ethtool.h
---

# RoCE Congestion Control: PFC, ECN and DCQCN

## Purpose

RoCE inherits InfiniBand's transport, which was designed for a **lossless** link layer. IB switches use credit-based flow control and never drop packets for congestion, so the IB RC transport recovers from loss crudely, with go-back-N retransmission after a timeout or NAK. On ordinary Ethernet, where switches drop on buffer overflow, even small loss rates collapse RoCE throughput. Making RoCE work therefore takes two cooperating mechanisms:
1. **PFC** (Priority Flow Control) makes one traffic class *lossless* hop by hop, by pausing upstream senders before buffers overflow.
2. **End-to-end congestion control**, classically **DCQCN**, driven by **ECN** marks, slows the actual sources early so PFC rarely has to fire, because PFC pauses cause head-of-line blocking, congestion spreading, and in the worst case deadlock.

Almost all of this runs in NIC firmware and switches. The Linux kernel's role is **configuration and observability**: DCB netlink for PFC/ETS/DSCP mapping, driver knobs for DCQCN parameters, ToS selection for RDMA connections, and counters.

## Mental Model

Think of a **highway with on-ramp metering**. **PFC** is a traffic officer at each interchange who holds up a hand ("stop, lane 3 only") when the road ahead is full. Nothing crashes (no drops), but a jam in one place backs up through every interchange behind it, even for cars headed elsewhere (head-of-line blocking and congestion spreading). If officers wait on each other in a circle, traffic freezes for good (PFC deadlock). **ECN + DCQCN** is on-ramp metering: congested road sections paint a mark on passing cars (ECN CE bit), the destination sends a postcard back to the car's owner (CNP), and the owner's NIC slows that car's on-ramp rate, then gradually speeds it up again. Good metering means the officers rarely have to raise their hands.

## How It Works

**Step 1 — classify RoCE traffic into a lossless class.** Ethernet has 8 priorities (PCP bits in the VLAN tag), and DCB-capable NICs and switches can also classify by **DSCP** in the IP header, which is preferred for RoCE v2 because it survives routing and doesn't need VLANs. RoCE traffic gets a specific DSCP (commonly 26), mapped to a priority (commonly 3) that is PFC-enabled. CNPs get their own high priority (commonly DSCP 48) so congestion feedback isn't itself congested. In Linux:
- the rdma_cm ToS for connections comes from `rdma_set_service_type()`/`RDMA_OPTION_ID_TOS` or configfs `default_roce_tos` (e.g. `106` = DSCP 26 with ECT bits set); raw verbs users set `traffic_class` in the AH/QP attributes
- the NIC is told to *trust DSCP* and given a DSCP-to-priority map through **DCB netlink** `ieee_setapp` with selector `IEEE_8021QAZ_APP_SEL_DSCP` (mlx5: `mlx5e_dcbnl_ieee_setapp`), set with `dcb app` (iproute2) or vendor tools.

**Step 2 — make that priority lossless: PFC.** `dcbnl` (`net/dcb/dcbnl.c`) carries IEEE 802.1Qaz/Qbb configuration to drivers:
- `ieee_setpfc(struct ieee_pfc)` — `pfc_en` bitmap of priorities to protect; `delay` (cable/PHY allowance for headroom); per-priority `requests`/`indications` counters (pause frames sent and received)
- `ieee_setets` — ETS bandwidth shares and priority-to-traffic-class mapping, so RoCE gets guaranteed bandwidth
- `dcbnl_setbuffer` — receive buffer sizes and priority-to-buffer mapping. PFC needs **headroom**: after sending PAUSE, the port must still absorb the bytes in flight on the wire (cable delay + MTU + response time), which is why `delay`/cable length matters.

When a lossless ingress buffer crosses its XOFF threshold, the NIC or switch sends a **PFC PAUSE** for that priority to its upstream neighbour, which stops transmitting that priority (others keep flowing) until XON. Configure with `dcb pfc set dev eth0 prio-pfc 3:on` or `mlnx_qos -i eth0 --pfc 0,0,0,1,0,0,0,0`. Switches must match exactly.

**Step 3 — slow sources before PFC fires: ECN + DCQCN.** RoCE v2 packets are sent ECN-capable (ECT). DCQCN (Zhu et al., SIGCOMM 2015; Microsoft + Mellanox) has three roles:
- **Congestion Point (switch)**: RED/WRED-style marking. As egress queue depth goes from `Kmin` to `Kmax`, packets are marked **CE** with rising probability (up to `Pmax`). The ECN threshold is set well below the PFC XOFF threshold, so marking starts first.
- **Notification Point (receiver NIC)**: on receiving CE-marked RoCE packets for a flow (QP), it sends a **CNP** (a special BTH opcode, 0x81) back to the sender, at most one per flow per `np_min_time_between_cnps` (e.g. 50 µs). CNPs carry their own DSCP/priority (`np_cnp_dscp`, `np_cnp_prio`).
- **Reaction Point (sender NIC)**: per QP, a rate limiter with current rate `Rc`, target rate `Rt`, and congestion estimate `α`. On a CNP: `Rt ← Rc`, `Rc ← Rc·(1 − α/2)`, `α ← (1 − g)·α + g`. Without CNPs, `α` decays every `rp_dce_tcp_rtt` period, and the rate *recovers* in phases driven by a timer (`rp_time_reset`) and a byte counter (`rp_byte_reset`): **fast recovery** (`Rc ← (Rt + Rc)/2`, default 5 steps, `rp_threshold`), then **additive increase** (`Rt += rp_ai_rate`), then **hyper increase** (`Rt += rp_hai_rate`). Clamps (`rp_min_rate`, `rp_max_rate`, `rp_min_dec_fac`, `rp_rate_to_set_on_first_cnp`) bound it.

It is rate-based rather than window-based because RDMA NICs pace at line rate in hardware without per-packet ACK clocking. Its heritage is QCN (802.1Qau), moved to IP ECN for L3.

**In the kernel: mlx5 as the example.** `drivers/infiniband/hw/mlx5/cong.c` exposes DCQCN tunables through **debugfs** (`/sys/kernel/debug/mlx5/<pci>/cc_params/`): `rp_*` (reaction point: `rp_ai_rate`, `rp_hai_rate`, `rp_time_reset`, `rp_byte_reset`, `rp_threshold`, `rp_min_dec_fac`, `rp_initial_alpha_value`, `rp_gd`, `rp_dce_tcp_g`, `rp_dce_tcp_rtt` ...), `np_*` (`np_min_time_between_cnps`, `np_cnp_dscp`, `np_cnp_prio_mode`, `np_cnp_prio`) and `rtt_resp_dscp` (for RTT-probe-based algorithms). Reads and writes become `QUERY_CONG_PARAMS`/`MODIFY_CONG_PARAMS` firmware commands on the `cong_control_r_roce_ecn_rp` and `..._np` nodes. Per-priority enable is vendor tooling (sysfs in out-of-tree OFED, or firmware defaults). Congestion **counters** (`counters.c`) appear in `rdma statistic` and sysfs `hw_counters`: `np_ecn_marked_roce_packets`, `np_cnp_sent`, `rp_cnp_handled`, `rp_cnp_ignored`, `roce_slow_restart_cnps`, plus per-QP optional counters `cc_rx_cnp_pkts`/`cc_tx_cnp_pkts`. Other vendors (bnxt_re, irdma) implement DCQCN variants with their own knobs.

**Failure modes and guards.**
- **Congestion spreading / victim flows**: PFC pauses a whole priority on a link, so flows not headed to the hotspot stall too. DCQCN tuning (marking early) is the mitigation.
- **PFC deadlock**: cyclic buffer dependencies, from routing loops, flooding, or up-down routing violations after link failures, freeze a priority permanently.
- **Pause storms**: a host whose NIC can't drain its receive buffer (hung driver, stuck PCIe) sends PAUSE forever, freezing its switch port and spreading upstream. Switches run a **PFC watchdog** (SONiC, Junos, Cumulus) that drops or disables PFC on a queue stuck paused. NICs have **stall prevention**: ethtool tunable `ETHTOOL_PFC_PREVENTION_TOUT` (`ethtool --set-tunable eth0 pfc-prevention-tout 100`; `PFC_STORM_PREVENTION_AUTO` or `DISABLE`) makes the NIC stop sending pauses after the timeout (mlx5: `mlx5e_set_pfc_prevention_tout` → port stall watermarks). In 2026 (Mohsin Bashir, net-next, 7.x) the tunable was documented to cover *global pause* storms too, ethtool gained a `tx_pause_storm_events` statistic, and fbnic and mlx5 report storm events.

**Beyond DCQCN.**
- **TIMELY** (Google, SIGCOMM 2015) and **Swift** (Google, SIGCOMM 2020): *delay-based*, using NIC hardware timestamps for RTT. Swift runs on Google's own stack. mlx5's `rtt_resp_dscp` supports RTT-probe-based variants in firmware.
- **HPCC** (Alibaba, SIGCOMM 2019): uses switch **in-band network telemetry (INT)** for exact link load. Reported flow-completion-time gains up to 95% over DCQCN and TIMELY, and it avoids DCQCN's roughly 15 tuning knobs.
- **Resilient / lossy RoCE**: ECN-driven congestion control *without* PFC (ConnectX-4 and later), plus NIC-side selective repeat and adaptive retransmission, so occasional drops cost one packet, not a window.
- **Programmable CC and Ultra Ethernet**: newer NICs (NVIDIA Spectrum-X, AMD Pensando, Broadcom) offer programmable CC engines, packet spraying and receiver-driven schemes. The UEC transport defines standard CC for AI fabrics.

## Key Data Structures

**`struct ieee_pfc`** (`include/uapi/linux/dcbnl.h`) — `pfc_cap`, `pfc_en` (bitmap of lossless priorities), `mbc`, `delay`, `requests[8]`, `indications[8]`.

**`struct ieee_ets`** — traffic-class bandwidth allocation and priority-to-TC map.

**`struct dcbnl_buffer`** — `prio2buffer[8]`, `buffer_size[8]`, `total_size`: lossless headroom sizing.

**`struct dcb_app`** — `{selector, priority, protocol}`; with `IEEE_8021QAZ_APP_SEL_DSCP`, maps DSCP to priority.

**mlx5 `enum mlx5_ib_dbg_cc_types` / `mlx5_ib_dbg_cc_name[]`** (`drivers/infiniband/hw/mlx5/cong.c`) — the exposed DCQCN parameter set.

## Key Functions / Entry Points

- **`dcbnl_ieee_set()` → `ops->ieee_setpfc` / `ieee_setets` / `ieee_setapp`** (`net/dcb/dcbnl.c`)
- **`mlx5e_dcbnl_ieee_setpfc()` / `mlx5e_dcbnl_setbuffer()` / `mlx5e_dcbnl_ieee_setapp()`** (`en_dcbnl.c`) — mlx5 PFC, buffers, DSCP trust
- **`mlx5_ib_init_cong_debugfs()` / `mlx5_ib_set_cc_params()`** (`hw/mlx5/cong.c`) — DCQCN tunables
- **`mlx5_ib_query_cong_counters()`** (`hw/mlx5/counters.c`) — ECN and CNP statistics
- **`mlx5e_set_pfc_prevention_tout()`** (`en_ethtool.c`) — stall and pause-storm prevention
- **`rdma_set_service_type()`** (`cma.c`) — per-connection ToS for rdma_cm users

## Important Flags & Config Options

- `CONFIG_DCB` — DCB netlink support
- iproute2 `dcb` (`dcb pfc`, `dcb ets`, `dcb app`, `dcb buffer`), `lldptool`, vendor `mlnx_qos`
- configfs `default_roce_tos`; verbs `traffic_class`
- mlx5 debugfs `cc_params/*` (reaction and notification point parameters)
- ethtool tunable `pfc-prevention-tout` (`ETHTOOL_PFC_PREVENTION_TOUT`), pause stats incl. `tx_pause_storm_events`
- Switch side: ECN `Kmin`/`Kmax`/`Pmax`, PFC XOFF/XON thresholds, headroom, PFC watchdog

## Interactions with Other Subsystems

- **↑ Userspace / operators**: `dcb`, `ethtool -a/-S`, `rdma statistic`, `mlnx_qos`, `show_gids`; perftest with `--tclass`
- **→ net / DCB**: `dcbnl` configuration path shared with FCoE and NVMe/TCP QoS; `ethtool` tunables and pause stats
- **→ rdma_cm**: ToS selection ([[rdma-cm-connection-manager]])
- **← RoCE v2**: provides the IP ECN field and CNP opcode that make end-to-end CC possible ([[roce-v1-and-v2]])
- **vs TCP**: TCP's congestion control (CUBIC, BBR, DCTCP) runs in the kernel per socket and tolerates loss. RDMA's runs in the NIC per QP and wants no loss. DCTCP and DCQCN share the ECN-fraction idea (`α`). iWARP inherits TCP's CC in NIC offload ([[iwarp-transport]])

## Design Decisions & Tradeoffs

- **Lossless L2 vs smarter transport.** RoCE chose to keep IB's simple transport and make Ethernet lossless (PFC). That was cheap in silicon early on, but pushed complexity into fabric operations: headroom, deadlocks, storms, and the Microsoft SIGCOMM 2016 lessons. The industry has since swung towards better NIC transports (selective repeat, lossy RoCE), converging with iWARP's original premise.
- **Rate-based, per-QP control in NIC hardware.** Line-rate reaction without host CPU, but many knobs (DCQCN has about 15), and tuning depends on fabric RTT, buffer sizes and incast degree. That motivated HPCC (INT) and delay-based schemes with fewer parameters.
- **ECN thresholds below PFC thresholds.** The design intent is "CC first, PFC as the safety net". Mis-set thresholds give either chronic pausing or under-utilization.
- **Kernel as configuration plane only.** Keeps the data path in hardware. The cost is vendor-specific knobs (debugfs, out-of-tree sysfs) and uneven observability, which recent upstream work (ethtool pause-storm stats, per-QP CNP counters) is standardizing.

## How It Has Evolved

- **2011–2012** — DCB netlink (802.1Qaz ETS/PFC/APP) in Linux 2.6.3x–3.x for FCoE and iSCSI, later reused by RoCE
- **2015** — DCQCN (SIGCOMM) and TIMELY (SIGCOMM); Mellanox ConnectX-3 Pro/4 ship DCQCN; mlx5 congestion parameters and counters upstream (4.x)
- **2016** — Microsoft "RDMA over Commodity Ethernet at Scale" (SIGCOMM) documents PFC deadlocks and pause storms and motivates watchdogs
- **2017–2018** — mlx5 PFC stall prevention via ethtool tunable (4.1x); DSCP trust and buffer configuration in dcbnl (4.1x–4.2x)
- **2019–2020** — HPCC, Swift; Resilient RoCE widely deployed
- **2023–2026** — AI fabrics: programmable CC, packet spraying, Ultra Ethernet; per-QP CNP counters; 2026 ethtool `tx_pause_storm_events` and pause-storm coverage of `pfc-prevention-tout` (fbnic, mlx5)

## Further Reading

- Paper — [Congestion Control for Large-Scale RDMA Deployments (DCQCN)](https://conferences.sigcomm.org/sigcomm/2015/pdf/papers/p523.pdf), SIGCOMM 2015
- Broadcom — [Introduction to Congestion Control for RoCE](https://docs.broadcom.com/doc/NCC-WP1XX)
- Paper — [HPCC: High Precision Congestion Control](https://dl.acm.org/doi/10.1145/3341302.3342085), SIGCOMM 2019
- Paper — [TIMELY](https://dl.acm.org/doi/10.1145/2785956.2787510) (2015); [Swift](https://research.google/pubs/swift-delay-is-simple-and-effective-for-congestion-control-in-the-datacenter/) (2020)
- NVIDIA — [Introduction to Resilient RoCE FAQ](https://enterprise-support.nvidia.com/s/article/introduction-to-resilient-roce---faq)
- SONiC — [PFC Watchdog](https://github.com/sonic-net/SONiC/wiki/PFC-Watchdog)
- Guo et al. — "RDMA over Commodity Ethernet at Scale", SIGCOMM 2016
- Related: [[roce-v1-and-v2]], [[rdma]], [[traffic-control-qdisc]], [[tcp-ip-stack]]

## LKML Highlights

- **"net: ethtool: Track TX pause storm" (Mohsin Bashir, net-next V4, March 2026)** — adds the `tx_pause_storm_events` counter, documents `ETHTOOL_PFC_PREVENTION_TOUT` as covering both PFC and global-pause storm prevention, and implements it in fbnic (hardware detection, default 500 ms) and mlx5 (stall metrics aggregated across priorities). Tariq Toukan's review covered partial-stat failure semantics. Applied to net-next on 2026-03-05.
- **mlx5 congestion control debugfs (Parav Pandit / Mellanox, 2017)** — exposed DCQCN reaction and notification point parameters and congestion counters upstream instead of only through out-of-tree OFED.
- **dcbnl DSCP APP selector and buffer configuration (Huy Nguyen, 2018)** — made DSCP-based trust and lossless headroom configurable through standard netlink, the prerequisite for routable RoCE v2 without VLAN PCP. (Message-ids unavailable: lore was unreachable this session.)
