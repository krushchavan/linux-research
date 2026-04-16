---
title: "Cgroup Freezer"
category: concept
tags: [cgroups, freezer, checkpoint-restore, process-suspension, containers]
subsystem: cgroups
kernel_version: "2.6.29"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html
  - https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v1/freezer-subsystem.html
  - https://lwn.net/Articles/679786/
---

# Cgroup Freezer

## Purpose

The cgroup freezer allows all processes in a cgroup subtree to be suspended atomically, without sending SIGSTOP to individual processes. This is used by container runtimes for live migration (CRIU checkpointing a frozen container), by job schedulers to pause low-priority batches while high-priority work runs, and by security tools performing forensic inspection of a container's state without risk of the container continuing to execute.

## Mental Model

The freezer is a pause button for an entire group of processes. Unlike SIGSTOP (which a process can catch, ignore with careful signal handling, or which leaves it interruptible), the kernel-level freeze puts tasks into `TASK_FROZEN` at kernel-user boundaries — the exact points where it is safe to pause without leaving kernel data structures in a half-completed state.

## How It Works

### Initiating a freeze

In cgroup v2, freeze and thaw are controlled via the `cgroup.freeze` file (a simple `0`/`1` toggle) and reported via `cgroup.events` (`frozen 1` when all tasks are suspended). In v1 there was a separate `freezer` controller with a `freezer.state` file.

Writing `1` to `cgroup.freeze` calls `cgroup_freeze()`, which:
1. Sets `CGRP_FREEZE` on the cgroup.
2. Calls `cgroup_for_each_live_descendant_pre()` to walk all descendant cgroups and set `CGRP_FREEZE` on each.
3. Iterates all tasks via `css_task_iter` and calls `cgroup_freeze_task()` on each.

`cgroup_freeze_task()` marks the task for freezing by setting `TIF_NOTIFY_SIGNAL` (or a similar mechanism) and calling `wake_up_process()` to ensure the task is scheduled soon, so it can reach the freeze point.

### Reaching TASK_FROZEN

Tasks do not freeze immediately — they freeze at the next safe kernel-user boundary. The freeze point is in `task_work_run()` or `get_signal()`, called when returning to userspace after a syscall or interrupt. At that point the task notices `CGRP_FREEZE` is set on its cgroup and calls `cgroup_enter_frozen()`, which:
1. Sets `task->frozen = true`.
2. Changes the task's state to `TASK_FROZEN`.
3. Calls `schedule()`, voluntarily yielding the CPU.

The task will not run again until it is explicitly unfrozen.

### State machine

The cgroup tracks three internal states:
- **THAWED**: `cgroup.freeze = 0`, all tasks running normally
- **FREEZING**: `cgroup.freeze = 1` but some tasks have not yet reached their freeze point
- **FROZEN**: all tasks are in `TASK_FROZEN`; reported as `frozen 1` in `cgroup.events`

`cgroup_update_frozen()` is called each time a task enters or leaves `TASK_FROZEN`. It counts frozen vs. non-frozen tasks in the subtree and transitions between states accordingly. The `cgroup.events` file notifies watchers (via poll/inotify) when the cgroup becomes fully frozen.

### Inheritance for new tasks

If a new task is forked inside a freezing or frozen cgroup, `cgroup_fork()` checks `CGRP_FREEZE` and calls `cgroup_freeze_task()` on the new child immediately. This prevents a race where a container runtime forks a helper process into a "frozen" container and accidentally unfreezes it.

### Thawing

Writing `0` to `cgroup.freeze` calls `cgroup_freeze()` with `freeze=false`. This clears `CGRP_FREEZE` on the cgroup and all descendants, then calls `cgroup_wake_frozen_tasks()` which iterates tasks in `TASK_FROZEN` and wakes them with `wake_up_process()`. Tasks re-enter the run queue and resume from their freeze point.

### Hierarchy semantics

Freeze is hierarchical: freezing a parent freezes all descendants. A child cgroup cannot be thawed while its parent is frozen (the parent's `CGRP_FREEZE` overrides). This ensures that operators can freeze a container subtree as a unit without worrying about child cgroups escaping the freeze.

## Key Data Structures

The freezer uses no dedicated per-cgroup struct in v2 — state is stored in `struct cgroup` directly:
- `cgroup.flags` — `CGRP_FREEZE` (freeze requested) and `CGRP_FROZEN` (fully frozen)
- `task_struct.frozen` — bool; true when the task is in `TASK_FROZEN` state

## Key Functions / Entry Points

**`cgroup_freeze()`** (`kernel/cgroup/cgroup.c`) — top-level entry; sets CGRP_FREEZE on the cgroup and all descendants, then calls cgroup_freeze_task() on all tasks

**`cgroup_freeze_task()`** (`kernel/cgroup/cgroup.c`) — schedules a task for freezing by triggering a TIF notification that will be processed at the next kernel-user boundary

**`cgroup_enter_frozen()`** (`kernel/cgroup/cgroup.c`) — called by a task at the freeze point; sets `task->frozen`, transitions to `TASK_FROZEN`, and schedules

**`cgroup_update_frozen()`** (`kernel/cgroup/cgroup.c`) — called on every freeze/thaw event; counts frozen tasks and updates `cgroup.events`

**`cgroup_wake_frozen_tasks()`** (`kernel/cgroup/cgroup.c`) — iterates frozen tasks and calls `wake_up_process()` during thaw

## Important Flags & Config Options

- `CONFIG_CGROUPS` — the freezer is part of the cgroup core in v2; no separate Kconfig needed
- `CONFIG_CGROUP_FREEZER` — enables the v1 standalone freezer controller (deprecated in favour of v2 core integration)
- `cgroup.freeze` — write `1` to freeze, `0` to thaw
- `cgroup.events` — read-only; `frozen 1` when fully frozen, `frozen 0` otherwise

## Interactions with Other Subsystems

- **↑ Userspace**: CRIU (Checkpoint/Restore In Userspace) writes `cgroup.freeze = 1`, waits for `frozen 1` in `cgroup.events`, checkpoints the process state, then restores on the target machine; container runtimes use the same pattern for pause/resume
- **→ Scheduler**: tasks in `TASK_FROZEN` are removed from the runqueue by `schedule()`; the scheduler treats them like tasks in `TASK_UNINTERRUPTIBLE` for load-balancing purposes
- **← [[cgroup-core]]**: freeze state is stored on `struct cgroup`; the `fork` callback ensures new tasks inherit the freeze

## Design Decisions & Tradeoffs

**Freezing at kernel-user boundaries** rather than immediately was a deliberate choice for correctness. Stopping a task mid-syscall would leave kernel locks held and data structures half-updated. By waiting until the task is about to return to userspace, the freeze is always in a clean state that can be safely checkpointed or inspected.

**`TASK_FROZEN` vs. SIGSTOP** — SIGSTOP can be caught during signal delivery in certain states, and some processes install signal handlers that complicate reliable stopping. `TASK_FROZEN` is a kernel-internal state that userspace cannot interfere with.

**Integration into the cgroup core (v2)** rather than a separate controller simplifies the mental model and removes the need to enable a dedicated controller. In v1, the `freezer` controller had to be mounted separately, and operators sometimes forgot to mount it.

## How It Has Evolved

- **2.6.29 (2009)** — cgroup freezer introduced as a standalone v1 controller
- **5.2 (2019)** — `cgroup.freeze` and `cgroup.events` added to cgroup v2 core; the standalone v1 freezer controller deprecated for v2 use
- **`TASK_FROZEN` state** — introduced to distinguish kernel-requested freezing (freezer, hibernation) from user-requested stopping (SIGSTOP), enabling cleaner interaction with power management

## Further Reading

1. [Control Group v2: core interface — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html#core-interface-files)
2. [Cgroup Freezer v1 documentation — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v1/freezer-subsystem.html)
3. [CRIU and cgroup freezer — criu.org](https://criu.org/Cgroups)
