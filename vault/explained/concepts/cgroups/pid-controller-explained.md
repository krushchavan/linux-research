---
title: "PID Controller — Explained"
category: explained
original: "[[pid-controller]]"
subsystem: cgroups
tags: [explained, cgroups, pids, fork-bomb]
converted: 2026-09-25
---

# The PID controller, explained

> Plain-language companion to [[pid-controller|the technical note]]. Same facts, fewer identifiers.

## The problem

A process that calls `fork` in a loop (a **fork bomb**, whether malicious or a bug) can use up every process ID on the machine. After that, nothing new can start anywhere: not a shell, not a login, not the tools needed to fix things. Memory and CPU limits don't stop this, because each process can be tiny. Containers need a hard cap on how many processes and threads they can create, one that the container can't sidestep by creating subgroups.

## The idea in one paragraph

Treat process slots like **hotel rooms** with a booking desk. Each new process (a fork) must be confirmed by the manager, who keeps a count of rooms in use for the whole wing (the cgroup and everything below it). Once the wing is full, bookings are refused, even if one floor (a child group) still thinks it has room, because the check is made at every level up the building.

## Step by step

### Step 1: A counter and a limit per group
Each group keeps a counter of tasks in it **and all its descendants**, plus a limit (by default effectively unlimited). That's the whole controller, the simplest of all the cgroup controllers.

### Step 2: Check before creating
This is the key step. On every `fork` or `clone`, before the new task is even allocated, the kernel walks **up** from the task's group to the root, adding one to each group's counter and checking it against that group's limit. If any level would go over, every increment made so far is undone and the fork fails with "try again". A child group set to "no limit" can't escape its parent's limit, since the parent's counter is checked too. Checking at creation also means the limit can't be dodged afterwards.

### Step 3: Confirm or roll back
If the check passes, the fork goes ahead and the charge is confirmed once the new task exists. If the fork fails later for some other reason, the charge is rolled back.

### Step 4: Release on exit
When a task exits, the counter is decreased at every level up the tree.

### Step 5: Watch it
- the current count covers the group and everything below it
- an events count goes up each time a fork is refused for this limit, so a non-zero value shows a container has hit its ceiling
- a peak value (since 5.17) records the highest count ever reached

## The picture

```text
 root         limit ∞      current 900
 └ container  limit 1000   current 1000   ← full
    └ build   limit ∞      current 400

 fork() in "build": build 401 ✓ → container 1001 ✗ → undo all → fail "try again"
                    container's refusal counter +1
 task exits in "build": build −1, container −1, root −1
```

## Tradeoffs

- **What it gives you:** fork bombs confined to their own container, checked at the moment of creation and impossible to evade with subgroups.
- **What it costs / requires:** an atomic update at every level of the tree on each fork and exit.
- **Where it bites:** once a parent is full, *no* child can fork, whatever its own headroom, because the parent's counter is shared. There's only a hard limit, no soft "slow down" tier as memory has; one was considered and judged pointless, since process IDs are discrete and cheap. The error is "try again" rather than "out of memory", deliberately retriable, though fork bombs rarely retry politely.

## How it got here

- **4.3 (2015):** the PID controller (Aditya Kali, Google), designed for stopping fork bombs in containers.
- **5.17 (2022):** the peak count added.

## Related

- Technical version: [[pid-controller]]
- [[cgroups-explained|cgroups]], [[cgroup-core-explained|cgroup core]], [[css-set-and-subsystem-state-explained|How tasks link to controllers]]
