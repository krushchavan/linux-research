---
title: "The netdev Generic Netlink Family — Explained"
category: explained
original: "[[netdev-netlink-family]]"
subsystem: net
tags: [explained, networking, netlink, ynl, control-plane]
converted: 2026-09-26
---

# The netdev netlink family, explained

> Plain-language companion to [[netdev-netlink-family|the technical note]]. Same facts, fewer identifiers.

## The problem

Network devices have been configured through rtnetlink (`ip link`) since the 1990s, but its message format is monolithic and grew by accretion, making it hard to extend. When XDP, page pools, NAPI instances, per-queue statistics and zero-copy memory providers all needed a user-space interface, bolting them onto the old format would have made it worse. They needed a new, cleanly extensible control channel.

## The idea in one paragraph

If rtnetlink is **an old paper form**, photocopied and annotated for 30 years, the **netdev** family is **a typed web API with a published schema**. A YAML specification is the source of truth; the kernel's input validation, the user-space header constants, the documentation and a client library (**YNL**) are all generated from it, so they can't drift apart. Each kind of object (device, page pool, queue, NAPI instance, statistics, dma-buf binding) is a resource with get and dump operations and change notifications on multicast groups, plus a few actions.

## Step by step

### Step 1: Spec and code generation
The specification declares enumerations and flags, attribute sets, operations and multicast groups. A generator turns it into the kernel's validation tables and operation lists and the user-space header; hand-written handlers live alongside. User space talks to it with the YNL command-line tool or the generated C library, which the devmem and io_uring test programs use.

### Step 2: What you can ask and do
- **device get** (with add/delete/change notifications): capability bitmaps for XDP features, XDP zero-copy segment limits, which receive metadata XDP can read (timestamp, hash, VLAN), and AF_XDP transmit features. This replaced guessing XDP support from driver names.
- **page pool get** (with notifications and statistics): each pool's ID, device, NAPI instance, buffers and memory **in flight**, **detach time** (pools lingering after their device went away, a leak signal), any devmem or io_uring provider backing it, and allocation and recycle counters.
- **queue get:** per queue, its type, NAPI instance, attached provider or AF_XDP socket, and lease. This is how an operator confirms a zero-copy binding took effect.
- **NAPI get/set:** NAPI ID, interrupt and polling thread; setting (admin) tunes deferred interrupts, GRO flush timeout, the epoll-driven interrupt-suspension busy-poll mode and threaded NAPI, used to pin applications to queues.
- **statistics get:** standardised per-device or per-queue counters (packets, bytes, allocation failures, hardware drops, checksum and offload counters), replacing inconsistent driver-specific names for common counters.
- **bind-rx** (admin in the user namespace): bind a dma-buf to receive queues for devmem TCP.
- **bind-tx** (unprivileged): map a dma-buf for devmem transmit.
- **queue create** (2026): create a receive queue on a virtual device (netkit) leased to a physical queue.

### Step 3: Resources that die with their owner
This is the key step for devmem. Bindings must disappear when their owner does. The family keeps **per-socket private state**, a small list of bindings for each netlink socket, and when the socket closes, every binding on it is unbound. That's how "close the socket to unbind" and crash-safe cleanup work without any new system call or file type.

### Step 4: Locking and namespaces
Handlers use each device's own lock rather than the global networking lock (for devices that opted in). Dumps iterate safely under RCU or table cursors, and notifications go to multicast groups so tools can watch, say, page-pool lifecycle. Lookups happen in the netlink socket's network namespace, and admin checks are per user namespace, so a container with its own namespace can bind queues on devices it owns or on leased queues, which is what makes pod-level zero-copy possible.

## The picture

```text
 netdev.yaml ──generator──▶ kernel validation + ops tables
                          ─▶ uapi header
                          ─▶ YNL client library / CLI
 ynl --dump queue-get      → queue 15: rx, napi 8201, provider: dmabuf #3
 ynl --dump page-pool-get  → pool 42: inflight 1024, detach-time (leak?)
 ynl --do bind-rx {eth0, fd, queues}  → binding #3, tied to THIS netlink socket
   socket closes (or process crashes) → all its bindings unbound
```

## Tradeoffs

- **What it gives you:** consistent validation and documentation, a free multi-language client library, cheap forward-compatible additions, per-object dumps with notifications, and crash-safe bindings.
- **What it costs / requires:** a build dependency on the generator and some rigidity (attributes must fit the schema model); two interfaces for device configuration, split by age.
- **Where it bites:** tying bindings to a netlink socket means an orchestrator must keep that socket open, or hand the job to the application. Permissions follow least privilege per operation: queue-changing operations need admin rights, caller-local ones don't.

## How it got here

- **6.2–6.3 (2023):** YAML specs and code generation (Jakub Kicinski); the netdev family with device get and XDP features (Lorenzo Bianconi, Kicinski).
- **6.5–6.7:** XDP receive metadata and AF_XDP features; page-pool introspection.
- **6.8:** queue and NAPI get (Amritha Nambiar), exposing queue-to-NAPI-to-interrupt mapping for busy polling and zero-copy placement.
- **6.9–6.10:** standardised statistics.
- **6.12:** bind-rx and per-socket binding lifetime; NAPI settings, later interrupt suspension (6.13) and threaded NAPI.
- **6.15–6.16:** io_uring provider reporting; bind-tx.
- **2026:** receive page size on bind-rx; lease attributes and queue create for netkit.

## Related

- Technical version: [[netdev-netlink-family]]
- [[netdev-queue-management-api-explained|Queue management API]], [[devmem-tcp-explained|devmem TCP]], [[devmem-tcp-rx-dmabuf-binding-and-token-recycling-explained|devmem RX binding]], [[devmem-tcp-tx-explained|devmem TX]], [[zero-copy-rx-zcrx|io_uring zcrx]]
- [[page-pool-explained|Page pool]], [[network-device-and-napi-explained|NAPI]], [[xdp-explained|XDP]], [[af-xdp-explained|AF_XDP]], [[rdma-netlink-restrack-and-cgroup-explained|RDMA netlink]]
