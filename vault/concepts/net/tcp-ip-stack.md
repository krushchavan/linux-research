---
title: "TCP/IP Stack"
category: concept
tags: [networking, tcp, udp, congestion-control, socket, transport-layer]
subsystem: net
kernel_version: "2.4"
researched: 2026-04-14
status: complete
explained: "[[tcp-ip-stack-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html
  - https://lwn.net/Articles/168894/
  - https://kernel-internals.org/site-index/
---

# TCP/IP Stack

> 📘 Plain-language version: [[tcp-ip-stack-explained]]

## Purpose

The TCP/IP stack implements the transport and internet layers of the network protocol suite: TCP provides reliable, ordered, full-duplex byte streams with congestion control and flow control; UDP provides lightweight unreliable datagrams. Both are exposed to userspace as POSIX sockets. The stack must simultaneously handle millions of concurrent connections on server hardware while achieving microsecond-range per-packet processing time.

## Mental Model

Think of TCP as a **postal service that guarantees delivery and order**. The sender wraps data into numbered envelopes (segments), the receiver sends acknowledgement receipts back, and any unacknowledged envelope is re-sent after a timeout. The sender also watches how fast the postal system can absorb letters (congestion control) to avoid flooding the post office. UDP is a **postcard service** — write the address, drop it in the box, forget about it. No acknowledgement, no ordering, no re-send.

## How It Works

**Socket creation and the protocol hierarchy.** When userspace calls `socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)`, the kernel allocates a `struct sock` via `tcp_prot.create()`. The sock is extended into `inet_sock` (adds source/destination IP and port) and further into `tcp_sock` (adds all TCP state: sequence numbers, congestion window, retransmit timer, etc.). The `tcp_prot` operations table wires the generic socket API to the TCP implementation.

**UDP receive path (fast, stateless).** `udp_rcv()` is registered in the protocol handler table (`inet_protos`) for protocol number 17. After IP delivers the skb, `udp_rcv()` calls `__udp4_lib_rcv()`, which computes a socket lookup key (src IP, src port, dst IP, dst port) and searches `udp_table` (a hash table). On a hit, `udp_rcvmsg()` / `__skb_recv_udp()` appends the skb to `sk->sk_receive_queue`. A waiting `recvmsg()` call wakes and copies data to userspace. On a miss (no bound socket), the kernel sends ICMP Port Unreachable.

**TCP receive: connection demultiplexing.** `tcp_v4_rcv()` is the IP-level entry for protocol 6. It calls `__inet_lookup_skb()`, which first searches the established connections hash table (`tcp_hashinfo.ehash`) using the 4-tuple — this is the hot path for ongoing connections, an O(1) hash lookup. On a miss, it checks the listening sockets table (`tcp_hashinfo.lhash`) for a matching bound address/port — this handles SYN packets.

**TCP fast-path receive for established connections.** `tcp_rcv_established()` handles the common case: in-order data on an established connection. It checks `TCP_HP_BITS` (the "header prediction" shortcut): if the packet has no unexpected flags, the sequence number matches `tp->rcv_nxt`, and there's no out-of-order queue, the data is directly moved to `sk_receive_queue` and an ACK is sent via `tcp_send_delayed_ack()`. This avoids the full `tcp_data_queue()` path for the overwhelmingly common in-order case.

**TCP out-of-order and SACK.** When a segment arrives with a sequence number beyond `tp->rcv_nxt` (gap in sequence space), `tcp_data_queue()` inserts it into `tp->out_of_order_queue` (a red-black tree keyed by sequence number). SACK options in subsequent ACKs inform the sender which segments were received out of order; the sender's `tcp_sacktag_write_queue()` marks those segments in the retransmit queue as "delivered", preventing unnecessary retransmission.

**TCP send path.** `tcp_sendmsg()` copies application data into `sk_buff`s, filling each to MSS. It enqueues them on `sk->sk_write_queue`. `tcp_write_xmit()` dequeues segments that fit within both the congestion window (`tp->snd_cwnd`) and the receiver's advertised window (`tp->snd_wnd`). For each eligible segment, `tcp_transmit_skb()` builds the TCP header (sequence number, ACK, window, options), calls `ip_queue_xmit()`, which routes the packet and hands it to `dev_queue_xmit()`.

**Retransmission.** The retransmit timer (`tp->retransmit_timer`, backed by `hrtimer`) fires if no ACK arrives within RTO (Retransmit Timeout, calculated from RTT measurements via Karn's algorithm). Modern kernels use **RACK** (Recent ACKs) for loss detection: instead of only using the retransmit timer, RACK infers loss when a packet is reordered beyond a threshold based on the most recently delivered segment's timestamp, enabling faster loss detection without requiring three duplicate ACKs.

**Congestion control.** TCP congestion control is a pluggable module (`struct tcp_congestion_ops`). The active algorithm is called at three points: when an ACK arrives (`cong_avoid()`), when a loss is detected (`ssthresh()`), and at the start of a connection or after a timeout (`init()`). The kernel ships with:
- **Cubic** (default): increases window cubically between losses; fast ramp-up after congestion
- **BBR**: model-based; estimates available bandwidth and minimum RTT independently; sends at bandwidth estimate, drains the queue during probe phases; avoids the "fill the queue" behaviour of loss-based algorithms
- **DCTCP**: uses ECN (Explicit Congestion Notification) to react early to congestion signals in datacenters, before queue buildup

**TCP connection establishment.** The classic three-way handshake proceeds via a small state machine in `tcp_rcv_state_process()`. SYN arrives → `tcp_v4_conn_request()` allocates a `request_sock` and sends SYN-ACK; ACK completes the handshake → `tcp_v4_syn_recv_sock()` allocates the full `tcp_sock` and moves it to `sk_ack_backlog` on the listener. When the application calls `accept()`, `inet_csk_accept()` dequeues from the completed backlog. **TCP Fast Open** (TFO, since 3.7) allows data in the SYN packet: the server sends a TFO cookie on first connection; subsequent SYNs include the cookie plus data, which is delivered to the accept queue before the connection fully completes.

**SYN flood defence.** When `tcp_syncookies = 1` (default on most distros), the kernel doesn't allocate a `request_sock` on SYN receipt. Instead, it encodes the connection parameters into the SYN-ACK's ISN (initial sequence number) using a cryptographic hash. When the ACK arrives, `cookie_v4_check()` verifies the ISN hash and reconstructs the `tcp_sock`. This avoids the `request_sock` table exhaustion that SYN flood attacks exploit.

## Key Data Structures

**`struct tcp_sock`** (`include/linux/tcp.h`) — the per-connection TCP state machine (embeds `inet_sock` → `sock`).
- `snd_una` / `snd_nxt` — oldest unACKed byte; next byte to send
- `snd_cwnd` / `snd_ssthresh` — congestion window (segments); slow-start threshold
- `snd_wnd` / `rcv_wnd` — peer's advertised window; local receive window
- `rcv_nxt` / `rcv_wup` — next expected sequence number; last window update seq
- `out_of_order_queue` — `struct rb_root`: red-black tree of out-of-order segments
- `rx_opt` — parsed TCP options: timestamps, SACK, window scale, MSS
- `ca_ops` — `struct tcp_congestion_ops *`: active congestion algorithm
- `ca_priv[]` — per-connection congestion algorithm private state
- `retransmit_timer` — fires when no ACK received within RTO

**`struct tcp_congestion_ops`** (`include/net/tcp.h`) — congestion control vtable.
- `ssthresh(sk)` — called on loss; returns new slow-start threshold
- `cong_avoid(sk, ack, acked)` — called on ACK; advances cwnd
- `cong_control(sk, ack, flag)` — optional override (used by BBR)
- `pkts_acked(sk, sample)` — called for each acknowledged packet (for RTT measurement)

**`struct inet_hashinfo`** (`include/net/inet_hashtables.h`) — global demultiplexing tables.
- `ehash[]` — established + time-wait socket hash table (4-tuple keyed)
- `lhash2[]` — listening socket table (addr + port keyed)
- `bhash[]` — bind table (port keyed, for `SO_REUSEPORT` management)

## Key Functions / Entry Points

**`tcp_v4_rcv()`** (`net/ipv4/tcp_ipv4.c`) — IP entry point for all TCP segments; demultiplexes via `__inet_lookup_skb()`.

**`tcp_rcv_established()`** (`net/ipv4/tcp_input.c`) — fast path for established connections; header prediction short-circuit.

**`tcp_data_queue()`** (`net/ipv4/tcp_input.c`) — handles out-of-order segments; inserts into the OOO red-black tree; sends SACK options.

**`tcp_write_xmit()`** (`net/ipv4/tcp_output.c`) — main send loop; respects cwnd/wnd; calls `tcp_transmit_skb()`.

**`tcp_ack()`** (`net/ipv4/tcp_input.c`) — processes incoming ACK; updates `snd_una`; calls `ca_ops->cong_avoid()`.

**`tcp_enter_loss()`** (`net/ipv4/tcp_input.c`) — called on RTO or triple-dup-ACK; halves ssthresh; resets cwnd; begins retransmission.

**`udp_sendmsg()`** (`net/ipv4/udp.c`) — UDP send; calls `ip_append_data()` to build the IP datagram, then `udp_push_pending_frames()`.

## Important Flags & Config Options

- `/proc/sys/net/ipv4/tcp_congestion_control` — active algorithm (e.g., `cubic`, `bbr`)
- `/proc/sys/net/ipv4/tcp_rmem` / `tcp_wmem` — per-socket buffer [min, default, max] in bytes
- `/proc/sys/net/ipv4/tcp_window_scaling` — enable RFC 1323 window scaling (default 1; allows > 64 KB window)
- `/proc/sys/net/ipv4/tcp_sack` — enable SACK (default 1)
- `/proc/sys/net/ipv4/tcp_timestamps` — enable RFC 1323 timestamps (RTT measurement; PAWS protection)
- `/proc/sys/net/ipv4/tcp_syncookies` — SYN flood protection (default 1)
- `/proc/sys/net/ipv4/tcp_fastopen` — TCP Fast Open: 1=client, 2=server, 3=both
- `/proc/sys/net/ipv4/tcp_fin_timeout` — FIN_WAIT2 timeout before cleanup (default 60 s)
- `SO_KEEPALIVE` / `TCP_KEEPIDLE` — enable TCP keep-alive probes; tune idle time before probing

## Interactions with Other Subsystems

- **↑ Userspace**: `socket()`, `connect()`, `accept()`, `send()`, `recv()` syscalls; `setsockopt()` for `TCP_NODELAY`, `SO_RCVBUF`, etc.
- **→ [[ip-routing]]**: `tcp_transmit_skb()` calls `ip_queue_xmit()`, which does the egress route lookup and calls `dst_output()`
- **→ [[sk-buff]]**: TCP socket's send queue holds `sk_buff`s; receive queue accumulates skbs until `recvmsg()` drains them
- **← [[netfilter]]**: TCP/UDP sockets are affected by conntrack (state tracking on LOCAL_IN) and NAT (port rewriting); conntrack stores state in the `nf_conn` attached to `skb->_nfct`
- **→ [[bpf]]**: `BPF_SOCK_OPS` programs can observe TCP events (RTT, congestion state changes); `bpf_sk_lookup` redirects packets to specific sockets; `tcp_bpf_proto` wrapper allows BPF programs to intercept send/receive

## Design Decisions & Tradeoffs

**Header prediction** — The fast-path check in `tcp_rcv_established()` (the "header prediction bits" `TCP_HP_BITS`) avoids the full slow-path for the most common case: an in-order segment with no flags requiring special handling. This is a minor code complexity cost for a significant per-packet saving on bulk transfers.

**Out-of-order red-black tree** — Before 4.9, the OOO queue was a sorted linked list, giving O(N) insertion on pathological reordering. The rb-tree gives O(log N) at the cost of slightly higher constant overhead. For data centre workloads where shallow reordering is common, the improvement is measurable.

**Pluggable congestion control** — Decoupling the algorithm from the TCP core allows Cubic, BBR, DCTCP, and others to coexist and be selected per-socket (`TCP_CONGESTION` sockopt). The cost is the `ca_ops` indirect call on every ACK. BBR's model-based approach requires additional per-ACK state (`BtlBw`, `RTprop`) stored in `ca_priv[]`.

**SYN cookies** — Encoding connection state in the ISN is mathematically clever but imposes limits: MSS, window scale, and SACK options cannot all be reliably recovered from a cookie, so TFO is not compatible with SYN cookies, and some SACK state is lost on the first window. The tradeoff is broadly accepted because it prevents the table exhaustion attack that would otherwise make the server unresponsive.

## How It Has Evolved

| Version | Change |
|---------|--------|
| 2.4 (2001) | Pluggable congestion control framework introduced |
| 2.6.13 (2005) | CUBIC merged as default congestion control (replaced BIC) |
| 3.7 (2013) | TCP Fast Open merged |
| 3.12 (2013) | TCP RACK loss detection prototype |
| 4.9 (2016) | Out-of-order queue converted from list to red-black tree |
| 4.9 (2016) | BBR congestion control merged |
| 4.13 (2017) | RACK-TLP (Tail Loss Probe) fully merged; faster loss detection for tail packets |
| 5.19 (2022) | MPTCP (Multi-Path TCP) out-of-tree patches increasingly mainlined |

## Further Reading

1. [TCP Implementation (kernel-internals.org)](https://kernel-internals.org/net/tcp-implementation/) — narrative walkthrough of send/receive paths
2. [TCP Congestion Control (kernel-internals.org)](https://kernel-internals.org/net/tcp-congestion-control/) — Cubic, BBR, and DCTCP compared
3. [BBR: Congestion-Based Congestion Control (ACM Queue, 2016)](https://queue.acm.org/detail.cfm?id=3022184) — the Google paper explaining BBR's model-based design
4. [kernel.org: ip-sysctl](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html) — all TCP/UDP sysctl variables

## LKML Highlights

- **BBR merge (2016)**: Neal Cardwell's series sparked a debate about whether BBR's assumptions about BDP (Bandwidth-Delay Product) were valid in the internet — particularly whether it could starve Cubic flows. The resolution was that BBR v1 was merged as an opt-in algorithm; BBRv2 addressing fairness issues was developed subsequently.
- **OOO red-black tree (2016)**: Yaogong Wang and Eric Dumazet's patch converting the OOO queue from a singly-linked list to an rbtree addressed a real-world attack: an adversary could force massive OOO queue operations with crafted packet sequences, causing O(N^2) work in the kernel.
