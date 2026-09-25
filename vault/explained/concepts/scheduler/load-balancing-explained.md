---
title: "Load Balancing — Explained"
category: explained
original: "[[load-balancing]]"
subsystem: scheduler
tags: [explained, scheduler, load-balancing, numa, pelt]
converted: 2026-09-25
---

# Load balancing, explained

> Plain-language companion to [[load-balancing|the technical note]]. Same facts, fewer identifiers.

## The problem

Giving each CPU its own run queue removes the global lock from task selection, but creates a new problem: tasks can pile up on one CPU while others sit idle. Fixing that means moving tasks, and moving isn't free:
- **cache locality:** a moved task leaves its warm cache behind
- **NUMA:** moving across sockets means slower access to memory on the old node
- **energy:** moving to a more powerful core on a mixed CPU costs power

## The idea in one paragraph

Think of a **bank with several teller windows**. A greeter assigns arriving customers to queues; periodically a manager looks over all the queues and moves people from long ones to empty ones. But the manager is careful: they don't move someone who's in the middle of being served (their cache is hot), prefers moving people to a nearby window over one across the building (NUMA), and moves people in batches to spread the cost. The greeter also tries to pick well at arrival, so less shuffling is needed later.

## Step by step

### Step 1: Model the hardware as nested domains
At boot, the kernel builds a hierarchy of **scheduling domains** that mirrors how CPUs share hardware:
1. **SMT:** hyperthread siblings sharing L1/L2 cache
2. **multi-core:** cores sharing the last-level (L3) cache
3. **package:** the physical socket
4. **NUMA:** across memory nodes

Each domain is split into **groups** of CPUs, e.g. at the NUMA level, one group per socket. This is the key insight: moving between hyperthread siblings is nearly free, between cores costs possible L3 misses, and between sockets means remote memory. The hierarchy lets balancing try cheap moves first. Each level has its own settings for how often to balance and how uneven things must be before acting (by default about 25% imbalance).

### Step 2: Measure load sensibly
Counting runnable tasks is too jumpy: one short burst briefly inflates it. Instead each task carries **PELT** averages (per-entity load tracking): decaying moving averages of its load (weighted by priority), its CPU utilisation, and time spent runnable. History older than about 32 ms counts for less than 1%. The balancer compares these averages, not raw task counts.

### Step 3: Periodic balancing
The timer tick checks whether balancing is due and, if so, raises a deferred softirq. That work walks the domains from the narrowest outward. At each level it finds the busiest group, compares it with the local group, and if the imbalance passes the threshold, **pulls** tasks from the busiest CPU. Some tasks can't be moved: those pinned to CPUs, those whose cache is still hot, and those a cpuset forbids.

### Step 4: Idle balancing
When a CPU runs out of work, it tries to pull work **before going to sleep**, so it doesn't sit idle while tasks wait elsewhere. It walks outward from the nearest domain and pulls a batch if the expected idle time outweighs the migration cost. If there's nothing to pull, it gives up quickly to save energy.

### Step 5: Placement at wake-up
A waking task is placed carefully in the first place:
1. **Wake affinity:** if waker and wakee talk often, the wakee's data is probably cached near the waker, so prefer an idle CPU in the waker's shared-cache domain.
2. **Idlest CPU:** otherwise, walk the domains looking for the idlest suitable CPU.

When the waker is about to block right after waking someone (a producer handing off to a consumer), the wakee can go on the waker's own CPU, which is about to be free: passing the torch.

### Step 6: Mixed big and small cores
On big.LITTLE or performance-plus-efficiency CPUs, a task using more than 80% of its current core's capacity is marked a **misfit**, and the next idle balance moves it to a bigger core. Wake-up placement also avoids putting CPU-hungry tasks on efficiency cores.

### Step 7: NUMA balancing
Optionally, the kernel periodically unmaps a task's pages so that the next access faults, and records which node's memory the task actually uses. If a task clearly favours one node, the task and its pages are moved there together. The scan rate adapts: slower when memory is already in the right place, faster when faults show lots of remote access.

## The picture

```text
 NUMA domain      [ socket 0 group ]  ◀── expensive ──▶  [ socket 1 group ]
 LLC domain       [core0 core1 core2 core3]  (shared L3: moderate)
 SMT domain       [cpu0 cpu1] (shared L1/L2: nearly free)

 periodic: walk inner → outer, pull from busiest group if imbalance > ~25%
 idle:     about to sleep? pull a batch first if worth it
 wake-up:  near the waker's cache → else idlest CPU
```

## Tradeoffs

- **What it gives you:** busy CPUs everywhere, with cheap migrations preferred and hardware topology, cache warmth and core size taken into account.
- **What it costs / requires:** pulling (idle CPUs take work) is simpler than pushing, because only the pulling CPU changes its own queue; real-time tasks do use pushing, where latency justifies the extra complexity. PELT smooths noise but lags: a CPU that has just gone idle still looks loaded for a few milliseconds.
- **Where it bites:** the imbalance threshold deliberately tolerates some unevenness, to stop tasks bouncing back and forth between two CPUs. NUMA balancing's deliberate faults add latency, which is why the scan rate adapts.

## How it got here

- **2.6.0:** per-CPU run queues and a load balancer arrived with the O(1) scheduler.
- **2.6.23:** scheduling domains (Ingo Molnár's series), because flat comparisons treated hyperthread siblings and remote NUMA nodes as equally good targets.
- **3.x:** PELT (Paul Turner's series) replaced static load accounting, since the runnable-task count was too unstable to base moves on.
- **3.13:** automatic NUMA balancing (Rik van Riel and Mel Gorman), after debate over fault cost versus placement gains.
- **4.x–5.x:** energy-aware scheduling, then misfit handling for mixed-capacity CPUs.

## Related

- Technical version: [[load-balancing]]
- [[scheduler-explained|Scheduler]], [[runqueue|Run queue]], [[cfs-eevdf-explained|CFS/EEVDF]], [[cpu-cgroups-explained|CPU cgroups]], [[rt-scheduler|Real-time scheduler]]
- [[numa-memory-policy|NUMA memory policy]], [[interrupt-handling-explained|Interrupt handling]]
