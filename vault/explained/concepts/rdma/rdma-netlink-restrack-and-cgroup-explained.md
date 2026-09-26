---
title: "RDMA Netlink, Resource Tracking, Counters and the rdma cgroup — Explained"
category: explained
original: "[[rdma-netlink-restrack-and-cgroup]]"
subsystem: rdma
tags: [explained, rdma, netlink, cgroup, observability]
converted: 2026-09-26
---

# RDMA visibility and limits, explained

> Plain-language companion to [[rdma-netlink-restrack-and-cgroup|the technical note]]. Same facts, fewer identifiers.

## The problem

RDMA resources (queue pairs, completion queues, memory regions, protection domains, connection IDs) are **scarce hardware objects** that ordinary Linux tools can't see: a process shows only one opaque open file for the RDMA device, and a single process can use up an adapter's capacity for everyone. Administrators need the RDMA equivalents of `ss`, `ip link` and cgroup limits.

## The idea in one paragraph

Think of the card as a **shared parking garage**. **Resource tracking** is the ticket log: every car (queue pair, memory region…) is logged with who parked it and whether it's a kernel or user car. **The netlink interface** is the attendant's window: "show me all cars on level mlx5_0", or "open a new level" (create a software RDMA link). **Counters** are meters you attach per level, or per group of cars (everything from one process). The **rdma cgroup** is the reservation system: the tenant group "batch-jobs" may hold at most N tickets on this garage, and when it's full, creating another object fails for that group only.

## Step by step

### Step 1: Log every object
Each core object embeds a tracking entry. At creation the core records its owner, the current task for user objects or a name like "nvme-rdma" for kernel ones, and after the driver succeeds, adds it to a per-device, per-type table with a stable ID that tools print (user queue pairs use their queue number). Readers take a reference so a listing can't race with destruction, and deletion waits for readers to finish. Internal driver objects can be hidden. Because entries record the task, listings show process ID and name and filter by PID namespace, so a container only sees its own resources.

### Step 2: The netlink window
A dedicated netlink family has several sub-users (path-query offload, iWARP port mapping, and device management). Device management covers:
- **devices and ports:** query, rename, move to a namespace, adaptive interrupt moderation, which device file belongs to which device (so libraries don't scan sysfs), and system-wide settings such as shared or exclusive namespace mode
- **links:** create and delete software devices, like `rdma link add rxe0 type rxe netdev eth0`, and sub-devices
- **resources:** per-type counts and detailed listings of queue pairs, connection IDs, completion queues, memory regions, protection domains, contexts and shared receive queues, with raw firmware dumps for vendor debugging
- **statistics:** set, get and remove counters
- **fast-registration pools** (2026): inspect and tune

Sensitive fields (keys, raw dumps) need network-admin capability in the device's namespace. Registration, removal and renames produce notifications, so `rdma monitor` can watch hotplug.

### Step 3: Counters
Port-level hardware statistics (packets, bytes, congestion notifications sent and handled, out-of-sequence packets, retransmits) appear in sysfs and `rdma statistic`. **Queue-pair-bound counters** (5.3, Mark Zhang) attach a hardware counter set to a group of queue pairs, either **automatically** (every new queue pair of a given type, or from a given process, joins a shared counter) or **manually** by queue number. Operators can then pin retransmits or congestion events on a particular job without instrumenting it. Expensive counters can be turned on only when needed.

### Step 4: Limits with the rdma cgroup
This is the key step for multi-tenant hosts. The controller (4.11, Parav Pandit) deliberately knows nothing about queue pairs; the RDMA stack defines just two resources per device:
- **handles:** open user contexts
- **objects:** *all* verbs objects together

Every user object creation **charges** the task's cgroup and each of its ancestors for that device. If any level would exceed its limit, the charge unwinds and creation fails with "try again", and the failure is counted for the events file. Limits are set per device (e.g. `mlx5_0 hca_handle=2 hca_object=2000`) and usage is visible. The charge stays with the cgroup that made the object, even if the task moves, and is returned when the object is destroyed. Kernel objects are never charged. Kubernetes RDMA device plugins set these limits per pod.

## The picture

```text
 create QP (user) ─▶ cgroup charge: pod → parent → root (mlx5_0: objects 1999/2000 ✓)
                 ─▶ driver creates → tracking entry {type QP, id 0x1a4, pid 4321, "trainer"}
 `rdma resource show qp`  ─netlink─▶ listing, filtered by caller's PID namespace
 `rdma statistic qp mode auto` ─▶ one counter per process: retransmits, CNPs…
 `rdma link add rxe0 type rxe netdev eth0` ─▶ software device appears
```

## Tradeoffs

- **What it gives you:** `ss`-style visibility into RDMA objects with process attribution, container-safe filtering, per-job hardware statistics, and per-device limits per cgroup.
- **What it costs / requires:** the cgroup is coarse: two counters, with every object type counting the same. It can't limit memory-region *bytes* (that's the locked-memory limit) or queue pairs specifically, and kernel users aren't accounted. Tracking holds task references and per-object reference counts.
- **Where it bites:** that coarseness was a deliberate choice. Tejun Heo pushed back on one knob per verb type, so the stack, not the cgroup core, defines resources and the controller stays stable as verbs evolve. Netlink was chosen over sysfs because listings of tens of thousands of queue pairs with filtering don't fit sysfs.

## How it got here

- **4.11 (2017):** the rdma cgroup controller.
- **4.16:** the netlink device and port interface and the `rdma` tool. **4.17:** resource tracking and listings (Leon Romanovsky).
- **5.1–5.3:** software link creation, renaming, namespace commands, device-file lookup; queue-pair counters (Mark Zhang).
- **5.9–6.x:** raw dumps, shared receive queue tracking, optional counters, monitoring events, sub-devices.
- **2026:** fast-registration pool controls and failure accounting.

## Related

- Technical version: [[rdma-netlink-restrack-and-cgroup]]
- [[rdma-explained|RDMA subsystem]], [[verbs-api-and-uverbs-explained|Verbs and uverbs]], [[ib-device-and-client-model-explained|Device and client model]], [[soft-rdma-rxe-and-siw-explained|rxe and siw]]
- [[cgroups-explained|cgroups]]
