---
title: "Virtual Memory Areas"
category: concept
tags: [memory, mm, vma, address-space, mmap, maple-tree]
subsystem: mm
kernel_version: "1.0+"
researched: 2026-04-05
status: complete
explained: "[[virtual-memory-areas-explained]]"
sources:
  - https://kernel-internals.org/mm/mmap/
  - https://lwn.net/Articles/919547/
  - https://lwn.net/Articles/892724/
  - https://lwn.net/Articles/997398/
  - https://lwn.net/Articles/787629/
---

# Virtual Memory Areas

> 📘 Plain-language version: [[virtual-memory-areas-explained]]

## Purpose

Every process needs a private, coherent view of memory — its own stack, heap, mapped files, and shared libraries at stable addresses, isolated from every other process. VMAs are how the kernel tracks and manages that view. A VMA (Virtual Memory Area) is a record saying: *"this virtual address range exists, has these permissions, and is backed by this source."* Without VMAs, the kernel would have no way to know whether a fault at a given address is legitimate or should deliver a segfault, what should happen on a write (allocate? copy-on-write? error?), or how to clean up when a process exits.

## Mental Model

The kernel's page table is like a detailed city street map marking exactly where every building (physical page) stands. VMAs are the zoning plan: broad regions with rules — "this block is residential (anonymous, writable), this one is commercial (read-only file mapping), this one is industrial (device MMIO, no execute)." The page table populates itself lazily as buildings are constructed (demand paging), but the zoning plan always says what's *supposed to be* there.

## How It Works

When a process calls `mmap(NULL, size, PROT_RW, MAP_ANON|MAP_PRIVATE, -1, 0)`, the kernel calls `do_mmap()` → `mmap_region()`. This function:

1. **Finds a free gap** in the process's virtual address space using the maple tree — a B-tree of VMAs indexed by address range. It scans for a region large enough for the request.
2. **Tries to merge** the new VMA with an adjacent existing VMA that has identical backing, flags, and permissions (`vma_merge()`). If a merge succeeds, no new `vm_area_struct` is allocated.
3. **If not mergeable**, allocates a new `vm_area_struct`, fills in `vm_start`, `vm_end`, `vm_flags`, `vm_file` (NULL for anonymous), `vm_ops` (operation dispatch table), and inserts it into the maple tree.

Critically, no physical memory is allocated. `mmap()` returns the virtual address immediately; the physical page arrives only on first access via a page fault.

**The Maple Tree (v6.1).** Before v6.1, VMAs were stored in an augmented red-black tree *and* a doubly-linked list — two structures kept in sync by every insert, split, and delete. This dual structure was the source of multiple correctness bugs, made concurrent access complex, and could not support RCU-safe reads. The maple tree (developed by Liam Howlett at Oracle) is a B-tree variant optimised for range queries and RCU-safe concurrent reads. A single data structure replaced both. Readers can call `mt_find()` under RCU without holding any lock; writers take the `mmap_lock`.

**Per-VMA locks (v6.4).** Historically, every VMA read or write — including page fault handling — required holding the `mmap_lock` on `mm_struct`. On a multi-threaded process where many threads fault simultaneously on *different* VMAs, they all serialised on this one rwsem. The per-VMA lock adds an seqlock to each `vm_area_struct`. The fault path now calls `lock_vma_under_rcu(mm, addr)` first: if the VMA is stable (seqcount unchanged since the RCU lock), the fault proceeds under just the VMA's lock — no `mmap_lock` held. Concurrent faults on different VMAs proceed in parallel. The `mmap_lock` is still required for structural changes (insert, split, delete, merge) but disappears from the common fault path.

The measured impact on production systems: `mmap_lock` dropped below 0.1% of total CPU cycles; TCP zerocopy improved by ~0.5% CPU.

**Fault dispatch.** Each VMA has a `vm_ops` pointer. When a page fault occurs on an address within a VMA, the fault handler reads `vm_ops->fault` to determine what to do. Anonymous VMAs have no `vm_ops` and fall through to `do_anonymous_page()`. File-backed VMAs point to filesystem-specific handlers that call `filemap_fault()`. Device VMAs may install PFN mappings directly.

**VMA splitting and munmap.** When `munmap()` unmaps part of a VMA, the kernel splits the VMA at the unmapped boundaries (creating up to two residual VMAs), removes page-table entries for the unmapped range, and performs TLB invalidation. The maple tree's range semantics make this efficient.

## Key Data Structures

**`struct mm_struct`** (`include/linux/mm_types.h`) — one per process; the root of the address space.
- `mm_mt` — maple tree holding all VMAs, indexed by `[vm_start, vm_end)`
- `pgd` — root page-table pointer; the CPU's CR3 (x86) or TTBR (ARM) points here
- `mmap_lock` — rwsem; taken for write on structural VMA changes; increasingly bypassed by per-VMA locks for reads
- `total_vm` — total mapped pages (sum of all VMA sizes)
- `locked_vm` — `mlock()`ed pages; never swapped
- `start_brk` / `brk` — heap boundaries; `brk()` syscall extends `brk`
- `start_stack` — top of stack (grows down)

**`struct vm_area_struct`** (`include/linux/mm_types.h`) — one VMA.
- `vm_start` / `vm_end` — `[start, end)` virtual address range
- `vm_flags` — `VM_READ`, `VM_WRITE`, `VM_EXEC`, `VM_SHARED`, `VM_GROWSDOWN`, `VM_LOCKED`, `VM_PFNMAP`, …
- `vm_ops` — function table: `fault`, `huge_fault`, `open`, `close`, `mremap`
- `vm_file` — backing file for file-backed VMAs; NULL for anonymous
- `vm_pgoff` — offset into `vm_file` in pages; used to locate the right folio in the page cache
- `vm_lock` — per-VMA seqlock (v6.4+); enables lockless fault handling
- `vm_lock_seq` — seqcount for the per-VMA lock

## Key Functions / Entry Points

**`do_mmap(file, addr, len, prot, flags, pgoff)`** (`mm/mmap.c`) — called by `mmap()` syscall; performs permission checks, size alignment, then calls `mmap_region()`.

**`mmap_region(file, addr, len, vm_flags, pgoff)`** (`mm/mmap.c`) — core VMA creation: gap finding, merge attempt, VMA allocation, tree insertion.

**`find_vma(mm, addr)`** (`mm/mmap.c`) — maple tree lookup; returns the VMA covering `addr` or the next one above it; used by fault handler and `mprotect()`.

**`vma_merge()`** (`mm/mmap.c`) — try to extend an adjacent VMA; avoids creating a new `vm_area_struct`.

**`do_vmi_align_munmap()`** (`mm/mmap.c`) — unmap a virtual range; splits VMAs at boundaries, removes PTEs, shoots down TLBs.

**`lock_vma_under_rcu(mm, addr)`** (`mm/memory.c`) — try to acquire a per-VMA read lock without `mmap_lock`; called first in the fault path (v6.4+).

**`expand_stack(vma, addr)`** (`mm/mmap.c`) — grow the stack VMA downward on stack-overflow fault.

## Important Flags & Config Options

| Flag | Meaning |
|------|---------|
| `VM_READ` / `VM_WRITE` / `VM_EXEC` | Page protection; set in PTEs when pages are installed |
| `VM_SHARED` | Changes are visible through all file mappings of this file |
| `VM_GROWSDOWN` | Stack region; `expand_stack()` may grow it downward |
| `VM_LOCKED` | `mlock()`; pages never paged out; fault-in on mmap |
| `VM_PFNMAP` | Raw PFN mapping; no `struct page`; used for device MMIO |
| `VM_DONTCOPY` | Do not copy this VMA across `fork()`; used by some device drivers |
| `VM_DONTEXPAND` | `mremap()` may not enlarge this VMA |
| `VM_ACCOUNT` | Count this VMA towards committed address space for overcommit checking |
| `CONFIG_USERFAULTFD` | Enable `userfaultfd`; adds `vm_userfaultfd_ctx` to each VMA |

## Interactions with Other Subsystems

- **↑ Userspace**: `mmap()`, `munmap()`, `mprotect()`, `madvise()`, `mlock()`, `mremap()`, `mincore()` all create, modify, or query VMAs.
- **→ Page fault handler**: fault handler calls `find_vma()` to locate the VMA and dispatches via `vm_ops->fault`.
- **→ Page cache**: file-backed VMAs point `vm_file` at an open file; fault handling calls `filemap_fault()` to populate the page cache and install the PTE.
- **← `fork()`**: `dup_mmap()` copies all VMAs into the child's `mm_struct`, marking pages as COW in both parent and child PTEs.
- **← OOM killer**: `oom_kill_process()` reads `mm->total_vm` and the VMA tree to compute the OOM score.
- **↓ Hardware MMU**: PTE entries installed by the fault handler correspond to VMA-defined permissions; the MMU enforces them in hardware on every access.

## Design Decisions & Tradeoffs

**Demand paging.** VMAs describe address ranges without allocating physical pages. Physical pages are created on first access. This makes `fork()` cheap (copy VMAs, mark pages COW — no page copying), `malloc()` instant (just extend the heap VMA), and overcommit possible. Cost: one page-fault latency on first access.

**Merge adjacent VMAs.** The kernel tries to merge a new VMA with its neighbours if they have identical properties. This reduces the number of `vm_area_struct` objects in memory and makes `/proc/<pid>/maps` output more readable. Cost: merge check on every `mmap()`.

**Maple tree over red-black tree + linked list (v6.1).** The dual data structure was a source of correctness bugs (the RB-tree and list had to stay in sync across every modification), was not RCU-safe, and had poor cache locality. The maple tree is a single structure, RCU-safe, and stores multiple entries per node (better cache behaviour for range scans). Cost: a new, less familiar data structure; the tree implementation itself is ~3000 lines.

**Per-VMA locks over mmap_lock (v6.4).** The `mmap_lock` was a global rwsem that serialised all page faults in a process. Per-VMA locks cost one seqlock per `vm_area_struct` (a few extra bytes per VMA) and extra complexity in the fault path (the retry path when a per-VMA lock can't be acquired). The gain: concurrent page faults on different VMAs.

## How It Has Evolved

| Version | Change | Driver |
|---------|--------|--------|
| Linux 1.0 | Basic VMA + linked list | Initial implementation |
| v2.6 (2002) | Augmented red-black tree + linked list | Large processes with many VMAs; O(log n) needed |
| v3.6 (2012) | Maple tree work begins (Liam Howlett) | mmap_lock contention and RCU prep |
| v6.1 (2022) | Maple tree replaces red-black tree + linked list | Correctness, RCU-safety, cache locality |
| v6.4 (2023) | Per-VMA locks | `mmap_lock` contention on multi-threaded fault workloads |
| v6.6 (2023) | Per-VMA locks extended to swap faults and userfaultfd | More fault types bypass mmap_lock |

## Further Reading

1. [LWN — Per-VMA locks](https://lwn.net/Articles/919547/) — design and motivation; the seqlock approach
2. [LWN — How to get rid of mmap_sem](https://lwn.net/Articles/787629/) — years of attempts before per-VMA locks succeeded; essential context
3. [LWN — Introducing the Maple Tree](https://lwn.net/Articles/892724/) — the B-tree replacement for VMAs
4. [LWN — docs/mm: add VMA locks documentation](https://lwn.net/Articles/997398/) — authoritative per-VMA lock protocol

## LKML Highlights

- **[PATCH v3: docs/mm: add VMA locks documentation](https://lore.kernel.org/all/20241114205402.859737-1-lorenzo.stoakes@oracle.com/) (Lorenzo Stoakes, Oracle, Nov 2024)** — review debate makes explicit why the seqlock-per-VMA design was chosen over RCU-only approaches; covers the `FAULT_FLAG_VMA_LOCK` → `FAULT_FLAG_RETRY` interaction that handles the case where a per-VMA lock can't be acquired.

- **[How to get rid of mmap_sem discussion](https://lwn.net/Articles/787629/) (various, 2019–2023)** — years of proposals (range locks, RCU-protected VMA lookups, lock-free fault paths) that preceded per-VMA locks; shows how hard the problem was and how many approaches were rejected before the seqlock design won.
