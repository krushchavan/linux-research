---
title: "Netdev Queue Management API — Explained"
category: explained
original: "[[netdev-queue-management-api]]"
subsystem: net
tags: [explained, networking, queues, memory-providers, netkit]
converted: 2026-09-26
---

# The netdev queue management API, explained

> Plain-language companion to [[netdev-queue-management-api|the technical note]]. Same facts, fewer identifiers.

## The problem

Traditionally a network driver managed all its queues as one block. Changing how receive buffers were allocated meant taking the whole interface down and up (dropping every connection) or using a driver-private reset. Zero-copy receive needs something much finer: when a process binds a dma-buf (devmem TCP) or an io_uring area to **one** receive queue, that queue's page pool must be torn down and rebuilt to draw from the new **memory provider**, while every other queue keeps running.

## The idea in one paragraph

Each receive queue is a **train car on a moving train**. Before, changing one car's cargo system meant stopping the train. The queue API lets the kernel **build a replacement car on a siding** (allocate everything with the new configuration), then briefly **uncouple the old car and couple the new one**, then scrap the old one. If coupling fails, the old car goes back on. **Leasing** is a sub-let: a container's virtual device gets a "car" that's really a pointer to a car on the physical train, so anything the container attaches to it is actually installed on the physical one.

## Step by step

### Step 1: The driver contract
A driver provides a small set of operations: how big its per-queue state is; **allocate** everything a queue needs (rings, descriptors, the page pool, which asks the queue's memory provider for buffers) *without touching the live queue*; **start** a prepared queue; **stop** the live queue and hand over its resources; and **free** a stopped queue's resources. Newer operations cover per-queue configuration (currently the receive page size), which device does DMA for a given queue (it can differ per queue), and, for virtual devices, creating a new queue for leasing.

### Step 2: Swap a queue safely
This is the key step. Under the device's own lock:
1. allocate space for new and old state
2. **allocate the new queue first**, with its page pool built on whatever provider is now recorded for the queue, so failures happen *before* any disruption
3. **check** the driver really built the pool on that provider. A driver that silently ignored it would put ordinary pages where the application expects its own memory, so this fails closed.
4. if the device is running, stop the old queue and start the new one; if starting fails, restart the old one and return the error. If the device is down, just swap, so the next start uses the new setup.
5. free the old state

A "restart" wrapper does the same with unchanged configuration.

### Step 3: Binding a memory provider goes through the core
Providers never talk to drivers directly. io_uring zero-copy receive and devmem ask the core to bind their provider to a queue. The core resolves **leases** (if the queue belongs to a virtual device, it acts on the physical one), then checks preconditions: queue operations exist, header split is on with threshold zero, no XDP program, the page size is supported, the queue isn't already bound or used by AF_XDP, and the index is valid. It records the provider, validates the resulting configuration, and swaps the queue, rolling back the record on failure. Unbinding clears the record and swaps back to ordinary pages. If the physical device disappears, each provider is told to drop its references.

### Step 4: Leasing queues to containers (2026)
Containers using Cilium's **netkit** devices can't see the physical card, yet zero-copy receive, devmem and AF_XDP all take "interface and queue number". Leasing bridges this. A netlink request on a *virtual* device creates a new queue and links it, in both directions, to a named queue on a physical device, holding a reference. Binding a provider or AF_XDP to the virtual queue is then **proxied** to the physical queue, so the physical card fills that queue from memory the container's process mapped. Direction checks prevent loops, locks are always taken virtual-before-physical, a notifier cleans up dependent virtual devices when the physical one goes away, and channel resizing refuses to remove leased queues. For transmit, devmem binding on a virtual device finds the physical DMA device through its leased queues.

### Step 5: Who implements it
Drivers with memory-provider support: bnxt, gve, mlx5, fbnic, netdevsim (for tests) and others. It's also the foundation for future per-queue changes, like ring or buffer sizes, without full resets.

## The picture

```text
 bind provider to queue 5:
   record provider ─▶ allocate NEW queue 5 (pool on provider) ─ fail? nothing disrupted
                   ─▶ check pool really uses provider
                   ─▶ stop OLD 5 → start NEW 5 ─ fail? restart OLD 5
                   ─▶ free OLD 5            (queues 0-4, 6-15 keep running)
 lease: netkit0 queue 1 ──lease──▶ eth0 queue 5
        container binds io_uring/AF_XDP on netkit0:1 → actually installed on eth0:5
```

## Tradeoffs

- **What it gives you:** zero-copy binding at runtime without disturbing other queues or connections; failures that leave the old queue running; one place that enforces header split, XDP, AF_XDP and lease rules for every provider; zero-copy inside containers without handing them the physical device.
- **What it costs / requires:** allocating the full new queue before stopping the old one temporarily doubles memory. Because the core treats driver queue state as opaque, whether the driver honoured the provider has to be checked afterwards.
- **Where it bites:** leasing adds lock-ordering rules, notifier-driven cleanup, and more code paths that must understand leases.

## How it got here

- **6.10 (2024):** the queue API defined (Mina Almasry, reviewed by Jakub Kicinski, who pushed for early refusal of unsupported devices).
- **6.12:** queue restart and provider binding, with devmem receive.
- **6.13–6.15:** generalised binding for io_uring zero-copy receive; the post-swap provider check; the device's own lock replaces the global networking lock for these paths.
- **2025–26:** per-queue configuration (page size) and per-queue DMA device.
- **2026:** queue leasing for netkit (Daniel Borkmann, David Wei; tested on mlx5 and bnxt at 100G), with AF_XDP and providers proxied, and further netkit io_uring work in June.

## Related

- Technical version: [[netdev-queue-management-api]]
- [[page-pool-explained|Page pool]], [[netmem-and-net-iov-abstraction-explained|netmem and net_iov]], [[devmem-tcp-explained|devmem TCP]], [[devmem-tcp-rx-dmabuf-binding-and-token-recycling-explained|devmem RX binding]], [[devmem-tcp-tx-explained|devmem TX]], [[zero-copy-rx-zcrx|io_uring zcrx]], [[header-split-and-flow-steering-for-zero-copy-rx-explained|Header split and steering]]
- [[netdev-netlink-family|netdev netlink]], [[af-xdp-explained|AF_XDP]], [[network-device-and-napi-explained|NAPI]], [[network-namespaces-explained|Network namespaces]]
