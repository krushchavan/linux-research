---
title: "SLUB Slab Allocator"
category: concept
tags: [memory, mm, slab, kmalloc, allocation, slub]
subsystem: mm
kernel_version: "2.6.22+"
researched: 2026-04-05
status: complete
sources:
  - https://kernel-internals.org/mm/slab/
  - https://kernel-internals.org/mm/slab-internals/
  - https://static.lwn.net/kerneldoc/core-api/memory-allocation.html
---

# SLUB Slab Allocator

## Purpose

The kernel needs to allocate objects measured in bytes — not pages. A `struct dentry` is ~192 bytes; a `struct task_struct` a few kilobytes. Allocating a full 4 KB page per object would waste 95%+ of that page on small types. SLUB solves this by carving buddy pages into typed caches of fixed-size slots, making allocation as fast as a pointer swap while keeping internal fragmentation at one slot's worth of rounding per object.

## Mental Model

Think of SLUB as a set of specialised vending machines — one machine per object type. Each machine's tray (the per-CPU slab) holds a batch of pre-cut slots ready to hand out. Taking a slot is instant and lock-free: just grab the front item and move the pointer. When the tray empties, the machine refills from a shared back-room stock (partial slab list). Only if the back room is empty does anyone have to phone the warehouse (buddy allocator) for a new delivery.

## How It Works

**Setup.** Every object type that deserves its own cache is registered with `kmem_cache_create(name, size, align, flags, ctor)`. This allocates a `kmem_cache` descriptor and sets up per-CPU and per-node state. For generic allocations, `kmalloc()` routes to pre-created power-of-two caches: `kmalloc-8`, `kmalloc-16`, `kmalloc-32`, `kmalloc-64`, `kmalloc-96`, `kmalloc-128`, … `kmalloc-8192`. A 100-byte request uses `kmalloc-128`, wasting 28 bytes — acceptable compared to a full page.

**Fast path (per-CPU, lockless).** Each CPU holds a `kmem_cache_cpu` pointing to a currently active slab page and a `freelist` — a pointer to the first free object within that page. Free objects are linked with an embedded next-pointer at a fixed offset within the object itself. Allocation is:

```c
// Conceptually:
void *obj = cpu_slab->freelist;           // grab first free slot
cpu_slab->freelist = get_freepointer(obj); // advance to next
return obj;
```

The actual implementation uses `cmpxchg` on the (freelist, tid) pair atomically. The `tid` (transaction ID) is a monotonically increasing counter that changes every time the CPU is preempted or the slab is replaced. This prevents ABA races: if an interrupt fires between reading the freelist and swapping it, the tid will have changed, the cmpxchg will fail, and the allocator retries.

**Slow path.** If the per-CPU freelist is empty, `__slab_alloc()` is called:
1. Check `cpu_slab->partial` — a list of partially-filled slabs on this CPU. If one has free objects, install it as the new `cpu_slab` and retry the fast path.
2. Check `kmem_cache_node->partial` — the per-NUMA-node partial list, protected by `n->list_lock`. Take a slab and install it.
3. If both are empty, call `new_slab()` → `alloc_slab_page()` → `alloc_pages(GFP_KERNEL, order)` to obtain a fresh page from the buddy allocator. Initialise it as a slab, install it as the current CPU slab, and allocate from it.

**Free path.** `kmem_cache_free(cache, obj)` / `kfree(obj)` reverses the process. If the freed object belongs to the current CPU's active slab, prepend it to `cpu_slab->freelist` — one store, no lock. If it belongs to a different slab, `__slab_free()` handles cross-slab accounting: update the slab's internal freelist, and if the slab transitions from full→partial or partial→empty, move it between lists accordingly. A completely empty slab is eventually returned to the buddy allocator.

**Security hardening.** SLUB includes several layers of protection:
- **Freelist pointer XOR** (`CONFIG_SLAB_FREELIST_HARDENED`): each next-pointer is XORed with a per-cache secret and the object's own address, so an attacker cannot predict freelist structure without the secret.
- **Freelist randomisation** (`CONFIG_SLAB_FREELIST_RANDOM`): the initial freelist order within a new slab is randomised, preventing reliable heap spray.
- **Poisoning** (`CONFIG_SLUB_DEBUG`): freed objects are filled with `0x6b`; allocated objects are checked. Use-after-free writes a different byte pattern, detected on next allocation.
- **Red zones** (`CONFIG_SLUB_DEBUG`): guard bytes `0xbb`/`0xcc` at object boundaries catch buffer overflows.
- **KFENCE** (`CONFIG_KFENCE`): a sampling-based detector that allocates objects in guard-page-protected pages with ~1/1000 probability. Catches use-after-free and out-of-bounds in production with near-zero overhead.
- **init_on_alloc/init_on_free** (boot params): zero memory on allocation or free, preventing information leaks and use-after-free data exposure.

## Key Data Structures

**`struct kmem_cache`** (`include/linux/slub_def.h`) — the cache descriptor; one per object type.
- `cpu_slab` — per-CPU pointer to current active slab state (`kmem_cache_cpu`)
- `size` — allocation slot size (user size + alignment padding)
- `object_size` — user-visible object size
- `flags` — `SLAB_HWCACHE_ALIGN`, `SLAB_POISON`, `SLAB_RED_ZONE`, `SLAB_ACCOUNT`, etc.
- `offset` — byte offset of the embedded freelist pointer within each object
- `oo` — packed `(order, objects_per_slab)` for buddy allocation sizing
- `node[MAX_NUMNODES]` — per-node partial slab list

**`struct kmem_cache_cpu`** (per-CPU, embedded in `kmem_cache`) — fast path state.
- `freelist` — pointer to first free object in the current slab; XOR-hardened if `SLAB_FREELIST_HARDENED`
- `tid` — transaction ID; incremented on preemption/slab switch to detect ABA in cmpxchg
- `slab` — current active slab page for this CPU
- `partial` — per-CPU partial slab list (faster than per-node, no lock)

**`struct kmem_cache_node`** (`mm/slab.h`) — per-NUMA-node slow-path state.
- `partial` — list of partially-full slabs with free objects
- `list_lock` — spinlock protecting the partial list
- `nr_partial` — count of partial slabs; controls when empty slabs are returned to buddy

## Key Functions / Entry Points

**`kmem_cache_alloc(cache, gfp)`** (`mm/slub.c`) — typed allocation; called by everything from `alloc_inode()` to `sk_prot_alloc()`; fast path is one cmpxchg.

**`kmalloc(size, gfp)`** — routes to the appropriate `kmalloc-N` cache; used for ad-hoc kernel allocations.

**`kvmalloc(size, gfp)`** — tries `kmalloc()` first; falls back to `vmalloc()` for large or fragmentation-affected sizes. Use when allocation size varies widely.

**`__slab_alloc(cache, gfp, addr, cpu_slab)`** — slow path; partial lists → buddy; called when per-CPU freelist is empty.

**`kmem_cache_free(cache, obj)`** / **`kfree(obj)`** — return object; fast path is one store to freelist.

**`__slab_free(cache, slab, obj, addr)`** — cross-slab free slow path; manages partial/empty list transitions.

**`kmem_cache_create(name, size, align, flags, ctor)`** — create a new typed cache.

**`kmem_cache_destroy(cache)`** — destroy a cache; asserts all objects have been freed.

## Important Flags & Config Options

| Option | Effect |
|--------|--------|
| `CONFIG_SLUB` | SLUB enabled (default since v2.6.22; only option since v6.8) |
| `CONFIG_SLUB_DEBUG` | Red-zone, poisoning, per-object tracking; significant overhead |
| `CONFIG_SLAB_FREELIST_HARDENED` | XOR freelist pointers with per-cache secret |
| `CONFIG_SLAB_FREELIST_RANDOM` | Randomise freelist order per slab at initialisation |
| `CONFIG_KFENCE` | Sampling-based production-safe UAF/OOB detector |
| `SLAB_HWCACHE_ALIGN` | Align objects to hardware cache lines; reduces false sharing |
| `SLAB_ACCOUNT` | Charge objects to `kmem` cgroup (needed for memcg accounting) |
| `SLAB_POISON` | Enable poisoning for this cache even without global debug |
| `init_on_alloc=1` | Zero-fill all allocations (boot param); security / leak prevention |
| `init_on_free=1` | Zero-fill on free (boot param); prevents UAF data exposure |

## Interactions with Other Subsystems

- **↑ Userspace**: no direct interface; kernel-internal only.
- **← All kernel subsystems**: virtually every kernel subsystem calls `kmalloc()` or `kmem_cache_alloc()`; SLUB is the universal sub-page allocator.
- **→ Buddy allocator**: calls `alloc_pages()` on slab cache miss to obtain a new slab page; frees pages back via `__free_pages()` when a slab goes empty.
- **← memcg**: `SLAB_ACCOUNT` caches call `mem_cgroup_charge()` on allocation, enforcing per-cgroup `kmem` limits.
- **→ KFENCE**: a small fraction of allocations are redirected to KFENCE's guard-page allocator for sampling-based memory safety checking.

## Design Decisions & Tradeoffs

**SLUB over SLAB.** SLUB replaced SLAB in 2007 not primarily for performance but for simplicity. SLAB maintained per-CPU and per-node magazines and had complex cache colouring logic. SLUB's embedded-freelist approach is conceptually simpler, making it far easier to add security hardening (freelist XOR, randomisation, poisoning, KFENCE) without introducing subtle bugs. The performance difference was marginal; the maintainability gain was large.

**Power-of-two size classes with internal fragmentation.** A 100-byte request using a 128-byte slot wastes 28 bytes. The alternative — arbitrary-size caches — would eliminate this waste but destroy cache locality (objects of the same size would no longer share a slab, destroying the hot-cache benefit) and make the allocator much harder to reason about. The 96-byte class was added as a special case to reduce waste for the critical inode-size range.

**Per-CPU partial list (v5.7+).** Before v5.7, the per-CPU state only had one active slab; on depletion, the allocator immediately went to the per-node partial list under a lock. Adding a per-CPU partial list (a few spare slabs per CPU) reduces lock pressure substantially on workloads with high allocation/free churn across multiple objects of the same type.

**No reference counting in the allocator.** SLUB tracks only whether a slot is free or in-use (via the freelist). Who holds a reference to an in-use object is the object owner's responsibility. This keeps the fast path minimal.

## How It Has Evolved

| Version | Change | Driver |
|---------|--------|--------|
| v2.6.22 (2007) | SLUB introduced; replaces SLAB as default | SLAB too complex; SLUB simpler, easier to harden |
| v2.6.39 (2011) | Per-CPU partial lists | Reduce per-node lock contention under churn |
| v4.9 (2016) | `kmalloc()` uses SLUB node-partial-list path | Unify allocation paths |
| v5.7 (2020) | Extended per-CPU partial list | Fewer slow-path invocations on busy systems |
| v5.17 (2022) | `slab_flags_t` type introduced | Type safety for cache flags |
| v6.1 (2022) | Slab page tracking moved to `struct slab` (split from `struct page`) | Cleaner type system; folio transition |
| v6.4 (2023) | SLOB removed | Redundant; SLUB efficient enough on embedded |
| v6.8 (2024) | SLAB removed; SLUB is sole slab implementation | Final consolidation |

## Further Reading

1. [kernel-internals.org/mm/slab/](https://kernel-internals.org/mm/slab/) — SLAB vs SLUB comparison, design rationale, size classes
2. [kernel-internals.org/mm/slab-internals/](https://kernel-internals.org/mm/slab-internals/) — per-CPU cmpxchg fast path, tid, slow path walkthrough
3. [kernel.org — Memory Allocation Guide](https://static.lwn.net/kerneldoc/core-api/memory-allocation.html) — when to use kmalloc vs vmalloc vs kvmalloc

## LKML Highlights

- **SLUB introduction (Christoph Lameter, 2007)** — the original SLUB RFC explicitly argues that "simpler code is correct code" and that SLAB's magazine system introduces races that are hard to audit; the thread shows the mm community's agreement that SLUB's gains justified replacing a mature allocator.
