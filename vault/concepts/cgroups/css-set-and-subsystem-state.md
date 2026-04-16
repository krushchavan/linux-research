---
title: "css_set and cgroup_subsys_state"
category: concept
tags: [cgroups, data-structures, task-struct, resource-management, memory-efficiency]
subsystem: cgroups
kernel_version: "2.6.24"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html
  - https://docs.kernel.org/admin-guide/cgroup-v1/cgroups.html
  - http://terenceli.github.io/%E6%8A%80%E6%9C%AF/2020/01/05/cgroup-internlas
  - https://www.schutzwerk.com/en/blog/linux-container-cgroups-04-groups-kernel/
---

# css_set and cgroup_subsys_state

## Purpose

`css_set` and `cgroup_subsys_state` are the data-model spine connecting every task to its resource controllers. Rather than storing each controller's per-task state directly in `task_struct` (which would bloat it by one pointer per controller), the kernel shares a single `css_set` among all tasks that belong to the same combination of cgroups. The `cgroup_subsys_state` (css) is the base class embedded in each controller's per-cgroup structure so the core can treat all controllers uniformly without knowing their internals.

## Mental Model

Imagine a library card catalogue. Each book (task) holds one library card (css_set). The card lists the shelves (cgroup_subsys_states) where the book belongs — one per subject (controller). If two books belong to exactly the same shelves, they share one card, saving cardboard. When a book moves to a new shelf, the catalogue clerk either finds an existing card for the new combination or prints a fresh one.

## How It Works

### The link from task to controllers

`task_struct` contains a single pointer `cgroups` of type `struct css_set *`. This one pointer is all the task needs at runtime; through it the kernel reaches every controller's per-cgroup state in O(1) by indexing `css_set->subsys[subsystem_id]`.

The key insight is **sharing**: every task in the system that belongs to *the same cgroup for every controller* shares a single `css_set` instance. When `fork()` creates a child, `cgroup_fork()` increments the parent's `css_set` reference count and assigns the same pointer to the child. No allocation happens, and `fork()` stays O(1) for cgroup purposes.

### Finding or creating a css_set

When a task migrates to a new cgroup, `cgroup_attach_task()` calls `find_existing_css_set()`. This function computes the new combination of `cgroup_subsys_state` pointers (one per controller, reflecting the new cgroup for the migrated controller and the old cgroups for all others), hashes them, and looks up a global `css_set_table` hash table protected by `css_set_lock`. A match means an existing `css_set` is reused (reference count incremented). No match means a new `css_set` is allocated and inserted.

The hash table lookup is cheap because migrations are infrequent compared to fork and per-cpu operations.

### The M:N relationship

A single `css_set` can span multiple cgroups (one per controller, which may all be different cgroups). A single cgroup can be referenced by multiple `css_set`s (one per distinct combination of tasks in it). This M:N relationship is tracked through `cgrp_cset_link` nodes:

```
css_set ──cgrp_links──> cgrp_cset_link ──cgrp──> cgroup
                                       └──cset──> css_set
cgroup ──cset_links──> cgrp_cset_link  ...
```

Each `cgrp_cset_link` record sits on two linked lists simultaneously: `css_set->cgrp_links` (so the core can find all cgroups a `css_set` spans) and `cgroup->cset_links` (so the core can enumerate all tasks in a cgroup for migration, freezing, or subsystem callbacks).

### cgroup_subsys_state as a base class

Each controller implements a per-cgroup struct that begins with an embedded `cgroup_subsys_state`:

```c
struct mem_cgroup {
    struct cgroup_subsys_state css;   /* must be first */
    struct page_counter memory;
    /* ... mem-specific fields ... */
};
```

This layout lets the core call `css_alloc()` (which returns a `cgroup_subsys_state *`) and then the controller upcasts the pointer to its full struct via `container_of()`. The `cgroup_subsys_state` carries lifecycle information (flags, reference count) that the core manages, while the controller-specific fields remain opaque to the core.

### Reference counting

`css_set` is reference-counted via `refcount_t css_set.refcount`. References are held by:
- Each task pointing to the css_set
- Each `cgrp_cset_link` node

When refcount drops to zero, `put_css_set_locked()` frees the css_set and releases all its `cgroup_subsys_state` references.

`cgroup_subsys_state` uses a *per-cpu* reference count (`percpu_ref`) for performance: hot paths (page allocation, scheduling) can increment the count on their local CPU without cache-line contention. Destruction goes through a slow two-phase process: `percpu_ref_kill()` switches the percpu ref to atomic mode, then an RCU callback fires `css_release()` once all readers have passed a quiescent state.

## Key Data Structures

**`struct css_set`** (`include/linux/cgroup-defs.h`) — shared state for a group of tasks with identical cgroup membership
- `subsys[CGROUP_SUBSYS_COUNT]` — pointers to each controller's `cgroup_subsys_state` for this task; indexed by `cgroup_subsys.id`
- `refcount` — number of tasks using this css_set plus `cgrp_cset_link` refs
- `tasks` — list of tasks using this css_set (non-threaded mode)
- `mg_tasks` — tasks being migrated; separated to avoid iterator interference
- `cgrp_links` — list of `cgrp_cset_link` records, one per cgroup this css_set touches
- `hlist` — node in `css_set_table` hash table for O(1) lookup
- `dfl_cgrp` — in v2 unified hierarchy, the single cgroup this css_set belongs to

**`struct cgroup_subsys_state`** (`include/linux/cgroup-defs.h`) — base class for all per-cgroup controller state
- `cgroup` — the cgroup this state belongs to
- `ss` — pointer back to the `cgroup_subsys` descriptor; NULL for the "core" css
- `refcnt` — per-cpu reference count; protects the css from premature destruction
- `flags` — `CSS_NO_REF`, `CSS_ONLINE`, `CSS_DYING`, `CSS_VISIBLE`
- `parent` — parent css; allows hierarchy traversal without accessing the full cgroup
- `serial_nr` — monotonically increasing ID used to order css events and migrations

**`struct cgrp_cset_link`** (`kernel/cgroup/cgroup.c`) — one record per (css_set, cgroup) pair
- `cgrp` — the cgroup
- `cset` — the css_set
- `cset_link` — list node in `css_set->cgrp_links`
- `cgrp_link` — list node in `cgroup->cset_links`

## Key Functions / Entry Points

**`css_set_get()` / `put_css_set()`** — increment/decrement reference count

**`find_existing_css_set()`** (`kernel/cgroup/cgroup.c`) — hash lookup for a css_set matching a given combination of cgroup_subsys_states; returns NULL if not found

**`cgroup_fork()`** (`kernel/cgroup/cgroup.c`) — called by `fork()`; takes a reference on the parent's css_set and assigns it to the child

**`cgroup_exit()`** (`kernel/cgroup/cgroup.c`) — called on task exit; drops the css_set reference; invokes controller `exit` callbacks

**`cgroup_task_migrate()`** (`kernel/cgroup/cgroup.c`) — swaps a task's css_set pointer after `cgroup_attach_task()` validated the move

**`css_get()` / `css_put()`** — manage references to a `cgroup_subsys_state`; `css_put()` may trigger the RCU-based teardown path

## Important Flags & Config Options

- `CSS_ONLINE` — the css is visible in the hierarchy and controllers can use it
- `CSS_DYING` — the parent cgroup directory was removed; no new references allowed
- `CSS_NO_REF` — this css type uses a simple atomic refcount instead of percpu_ref (for lightweight controllers)
- `CGRP_SUBSYS_COUNT` — compile-time constant giving the number of registered controllers; determines the array size in `css_set`

## Interactions with Other Subsystems

- **↑ Userspace**: transparent; userspace sees only cgroup directories and interface files, not css_sets
- **→ [[cgroup-core]]**: the core manages css_set creation, lookup, and lifecycle; individual controllers do not interact with css_sets directly
- **→ All controllers**: each controller embeds `cgroup_subsys_state` at the start of its per-cgroup struct; the core allocates and frees via `css_alloc`/`css_free` callbacks
- **← task_struct**: `task_struct.cgroups` holds the one pointer that binds a task to all its controllers

## Design Decisions & Tradeoffs

**Sharing css_sets** trades migration complexity for fork/lookup efficiency. The hash table lookup during migration is O(1) amortized but requires `css_set_lock`. In workloads with frequent fork and rare migration (containers), the tradeoff is favorable. In workloads with frequent migration (some job schedulers), the hash table can become a contention point.

**percpu_ref for css** makes controller hot paths (e.g. `mem_cgroup_charge()` on every page fault) nearly free from a reference-counting perspective: incrementing a per-cpu counter requires only a local cache-line write. The cost is a more complex two-phase destruction protocol.

**Opaque css via container_of** allows the core to manage lifetimes uniformly without knowing controller internals. This is a classic C "object-oriented" pattern. The requirement that `cgroup_subsys_state` be the *first* member of the controller struct is a fragile constraint — if any controller accidentally reorders its struct, the `container_of` cast silently produces wrong results. Kernel convention enforces this through code review rather than compiler checks.

## How It Has Evolved

- **v1 (2.6.24)** — original design; css_set was called `struct css_set` from the start, with the hash table optimization for sharing
- **v2 / unified hierarchy (4.5)** — `dfl_cgrp` field added; in unified hierarchy a task belongs to exactly one cgroup, simplifying the M:N relationship
- **percpu_ref (3.11, 2013)** — `cgroup_subsys_state.refcnt` migrated from simple `atomic_t` to `percpu_ref` to eliminate cache-line contention in high-fork workloads
- **threaded cgroups (4.14)** — `mg_tasks` and `dying_tasks` lists added to css_set to support per-thread cgroup membership within a domain subtree

## Further Reading

1. [Control groups v1 internals — kernel.org](https://docs.kernel.org/admin-guide/cgroup-v1/cgroups.html)
2. [cgroups internals blog post — terenceli.github.io](http://terenceli.github.io/%E6%8A%80%E6%9C%AF/2020/01/05/cgroup-internlas)
3. [Container security fundamentals part 4: Cgroups — Datadog](https://securitylabs.datadoghq.com/articles/container-security-fundamentals-part-4/)
