---
title: "Page Table Management — Explained"
category: explained
original: "[[page-table-management]]"
subsystem: mm
tags: [explained, mm, page-tables, tlb, mmu]
converted: 2026-09-25
---

# Page table management, explained

> Plain-language companion to [[page-table-management|the technical note]]. Same facts, fewer identifiers.

## The problem

Every memory access a program makes uses a *virtual* address that the CPU's memory management unit (MMU) must translate to a *physical* one. The MMU does this by reading **page tables** that the kernel builds for each process. Without correct tables, a process can't touch its own memory; without efficient management of them, every fault, `fork`, `exec` and `munmap` becomes expensive.

There are a few complications. Address spaces are huge (up to 128 PiB of virtual space) but sparsely used. Different CPU architectures use different numbers of table levels. Many threads fault at once. And the CPU caches translations in its **TLB**, so whenever the kernel changes a table, it must make sure no CPU keeps using a stale cached translation.

## The idea in one paragraph

Page tables are **nested arrays, each exactly one page (4 KB)**. Each entry either points to the next array down or, at the bottom, holds a physical page number plus permission bits. A virtual address is chopped into pieces: each piece indexes one level, and the last 12 bits are the offset within the page. The hardware walks these arrays by itself and caches the results; the kernel keeps them accurate, builds lower levels only when needed, and tells every CPU when a cached translation must be thrown away.

## Step by step

### Step 1: Up to five levels
Linux uses a generic five-level hierarchy. On x86-64 with 57-bit addresses, each level uses 9 bits of the address (512 entries per table):

| Level | Each entry covers |
|---|---|
| top (PGD) | 128 PB / 512 |
| P4D | 512 GB |
| PUD | 1 GB |
| PMD | 2 MB |
| PTE (bottom) | 4 KB, one page |

### Step 2: Fold away levels you don't have
Most machines don't use all five. A CPU in four-level mode (48-bit addresses) skips one; ARM64 with 4 KB pages and 39-bit addresses uses three. The unused levels are **folded**: at compile time their lookup becomes a no-op. Generic kernel code always "walks five levels", and the compiler removes the ones that don't exist, at zero runtime cost. That's how adding a new level (in 4.11) touched only generic code and one architecture instead of every driver.

### Step 3: What an entry holds
A bottom-level entry on x86-64 holds the physical page number and bits such as:
- **present:** valid; if clear, access faults
- **writable** and **user-accessible**
- **accessed:** set by hardware on any access, used by reclaim to judge what's hot
- **dirty:** set by hardware on any write
- **no-execute:** code can't run from this page

At the 2 MB or 1 GB level, a "page size" bit makes that entry the bottom: it maps a whole huge page directly.

### Step 4: Build tables on demand
Each process gets its own top-level table; lower tables are created only when memory is actually used. On a page fault, the kernel walks down from the top, and at each level where the entry is empty, it allocates a new zeroed table and installs it with an **atomic compare-and-swap**. If two CPUs race to fill the same slot, one wins and the other frees its table and uses the winner's.

At the 2 MB level, if the region can use a huge page and a contiguous 2 MB block is available, a huge entry is installed directly and the bottom level is skipped. Otherwise, the bottom-level fault handling takes over (new zero page, read from file, copy-on-write...).

The kernel's own mappings live in a reference top-level table whose kernel half is copied into every new process's top-level table (on architectures that don't keep kernel tables separate).

### Step 5: Lock finely
Originally one per-process spinlock protected all page-table changes, and multi-threaded programs faulting at once serialised on it. Now:
- the per-process lock only protects the upper levels (installing or removing whole mid-level tables)
- each bottom-level and 2 MB-level table has **its own spinlock**, kept in the descriptor of the page holding that table

So CPUs faulting in different areas don't contend. The rules are strict: holding a bottom-level lock, you may not take the per-process lock.

### Step 6: Keep TLBs honest
This is the key step for correctness. When an entry changes, other CPUs may still have the old translation cached. The kernel must invalidate it:
- **one page:** invalidate locally, and send an inter-processor interrupt (IPI) to every CPU that recently ran this process
- **a big unmap:** flushing page by page would be disastrous, so the kernel **gathers**: it clears all the entries, collects the freed pages, then does *one* batched flush, and only after that frees the pages. N interrupts become one.
- **lazy mode:** a CPU running a kernel thread never touches user page tables, so it's skipped for flush interrupts unless the tables themselves are being freed
- **address-space tags (PCID):** on x86 CPUs that support it, TLB entries are tagged per address space, so switching processes doesn't wipe the TLB

### Step 7: A generic walker
Beyond faults, a reusable walker lets other code inspect or change page tables by supplying callbacks per level, plus one for holes. It handles huge entries correctly. It's used for per-process memory reports, NUMA balancing, KSM (merging identical pages) and more.

## The picture

```text
 virtual address (x86-64, 5-level):
 [ 9 bits | 9 bits | 9 bits | 9 bits | 9 bits | 12-bit offset ]
     │        │        │        │        │
    top ──▶  P4D ──▶  PUD ──▶  PMD ──▶  PTE ──▶ physical page + offset
                                │
                           huge page bit? → 2 MB page, stop here

 each table = one 4 KB page, 512 entries; missing tables built on first fault
 per-table spinlocks at the bottom levels

 munmap: clear entries ... collect pages ... ONE batched TLB flush ... free pages
```

## Tradeoffs

- **What it gives you:** hardware-native translation (the tables are exactly what the MMU walks), cheap sparse address spaces, instant `mmap` and near-constant-time `fork` (copy-on-write), one codebase from two-level embedded chips to five-level servers.
- **What it costs / requires:** a full table page per level for any mapping deep in the tree; careful locking and TLB invalidation on every change; code that must respect folded levels.
- **Where it bites:** TLB shootdowns across many CPUs are expensive, which is why batching, lazy mode and tags matter. The Meltdown mitigation (page-table isolation) keeps separate kernel and user tables and switches between them on every kernel entry and exit, costing about 1%.

## How it got here

- **1991:** two levels, hard-coded for 32-bit i386.
- **1999 (2.2):** three levels on x86 (PAE) to reach 64 GB of physical memory.
- **2005 (2.6.11):** four levels for x86-64, 48-bit addresses; the middle levels added to generic code with folding for 32-bit.
- **2012–2013:** per-table locks at the bottom level (3.7), then at the 2 MB level.
- **2017 (4.11–4.14):** the P4D level added generically (Kirill Shutemov), then five-level tables on x86-64, reaching 57-bit virtual and 52-bit physical addresses.
- **2018 (4.15):** page-table isolation against Meltdown. **2020–2022:** preparation to drop the old 32-bit temporary-mapping path, and folios reaching page-table code. A 2018 proposal to unify all per-level walk code stalled over the flag-day conversion it required.

## Related

- Technical version: [[page-table-management]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[page-fault-handler-explained|Page fault handler]]: the main user of the fault-time walk
- [[virtual-memory-areas]]: the *intent* that page tables implement
- [[rmap-reverse-mapping-explained|rmap-reverse-mapping]]: finding page-table entries from a physical page
- [[transparent-huge-pages-explained|transparent-huge-pages]], [[huge-pages-hugetlbfs-explained|hugetlbfs]]: huge entries at higher levels
- [[swap-explained|swap]], [[numa-memory-policy-explained|NUMA memory policy]]
