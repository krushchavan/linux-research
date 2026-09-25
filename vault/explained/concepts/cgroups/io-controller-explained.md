---
title: "I/O Controller (blkcg) — Explained"
category: explained
original: "[[io-controller]]"
subsystem: cgroups
tags: [explained, cgroups, io, block, iocost]
converted: 2026-09-25
---

# The cgroup I/O controller, explained

> Plain-language companion to [[io-controller|the technical note]]. Same facts, fewer identifiers.

## The problem

Disks are shared. One container doing heavy I/O can saturate a disk and starve every other container of storage access. Operators want to cap a group's disk traffic, share a busy disk fairly, or protect a latency-sensitive database from noisy neighbours, and different workloads want different ones of these.

Two things make it harder. Limits only make sense per device (500 operations per second is generous for a spinning disk and tiny for an SSD). And much disk writing happens long after the program wrote to memory, in background writeback, where it's easy to charge the wrong group.

## The idea in one paragraph

Picture a **shared motorway with toll booths**. A hard **limit** is a speed limit: traffic over it is made to wait. A **weight** is how many lanes a group gets when the road is congested: twice the weight, twice the lanes. **Latency protection** is a guarded carpool lane: if a protected group's traffic starts getting delayed, *other* groups are made to give way. Every group gets separate state for each device it uses, and background writeback is charged to the group that dirtied the data.

## Step by step

### Step 1: Per-group, per-device state
Each cgroup has one I/O record, plus one entry per device it does I/O to. A group writing to three disks has three entries. When an I/O request (a bio) is submitted, the kernel finds or creates the entry for (this group, this device), which keeps both the group and the device's queue alive while I/O is in flight. Every policy check hangs off that entry.

### Step 2: Hard limits
A group's max setting installs limits on bytes and operations per second, separately for reads and writes, as four **token buckets**. For each incoming I/O:
1. if it fits the budget, spend the tokens and let it through
2. if the bucket is empty, queue it and set a timer to release it as tokens refill at the configured rate

The timer adapts: with many small I/Os queued, it fires often, releasing them in bursts that match the rate. Limits are simple and predictable, but not work-conserving: a group at its limit can't use spare capacity even when the disk is idle.

### Step 3: Proportional sharing (iocost)
This is the key step for fairness. Weights (1 to 10,000, default 100) use a **cost model**: each I/O is given a cost from an estimate of the device's seek and transfer time, and groups are scheduled by **virtual time**, much like the CPU scheduler:
- each group's virtual time advances with the cost of its I/O, scaled by its weight
- a group ahead of global virtual time (it's had more than its share) has its I/O delayed
- a group behind is served immediately and builds up credit it can spend in bursts

The device model can be tuned by hand or calibrated automatically. A quality-of-service layer adds latency targets, throttling workloads that drive latency too high. It's work-conserving, but only as good as the cost model.

### Step 4: Latency protection
A protected group gets a latency target in microseconds. The controller watches its average I/O completion latency; if it rises above target, the controller cuts the I/O share of its **siblings** on that device, not the protected group's. It's the reverse of throttling: others are penalised for hurting the protected group. That protects the database at the cost of throughput for everyone else. In practice, deployments often combine latency protection for databases with weights for background work.

### Step 5: Charging writeback correctly
When a page is dirtied, it's tagged with the group responsible. When writeback later flushes it, the I/O is charged to that group's budget, not to whoever happens to be running the flush. A process that dirties lots of data and then moves to another group still pays for its writes. The memory and I/O controllers cooperate on this. Charging the flusher's current group would be simpler, but wrong after a move.

## The picture

```text
 bio from group G to device D ─▶ entry (G, D)
   max set?      ─▶ token buckets (read/write × bytes/ops): enough? pass : queue + timer
   weight set?   ─▶ cost(bio) → G's virtual time: ahead? delay : issue (earn credit)
   latency target on sibling S? ─▶ S too slow → shrink G's share

 write() → page dirtied, tagged G ··· later ··· writeback bio charged to G
```

## Tradeoffs

- **What it gives you:** hard caps, fair proportional sharing and latency protection, per device, with writeback charged to the right group.
- **What it costs / requires:** three separate mechanisms to understand and tune; a cost model that may be imprecise for a given device; extra bookkeeping to attribute writeback.
- **Where it bites:** hard limits waste idle capacity, latency protection lowers everyone else's throughput, and weights depend on a good device model. No single mechanism fits every workload.

## How it got here

- **2.6.33 (2010):** the v1 block I/O controller, with proportional weights through the CFQ scheduler.
- **4.5 (2016):** the v2 I/O controller with hard limits and weights.
- **5.4 (2019):** iocost, a cost-model controller better suited to SSDs than CFQ-based scheduling.
- **5.14 (2021):** discard statistics in the stats file; latency protection stabilised.

## Related

- Technical version: [[io-controller]]
- [[cgroups-explained|cgroups]], [[cgroup-core-explained|cgroup core]], [[memcg-explained|Memory cgroups]]
- [[block-explained|Block layer]], [[io-scheduler-explained|I/O schedulers]], [[writeback-infrastructure-explained|Writeback]]
