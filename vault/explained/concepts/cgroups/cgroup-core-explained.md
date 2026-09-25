---
title: "Cgroup Core — Explained"
category: explained
original: "[[cgroup-core]]"
subsystem: cgroups
tags: [explained, cgroups, hierarchy, kernfs]
converted: 2026-09-25
---

# The cgroup core, explained

> Plain-language companion to [[cgroup-core|the technical note]]. Same facts, fewer identifiers.

## The problem

[[cgroups-explained|cgroups]] has many resource controllers (memory, CPU, I/O, PIDs, cpuset), and each needs to know which process belongs to which group, and to be told when groups appear and disappear or when processes move. If every controller kept its own idea of the tree, a process could sit in different places for different controllers (exactly what went wrong in v1) and nothing would stop the structure from becoming inconsistent.

Something has to own the tree itself: its shape, its membership rules, how it looks to user space, and the order in which controllers are told about changes.

## The idea in one paragraph

The core is the **building manager** of a building made of rooms. Each room is a cgroup; putting a person (process) in a room places them under that room's rules. The manager tracks who's in which room, keeps the floor plan sensible, and handles the paperwork when people move. The controllers are like the air conditioning, power and water: each follows the building's layout, but otherwise works independently.

## Step by step

### Step 1: Boot with everyone already placed
Very early in boot, the core creates the single root of the v2 hierarchy and a shared state bundle for tasks not placed anywhere else, and gives it to the first process. Every process is therefore always in *some* cgroup, even before the cgroup filesystem is mounted. Later in boot, the core registers the `cgroup2` filesystem type and sets up the files that appear in every group directory (available controllers, member processes, controllers enabled for children).

### Step 2: Groups are directories
Each cgroup is backed by a node in **kernfs**, a small reusable pseudo-filesystem layer. `mkdir` under `/sys/fs/cgroup` creates a cgroup:
1. allocate it and link it to its parent
2. ask each controller enabled for the parent's children to set up its per-group state
3. create the directory and fill it with the standard files
4. mark each controller's state as online

`rmdir` refuses while the group still has processes or child groups; otherwise controllers are told to go offline and then free their state, in reverse order.

### Step 3: Moving a process
Writing a process ID into a group's process-list file moves it:
1. **Validate:** the caller may write here, the group isn't frozen, and the **no-internal-process rule** holds (see below).
2. **Find or make a state bundle:** look up the bundle for the new combination of per-controller states in a global hash table, and reuse it if another task already has that combination (the common case), otherwise create one.
3. **Swap** the task's bundle pointer under RCU, and update the lists that let each controller enumerate its group's tasks.
4. **Tell controllers:** each controller's attach hook updates scheduling, accounting or affinity. The scheduler, for instance, is told the task changed group.
5. **Notify:** the group's event file is updated, and tracing hooks fire.

### Step 4: The no-internal-process rule
This is the key rule of v2. A group that has controllers turned on for its children may not hold processes itself. In v1, processes in an inner group competed directly against its child groups, and each controller handled that differently. Allowing processes only in leaves makes resource splitting fully predictable. It also matters for the next step: while a controller is being switched on down a subtree, a group holding processes would have tasks the controller has no state for.

### Step 5: Turning controllers on and off
Writing "+memory" to a group's children-controllers file first checks that the parent actually has memory available, then walks down the subtree asking the memory controller to set up state in every group. Writing "-memory" walks down taking it offline and freeing it.

### Step 6: Locking
- one global mutex serialises structural changes (mkdir, rmdir, enabling controllers, bulk moves)
- a spinlock protects bundle reference counts and task-to-bundle links
- RCU lets hot paths read a task's bundle, and so find its controllers' state, without locks

## The picture

```text
 /sys/fs/cgroup                (root, v2 single hierarchy)
 ├─ system.slice   [children get: memory, cpu]   ← no processes here
 │   ├─ nginx.service   pids: 812 813            ← processes only in leaves
 │   └─ sshd.service    pids: 640
 └─ user.slice ...

 echo 812 > app/cgroup.procs:
   validate → find/create bundle → swap pointer (RCU) → controllers' attach hooks → events
```

## Tradeoffs

- **What it gives you:** one authoritative answer to "which group is this process in?", a predictable structure, a familiar directory interface, and cheap lookups on hot paths.
- **What it costs / requires:** a global mutex for structural changes, and sometimes artificial leaf groups just to satisfy the no-internal-process rule.
- **Where it bites:** tools written for v1's per-controller hierarchies had to be reworked for the single tree, and the rule surprises people who try to put processes in a parent group.

## How it got here

- **2.6.24 (2008):** Paul Menage's original cgroups, with cpuset, memory and CPU controllers.
- **3.14 (2014):** kernfs extracted (Tejun Heo) and the core ported onto it, fixing deep VFS locking problems that plagued v1.
- **3.16 (2014):** the unified hierarchy prototype with controllers enabled per subtree. **4.5 (2016):** v2 declared stable.
- **4.14 (2017):** threaded groups, letting threads of one process sit in different groups inside a domain subtree.
- **5.2 (2019):** freezing moved into the core.

## Related

- Technical version: [[cgroup-core]]
- [[cgroups-explained|cgroups]], [[css-set-and-subsystem-state-explained|Shared state bundles]], [[cgroup-freezer-explained|Freezer]], [[cgroup-bpf-explained|cgroup BPF]]
- [[io-controller|I/O controller]], [[pid-controller|PID controller]], [[cpuset-controller-explained|cpuset]], [[memcg-explained|Memory cgroups]]
- [[fs-explained|Filesystem subsystem (VFS)]], [[rcu-read-copy-update|RCU]]
