---
title: "RDMA Netlink, Resource Tracking, Counters and the rdma cgroup"
category: concept
tags: [rdma, netlink, restrack, cgroup, observability, iproute2]
subsystem: rdma
kernel_version: "4.11 (rdma cgroup); 4.16–4.17 (nldev, restrack); 5.3 (counters)"
researched: 2026-09-26
status: complete
explained: "[[rdma-netlink-restrack-and-cgroup-explained]]"
sources:
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/nldev.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/restrack.c
  - https://github.com/torvalds/linux/blob/master/include/rdma/restrack.h
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/counters.c
  - https://github.com/torvalds/linux/blob/master/include/uapi/rdma/rdma_netlink.h
  - https://github.com/torvalds/linux/blob/master/kernel/cgroup/rdma.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/cgroup.c
  - https://lwn.net/Articles/674161/
  - https://lwn.net/Articles/677833/
---

# RDMA Netlink, Resource Tracking, Counters and the rdma cgroup

> 📘 Plain-language version: [[rdma-netlink-restrack-and-cgroup-explained]]

## Purpose

RDMA resources (QPs, CQs, MRs, PDs, CM IDs) are **scarce hardware objects** that live outside anything normal Linux tooling can see. They don't show up in `/proc/<pid>/fd`, `ss` or `lsof` beyond one opaque `/dev/infiniband/uverbs0` descriptor, and a single process can exhaust an adapter's QP or MR capacity for everyone. This component group gives administrators the equivalent of `ss`, `ip link` and cgroup limits for RDMA:
- **restrack** — records every hardware object with its owner
- **nldev** — the `NETLINK_RDMA` API behind the iproute2 `rdma` tool
- **counters** — per-port and per-QP hardware statistics with flexible binding
- **the rdma cgroup controller** — hierarchical per-device limits on how many handles and objects a group of processes may create

## Mental Model

Think of the NIC as a **shared parking garage**. **restrack** is the ticket log: every car (QP, MR ...) is logged with which driver (task and PID) parked it and whether it is a kernel or user car. **nldev** is the attendant's window where you ask "show me all cars on level mlx5_0" or "open a new level" (create an rxe link). **Counters** are meters you can attach per level, or per group of cars (all cars from PID 1234). The **rdma cgroup** is the reservation system: tenant group "batch-jobs" may hold at most N tickets on garage mlx5_0, and when it's full, `ibv_create_qp()` fails with `EAGAIN` for that group only.

## How It Works

**Resource tracking (restrack).** Every core object embeds a `struct rdma_restrack_entry res` (`ib_pd.res`, `ib_cq.res`, `ib_qp.res`, `ib_mr.res` ...). At creation the core calls `rdma_restrack_new(&obj->res, TYPE)`, sets the owner (`rdma_restrack_set_name()` records either the current task, for user objects, or a `kern_name` such as `"nvme-rdma"` for kernel ones), and after the driver succeeds, `rdma_restrack_add()`. That inserts the entry into the per-device, per-type xarray in `ib_device.res` and assigns the stable `id` that tools print (e.g. `pdn 3`, `cqn 17`). Userspace QPs use the QP number as the ID. Lookups for netlink hold the object with `rdma_restrack_get()` (a kref), so a dump can't race with destruction. `rdma_restrack_del()` waits on `comp` until all such readers drop it. Objects that must not be visible (internal driver QPs) use `rdma_restrack_no_track()`. Because entries record the `task_struct`, dumps can show `pid`/`comm` and filter by PID namespace, so a container only sees its own resources.

**The netlink family (nldev).** `NETLINK_RDMA` is a dedicated netlink protocol with sub-clients (`RDMA_NL_LS` for SA path offload, `RDMA_NL_IWCM` for iWARP port mapping, and **`RDMA_NL_NLDEV`** for device management). `nldev.c` implements the command table:
- **Devices and ports**: `RDMA_NLDEV_CMD_GET` / `SET` (rename, move to netns, set `dim`/adaptive moderation, privileged QKey), `PORT_GET`, `GET_CHARDEV` (tells rdma-core which `/dev/infiniband/*` node belongs to a device, instead of scanning sysfs), `SYS_GET` / `SYS_SET` (netns shared vs exclusive mode, privileged QKey, monitoring).
- **Links**: `NEWLINK` / `DELLINK` create and destroy software devices (`rdma link add rxe0 type rxe netdev eth0` → `rdma_link_ops` of rxe or siw). `NEWDEV` / `DELDEV` create sub-devices.
- **Resources**: `RES_GET` (per-type counts) and `RES_{QP,CM_ID,CQ,MR,PD,CTX,SRQ}_GET` dumps (QP state, type, PSNs, owning PID; MR lkey/rkey/length for privileged users; CM ID addresses). The `_GET_RAW` variants return raw driver contexts (firmware QP/CQ/MR dumps) for vendor debugging.
- **Statistics**: `STAT_SET` / `STAT_GET` / `STAT_DEL` / `STAT_GET_STATUS` for counters; optional counters can be enabled per port.
- **FRMR pools** (2026): `FRMR_POOLS_GET` / `SET` to inspect and tune fast-registration pools.

Privileged fields (keys, raw dumps) require `CAP_NET_ADMIN` in the device's netns. Device registration, unregistration and renames emit notifications (`rdma_nl_notify_event`), so `rdma monitor` can watch hotplug.

**Counters.** Port-level hardware stats (`hw_counters`: packets, bytes, congestion events such as `np_cnp_sent` and `rp_cnp_handled`, out-of-sequence, retransmits) come from the driver's `alloc_hw_port_stats` / `get_hw_stats` ops and appear in sysfs and `rdma statistic show`. **QP-bound counters** (5.3, Mark Zhang) are hardware counter sets that can be bound to groups of QPs:
- *auto mode* binds every new QP matching a mask (`RDMA_COUNTER_MASK_QP_TYPE`, `RDMA_COUNTER_MASK_PID`) to a shared counter, e.g. one counter per process
- *manual mode* binds specific QP numbers (`rdma statistic qp bind`).

This lets operators attribute retransmits or CNPs to a specific job without per-QP instrumentation. Optional counters (6.x) allow enabling expensive counters only when needed.

**The rdma cgroup controller.** The controller (`kernel/cgroup/rdma.c`, 4.11, Parav Pandit) is deliberately generic. It doesn't know what a QP is. Each `ib_device` registers an `rdmacg_device` at registration (`ib_device_register_rdmacg`). Two resource types are defined by the RDMA stack:
- `hca_handle` — number of user contexts (open `ib_ucontext`s): charged in `ib_uverbs_get_context()`
- `hca_object` — number of *all* verbs objects: charged in `alloc_uobj()` (`rdma_core.c`) for every uobject.

`rdmacg_try_charge()` walks from the task's cgroup to the root, charging a per-cgroup, per-device resource pool (`rdmacg_resource_pool`) at each level. If any level would exceed its limit it unwinds and returns `-EAGAIN`, and records `events_max` or `events_alloc_fail` for the `rdma.events` file. Limits are set per device in `rdma.max`: `echo "mlx5_0 hca_handle=2 hca_object=2000" > rdma.max`. Usage is visible in `rdma.current`. Uncharge happens when the uobject is destroyed. The charge stays with the cgroup that allocated it even if the task later migrates, so the original cgroup is credited when the object dies. Kernel objects (ULPs) are never charged.

## Key Data Structures

**`struct rdma_restrack_entry`** (`include/rdma/restrack.h`)
- `valid` — added to the DB and not yet deleted
- `no_track` — hidden from the DB
- `kref`, `comp` — reader references and deletion wait
- `task` / `kern_name` — owner
- `type` — PD, CQ, QP, CM_ID, MR, CTX, COUNTER, SRQ
- `user` — user vs kernel resource
- `id` — stable ID exposed to tools

**`struct rdma_restrack_root`** (`restrack.h` internal) — per-device, per-type xarray.

**`struct rdma_counter`** (`include/rdma/rdma_counter.h`) — a bound counter: `mode` (NONE/AUTO/MANUAL), mask, `stats`, list of QPs.

**`struct rdma_cgroup` / `struct rdmacg_device` / `struct rdmacg_resource_pool`** (`include/linux/cgroup_rdma.h`, `kernel/cgroup/rdma.c`) — per-cgroup pools keyed by device, with `max`, `usage`, and event counters per resource type.

## Key Functions / Entry Points

- **`rdma_restrack_new()` / `rdma_restrack_add()` / `rdma_restrack_del()` / `rdma_restrack_get()` / `rdma_restrack_put()`** (`restrack.c`)
- **`nldev_get_doit()`, `nldev_res_get_*_dumpit()`, `nldev_newlink()`, `nldev_stat_set_doit()`** (`nldev.c`)
- **`rdma_nl_register()`** (`netlink.c`) — sub-client registration on `NETLINK_RDMA`
- **`rdma_counter_bind_qp_auto()` / `rdma_counter_bind_qpn()`** (`counters.c`)
- **`ib_rdmacg_try_charge()` / `ib_rdmacg_uncharge()`** (`drivers/infiniband/core/cgroup.c`) → **`rdmacg_try_charge()`** (`kernel/cgroup/rdma.c`)

## Important Flags & Config Options

- `CONFIG_CGROUP_RDMA`
- cgroup files: `rdma.max`, `rdma.current`, `rdma.events` (v2)
- iproute2 `rdma` commands: `rdma dev`, `rdma link add|del`, `rdma resource show [qp|cq|mr|pd|cm_id|ctx|srq]`, `rdma statistic [qp] [bind|unbind|mode]`, `rdma system set netns`, `rdma monitor`
- `CAP_NET_ADMIN` — needed for keys, raw resource dumps, link creation

## Interactions with Other Subsystems

- **↑ Userspace**: iproute2 `rdma`, rdma-core (`GET_CHARDEV`), orchestration (Kubernetes RDMA device plugins set `rdma.max` per pod)
- **→ cgroup core**: rdma controller callbacks, hierarchy walk, v1 and v2 interfaces
- **→ netlink**: `NETLINK_RDMA` protocol family, per-netns sockets
- **→ PID namespaces**: restrack filters by the reader's PID namespace
- **← uverbs**: every uobject creation charges cgroup and adds restrack ([[verbs-api-and-uverbs]])
- **← device model**: registration creates the cgroup device and the restrack root ([[ib-device-and-client-model]])

## Design Decisions & Tradeoffs

- **Generic controller, stack-defined resources.** From Parav Pandit's cover letter: the RDMA stack, not the cgroup, defines resources, so the controller stays stable as verbs evolve. The rejected alternative was one cgroup knob per verb type (QP, CQ, MR, AH ...). The final design is coarse: two counters, with `hca_object` covering every object type equally, which trades precision for simplicity. A cgroup can't limit MR *bytes* (that is `RLIMIT_MEMLOCK`) or QPs specifically.
- **Charge at uobject allocation.** Uniform and race-free because it sits in the generic uverbs object path, but kernel ULP objects are unaccounted.
- **Netlink over sysfs for resources.** Dumps of tens of thousands of QPs with filtering and PID attribution don't fit sysfs. nldev follows the `ip`/`devlink` model.
- **Restrack with owner task pointers.** This enables PID and namespace filtering, at the cost of holding task references and the complexity of per-object krefs and completions.

## How It Has Evolved

- **4.11 (2017)** — rdma cgroup controller
- **4.16** — `NETLINK_RDMA` nldev device and port queries; iproute2 `rdma` tool
- **4.17** — restrack and resource dumps (Leon Romanovsky)
- **5.1–5.3** — `rdma link add` for rxe/siw via netlink; device rename; netns commands; `GET_CHARDEV`
- **5.3** — QP counters with auto and manual binding (Mark Zhang)
- **5.9–6.x** — raw resource dumps (`_GET_RAW`), SRQ tracking, optional counters, `rdma monitor` events, sub-devices
- **2026** — FRMR pool netlink controls; `rdma.events` failure accounting

## Further Reading

- LWN — [rdma controller support](https://lwn.net/Articles/674161/) and [rdmacg: IB/core: rdma controller support](https://lwn.net/Articles/677833/)
- `man rdma`, `man rdma-resource`, `man rdma-statistic`, `man rdma-link` (iproute2)
- kernel.org — cgroup v2 docs, "RDMA" controller section (Documentation/admin-guide/cgroup-v2.rst)
- Related: [[rdma]], [[verbs-api-and-uverbs]], [[ib-device-and-client-model]]

## LKML Highlights

- **`<1454154087-27375-1-git-send-email-pandit.parav@gmail.com>`** — rdma cgroup v5 (Parav Pandit). Tejun Heo pushed back on per-verb resource knobs, which is why the final controller exposes only `hca_handle` and `hca_object`.
- **"RDMA resource tracking" (Leon Romanovsky, 2018, 4.17)** — introduced restrack and nldev resource dumps so `rdma resource show` could attribute QPs to PIDs, a long-standing operational gap.
- **"RDMA: Statistic counter support" (Mark Zhang, 2019, 5.3)** — per-QP hardware counters with auto-binding by QP type or PID. (Message-ids for the last two unavailable: lore was unreachable this session.)
