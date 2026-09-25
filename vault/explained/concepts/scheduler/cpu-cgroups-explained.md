---
title: "CPU Cgroups — Explained"
category: explained
original: "[[cpu-cgroups]]"
subsystem: scheduler
tags: [explained, scheduler, cgroups, containers, bandwidth]
converted: 2026-09-25
---

# CPU cgroups, explained

> Plain-language companion to [[cpu-cgroups|the technical note]]. Same facts, fewer identifiers.

## The problem

Without CPU controls, any process can spawn endless threads and take over a shared machine. Containers on shared hosts need two different guarantees:
- **fair sharing under contention:** when everyone wants CPU, each group gets its proportion, and nobody starves
- **a hard ceiling:** a runaway container can't monopolise the host, even when CPU is free

These are separate needs, and one knob can't express both.

## The idea in one paragraph

Picture a **restaurant**. **Weight** is the reservation system: bigger reservations get proportionally more tables, but on a quiet night anyone can use the empty ones. **Bandwidth** is a strict time limit: every table is cleared after 90 minutes, even if nobody is waiting. A group can have both: a big reservation *and* a time limit. Underneath, the scheduler mirrors the cgroup tree: each group gets its own queue on each CPU, and the group as a whole competes in its parent's queue as if it were one task.

## Step by step

### Step 1: Mirror the hierarchy
With group scheduling turned on, each cgroup gets, on every CPU, a **queue holding its tasks** and a single **entity representing the whole group** in the parent's queue. The CPU's top-level queue holds individual tasks and group entities side by side. When a group entity wins, the scheduler descends into that group's queue and picks a task from inside. Tasks in group A and group B never compete directly in the same tree, and that's what provides the isolation.

### Step 2: Weight, the soft limit
When every group wants CPU, time is split in proportion to their weights. When a group is idle, its share goes to whoever is busy.
- **cgroup v1:** "shares", default 1024; only ratios matter, so 2048 gets twice the CPU of 1024
- **cgroup v2:** "weight", default 100, range 1–10000, converted internally to v1-style shares

Changing a weight updates the group's entity on every CPU and propagates up the hierarchy.

### Step 3: Bandwidth, the hard limit
A group can be given a **quota per period**, e.g. 50 ms of CPU every 100 ms (v2 writes this as one value; v1 splits it into two files). The group has one shared pool of remaining runtime for the current period.

### Step 4: Borrow in slices
This is the key step. Taking from the shared pool on every timer tick would mean cross-CPU locking on a hot path. So each CPU **borrows a slice** (5 ms by default, tunable) at a time and runs the group's tasks until that's used up, then goes back for another. Benchmarks for the original series showed per-tick global accounting was a scalability bottleneck on machines with more than 32 CPUs. The cost: the actual throttle point can be up to one slice late.

### Step 5: Throttle
When a CPU goes back for more and the pool is empty, the group's queue on that CPU is **throttled**: pulled out of the CPU's tree and put on the group's throttled list. None of the group's tasks there are scheduled until the next period.

### Step 6: Refill
A timer fires at each period boundary, refills the pool to the full quota, and puts every throttled queue back into its CPU's tree. Waiting tasks can run again straight away.

### Step 7: Nested limits (v2)
In cgroup v2, a child can't exceed its ancestors. If a container is capped at 200 ms per 100 ms (two CPUs' worth) and a child inside it asks for 300 ms, the child is still held to 200 ms. v1 didn't enforce this inheritance.

## The picture

```text
 CPU 0 top-level queue:  [task x] [group A entity (weight 200)] [group B entity (weight 100)]
                                         │ wins → descend
                                         ▼
                              group A's queue: [a1] [a2] [a3]

 group A bandwidth pool: 50 ms per 100 ms
    CPU 0 borrows 5 ms ─┐
    CPU 1 borrows 5 ms ─┼─▶ pool empty → throttle A's queues ─▶ period timer: refill, unthrottle
    CPU 2 borrows 5 ms ─┘
```

## Tradeoffs

- **What it gives you:** fair sharing and hard caps as independent controls, since a container may want high weight to win contention *and* a cap to prevent accidental runaway; per-group throttling statistics in v2.
- **What it costs / requires:** slice borrowing trades some quota precision for much less lock contention. v2's safer nested limits mean migrating away from v1 interfaces that many tools still depend on.
- **Where it bites:** throttling applies to the whole group's queue on a CPU, not to individual tasks. That's simpler and avoids partial-throttling races, but causes a kind of priority inversion: a high-priority task in a throttled group waits because of the group's quota, not anything it did.

## How it got here

- **2.6.24:** group scheduling with proportional shares.
- **3.2:** bandwidth throttling (Paul Turner's series), with the per-CPU slice design chosen after benchmarking.
- **4.15:** the cgroup v2 CPU controller with unified weight and max settings (Tejun Heo's series), closing v1's hierarchy gap despite migration pain for existing tools.
- **5.x:** nested bandwidth enforcement in v2 and better statistics.

## Related

- Technical version: [[cpu-cgroups]]
- [[scheduler-explained|Scheduler]], [[cfs-eevdf-explained|CFS/EEVDF]], [[runqueue|Run queue]]
- [[cgroups-explained|cgroups]], [[mm-explained|Memory management]]
