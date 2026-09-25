---
title: "CFS and EEVDF: The Fair Scheduler — Explained"
category: explained
original: "[[cfs-eevdf]]"
subsystem: scheduler
tags: [explained, scheduler, cfs, eevdf, fairness]
converted: 2026-09-25
---

# CFS and EEVDF, explained

> Plain-language companion to [[cfs-eevdf|the technical note]]. Same facts, fewer identifiers.

## The problem

Every shell, daemon, container and desktop app that hasn't asked for real-time priority is handled by the fair scheduler. It has to meet three partly conflicting goals at once:
- **fairness:** nobody is permanently starved relative to their priority
- **low latency:** interactive tasks get the CPU promptly when they wake
- **throughput:** batch work keeps the CPU busy without needless switching

Its predecessor, the O(1) scheduler, tried to meet them with opaque "is this task interactive?" guesses. CFS then accumulated its own pile of wake-up tweaks. The core tension: picking whoever has had the least CPU is a *fairness* rule, not a *latency* rule. A task handling a network packet with a 1 ms deadline got no advantage over a batch job that happened to nap briefly.

## The idea in one paragraph

Give every task a **virtual clock that runs at a different speed**. A high-priority task's clock runs slowly, so it always looks as if it has used less than it really has; a low-priority task's clock runs fast. Always run whoever's clock shows the least time, and higher-priority tasks automatically get more real CPU, with no special cases. EEVDF adds a twist: among the tasks that **haven't yet used more than their fair share**, pick the one with the **earliest deadline**. Latency-sensitive tasks can then jump the queue without breaking fairness.

## Step by step

### Step 1: Virtual runtime
Each task's virtual runtime grows with the real CPU time it uses, scaled by its weight relative to a normal (nice 0) task. At nice −5, virtual time grows at about a third of the real rate; at nice +5, about three times it. Each nice step changes the weight by about 1.25×, roughly a 10% throughput difference; the extremes (−20 versus +19) differ by nearly 6000 to 1. Over time, the CPU shares of any two tasks converge to the ratio of their weights: fairness that can be proved, not guessed.

### Step 2: The sorted tree
All runnable fair tasks on a CPU sit in a red-black tree ordered by virtual runtime, with the leftmost (smallest) task cached so it can be found instantly. On each timer tick, the running task's virtual runtime is advanced; if it has used more than its share of the scheduling period, it's flagged to be switched out.

### Step 3: Handling sleepers
A task that slept for a long time would come back with a virtual runtime far behind everyone else's, and could then hog the CPU to "catch up". So when a task wakes, its virtual runtime is moved up to a bit behind the current average (about half a slice behind). It lands near the front of the queue, but can't starve the others.

### Step 4: Eligibility (EEVDF, 6.6+)
EEVDF is based on a 1995 paper by Ion Stoica and Hussein Abdel-Wahab. A task is **eligible** only if its virtual runtime is at or below the weighted average, meaning it hasn't used more than its fair share. Only eligible tasks can be picked.

### Step 5: Virtual deadlines
This is the key step. Each task gets a **virtual deadline**: its virtual runtime plus its requested time slice (scaled by weight). A task asking for **shorter slices gets an earlier deadline**. The scheduler picks the eligible task with the earliest deadline. Latency-sensitive tasks get to run sooner as a direct result of the rule, not through a special case, and the old wake-up tweaks could be removed because this one mechanism covers them.

### Step 6: Wake-up pre-emption
When a task wakes, its virtual deadline is compared with the running task's. If it's earlier, the running task is flagged to be switched out, a more principled test than the old heuristic.

### Step 7: Groups
With group scheduling, each cgroup gets its own per-CPU queue and a single entity representing the whole group. That entity competes in the parent's queue using the group's weight, while tasks inside the group compete among themselves: a two-level hierarchy rather than one flat tree. See [[cpu-cgroups-explained|CPU cgroups]].

## The picture

```text
 virtual runtime (lower = owed more CPU)       avg
 ────────────────────────────────────────────── │ ──────────────▶
   A: nice -5  ●────────────── deadline 12       │
   B: nice 0        ●── deadline 9 (short slice) │
   C: nice +5                                    │   ● ineligible (ahead of share)

 CFS picked:   smallest virtual runtime  → A
 EEVDF picks:  eligible (left of avg) with earliest deadline → B
```

## Tradeoffs

- **What it gives you:** provable weighted fairness; latency that follows from requested slice length rather than fragile heuristics; group hierarchies for containers.
- **What it costs / requires:** fairness is only approximate within a scheduling window, since tasks run in slices. Shrinking that window (6 ms by default for a handful of tasks, set as a desktop-latency compromise) means more context switches and overhead. A minimum slice (0.75 ms by default) prevents thrashing when there are many tasks.
- **Where it bites:** a red-black tree costs logarithmic time per operation. A sorted list would be linear per insertion, and a heap offers the same bound with more complexity; the tree also behaves well in cache at typical sizes (usually under 100 runnable tasks per CPU).

## How it got here

- **2.6.23 (2007):** CFS replaced the O(1) scheduler. Ingo Molnár's cover letter credited Con Kolivas's RSDL as the inspiration, and pitched fairness as provable rather than heuristic.
- **2.6.24:** group scheduling for cgroups.
- **3.x:** PELT, a decaying-average load measure used by the load balancer.
- **5.x:** some CFS wake-up heuristics removed (a partial clean-up).
- **6.6 (2023):** EEVDF replaced CFS's selection rule. Peter Zijlstra's series showed per-benchmark results matching or beating CFS without special cases. Work continues on a latency-nice interface and on integrating EEVDF with group scheduling.

## Related

- Technical version: [[cfs-eevdf]]
- [[scheduler-explained|Scheduler]], [[runqueue|Run queue]], [[cpu-cgroups-explained|CPU cgroups]], [[load-balancing|Load balancing]], [[scheduler-classes|Scheduling classes]]
- [[interrupt-handling-explained|Interrupt handling]]
