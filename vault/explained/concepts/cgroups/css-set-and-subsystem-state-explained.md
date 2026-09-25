---
title: "css_set and cgroup_subsys_state — Explained"
category: explained
original: "[[css-set-and-subsystem-state]]"
subsystem: cgroups
tags: [explained, cgroups, data-model, reference-counting]
converted: 2026-09-25
---

# How tasks are linked to cgroup controllers, explained

> Plain-language companion to [[css-set-and-subsystem-state|the technical note]]. Same facts, fewer identifiers.

## The problem

Every task must be able to reach each [[cgroups-explained|cgroup]] controller's state for the group it's in: the memory controller on every page fault, the scheduler on every scheduling decision. The obvious design, one pointer per controller in every task, bloats every task and makes `fork` slower with each controller compiled in.

The kernel core also has to create, find and destroy each controller's per-group state without knowing what's inside it, and reference counting on these hot paths mustn't turn into a contention point across CPUs.

## The idea in one paragraph

Use a **shared library card**. Each task (book) holds exactly one card listing its shelf for every subject (controller). Books that sit on exactly the same shelves **share one card**. When a book moves, the clerk looks for an existing card with the new combination and prints a new one only if none exists. Every controller's per-group structure also starts with the same small common header, so the core can manage them all identically without knowing their contents.

## Step by step

### Step 1: One pointer per task
A task holds a single pointer to its shared **bundle** (the card). The bundle holds an array with one entry per controller, pointing to that controller's state for the task's group. Any controller's state is reached with one lookup by controller number.

### Step 2: Sharing, and cheap forks
This is the key idea. All tasks in exactly the same group for every controller share one bundle. On `fork`, the child simply takes another reference to its parent's bundle: no allocation, no searching, constant cost.

### Step 3: Moving a task
When a task moves, the kernel builds the new combination (the new group's state for the moving controllers, the old states for the rest), hashes it, and looks it up in a global table under a lock. A match is reused with its count raised; otherwise a new bundle is made and added. Moves are rare compared with forks, so the lookup cost is fine.

### Step 4: The many-to-many links
One bundle can span several groups (in general, one per controller), and one group can be used by many bundles (one per distinct combination of tasks in it). Small link records connect them. Each link sits on two lists at once, one on the bundle and one on the group, so the core can find every group a bundle touches and every task in a group (to move, freeze or notify them).

### Step 5: A common header for every controller
Each controller's per-group structure begins with the same **state header**: which group it belongs to, which controller, a reference count, flags (online, dying, visible), a parent pointer and a serial number. The core allocates and frees states through controller callbacks and only ever touches the header; the controller converts the header pointer back into its full structure. The header must come first, and nothing but code review enforces that, so reordering a controller's structure would silently break the conversion.

### Step 6: Reference counting without contention
- Bundles use an ordinary reference count held by each task and each link. When it hits zero, the bundle is freed and its references to controller states dropped.
- Controller states use a **per-CPU reference count**, so hot paths (charging a page on a fault, scheduling) only touch their own CPU's counter. Tearing one down takes two phases: switch the counter to a single shared atomic, then free the state from an RCU callback once all readers are done.

## The picture

```text
 task A ─┐                    ┌─▶ memory state  (group /app)
 task B ─┼─▶ shared bundle ───┼─▶ CPU state     (group /app)
 task C ─┘   (refcount 3+links)└─▶ PIDs state   (group /app)

 move task C to /batch for all controllers:
   hash(new combination) → found? reuse : create → C points at new bundle

 controller state = [ common header | controller's own fields … ]
                      ▲ core only touches this part
```

## Tradeoffs

- **What it gives you:** one pointer per task, constant-cost forks, one-step access to any controller's state, uniform lifetime management, and nearly free reference counting on hot paths.
- **What it costs / requires:** more complex moves (hash lookup under a lock) and a two-phase teardown for per-CPU counts.
- **Where it bites:** in workloads that move tasks between groups very often (some job schedulers), the global table's lock can become a contention point. The "header first" rule is fragile.

## How it got here

- **2.6.24 (2008):** the original design, with shared bundles and hash-table lookup from the start.
- **3.11 (2013):** controller state reference counts became per-CPU, removing contention in fork-heavy workloads.
- **4.5 (v2):** in the unified hierarchy each task is in exactly one group, and bundles record it, simplifying the many-to-many picture.
- **4.14:** lists for migrating and dying tasks added to support threaded groups.

## Related

- Technical version: [[css-set-and-subsystem-state]]
- [[cgroups-explained|cgroups]], [[cgroup-core-explained|cgroup core]], [[memcg-explained|Memory cgroups]]
- [[rcu-read-copy-update-explained|RCU]]
