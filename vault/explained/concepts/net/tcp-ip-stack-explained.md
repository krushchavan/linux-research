---
title: "TCP/IP Stack — Explained"
category: explained
original: "[[tcp-ip-stack]]"
subsystem: net
tags: [explained, networking, tcp, udp, congestion-control]
converted: 2026-09-25
---

# The TCP/IP stack, explained

> Plain-language companion to [[tcp-ip-stack|the technical note]]. Same facts, fewer identifiers.

## The problem

Programs want two kinds of network service. **TCP** gives a reliable, in-order, two-way byte stream: every byte arrives, once, in order, even though the network drops, duplicates and reorders packets, and without overwhelming either the receiver or the network in between. **UDP** gives cheap, fire-and-forget datagrams. Both appear to programs as ordinary sockets.

The kernel must do this for millions of simultaneous connections on a big server, spending only microseconds per packet, while also fending off attacks such as SYN floods and crafted reordering.

## The idea in one paragraph

TCP is a **postal service that guarantees delivery and order**. The sender puts data in numbered envelopes (segments); the receiver sends receipts (acknowledgements); anything not acknowledged in time is sent again. The sender also watches how much the postal system can absorb (**congestion control**) so it doesn't flood the sorting offices. UDP is a **postcard service**: write the address, drop it in the box, forget about it. No receipts, no ordering, no resending.

## Step by step

### Step 1: A socket is layered state
Creating a TCP socket builds a generic socket, extended with IP addresses and ports, extended again with all TCP state: sequence numbers, windows, timers, congestion state. A protocol table wires the generic socket calls to TCP's implementation (or UDP's).

### Step 2: UDP receive: find the socket and queue it
IP hands UDP the packet; UDP hashes the source and destination addresses and ports, looks the socket up, appends the packet to its receive queue and wakes any waiting reader. If no socket is bound, the kernel replies with ICMP "port unreachable". That's all: no per-flow state.

### Step 3: TCP receive: find the connection
TCP first looks in the **established** connections table (a hash on the four-tuple), the hot path for ongoing connections, and only then in the **listening** table, which handles new connection requests.

### Step 4: The fast path for in-order data
This is the key step for throughput. For an established connection, TCP checks a few **header prediction** conditions: no unusual flags, the sequence number is exactly the next one expected, and nothing is waiting out of order. If they hold (the overwhelmingly common case in bulk transfers), the data goes straight onto the receive queue and a delayed acknowledgement is scheduled, skipping the general-purpose path.

### Step 5: Out of order, SACK, and loss
A segment arriving past a gap is kept in a **sorted tree** by sequence number until the gap is filled. Acknowledgements carry **SACK** blocks telling the sender which later pieces did arrive, so it retransmits only what's missing. The sender retransmits when a timer based on measured round-trip times expires, or earlier using **RACK**, which infers a loss when a packet sent before one that has already arrived hasn't been acknowledged within a time threshold, with no need to wait for three duplicate acknowledgements.

### Step 6: Sending
The program's data is copied into segment-sized skbs on the socket's write queue. The sender releases segments only while they fit within **both** the congestion window (what the network can take) and the receiver's advertised window (what the receiver can take). Each segment gets its TCP header and is handed to IP for routing and transmission.

### Step 7: Congestion control, pluggable
The algorithm is a module called on each acknowledgement, on loss, and at the start:
- **Cubic** (the default): grows the window along a cubic curve between losses, ramping up quickly after congestion
- **BBR**: model-based; estimates bottleneck bandwidth and minimum round-trip time separately and sends at that rate, draining queues in probe phases rather than filling them
- **DCTCP**: reacts early to ECN congestion marks, for datacentres

It can be chosen system-wide or per socket.

### Step 8: Connecting, and surviving SYN floods
The three-way handshake runs through a small state machine: a SYN creates a lightweight **request** entry and a SYN-ACK is sent; the final ACK creates the full connection and queues it for `accept`. **TCP Fast Open** lets a returning client send data in the SYN itself, using a cookie from an earlier connection.

A SYN flood tries to fill the request table with half-open connections. With **SYN cookies** (on by default in most distributions), the server keeps no state at all: it encodes the connection's parameters, cryptographically, into its initial sequence number, and rebuilds the connection when the ACK comes back carrying it. Not everything fits in a cookie (MSS, window scaling and SACK can't all be fully recovered), and Fast Open doesn't work with cookies.

## The picture

```text
 SYN ─▶ (request entry | SYN cookie) ─ SYN-ACK ─▶ ACK ─▶ connection ─▶ accept queue

 receive: established table hit ─▶ in order & no surprises? ─▶ receive queue, delayed ACK
                                  └ gap ─▶ out-of-order tree ─▶ ACK with SACK blocks

 send: write queue ─▶ fits congestion window AND receiver window? ─▶ header ─▶ IP
       no ACK in time / RACK says lost ─▶ retransmit; algorithm adjusts the window
```

## Tradeoffs

- **What it gives you:** reliable ordered streams with fast paths for the common case, efficient selective retransmission, swappable congestion algorithms, and resistance to SYN floods.
- **What it costs / requires:** an indirect call to the congestion module on every acknowledgement; per-connection state and timers; tuning (buffer sizes, algorithm choice) for very different environments.
- **Where it bites:** SYN cookies lose some options; BBR v1 raised concerns about starving Cubic flows, which is why it's opt-in. Before 4.9, crafted reordering could force expensive work on a sorted list; a tree now bounds it.

## How it got here

- **2.4 (2001):** a pluggable congestion-control framework.
- **2.6.13 (2005):** Cubic replaced BIC as the default.
- **3.7:** TCP Fast Open. **3.12:** an early RACK prototype.
- **4.9 (2016):** the out-of-order queue became a red-black tree (Yaogong Wang, Eric Dumazet), closing an attack that forced quadratic work; BBR merged (Neal Cardwell), opt-in, with BBRv2 later tackling fairness.
- **4.13 (2017):** RACK with tail loss probing fully merged. **5.19 (2022):** more multipath TCP mainlined.

## Related

- Technical version: [[tcp-ip-stack]]
- [[net-explained|Networking stack]], [[sk-buff-explained|skb]], [[ip-routing-explained|IP routing]], [[network-namespaces-explained|Network namespaces]]
- [[netfilter-explained|Netfilter]], [[bpf-explained|BPF]], [[traffic-control-qdisc-explained|Traffic control]]
