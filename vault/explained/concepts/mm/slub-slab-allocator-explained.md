---
title: "SLUB Slab Allocator — Explained"
category: explained
original: "[[slub-slab-allocator]]"
subsystem: mm
tags: [explained, mm, slab, kmalloc, hardening]
converted: 2026-09-25
---

# The SLUB slab allocator, explained

> Plain-language companion to [[slub-slab-allocator|the technical note]]. Same facts, fewer identifiers.

## The problem

The kernel is full of small objects: a directory-cache entry is about 192 bytes, a task descriptor a few kilobytes. The page allocator hands out whole 4 KB pages. Giving each small object its own page would waste 95% or more of it.

The kernel also allocates and frees these objects constantly, on every CPU, often in hot paths, so the small-object allocator has to be nearly free in the common case. And because kernel heap bugs (use-after-free, overflows) are a favourite attack target, it should make those bugs hard to exploit and easy to catch.

## The idea in one paragraph

Cut pages into equal-sized slots, with **one cache per object type**. Think of **a vending machine per type**. Each CPU has its own tray of ready slots (the current **slab**, a page carved into slots), and taking one is instant: grab the front slot and move a pointer, no lock. When the tray empties, refill from a shared back-room stock of partly used slabs. Only if that's empty does anyone call the warehouse (the page allocator) for a fresh page.

## Step by step

### Step 1: Create caches
Each object type worth its own cache registers one, giving a name, size, alignment, flags and optional constructor. For general-purpose `kmalloc`, there's a set of ready-made size classes: 8, 16, 32, 64, 96, 128 bytes and up to 8 KB. A 100-byte request takes a 128-byte slot, wasting 28 bytes, far better than a whole page. (The 96-byte class exists specially to cut waste for a commonly used size range.)

### Step 2: The fast path: one atomic swap
Each CPU tracks its current slab and a pointer to its first free slot. Free slots are chained through a "next free" pointer stored *inside* each free slot. Allocating means: take the first free slot and advance the pointer to the next.

This is the key step. It's done as one atomic compare-and-swap on the pair (free pointer, transaction ID). The transaction ID changes whenever the CPU is preempted or its slab is replaced. If an interrupt or preemption sneaks in between reading the free pointer and swapping it, the ID no longer matches, the swap fails, and the allocator simply retries. That prevents a classic race (where a pointer is changed and changed back, so it looks untouched) without taking a lock.

### Step 3: The slow path: find another slab
If this CPU's slab has no free slots:
1. use one of this CPU's spare partly used slabs, if any
2. otherwise take one from the per-NUMA-node list of partly used slabs (under that list's lock)
3. otherwise allocate a fresh page (or small block of pages) from the page allocator, carve it into slots, and use it

### Step 4: Freeing
If the object belongs to this CPU's current slab, it's pushed back on the free chain: one store, no lock. Otherwise the slow free path updates that slab's own free chain and moves the slab between "full", "partly used" and "empty" as needed. Empty slabs are eventually returned to the page allocator.

### Step 5: Hardening
Because the design is simple, security features layer on cleanly:
- **scrambled free pointers:** each "next free" pointer is XORed with a per-cache secret and the slot's address, so an attacker can't forge the chain without the secret
- **randomised slot order** in each new slab, defeating predictable heap spraying
- **poisoning:** freed objects are filled with a known byte pattern and checked later, catching writes after free
- **red zones:** guard bytes around each object catch overflows
- **KFENCE:** about 1 in 1000 allocations is placed on a page surrounded by guard pages, catching use-after-free and out-of-bounds bugs in production at near-zero cost
- **zero on allocate / zero on free:** boot options that prevent leaking old data

### Step 6: Per-CPU spare slabs
Originally a CPU had just one active slab and went straight to the locked per-node list when it ran out. Adding a few spare partly used slabs per CPU cuts that lock traffic substantially on workloads with heavy allocate/free churn.

## The picture

```text
 kmem cache "dentry" (192-byte slots)
   CPU 0: current slab [■][□][□][■][□]   free chain: □ → □ → □
          spare slabs: [■■□□□] [■■■□□]
   CPU 1: current slab [■][■][□][□][□]
   node lists: partly used slabs (lock) ── empty? ──▶ page allocator

 allocate:  swap (free pointer, transaction id) atomically → take first □
            fails? (preempted / interrupted) → retry
 free (same slab):  push onto free chain, no lock
 ■ = in use   □ = free
```

## Tradeoffs

- **What it gives you:** small-object allocation that's usually a single atomic operation, low waste, good cache locality (same-sized objects share pages), and room for strong hardening.
- **What it costs / requires:** some rounding waste per object from the size classes; memory held in per-CPU and partly used slabs.
- **Where it bites:** the allocator tracks only free versus in use, not who holds an object, so reference counting and lifetime bugs are the owner's problem. Full debugging (red zones, poisoning) has significant overhead, which is why KFENCE's sampling approach exists for production.

## How it got here

- **2.6.22 (2007):** SLUB introduced by Christoph Lameter and made the default, replacing SLAB, whose per-CPU "magazines" and cache colouring were hard to audit. His argument was that simpler code is correct code; the performance difference was marginal.
- **2.6.39 (2011) and 5.7 (2020):** per-CPU spare slab lists, then more of them, to reduce slow-path trips.
- **5.17 (2022):** a dedicated type for cache flags. **6.1:** slab tracking split into its own structure, separate from the page descriptor.
- **6.4 (2023):** SLOB removed. **6.8 (2024):** SLAB removed; SLUB is the only slab allocator.

## Related

- Technical version: [[slub-slab-allocator]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[buddy-allocator-explained|Buddy allocator]]: where slab pages come from
- [[per-cpu-page-allocator-pcp-explained|Per-CPU page allocator]]: serves many of those page requests
- [[vmalloc-explained|vmalloc]]: the fallback for large allocations
- [[memory-cgroup-explained|Memory cgroups]]: charging kernel objects to groups
- [[kernel-hardening|Kernel hardening]]
