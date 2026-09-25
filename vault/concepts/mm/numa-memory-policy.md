---
title: "NUMA Memory Policy"
category: concept
tags: [numa, memory-policy, mempolicy, allocation, numa-balancing]
subsystem: mm
kernel_version: "2.6.7"
researched: 2026-04-12
status: complete
explained: "[[numa-memory-policy-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/mm/numa_memory_policy.html
  - https://www.kernel.org/doc/Documentation/vm/numa_memory_policy.txt
  - https://lwn.net/Articles/862707/
  - https://lwn.net/Articles/254445/
  - https://lwn.net/Articles/486858/
  - https://lwn.net/Articles/523065/
  - https://lwn.net/Articles/973964/
  - https://github.com/torvalds/linux/blob/master/include/linux/mempolicy.h
  - https://github.com/torvalds/linux/blob/master/mm/mempolicy.c
---

# NUMA Memory Policy

> 📘 Plain-language version: [[numa-memory-policy-explained]]

## Purpose

On NUMA (Non-Uniform Memory Access) systems, memory attached to one processor socket is cheaper to access from that socket's CPUs than from remote CPUs across an interconnect. Without explicit guidance, the kernel may place pages on any node, causing a process's threads to pay remote-access penalties for much of their working set. The NUMA memory policy subsystem provides a hierarchy of controls — from per-process down to per-VMA — that let both applications and administrators express allocation preferences, so that the kernel can satisfy requests from the nodes most likely to deliver low-latency access.

## Mental Model

Think of NUMA memory policy as a four-layer decision tree that the allocator walks from bottom to top. When a page fault triggers an allocation, the kernel checks the innermost policy first (the VMA's policy), then the thread's policy, then the system-wide default. At each level it either commits to a node set or says "nothing here, try the next level up." The policy itself never moves pages — it only governs *where* new pages are born. Moving existing pages to improve locality is a separate mechanism (NUMA balancing, `mbind()` with `MPOL_MF_MOVE`).

## How It Works

### The Policy Hierarchy

Every allocation begins at the bottom of a four-rung ladder:

1. **System default** — the kernel's own hard-coded policy. Normally `MPOL_LOCAL` (allocate from the node the running CPU belongs to). During early boot the system uses `MPOL_INTERLEAVED` across all nodes so that kernel data structures are spread evenly before any per-CPU locality is established.
2. **Task policy** — installed by `set_mempolicy(2)`. Applies to the calling thread and inherited by children across `fork()` and `exec()`. Lives in `task_struct->mempolicy`.
3. **VMA policy** — installed by `mbind(2)` on a virtual address range. Overrides the task policy for anonymous pages in that range. Lives as a red-black tree of `vm_policy_node` entries hanging off the VMA. Inherited across `fork()` but *not* across `exec()` (the address space is replaced).
4. **Shared policy** — a special form of VMA policy for `shmfs`/`tmpfs` objects. All tasks that attach to the shared memory object share one policy tree, not a per-task copy.

The allocator finds the effective policy by calling `get_vma_policy()` (which checks the VMA then falls back to the task), and then calls `mpol_node_array()` on the result to get the concrete nodemask to allocate from.

### struct mempolicy

The unit of policy is `struct mempolicy` (`include/linux/mempolicy.h`):

```c
struct mempolicy {
    atomic_t        refcnt;     /* shared, so ref-counted */
    unsigned short  mode;       /* MPOL_* mode */
    unsigned short  flags;      /* MPOL_F_* modifier flags */
    nodemask_t      nodes;      /* allowed/preferred node set */
    int             home_node;  /* for MPOL_BIND / MPOL_PREFERRED_MANY */
    union {
        nodemask_t  cpuset_mems_allowed;  /* relative mode: allowed mask at install time */
        nodemask_t  user_nodemask;        /* static mode: original user mask */
    } w;
    struct rcu_head rcu;
};
```

The `mode` encodes *what to do*; `nodes` encodes *where*; and `flags` modifies how `nodes` is interpreted as cpusets change.

### Allocation Modes

**`MPOL_DEFAULT`** is the identity element: it means "no policy at this level, consult the next level up." Setting the task policy to `MPOL_DEFAULT` removes the task policy entirely. Setting a VMA policy to `MPOL_DEFAULT` removes that VMA's policy.

**`MPOL_PREFERRED`** attempts to allocate from a single preferred node stored in `home_node`. If that node cannot satisfy the request, the allocator falls back to other nodes in order of increasing NUMA distance. This is the mode to use when one node is slightly preferred but availability matters more than strict locality.

**`MPOL_PREFERRED_MANY`** (added in 5.15) extends the preferred semantics to a *set* of nodes. All nodes in `nodes` are treated as equally preferred; the kernel falls back to the rest of the system only when none of the preferred nodes can satisfy the request. This was introduced to express "allocate from any high-bandwidth memory node" on heterogeneous-memory platforms without risking the hard failure of `MPOL_BIND`.

**`MPOL_BIND`** is strict: memory must come from the nodemask or the allocation fails (and triggers reclaim). Within the allowed set the allocator picks the closest node with free pages. Use this when correctness depends on locality (e.g., a realtime thread must not pay unbounded remote latency).

**`MPOL_INTERLEAVED`** distributes allocations round-robin across the specified nodes on a page-by-page basis. Each task has a `numa_next_node` cursor that advances mod the size of the nodeset. This trades peak bandwidth for balanced utilisation and predictable worst-case latency — useful for workloads with no natural locality (large shared hash tables, kernel boot).

**`MPOL_WEIGHTED_INTERLEAVE`** (added in 6.9) is like `MPOL_INTERLEAVED` but each node in the mask carries a weight read from sysfs (`/sys/kernel/mm/mempolicy/weighted_interleave/node<N>`). The kernel allocates proportionally, allowing heterogeneous-capacity nodes to each absorb an appropriate share of traffic. Weights default to values derived from HMAT (Heterogeneous Memory Attribute Table) firmware tables.

### Mode Flags

Two flags modify how the `nodes` nodemask behaves as cpusets change:

**`MPOL_F_STATIC_NODES`**: the user-supplied nodemask is stored verbatim in `w.user_nodemask`. If the task's cpuset restricts allowed nodes, only the intersection of the user mask and the cpuset is used. If the intersection is empty the allocation is disallowed rather than silently widened.

**`MPOL_F_RELATIVE_NODES`**: the user supplies a *relative* nodemask (bit N = "the Nth allowed node"). When the cpuset changes, the kernel remaps the original relative bits against the new allowed set, preserving intended distribution. This is useful in container/cpuset environments where the absolute node numbers are not known in advance.

### Installing a Policy — the Kernel Path

`set_mempolicy(2)` calls `sys_set_mempolicy()` → `do_set_mempolicy()`. The function:
1. Validates the mode and nodemask, copying the user nodemask into kernel space.
2. Calls `mpol_new()` to allocate a `struct mempolicy` from the `mempolicy` kmem cache, initialising refcnt to 1.
3. If `MPOL_F_RELATIVE_NODES` or `MPOL_F_STATIC_NODES` is set, stores the original user nodemask in `w`.
4. Calls `mpol_rebind_policy()` to intersect `nodes` with the current cpuset allowed set (unless `STATIC_NODES`).
5. Atomically swaps `current->mempolicy` and drops the reference on the old one.

`mbind(2)` is heavier: it acquires `mmap_write_lock(mm)`, walks the VMA tree for the range, installs or replaces per-VMA policies, and optionally migrates existing pages (`MPOL_MF_MOVE` or `MPOL_MF_MOVE_ALL`).

### The Allocation Fast Path

When `__alloc_pages_nodemask()` is called, it immediately checks the effective nodemask:

1. `get_vma_policy()` returns a `struct mempolicy*`: first tries the VMA's policy (if the fault is within a VMA), then `current->mempolicy`, then `&default_policy`.
2. `policy_nodemask()` extracts the effective `nodemask_t` given the current cpuset, handling interleave cursor advancement for `MPOL_INTERLEAVED`.
3. The nodemask is passed down to the zone-list selection logic: `build_zonelist_cache()` filters the global `zonelist` to only include zones on allowed nodes.
4. The allocator tries zones in that filtered list, respecting watermarks. If all preferred nodes are exhausted and the mode is not `MPOL_BIND`, it retries on the full zone list.

For `MPOL_INTERLEAVED`, `interleave_nid()` picks the next node by reading and advancing `task_struct->numa_next_node`, calling `next_node_in()` to wrap around the nodemask.

### Reference Counting and Lifetime

`struct mempolicy` is reference-counted with `mpol_get()` / `mpol_put()`. The slow-path rules:

- **Task policy**: held with a normal reference. `mpol_put()` on exit/exec. No extra references needed during page fault because the task holds its own mmap_read_lock which prevents concurrent `set_mempolicy` from freeing the policy under it.
- **VMA policy**: stored in the VMA's `vm_ops` policy tree. The VMA's lifetime governs it; fork COWs the VMA and gets a new reference via `mpol_dup()`.
- **Shared policy**: a spinlock-protected radix-tree lookup returns a temporary reference incremented under the spinlock, which must be dropped after the allocation.

The `struct rcu_head` member allows policy objects to be freed via RCU in paths where taking a lock is impractical.

### NUMA Balancing (Automatic Migration)

Explicit policy covers the case where applications know their topology in advance. For the common case where they do not, the kernel adds **NUMA balancing** (merged in 3.8, stabilised in 3.10):

1. A periodic `task_tick_numa()` in the scheduler unmaps a fraction of the task's pages by setting a special *NUMA hinting* PTE bit (`_PAGE_NUMA` on x86, equal to `_PAGE_PROTNONE` but distinguished by context).
2. When the task next touches one of those pages, a page fault fires and calls `do_numa_page()`. This records which node the access came from (the faulting CPU's node) and which node the page currently lives on.
3. If the page is consistently accessed from a different node than where it resides, `migrate_misplaced_page()` migrates it using the standard `migrate_pages()` path.
4. Related threads that share pages are grouped into *NUMA groups* (tracked in `task_struct->numa_group`). The scheduler uses group membership to place co-located threads on nodes that share their hot pages.

NUMA balancing is controlled by `/proc/sys/kernel/numa_balancing` and can be tuned via several `numa_balancing_*` sysctls. It complements explicit policy: `mbind()` policies take precedence over balancing-driven migration.

## Key Data Structures

**`struct mempolicy`** (`include/linux/mempolicy.h`) — the unit of NUMA allocation policy.
- `refcnt` — atomic reference count; freed via `mpol_put()` when reaching zero.
- `mode` — one of `MPOL_DEFAULT`, `MPOL_BIND`, `MPOL_PREFERRED`, `MPOL_PREFERRED_MANY`, `MPOL_INTERLEAVED`, `MPOL_WEIGHTED_INTERLEAVE`.
- `flags` — `MPOL_F_STATIC_NODES` or `MPOL_F_RELATIVE_NODES` controlling nodemask rebinding.
- `nodes` — the effective nodemask after cpuset intersection; this is what the allocator sees.
- `home_node` — single preferred node for `MPOL_PREFERRED` / `MPOL_PREFERRED_MANY`.
- `w.user_nodemask` / `w.cpuset_mems_allowed` — the original user input or the allowed mask at install time, used to recompute `nodes` after cpuset changes.

**`task_struct::mempolicy`** — per-thread policy pointer; NULL means use the system default.

**`task_struct::numa_next_node`** — interleave cursor; which node gets the next page under `MPOL_INTERLEAVED`.

**`vm_area_struct` VMA policy tree** — a red-black tree keyed by file offset (for shared) or virtual address (for private), each leaf holding a `struct mempolicy*`.

## Key Functions / Entry Points

**`do_set_mempolicy()`** (`mm/mempolicy.c`) — implements `set_mempolicy(2)`; validates, allocates, and swaps the task policy.

**`do_mbind()`** (`mm/mempolicy.c`) — implements `mbind(2)`; walks VMAs, installs per-VMA policies, optionally triggers page migration.

**`get_vma_policy()`** (`mm/mempolicy.c`) — returns the effective policy for a fault address; checks VMA first, then task, then default.

**`policy_nodemask()`** (`mm/mempolicy.c`) — extracts the effective `nodemask_t` from a policy, advancing the interleave cursor if needed.

**`mpol_new()`** (`mm/mempolicy.c`) — allocates and initialises a fresh `struct mempolicy` from the slab cache.

**`mpol_rebind_policy()`** (`mm/mempolicy.c`) — recomputes `nodes` after a cpuset membership change; called by cpuset code when the allowed set changes.

**`mpol_dup()`** (`mm/mempolicy.c`) — deep-copies a policy for VMA duplication on `fork()`.

**`interleave_nid()`** (`mm/mempolicy.c`) — selects the next node for an interleaved allocation by advancing `task_struct::numa_next_node`.

**`do_numa_page()`** (`mm/memory.c`) — fault handler for NUMA hinting faults; decides whether to migrate the page.

## Important Flags & Config Options

| Symbol / Knob | What it controls |
|---|---|
| `CONFIG_NUMA` | Enables all NUMA policy infrastructure; without this the kernel builds stub no-op wrappers. |
| `CONFIG_NUMA_BALANCING` | Compiles in automatic page migration via hinting faults. |
| `/proc/sys/kernel/numa_balancing` | Enable (1) or disable (0) automatic NUMA balancing at runtime. |
| `/proc/sys/kernel/numa_balancing_scan_period_min_ms` / `_max_ms` | Controls how frequently the scanner unmaps pages to generate hinting faults. |
| `/proc/sys/kernel/numa_balancing_scan_size_mb` | How many MB of a task's address space are scanned per period. |
| `/sys/kernel/mm/mempolicy/weighted_interleave/node<N>` | Per-node weight for `MPOL_WEIGHTED_INTERLEAVE`; sourced from HMAT firmware data by default. |
| `/proc/<pid>/numa_maps` | Per-process view of page distribution across nodes — invaluable for diagnosing policy effectiveness. |
| `numactl(8)` | CLI wrapper for `set_mempolicy` / `mbind`; no code changes required to apply policy to existing binaries. |

## Interactions with Other Subsystems

- **↑ Userspace**: `set_mempolicy(2)`, `mbind(2)`, `get_mempolicy(2)`, `set_mempolicy_home_node(2)`. Also `numactl(8)`, `libnuma`. `/proc/<pid>/numa_maps` exposes observed distribution.
- **→ [[page-fault-handler]]**: the allocation triggered by a page fault uses `get_vma_policy()` to find the governing policy, then passes its nodemask to `__alloc_pages()`.
- **→ [[buddy-allocator]]**: receives the filtered zone list derived from the policy's nodemask; responsible for the actual page selection within those zones.
- **→ [[memory-compaction]]**: `mbind()` with `MPOL_MF_MOVE` calls `migrate_pages()` which may trigger compaction on the destination node to free contiguous ranges.
- **← [[memcg]]**: memory cgroups can restrict which nodes a task may use, and their cpuset constraints feed into `mpol_rebind_policy()`.
- **← [[scheduler]]** (NUMA balancing): the CFS scheduler's `task_tick_numa()` drives the periodic page unmapping that enables automatic locality improvement.
- **← cpuset**: whenever a task's cpuset `mems` changes, `cpuset_change_task_nodemask()` calls `mpol_rebind_task()` to recompute all policy nodemasks.

## Design Decisions & Tradeoffs

**Hierarchy over a single global policy.** Having four levels (system / task / VMA / shared) allows coarse defaults with surgical overrides. The cost is complexity in lookup and rebinding; the benefit is that a library can set a VMA policy without knowing the application's task policy.

**MPOL_PREFERRED vs. MPOL_BIND.** `MPOL_PREFERRED` is forgiving: if the preferred node is exhausted the allocator silently falls back. `MPOL_BIND` is strict: it will trigger reclaim and OOM-kill before allocating off-node. The tradeoff is predictability vs. availability. Most applications should use `MPOL_PREFERRED`; `MPOL_BIND` is for latency-sensitive workloads where off-node allocation is worse than an OOM kill.

**Conflating memory type with locality (MPOL_PREFERRED_MANY).** The 5.15 introduction of `MPOL_PREFERRED_MANY` was explicitly a pragmatic reuse of NUMA infrastructure to address heterogeneous memory types (e.g., PMEM alongside DRAM) rather than creating a new type-selection API. Reviewers acknowledged the conceptual conflation but accepted it to avoid low-appetite new syscalls. A future `process_mbind()` system call using pidfds may eventually separate the two concerns cleanly.

**Static vs. relative nodes.** Containerised workloads want policies that remain meaningful as processes are moved between cpusets. `MPOL_F_RELATIVE_NODES` solves this by storing intent (relative position) rather than absolute node numbers. The implementation complexity (dual nodemask storage, rebinding logic) is significant but necessary for correctness in dynamic environments.

**Shared policy spinlock.** The shared policy path uses a spinlock plus an extra reference count for the period between lookup and allocation. This is slower than the task/VMA paths (no extra refcount needed there) but is acceptable because shared memory allocations are less frequent per-byte than private anonymous allocations.

## How It Has Evolved

- **2.6.7 (2004)**: Initial NUMA API — `set_mempolicy`, `get_mempolicy`, `mbind`. Four modes: DEFAULT, BIND, PREFERRED, INTERLEAVED. Reference-counted `struct mempolicy`.
- **2.6.19**: `MPOL_F_STATIC_NODES` and `MPOL_F_RELATIVE_NODES` added to handle cpuset-induced nodemask remapping correctly.
- **3.8–3.10 (2013)**: NUMA balancing merged. Hinting-fault mechanism (`_PAGE_NUMA` PTE bit), `do_numa_page()`, NUMA groups, and scheduler integration.
- **3.13**: `set_mempolicy_home_node` variant and `home_node` field added for `MPOL_BIND`/`MPOL_PREFERRED_MANY` to express a primary node within a bound set.
- **5.15 (2021)**: `MPOL_PREFERRED_MANY` added to handle heterogeneous memory systems where multiple nodes share a memory type (e.g., all CXL nodes).
- **6.9 (2024)**: `MPOL_WEIGHTED_INTERLEAVE` merged. Global weights via sysfs, seeded from HMAT. Per-task weights deferred to a future release due to syscall design concerns.

## Further Reading

1. [NUMA Memory Policy — kernel.org documentation](https://www.kernel.org/doc/html/latest/admin-guide/mm/numa_memory_policy.html) — authoritative reference for policy modes and syscall semantics.
2. [NUMA policy and memory types — LWN (2021)](https://lwn.net/Articles/862707/) — covers the motivation and design of `MPOL_PREFERRED_MANY` for heterogeneous memory.
3. [Memory part 4: NUMA support — LWN (2008)](https://lwn.net/Articles/254445/) — Ulrich Drepper's accessible deep-dive into NUMA architecture and Linux policy machinery.
4. [Foundation for automatic NUMA balancing — LWN (2012)](https://lwn.net/Articles/523065/) — the RFC that introduced hinting faults and automatic migration.
5. [Toward better NUMA scheduling — LWN (2012)](https://lwn.net/Articles/486858/) — lazy migration, home nodes, and NUMA groups in the scheduler.
6. [Extending the mempolicy interface for heterogeneous systems — LWN (2023)](https://lwn.net/Articles/973964/) — `MPOL_WEIGHTED_INTERLEAVE`, `process_mbind()` proposal, and the ongoing heterogeneous-memory design debate.

## LKML Highlights

- **`MPOL_PREFERRED_MANY` introduction (2021)**: The thread debated whether NUMA node IDs were the right abstraction for memory *types* vs. memory *locality*. The pragmatic outcome — reuse existing infrastructure, avoid new syscalls — prevailed. Message context: the 5.15 merge window discussions around `linux-mm@kvack.org` circa September 2021.
- **NUMA balancing RFC (2012)**: Rik van Riel's foundational RFC introduced the `_PAGE_NUMA` hinting bit and the lazy-migration model. The debate centred on scan period tuning and whether the overhead justified the benefit on workloads with no natural locality (it did not — `numa_balancing` can be disabled). See `lwn.net/Articles/523065/`.
- **`MPOL_F_STATIC_NODES` (2.6.19)**: Added after container workloads revealed that cpuset changes silently corrupted policies by changing the meaning of stored node bits. The fix introduced dual nodemask storage (`w.user_nodemask` / `w.cpuset_mems_allowed`) and the rebinding callbacks into the cpuset code.
