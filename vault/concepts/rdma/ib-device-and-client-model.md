---
title: "ib_device and the Client Model"
category: concept
tags: [rdma, infiniband, device-model, hotplug, ib-core]
subsystem: rdma
kernel_version: "2.6.11 (xarray/two-stage registration rewrite: 5.1)"
researched: 2026-09-26
status: complete
explained: "[[ib-device-and-client-model-explained]]"
sources:
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/device.c
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_verbs.h
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/uverbs_main.c
  - https://www.kernel.org/doc/html/latest/infiniband/core_locking.html
---

# ib_device and the Client Model

> 📘 Plain-language version: [[ib-device-and-client-model-explained]]

## Purpose

The RDMA stack has many **providers** (hardware drivers: mlx5, bnxt_re, irdma, efa, rxe, siw ...) and many **clients** (uverbs, the CMs, IPoIB, NVMe-oF, NFS/RDMA, SMC-R ...), and they load, unload and hot-unplug independently. `ib_core` is a small publish/subscribe registry between them. It tells every client about every device, gives each client private per-device state, and, hardest of all, guarantees that when a device disappears every client has let go of it before the driver's memory is freed. Without it, each ULP would need its own ad-hoc driver discovery and its own device-removal races.

## Mental Model

Think of `ib_core` as a **building directory with a strict move-out procedure**. Devices are apartments and clients are services (mail, cleaning, internet). When an apartment opens, every registered service gets an `add()` call and sets up its account, stored in the device's `client_data` slot for that service. When an apartment closes, the services are told in *reverse* sign-up order (LIFO), so services that depend on earlier ones leave first. The landlord doesn't hand the keys back to the driver until the occupancy count (`refcount`) reaches zero. A resident who refuses to leave (a userspace process holding a verbs context) isn't waited for. Their locks are changed (**disassociation**) and they're left holding a dead key.

## How It Works

**Allocation.** A provider embeds `struct ib_device` as the first member of its own device struct and allocates it with the `ib_alloc_device(drv_struct, member)` macro, which wraps `_ib_alloc_device()`. It fills in `struct ib_device_ops` with `ib_set_device_ops()`. This vtable holds roughly 200 optional function pointers, and the core uses NULL checks as capability discovery: no `reg_user_mr_dmabuf` means no dma-buf MRs, and no `disassociate_ucontext` means uverbs must pin the driver module while files are open. It sets `attrs`, `phys_port_cnt` and `node_type`, and, for RoCE and iWARP, binds each port to its `net_device` with `ib_device_set_netdev()`.

**Two-stage registration.** `ib_register_device(device, name, dma_device)` first calls `assign_name()`, which resolves a `%d` pattern like `mlx5_%d` under the write side of `devices_rwsem` so names are unique. This puts the device in the global `devices` xarray, but *without* the `DEVICE_REGISTERED` mark. The xarray mark is the state machine. Anyone iterating with `xa_for_each_marked(..., DEVICE_REGISTERED)` sees only fully live devices, while half-registered or half-removed devices stay findable by index for the code that is building or tearing them down. The core then records `dma_device`. If the driver passes NULL (software providers like rxe and siw), the `ib_dma_*` helpers store kernel virtual addresses instead of DMA addresses, which is the `ib_uses_virt_dma()` case. In a confidential-computing guest it sets `cc_dma_bounce`. It sets up per-port data and the GID/P_Key cache (`ib_cache_setup_one`), registers sysfs attribute groups, the rdma cgroup device (`ib_device_register_rdmacg`) and counters, then calls `device_add()` with uevents suppressed so udev never sees a half-initialized device.

**Enabling and client fan-out.** `enable_device_and_get()` sets `refcount` to 1, sets the `DEVICE_REGISTERED` mark, and iterates the `clients` xarray, calling `add_client_context()` → `client->add(device)` for each client. A client that doesn't want the device returns `-EOPNOTSUPP`. For example, IPoIB skips non-IB ports, and clients that need kernel verbs skip devices without `kverbs_provider` unless `no_kverbs_req` is set. The client stores its per-device state with `ib_set_client_data()`, which sets the `CLIENT_DATA_REGISTERED` mark in the device's `client_data` xarray. When a *client* registers later (`ib_register_client()`, e.g. `modprobe ib_ipoib`), it gets the next `client_id` and the same `add()` call on every already-registered device. Client IDs are assigned monotonically, and that ordering is what later makes teardown LIFO.

**Holding a device.** Code outside the registry that wants to use a device, such as netlink handlers or `ib_device_get_by_netdev()`, calls `ib_device_try_get()`. It increments `refcount` only if the count is non-zero, and the caller must `ib_device_put()` afterwards. A positive `refcount` means "registered and cannot finish unregistering". The last put completes `unreg_completion`.

**Unregistration (the slow, careful path).** `ib_unregister_device()` runs `__ib_unregister_device()` under `unregistration_lock`, so racing unregisters (a driver unbinding while netlink deletes an rxe link) are fully fenced: whichever returns second sees an already-dead device. It removes sub-devices first. Then `disable_device()` clears `DEVICE_REGISTERED` (new lookups stop), walks client IDs **downward** from `highest_client_id`, and calls `remove_client_context()` → `client->remove(device, client_data)` for each. Removal callbacks may sleep and must release every object they created on the device. The core then destroys the shared CQ pool, drops the registration reference, and **waits** on `unreg_completion` for every `ib_device_try_get()` holder. Only then are netdev bindings, sysfs, the cgroup device and caches torn down. If the driver uses the modern `dealloc_driver` op, the core frees the device itself.

**Userspace can't be waited for: disassociation.** The uverbs client can't block removal until every process closes `/dev/infiniband/uverbsN`, because a process could hold it forever. In its `remove()` callback, `ib_uverbs_remove_one()` instead **disassociates**. It uses SRCU (`disassociate_srcu`) to wait out in-flight syscalls, destroys every hardware object in every open context with reason `RDMA_REMOVE_DRIVER_REMOVE`, and revokes all mmaps (`rdma_user_mmap_disassociate()` zaps the PTEs, and later faults get a zero `disassociate_page` instead of a doorbell). It posts `IB_EVENT_DEVICE_FATAL` to the async event fd. The process keeps valid file descriptors, but every verb now returns `-EIO`, so it can clean up at its own pace and the NIC can be removed immediately. Drivers that implement `disassociate_ucontext` get this behaviour. Others make uverbs hold a module reference, so module unload waits for the files to close.

**Namespaces and renaming.** By default (`ib_core netns_mode=1`, "shared") every device is visible in all network namespaces through `compat_devs` shadow devices. In exclusive mode (`rdma system set netns exclusive`) a device lives in exactly one netns and moves with `rdma dev set <dev> netns <ns>`. The move runs `rdma_dev_change_netns()`, which is effectively a full disable/enable cycle so every client re-evaluates. `ib_device_rename()` lets udev rules give stable names (`rdma_rename` → names like `rocep1s0f0`) and calls each client's `rename` hook.

**Locking rules for users.** The three rwsems (`devices_rwsem`, `clients_rwsem`, per-device `client_data_rwsem`) each protect the xarray of the same name and are never nested, except that client_data may nest inside the read side of the other two. Per the midlayer locking document, `add()` and `remove()` run in process context and may sleep, the device must not be used before `add()` or after `remove()` returns, and `ib_register_device()` must be called from process context without holding semaphores that could deadlock against a client's callbacks.

## Key Data Structures

**`struct ib_device`** (`include/rdma/ib_verbs.h`) — one RDMA device (possibly multi-port).
- `ops` — provider vtable; NULL entries mean "not supported"
- `index` — slot in the global `devices` xarray
- `client_data`, `client_data_rwsem` — per-client private pointers
- `refcount`, `unreg_completion`, `unregistration_lock` — registration lifetime
- `port_data` — per-port caches, netdev binding, counters
- `dma_device` — the struct device used for DMA mapping (NULL = virtual addresses)
- `compat_devs` — shadow devices for shared-netns mode
- `parent`, `subdev_list_head`, `type` — sub-device hierarchy (SMI sub-devices, for example)

**`struct ib_client`** (`include/rdma/ib_verbs.h`) — a consumer of RDMA devices.
- `add`, `remove`, `rename` — lifecycle callbacks
- `get_net_dev_by_params` — lets rdma_cm find e.g. the IPoIB netdev for an incoming request
- `get_nl_info` — lets netlink report the client's char device (uverbs, umad)
- `uses`, `uses_zero` — client-level refcount for `ib_unregister_client()`
- `no_kverbs_req` — willing to bind devices without kernel verbs support

## Key Functions / Entry Points

- **`ib_register_device()`** (`device.c`) — named, two-stage registration; ends with `ib_device_notify_register()` (netlink event)
- **`ib_unregister_device()` / `ib_unregister_device_queued()` / `ib_unregister_driver()`** — synchronous, async (from atomic or event contexts) and per-driver bulk unregister
- **`enable_device_and_get()` / `disable_device()`** — mark flip plus client fan-out and fan-in
- **`ib_register_client()` / `ib_unregister_client()`** — subscribe to all present and future devices
- **`ib_set_client_data()` / `ib_get_client_data()`** — per-client, per-device state
- **`ib_device_try_get()` / `ib_device_put()`** — hold a device registered
- **`ib_device_get_by_netdev()` / `ib_device_set_netdev()`** — RoCE/iWARP netdev ↔ ib_device mapping
- **`ib_uverbs_remove_one()` → `uverbs_destroy_ufile_hw()`** (`uverbs_main.c`, `rdma_core.c`) — userspace disassociation

## Important Flags & Config Options

- `CONFIG_INFINIBAND` — builds `ib_core`
- `ib_core.netns_mode` / `rdma system set netns shared|exclusive` — device visibility across network namespaces
- `ops.dealloc_driver` — opt in to core-managed freeing (the modern flow; required for `ib_unregister_driver()`)
- `ops.disassociate_ucontext` — opt in to hot-unplug without waiting for userspace
- `kverbs_provider` / `no_kverbs_req` — whether kernel ULPs can bind the device

## Interactions with Other Subsystems

- **↑ Userspace**: `rdma dev`, `rdma link`, `rdma system` (iproute2 over `NETLINK_RDMA`); sysfs `/sys/class/infiniband/<dev>`; udev rename rules
- **→ Driver core**: each `ib_device` is a `struct device` (`class infiniband`); `device_add`/`device_del` with suppressed uevents during setup
- **→ net**: netdev binding per port, and netns ownership for exclusive mode; netdev notifiers can trigger unregister (rxe when its netdev goes away)
- **→ LSM**: `ib_security_change()` notifier re-evaluates P_Key access (SELinux `infiniband_pkey`)
- **← Clients**: uverbs, umad, ucma, `ib_cm`, `iw_cm`, `rdma_cm`, IPoIB, SRP/iSER, NVMe-oF host/target, xprtrdma/svcrdma, SMC-R, RTRS

## Design Decisions & Tradeoffs

- **Xarray marks as the state machine.** The 2019 rework (Jason Gunthorpe, 5.1) replaced linked lists and a global mutex with xarrays plus rwsems, where the presence of a mark means "fully registered". This allows concurrent registration and lookup and restartable iteration, without holding a lock across client callbacks that may sleep.
- **LIFO client teardown.** Later clients may depend on earlier ones (rdma_cm depends on ib_cm and the SA client), so they are removed in reverse registration order.
- **Disassociate rather than wait.** Blocking hot-unplug on userspace was untenable for servers and for PCI error recovery. The cost is that every uverbs path has to cope with "device gone" at any point, so the SRCU read sections and zero-page mmaps exist.
- **Core-managed dealloc.** Earlier drivers freed their own `ib_device` after unregister, racing with netlink and sysfs users. `dealloc_driver` moved ownership to the core, so the last reference frees it.

## How It Has Evolved

- **2.6.11** — original `ib_register_device`/`ib_client` with a global device list and mutex
- **4.x** — `ib_device_ops` introduced (4.20/5.0) to replace direct function pointers in `ib_device`
- **5.1** — xarray-based registry, `ib_device_try_get`, `dealloc_driver`, `ib_unregister_driver`, `ib_unregister_device_queued`, device rename
- **5.2–5.3** — net namespace support (shared/exclusive), compat devices
- **6.x** — sub-devices (`add_sub_dev`/`del_sub_dev`), NUMA-aware object allocation (`get_numa_node`), CoCo `cc_dma_bounce`

## Further Reading

- kernel.org — [InfiniBand Midlayer Locking](https://www.kernel.org/doc/html/latest/infiniband/core_locking.html)
- Source — `drivers/infiniband/core/device.c` (the block comment at the top explains the rwsem/xarray rules)
- Parent note: [[rdma]]; related: [[verbs-api-and-uverbs]], [[roce-gid-table-and-netdev-binding]]

## LKML Highlights

- **"RDMA: Use xarray and rwsem for device and client lists" (Jason Gunthorpe, early 2019, 5.1 cycle)** — replaced the global `device_mutex` so client add/remove no longer ran under one lock. Introduced the mark-based two-stage flow and `ib_device_try_get()`. (Message-id not retrievable this session; the lore search tool failed with a TLS error.)
- **Driver-managed vs core-managed dealloc (`dealloc_driver`, 5.1)** — motivated by rxe/siw netlink `link delete` racing with driver unbind; led to `ib_unregister_driver()` for module exit.
