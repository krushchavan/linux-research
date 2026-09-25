---
title: "Control Groups (cgroups) — Explained"
category: explained
original: "[[cgroups]]"
subsystem: cgroups
tags: [explained, cgroups, containers, resource-control]
converted: 2026-09-25
---

# Control groups (cgroups), explained

> Plain-language companion to [[cgroups|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

On a shared machine, one runaway program can eat all the memory, hog the CPUs, saturate the disk or fork itself into oblivion, and everyone else suffers. Operators need to group processes (a container, a service, a batch job) and say "this group gets at most this much memory, this share of CPU, this much disk bandwidth, this many processes", then see how much each group actually used.

It has to be hierarchical, so a container can subdivide its own allowance; enforced by the kernel in the hot paths (every page allocation, every scheduling decision, every I/O, every fork); and cheap enough that it doesn't slow those paths down. Together with namespaces, this is the kernel foundation of Linux containers.

## The big picture

Think of cgroups as **a tree of folders**. Each folder is a cgroup; putting a process in a folder places it under that folder's rules. A parent bounds what its children can have (a child can only hand out what its parent was given), and every rule of every ancestor applies to the processes below.

```text
 systemd / container runtime
          │ mkdir, write files under /sys/fs/cgroup
   cgroup filesystem (kernfs)
          │
   cgroup core: the tree, membership, which controllers are on where
          │
   shared per-task bundle of controller state
     ├─ memory   ├─ CPU     ├─ I/O      ├─ PIDs
     ├─ cpuset   ├─ freezer └─ BPF programs hooked to cgroups
```

There are two layers: a **core** that manages the tree and who belongs where, and **controllers**, one per resource, that do the accounting and enforcement. Controllers are told, through callbacks, when cgroups are created or removed and when tasks fork or move.

## The pieces

### The core
Each cgroup is a node in the tree and a directory under `/sys/fs/cgroup`. Creating a directory creates a cgroup and asks each enabled controller to set up its per-group state. Writing a process ID to a group's process list moves the process there.

cgroup v2 enforces the **no-internal-process rule**: a group that hands controllers down to its children can't also hold processes directly, so a parent's own tasks never compete unfairly against its child groups. Controllers are switched on for a group's children by writing to a control file; the change propagates down the subtree, setting up or tearing down per-group state. See [[cgroup-core-explained|the cgroup core]].

### Shared state bundles
This is the key efficiency trick. Rather than giving every task its own pointer to each controller's state, all tasks that sit in exactly the same combination of groups **share one bundle** of pointers. Moving a task looks up a bundle for the new combination in a hash table, creating one only if none exists; reference counts free bundles when unused.

Forking is then cheap: the child just takes a reference to its parent's bundle. Storing per-controller pointers in every task would bloat each task and make fork slower as more controllers are compiled in. Links in both directions let the core list every task in a group, and let controllers find every group a bundle touches. See [[css-set-and-subsystem-state|shared state bundles]].

### Memory
Every page of memory is charged to the group that allocated it. Four tiers shape reclaim:
- **min:** hard protection; pages up to this level are never reclaimed
- **low:** soft protection; reclaimed only when unprotected memory runs out
- **high:** throttle; tasks over it are made to sleep briefly so reclaim can catch up, with no OOM kill
- **max:** hard limit; exceed it, direct reclaim runs, and if that fails the OOM killer picks a victim *within the group*

Charges are dropped when pages are freed, and handed to the parent when a group is removed. Dirty-page ownership is tracked so writeback is charged to the right group even if the writer has moved. See [[memcg-explained|memory cgroups]].

### CPU
Each group becomes a scheduling entity that competes with its siblings, with its tasks competing inside it: a tree of fair shares.
- **Weights** (1 to 10,000, default 100) split CPU in proportion when CPUs are busy. It's work-conserving: an idle group's share goes to others.
- **Bandwidth limits** give a group a quota of run time per period (default 100 ms). When the quota is used up, the group is **throttled**, taken off the run queues entirely, until a timer refills it at the period's end. CPUs draw run time from the group's pool in 5 ms slices to limit lock contention. Limits nest: a child gets at most what its parent has left.

See [[cpu-cgroups|CPU cgroups]].

### I/O
Each group has per-device state in the block layer:
- **max** limits bytes and operations per second per direction with token buckets; I/O over the limit waits on a queue until tokens refill
- **weight** uses a cost model that estimates each I/O's device time and shares device time in proportion, with a virtual-time scheduler much like the CPU's
- **latency** protects a group: if its latency rises above target, *others* get less

Writeback is jointly managed with the memory controller, so dirty pages are written back under the budget of the group that dirtied them. See [[io-controller|the I/O controller]].

### PIDs
A counter per group caps the number of tasks, mainly to stop fork bombs in containers. Every fork checks the counter at each level up the tree; if any level would go over, the fork fails with "try again". A parent's limit covers all its descendants combined. See [[pid-controller|the PID controller]].

### cpuset
Pins a group's tasks to certain CPUs and memory nodes, avoiding slow remote-memory access on NUMA machines. Each group's **effective** set is what it asked for intersected with its parent's. Changing the CPUs updates every task's allowed CPUs; changing memory nodes also migrates pages. A **partition** carves a group's CPUs out of the parent's scheduling domain entirely, for guaranteed isolation. See [[cpuset-controller|cpuset]].

### Freezer
Writing 1 to a group's freeze file suspends all its tasks at their next return to user space, without sending POSIX signals. The group reports "freezing" until every task is stopped, then "frozen". New children of a freezing group are frozen at once, and freezing is hierarchical. It's used for checkpointing and migration, pausing batch jobs, and forensics. In v2 it's part of the core. See [[cgroup-freezer|the freezer]].

### BPF programs on cgroups
eBPF programs can be attached to a group to filter network traffic, control socket creation, gate device access or sysctls, and more. They replace several v1 controllers. At each hook, the programs attached along the path to the root run in order, using arrays prebuilt at attach time so no tree walk is needed per packet. Flags decide whether descendants may override or stack programs. See [[cgroup-bpf-explained|cgroup BPF]].

## A request's journey

A process in a container limited to 50% of one CPU spins in a loop:

1. **Run and charge.** Each time it runs, its group's remaining run time goes down.
2. **Draw more.** When a CPU's local slice runs out, it pulls another 5 ms from the group's pool.
3. **Throttle.** When the pool is empty, the group's run queues are removed from every CPU; nothing in the group runs.
4. **Refill.** When the period timer fires, the pool is refilled and the group's run queues are put back. This is the key point: the limit is enforced by removing the whole group from scheduling, not by slowing individual tasks.
5. **Meanwhile, memory.** If the same container allocates past its memory max, the page-fault path charges the page, fails, runs reclaim inside the group and, if that doesn't help, kills a task *within the container*, recording the event for operators to see.

## Tradeoffs

- **What it gives you:** hierarchical limits, protections and accounting for memory, CPU, I/O and processes, container isolation, and extensible policy via BPF, with cheap forks thanks to shared bundles.
- **What it costs / requires:** accounting work in the hottest kernel paths; a stricter directory layout in v2 (processes only in leaves, sometimes needing artificial leaf groups); BPF tooling for policies that used to be simple file writes.
- **Where it bites:** CPU bandwidth limits cause bursty throttling pauses, and memory max leads to in-container OOM kills. Moving from v1's separate per-controller trees to v2's single tree meant updating systemd and many tools.

## How it got here

- **2.6.24 (2008):** Paul Menage's generic cgroups with cpuset, memory, CPU and I/O controllers, each able to have its own separate hierarchy, so a process had no single "which group am I in?" answer.
- **3.14–3.16 (2014):** Tejun Heo extracted the filesystem layer into kernfs, fixing deep locking problems, and merged the unified hierarchy as an experiment; v2 declared stable in 4.5 (2016).
- **4.14 (2017):** threaded groups, so threads of one process can be in different groups. **4.20 (2018):** per-group pressure stall information for CPU, memory and I/O.
- **5.2 (2019):** BPF replaces the v1 devices controller; the freezer moves into the core. **5.4 (2019):** the cost-model I/O controller.
- **Ongoing:** hardening delegation to unprivileged managers, tighter CPU isolation for partitions, cheaper memory charging, and richer BPF program stacking.

## Related

- Technical version: [[cgroups]]
- [[cgroup-core-explained|Core]], [[css-set-and-subsystem-state|State bundles]], [[io-controller|I/O]], [[pid-controller|PIDs]], [[cpuset-controller|cpuset]], [[cgroup-freezer|Freezer]], [[cgroup-bpf-explained|BPF]], [[cpu-cgroups|CPU]]
- [[memcg-explained|Memory cgroups]], [[memory-cgroup-explained|Memory cgroup concepts]], [[psi-pressure-stall-information-explained|Pressure stall information]], [[oom-killer-explained|OOM killer]]
- [[scheduler|Scheduler]], [[block-explained|Block layer]], [[writeback-infrastructure-explained|Writeback]], [[bpf-explained|BPF]]
