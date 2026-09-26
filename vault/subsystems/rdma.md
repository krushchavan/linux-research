---
title: "RDMA"
category: subsystem
tags: [rdma, infiniband, roce, verbs, kernel-bypass, zero-copy]
maintainer: Jason Gunthorpe, Leon Romanovsky (NVIDIA)
mailing_list: linux-rdma@vger.kernel.org
source_path: drivers/infiniband/, include/rdma/, include/uapi/rdma/
researched: 2026-09-26
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/infiniband/index.html
  - https://www.kernel.org/doc/html/latest/infiniband/user_verbs.html
  - https://www.kernel.org/doc/html/latest/infiniband/core_locking.html
  - https://raw.githubusercontent.com/torvalds/linux/master/MAINTAINERS
  - https://github.com/torvalds/linux/tree/master/drivers/infiniband/core
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_verbs.h
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_umem.h
  - https://github.com/torvalds/linux/blob/master/include/uapi/rdma/ib_user_ioctl_verbs.h
  - https://lwn.net/Articles/733179/
  - https://lwn.net/Articles/836484/
  - https://lwn.net/Articles/1056826/
  - https://lwn.net/Articles/674161/
  - https://lwn.net/Articles/914607/
  - https://patchwork.kernel.org/project/linux-rdma/patch/20181203205827.GA25410@ziepe.ca/
---

# RDMA Subsystem

## Overview

The RDMA subsystem (historically, and still in its paths, "InfiniBand") is the kernel's framework for **Remote Direct Memory Access** network adapters. On these NICs the *hardware* runs the transport protocol and moves bytes directly between registered application memory on two hosts, with no kernel involvement per operation and no CPU copies. The kernel is the **control plane**: it discovers devices, allocates and protects hardware objects (queues, memory keys), pins and DMA-maps memory, sets up connections, and cleans up when a process dies. The **data plane** (posting work and polling completions) runs straight from userspace to memory-mapped hardware doorbells. It supports three wire transports behind one API: native InfiniBand, RoCE (RDMA over Converged Ethernet) and iWARP (RDMA over TCP). It also has two software-only providers (rxe, siw) that run RDMA over any Ethernet NIC.

## Mental Model

**The kernel is a notary, not a courier.** In the socket model the kernel carries every byte: `send()` copies into an skb, the stack builds headers, and the NIC DMAs from kernel memory. In RDMA the kernel only notarizes agreements up front. It says "this region of process memory is pinned at these DMA addresses and may be accessed with key 0x1234", and "this queue pair belongs to this process and may talk to that remote QP". After that the application and the NIC talk directly. The application writes a *work request* into a queue in its own memory and rings a doorbell page mapped into its address space. The NIC reads the request, moves the data (possibly writing straight into the *remote* host's memory without that host's CPU noticing), and writes a *completion* into another queue that the application polls.

Almost every design decision in the subsystem follows from that split. Slow-path operations sleep, allocate and validate heavily. Fast-path verbs must never sleep. Memory must stay put for as long as the hardware might touch it, which is why pinning, ODP and dma-buf dominate the subsystem's history.

Compare [[io_uring]]: io_uring also uses shared-memory submission and completion rings to avoid per-operation syscalls, but the *kernel* still executes every operation. In RDMA the kernel executes none of them.

## Architecture

```mermaid
flowchart TB
    subgraph US[Userspace]
        APP[Application / MPI / NCCL / SPDK]
        LIBIBV[libibverbs + provider lib e.g. libmlx5]
        LIBCM[librdmacm]
    end
    subgraph K[Kernel: drivers/infiniband/core]
        UVERBS[ib_uverbs<br/>/dev/infiniband/uverbsN<br/>ioctl + legacy write ABI]
        UCMA[ucma<br/>/dev/infiniband/rdma_cm]
        UMAD[ib_umad<br/>/dev/infiniband/umadN]
        CORE[ib_core<br/>device + client registry<br/>verbs dispatch, caches]
        UMEM[ib_umem<br/>pin / ODP / dma-buf]
        CMA[rdma_cm<br/>IP-addressed connections]
        CM[ib_cm / iw_cm]
        MAD[MAD + SA client]
        GID[RoCE GID mgmt<br/>netdev notifier]
        RW[rdma_rw API<br/>for kernel ULPs]
        NL[rdma netlink nldev<br/>restrack, counters]
        CG[rdma cgroup]
    end
    subgraph ULP[Kernel ULPs]
        NVMEOF[NVMe-oF RDMA]
        NFSRDMA[NFS/RDMA]
        IPOIB[IPoIB]
        SMC[SMC-R]
        ISER[iSER / SRP / RTRS]
    end
    subgraph HW[Providers]
        MLX[mlx5, bnxt_re, irdma, efa, ionic, hns ...]
        SW[rxe (Soft-RoCE), siw (soft-iWARP)]
    end
    APP --> LIBIBV --> UVERBS
    APP --> LIBCM --> UCMA --> CMA
    LIBIBV -. doorbell MMIO + CQ polling, no syscall .-> MLX
    UVERBS --> CORE
    UVERBS --> UMEM
    CMA --> CM --> MAD
    CORE --> MLX
    CORE --> SW
    ULP --> RW --> CORE
    ULP --> CMA
    GID --> CORE
    NL --> CORE
    UVERBS --> CG
```

Read it top-down for the **control path**. Userspace libraries enter through three character devices: verbs, connection manager and MAD. Each lands in a core module, and `ib_core` dispatches to the provider driver through `struct ib_device_ops`. The dotted arrow is the **data path**. After setup, libibverbs' provider library writes work-queue entries into memory it mmaped from the driver and rings an MMIO doorbell directly, with no kernel transition. Kernel ULPs (NVMe-oF, NFS/RDMA, IPoIB, SMC-R) are clients of `ib_core` just like uverbs is. They use the same verbs from kernel context, usually through the `rdma_rw` helper.

---

## Core Components

### [[ib-device-and-client-model]]

**Purpose**: Hardware drivers ("providers") and consumers ("clients": uverbs, IPoIB, the CMs, NVMe-oF) appear and disappear independently. `ib_core` is the registry that tells every client about every device and guarantees ordered teardown when a NIC is hot-unplugged.

**How it works**: A provider allocates its device with `ib_alloc_device()`, a macro that embeds `struct ib_device` at the start of the driver's own structure. It fills in `ops` (a `struct ib_device_ops` vtable of roughly 200 optional callbacks such as `create_qp`, `post_send`, `reg_user_mr`) with `ib_set_device_ops()`, then calls `ib_register_device()`. Registration assigns a name (e.g. `mlx5_0`), creates sysfs and the per-port cache, and then walks every registered `struct ib_client`, calling `client->add(device)`. Clients stash per-device state with `ib_set_client_data()` in the device's `client_data` xarray. `ib_unregister_device()` runs the reverse walk in reverse client order. It waits for the device `refcount` to drop, fires `IB_EVENT_DEVICE_FATAL`/removal events so users can release objects, and for uverbs *disassociates* open user contexts. After disassociation the process's file descriptors stay valid but its hardware objects are gone, and every further verb fails. Devices can also be network-namespace aware (`compat_devs`, or exclusive mode set through netlink), and a parent device can own sub-devices.

**Key struct**: `struct ib_device` (`include/rdma/ib_verbs.h`)
- `ops` — the provider vtable. The core checks for NULL ops to discover capabilities.
- `client_data` (xarray) + `client_data_rwsem` — per-client private pointers
- `port_data` — per-port GID/P_Key caches, netdev binding and counters
- `attrs` (`struct ib_device_attr`) — capability limits: max QPs, max MR size, atomic support, ODP caps
- `refcount` / `unreg_completion` — keeps the device registered while users hold it
- `cg_device` — rdma cgroup accounting anchor
- `res` — resource-tracking root, used for netlink introspection

**Key functions**:
- `ib_register_device()` / `ib_unregister_device()` — `drivers/infiniband/core/device.c`
- `ib_register_client()` / `ib_unregister_client()` — consumers subscribe to devices
- `ib_device_get_by_netdev()` — RoCE/iWARP lookup from a `net_device`

**Config & flags**: `CONFIG_INFINIBAND` (the `ib_core` module). The `rdma system set netns shared|exclusive` netlink knob controls whether devices are visible in every netns or only in the one they are assigned to.

---

### [[verbs-api-and-uverbs]]

**Purpose**: "Verbs" is the InfiniBand spec's abstract API (create a PD, register an MR, post a send). `ib_uverbs` exposes it to userspace securely: it validates every request, turns user handles into kernel objects, and cleans everything up when the process dies.

**How it works**: libibverbs opens `/dev/infiniband/uverbsN`. The first command allocates an `ib_ucontext`, and the provider returns doorbell and queue memory for the process to `mmap()`. Two ABIs coexist. The original **write() ABI** sends a fixed-layout command struct through `write()`. Because `write()` was being used as an ioctl, it opened credential-confusion holes (a privileged process could be tricked into writing a command). The fix was to forbid it from contexts such as `splice`. That led to the **ioctl ABI** (`RDMA_VERBS_IOCTL`, 4.14–4.20 era, driven by Matan Barak and Jason Gunthorpe). An ioctl call is a header (`object_id`, `method_id`, `driver_id`) plus an array of typed attributes (`struct ib_uverbs_attr`). The kernel describes each method declaratively with `DECLARE_UVERBS_NAMED_METHOD`, listing which attributes are mandatory, which are object handles to look up and lock, and which are output. The generic parser (`uverbs_ioctl.c`) validates the attributes before the handler runs, so handler code only sees a checked `struct uverbs_attr_bundle`. Every user-visible object is an `ib_uobject` in a per-file xarray. Destruction, including destruction forced by process death or device removal, follows a declared dependency order (`rdma_core.c`). Legacy write() commands are now dispatched through the same method tree (`UVERBS_METHOD_INVOKE_WRITE`).

**Key struct**: `struct ib_uobject` (`include/rdma/ib_verbs.h`)
- `user_handle` — the opaque cookie userspace sees in async events
- `ufile` / `context` — owning file and user context
- `object` — the real `ib_qp`/`ib_cq`/`ib_mr`
- `usecnt` — shared vs exclusive lock for concurrent commands
- `cg_obj` — rdma cgroup charge

**Key functions**:
- `ib_uverbs_ioctl()` → `ib_uverbs_cmd_verbs()` — ioctl dispatch (`uverbs_ioctl.c`)
- `uverbs_destroy_ufile_hw()` — teardown on close or disassociation (`rdma_core.c`)
- `rdma_user_mmap_entry_insert()` — hand doorbell and queue memory to userspace safely

**Config & flags**: `CONFIG_INFINIBAND_USER_ACCESS`, `CONFIG_INFINIBAND_USER_MEM`. Per-device `uverbs_cmd_mask` and the driver's `driver_def` uapi tree add vendor-specific methods (mlx5 DevX, for example).

---

### [[queue-pairs-and-completion-queues]]

**Purpose**: These are the data-path objects. A **Queue Pair (QP)** is one endpoint of a hardware transport connection, with a send queue and a receive queue. A **Completion Queue (CQ)** is where the hardware reports finished work. They play the role that io_uring's SQ and CQ play, except that the consumer is the NIC.

**How it works**: A consumer allocates a Protection Domain (`ib_alloc_pd`), which scopes which QPs may use which memory keys. It creates CQs and then a QP bound to a send CQ and a receive CQ (`ib_create_qp`). The QP type sets the service: **RC** (reliable connected: ordered, acked, supports RDMA READ/WRITE/atomics), **UC**, **UD** (unreliable datagram, like UDP), **XRC**, plus vendor types such as mlx5 DC and AWS EFA SRD. A new QP walks a state machine through `ib_modify_qp()`: RESET → INIT → RTR (ready to receive; needs the remote QPN and path) → RTS (ready to send). Work is posted with `ib_post_send()` and `ib_post_recv()`. Each work request carries a list of scatter/gather entries `{addr, length, lkey}` and, for one-sided operations, the remote `{addr, rkey}`. Completions are `struct ib_wc` entries holding `wr_id`, `status`, `opcode` and `byte_len`. Kernel users don't call `ib_poll_cq` in their own loop. They allocate CQs through `ib_alloc_cq()` with an `ib_poll_context` (`IB_POLL_SOFTIRQ` via irq_poll, `IB_POLL_WORKQUEUE`, `IB_POLL_DIRECT`) and attach a `struct ib_cqe` with a `done` callback to every WR. The core polls in budgets and calls the callbacks, and adaptive interrupt moderation (RDMA DIM) tunes coalescing. The **shared CQ pool** (`ib_cq_pool_get`, 5.9) lets many ULP queues share per-vector CQs. Shared Receive Queues (SRQ) let many QPs draw receive buffers from one pool.

**Key struct**: `struct ib_qp` / `struct ib_cq` (`include/rdma/ib_verbs.h`)
- `ib_qp.send_cq`, `recv_cq`, `srq`, `pd` — the objects this QP is wired to
- `ib_qp.qp_num`, `qp_type` — wire identity and service
- `ib_cq.poll_ctx`, `comp_vector` — how and on which CPU completions are reaped
- `ib_cq.dim` — adaptive moderation state

**Key functions**: `ib_create_qp()`, `ib_modify_qp()`, `ib_post_send()`, `ib_post_recv()`, `ib_alloc_cq()`, `ib_cq_pool_get()`, `ib_drain_qp()`

**Config & flags**: WR opcodes (`IB_WR_SEND`, `IB_WR_RDMA_WRITE`, `IB_WR_RDMA_READ`, `IB_WR_ATOMIC_CMP_AND_SWP`, `IB_WR_REG_MR`, `IB_WR_LOCAL_INV`), `IB_SEND_SIGNALED` (request a completion), `IB_SEND_INLINE`.

---

### [[memory-registration-and-ib-umem]]

**Purpose**: The NIC must translate application virtual addresses to DMA addresses by itself, at line rate, possibly for a remote peer. Registration builds that translation (an **MR**, with an `lkey` for local use and an `rkey` to hand to peers), and the kernel must guarantee the pages don't move while the NIC holds them.

**How it works**: `ibv_reg_mr()` reaches the provider's `reg_user_mr`, which calls `ib_umem_get_va()` (or the newer descriptor form, `ib_umem_get_desc()`). The core checks `can_do_mlock()` and charges the page count to `mm->pinned_vm` against `RLIMIT_MEMLOCK`. It then pins with `pin_user_pages_fast(FOLL_LONGTERM | FOLL_WRITE)`, which migrates the pages out of CMA/ZONE_MOVABLE first. It builds an `sg_append_table` from the pages and DMA-maps it with `ib_dma_map_sgtable_attrs()`. The driver calls `ib_umem_find_best_pgsz()` to choose the largest page size its MTT supports for this layout (huge pages give far fewer translation entries), then programs the NIC's translation table. `ib_umem_release()` reverses all of this. Pinning is the root of RDMA's longest-running conflicts with mm: pinned pages defeat reclaim, migration, compaction, and filesystem DAX truncate. That drove the creation of `pin_user_pages()`/`FOLL_LONGTERM` (see [[get-user-pages-and-pinning]]). The alternatives are ODP (next component) and **dma-buf** umems (`ib_umem_dmabuf`, 5.12), which register GPU or accelerator memory that has no `struct page`. Kernel ULPs don't use umem. They use Fast Registration (`IB_WR_REG_MR` posted on the QP), pooled through `ib_mr_pool` and the newer FRMR pools.

**Key struct**: `struct ib_umem` (`include/rdma/ib_umem.h`)
- `owning_mm` — which mm's `pinned_vm` is charged
- `iova`, `address`, `length` — device-visible IOVA vs user VA
- `is_odp`, `is_dmabuf` — which of three flavours this is
- `sgt_append` — the DMA-mapped scatterlist the driver walks

**Key functions**: `ib_umem_get_va()`, `ib_umem_get_desc()`, `ib_umem_find_best_pgsz()`, `ib_umem_release()` (`umem.c`); `ib_umem_dmabuf_get()` (`umem_dmabuf.c`)

**Config & flags**: `IB_ACCESS_LOCAL_WRITE`, `IB_ACCESS_REMOTE_READ/WRITE/ATOMIC`, `IB_ACCESS_ON_DEMAND`, `IB_ACCESS_RELAXED_ORDERING`; `RLIMIT_MEMLOCK` (`ulimit -l`).

---

### [[on-demand-paging-odp]]

**Purpose**: ODP lets an application register memory *without pinning it*. The NIC takes a page fault when it hits an unmapped page, and the kernel invalidates the NIC's mapping when mm wants to move or reclaim the page. The result is RDMA that coexists with swap, THP, NUMA migration and huge address ranges.

**How it works**: With `IB_ACCESS_ON_DEMAND`, `ib_umem_odp_get()` registers an `mmu_interval_notifier` over the range instead of pinning. When the NIC accesses a page with no valid translation, it raises a *network page fault* to the driver (mlx5 handles these in a workqueue). The driver calls `ib_umem_odp_map_dma_and_lock()`, which uses HMM (`hmm_range_fault()`) to fault the pages in, DMA-maps them and updates the NIC's table. Meanwhile the remote side's packet is stalled or retried at the transport level. When mm unmaps or migrates pages, the notifier's `invalidate` callback makes the driver zap the NIC mappings before the pages go away. **Implicit ODP** registers the *entire* address space (`addr=0, length=SIZE_MAX`), and the driver builds child MRs lazily. ODP is the machinery that dma-buf *dynamic* attachment reuses: an exporter's `move_notify` looks just like an mmu-notifier invalidation.

**Key struct**: `struct ib_umem_odp` (`include/rdma/ib_umem_odp.h`)
- `notifier` — the mmu interval notifier over the registered range
- `map` (`struct hmm_dma_map`) — per-page DMA addresses and valid bits
- `umem_mutex` — serializes fault-in vs invalidation
- `is_implicit_odp` — whole-address-space anchor

**Key functions**: `ib_umem_odp_get()`, `ib_umem_odp_map_dma_and_lock()`, `ib_umem_odp_unmap_dma_pages()` (`umem_odp.c`); `mlx5_ib_invalidate_range()` in the mlx5 driver

**Config & flags**: `CONFIG_INFINIBAND_ON_DEMAND_PAGING`; the device capability `attrs.odp_caps` (per transport: which opcodes may fault). Software ODP was added to rxe in 6.x.

---

### [[rdma-cm-connection-manager]]

**Purpose**: Bringing up an RC QP needs the peer's QP number, path (LID/GID, MTU, rate) and initial packet sequence numbers. That exchange is error-prone to hand-roll. The RDMA CM gives a sockets-like API (`rdma_resolve_addr` → `rdma_resolve_route` → `rdma_connect` / `rdma_listen` / `rdma_accept`) keyed by **IP addresses and ports**, so the same code works over IB, RoCE and iWARP.

**How it works**: `rdma_create_id()` makes an `rdma_cm_id` with an event handler. Address resolution (`addr.c`) maps the destination IP to a local RDMA device and port through the IP routing table, plus neighbour resolution for RoCE/iWARP or the SA for IB. Route resolution fills in a `sa_path_rec`. Connect then hands off to a transport-specific CM. `ib_cm` exchanges REQ/REP/RTU MADs for InfiniBand and RoCE. `iw_cm` drives iWARP's MPA handshake over a real TCP connection, with port mapping helped by the `iwpmd` daemon over netlink. The CM moves the QP through INIT/RTR/RTS for you and reports progress as `enum rdma_cm_event_type` events (`ADDR_RESOLVED`, `ROUTE_RESOLVED`, `CONNECT_REQUEST`, `ESTABLISHED`, `DISCONNECTED`, `DEVICE_REMOVAL` ...). Userspace reaches it through `ucma` (`/dev/infiniband/rdma_cm`), which queues events for `rdma_get_cm_event()`. Nearly every kernel ULP (NVMe-oF, NFS/RDMA, iSER, RTRS, SMC-R does its own thing) uses it.

**Key struct**: `struct rdma_cm_id` (`include/rdma/rdma_cm.h`) — `device`, `qp`, `route` (`rdma_addr` + path records), `ps` (port space: TCP/UDP/IB), `event_handler`.

**Key functions**: `rdma_create_id()`, `rdma_resolve_addr()`, `rdma_resolve_route()`, `rdma_connect()`, `rdma_listen()`, `rdma_accept()`, `rdma_disconnect()` (`cma.c`)

**Config & flags**: `CONFIG_INFINIBAND_ADDR_TRANS`; configfs `/sys/kernel/config/rdma_cm/<dev>/ports/N/default_roce_mode` (RoCE v1 vs v2) and `default_roce_tos`.

---

### [[mad-and-subnet-administration]]

**Purpose**: An InfiniBand fabric is managed in-band by **Management Datagrams (MADs)** on special QPs (QP0 for subnet management, QP1 for general services). The kernel must multiplex these QPs among many agents: the CM, SA queries, userspace subnet managers like OpenSM, and diagnostics.

**How it works**: `mad.c` owns QP0 and QP1 per port. Agents register with `ib_register_mad_agent()` for a management class/version and get MADs routed by class plus transaction ID, with timeouts, retries and RMPP segmentation for large payloads (`mad_rmpp.c`). `sa_query.c` is the Subnet Administration client: it asks the subnet manager for path records and multicast membership. `user_mad.c` exposes `/dev/infiniband/umadN` (and `issmN` for the SM lock) to userspace. On RoCE there is no SM and no QP0, but QP1 still carries CM MADs encapsulated in UDP (v2) or Ethernet (v1).

**Key struct**: `struct ib_mad_agent`, `struct ib_mad_send_buf` (`include/rdma/ib_mad.h`)

**Key functions**: `ib_register_mad_agent()`, `ib_post_send_mad()`, `ib_sa_path_rec_get()`

**Config & flags**: `CONFIG_INFINIBAND_USER_MAD`; module params `send_queue_size`/`recv_queue_size` of `ib_core`.

---

### [[roce-gid-table-and-netdev-binding]]

**Purpose**: On Ethernet (RoCE), an RDMA "address" (GID) is derived from the netdev's IP and MAC addresses and VLAN. The GID table must track every IP address change, bond failover and VLAN creation, or connections are sourced from stale addresses.

**How it works**: `roce_gid_mgmt.c` registers netdevice and inetaddr/inet6addr notifiers. When an address appears on a netdev that is bound to an RDMA port (or on its upper devices: VLAN, bond, macvlan), it adds GID entries for each RoCE type (v1 = raw Ethernet, v2 = UDP/IP) to the port's GID cache (`cache.c`). Entries carry a `struct ib_gid_attr` that references the `net_device`. The CM and address-handle creation choose a source GID with `rdma_find_gid_by_port()` and `rdma_read_gid_attr_ndev_rcu()`, so the right VLAN, netns and bond slave are used. Hardware LAG (`lag.c`) lets a bond of two ports appear as one RDMA device.

**Key struct**: `struct ib_gid_attr` (`include/rdma/ib_verbs.h`) — `gid`, `gid_type`, `ndev`, `index`, `port_num`.

**Key functions**: `roce_gid_mgmt_init()`, `ib_cache_gid_add()`, `rdma_query_gid()`, `rdma_get_gid_attr()`

**Config & flags**: sysfs `/sys/class/infiniband/<dev>/ports/N/gid_attrs/{types,ndevs}/`; configfs default RoCE mode.

---

### [[rdma-rw-api]]

**Purpose**: Storage ULP targets (NVMe-oF target, iSER target, SRP target, NFS server) all do the same dance: take a host's `{addr, rkey, len}` descriptor, register or map local pages, and issue RDMA READ or WRITE, respecting device SGE limits and iWARP's rule that READ sinks must be registered. `rdma_rw` does this once, correctly.

**How it works**: `rdma_rw_ctx_init()` takes a local scatterlist (or bvecs) and a remote address/rkey. It picks a strategy: a single SGE, multiple SGEs split across chained WRs, an IOVA-contiguous mapping built with the new DMA IOVA API, or MR registration (forced on iWARP and whenever `force_mr` is set, e.g. for T10-PI signature offload). `rdma_rw_ctx_post()` posts the chain with one completion at the end. `rdma_rw_ctx_destroy()` unmaps and returns MRs to the QP's pool.

**Key struct**: `struct rdma_rw_ctx` (`include/rdma/rw.h`) — tagged union over `single`, `map`, `iova` and `reg` strategies.

**Key functions**: `rdma_rw_ctx_init()`, `rdma_rw_ctx_post()`, `rdma_rw_ctx_destroy()`, `rdma_rw_mr_factor()` (`rw.c`)

**Config & flags**: `rdma_rw` module parameter `force_mr` (debug).

---

### [[rdma-netlink-restrack-and-cgroup]]

**Purpose**: RDMA resources are hardware-limited and live outside the file tables that normal tools inspect. Admins need to see which process owns which QP, set per-cgroup limits, and read counters.

**How it works**: **restrack** (`restrack.c`, 4.17) adds every PD, CQ, QP, MR, CM ID and SRQ to a per-device xarray with its owning task. **nldev** (`nldev.c`) exposes restrack, device and port attributes, statistics and link creation over the `NETLINK_RDMA` family. The iproute2 `rdma` tool is the front end: `rdma resource show qp`, `rdma link add rxe0 type rxe netdev eth0`, `rdma statistic`. Per-QP and per-port hardware **counters** (`counters.c`) support auto-binding by QP type or PID. The **rdma cgroup** controller (4.11, Parav Pandit) charges `hca_handle` (user contexts) and `hca_object` (all verbs objects) per device, per cgroup, at uobject creation.

**Key struct**: `struct rdma_restrack_entry`, `struct rdmacg_device`

**Key functions**: `rdma_restrack_add()`, `rdma_restrack_del()`, `rdmacg_try_charge()`

**Config & flags**: `CONFIG_CGROUP_RDMA`; cgroup files `rdma.max`, `rdma.current`.

---

### [[soft-rdma-rxe-and-siw]]

**Purpose**: Software RDMA providers let any Ethernet NIC speak RoCE v2 (**rxe**, Soft-RoCE, 4.8) or iWARP (**siw**, soft-iWARP, 5.3). They are used for development, CI, interoperability with hardware peers, and hosts where only one side has an RDMA NIC.

**How it works**: Both register an `ib_device` whose `ops` are implemented in software. rxe encapsulates IB transport headers in UDP port 4791, with requester, responder and completer tasks processing QPs and ICRC computed in software. siw runs the iWARP DDP/RDMAP/MPA layers over a kernel TCP socket. Userspace still uses the zero-syscall data path: the provider library writes WQEs to shared memory, but "ringing the doorbell" becomes a syscall (`post_send` via uverbs) because there is no hardware to notice. They are useful for correctness, not performance. rxe gained ODP support and siw is maintained by its original author, Bernard Metzler (IBM).

**Key struct**: `struct rxe_dev`, `struct rxe_qp`; `struct siw_device`, `struct siw_qp`

**Key functions**: `rxe_net_add()`, `rxe_requester()`, `rxe_responder()`; `siw_qp_sq_process()`, `siw_tcp_rx_data()`

**Config & flags**: `CONFIG_RDMA_RXE`, `CONFIG_RDMA_SIW`; created with `rdma link add <name> type rxe|siw netdev <ifname>`.

---

## How Components Interact

**Scenario 1 — a userspace RC connection with librdmacm, then one RDMA WRITE**

```mermaid
sequenceDiagram
    participant App
    participant ucma as ucma/rdma_cm
    participant uv as ib_uverbs
    participant umem as ib_umem
    participant drv as provider (mlx5)
    participant NIC
    App->>ucma: rdma_create_id, rdma_resolve_addr(IP)
    ucma->>ucma: route lookup, pick device+GID (GID table)
    App->>uv: ibv_alloc_pd, ibv_create_cq
    App->>uv: ibv_reg_mr(buf)
    uv->>umem: ib_umem_get: charge RLIMIT_MEMLOCK, pin_user_pages(FOLL_LONGTERM), DMA map
    umem->>drv: program MTT, return lkey/rkey
    App->>ucma: rdma_create_qp, rdma_connect
    ucma->>ucma: ib_cm REQ/REP/RTU over QP1 MADs; modify QP INIT→RTR→RTS
    Note over App,NIC: data path — no kernel
    App->>NIC: write WQE {RDMA_WRITE, lkey, remote addr+rkey} + MMIO doorbell
    NIC->>NIC: DMA from local MR, transmit, remote NIC DMAs into remote MR
    NIC->>App: CQE in CQ memory; app polls
```

The kernel took part in addressing, pinning, CM handshake and QP state changes, and not in the write itself. The remote host's CPU and kernel never see the write either. Only the remote application, if it polls the target buffer, knows data arrived.

**Scenario 2 — NVMe-oF target serves a host read.** The `nvmet_rdma` target receives the command capsule in a posted receive buffer (its CQ callback runs in softirq through `IB_POLL_SOFTIRQ`). It submits the block I/O, then calls `rdma_rw_ctx_init()` with the host's keyed SGL and posts an RDMA WRITE of the data followed by a SEND of the response. It uses the shared CQ pool and FRMR pools to avoid per-I/O allocation.

**Scenario 3 — memory migration under an ODP MR.** Compaction wants to move a page inside an ODP-registered range. The mmu interval notifier fires. mlx5 invalidates the NIC translation entries and waits for in-flight DMA. The page moves. The next NIC access faults, the driver calls `ib_umem_odp_map_dma_and_lock()` → `hmm_range_fault()`, maps the new page, and resumes the stalled QP.

## Where It Fits in the Kernel

- **↑ Userspace**: `/dev/infiniband/uverbsN` (ioctl/write + mmap), `/dev/infiniband/rdma_cm`, `/dev/infiniband/umadN`, `NETLINK_RDMA`, sysfs `/sys/class/infiniband/`. Libraries: rdma-core (libibverbs, librdmacm, providers), UCX, libfabric, NCCL, SPDK.
- **→ mm**: long-term pinning (`pin_user_pages`), `pinned_vm` accounting, mmu notifiers and HMM for ODP. See [[get-user-pages-and-pinning]].
- **→ DMA / IOMMU**: `ib_dma_*` wrappers over the [[dma-mapping-api]], the new DMA IOVA API in `rdma_rw`, and P2PDMA for device-to-device memory.
- **→ dma-buf**: RDMA both imports (register GPU memory as an MR) and, since 2026, exports (device memory and UAR pages) dma-bufs.
- **→ net**: RoCE/iWARP bind to `net_device`s. Netdev and inetaddr notifiers feed the GID table, and the CM uses IP routing and neighbour lookup. iWARP's CM uses real TCP.
- **← Storage and network ULPs**: NVMe-oF (host and target), NFS/RDMA (xprtrdma/svcrdma), SMB Direct (ksmbd/cifs), iSER, SRP, RTRS/RNBD, IPoIB, SMC-R.
- **← cgroups**: the rdma controller.
- **↓ Hardware**: PCIe RDMA NICs (mlx5, bnxt_re, irdma, hns, erdma, efa, mana, ionic ...), plus software providers over any netdev.

## Design Decisions & Tradeoffs

- **Kernel bypass for the data path, kernel ownership of the control path.** The data path skips syscalls, copies and interrupts (optionally). The price is that the kernel cannot see, schedule, account or filter traffic after setup. No netfilter, no qdisc, no per-packet cgroup. Security therefore rests entirely on memory keys and PD scoping enforced by hardware.
- **Pinning over paging.** The original model pins every registered page for the MR's lifetime. It is simple and fast, but it conflicts with reclaim, migration, CMA and DAX truncation. The mm side answered with `FOLL_LONGTERM` and `pin_user_pages()` (which migrates out of movable zones first). The RDMA side answered with ODP (which needs NIC fault support) and dma-buf dynamic attach.
- **write() → ioctl.** The fixed-struct write() ABI was simple, but insecure because of credential semantics, and not extensible. The attribute-based ioctl ABI with declarative method specs centralizes validation and lets drivers add methods (mlx5 DevX exposes almost the raw device command interface) without growing core code.
- **One verbs API over three transports.** IB, RoCE and iWARP share `ib_device_ops`. Transport differences leak through `rdma_protocol_*()` / `rdma_cap_*()` helpers (iWARP needs registered READ sinks and a TCP-based CM; RoCE has no SM). `rdma_cm` hides most of this behind IP addressing.
- **Hot-unplug by disassociation.** Rather than blocking device removal until every process exits, uverbs revokes hardware and leaves userspace with dead but valid handles. That is safer for servers, but it forces every uverbs path to handle "device gone" at any point.

## How It Has Evolved

- **2.6.11 (2005)** — InfiniBand core, mthca, IPoIB and the uverbs write() ABI merged (OpenIB/OFA stack).
- **2.6.x** — RDMA CM (2006), iWARP CM, and the stack renamed "RDMA" in concept while keeping `infiniband` paths.
- **3.19 (2014)** — On-Demand Paging for mlx5.
- **4.5–4.9** — RoCE v2 GID types, the `rdma_rw` API (4.7), rxe Soft-RoCE (4.8).
- **4.11** — rdma cgroup controller.
- **4.14–4.20** — the ioctl uverbs ABI, then all write() commands tunneled through it; mlx5 DevX.
- **4.16–4.17** — rdma netlink (nldev) and restrack; the iproute2 `rdma` tool.
- **5.3** — siw soft-iWARP.
- **5.9** — shared CQ pool.
- **5.12** — dma-buf import for MRs (Jianxin Xiong, Intel), initially limited to ODP-capable NICs for dynamic attach; pinned dma-buf attach followed for NICs without ODP.
- **6.x** — ODP for rxe; new providers (Microsoft mana, AMD Pensando ionic 2025, Alibaba erdma), DMA IOVA API adoption in `rdma_rw`, FRMR pools.
- **2026** — dma-buf **export** from RDMA devices (Edward Srouji, NVIDIA), revocable pinned dma-buf import, unified `ib_uverbs_buffer_desc` so any umem-taking verb can accept a VA or a dma-buf fd, and the hfi1 → hfi2 migration (Cornelis).

## Recent Development Activity

- **dma-buf in both directions**: export of device memory (mlx5 first), revocable pinned import (`pinned_revoke` callback in `ib_umem_dmabuf`), and erdma adding dma-buf MRs. The theme is GPU ↔ NIC zero-copy for AI clusters. The same pressure produced [[devmem-tcp]] and io_uring zcrx on the socket side.
- **uverbs ABI hygiene**: udata helpers and documented uABI compatibility rules (2026), buffer descriptors, and completion counters (`comp_cntrs`) as an alternative to CQEs for high-rate one-sided traffic.
- **Confidential computing**: `cc_dma_bounce` for CoCo guests that require bounce buffering.
- **Ultra Ethernet / new transports**: vendor QP types (EFA SRD, mlx5 DC) and upcoming UEC transport discussions keep testing how well verbs covers transports that aren't InfiniBand.

## Further Reading

1. LWN — [RDMA: Add dma-buf support](https://lwn.net/Articles/836484/) (2020)
2. LWN — [RDMA: Add support for exporting dma-buf file descriptors](https://lwn.net/Articles/1056826/) (2026)
3. LWN — [IB/core: SG IOCTL based RDMA ABI](https://lwn.net/Articles/733179/) (2017)
4. LWN — [rdma controller support](https://lwn.net/Articles/674161/) (2016)
5. LWN — [On-Demand Paging on SoftRoCE](https://lwn.net/Articles/914607/)
6. kernel.org — [InfiniBand documentation](https://www.kernel.org/doc/html/latest/infiniband/index.html), especially *Userspace verbs access* and *Midlayer locking*
7. rdma-core — https://github.com/linux-rdma/rdma-core (userspace half of the ABI, with provider libraries)
8. Related vault notes: [[io_uring]], [[get-user-pages-and-pinning]], [[dma-mapping-api]], [[devmem-tcp]], [[af-xdp]]

## LKML Highlights

- **`<1501765627-104860-1-git-send-email-matanb@mellanox.com>`** — Matan Barak's "SG IOCTL based RDMA ABI". It introduced the object/method/attribute tree that replaced per-command write() structs and moved uobject locking and lifetime into the core.
- **`<1604616489-69267-1-git-send-email-jianxin.xiong@intel.com>`** — dma-buf support for RDMA MRs. The debate settled on *dynamic* attach, where the exporter can move memory and the NIC must handle invalidation like ODP, instead of pinning GPU VRAM.
- **`<20260201-dmabuf-export-v3-0-da238b614fe3@nvidia.com>`** — RDMA devices become dma-buf *exporters*. v3 added waiting for importers after `dma_buf_move_notify()` revocation and paired pin/unpin, the lifetime details that make revocation safe.
- **`<1454154087-27375-1-git-send-email-pandit.parav@gmail.com>`** — the rdma cgroup. The key design choice was that the RDMA stack, not the cgroup core, defines the resource types.
