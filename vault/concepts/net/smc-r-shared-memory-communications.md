---
title: "SMC-R: Shared Memory Communications over RDMA"
category: concept
tags: [net, smc, rdma, sockets, transparent-acceleration, roce]
subsystem: net
kernel_version: "4.11 (SMC-R); 4.19 (SMC-D); 5.10–5.18 (SMCv2 / SMC-Rv2); 6.11 (IPPROTO_SMC)"
researched: 2026-09-26
status: complete
sources:
  - https://www.rfc-editor.org/rfc/rfc7609.html
  - https://lwn.net/Articles/976037/
  - https://lwn.net/Articles/1032749/
  - https://www.ibm.com/support/pages/accelerate-networking-shared-memory-communications-ibm-z-0
  - https://github.com/torvalds/linux/tree/master/net/smc
  - https://github.com/torvalds/linux/blob/master/net/smc/smc.h
  - https://github.com/torvalds/linux/blob/master/net/smc/smc_sysctl.c
  - https://github.com/torvalds/linux/blob/master/net/smc/smc_hs_bpf.c
---

# SMC-R: Shared Memory Communications over RDMA

## Purpose

Most applications will never be rewritten for verbs. **SMC (Shared Memory Communications)** gives unmodified **TCP socket applications** RDMA's benefits: bypassing the TCP/IP stack for the data path, with fewer copies and lower CPU and latency, *transparently*. An SMC socket starts life as a normal TCP connection. During the TCP handshake both sides discover they are SMC-capable, negotiate RDMA resources over that TCP connection, and then move all application data by **RDMA WRITE into a peer's pre-registered receive buffer**, with the TCP connection kept alive only for control and teardown. If either side (or the network) doesn't support SMC, the socket silently stays plain TCP. It comes from IBM (for z Systems), is documented in informational RFC 7609, and is heavily developed by Alibaba for cloud use. The **SMC-R** variant runs over RoCE. **SMC-D** uses intra-host shared memory devices (s390 ISM, or a loopback device) for VM-to-VM or container-to-container traffic.

## Mental Model

SMC is **TCP with a private express lane**. Two neighbours meet over the public road (TCP). If both own a private tunnel (an RDMA NIC on the same RoCE network), they agree in that first conversation to exchange mailbox keys. From then on, when one writes, it drops the bytes straight into the other's **mailbox** (the peer's RMBE, a ring buffer in registered memory) through the tunnel and leaves a small note (a CDC message) saying "I've written up to here". The reader takes bytes out and sends back a note saying "I've read up to here" so the writer knows how much space is free. The public-road connection stays open for goodbyes and emergencies. The applications only ever call `send()` and `recv()`.

## How It Works

**Getting an SMC socket.** Applications opt in (or are opted in) by one of:
- `socket(AF_SMC, SOCK_STREAM, SMCPROTO_SMC|SMCPROTO_SMC6)` — the original dedicated family (`af_smc.c`)
- **`socket(AF_INET[6], SOCK_STREAM, IPPROTO_SMC)`** (6.11, D. Wythe / Alibaba, `smc_inet.c`) — SMC as an AF_INET protocol, so addressing, tooling and **eBPF hooks** (e.g. a BPF program rewriting the protocol at socket creation) work without a new family
- `smc_run` (smc-tools) — an `LD_PRELOAD` shim that rewrites `socket()` calls. It fails for static binaries, which is one motivation for `IPPROTO_SMC`
- `setsockopt(SOL_TCP, TCP_ULP, "smc")` — convert a TCP socket before connecting.

Internally every SMC socket owns an internal **CLC TCP socket** (`smc->clcsock`) that does the real TCP connect or accept.

**Phase 1 — capability discovery (TCP option).** When the CLC socket connects, SMC sets `tp->syn_smc`, which adds an experimental **TCP option (kind 254, ExID "SMCR")** to the SYN and SYN-ACK. If the peer doesn't echo it (a non-SMC host, or a middlebox that strips options), the socket **falls back** to plain TCP immediately (`smc_switch_to_fallback()`), and from then on all socket calls go straight to the TCP socket. There is no penalty beyond the option bytes.

**Phase 2 — CLC handshake (over the TCP connection).** Both sides exchange **Connection Layer Control** messages on the established TCP connection (`smc_clc.c`): *Proposal* (client: supported SMC types and versions, its RoCE GID and MAC or ISM IDs, IP prefix), *Accept* (server: chosen device, its QP number, its RMB's **rkey + virtual address + RMBE index/size**), and *Confirm* (client: the same about its own side). SMCv1 requires both hosts on the same IP subnet and RoCE L2 network. **SMC-Rv2** (5.1x) adds routable RoCE v2 and larger connection counts, and SMCv2 adds EID-based (enterprise ID) peering for SMC-D across subnets. The handshake runs asynchronously in a workqueue (`smc_connect_work`) so non-blocking `connect()` still works. The number of concurrent handshakes can be limited (`limit_smc_hs`), and a **BPF struct_ops "handshake control"** (`smc_hs_bpf.c`, sysctl `hs_ctrl`, 2025–26) lets policy code decide per connection whether to attempt SMC, e.g. only for flows expected to be long-lived.

**Link groups and buffers (`smc_core.c`, `smc_ib.c`, `smc_llc.c`).** RDMA resources are shared, not per-connection. Between two hosts, SMC-R keeps a **link group** (`struct smc_link_group`) of one or more **links** (`struct smc_link`), each an RC QP over a (preferably distinct) RoCE device pair, used for redundancy and load spreading. Each connection gets:
- a **send buffer** (`sndbuf_desc`) in local memory
- an **RMBE**: an element of a registered **Remote Memory Buffer** (`rmb_desc`), the ring buffer the *peer* writes into. RMBs come from size-class pools (16 KB … 1 MB, virtually or physically contiguous per `smcr_buf_type`) and are registered with `IB_ACCESS_REMOTE_WRITE`.

**LLC** (Link Layer Control) messages, exchanged as SENDs on the QPs, add and delete links, confirm rkeys for new RMBs on every link (`smcr_link_reg_buf`), and run keepalive "test link" probes (`smcr_testlink_time`). Parameters such as `smcr_max_links_per_lgr`, `smcr_max_conns_per_lgr`, `smcr_max_send_wr` and `smcr_max_recv_wr` are sysctls.

**Data path — send.** `smc_sendmsg()` → `smc_tx_sendmsg()` copies user data into the connection's send buffer, then `smc_tx_sndbuf_nonempty()` → `smc_tx_rdma_writes()` posts **RDMA WRITE(s)** from the send buffer into the peer's RMBE at the current *producer cursor* (handling ring wrap with two WRs). It follows with a **CDC** message (Connection Data Control, a small SEND, `smc_cdc.c`) carrying the new producer cursor and flags (urgent data, FIN-like `peer_done_writing`, abort). Before writing, the sender checks `peer_rmbe_space`, the space the peer has told it is free, which is the flow-control window. **Autocorking** (`autocorking_size`) delays small writes to batch them, like TCP autocork.

**Data path — receive.** The CDC message arrives as a receive completion (`smc_cdc_rx_handler()`), updates the connection's view of the peer's producer cursor, and wakes readers. `smc_recvmsg()` → `smc_rx_recvmsg()` **copies from the local RMBE** into the user buffer (or splices), advances the *consumer cursor*, and, once enough has been consumed (`rmbe_update_limit`), sends a CDC back with the new consumer cursor so the peer can reuse the space. On the wire this is **one copy on each side** (user → sndbuf, RMBE → user) and zero protocol processing. The kernel TCP stack and softirq networking aren't involved at all, and the RDMA NIC does the transfer.

**Failover.** If a link fails (port down, device removal), connections move to another link in the group. LLC `DELETE LINK` coordinates, and unconfirmed RDMA writes are replayed on the surviving link, so applications notice nothing. If *no* RDMA path remains, the connection is **aborted**: an active SMC connection can't fall back to TCP mid-stream, because the byte stream was never on TCP.

**Closing.** `close()` or `shutdown()` exchange CDC close flags (`smc_close.c`), then the internal TCP connection is closed normally. Buffers go back to the link group's pools for reuse by the next connection, so an established link group amortizes the RDMA setup cost.

**SMC-D and DIBS.** SMC-D replaces RDMA WRITE with writes into a shared-memory **DMB** exposed by an **ISM** device (s390 hypervisor) or, since 6.9, a software **loopback** ISM for same-host containers. In 2025 (Alexandra Winter, IBM) the device side was factored into a generic **DIBS** ("Direct Internal Buffer Sharing") layer (`net/dibs`), cleanly separating ISM and loopback devices from SMC-D as a client.

## Key Data Structures

**`struct smc_sock`** (`smc.h`) — the SMC socket: embeds `struct sock`; `clcsock` (the internal TCP socket), `conn`, `use_fallback`, `fallback_rsn`, connect and accept work.

**`struct smc_connection`** (`smc.h`) — per-connection RDMA state: `lgr`, `lnk`, `peer_rmbe_idx`, `peer_rmbe_size`, `peer_rmbe_space` (the send window), `rtoken_idx` (peer RMB rkey/addr), `sndbuf_desc`, `rmb_desc`, cursors (`tx_curs_prep`, `tx_curs_sent`, `tx_curs_fin`, `local_tx_ctrl`, `local_rx_ctrl`), `rmbe_update_limit`, `tx_cdc_seq`.

**`struct smc_link_group` / `struct smc_link`** (`smc_core.h`) — shared peer relationship: links (QP, CQs, `wr_tx`/`wr_rx` buffers), RMB and sndbuf pools per size class, peer rkey table (`rtokens`).

**`struct smc_buf_desc`** — a send buffer or RMB: pages or vmalloc memory, per-link `mr[]` and `sgt[]`, `used` flag for pool reuse.

**`struct smc_cdc_msg`** (`smc_cdc.h`) — on-wire CDC: sequence number, token, producer and consumer cursors (wrap count + offset), producer flags, connection-state flags.

## Key Functions / Entry Points

- **`smc_create()` / `smc_inet_init_sock()`** — socket creation via AF_SMC or IPPROTO_SMC
- **`smc_connect()` → `__smc_connect()` → `smc_connect_rdma()`**; **`smc_listen_work()`** — CLC handshake, both sides
- **`smc_switch_to_fallback()`** — become plain TCP
- **`smc_tx_sendmsg()` / `smc_tx_rdma_writes()` / `smc_cdc_msg_send()`** (`smc_tx.c`, `smc_cdc.c`) — send path
- **`smc_cdc_rx_handler()` / `smc_rx_recvmsg()`** (`smc_cdc.c`, `smc_rx.c`) — receive path
- **`smc_conn_create()` / `smcr_lgr_reg_rmbs()` / `smc_llc_*`** (`smc_core.c`, `smc_llc.c`) — link group and buffer management
- **`smcr_link_down()` / `smc_switch_conns()`** — failover

## Important Flags & Config Options

- `CONFIG_SMC`, `CONFIG_SMC_DIAG`, `CONFIG_SMC_LO` (loopback ISM), `CONFIG_DIBS`
- sysctls `net.smc.*`: `autocorking_size`, `smcr_buf_type` (physically vs virtually contiguous RMBs), `smcr_testlink_time`, `wmem`, `rmem`, `smcr_max_links_per_lgr`, `smcr_max_conns_per_lgr`, `limit_smc_hs`, `smcr_max_send_wr`, `smcr_max_recv_wr`, `hs_ctrl`
- `net/smc` **pnet table** (`smc_pnet.c`, `smc_pnet` tool) — maps netdevs to RoCE/ISM devices when not discoverable automatically
- smc-tools: `smc_run`, `smcss` (like `ss`), `smcd`/`smcr` stats (netlink, `smc_stats.c`)

## Interactions with Other Subsystems

- **↑ Userspace**: standard sockets (`send`/`recv`/`poll`/`splice`), `IPPROTO_SMC`, `smc_run`; diag via `smc_diag` and netlink
- **→ TCP**: the internal CLC socket, the experimental SYN option, fallback to pure TCP ([[tcp-ip-stack]])
- **→ RDMA core**: an `ib_client`; RC QPs, MRs with remote write, RoCE GIDs (v1 or v2) ([[rdma]], [[memory-registration-and-ib-umem]], [[roce-v1-and-v2]])
- **→ BPF**: IPPROTO_SMC enables BPF-based protocol selection; struct_ops handshake control
- **→ DIBS / ISM**: SMC-D transport
- **Compared with io_uring**: both keep the socket API, but differently. io_uring makes *TCP* cheaper to drive (batched submission, zero-copy send, zcrx receive, registered buffers) while TCP/IP still runs in the kernel. SMC removes TCP/IP from the data path and uses the RDMA NIC as the transport, but still copies once on each side. They can combine: an io_uring application's socket could be an `IPPROTO_SMC` socket ([[io-uring-zero-copy-networking]])

## Design Decisions & Tradeoffs

- **Transparency first.** Keeping the socket API and a real TCP connection makes SMC deployable (no app changes, automatic fallback, familiar addressing and firewalls for connection setup). The cost is two copies (user↔buffer on each end), the CLC handshake latency (bad for short-lived connections, hence `limit_smc_hs` and BPF handshake policy), and that netfilter, TC and TCP instrumentation don't see the data.
- **Shared link groups and RMB pools.** Amortize QP and MR costs across many connections and avoid per-connection registration. The cost is complex lifetime and failover logic across connections.
- **One-sided RDMA WRITE + CDC notification.** Writes land without receiver CPU involvement, and CDCs play the role of TCP ACKs and window updates. It's a simple credit protocol, but the receiver must still copy out.
- **No mid-stream fallback.** Once data flows over RDMA, TCP's sequence space no longer represents the stream, so losing all RDMA paths aborts the connection. Link groups with multiple links mitigate this.
- **SMCv1's L2 restriction** made early SMC-R impractical in routed clouds. SMC-Rv2 over RoCE v2 and Alibaba's work on large-scale cloud usage (eRDMA, a virtualized iWARP-based RDMA, as a transport) widened applicability.

## How It Has Evolved

- **4.11 (2017)** — SMC-R merged (Ursula Braun, IBM; RFC 7609 published 2015)
- **4.19** — SMC-D with the s390 ISM device
- **5.x** — SMCv2 (EID-based SMC-D across subnets, 5.10–5.11), SMC-Rv2 over routable RoCE v2 (5.17–5.18, Karsten Graul); netlink stats; link-group multi-link failover improvements
- **5.18–6.x** — Alibaba contributions: autocorking, sysctls for buffer types and limits, handshake limits, performance work (D. Wythe, Tony Lu, Wen Gu …)
- **6.9** — SMC-D loopback (virtual ISM) for same-host communication on any architecture
- **6.11** — `IPPROTO_SMC`
- **2025–26** — DIBS layer (Alexandra Winter); BPF handshake control (`hs_ctrl`); ongoing hardening

## Further Reading

- IETF — [RFC 7609: IBM's Shared Memory Communications over RDMA (SMC-R) Protocol](https://www.rfc-editor.org/rfc/rfc7609.html)
- LWN — [Introduce IPPROTO_SMC](https://lwn.net/Articles/976037/) (2024)
- LWN — [dibs — Direct Internal Buffer Sharing](https://lwn.net/Articles/1032749/) (2025)
- IBM — [Accelerate networking with Shared Memory Communications](https://www.ibm.com/support/pages/accelerate-networking-shared-memory-communications-ibm-z-0)
- smc-tools — https://github.com/ibm-s390-linux/smc-tools
- Related: [[rdma]], [[tcp-ip-stack]], [[roce-v1-and-v2]], [[io-uring-zero-copy-networking]], [[af-xdp]]

## LKML Highlights

- **`<1717061440-59937-1-git-send-email-alibuda@linux.alibaba.com>`** — "Introduce IPPROTO_SMC" (D. Wythe). SMC sockets via `AF_INET(6)` so eBPF and existing infrastructure apply, replacing `LD_PRELOAD` `smc_run`, which is "completely ineffective in scenarios of static linking".
- **`<20250806154122.3413330-1-wintera@linux.ibm.com>`** — "dibs — Direct Internal Buffer Sharing" (Alexandra Winter). Extracts ISM and loopback into a generic shim with devices and clients, decoupling them from SMC-D.
- **"net/smc: SMC-R v2" (Karsten Graul, IBM, 2021–22)** — made SMC-R routable over RoCE v2 by adding IP-based peer discovery in CLC and GID selection. (Message-id unavailable: lore was unreachable this session.)
