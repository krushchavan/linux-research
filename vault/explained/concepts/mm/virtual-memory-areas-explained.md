---
title: "Virtual Memory Areas — Explained"
category: explained
original: "[[virtual-memory-areas]]"
subsystem: mm
tags: [explained, mm, vma, mmap, address-space]
converted: 2026-09-25
---

# Virtual memory areas (VMAs), explained

> Plain-language companion to [[virtual-memory-areas|the technical note]]. Same facts, fewer identifiers.

## The problem

Every process needs its own private, coherent view of memory: a stack, a heap, its program code, mapped files and shared libraries, each at stable addresses and with its own rules (readable, writable, executable, shared or private), isolated from every other process.

The kernel has to know, for any address a process touches, whether that access is legitimate and what should happen: allocate a fresh page, copy a shared one, read part of a file, or deliver a segfault. And it has to clean all of it up when the process exits. Page tables alone can't answer this, because most of them are filled in lazily, only after first use.

## The idea in one paragraph

Keep, per process, a list of **ranges with rules**. If page tables are a detailed street map showing every building that has actually been built, VMAs are the **zoning plan**: "this block is residential (anonymous, writable), this one is commercial (read-only file mapping), this one is industrial (device memory, no execute)". `mmap` only draws a new zone. Buildings (physical pages) go up on first use, following the zone's rules.

## Step by step

### Step 1: A VMA is a range plus rules
Each VMA records a start and end address, permissions and other flags, what backs it (a file and an offset into it, or nothing for anonymous memory), and a table of operations saying how to handle faults in it. The process's memory descriptor holds all its VMAs, along with the pointer to its top-level page table and a few totals (mapped size, locked size, heap and stack boundaries).

### Step 2: Creating one with `mmap`
When a process maps memory, the kernel:
1. **finds a gap** big enough in the address space
2. **tries to merge** with a neighbouring VMA that has identical backing, flags and permissions, so no new record is needed. This keeps the number of VMAs down (and memory maps readable).
3. otherwise **creates** a new VMA and inserts it

No physical memory is allocated. `mmap` returns immediately; pages arrive on first touch.

### Step 3: One tree instead of two structures (6.1)
VMAs used to be kept in a balanced binary tree *and* a linked list, updated together on every change. That was a source of bugs, had poor cache behaviour, and couldn't be read without a lock. Since 6.1 they live in a single **maple tree** (Liam Howlett, Oracle), a B-tree built for ranges, which lock-free readers can walk under RCU. Writers still take the process's memory lock.

### Step 4: Faults dispatch through the VMA
When a fault hits an address, the handler finds the covering VMA and follows its rules. Anonymous VMAs have no fault operation and get a zero-filled page. File-backed VMAs go to the filesystem's handler, which fills from the page cache. Device VMAs may map raw device memory directly.

### Step 5: Per-VMA locks (6.4)
This is the key performance step. Historically every fault took the process-wide memory lock, so many threads faulting in *different* regions queued behind one lock. Now each VMA has its own lock with a sequence counter. The fault path first looks up the VMA under RCU only and locks just that VMA; if the sequence counter shows it changed meanwhile, it retries under the process-wide lock. Structural changes (insert, split, delete, merge) still need the process-wide lock, but it has disappeared from the common fault path. In production, time spent on that lock dropped below 0.1% of CPU, and TCP zero-copy improved by about 0.5% CPU. 6.6 extended this to swap faults and user-space fault handling.

### Step 6: Splitting and unmapping
Unmapping part of a VMA splits it at the edges (leaving up to two pieces), removes the page-table entries for the unmapped range, and invalidates TLBs.

### Step 7: fork and stack growth
`fork` copies every VMA into the child and marks pages copy-on-write in both. A fault just below the stack VMA can grow the stack downward.

## Useful flags

- **read / write / execute:** copied into page-table entries when pages are installed
- **shared:** changes are visible to every mapping of the file
- **grows down:** the stack
- **locked:** `mlock`ed; never paged out
- **raw device mapping:** no page descriptors behind it (device registers)
- **don't copy on fork**, **don't expand on remap**, and **counts toward overcommit**

## The picture

```text
 process address space (zoning plan)          page tables (buildings so far)
 ┌──────────────────────────────┐
 │ stack    rw-  grows down      │ ─── only touched pages have entries
 │ ...gap...                     │
 │ libc.so  r-x  file, offset 0  │ ─── filled from page cache on first touch
 │ heap     rw-  anonymous       │ ─── zero pages on first write
 │ program  r-x  file            │
 └──────────────────────────────┘
      stored in one maple tree; each VMA has its own lock (6.4)

 mmap: find gap → merge with neighbour? → else new VMA   (no RAM allocated)
 fault at X: find VMA (RCU + VMA lock) → follow its rules → install page
```

## Tradeoffs

- **What it gives you:** instant `mmap` and `malloc`, cheap `fork`, overcommit, and a clear rulebook for every address.
- **What it costs / requires:** a fault on first access to every page; a merge check on every `mmap`; the maple tree is a new, intricate structure (around 3000 lines); per-VMA locks add a few bytes per VMA and a retry path.
- **Where it bites:** getting rid of the process-wide lock took years of failed approaches (range locks, RCU-only lookups, lock-free fault paths) before the per-VMA design won. Structural changes still serialise on it.

## How it got here

- **Linux 1.0:** VMAs in a linked list.
- **2.6 (2002):** an augmented red-black tree alongside the list, for processes with many VMAs.
- **6.1 (2022):** the maple tree replaces both.
- **6.4 (2023):** per-VMA locks on the fault path.
- **6.6 (2023):** per-VMA locks extended to swap faults and user-space fault handling. The locking protocol was documented in 2024 (Lorenzo Stoakes).

## Related

- Technical version: [[virtual-memory-areas]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[maple-tree-explained|Maple tree]]: where VMAs are stored
- [[page-fault-handler-explained|Page fault handler]]: follows the VMA's rules
- [[page-table-management-explained|Page table management]]: the "buildings"
- [[page-cache-explained|Page cache]], [[rmap-reverse-mapping-explained|Reverse mapping]], [[oom-killer-explained|OOM killer]]
