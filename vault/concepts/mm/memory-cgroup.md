---
title: "Memory Cgroup (memcg)"
category: concept
tags: [mm, cgroups, memcg, resource-control, containers]
subsystem: mm
kernel_version: "2.6.25"
researched: 2026-04-13
status: complete
explained: "[[memory-cgroup-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html
  - https://docs.kernel.org/admin-guide/cgroup-v1/memory.html
  - https://www.kernel.org/doc/html/v6.9/admin-guide/cgroup-v1/memcg_test.html
  - https://lwn.net/Articles/529927/
  - https://lwn.net/Articles/516529/
  - https://lwn.net/Articles/759658/
  - https://github.com/torvalds/linux/blob/master/include/linux/memcontrol.h
  - https://github.com/torvalds/linux/blob/master/mm/memcontrol.c
---

# Memory Cgroup (memcg)

> 📘 Plain-language version: [[memory-cgroup-explained]]

## Purpose

Without memory cgroups, all processes on a system share a single pool of physical memory with no per-workload accounting or limits — one runaway container can exhaust RAM and trigger system-wide OOM events. The memory controller (`memcg`) adds per-cgroup accounting, limiting, protection, and reclaim so that each container or workload group gets a bounded, independently managed slice of memory. It is the foundational building block for memory isolation in container runtimes (Docker, containerd, systemd units, and Kubernetes pods).

## Mental Model

Think of each cgroup as having a separate water tank with its own fill level, high-water alarm (`memory.high`), and overflow drain (`memory.max`). Every physical page carries a tag identifying which tank it belongs to. When the tank approaches the alarm level, the kernel slows down allocations to drain it. When it overflows, the OOM killer acts. Ancestor tanks accumulate the fill of all descendant tanks, so a root tank can cap an entire subtree without knowing the exact distribution inside.

## How It Works

### Page Charging: Binding Pages to Cgroups

Every physical [[folio]] (a contiguous group of pages, the modern unit since ~5.16) is tagged at birth with a pointer to the `mem_cgroup` that owns it. The tagging happens in `mem_cgroup_charge()` (`mm/memcontrol.c`), which is called from two main sites:

- **Anonymous pages**: on the [[page fault handler]] path, just before the new page is inserted into the page table (`do_anonymous_page()`, `do_wp_page()`).
- **File/page-cache pages**: when a page is first added to the address-space's xarray (`__add_to_page_cache_locked()`).

`mem_cgroup_charge()` calls `try_charge()`, which walks up the cgroup hierarchy, incrementing the `page_counter` of every ancestor. The `page_counter` structure (`include/linux/page_counter.h`) holds `usage` (current bytes charged) and `max` (the hard limit). If any ancestor's `usage + PAGE_SIZE` would exceed its `max` (the `memory.max` file), `try_charge()` first attempts [[page reclaim]] on that cgroup before returning `-ENOMEM`. If reclaim succeeds, the charge goes through; otherwise the path ends in the [[OOM killer]] selecting a victim within the offending cgroup.

The two-phase commit is important: `try_charge()` speculatively increments the counter without yet linking the folio to the memcg. Only after the folio is safely inserted into the page-table or page-cache does `mem_cgroup_commit_charge()` record the binding in the folio's internal memcg pointer (`folio->memcg` via `folio_set_memcg()`). If the insertion fails, `mem_cgroup_cancel_charge()` rolls back the counter. This prevents races where a page is counted but never inserted.

Uncharing happens symmetrically in `mem_cgroup_uncharge()`, called when the folio's last reference is dropped. The counter is decremented all the way up the hierarchy.

### Per-Cgroup LRU Lists

The kernel's traditional reclaim uses a global pair of LRU lists (active + inactive) per NUMA node. memcg replaces this with a three-dimensional structure: one `lruvec` per (cgroup × NUMA node). The `lruvec` structure (`include/linux/mmzone.h`) holds five per-node LRU lists:

- `LRU_INACTIVE_ANON`, `LRU_ACTIVE_ANON` — anonymous (non-file) pages
- `LRU_INACTIVE_FILE`, `LRU_ACTIVE_FILE` — file-backed pages
- `LRU_UNEVICTABLE` — pages that cannot be reclaimed (mlocked, etc.)

When a page is first charged to a cgroup, it is also added to that cgroup's `lruvec` rather than the global one. `lruvec->lru_lock` serialises all LRU operations for that (cgroup, node) pair; the folio's `PG_lru` flag is cleared before isolation and set after reinsertion, preventing concurrent reclaim from touching the same folio twice.

Because each cgroup has its own LRU, the reclaim algorithm can target a specific cgroup: when `try_charge()` finds a cgroup over limit, it calls `mem_cgroup_reclaim()` which iterates only that cgroup's LRU lists. The reclaim algorithm itself (`shrink_lruvec()`) is unchanged; it just operates on a cgroup-scoped `lruvec` instead of the global one.

### memory.high: The Soft Throttle

`memory.max` is the hard limit, but the primary knob for container runtimes is `memory.high`. When a cgroup's usage exceeds `memory.high`, `try_charge()` does not immediately OOM; instead, it calls `mem_cgroup_handle_over_high()`, which introduces a proportional allocation delay. The delay is calculated based on how far over the high watermark the cgroup is: a 1 % overage causes a brief sleep, while a 50 % overage causes a much longer one. This throttling gives a management daemon (e.g., `systemd`'s oomd, or the Kubernetes kubelet) time to respond — by shrinking the workload or raising the limit — before OOM is triggered. PSI (Pressure Stall Information) via `memory.pressure` lets operators observe the accumulated stall time in near-real-time.

### Hierarchical Protection: memory.min and memory.low

The protection model works in the opposite direction from limits. `memory.min` is a hard guarantee: the kernel will never reclaim pages from a cgroup if doing so would reduce its usage below `memory.min`. Even under severe system-wide pressure, `memory.min` pages are treated as off-limits. `memory.low` is the soft variant: the reclaim scanner applies a "skip" probability proportional to how much of `memory.low` is still filled, biasing reclaim toward less-protected cgroups.

Both protections propagate bottom-up: a child's protection is only effective up to the parent's effective protection. A child advertising `memory.min = 1G` under a parent with `memory.min = 512M` only gets 512 MB of hard protection — the parent's promise is the binding constraint.

### Swap Accounting

When a page is swapped out, its physical memory is freed but the cgroup that owned it should still be held accountable for the swap slot it now occupies (otherwise, a cgroup could evade limits simply by swapping aggressively). `CONFIG_MEMCG_SWAP` enables a `swap_cgroup` table, indexed by swap entry, that records which `mem_cgroup` owns each swap slot. A second counter, `memsw` (memory + swap), is incremented for the swap entry and decremented when the page is swapped back in. In cgroup v2, `memory.swap.max` caps this counter independently.

When a swapped page is faulted back in, `mem_cgroup_charge_swap()` decrements the swap counter and `mem_cgroup_charge()` re-establishes the RAM charge, keeping the total `memsw` constant.

### Kernel Memory Accounting

User pages are straightforward to track because they have an owning process and a clear lifetime. Kernel-internal allocations (slab objects, kernel stacks, socket buffers) are harder because they are shared across contexts. memcg tracks three kernel memory types:

- **Slab objects**: each object type gets a per-cgroup `kmem_cache`. When a cgroup allocates a kernel object (e.g., a `dentry`), it is carved from that cgroup's cache. The per-cgroup cache is created lazily on first use. This design prevents cross-cgroup pinning: a cgroup cannot keep another's slab pages alive by holding references to shared objects.
- **Kernel stacks**: each task's kernel stack (typically 8–16 KB) is charged to the task's owning cgroup.
- **Socket memory**: `sk_mem_charge()` / `sk_mem_uncharge()` charge TCP/UDP socket buffers to the socket's owning cgroup.

All kernel charges feed into a sub-counter `kmem.usage` that also contributes to the top-level `memory.current`, so kernel and user memory are capped by the same `memory.max`.

### OOM Within a Cgroup

When `try_charge()` exhausts the cgroup's memory and reclaim fails, it invokes the [[OOM killer]] scoped to that cgroup. `mem_cgroup_out_of_memory()` calls `out_of_memory()` with an `oom_control` structure that constrains victim selection to tasks within the offending cgroup and its descendants. The "bulkiest" task (highest `oom_score_adj` × RSS) is selected and sent `SIGKILL`. If `memory.oom.group = 1` (cgroup v2), the entire cgroup is killed together — every task gets `SIGKILL` simultaneously, preventing partial-group zombies.

## Key Data Structures

**`struct mem_cgroup`** (`include/linux/memcontrol.h`) — the per-cgroup controller state, embedded in the cgroup's `css` (cgroup subsystem state).
- `memory` (`struct page_counter`) — current usage and `memory.max` limit
- `memsw` (`struct page_counter`) — combined memory+swap counter and limit
- `kmem` (`struct page_counter`) — kernel memory sub-counter
- `nodeinfo[]` — per-NUMA-node array of `mem_cgroup_per_node`, each holding the five `lruvec` LRU lists
- `high` (`unsigned long`) — the `memory.high` watermark in pages
- `oom_group` (`bool`) — whether to kill the whole cgroup on OOM
- `css` (`struct cgroup_subsys_state`) — links into the cgroup hierarchy; `css.parent` traversal is how hierarchy-wide charges walk up to ancestors

**`struct page_counter`** (`include/linux/page_counter.h`) — a single usage counter with limit semantics.
- `usage` (`atomic_long_t`) — current usage in bytes
- `max` — the configured limit; `PAGE_COUNTER_MAX` means unlimited
- `parent` — pointer to parent counter for hierarchical propagation

**`struct lruvec`** (`include/linux/mmzone.h`) — per-(cgroup, node) LRU state.
- `lists[NR_LRU_LISTS]` — the five `list_head` LRU queues
- `lru_lock` (`spinlock_t`) — serialises all list operations for this (cgroup, node) pair
- `memcg` (`struct mem_cgroup *`) — back-pointer to the owning cgroup

## Key Functions / Entry Points

**`mem_cgroup_charge()`** (`mm/memcontrol.c`) — public entry point called by page-fault and page-cache insertion paths; calls `try_charge()` then `commit_charge()`.

**`try_charge()`** (`mm/memcontrol.c`) — walks the hierarchy, increments `page_counter` at each level, triggers reclaim if over limit, applies `memory.high` throttling delay, returns 0 or `-ENOMEM`.

**`mem_cgroup_uncharge()`** (`mm/memcontrol.c`) — called when a folio's last reference is dropped; decrements counters all the way to root.

**`mem_cgroup_handle_over_high()`** (`mm/memcontrol.c`) — called in return-to-userspace path if `current->memcg_nr_pages_over_high > 0`; applies proportional sleep to throttle the offending task.

**`mem_cgroup_reclaim()`** / **`try_to_free_mem_cgroup_pages()`** (`mm/memcontrol.c`) — initiates direct reclaim scoped to a specific cgroup; calls `shrink_lruvec()` on the cgroup's per-node LRU lists.

**`mem_cgroup_out_of_memory()`** (`mm/memcontrol.c`) — invokes the OOM killer constrained to the cgroup subtree.

**`folio_memcg()`** (`include/linux/memcontrol.h`) — returns the `mem_cgroup` pointer stored in a folio; used throughout reclaim, charge, and stat update paths.

## Important Flags & Config Options

| Symbol / Interface | Effect |
|---|---|
| `CONFIG_MEMCG` | Enables the memory controller at build time; required for all memcg features |
| `CONFIG_MEMCG_SWAP` | Enables swap accounting (`memory.swap.*`); adds a small overhead per swap entry |
| `CONFIG_MEMCG_KMEM` | Enables kernel memory accounting (slab, stacks, sockets); enabled by default since 4.5 |
| `cgroup.memory=noswap` | Kernel cmdline: disables swap accounting globally even if `CONFIG_MEMCG_SWAP=y` |
| `memory.min` | Hard protection in bytes; reclaim will not touch this cgroup below this level |
| `memory.low` | Soft protection; biases reclaim away from this cgroup |
| `memory.high` | Throttling threshold; breaching this causes allocation delays before OOM |
| `memory.max` | Hard limit; OOM kill if exceeded and reclaim fails |
| `memory.swap.max` | Caps swap usage independently (cgroup v2 only) |
| `memory.oom.group` | Kill all tasks in the cgroup together on OOM (cgroup v2 only) |
| `memory.reclaim` | Write bytes to trigger proactive reclaim from the cgroup (cgroup v2, v5.19+) |

## Interactions with Other Subsystems

- **↑ Userspace**: container runtimes (containerd, runc) write `memory.max`/`memory.high`/`memory.min` at container start. Monitoring agents read `memory.stat` and `memory.pressure` to detect throttling. `systemd-oomd` subscribes to PSI events to proactively kill cgroups before kernel OOM fires.
- **→ [[page reclaim]]**: memcg provides a cgroup-scoped `lruvec` and wraps `try_to_free_mem_cgroup_pages()` so the reclaim engine operates on a per-cgroup LRU rather than the global one. It also raises or lowers the reclaim pressure signal based on `memory.low` protection calculations.
- **→ [[OOM killer]]**: memcg scopes OOM to a cgroup subtree by passing `mem_cgroup` context to `out_of_memory()`; the OOM killer respects this scope when selecting victims.
- **→ [[swap]]**: `CONFIG_MEMCG_SWAP` hooks into `swap_map` and `swap_cgroup` tables so that swap slots carry cgroup ownership; `memory.swap.max` is enforced at swap-out time.
- **→ [[SLUB slab allocator]]**: per-cgroup `kmem_cache` objects are allocated lazily; slab shrinkers report per-memcg reclaimable object counts to the reclaim engine.
- **← [[page fault handler]]**: calls `mem_cgroup_charge()` at anonymous fault time; the charge result can abort the fault with `ENOMEM` if the cgroup is at its hard limit.
- **← [[PSI (Pressure Stall Information)]]**: memory.high throttling accumulates task stall time into the memcg PSI clock, which is readable from `memory.pressure`.
- **← [[scheduler]]**: task migration between cgroups does not retag already-allocated pages; only new allocations after migration are charged to the new cgroup.

## Design Decisions & Tradeoffs

**Per-cgroup LRU vs. global LRU with memcg tags**: Early implementations used a single global LRU and added per-page memcg metadata, scanning everything and skipping non-target pages during cgroup reclaim. This was replaced with fully isolated per-cgroup LRU lists (`lruvec`). The cost is memory overhead (each `mem_cgroup_per_node` carries five list_heads × nodes) and extra locking. The benefit is O(cgroup size) reclaim rather than O(system size), which matters enormously at scale.

**Two-phase charge (try + commit/cancel)**: An alternative would be to charge at folio allocation in the page allocator. This was rejected because many allocations are kernel-internal with no clear cgroup ownership, and because it would require propagating memcg context through all of `kmalloc`. Instead, memcg charges at the semantic boundary where a folio gets a user-visible owner (page-table entry or page-cache slot). The two-phase design handles the window between "counting the allocation" and "recording which folio it is" without a lock.

**Selective kernel memory accounting**: Rather than tracking all `kmalloc` calls, memcg uses per-cgroup slab caches only for object types that are explicitly annotated (`SLAB_ACCOUNT`). This selective approach trades completeness for performance: un-annotated kernel allocations are not charged. The kernel gradually added annotations to common types (dentries, inodes, file objects) over several releases.

**memory.high as the primary control, not memory.max**: Container runtimes are encouraged to set `memory.high` well below `memory.max`. This creates a throttling buffer: `memory.high` slows allocations and triggers reclaim while leaving headroom before OOM. Using only `memory.max` (as was common in early Docker deployments) causes abrupt OOM kills with no warning, since the kernel goes from normal operation to killing tasks in a single step.

**Ownership immutability**: A charged page stays in its original cgroup even if the allocating process migrates to another cgroup. This avoids the complexity of recharging every mapped page on migration (which would require locking every page table that maps the page) at the cost of some accounting imprecision for highly mobile workloads.

## How It Has Evolved

**2.6.25 (2008)**: Initial merge by Balbir Singh. Per-process memory accounting with `memory.limit_in_bytes` and per-cgroup LRU. No hierarchy support, no swap accounting.

**2.6.29–2.6.34**: Hierarchical accounting enabled by `memory.use_hierarchy`; soft limit reclaim (`memory.soft_limit_in_bytes`) added for background pressure.

**3.8 (2013)**: Kernel memory accounting (`kmem`) merged (Glauber Costa, Michal Hocko). Per-cgroup slab caches, stack, and socket memory tracking added.

**4.0 (2015)**: memcg became a first-class citizen in cgroup v2 (Johannes Weiner, Tejun Heo). New clean interface: `memory.min`, `memory.low`, `memory.high`, `memory.max`, removing the tangle of v1 knobs. `memory.use_hierarchy = 1` became mandatory.

**4.5 (2016)**: `CONFIG_MEMCG_KMEM` enabled by default; kernel memory charges now included in `memory.current`.

**4.20 / 5.2 (2018–2019)**: PSI (Pressure Stall Information) merged; `memory.pressure` added to cgroup v2, enabling low-latency memory pressure monitoring without polling.

**5.9 (2020)**: Per-memcg LRU lock (`lruvec->lru_lock`) replacing the global `pgdat->lru_lock`, eliminating a major lock contention point under many-cgroup workloads (Alex Shi).

**5.16 (2022)**: folio conversion of the page-cache and LRU infrastructure; `page_cgroup` renamed/replaced by `folio`-native memcg pointer, reducing metadata overhead and pointer chasing.

**5.19 (2022)**: `memory.reclaim` interface added for proactive reclaim from userspace.

**6.1 (2022)**: MGLRU (Multi-Generational LRU) landed; extends `lruvec` with generation-based LRU lists, providing better reclaim accuracy per-cgroup.

## Further Reading

1. [Control Group v2 — Memory Controller (kernel.org)](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html#memory) — authoritative cgroup v2 interface reference
2. [Memory Resource Controller — cgroup v1 (kernel.org)](https://docs.kernel.org/admin-guide/cgroup-v1/memory.html) — v1 implementation details and accounting semantics
3. [Memcg Implementation Memo (kernel.org)](https://www.kernel.org/doc/html/v6.9/admin-guide/cgroup-v1/memcg_test.html) — developer-level notes on charge/uncharge internals
4. [Documentation/cgroups/memory.txt — LWN.net](https://lwn.net/Articles/529927/) — annotated walkthrough of early memcg design
5. [KS2012: Improving kernel-memory accounting for memcg — LWN.net](https://lwn.net/Articles/516529/) — kernel summit discussion on slab accounting design decisions
6. [PSI: Pressure Stall Information — LWN.net](https://lwn.net/Articles/759658/) — design and implementation of the `memory.pressure` interface
7. [Facebook cgroup v2 memory controller guide](https://facebookmicrosites.github.io/cgroup2/docs/memory-controller.html) — practical deployment guidance with memcg v2

## LKML Highlights

> No specific LKML message IDs collected in this research session. The most historically significant threads are the original memcg submission by Balbir Singh (2008), the cgroup v2 unification by Tejun Heo (~2014), and the per-memcg LRU lock series by Alex Shi (2020). Search lore.kernel.org for `mem_cgroup` with date filters to locate them.
