---
title: "Netdev Queue Management API (Per-Queue Restart, Memory Providers, Queue Leasing)"
category: concept
tags: [net, queue-api, memory-provider, page-pool, netkit, zero-copy]
subsystem: net
kernel_version: "6.10 (queue_mgmt_ops); 6.12 (netdev_rx_queue_restart + providers); 2026 (queue config, queue leasing / queue-create)"
researched: 2026-09-26
status: complete
sources:
  - https://github.com/torvalds/linux/blob/master/include/net/netdev_queues.h
  - https://github.com/torvalds/linux/blob/master/net/core/netdev_rx_queue.c
  - https://github.com/torvalds/linux/blob/master/net/core/netdev-genl.c
  - https://github.com/torvalds/linux/blob/master/Documentation/netlink/specs/netdev.yaml
  - https://www.mail-archive.com/dri-devel@lists.freedesktop.org/msg484975.html
  - https://www.mail-archive.com/linux-trace-kernel@vger.kernel.org/msg01139.html
  - https://ratatoskr.run/netdev/2026/04/7945760/t
  - https://ratatoskr.run/netdev/2026/06/17118890/t
---

# Netdev Queue Management API (Per-Queue Restart, Memory Providers, Queue Leasing)

## Purpose

Historically a NIC driver owned all its queues as a block. Changing anything about how RX buffers are allocated meant `ndo_stop` + `ndo_open` (a full interface bounce, dropping every flow) or driver-private reset paths. Zero-copy receive needs something much finer. When a process binds a dma-buf (devmem TCP) or an io_uring area (zcrx) to **one** RX queue, that queue's page pool must be torn down and rebuilt to pull buffers from the new **memory provider**, while every other queue keeps running. The **queue management API** (`struct netdev_queue_mgmt_ops`) is a small driver contract that lets the core **allocate, start, stop and free a single RX queue's resources** in a failure-safe, restartable way. It has since grown per-queue configuration (e.g. `rx_page_size`), a DMA-device query, and **queue leasing**, so a virtual device in a container (netkit) can proxy memory providers and AF_XDP onto a physical NIC queue.

## Mental Model

Think of each RX queue as a **train car** on a moving train. Before, changing a car's cargo system meant stopping the whole train. The queue API lets the core **prepare a replacement car on a siding** (allocate new memory with the new configuration), then briefly **uncouple the old car and couple the new one** (stop old, start new), then scrap the old car. If coupling fails, the old car goes back on (restart with old memory). **Leasing** is a sub-let: a container's virtual device gets a "car" that is really a pointer to a car on the physical train, so anything the container attaches to its car is actually installed on the physical one.

## How It Works

**The driver contract (`include/net/netdev_queues.h`).** A driver sets `dev->queue_mgmt_ops` to a `struct netdev_queue_mgmt_ops`:
- `ndo_queue_mem_size` — size of the driver's opaque per-queue memory blob (rings, page pool, descriptors, NAPI-related state)
- `ndo_queue_mem_alloc(dev, qcfg, mem, idx)` — allocate *everything* a queue needs into `mem`, including creating the page pool (which asks the queue's memory provider, if any, for buffers) and filling descriptors, **without touching the live queue**
- `ndo_queue_start(dev, qcfg, mem, idx)` — make `mem` the live queue: program hardware, enable NAPI
- `ndo_queue_stop(dev, mem, idx)` — quiesce the live queue and move its resources into `mem`
- `ndo_queue_mem_free(dev, mem)` — free a (stopped) queue's resources
- `ndo_default_qcfg` / `ndo_validate_qcfg` — per-queue configuration (`struct netdev_queue_config`, currently `rx_page_size`), advertised via `supported_params` (`QCFG_RX_PAGE_SIZE`)
- `ndo_queue_get_dma_dev(dev, idx)` — the `struct device` that DMAs for this queue (can differ per queue on multi-PF or SR-IOV-like devices), used by providers to map memory correctly
- `ndo_queue_create(dev, extack)` — (virtual devices) create a new RX queue for leasing

**Restart / reconfigure (`netdev_rx_queue_reconfig()`, `net/core/netdev_rx_queue.c`).** Under the netdev **instance lock** (`netdev_assert_locked`):
1. `kvzalloc` two blobs, `new_mem` and `old_mem`.
2. `ndo_queue_mem_alloc(new config → new_mem)`. The new page pool is created here, so if a provider was just recorded in `rxq->mp_params`, the pool is built on it. Allocation failures happen *before* disruption.
3. `page_pool_check_memory_provider(dev, rxq)` verifies the driver actually created a pool using the queue's provider. A driver that silently ignored it would put provider-less pages where the application expects its memory, so this fails closed.
4. If the device is running: `ndo_queue_stop(old_mem)` then `ndo_queue_start(new_mem)`. If start fails, restart with `old_mem` (WARN if even that fails), free the new resources, and return the error. If the device is down, just swap blobs so the next open uses the new configuration.
5. `ndo_queue_mem_free(old_mem)`.

`netdev_rx_queue_restart(dev, idx)` is the "same config, fresh resources" wrapper, exported in the `NETDEV_INTERNAL` namespace.

**Binding a memory provider (`netif_mp_open_rxq()` / `__netif_mp_open_rxq()`).** Providers never talk to drivers directly. io_uring zcrx (`io_register_zcrx`) and devmem (`net_devmem_bind_dmabuf_to_queue`) call `netif_mp_open_rxq(dev, idx, &pp_memory_provider_params{mp_ops, mp_priv, rx_page_size}, extack)`, which:
- resolves **leases** (`__netif_get_rx_queue_lease(..., NETIF_VIRT_TO_PHYS)`): if the ifindex/queue is a virtual device's leased queue, operate on the physical device and queue instead
- validates preconditions: queue ops present; `tcp-data-split` enabled and `hds-thresh == 0`; no XDP program; `rx_page_size` supported if requested; queue not already provider-bound or used by AF_XDP; queue index in range ([[header-split-and-flow-steering-for-zero-copy-rx]])
- stores the params in `rxq->mp_params`, validates the resulting queue config (`netdev_queue_config_validate()`), and runs the reconfigure above, rolling `mp_params` back on failure.

`netif_mp_close_rxq()` clears `mp_params` and restarts the queue onto ordinary pages. If the physical device is unregistered, the core calls each provider's `uninstall` so it can drop its references ([[page-pool]], [[netmem-and-net-iov-abstraction]]).

**Queue leasing (2026, Daniel Borkmann & David Wei).** Containers (Kubernetes pods using Cilium's **netkit** devices) can't see the physical NIC, yet zcrx, devmem and AF_XDP all take `(ifindex, queue_id)`. Leasing bridges this:
- netlink **`queue-create`** (`NETDEV_CMD_QUEUE_CREATE`) on a *virtual* device with `type = rx` and a nested **`lease {ifindex, queue, netns-id}`** calls the virtual device's `ndo_queue_create()` to add a queue, then `netdev_rx_queue_lease(virt_rxq, phys_rxq)`. That links `rxq->lease` in both directions and holds a tracked reference on the physical device.
- memory-provider binding and AF_XDP pool registration (`xsk_reg_pool_at_qid`) on the virtual queue are **proxied** to the physical queue, so the physical NIC fills that queue from memory DMA-mapped from the container's process.
- direction checks (`netif_lease_dir_ok()`: virtual devices have no `dev.parent`, physical ones do) prevent loops. Lock order is virtual before physical. A netdevice notifier cleans up dependent netkit devices when the physical device goes away. Ethtool channel resizing refuses to remove leased or busy queues.
- For TX, devmem `bind-tx` on a `NETMEM_TX_NO_DMA` virtual device walks its leased queues to find the physical DMA device ([[devmem-tcp-tx]]). June 2026 follow-ups extend netkit's io_uring zero-copy support.

**Who implements it.** Drivers with memory-provider support implement the queue ops: Broadcom bnxt, Google gve, NVIDIA mlx5, Meta fbnic, netdevsim (for selftests), and others added with zcrx/devmem enablement. The API is also the basis for future per-queue reconfiguration (ring sizes, buffer sizes) without full resets.

## Key Data Structures

**`struct netdev_queue_mgmt_ops`** (`include/net/netdev_queues.h`) — `ndo_queue_mem_size`, `ndo_queue_mem_alloc`, `ndo_queue_mem_free`, `ndo_queue_start`, `ndo_queue_stop`, `ndo_default_qcfg`, `ndo_validate_qcfg`, `ndo_queue_get_dma_dev`, `ndo_queue_create`, `supported_params`.

**`struct netdev_queue_config`** — `rx_page_size` (for now).

**`struct netdev_rx_queue`** (`include/net/netdev_rx_queue.h`) — per-RX-queue core state: `dev`, `napi`, `mp_params` (`struct pp_memory_provider_params {mp_ops, mp_priv, rx_page_size}`), `pool` (AF_XDP), `lease`, `lease_tracker`.

## Key Functions / Entry Points

- **`netdev_rx_queue_reconfig()` / `netdev_rx_queue_restart()`** — failure-safe per-queue swap
- **`netif_mp_open_rxq()` / `netif_mp_close_rxq()`** — install and remove a memory provider (with lease proxying)
- **`page_pool_check_memory_provider()`** — verify the driver honoured the provider
- **`netdev_queue_get_dma_dev()`** — DMA device for a queue
- **`netdev_nl_queue_create_doit()`** (`netdev-genl.c`) / **`netdev_rx_queue_lease()` / `netdev_rx_queue_unlease()`** — leasing
- **`__netif_get_rx_queue_lease()` / `netif_rxq_is_leased()` / `netif_rxq_has_unreadable_mp()`** — helpers used by providers, AF_XDP and ethtool

## Important Flags & Config Options

- Instance lock: queue ops run under `netdev_lock()` (the per-netdev lock replacing RTNL for these paths); drivers opt in via `netdev_need_ops_lock()`
- `QCFG_RX_PAGE_SIZE` — driver supports custom RX page sizes per queue
- Netlink: `queue-get` (shows provider and lease), `queue-create` with nested `lease`
- Symbol namespace `NETDEV_INTERNAL`

## Interactions with Other Subsystems

- **↑ Userspace**: indirectly via `bind-rx`, `IORING_REGISTER_ZCRX_IFQ`, AF_XDP bind, and directly via `queue-create` ([[netdev-netlink-family]])
- **→ page pool**: queue allocation creates pools; providers plug in through `mp_params` ([[page-pool]])
- **→ drivers**: implement queue ops; NAPI per queue ([[network-device-and-napi]])
- **← devmem / zcrx / AF_XDP**: all bind through these helpers ([[devmem-tcp-rx-dmabuf-binding-and-token-recycling]], [[zero-copy-rx-zcrx]], [[af-xdp]])
- **← ethtool**: channel and ring changes consult provider and lease state ([[header-split-and-flow-steering-for-zero-copy-rx]])
- **← containers**: netkit leasing brings zero-copy into pods ([[network-namespaces]])

## Design Decisions & Tradeoffs

- **Allocate-before-stop.** Allocating the full new queue before stopping the old one doubles transient memory but makes failures non-disruptive, which matters when binding is driven by unprivileged-ish applications at runtime.
- **Opaque per-queue blobs.** The core never interprets driver queue memory, which keeps the API tiny and driver-agnostic. The cost is that correctness (e.g. actually using the provider) must be verified after the fact (`page_pool_check_memory_provider`).
- **Core-mediated providers.** Providers go through `netif_mp_open_rxq()` rather than driver hooks, so the core can enforce HDS, XDP, AF_XDP and lease invariants uniformly for zcrx and devmem.
- **Leasing instead of passthrough.** Rather than handing containers the physical netdev, leases proxy only the queue-level operations, keeping the physical device in the host namespace. The price is lock-ordering rules, notifier-driven cleanup, and more paths that must understand leases.

## How It Has Evolved

- **2024 (6.10)** — queue API defined (Mina Almasry, reviewed by Jakub Kicinski) as part of devmem prerequisites
- **6.12** — `netdev_rx_queue_restart()`, memory providers bound via restart, devmem RX
- **6.13–6.15** — `netif_mp_open_rxq()`/`close` generalized for io_uring zcrx; `page_pool_check_memory_provider()`; instance lock replaces RTNL for queue ops
- **2025–26** — per-queue config (`netdev_queue_config`, `rx_page_size`, validate hooks); `ndo_queue_get_dma_dev`
- **2026** — queue leasing and `queue-create` for netkit (Daniel Borkmann, David Wei; v11 April 2026); AF_XDP and providers proxied through leases; netkit io_uring ZC extensions (June 2026)

## Further Reading

- Source — `include/net/netdev_queues.h`, `net/core/netdev_rx_queue.c`
- Mailing list — [queue_api: define queue api (RFC v6)](https://www.mail-archive.com/dri-devel@lists.freedesktop.org/msg484975.html); [netdev: add netdev_rx_queue_restart() (v26)](https://www.mail-archive.com/linux-trace-kernel@vger.kernel.org/msg01139.html)
- Ratatoskr — [netkit: Support for io_uring zero-copy and AF_XDP (queue leasing) v11](https://ratatoskr.run/netdev/2026/04/7945760/t); [Extend netkit io_uring ZC](https://ratatoskr.run/netdev/2026/06/17118890/t)
- Related: [[page-pool]], [[devmem-tcp]], [[zero-copy-rx-zcrx]], [[netdev-netlink-family]], [[af-xdp]]

## LKML Highlights

- **"queue_api: define queue api" (Mina Almasry, RFC v6, March 2024)** — defined the mem_alloc/mem_free/start/stop contract. Jakub Kicinski pushed for a driver flag advertising memory-provider support so the core can refuse unsupported devices early.
- **"netdev: add netdev_rx_queue_restart()" (v18–v26, 2024)** — the restart helper at the head of the devmem series, with the allocate-first, restore-on-failure semantics still used today.
- **"netkit: Support for io_uring zero-copy and AF_XDP" v11 (Daniel Borkmann, David Wei, April 2026)** — queue leasing via `queue-create`, proxying `netif_mp_{open,close}_rxq` and `xsk_{reg,clear}_pool_at_qid` to physical queues. Tested on mlx5 ConnectX-6 and bnxt 100G. Reviews consolidated driver callbacks into core APIs and tightened ethtool channel checks.
