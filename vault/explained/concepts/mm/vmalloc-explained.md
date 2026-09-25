---
title: "vmalloc — Explained"
category: explained
original: "[[vmalloc]]"
subsystem: mm
tags: [explained, mm, vmalloc, kernel-allocation]
converted: 2026-09-25
---

# vmalloc, explained

> Plain-language companion to [[vmalloc|the technical note]]. Same facts, fewer identifiers.

## The problem

The kernel's usual allocator (`kmalloc`) returns memory that is *physically* contiguous, which the page allocator can only provide if a big enough unbroken block exists. On a system that has been running for a while, free memory is scattered, and a large request can fail even with plenty of memory free in total.

Many large kernel allocations don't actually need physical contiguity. The code using them only needs the memory to *look* contiguous: a loaded module's code, a firmware image, a big table.

## The idea in one paragraph

Grab pages from wherever they happen to be, then use the page tables to make them **appear side by side** in a dedicated region of the kernel's virtual address space. Picture a hotel where a group wants ten adjoining rooms but only scattered single rooms are free: vmalloc gives the group a master keycard that opens rooms 101, 214, 307 and 412, and to the group they feel like one suite. The keycard is the kernel page table. The price is that each page needs its own translation, so there's more TLB pressure.

## Step by step

### Step 1: A reserved window
The kernel sets aside a large range of its own virtual address space for this (many gigabytes on 64-bit), separate from the region that maps all physical memory directly and separate from user space.

### Step 2: Find a free virtual range
All current vmalloc ranges are tracked in a balanced (red-black) tree. A request searches it for a gap of the requested size plus one guard page. Before 2.6.28 this was a linked-list walk, which got unacceptably slow once hundreds of modules were loaded.

### Step 3: Allocate pages from anywhere
One page at a time is allocated from the page allocator. They can come from anywhere in RAM, need not be adjacent, and may even be on different NUMA nodes (a NUMA-aware variant prefers the local node).

### Step 4: Map them in order
Page-table entries are installed so that each page appears at the next virtual address in sequence. From then on, the range looks contiguous to any code using it.

### Step 5: A guard page at the end
Each range ends with one unmapped **guard page**. Running off the end triggers an immediate fault instead of silently corrupting the next allocation. It costs virtual address space but no physical memory.

### Step 6: Free, with lazy TLB flushing
This is the key performance trick. Freeing removes the mappings and returns the pages, but every CPU might still have the old translations cached, and flushing them needs an interrupt to every CPU, which is expensive. So freed ranges are collected and flushed **in batches**, one round of interrupts for many frees. The catch: freed address space can't be reused until the batch flush happens. (Kernel page tables are shared by all CPUs, so there's no per-process flushing to do, only this global one.)

### Step 7: Know when to use it
Because each 4 KB page needs its own TLB entry (a 256 KB area needs 64, where a physically contiguous one might need a handful), vmalloc is kept out of hot paths. Its typical users:
- loadable kernel modules (code and data)
- large driver buffers such as firmware images
- mapping device registers into the kernel
- temporary buffers for large copies from user space
- the fallback for "try `kmalloc`, else vmalloc" (`kvmalloc`), the recommended choice when the size isn't known in advance

A related call maps an existing set of pages into the vmalloc window without allocating new ones.

## The picture

```text
 physical RAM:  [ ][A][ ][ ][B][ ][ ][ ][C][ ][D][ ]   (scattered free pages)

 vmalloc window (kernel virtual addresses):
   ... [ A ][ B ][ C ][ D ][guard] ...   ← looks contiguous
         └──── page tables map each page ────┘

 vfree: unmap → pages back to allocator → range waits for the next batched TLB flush
```

## Tradeoffs

- **What it gives you:** large allocations that succeed even on fragmented systems, and overflow detection from guard pages.
- **What it costs / requires:** one TLB entry per 4 KB page, page-table setup on every allocation, and it may sleep.
- **Where it bites:** in hot paths the extra TLB pressure hurts, which is why it's reserved for large or rare allocations. Freed address space isn't reusable until the lazy flush runs. On old 32-bit systems it was also used as an escape hatch for address-space limits; on 64-bit it's purely about large or fragmented allocations.

## How it got here

- **Linux 1.0:** basic vmalloc with list-based tracking, driven by module loading.
- **2.6.28 (2008):** a full rewrite (Nick Piggin, Ingo Molnar) with the tree, lazy TLB flushing and per-CPU front ends, driven by measured slowdowns from many modules and interrupt storms on free.
- **5.13 (2021):** huge-page mappings for large vmalloc regions, to reduce TLB pressure.
- **6.12 (2024):** resizing a vmalloc area in place, prompted by Rust's allocation patterns.

## Related

- Technical version: [[vmalloc]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[buddy-allocator-explained|Buddy allocator]]: where each page comes from
- [[slub-slab-allocator-explained|SLUB]]: the physically contiguous allocator vmalloc complements
- [[page-table-management-explained|Page table management]]: how the pages are stitched together
