---
title: "Memory Cgroup (memcg) — Explained"
category: explained
original: "[[memory-cgroup]]"
subsystem: mm
tags: [explained, mm, cgroups, containers, memcg]
converted: 2026-09-25
---

# The memory cgroup controller, explained

> Plain-language companion to [[memory-cgroup|the technical note]]. Same facts, fewer identifiers.

## The problem

Without some form of accounting, every process on a machine draws from one shared pool of RAM. A single runaway container can eat all of it and trigger an out-of-memory event that kills something unrelated. Running many workloads on one machine (containers, systemd services, Kubernetes pods) needs each group to get a bounded, separately managed share: its own limit, its own reclaim, its own OOM handling, and some protection from its neighbours.

The hard parts: every page must be attributed to someone, even kernel-internal memory; reclaiming "only from this group" must not mean scanning the whole machine; and a hard limit that goes straight from "fine" to "killed" is a bad experience.

## The idea in one paragraph

Give each control group (cgroup) its own **water tank**: a fill level, a warning line (`memory.high`) and an overflow limit (`memory.max`). Every page carries a tag saying which tank it belongs to. As a tank nears its warning line, the kernel slows that group's allocations and reclaims from it; if it overflows, the OOM killer acts within that group. Parent tanks add up the fill of all their children, so a parent can cap a whole subtree without knowing how it's divided.

## Step by step

### Step 1: Charge each page to its owner
Pages are charged at the moment they get an owner that users can see:
- **anonymous memory:** in the page-fault path, just before the new page goes into the page table
- **file data:** when a page is first added to a file's page cache

Charging walks **up the cgroup tree**, increasing the counter at every ancestor. If any ancestor would go over its hard limit, the kernel first tries to reclaim memory from that group. Only if that fails does the charge fail, and the group's OOM handling takes over.

### Step 2: Two-phase charging
The charge is taken in two steps. First the counters are raised speculatively. Only once the page is safely in the page table or page cache is the page actually tagged with its group. If insertion fails, the charge is cancelled. That avoids a page being counted but never used, without needing a lock across the whole operation. When a page's last reference goes away, the counters are lowered all the way up.

### Step 3: Separate LRU lists per group
This is the key step for scale. Reclaim works from LRU lists (least recently used). memcg gives every **(cgroup, NUMA node)** pair its own set of lists: inactive and active anonymous, inactive and active file, and unevictable. A newly charged page goes onto its group's lists. When a group is over its limit, reclaim scans only that group's lists, so the cost depends on the group's size, not the whole machine's. Early versions used one global list and skipped other groups' pages, which was far slower. The reclaim algorithm itself is unchanged; it just runs on a group's lists.

### Step 4: `memory.high`, the gentle brake
Container runtimes are encouraged to rely on the **high** line, set well below the hard limit. Going over it doesn't kill anything. On the way back to user space, the task is put to sleep for a time proportional to how far over it is: a little for 1% over, much longer for 50%. That buys time for a management daemon (systemd's oomd, the Kubernetes kubelet) to shrink the workload or raise the limit. The accumulated stall time is visible as memory pressure (PSI). Using only the hard limit, as early Docker setups did, goes from normal straight to killing with no warning.

### Step 5: Protection: `memory.min` and `memory.low`
Protections work the other way from limits:
- **min** is a hard guarantee: reclaim never takes a group below this, even under severe system-wide pressure.
- **low** is a soft one: reclaim is biased away from the group in proportion to how much of its protected amount is in use.

Protection flows down the tree. A child claiming 1 GB of hard protection under a parent that has only 512 MB gets 512 MB; the parent's promise is the binding one.

### Step 6: Swap counts too
Otherwise a group could dodge its limit by swapping aggressively. With swap accounting, a table records which group owns each swap slot, and a combined memory-plus-swap counter is kept. In cgroup v2, swap has its own separate cap. When a page is swapped back in, the swap charge moves back to a memory charge, keeping the total constant.

### Step 7: Kernel memory counts too
User pages are easy to attribute; kernel memory is trickier. memcg tracks three kinds:
- **slab objects:** object types marked for accounting (dentries, inodes, file objects, added over several releases) get per-group caches, created on first use, so one group can't keep another's slab pages alive
- **kernel stacks:** each task's 8–16 KB stack is charged to its group
- **socket buffers:** TCP and UDP buffers are charged to the socket's group

All of this counts toward the same limit as user memory.

### Step 8: OOM inside the group
If reclaim can't bring a group under its hard limit, the OOM killer runs **scoped to that group** and its descendants, killing the biggest task there. With the "group" option, every task in the cgroup is killed together, so no half-dead group is left behind.

### Step 9: Moving tasks doesn't move pages
A page stays charged to the group that allocated it, even if the process later moves to another group. Only new allocations are charged to the new group. Re-charging every mapped page on a move would mean locking every page table that maps it.

## The picture

```text
                 root (sum of everything)
                /                    \
        containers (max 8G)          system (min 1G)
          /           \
   web (high 3G,     db (min 2G, max 4G)
        max 4G)
   │ page charged ─▶ counters rise at web, containers, root
   │ web > high   ─▶ allocations slowed + reclaim from web's own LRU lists
   │ web > max    ─▶ reclaim; if that fails → OOM kill inside web only
   │ system pressure ─▶ reclaim skips db below 2G (min), prefers unprotected groups
```

## Tradeoffs

- **What it gives you:** per-workload limits, protection and OOM handling that container runtimes build on, with reclaim cost proportional to the group being reclaimed.
- **What it costs / requires:** separate LRU lists per group per node (memory and extra locking); only specially marked kernel object types are charged, so some kernel memory escapes accounting.
- **Where it bites:** ownership stays with the original group after a task moves, so accounting can drift for workloads that move around. Relying on `memory.max` alone produces abrupt OOM kills; `memory.high` is the intended control.

## How it got here

- **2.6.25 (2008):** first merged (Balbir Singh), with per-group limits and LRU lists but no hierarchy or swap accounting.
- **2.6.29–2.6.34:** hierarchical accounting and soft-limit reclaim.
- **3.8 (2013):** kernel memory accounting (Glauber Costa, Michal Hocko).
- **4.0–4.5 (2015–2016):** cgroup v2's clean interface of min, low, high and max (Johannes Weiner, Tejun Heo), hierarchy made mandatory, and kernel memory counted by default.
- **4.20–5.2:** pressure stall information and memory pressure files.
- **5.9 (2020):** a per-group LRU lock replaced a per-node one, removing a major contention point (Alex Shi).
- **5.16–6.1 (2022):** folio conversion, proactive reclaim from user space (5.19), and multi-generation LRU per group (6.1).

## Related

- Technical version: [[memory-cgroup]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[page-reclaim-explained|page-reclaim]], [[oom-killer-explained|oom-killer]], [[swap]]: what the controller drives
- [[psi-pressure-stall-information]]: how throttling becomes visible
- [[folio-explained|Folios]]: the unit that carries the group tag
- [[slub-slab-allocator]], [[page-fault-handler-explained|page-fault-handler]]
- [[cgroups|Control groups]], [[cgroup-core]]
