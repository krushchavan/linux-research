---
title: "Cgroup Core"
category: concept
tags: [cgroups, hierarchy, kernfs, process-management, resource-management]
subsystem: cgroups
kernel_version: "2.6.24"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html
  - https://lwn.net/Articles/679786/
  - https://lwn.net/Articles/594844/
  - http://terenceli.github.io/%E6%8A%80%E6%9C%AF/2020/01/05/cgroup-internlas
---

# Cgroup Core

## Purpose

The cgroup core is the substrate on which all resource controllers are built. It maintains the hierarchical tree of cgroup nodes, manages process membership (which task lives in which group), enforces the structural rules of the v2 unified hierarchy, and exposes the entire system to userspace as a pseudo-filesystem backed by kernfs. Without the core, individual resource controllers would have no shared notion of where a process sits.

## Mental Model

Think of the cgroup core as a tree of rooms in a building. Each room is a cgroup. Moving a process into a room places it under that room's rules. The building manager (the core) tracks which person is in which room, ensures the floor plan makes sense, and handles the paperwork when people move. The controllers — CPU, memory, I/O — are the air conditioning, power, and water systems wired to each room; they follow the building's layout but are otherwise independent of each other.

## How It Works

### Boot-time initialization

The cgroup core initializes in two phases. `cgroup_init_early()` runs as the kernel starts: it allocates `cgrp_dfl_root` (the single root of the v2 unified hierarchy), creates the root cgroup `cgrp_dfl_root.cgrp`, and attaches `init_css_set` — the shared controller-state set for all tasks that haven't been explicitly placed anywhere — to `init_task` (pid 1). This means every process in the system is always a member of some cgroup, even before any cgroupfs is mounted.

`cgroup_init()` runs after early boot: it registers the `cgroup2` filesystem type, initializes per-subsystem files (the `cgroup.controllers`, `cgroup.procs`, and `cgroup.subtree_control` files that appear in every directory), and calls `cgroup_setup_root()` to finalize the root cgroup's kernfs representation.

### Directory structure via kernfs

Each cgroup is backed by a kernfs node (`struct kernfs_node`, referenced through `cgroup->kn`). When userspace calls `mkdir` under `/sys/fs/cgroup`, the VFS routes it to `cgroup_mkdir()`. This function:

1. Allocates a new `struct cgroup` and links it to its parent via `cgroup->parent`
2. Calls `css_alloc()` on each controller currently enabled in the parent's `subtree_control` bitmask, giving each controller a chance to allocate per-cgroup state
3. Creates a kernfs directory node and populates it with the standard interface files
4. Publishes the new cgroup by setting `CSS_ONLINE` on each created `cgroup_subsys_state`

Similarly, `cgroup_rmdir()` fires when the directory is removed. It refuses if the cgroup still contains tasks or child directories. It calls `css_offline()` and then `css_free()` on each controller in reverse order.

### Process attachment

Moving a process requires writing its PID to `cgroup.procs`. The VFS write reaches `cgroup_procs_write()`, which calls `cgroup_attach_task()`. The attach sequence:

1. **Validate** the target cgroup: verify the caller has write permission, that the cgroup is not frozen, and crucially enforce the **no-internal-process rule** — a non-leaf cgroup (one with active controllers on its `subtree_control`) cannot hold tasks. This prevents parent tasks from competing in a controller's view against their child cgroup's tasks.

2. **Find or create a css_set**: `find_existing_css_set()` looks up a global hash table keyed on the new combination of `cgroup_subsys_state` pointers. If a matching `css_set` already exists (because another task lives in the same combination of cgroups), it is reused. Otherwise a new one is allocated. Reuse is the common case; it keeps memory and `fork()` overhead low.

3. **Swap the task's css_set pointer** under RCU and update the linked lists (`css_set->tasks`, `cgrp_cset_link`) so each controller can enumerate all tasks in its cgroup.

4. **Invoke controller callbacks**: each controller's `attach()` callback runs so it can update scheduling, accounting, or affinity state.

5. **Notify**: `cgroup.events` (if monitored) is updated; perf/tracing hooks fire.

### Controller enablement

Writing `+memory` to `cgroup.subtree_control` calls `cgroup_subtree_control_write()`. The core validates that the parent has the controller available (it must appear in `cgroup.controllers`), then propagates downward: every cgroup in the subtree gets a `css_alloc()` call for the newly enabled controller. Disabling a controller calls `css_offline()` and `css_free()` down the tree. This propagation is why the no-internal-process rule matters: if a cgroup held tasks during propagation, the controller would see tasks without a valid per-cgroup state.

### Locking strategy

The cgroup core uses a combination of:
- `cgroup_mutex` — a global mutex serializing structural operations (mkdir, rmdir, enabling controllers, bulk migrations)
- `css_set_lock` — a spinlock protecting `css_set` reference counts and task-to-css-set mappings
- RCU — for read-side access to task→css_set pointers, allowing fast lockless controller lookups on the hot path

## Key Data Structures

**`struct cgroup`** (`include/linux/cgroup-defs.h`) — represents one node in the hierarchy
- `self` — embedded `cgroup_subsys_state`; the core's own per-cgroup state
- `root` — pointer to the owning `cgroup_root`
- `parent` — parent cgroup; NULL at the root
- `children` — list of direct children
- `cset_links` — set of `cgrp_cset_link` records linking this cgroup to all `css_set`s with tasks here
- `subtree_control` — bitmask of controllers enabled for direct children
- `subtree_ss_mask` — union of all controllers in this subtree
- `kn` — kernfs node (the directory)
- `flags` — `CGRP_NOTIFY_ON_RELEASE`, `CGRP_CPUSET_CLONE_CHILDREN`, `CGRP_FREEZE`, `CGRP_FROZEN`

**`struct cgroup_root`** (`include/linux/cgroup-defs.h`) — the root of a hierarchy
- `cgrp` — the embedded root cgroup
- `subsys_mask` — bitmask of controllers bound to this hierarchy
- `flags` — `CGRP_ROOT_NOPREFIX`, `CGRP_ROOT_XATTR`

**`struct cgroup_subsys`** (`include/linux/cgroup-defs.h`) — per-controller descriptor (one global instance per controller)
- `css_alloc` / `css_free` — lifecycle callbacks
- `css_online` / `css_offline` — visibility callbacks
- `attach` — task-migration callback
- `fork` / `exit` — task lifecycle hooks
- `id` — subsystem index into `css_set.subsys[]`

## Key Functions / Entry Points

**`cgroup_init_early()`** (`kernel/cgroup/cgroup.c`) — called at kernel start; allocates root and init_css_set

**`cgroup_init()`** (`kernel/cgroup/cgroup.c`) — called after early boot; registers cgroupfs and finalizes root

**`cgroup_mkdir()`** (`kernel/cgroup/cgroup.c`) — VFS mkdir; creates a child cgroup

**`cgroup_rmdir()`** (`kernel/cgroup/cgroup.c`) — VFS rmdir; destroys an empty cgroup

**`cgroup_attach_task()`** (`kernel/cgroup/cgroup.c`) — migrates a task; finds/creates css_set, updates lists, invokes callbacks

**`cgroup_procs_write()`** (`kernel/cgroup/cgroup.c`) — handles writes to `cgroup.procs`; top-level entry point for task migration

**`cgroup_subtree_control_write()`** (`kernel/cgroup/cgroup.c`) — handles writes to `cgroup.subtree_control`; enables/disables controllers

**`css_alloc()` / `css_free()`** — controller callbacks invoked by the core; each controller defines these

## Important Flags & Config Options

- `CONFIG_CGROUPS` — enables the cgroup core; required by all controllers
- `CONFIG_CGROUP_DEBUG` — adds debug information to the cgroupfs interface
- `CGRP_FREEZE` — cgroup is being frozen (written to `cgroup.freeze`)
- `CGRP_FROZEN` — all tasks in the cgroup are suspended
- `CSS_ONLINE` — controller state is live and visible in the hierarchy
- `CSS_DYING` — state is being torn down; new references should fail

## Interactions with Other Subsystems

- **↑ Userspace**: `mkdir`/`rmdir` under `/sys/fs/cgroup`, writes to `cgroup.procs` and `cgroup.subtree_control`, reads from `cgroup.controllers` and `cgroup.events`
- **→ kernfs**: uses kernfs for the filesystem interface; all per-cgroup files are kernfs nodes with custom read/write callbacks
- **→ Controllers (memory, CPU, I/O, PID, cpuset)**: invokes `css_alloc`, `css_online`, `css_offline`, `css_free`, `attach`, `fork`, `exit` callbacks
- **← Namespaces**: `cgroupns` (`kernel/cgroup/namespace.c`) provides a per-namespace view of the hierarchy; `nsenter --cgroup` rebases a process to a subtree root
- **← Task scheduler**: `sched_move_task()` is called from `cgroup_attach_task()` to update the scheduler's view of group membership

## Design Decisions & Tradeoffs

**Unified hierarchy** — v2 mandates a single hierarchy; all controllers share one tree. This was the biggest design break from v1, where each controller could be mounted independently on its own hierarchy. The single hierarchy allows the core to authoritatively answer "which cgroup does process P belong to?" — in v1, the answer was controller-dependent and potentially contradictory.

**No-internal-process rule** — Non-leaf cgroups with active controllers cannot hold tasks. This sounds restrictive, but it eliminates "internal competition": in v1, tasks at an internal node competed directly against child cgroups, which controllers handled inconsistently. By restricting tasks to leaves, the tree's resource allocation semantics become fully predictable.

**kernfs instead of direct VFS** — The cgroup core uses kernfs rather than implementing a full pseudo-filesystem. kernfs handles the low-level inode/dentry/file operations; the cgroup code provides only the higher-level create/delete/read/write callbacks. This was introduced in 3.14 to fix deep VFS locking issues that plagued v1.

## How It Has Evolved

- **2.6.24 (2008)** — Paul Menage's original cgroup patch; core plus cpuset, memory, CPU controllers
- **3.14 (2014)** — kernfs extraction (Tejun Heo); cgroup core ported to use kernfs, eliminating VFS locking issues
- **3.16 (2014)** — unified hierarchy prototype merged; single hierarchy with `cgroup.subtree_control` semantics
- **4.5 (2016)** — cgroup v2 API declared stable
- **4.14 (2017)** — threaded cgroups: allows threads of a single process to reside in different cgroups within a domain subtree
- **5.2 (2019)** — `cgroup.freeze` added to the core; cgroup freezer integrated from its own v1 controller

## Further Reading

1. [Control Group v2 — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
2. [Understanding the new control groups API — LWN.net](https://lwn.net/Articles/679786/)
3. [The unified control group hierarchy in 3.16 — LWN.net](https://lwn.net/Articles/601840/)
4. [The past, present, and future of control groups — LWN.net](https://lwn.net/Articles/574317/)

## LKML Highlights

- **Unified hierarchy v2 patchset cover letter** — Tejun Heo introduced the unified hierarchy as a solution to the four fundamental problems of v1: membership ambiguity, controller coordination, process-thread fragmentation, and internal task competition.
