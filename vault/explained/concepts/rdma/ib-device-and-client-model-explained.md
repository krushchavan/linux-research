---
title: "ib_device and the Client Model — Explained"
category: explained
original: "[[ib-device-and-client-model]]"
subsystem: rdma
tags: [explained, rdma, device-model, hot-unplug]
converted: 2026-09-26
---

# RDMA devices and clients, explained

> Plain-language companion to [[ib-device-and-client-model|the technical note]]. Same facts, fewer identifiers.

## The problem

The RDMA stack has many **providers** (hardware and software drivers: mlx5, bnxt_re, irdma, efa, rxe, siw…) and many **clients** (user-space access, the connection managers, IPoIB, NVMe-oF, NFS/RDMA, SMC-R…). They load, unload and get hot-unplugged independently. Every client needs to learn about every device, keep its own per-device state, and, hardest of all, let go before a disappearing device's memory is freed. Without a central registry, each client would need its own driver discovery and its own device-removal races.

## The idea in one paragraph

The RDMA core is a **building directory with a strict move-out procedure**. Devices are apartments; clients are services (mail, cleaning, internet). When an apartment opens, every registered service is told and sets up its account in a slot kept for it. When an apartment closes, services are told in **reverse sign-up order**, so those that depend on earlier ones leave first, and the keys don't go back to the driver until the occupancy count reaches zero. A resident who won't leave (a user process holding the device open) isn't waited for: the locks are changed (**disassociation**) and they're left holding a dead key.

## Step by step

### Step 1: Allocate
A provider embeds the core device structure at the start of its own and fills in its **operations table**, about 200 optional entries. Missing entries tell the core what isn't supported (no dma-buf registration, no disassociation support, and so on). It sets limits and port counts and, for RoCE and iWARP, binds each port to its network device.

### Step 2: Register in two stages
The device gets a unique name (e.g. `mlx5_0`) and a slot in a global table, but **without** the "registered" mark. That mark is the state machine: anyone iterating over live devices only sees marked ones, while half-built or half-removed devices stay reachable for the code building or tearing them down. The core records which device does DMA (software providers pass none and use plain kernel addresses; confidential-computing guests get bounce buffering), sets up port caches, sysfs, cgroup accounting and counters, and adds the device to the driver model with announcements suppressed, so udev never sees a half-initialised device.

### Step 3: Enable and tell every client
The device's reference count is set to one, the mark is set, and every registered client is called to add it. A client can decline (IPoIB skips non-InfiniBand ports; clients needing kernel verbs skip devices without them). Accepting clients store per-device state in the device's client slot. A client that registers later, say when a module loads, gets the same call for every existing device. Client IDs are handed out in increasing order, which is what later makes teardown reverse-ordered.

### Step 4: Holding a device
Code outside the registry, such as netlink handlers or lookups by network device, takes a reference only if the count is still non-zero, and releases it when done. A positive count means "registered and cannot finish unregistering"; the last release signals whoever is waiting.

### Step 5: Unregister carefully
This is the key step. Unregistering runs under a lock so racing attempts (a driver unbinding while netlink deletes a software link) are fenced: whoever comes second finds the device already dead. Sub-devices go first. Then the mark is cleared so new lookups stop, and clients are told to remove the device **in reverse order**; their callbacks may sleep and must release everything they created. The core destroys the shared completion-queue pool, drops its own reference, and **waits** for every other holder to let go. Only then are network bindings, sysfs, cgroup data and caches torn down, and with modern drivers the core frees the device itself.

### Step 6: Don't wait for user space: disassociate
The user-access client can't block removal until every process closes the device file, because a process could keep it open forever. Instead it waits out system calls already in progress, destroys every hardware object in every open context, and revokes all memory mappings of card registers (later accesses see a harmless zero page instead of a doorbell). It posts a "device fatal" event. The process keeps valid file descriptors, but every verb now fails, so it can clean up at its own pace while the card is removed immediately. Drivers without disassociation support instead make module unload wait for the files to close.

### Step 7: Namespaces and names
By default ("shared" mode) every device is visible in every network namespace through shadow devices. In "exclusive" mode a device lives in exactly one namespace and moving it is effectively a full disable/enable, so every client re-evaluates. Devices can be renamed (udev gives stable names like `rocep1s0f0`) and clients are told.

### Step 8: Locking rules
Three reader/writer locks protect the device table, the client table and each device's client slots, and they're never nested except in one documented order. Add and remove callbacks run in process context and may sleep; a client mustn't use a device before its add or after its remove returns.

## The picture

```text
 provider registers mlx5_0 ─▶ [table slot, NOT marked] → caches, sysfs, cgroup
                           ─▶ mark "registered", refcount = 1
                           ─▶ clients add (in ID order): uverbs, umad, cm, rdma_cm, ipoib…
 unregister ─▶ unmark → clients remove (reverse order) → wait refcount → tear down → free
 user process with device open: disassociated → handles valid, verbs fail with EIO
```

## Tradeoffs

- **What it gives you:** automatic discovery of every device by every client, per-client state per device, safe concurrent registration and lookup, and immediate hot-unplug even with processes still attached.
- **What it costs / requires:** every user-access path must handle "device gone" at any moment, which is why in-flight calls are tracked and revoked mappings point at a zero page.
- **Where it bites:** drivers that freed their own device after unregistering raced with netlink and sysfs users; moving freeing into the core (5.1) fixed it. Clients that depend on each other rely on the reverse teardown order.

## How it got here

- **2.6.11:** the original registry, with a global device list and one mutex.
- **4.20/5.0:** the separate operations table replaced function pointers directly in the device structure.
- **5.1 (2019):** Jason Gunthorpe's rework: tables plus reader/writer locks with marks as state, safe references, core-managed freeing, per-driver and deferred unregistration, and renaming. Motivated partly by rxe/siw link deletion racing with driver unbind.
- **5.2–5.3:** network namespace support.
- **6.x:** sub-devices, NUMA-aware allocation, confidential-computing bounce buffering.

## Related

- Technical version: [[ib-device-and-client-model]]
- [[rdma-explained|RDMA subsystem]], [[verbs-api-and-uverbs|Verbs and uverbs]], [[roce-gid-table-and-netdev-binding-explained|RoCE GID table]], [[rdma-netlink-restrack-and-cgroup-explained|Netlink, restrack and cgroup]]
