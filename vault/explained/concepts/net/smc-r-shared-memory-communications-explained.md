---
title: "SMC-R: Shared Memory Communications over RDMA — Explained"
category: explained
original: "[[smc-r-shared-memory-communications]]"
subsystem: net
tags: [explained, networking, smc, rdma, sockets]
converted: 2026-09-26
---

# SMC-R, explained

> Plain-language companion to [[smc-r-shared-memory-communications|the technical note]]. Same facts, fewer identifiers.

## The problem

RDMA can bypass the TCP/IP stack and cut CPU use and latency, but it needs applications written for verbs, and most never will be. **SMC** (Shared Memory Communications) gives **unmodified TCP socket applications** RDMA's benefits transparently. A connection starts as ordinary TCP; if both ends turn out to support SMC, application data then moves by **RDMA writes into the peer's pre-registered receive buffer**, and the TCP connection stays open only for control and teardown. If either side (or the network) can't do SMC, the socket quietly stays plain TCP. It comes from IBM (for mainframes), is described in RFC 7609, and is heavily developed by Alibaba for cloud use. **SMC-R** runs over RoCE; **SMC-D** uses shared memory between VMs or containers on one host.

## The idea in one paragraph

SMC is **TCP with a private express lane**. Two neighbours meet on the public road (TCP). If both own a private tunnel (RDMA cards on the same RoCE network), they agree in that first conversation to swap mailbox keys. From then on, the writer drops bytes straight into the other's **mailbox** (a ring buffer in registered memory) through the tunnel and leaves a small note saying "I've written up to here". The reader takes bytes out and sends back a note saying "I've read up to here", so the writer knows how much room is left. The public-road connection stays open for goodbyes and emergencies. Applications only ever call send and receive.

## Step by step

### Step 1: Get an SMC socket
Applications opt in by creating an SMC socket (its own address family), or since 6.11 a normal IPv4/IPv6 stream socket with the **SMC protocol**, which lets existing tooling and BPF hooks (for example rewriting the protocol at socket creation) work. Alternatives are a preload shim that rewrites socket calls (useless for static binaries, one reason for the protocol option) or converting a TCP socket before connecting. Every SMC socket owns an internal TCP socket that does the real connect or accept.

### Step 2: Discover support during the TCP handshake
The internal socket's SYN and SYN-ACK carry an experimental TCP option saying "I speak SMC". If the peer doesn't echo it (it doesn't support SMC, or a middlebox stripped the option), the socket **falls back** to plain TCP at once, and from then on everything goes straight to TCP. The only cost is a few option bytes.

### Step 3: Negotiate over the TCP connection
Both sides exchange control messages on the established TCP connection: the client proposes (supported SMC types, its RDMA address, IP prefix), the server accepts (chosen device, its queue number, its receive buffer's remote key, address and slot), and the client confirms with the same about itself. Version 1 needs both hosts on the same subnet and layer-2 RoCE network; **version 2** adds routable RoCE v2 and more connections. The negotiation runs in a background worker so non-blocking connect still works. The number of concurrent negotiations can be limited, and since 2025–26 a **BPF policy** can decide per connection whether to try SMC at all (say, only for long-lived flows).

### Step 4: Share RDMA resources between connections
RDMA setup is expensive, so it isn't per connection. Between two hosts, SMC-R keeps a **link group** of one or more **links**, each a reliable queue pair over (ideally different) RDMA devices, for redundancy and load spreading. Each connection gets a local **send buffer** and a slot in a registered **receive buffer** that the *peer* writes into, drawn from size-class pools (16 KB to 1 MB) registered for remote write. Link-management messages add and remove links, register keys for new buffers on every link, and run keepalive probes.

### Step 5: Send
This is the key step. Sending copies the application's data into the send buffer, then posts **RDMA writes** from there into the peer's receive slot at the current write position (two writes if it wraps around the ring), followed by a small **control message** carrying the new write position and flags (urgent data, done writing, abort). Before writing, the sender checks how much space the peer has said is free: that's the flow-control window. **Autocorking** delays small writes to batch them, like TCP's autocork.

### Step 6: Receive
The control message arrives as a completion, updates the reader's view of the write position, and wakes readers. Receiving **copies from the local receive buffer** into the application, advances the read position, and once enough has been read, sends a control message back so the writer can reuse the space. So there's **one copy on each side** and no protocol processing: the kernel's TCP stack and softirq networking aren't involved in the data path at all.

### Step 7: Failover and closing
If a link fails, connections move to another link in the group, with unconfirmed writes replayed, and applications notice nothing. If **no** RDMA path remains, the connection is **aborted**: it can't fall back to TCP mid-stream, because the byte stream was never on TCP. Closing exchanges close flags, then the internal TCP connection closes normally, and buffers go back to the pools for the next connection, so an established link group spreads the setup cost across many connections.

### Step 8: SMC-D
SMC-D replaces RDMA writes with writes into a shared-memory buffer exposed by a hypervisor device on IBM mainframes or, since 6.9, a software **loopback** device for containers on one host. In 2025 the device side was split into a generic **direct internal buffer sharing** layer, cleanly separate from SMC-D.

## The picture

```text
 connect(): TCP SYN [+SMC option] ─▶ SYN-ACK [+SMC option]?  no → plain TCP forever
                                                               yes ↓
 control msgs over TCP: propose / accept (QPN, rkey, buffer slot) / confirm
 send("abc…"): copy → send buffer ─RDMA WRITE─▶ peer's receive slot (ring)
               + control msg {written up to X}
 peer recv(): copy out of slot → control msg {read up to Y} → sender's window grows
 link fails → move to another link;  no links left → abort (no mid-stream TCP fallback)
```

## Tradeoffs

- **What it gives you:** RDMA transport for unmodified socket applications, automatic fallback, familiar addressing and firewalls for connection setup, no TCP/IP processing on the data path, and shared, failover-capable links.
- **What it costs / requires:** one copy on each end; handshake latency that hurts short-lived connections (hence limits and BPF policy); netfilter, traffic control and TCP instrumentation don't see the data; complex lifetime and failover logic across shared links.
- **Where it bites:** losing every RDMA path aborts connections. Version 1's layer-2 restriction made early SMC-R impractical in routed clouds, until version 2 over RoCE v2 and Alibaba's cloud work (including a virtualised iWARP-based RDMA as a transport). Compared with io_uring, which makes *TCP* cheaper to drive while keeping TCP/IP in the kernel, SMC removes TCP/IP from the data path but still copies once per side; the two can be combined.

## How it got here

- **4.11 (2017):** SMC-R merged (Ursula Braun, IBM; RFC 7609 from 2015).
- **4.19:** SMC-D with the mainframe shared-memory device.
- **5.x:** SMC version 2 (5.10–5.11) and routable SMC-R v2 over RoCE v2 (5.17–5.18, Karsten Graul); statistics; better multi-link failover.
- **5.18–6.x:** Alibaba work on autocorking, buffer types, limits and performance.
- **6.9:** loopback SMC-D for any architecture. **6.11:** the SMC protocol for ordinary sockets (D. Wythe).
- **2025–26:** the direct buffer-sharing layer (Alexandra Winter) and BPF handshake policy.

## Related

- Technical version: [[smc-r-shared-memory-communications]]
- [[rdma-explained|RDMA subsystem]], [[memory-registration-and-ib-umem-explained|Memory registration]], [[roce-v1-and-v2-explained|RoCE v1 and v2]], [[tcp-ip-stack-explained|TCP/IP stack]]
- [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]], [[af-xdp-explained|AF_XDP]]
