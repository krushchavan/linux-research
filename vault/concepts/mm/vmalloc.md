---
title: "vmalloc"
category: concept
tags: [memory, mm, vmalloc, virtual-memory, kernel-allocator]
subsystem: mm
kernel_version: "1.0+"
researched: 2026-04-05
status: complete
sources:
  - https://kernel-internals.org/mm/vmalloc/
  - https://static.lwn.net/kerneldoc/core-api/memory-allocation.html
---

# vmalloc

## Purpose

`kmalloc()` guarantees physically-contiguous memory, which the buddy allocator can only provide when a sufficiently large contiguous block exists. On a fragmented system, large kmalloc requests fail even when plenty of total free memory remains. `vmalloc()` solves this by mapping physically non-contiguous pages into a single contiguous virtual address range — trading physical contiguity (and the TLB efficiency it brings) for the ability to always satisfy large allocations.

## Mental Model

Imagine a hotel where all rooms on a floor must be occupied consecutively (physical contiguity — kmalloc). After a busy night, only scattered single rooms remain; a group wanting 10 consecutive rooms can't be accommodated. vmalloc is like issuing the group a master keycard that opens rooms 101, 214, 307, 412 — physically scattered, but the group experiences them as one connected suite. The keycard is the kernel page table that makes the scattered physical pages appear contiguous in virtual address space.

## How It Works

The kernel reserves a dedicated region of its virtual address space called the *vmalloc area* — a large range (many gigabytes on 64-bit) separate from both the direct-map physmem and user address space.

When `vmalloc(size)` is called, the allocator does three things in sequence:

**1. Find virtual space.** A global red-black tree (`vmap_area_root`) tracks all currently allocated vmalloc ranges. The allocator searches this tree for a free gap of `size + guard_page` bytes aligned to `PAGE_SIZE`. This replaced the original O(n) linked-list walk in v2.6.28, which became unacceptably slow when hundreds of kernel modules were loaded.

**2. Allocate physical pages.** `__vmalloc_node()` calls `alloc_page(GFP_KERNEL)` once per required page — these pages can come from anywhere in physical RAM. They need not be contiguous, adjacent, or even from the same NUMA node (though NUMA-aware vmalloc can prefer local nodes).

**3. Map into kernel page tables.** `map_kernel_range()` installs PTEs in the kernel's page tables, mapping each physical page at its assigned virtual address in sequence. After this step, the virtual address range appears contiguous to any code that accesses it.

`vfree(addr)` reverses this: it removes the PTE entries, releases the `vmap_area` record from the RB-tree, and calls `free_page()` for each backing page. But the TLB invalidation is *lazy*: freed vmalloc ranges accumulate in a per-CPU free list and are batched into a single IPI flush, amortising the cost of inter-processor TLB shootdowns across many `vfree()` calls.

Each vmalloc region ends with an unmapped *guard page*. A buffer overflow past the end of a vmalloc allocation triggers an immediate page fault rather than silently corrupting whatever follows in the vmalloc area — a cheap safety net.

**Performance cost.** Because the physical pages backing a vmalloc region are not contiguous, each 4 KB page needs its own TLB entry. A single 256 KB kmalloc allocation might use one large TLB entry (if the hardware supports it) or a small handful; the equivalent vmalloc allocation requires 64 TLB entries. This extra TLB pressure makes vmalloc unsuitable for hot allocation paths. It is used intentionally only for:
- **Loadable kernel modules** — the `.ko` text and data sections are vmalloc'd
- **Large driver buffers** — firmware images, DMA control structures that don't need physical contiguity
- **`ioremap()`** — mapping device MMIO into the kernel VA space
- **`copy_from_user()` large paths** — temporary buffers for large user-kernel data copies
- **`kvmalloc()` fallback** — when `kmalloc()` fails and the caller can accept virtual contiguity

**`kvmalloc(size, gfp)`** is the recommended choice when the caller doesn't know in advance whether the allocation will be large: it tries `kmalloc()` first (fast, physically contiguous) and falls back to `vmalloc()` only if that fails. Use `kvmalloc()` rather than manually open-coding the try/fallback pattern.

## Key Data Structures

**`struct vmap_area`** (`mm/vmalloc.c`) — tracks one allocated or free vmalloc range.
- `va_start` / `va_end` — virtual address range `[va_start, va_end)`
- `rb_node` — position in the global `vmap_area_root` red-black tree (O(log n) lookups)
- `list` — position in a chronological list used for lazy TLB flush batching
- `vm` — pointer to the `vm_struct` if this range is an active vmalloc allocation
- `vm_flags` — `VM_ALLOC` (vmalloc), `VM_MAP` (vmap), `VM_IOREMAP`, etc.

**`struct vm_struct`** (`include/linux/vmalloc.h`) — metadata for one vmalloc allocation.
- `addr` — virtual start address
- `size` — allocation size including the guard page
- `pages` — array of pointers to the backing `struct page`s
- `nr_pages` — number of backing pages
- `flags` — allocation type flags
- `next` — linked list of all `vm_struct`s (used for `/proc/vmallocinfo`)

## Key Functions / Entry Points

**`vmalloc(size)`** — standard large kernel allocation; virtually contiguous, physically scattered; may sleep.

**`vzalloc(size)`** — vmalloc + zero-fill; equivalent to `vmalloc(size)` followed by `memset(0)` but more efficient.

**`vmalloc_node(size, node)`** — NUMA-aware vmalloc; prefer physical pages from `node`.

**`vmap(pages, count, flags, prot)`** — map an existing array of `struct page *` into vmalloc space without allocating new physical pages. Used when you have pages from some other source (e.g., a scatter-gather list) and want a kernel VA to access them.

**`vfree(addr)`** — unmap and free; TLB invalidation is lazy-batched.

**`__vmalloc_node(size, align, gfp, node)`** — internal; full control over alignment, GFP flags, and NUMA node.

**`ioremap(phys_addr, size)`** (`arch/x86/mm/ioremap.c`) — map device MMIO physical addresses into vmalloc VA space; similar internals, different semantics (non-cacheable mappings).

## Important Flags & Config Options

| Option | Effect |
|--------|--------|
| `GFP_KERNEL` | Used internally for backing page allocations; `vmalloc()` may sleep |
| `GFP_ATOMIC` | `__vmalloc()` with `GFP_ATOMIC` for non-sleeping vmalloc (rarely correct) |
| `VM_ALLOC` | Marks the range as a vmalloc allocation (vs. ioremap, vmap) |
| `VM_NO_GUARD` | Disable the trailing guard page (unusual; used by module loader for exact sizing) |
| `CONFIG_MODULES` | Primary consumer of vmalloc; module text/data lives in vmalloc space |
| `VMALLOC_START` / `VMALLOC_END` | Architecture constants defining the vmalloc window in kernel VA space |
| `/proc/vmallocinfo` | Lists all active vmalloc ranges, their sizes, callers, and backing pages |

## Interactions with Other Subsystems

- **← Kernel modules (`kernel/module/`)**: every loaded `.ko` file's text, data, BSS, and exception tables are vmalloc'd via `module_alloc()`.
- **← Device drivers**: large firmware buffers, DMA control regions, and MMIO mappings via `ioremap()` use vmalloc infrastructure.
- **→ Buddy allocator**: calls `alloc_page()` for each backing physical page.
- **→ Hardware MMU**: installs PTEs directly in the kernel's master page tables; all CPUs share the kernel portion of their page tables so no per-process TLB flush is needed, but a global IPI is required when unmapping.
- **← SLUB**: `kvmalloc()` falls back to vmalloc when kmalloc fails; SLUB itself never calls vmalloc.

## Design Decisions & Tradeoffs

**Lazy TLB flushing (v2.6.28).** Freeing a vmalloc region requires invalidating TLB entries on every CPU — an expensive IPI storm. Early Linux did this immediately on each `vfree()`. The v2.6.28 rewrite batched these into a deferred flush: freed ranges accumulate and are invalidated together. The cost is that freed VA space cannot be immediately reused (it might still be in remote TLBs), but the IPI overhead is amortised dramatically.

**RB-tree for VA space management (v2.6.28).** The original vmalloc area was managed as a linked list. With only a handful of vmalloc regions this was fine; with hundreds of loaded modules and driver firmware regions it became O(n) per allocation. The switch to a red-black tree gives O(log n) allocation and freeing.

**Guard pages.** Every vmalloc region gets a guard page at its end. This costs one wasted virtual address page but catches buffer overflows immediately rather than letting them corrupt adjacent allocations silently. The guard page adds no physical memory overhead — it is simply unmapped.

**vmalloc vs. highmem (historical).** On 32-bit systems, the kernel's direct-map only covered the first ~896 MB of RAM; the rest was "highmem" accessible only through temporary mappings. vmalloc was sometimes used as an escape hatch on such systems. On 64-bit, the entire physical memory can be direct-mapped, so vmalloc is purely about large/fragmented allocations, not address space limits.

## How It Has Evolved

| Version | Change | Driver |
|---------|--------|--------|
| Linux 1.0 | Basic vmalloc, linked-list VA tracking | Module loading needs |
| v2.6.28 (2008) | Full rewrite: RB-tree, lazy TLB flushing, per-CPU frontends | Module explosion; TLB flush IPI storm |
| v5.13 (2021) | Huge page support for vmalloc mappings | Large vmalloc regions suffer TLB pressure with 4 KB pages |
| v6.12 (2024) | `vrealloc()` — in-place vmalloc resize | Rust's allocation patterns; avoids allocate-copy-free cycle |

## Further Reading

1. [kernel-internals.org/mm/vmalloc/](https://kernel-internals.org/mm/vmalloc/) — design, RB-tree, guard pages, lazy TLB, evolution
2. [kernel.org — Memory Allocation Guide](https://static.lwn.net/kerneldoc/core-api/memory-allocation.html) — when to use vmalloc vs. kmalloc vs. kvmalloc
3. `/proc/vmallocinfo` — runtime inspection of all active vmalloc mappings

## LKML Highlights

- **vmalloc rewrite (Nick Piggin / Ingo Molnar, v2.6.28, 2008)** — the patch description details why the original O(n) linked-list approach collapsed under module load pressure and how lazy TLB flushing avoids per-free IPI storms; a clean example of a necessary rewrite driven by real measurement, not speculation.
