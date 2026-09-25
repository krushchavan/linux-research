---
title: "Cgroup Freezer — Explained"
category: explained
original: "[[cgroup-freezer]]"
subsystem: cgroups
tags: [explained, cgroups, freezer, checkpoint]
converted: 2026-09-25
---

# The cgroup freezer, explained

> Plain-language companion to [[cgroup-freezer|the technical note]]. Same facts, fewer identifiers.

## The problem

Sometimes an entire group of processes needs to stop at once: to checkpoint a container and move it to another machine (CRIU), to pause a low-priority batch job while urgent work runs, or to inspect a suspicious container without it carrying on. Sending SIGSTOP to each process is racy (new processes can appear meanwhile) and unreliable: stop signals can be caught in some states, and processes may have handlers that complicate stopping.

A task also can't be stopped just anywhere. Freezing it in the middle of a system call could leave kernel locks held and data structures half updated, which is useless for a clean checkpoint.

## The idea in one paragraph

The freezer is a **pause button for a whole group**. Pressing it marks the group (and every group below it), then nudges each task so it soon reaches a **safe stopping point**: the moment it's about to return from the kernel to user space, when nothing inside the kernel is half done. There each task parks itself in a special frozen state that user space can't interfere with. Once every task has parked, the group reports "frozen".

## Step by step

### Step 1: Press the button
In cgroup v2 there's a simple freeze file: write 1 to freeze, 0 to thaw. Writing 1:
1. marks the group as freezing
2. walks every descendant group and marks it too
3. goes through every task and nudges it: flag it and wake it so it gets scheduled soon

### Step 2: Tasks stop themselves at a safe point
This is the key step. Tasks don't freeze instantly; each freezes at its next kernel-to-user boundary (on the way back from a system call or interrupt). There it notices its group is freezing, marks itself frozen, switches to the frozen state and gives up the CPU. It won't run again until thawed. Because this happens only at a clean boundary, the frozen state is always safe to checkpoint or inspect.

### Step 3: Track progress
The group moves through three states:
- **thawed:** running normally
- **freezing:** the button is pressed, but some tasks haven't reached their stopping point yet
- **frozen:** every task is parked

Each time a task freezes or thaws, the group recounts. When it becomes fully frozen, its events file changes, and anyone watching it (with poll or inotify) is notified, which is how tools know it's safe to proceed.

### Step 4: No escaping through fork
A task forked inside a freezing or frozen group is frozen immediately. Otherwise a runtime could fork a helper into a "frozen" container and accidentally leave something running.

### Step 5: Thaw
Writing 0 clears the marks on the group and its descendants and wakes every frozen task, which resumes exactly where it stopped.

### Step 6: Hierarchy
Freezing a parent freezes everything below it, and a child can't be thawed while its parent is frozen. A whole container subtree can be paused as a unit, with no child group escaping.

## The picture

```text
 echo 1 > container/cgroup.freeze
   mark container + all descendants "freezing"
   nudge every task ──▶ task reaches kernel→user boundary ──▶ parks (frozen)
   state: freezing … (tasks still arriving) … frozen  → events file says "frozen 1"

 CRIU:  freeze ─▶ wait for "frozen 1" ─▶ checkpoint ─▶ restore elsewhere
 echo 0 > cgroup.freeze ─▶ clear marks ─▶ wake frozen tasks ─▶ resume
```

## Tradeoffs

- **What it gives you:** an atomic, race-free pause of a whole subtree that processes can't dodge, always at a clean point, with a way to learn exactly when freezing has finished.
- **What it costs / requires:** freezing isn't instant, since tasks have to reach a boundary first, so callers must wait for the frozen report.
- **Where it bites:** a task stuck inside the kernel (for example, waiting on slow I/O) won't reach a boundary, so the group can stay "freezing" for a long time. Frozen tasks count as uninterruptible for scheduler load balancing.

## How it got here

- **2.6.29 (2009):** the freezer as a separate v1 controller, which had to be mounted on its own, and was sometimes forgotten.
- **A dedicated frozen task state:** introduced to separate kernel-requested freezing (freezer, hibernation) from user-requested stopping (SIGSTOP), which also made power management cleaner.
- **5.2 (2019):** the freeze and events files built into the v2 core, with no separate controller needed; the v1 freezer is deprecated for v2 use.

## Related

- Technical version: [[cgroup-freezer]]
- [[cgroups-explained|cgroups]], [[cgroup-core-explained|cgroup core]], [[cgroup-bpf-explained|cgroup BPF]]
- [[scheduler-explained|Scheduler]], [[inotify-and-fanotify-explained|inotify and fanotify]]
