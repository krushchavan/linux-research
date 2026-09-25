---
title: "Cpuset Controller — Explained"
category: explained
original: "[[cpuset-controller]]"
subsystem: cgroups
tags: [explained, cgroups, cpuset, numa, cpu-isolation]
converted: 2026-09-25
---

# The cpuset controller, explained

> Plain-language companion to [[cpuset-controller|the technical note]]. Same facts, fewer identifiers.

## The problem

On large multi-socket servers, memory is split into NUMA nodes, each close to some CPUs and far from others; reaching remote memory can be 2 to 3 times slower than local memory. A workload that wanders across sockets, or whose memory ends up on a far node, runs noticeably slower. Real-time and HPC jobs have a stricter need: CPUs of their own, with no unrelated task ever scheduled there to cause jitter.

Operators need to confine a group of processes to particular CPUs and memory nodes, safely delegable (a child group mustn't grab CPUs its parent doesn't have), and sometimes to carve CPUs out completely.

## The idea in one paragraph

Picture an office building with several floors (NUMA nodes), each with its own lifts (CPUs) and supply room (memory). The cpuset controller assigns a company (a cgroup) to certain floors; its staff (tasks) may only use those floors' lifts and supplies. A department can even get a floor **entirely to itself**, with no one else's post passing through: that's a **partition**. Throughout, a group can only ever use what its parent has.

## Step by step

### Step 1: Requested versus effective
Each group records the CPUs and memory nodes it **asked for**. What its tasks actually get is the **effective** set: the request intersected with the parent's effective set. So any group can write any request, but it can never gain a CPU or node its parent lacks. That's what makes delegation safe without special permissions.

### Step 2: Applying a change to CPUs
When the CPU list is written, the controller validates it, computes the new effective set, then goes through every task in the group and updates its allowed CPUs. The scheduler confines each task to them from its next scheduling decision.

### Step 3: Applying a change to memory nodes
Changing the memory nodes can, if memory migration is enabled, move the processes' pages onto the new nodes. It also interacts with per-process NUMA policies: a policy naming nodes outside the new set is rebound to the overlap, and if a task's preferred node disappears, allocations fall back to any allowed node.

### Step 4: Changes cascade down
Changing one group's sets recomputes the effective sets of all its descendants, level by level, and applies them to their tasks, so every descendant's effective set stays within its ancestors'. CPU hotplug uses the same path: when a CPU goes offline, all effective sets are recomputed and tasks are moved off it.

### Step 5: Partitions
This is the key step for isolation. Setting a group's partition mode to **root** doesn't just restrict its tasks; it **removes** its CPUs from the parent's scheduling domain altogether, and the scheduler rebuilds its domains so those CPUs form their own isolated domain. No task outside the partition, not even the parent's own, can run there. The partition must own at least one CPU from the parent's effective set. **Isolated** mode (5.17) goes further, stopping load balancing across the boundary. The default, **member**, shares the parent's domain normally.

Most kernel resource controls share; this one deliberately grants exclusive ownership, because for real-time work even occasional intrusions onto "your" CPU cause unacceptable jitter. It suits co-location, such as a latency-sensitive database that must never share CPUs with batch jobs.

## The picture

```text
 root              effective CPUs 0-15, nodes 0-1
 ├─ db   asks 4-7  → effective 4-7   partition=root → 4-7 removed from root's domain
 └─ web  asks 0-9  → effective 0-3,8-9 (can't have 4-7: now owned by db)

 write cpus → validate → effective = request ∩ parent → update every task → cascade down
 CPU goes offline → recompute all effective sets → move tasks off it
```

## Tradeoffs

- **What it gives you:** NUMA-local placement, safe delegation through intersection, and truly exclusive CPUs for latency-critical work.
- **What it costs / requires:** partitions take CPUs away from everyone else, and changing memory nodes can mean migrating lots of pages.
- **Where it bites:** because the effective set is an intersection, a group can end up with far fewer CPUs than it asked for without any error; check the effective files, not the requests. Cpusets are older than cgroups, which is why they have more knobs (spreading, migration, partitions) than newer controllers.

## How it got here

- **2.6.0 (2003):** the original cpuset filesystem, for NUMA HPC at SGI.
- **2.6.24 (2008):** reimplemented as a cgroup controller when cgroups arrived.
- **5.0 (2019):** partitions in cgroup v2, for CPU isolation domains.
- **5.17 (2022):** isolated partitions, with no load balancing across the boundary.

## Related

- Technical version: [[cpuset-controller]]
- [[cgroups-explained|cgroups]], [[cgroup-core-explained|cgroup core]], [[cpu-cgroups|CPU cgroups]]
- [[numa-memory-policy-explained|NUMA memory policy]], [[scheduler-explained|Scheduler]]
