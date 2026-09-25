---
title: "NUMA Memory Policy — Explained"
category: explained
original: "[[numa-memory-policy]]"
subsystem: mm
tags: [explained, mm, numa, mempolicy, locality]
converted: 2026-09-25
---

# NUMA memory policy, explained

> Plain-language companion to [[numa-memory-policy|the technical note]]. Same facts, fewer identifiers.

## The problem

On a multi-socket machine, each processor socket has its own memory attached. Reading your own socket's memory is fast; reading another socket's memory goes across an interconnect and is slower. This is **NUMA**: non-uniform memory access. Each socket's memory is a **node**.

If the kernel places a process's pages without thinking, its threads may pay the remote penalty for much of their working set. But the kernel can't always guess right: some programs want everything local, some want memory spread evenly for bandwidth, some must never touch a certain node, and newer machines mix different *kinds* of memory (DRAM, high-bandwidth memory, CXL-attached memory) as separate nodes.

## The idea in one paragraph

Let applications and administrators say **where new pages should come from**, at several levels, and have the allocator honour the most specific one. Think of a decision ladder: when a page fault needs a new page, the kernel checks the policy for that memory region first, then the thread's policy, then the system default. The first one that says something wins. The policy never moves existing pages; it only decides where new pages are born. Moving pages to improve locality is a separate mechanism (automatic NUMA balancing, or an explicit move request).

## Step by step

### Step 1: Four levels of policy
- **System default:** normally "allocate on the node of the CPU that's running". During early boot, kernel data is interleaved across all nodes instead, since there is no locality yet.
- **Thread policy:** set with a system call; inherited by children across `fork` and `exec`.
- **Memory-range policy:** set on a range of addresses with `mbind`; overrides the thread policy there. Inherited across `fork` but not `exec`, which replaces the address space.
- **Shared policy:** a range policy for shared-memory objects (tmpfs), shared by every process that maps the object.

### Step 2: Choose a mode
Each policy has a mode and a set of nodes:
- **Default:** "no opinion here, ask the next level up".
- **Preferred:** try one node; if it can't satisfy the request, fall back to others in order of distance. For when locality helps but availability matters more.
- **Preferred-many (5.15):** a *set* of equally preferred nodes, falling back to the rest only when all of them are full. Added so heterogeneous systems can say "use any high-bandwidth memory node" without risking hard failure.
- **Bind:** memory *must* come from these nodes, or the allocation fails (after reclaim, and possibly an OOM kill). For when off-node memory is worse than failing, such as a real-time thread.
- **Interleave:** hand out pages round-robin across the nodes, page by page, using a per-thread cursor. Trades peak locality for balanced bandwidth and predictable worst-case latency; good for big shared hash tables and for boot.
- **Weighted interleave (6.9):** interleave in proportion to per-node weights, so a bigger or faster node takes a bigger share. Default weights come from firmware tables describing memory performance (HMAT).

### Step 3: Stay meaningful when allowed nodes change
A process's allowed nodes can change when it's moved between cpusets (for example in containers). Two options control what a policy's node set means then:
- **static:** keep the exact nodes asked for, and use only those still allowed. If none are, refuse rather than quietly widening.
- **relative:** treat the set as positions ("the 2nd allowed node"), and remap when the allowed set changes, preserving the intended spread.

Both were added after cpuset changes were found to silently corrupt policies by changing what the stored node numbers meant.

### Step 4: Installing a policy
Setting a thread policy validates the request, creates a reference-counted policy object, stores the original request if one of the options above needs it, intersects the nodes with what the cpuset allows, and swaps it in. Setting a range policy is heavier: it takes the process's memory lock for writing, walks the affected regions, attaches policies, and can optionally migrate existing pages to match.

### Step 5: Allocating with a policy
This is the key step. When a page is needed, the kernel:
1. finds the effective policy: the region's, else the thread's, else the default
2. turns it into a concrete set of nodes, given the current cpuset (for interleave, it advances the cursor and picks the next node)
3. restricts the allocator's list of candidate memory zones to those nodes
4. tries them, respecting free-memory watermarks. Unless the mode is "bind", if all preferred nodes are exhausted it retries anywhere.

### Step 6: Automatic NUMA balancing
Most programs don't know their topology. Since 3.8–3.10 the kernel can improve locality by itself:
1. periodically, the scheduler marks a fraction of a task's pages so the next access will fault (a "hinting" fault)
2. that fault records which node the access came from and where the page lives
3. if a page is repeatedly used from another node, it's migrated there
4. threads that share pages are grouped, so the scheduler can place them together near their data

Explicit range policies take precedence over this automatic migration, and balancing can be turned off.

## The picture

```text
 page fault needs a new page
        │
        ▼
 region policy?  ──yes──┐
        │ no            │
 thread policy?  ──yes──┤
        │ no            │
 system default ────────┤
                        ▼
      mode + nodes → concrete node set (∩ cpuset)
        preferred:     node 1, else nearest others
        preferred-many:{1,3}, else anywhere
        bind:          {0,1} only, or fail
        interleave:    0,1,2,3,0,1,... (weighted: 0,0,0,1,...)
                        ▼
              allocator tries zones on those nodes

 separately: NUMA balancing samples accesses → migrates misplaced pages
```

## Tradeoffs

- **What it gives you:** coarse defaults with precise overrides; a library can set a policy on its own memory without knowing the application's thread policy; container-safe relative policies.
- **What it costs / requires:** lookup and rebinding complexity; shared-memory policies need an extra lock and reference per allocation (slower, but those allocations are rarer).
- **Where it bites:** "bind" can trigger reclaim and OOM kills rather than use perfectly good memory elsewhere. Using NUMA nodes to express *memory types* (preferred-many, weighted interleave) mixes two ideas, locality and kind of memory. Reviewers accepted it pragmatically to avoid new system calls, and a future call using process file descriptors may separate them. Automatic balancing costs overhead that doesn't pay off on workloads with no natural locality.

## How it got here

- **2.6.7 (2004):** the NUMA API with four modes: default, bind, preferred, interleave.
- **2.6.19:** static and relative node options, after cpuset changes corrupted policies.
- **3.8–3.10 (2013):** automatic NUMA balancing (Rik van Riel's foundational RFC) with hinting faults, NUMA groups and scheduler integration.
- **5.15 (2021):** preferred-many, for heterogeneous memory such as CXL nodes.
- **6.9 (2024):** weighted interleave with system-wide weights; per-task weights deferred over system-call design concerns.

## Related

- Technical version: [[numa-memory-policy]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[buddy-allocator-explained|Buddy allocator]]: picks pages within the chosen nodes
- [[page-fault-handler-explained|page-fault-handler]]: where the policy is looked up
- [[memory-compaction-explained|Memory compaction]]: may run when moving pages to a node
- [[memory-cgroup-explained|Memory cgroups]], [[cpuset-controller-explained|cpuset controller]], [[scheduler|Scheduler]]
