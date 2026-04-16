---
title: "PID Controller"
category: concept
tags: [cgroups, pid, fork-bomb, process-limits, security]
subsystem: cgroups
kernel_version: "4.3"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html
  - https://lwn.net/Articles/679786/
---

# PID Controller

## Purpose

The PID controller limits how many tasks (processes and threads) a cgroup tree may contain. Without it, a malicious or buggy process inside a container can call `fork()` in a loop, consuming all available PIDs on the system and preventing any new processes from starting — a fork-bomb denial-of-service. The controller stops this at the boundary of the cgroup tree, confining the damage to the container.

## Mental Model

Think of PIDs as hotel rooms. The PID controller is a reservation system: each room request (fork) checks with the hotel manager before confirming. The manager tracks how many rooms are in use across the entire wing (the cgroup subtree) and refuses bookings once the wing is full. The wing owner cannot exceed the allocation even if individual floors (child cgroups) have capacity remaining, because the check is hierarchical.

## How It Works

The PID controller is the simplest of the resource controllers. `struct pids_cgroup` embeds a `cgroup_subsys_state` and holds two values: `pids_current` (an atomic counter of tasks currently in this cgroup *and all its descendants*) and `pids_limit` (the maximum allowed, defaulting to `PIDS_MAX` which means "no limit").

### fork path

On every `fork()` or `clone()` call, the kernel invokes `pids_can_fork()` before the new task is allocated. This function walks *up* the hierarchy from the current cgroup to the root, calling `pids_try_charge()` at each level. `pids_try_charge()` atomically increments `pids_current` and checks whether it exceeds `pids_limit`. If any ancestor would be exceeded, all the tentative increments are rolled back and the function returns `-EAGAIN`. The fork system call propagates this as `EAGAIN` to userspace.

The hierarchical check is critical: it prevents a child cgroup from circumventing a parent's limit. Even if the child has `pids.max = max`, the parent's limit is enforced.

### post-fork

If `pids_can_fork()` succeeds, the fork proceeds. After the new task is fully created, `pids_fork()` finalizes the charge. If the fork fails for any reason after `pids_can_fork()` succeeded, `pids_cancel_fork()` rolls back the increment.

### exit path

When a task exits, `pids_release()` decrements `pids_current` at every ancestor. The decrement is unconditional and uses `atomic_long_dec()`.

### Accounting scope

`pids.current` reports the count for the cgroup and *all its descendants* combined, because the limit is hierarchical. Writing `1000` to a parent's `pids.max` means the parent plus all children combined cannot exceed 1000 tasks, regardless of per-child settings.

`pids.events` records `max` events: each time `pids_can_fork()` rejects a fork due to the limit, the event counter increments. This is useful for monitoring: a non-zero `pids.events` indicates a container has hit its fork limit.

`pids.peak` (added in 5.17) records the high-water mark of `pids.current` for the lifetime of the cgroup.

## Key Data Structures

**`struct pids_cgroup`** (`kernel/cgroup/pids.c`) — per-cgroup PID controller state
- `css` — embedded `cgroup_subsys_state`
- `pids_current` — `atomic64_t`; current task count for this cgroup and all descendants
- `pids_limit` — maximum allowed (PIDS_MAX = PID_MAX_LIMIT ≈ 4 million on 64-bit)
- `events_limit` — count of times the limit was hit (written to `pids.events`)

## Key Functions / Entry Points

**`pids_can_fork()`** (`kernel/cgroup/pids.c`) — called before task creation; walks hierarchy checking limits

**`pids_cancel_fork()`** (`kernel/cgroup/pids.c`) — rolls back a `pids_can_fork()` charge if the fork subsequently fails

**`pids_fork()`** (`kernel/cgroup/pids.c`) — finalizes the charge after the new task is live

**`pids_release()`** (`kernel/cgroup/pids.c`) — decrements counts at all ancestors on task exit

## Important Flags & Config Options

- `CONFIG_CGROUP_PIDS` — enables the PID controller
- `pids.max` — write a number to set the limit; write `max` to remove it
- `pids.current` — read-only; current task count for this subtree
- `pids.peak` — read-only; maximum `pids.current` ever recorded (since 5.17)
- `pids.events` — read-only; `max` field counts fork rejections

## Interactions with Other Subsystems

- **↑ Userspace**: container runtimes write `pids.max` at setup time; monitoring tools read `pids.current` and `pids.events`
- **→ fork path**: the kernel calls `pids_can_fork()` in `copy_process()` before any task-struct allocation; failure aborts the fork with `EAGAIN`
- **← [[cgroup-core]]**: the core's `fork` and `exit` callbacks trigger `pids_fork()` and `pids_release()` respectively

## Design Decisions & Tradeoffs

**Hierarchical check on fork rather than per-task** means the limit is enforced at the moment of creation and cannot be evaded by migrating tasks into the cgroup after the fact. The downside: if a parent's limit is already at capacity, no child cgroup can fork even if the child has headroom, because the parent-level counter is shared.

**`EAGAIN` instead of `ENOMEM`** was a deliberate choice: `EAGAIN` is retriable, signaling to the caller that it should try again later rather than treating the failure as a permanent resource shortage. In practice, fork-bomb processes rarely retry gracefully.

**No soft limit** unlike memory (which has `memory.high` for throttling before `memory.max` for hard limits), the PID controller has only a hard limit. A soft-limit tier was considered but deemed unnecessary: PIDs are discrete and cheap, and a gradual approach does not make sense for preventing fork bombs.

## How It Has Evolved

- **4.3 (2015)** — PID controller introduced (Aditya Kali, Google); designed specifically for container fork-bomb prevention
- **5.17 (2022)** — `pids.peak` file added to record the high-water mark

## Further Reading

1. [Control Group v2: PID — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html#pid)
2. [Limiting the number of processes per cgroup — LWN.net](https://lwn.net/Articles/659813/)
