---
title: "Linux Networking (net) — Explained"
category: explained
original: "[[net]]"
subsystem: net
tags: [explained, networking, tcp-ip, napi, xdp]
converted: 2026-09-25
---

# The Linux networking stack, explained

> Plain-language companion to [[net|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

The networking stack takes raw frames from network cards, decides for each one whether to deliver it to a local program, forward it or drop it, and turns the survivors into the byte streams and datagrams programs read from sockets. In the other direction, it turns program data into correctly addressed, paced packets.

It has to do all this for very different users at once: a laptop's interactive SSH session wants low latency; a server wants to fill a 100 Gb/s link; containers and VMs each want what looks like their own private network; and security and load-balancing tools want to inspect or redirect packets at millions per second. No single design wins everywhere, so the stack is a layered compromise between generality, throughput and latency.

## The big picture

Think of a **motorway with toll booths**. A packet is a car; each layer is a booth that reads a header, strips it off, decides what happens next (drop, forward, deliver locally), and waves the rest on. Sockets are the on-ramps where programs join. The **skb** is the car itself, carrying both the payload and every decision made along the way. **XDP** is a weigh station *before* the first booth, where known-bad traffic is thrown out almost for free.

```text
 NIC rings ─▶ driver ─┬─ XDP program (before any allocation): drop / pass / redirect ─▶ AF_XDP app
                      ▼ pass
                NAPI poll (batching, GRO)
                      ▼
          link layer ─▶ firewall (prerouting) ─▶ IP ─▶ routing
                                                ├─ local ─▶ firewall (input) ─▶ TCP/UDP ─▶ socket ─▶ app
                                                └─ forward ─▶ firewall (forward) ─▶ qdisc (shaping) ─▶ NIC
```

## The pieces

### The skb: one packet, many layers
An **skb** doesn't contain packet data; it points into a separate buffer that has free **headroom** in front, the packet in the middle, and **tailroom** after. Adding a header (IP handing down to Ethernet) just moves the start pointer back into the headroom; stripping one moves it forward. No copying.

Large packets chain extra page fragments, which is how TCP can hand the card a single 64 KB "packet" for the hardware to slice into wire-sized frames (segmentation offload). Reference counts are split between the metadata and the shared data, so a **clone** (for multicast or packet capture) can share the data but have its own header area, while a full **copy** duplicates everything. The skb also records checksum status (hardware already verified it; hardware must still compute it), a cached flow hash, the owning socket, a cached route, and a small scratch area each layer can use for its own state. See [[sk-buff|the skb]].

### Network devices and NAPI
Every interface (Ethernet, Wi-Fi, virtual, tunnel) is a **network device** with a table of driver operations and a set of offload capability flags.

Receiving uses **NAPI** to avoid an interrupt per packet:
1. the first packet raises an interrupt; the driver disables further receive interrupts and schedules polling
2. in soft-interrupt context, the driver's poll function is called with a **budget** (64 packets by default); it builds skbs from the receive ring and passes them up, with **GRO** merging segments of the same TCP flow into bigger skbs to save per-packet work
3. if it used the whole budget, polling continues; if the ring empties first, interrupts are switched back on

This is the key trade in receive: interrupts when quiet (good latency), batched polling when busy (good throughput). Since 5.11, **threaded NAPI** can run polling in a per-interface kernel thread instead, which the scheduler can see, prioritise and pin to CPUs. See [[network-device-and-napi|devices and NAPI]].

### Routing
On arrival, IP checks the header, runs the firewall's prerouting hook, then looks the destination up in the **FIB** (forwarding table). IPv4's FIB is an **LC-trie**, a compressed prefix tree that finds the longest matching prefix quickly. The result becomes a cached route holding the output device, the next hop, and a function pointer: local delivery, or forwarding. Forwarding decrements the TTL (dropping at zero), runs the forward hook, fragments if the packet is bigger than the outgoing MTU, and queues it for transmission.

**Policy routing** allows up to 255 tables, chosen by rules matching source, destination, incoming interface or a firewall mark (for VPN split routing, VRFs, per-user routes). **ECMP** spreads flows across equal-cost paths by hashing each flow's addresses (and optionally ports), so one flow always takes one path and isn't reordered. See [[ip-routing|IP routing]].

### TCP and UDP
Sockets are layered structures: generic socket, then internet socket, then TCP or UDP socket, with a protocol table connecting them.
- **UDP receive:** hash the addresses and ports to find the socket, append the skb to its queue, wake the reader. No state machine.
- **TCP receive:** find the socket (established connections first, then listeners for new connections), check sequence numbers, update the window, acknowledge, and queue in-order data; out-of-order segments wait in a sorted tree.
- **TCP send:** copy program data into skbs on the socket's write queue, then send what fits in both the **congestion window** and the receiver's advertised window. Retransmission is driven by timers and by SACK- and RACK-based loss detection.

**Congestion control** is pluggable: Cubic (the default), Reno, DCTCP, and BBR, which models bandwidth and round-trip time to keep the pipe full without building queues. See [[tcp-ip-stack|the TCP/IP stack]].

### Traffic control (qdiscs)
Every device's outgoing path has a **queueing discipline** that decides the order packets leave in:
- **pfifo_fast** (the kernel default): three priority bands chosen by the packet's type-of-service field
- **HTB**: a hierarchy of classes, each with a guaranteed rate and a ceiling, using token buckets, for rate limiting
- **fq**: fair queueing per flow with pacing, recommended for internet-facing servers since it stops one flow from blocking others

Classifiers can be eBPF programs (since 4.1), which have largely replaced complex qdisc hierarchies for software-defined networking. See [[traffic-control-qdisc|traffic control]].

### Network namespaces
A **network namespace** gives a group of processes its own interfaces, routing tables, firewall and connection-tracking state, port space and network sysctls, as if it were a separate machine. Creating one calls every networking subsystem's registered per-namespace initialiser. Physical cards stay global; containers usually get one end of a **veth** pair (packets sent on one end appear on the other), or macvlan, ipvlan or SR-IOV virtual functions. Because socket lookup searches only the packet's own namespace, two containers can both listen on port 80. See [[network-namespaces|network namespaces]].

### XDP and AF_XDP
**XDP** runs an eBPF program inside the driver, **before any skb is allocated**, on a lightweight descriptor of the raw bytes, at 10 to 50 million packets per second. Its verdict:
- **drop**: discard at once, the cheapest DDoS defence
- **pass**: continue into the normal stack
- **tx**: bounce back out of the same interface
- **redirect**: to another interface, another CPU, or a user-space socket
- **aborted**: drop and emit a trace event, for debugging

It runs **natively** in drivers that support it, **generically** after skb allocation on any driver (without the allocation savings), or **offloaded** into NIC hardware. **AF_XDP** builds on redirect: an application registers a chunk of its own memory as frames, and packets land directly in it through shared rings, with no copy and no skb. See [[xdp|XDP]].

## A request's journey

A TCP segment arrives for a local web server:

1. **Driver and XDP.** The card writes the frame into a receive ring and interrupts. The XDP program looks at the raw bytes and says pass.
2. **NAPI.** The driver builds an skb in its poll loop, and GRO merges it with neighbouring segments of the same flow.
3. **IP.** The header is checked, the prerouting firewall hook accepts it, and the routing lookup says "local".
4. **Input hook.** The firewall's local-input hook accepts it.
5. **TCP.** The socket is found in the established-connections table, the sequence number checks out, the data is queued and an acknowledgement goes out.
6. **The program.** The server's `recv` copies the data out and returns. This is where every earlier layer's work (header stripped by pointer moves, route cached in the skb) pays off: nothing was copied until this final step.

Forwarding follows the same start, then routing picks an output device, TTL is decremented, the forward hook runs, the neighbour's link address is filled in, and the qdisc paces it onto the transmit ring. An XDP load balancer never gets that far: it redirects the raw frame straight to another card's transmit path, with no skb ever built.

## Tradeoffs

- **What it gives you:** a full, general TCP/IP stack with batching, offloads, pluggable congestion control, policy routing, per-container isolation, and programmable fast paths from the driver up.
- **What it costs / requires:** care with shared skbs before editing headers; per-driver NAPI and XDP support; function-pointer indirection in hot paths; route insertions that are costlier than lookups.
- **Where it bites:** XDP sees only raw bytes (no socket state or rich skb helpers); choosing a congestion algorithm matters (Cubic for WAN, BBR for large training clusters, DCTCP inside datacentres); the kernel's default qdisc is not what most distributions actually set.

## How it got here

- **2.4 (2001):** NAPI replaces interrupt-per-packet receive. **2.6 (2003):** netfilter/iptables mature and connection tracking merges.
- **2.6.20 (2007):** generic segmentation and receive offload.
- **3.9 and 3.11 (2013):** multiple sockets per port for load spreading; TCP Fast Open, sending data in the SYN.
- **4.8 (2016):** XDP. **4.14 (2017):** AF_XDP. **4.19 (2018):** BBR (per the note).
- **5.1 (2019):** initial multipath TCP. **5.11 (2021):** threaded NAPI. **5.14 and 6.0:** BIG TCP, segments over 64 KB for IPv6 then IPv4.
- **Ongoing:** multipath TCP maturity, loss-detection tuning, io_uring networking, smart-NIC offload, and zero-copy send.

## Related

- Technical version: [[net]]
- [[sk-buff|skb]], [[network-device-and-napi|Devices and NAPI]], [[ip-routing|Routing]], [[tcp-ip-stack|TCP/IP]], [[traffic-control-qdisc|Traffic control]], [[network-namespaces|Namespaces]], [[xdp|XDP]], [[page-pool|Page pool]], [[devmem-tcp|Device-memory TCP]]
- [[netfilter|Netfilter]], [[bpf-explained|BPF]], [[cgroup-bpf-explained|cgroup BPF]], [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]]
- [[interrupt-handling-explained|Interrupt handling]], [[rcu-read-copy-update-explained|RCU]], [[dma-mapping-api-explained|DMA mapping]]
