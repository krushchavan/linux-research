---
title: "memcg (Memory Control Group) — Explained"
category: explained
original: "[[memcg]]"
subsystem: memcg
tags: [explained, memcg, cgroups, containers, memory]
converted: 2026-09-25
---

# memcg, the memory control group subsystem, explained

> Plain-language companion to [[memcg|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

On a machine running many workloads (containers, batch jobs, services), memory is one shared pool. Without separation, one runaway process can push out the whole system's file cache and trigger system-wide out-of-memory kills of things that did nothing wrong.

memcg adds per-group accounting and enforcement. It counts every page a group of processes uses (anonymous memory, file cache, swap, kernel memory), enforces limits, and keeps memory pressure inside the group that caused it. It's the foundation of memory isolation for containers.

## The big picture

Think of memcg as **separate sub-budgets** inside the machine's total memory. Each group has its own account. Every page allocated is charged to it; every page freed is credited back. If a group goes over its soft ceiling, the kernel reclaims from *that group's own* pages first, not from the whole system, and slows the group down. If it hits its hard ceiling and reclaim fails, only that group's OOM handling fires.

```text
 task faults in a page / allocates kernel memory
            │ charge
            ▼
   group's counter (usage, with min / low / high / max)
            │ also charged up the tree
            ▼
   parent's counter ... root
            │
     usage ≥ high ──▶ reclaim from this group's own LRU lists + slow the task
     usage ≥ max, reclaim fails ──▶ OOM kill inside this group only
            ╎
     stall time ──▶ pressure information (memory.pressure)
```

## The pieces

### Accounting

Every page must be attributed to a group so limits are accurate. (See also [[memory-cgroup-explained|the memory cgroup concept note]].)

1. Each page records which group owns it.
2. On allocation, the kernel finds the process's group and atomically adds the page to that group's counter and to every ancestor's counter.
3. If any ancestor's hard limit would be exceeded, reclaim is triggered for that ancestor; if reclaim fails, OOM follows.
4. When a page is freed, the counters are reduced all the way up.

Each group keeps separate counters for memory, swap and kernel memory, plus statistics and optional notification thresholds.

### Per-group LRU lists

Each group has its own active and inactive lists (anonymous and file) for every NUMA node, so reclaim targets the group that's over its limit.

1. Pages join their group's lists when faulted in and age within those lists.
2. When a group passes its soft ceiling, the same reclaim code the system uses globally runs, but restricted to that group's lists.
3. If a limit set on an *ancestor* is hit, reclaim starts at that ancestor and scans all its descendants' lists proportionally, so one child isn't starved to protect the others.

In cgroup v1, a group could even have its own swappiness; zero stopped its anonymous memory from being swapped at all.

### Four levels of protection and limit (cgroup v2)

From softest to hardest:

| Setting | Meaning | What happens |
|---|---|---|
| min | hard guarantee | global reclaim skips the group while it's below this |
| low | soft protection | reclaim pressure on the group is reduced proportionally |
| high | soft ceiling | aggressive reclaim within the group, and allocating tasks are slowed |
| max | hard ceiling | OOM kill if reclaim can't get back under it |

The effective limit is the smallest of the group's own and all its ancestors' limits. **high** is the key one for containers: overage causes delays proportional to how far over the group is, putting **back-pressure on the allocating task** rather than on the whole system. The "OOM group" option kills every task in the group together, so a container fails cleanly instead of leaving orphans.

### Pressure information

Pressure stall information (PSI) measures the share of time tasks are stalled waiting for memory, as "some" (at least one task stalled) and "full" (all stalled), averaged over 10, 60 and 300 seconds. Each group exposes its own pressure file, and orchestrators (Kubernetes, systemd) watch it to scale up or evict before OOM. An events file counts how often each threshold (low, high, max, OOM, OOM kill) was hit. See [[psi-pressure-stall-information-explained|PSI]].

## A request's journey

A container going over its soft ceiling:

1. **Fault.** A task in the container touches a new page of anonymous memory.
2. **Charge.** The page is charged to the container's group, and usage goes past **high**.
3. **Reclaim locally.** Before returning, the task is made to reclaim from its own group's LRU lists (and is slowed in proportion to the overage).
4. **Success.** If enough is freed, the charge completes and the task continues.
5. **Or failure.** If reclaim fails and **max** is crossed, the group's OOM handling runs; with the group option, every task in the container is killed.
6. **Recorded.** Every task that stalled during steps 3–5 adds to the group's pressure numbers.

## Tradeoffs

- **What it gives you:** per-container memory limits, protections, and OOM handling, with reclaim cost proportional to the group's size rather than the whole machine.
- **What it costs / requires:** per-page ownership records and per-group lists. The original merge measured about 3% overhead for per-page accounting, accepted as the price of isolation.
- **Where it bites:** pages are charged when first touched, not when reserved, so a process that maps a big buffer can hit its limit at an unexpected moment later. Hard limits alone (as in v1) kill abruptly; v2's **high** throttling gives applications a chance to shed memory first. Kernel memory accounting is still being made more accurate for socket buffers and BPF maps.

## How it got here

- **2.6.25 (2008):** memcg merged (Balbir Singh) with anonymous-memory accounting and a single limit, after debate about per-page overhead.
- **2.6.29–2.6.32 (2009):** file cache accounting, then hierarchical accounting and reclaim.
- **3.8 (2013):** kernel memory accounting.
- **2012:** hierarchical reclaim redesigned (Michal Hocko and others) so children could no longer exceed their parent's limit.
- **4.5 (2016):** cgroup v2 non-experimental, with min, low, high and max.
- **4.19–4.20 (2018):** pressure stall information and the OOM-group option (Roman Gushchin), motivated by container runtimes needing clean teardown.
- **5.x:** proactive reclaim from user space, plus cgroup-aware writeback so dirty pages are written on behalf of the group that dirtied them.

## Related

- Technical version: [[memcg]]
- [[memory-cgroup-explained|Memory cgroup (concept note)]]: the mechanism in more detail
- [[mm-explained|Memory management]]: the subsystem memcg extends
- [[page-reclaim-explained|Page reclaim]], [[oom-killer-explained|OOM killer]], [[swap-explained|Swap]]
- [[psi-pressure-stall-information-explained|Pressure stall information]]
- [[writeback-infrastructure-explained|writeback-infrastructure]], [[cgroups-explained|Control groups]]
