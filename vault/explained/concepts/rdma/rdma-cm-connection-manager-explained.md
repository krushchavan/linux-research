---
title: "RDMA Connection Manager (rdma_cm) — Explained"
category: explained
original: "[[rdma-cm-connection-manager]]"
subsystem: rdma
tags: [explained, rdma, connection-manager, rdma-cm]
converted: 2026-09-26
---

# The RDMA connection manager, explained

> Plain-language companion to [[rdma-cm-connection-manager|the technical note]]. Same facts, fewer identifiers.

## The problem

Before two reliable-connected queue pairs can talk, each must learn the other's queue number, starting sequence number, path (addresses, MTU, service level) and capabilities, and both must step their queue pairs through init, ready-to-receive and ready-to-send in a coordinated way. Every transport does this differently: InfiniBand uses management messages and a subnet manager, RoCE sends the same messages over UDP or Ethernet with addresses derived from IP, and iWARP uses a real TCP connection plus its own handshake. Doing it by hand, per transport, is error-prone.

## The idea in one paragraph

The connection manager is **a travel agent for queue pairs**. You say "I want to reach 10.0.0.2 port 4420", and it (1) works out which of your RDMA devices and ports can get there and which source address to use, (2) books the path, from the subnet administrator on InfiniBand or from IP routing and neighbour tables on Ethernet, (3) negotiates with the other side's agent using the right handshake for the transport, and (4) hands you a queue pair already brought to ready-to-send. It reports progress as **events**, because every step may involve network round trips. The API looks like sockets: resolve address, resolve route, connect or listen and accept, disconnect.

## Step by step

### Step 1: Create an ID
A kernel user creates a connection ID with an event handler; user space does the same through librdmacm and a device file, where callbacks become queued events it reads. Each ID has a **port space** (TCP-like for reliable connections, UDP-like for datagrams, and a few others), so an IP-style port maps onto an InfiniBand service ID. Each ID also tracks its state, changed atomically so concurrent calls and callbacks can't corrupt it.

### Step 2: Resolve the address
The active side gives a destination (IPv4, IPv6 or native InfiniBand) and optionally a source. The kernel does an ordinary **IP route lookup** to find the outgoing network device, then gets the link-layer address from the **neighbour table** (sending ARP or neighbour discovery if needed) for RoCE and iWARP, or from IPoIB. It then binds the ID to the RDMA device and port whose address table holds an entry for that network device and IP, choosing RoCE v1 or v2 by the configured default. Loopback and wildcard destinations get special handling. An "address resolved" event follows.

### Step 3: Resolve the route
- **InfiniBand:** ask the subnet administrator for a path record, getting service level, MTU, rate, lifetime and optional alternate paths.
- **RoCE:** there's no subnet manager, so a path is **synthesised** locally: MTU from the interface, rate from link speed, traffic class from the requested type of service or a configured default, and the RoCE version.
- **iWARP:** nothing to do; TCP will route.

A "route resolved" event follows.

### Step 4a: Connect
The application creates its queue pair through the manager (which brings it to init) and connects, supplying a little private data, read/atomic depths and retry counts. On InfiniBand and RoCE, the manager sends a **request** message on the general management queue (on RoCE v2, over UDP port 4791) carrying the queue number, starting sequence number, path and private data. On iWARP, the card (or siw) opens a TCP connection and exchanges its handshake frames, with the port-mapper daemon reserving the TCP port.

### Step 4b: Listen and accept
The passive side binds and listens. A wildcard bind listens on **every** RDMA device, now and in the future, by creating a child listener as each device appears. An incoming request is matched to the right network device and namespace and to the listener's port; the manager creates a **new** ID for the connection and delivers a "connect request" event with the private data. The passive side creates its queue pair and accepts: the manager moves it to ready-to-receive using the peer's details from the request, and sends a **reply**.

### Step 5: Establish
This is the key step. The active side receives the reply, moves its queue pair to ready-to-receive and then ready-to-send, sends a **ready-to-use** message, and gets an "established" event. The passive side moves to ready-to-send on receiving it, or on the first incoming packet, since that message can be lost. iWARP completes when its handshake reply arrives. Neither side touched the queue-pair state machine itself.

### Step 6: Disconnect, time-wait and failures
Disconnecting moves the queue pair to error (flushing outstanding work) and exchanges disconnect request and reply messages; both sides get "disconnected". The queue number then sits in **time-wait** until no packets from the old connection can still be in flight, like TCP's TIME_WAIT. Failures arrive as events: no path (route error), no listener (a **reject** with a reason and optional private data), retries exhausted (unreachable), address changes after a bond failover (address change), and device removal, which asks the user to destroy everything on the ID so the device can go.

### Step 7: Datagrams, multicast and extras
Datagram IDs have no connection: "connect" does a small service-resolution exchange to learn the remote queue number and key, and multicast joins go through the subnet administrator on InfiniBand or map to Ethernet multicast with IGMP/MLD on RoCE. **Enhanced connection establishment** (5.8) lets vendors negotiate optional features inside the handshake; there are socket-like setters for ack timeout, receiver-not-ready timer, address reuse and IPv6-only; and since 2025 an InfiniBand service name can be resolved into addresses, like `getaddrinfo`.

## The picture

```text
 active                                         passive
 create ID ─ resolve addr (IP route + ARP → device, GID)
           ─ resolve route (SA path | synthesised for RoCE | none for iWARP)
 create QP (init) ─ connect ──── REQUEST {QPN, PSN, path, private data} ──▶ new ID, "connect request"
                                                           create QP, accept → ready-to-receive
            ◀──────────────────────────── REPLY ─────────────
 ready-to-receive → ready-to-send ─ READY-TO-USE ──▶ ready-to-send
 "established"                                     "established"
 iWARP: TCP connect + MPA request/reply instead of REQUEST/REPLY
```

## Tradeoffs

- **What it gives you:** transport-independent, IP-addressed connection setup with queue-pair transitions done for you, so path, queue-number and sequence-number mismatches can't happen; used by nearly every kernel RDMA user (NVMe-oF, NFS/RDMA, iSER, RTRS, SMB Direct, RDS).
- **What it costs / requires:** correct IP routing and neighbour state, so ARP problems become RDMA connection problems; an asynchronous event model (librdmacm offers blocking wrappers for simple programs); tiny private data (56 usable bytes on InfiniBand and RoCE), so upper layers exchange keys and parameters after connecting.
- **Where it bites:** translating two very different transport protocols into one event model makes the core file large (over 5,600 lines) and subtle, a steady source of races around device removal and listener fan-out. Compared with io_uring, which uses ordinary TCP sockets, RDMA needs this separate manager because transport state lives in the card and must be negotiated before the first byte moves.

## How it got here

- **2.6.17–2.6.18 (2006):** the connection manager and its user-space channel (Sean Hefty, Intel), with the event-queue model librdmacm still uses.
- **2.6.19–2.6.20:** iWARP integration. **2.6.3x:** RoCE route synthesis.
- **4.x:** RoCE v2 address types and configured defaults (Matan Barak, Moni Shoua); per-namespace IDs; native InfiniBand addressing.
- **5.8:** enhanced connection establishment.
- **2020–2021:** listener and device-removal race fixes after fuzzing found use-after-frees (Jason Gunthorpe).
- **2025–2026:** InfiniBand service-name resolution.

## Related

- Technical version: [[rdma-cm-connection-manager]]
- [[rdma-explained|RDMA subsystem]], [[queue-pairs-and-completion-queues-explained|Queue pairs and CQs]], [[roce-gid-table-and-netdev-binding|RoCE GID table]], [[iwarp-transport-explained|iWARP]], [[mad-and-subnet-administration-explained|Management datagrams]], [[ib-device-and-client-model-explained|Device and client model]], [[nvme-over-fabrics-rdma-and-tcp|NVMe over Fabrics]]
