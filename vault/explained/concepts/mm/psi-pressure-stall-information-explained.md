---
title: "PSI (Pressure Stall Information) — Explained"
category: explained
original: "[[psi-pressure-stall-information]]"
subsystem: mm
tags: [explained, mm, psi, monitoring, cgroups]
converted: 2026-09-25
---

# Pressure stall information (PSI), explained

> Plain-language companion to [[psi-pressure-stall-information|the technical note]]. Same facts, fewer identifiers.

## The problem

Classic metrics describe what the *hardware* is doing: CPU utilisation, bytes of free memory, disk throughput. They don't say whether the *workload* is suffering. A machine can show 30% CPU use and plenty of activity while its tasks are mostly stuck in memory reclaim, getting nothing done.

To shed load, tune container limits, or kill a runaway group *before* the kernel's out-of-memory killer fires, you need a direct measure of how much time work is being held up waiting for a resource, and you need it quickly.

## The idea in one paragraph

PSI is **a stopwatch that runs whenever tasks are stuck at a red light** waiting for CPU, memory or I/O, and pauses when they're moving again. It runs at two severity levels: **some** (at least one task is stuck) and **full** (every task that wants to run is stuck, so even the CPUs are wasted). The share of wall-clock time the stopwatch was running is reported as a percentage, averaged over 10 seconds, 60 seconds and 5 minutes, both system-wide and per cgroup. Programs can also ask to be woken the moment stall time crosses a threshold.

## Step by step

### Step 1: Notice state changes
Every time a task starts or stops waiting on a resource, the scheduler (or the memory-reclaim path) reports it. PSI tracks how many tasks on each CPU are:
- waiting for disk I/O
- stalled on memory (reclaim, swap-in, re-reading evicted pages)
- runnable
- running but stuck inside reclaim

That last one matters: a task spinning in direct reclaim *is* using a CPU, but doing nothing useful, so it counts as stalled.

### Step 2: Update per-CPU counters
This is the key step for keeping overhead low. Each change is recorded in **per-CPU** counters for the task's cgroup and every ancestor up to the root. From the counts, PSI works out the current state (none, some, full), and adds the time spent in the *previous* state to a bucket. Counters are small (32-bit) to stay cache-friendly, and updates are protected by a sequence counter so readers can tell if they caught a write in progress. A global counter updated hundreds of thousands of times a second would bounce between CPU caches; per-CPU counters avoid that.

### Step 3: Aggregate every 2 seconds
A background job runs every **2 seconds** while the system is busy (or on demand when someone reads the numbers). It collects every CPU's time buckets and updates three running averages: 10 s, 60 s and 300 s. Because the period is fixed, the averaging constants are computed at build time. A never-decaying **total** stall time since boot is kept as well. When the system is fully idle, the job stops rescheduling itself.

### Step 4: Read the numbers
System-wide numbers appear in three pressure files (cpu, memory, io), and each cgroup has its own set. Each shows "some" and "full" lines, with the three averages and the total. CPU shows only "some": if every task is waiting for CPU, the CPU is busy running *something*, so "everyone stalled and the CPU wasted" can't happen.

### Step 5: Triggers for fast reaction (5.2)
A 2-second loop is too slow to catch a memory crisis in time. A program can open a pressure file, write a threshold such as "wake me if at least 100 ms of *some* memory stall builds up in any 1-second window", and then wait with `poll`. Windows range from 500 ms to 10 s (unprivileged users must use multiples of 2 s).

While a trigger exists, the kernel runs a faster aggregation at the trigger's granularity (as often as every 50 ms, chosen to keep overhead under 0.5% CPU on a busy system). When the threshold is crossed, the waiting program is woken. systemd-oomd, Android's low-memory killer daemon and Meta's oomd all use this to kill a cgroup before the kernel OOM killer has to.

### Step 6: Count only meaningful memory stalls
First-time page faults are normal (a program loading its data) and aren't pressure. For memory, PSI counts **refaults**: pages that were evicted under pressure and now have to come back. That avoids false alarms when a workload is simply reading new data.

## The picture

```text
 task starts/stops waiting ──▶ per-CPU counters (this cgroup + every ancestor)
                                  state: none │ some │ full   → add elapsed time
                                          │
                   every 2 s (or on read) │   trigger armed? every ≥50 ms
                                          ▼
          averages over 10 s / 60 s / 300 s  +  total stall time
                                          │
        /proc/pressure/memory:  some avg10=4.67 avg60=2.13 avg300=0.85 total=...
                                full avg10=0.00 ...
                                          │
        trigger "some 100 ms per 1 s" crossed ──▶ wake poller (e.g. systemd-oomd)
                                                   → kill a cgroup before OOM
```

## Tradeoffs

- **What it gives you:** a direct measure of lost productivity per resource and per cgroup, and event-driven alerts fast enough to act before OOM.
- **What it costs / requires:** a little work on every task state change, a walk up the cgroup tree for each (more for deep hierarchies), and a periodic pass over all CPUs.
- **Where it bites:** the averages smooth away short spikes: 10 seconds of full stall followed by 50 calm seconds shows as about 17% in the 60-second average, possibly below an alert threshold. Use the total counter, differenced between reads, to catch those. "Some" and "full" answer different questions (resource contention versus lost CPU capacity), and you need both.

## How it got here

- **4.20 (Dec 2018):** merged by Johannes Weiner (Meta), covering CPU, memory and I/O, system-wide and per cgroup. Meta had run it internally for several kernel versions; review of per-cgroup overhead led to the per-CPU, sequence-counter design. The three windows echo the traditional load average.
- **5.2 (2019):** triggers, by Suren Baghdasaryan, enabling Android to replace its in-kernel low-memory killer with a user-space daemon.
- **5.13 (2021):** commonly enabled by default, with an option to build it in but switch it on at boot.
- **5.19 / 6.x:** interrupt pressure (time lost to interrupt handling), and cheaper trigger aggregation on large machines.

## Related

- Technical version: [[psi-pressure-stall-information]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[memory-cgroup-explained|Memory cgroups]]: per-group pressure and throttling
- [[page-reclaim-explained|Page reclaim]]: the main source of memory stalls
- [[oom-killer-explained|OOM killer]]: what PSI-based daemons try to pre-empt
- [[swap-explained|swap]], [[scheduler|Scheduler]], [[cgroups-explained|Control groups]]
