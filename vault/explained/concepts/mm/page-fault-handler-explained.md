---
title: "Page Fault Handler — Explained"
category: explained
original: "[[page-fault-handler]]"
subsystem: mm
tags: [explained, mm, page-faults, demand-paging, cow]
converted: 2026-09-25
---

# The page fault handler, explained

> Plain-language companion to [[page-fault-handler|the technical note]]. Same facts, fewer identifiers.

## The problem

Linux hands out memory lazily. `mmap` returns an address range instantly without allocating anything, and `fork` copies a process without copying its memory. That only works if something fills in the real memory later, at the exact moment a program first touches an address.

The CPU helps: when it can't translate an address (no mapping, or a write to a read-only page), it stops and asks the kernel. But the kernel then has to tell apart very different situations: a fresh page being touched for the first time, a page shared after `fork` that now needs its own copy, a page that was swapped out to disk, a file page not yet read in, or a genuine bug (a bad pointer). And it has to fix the expected cases fast enough that programs only notice a small delay.

## The idea in one paragraph

Virtual addresses are **promises**. `mmap` writes a promise ("this range is yours") but delivers nothing. The page fault handler is the **delivery service**: the moment a program actually uses a promised address, it works out what kind of delivery is needed, obtains the right physical page, installs the mapping, and restarts the instruction, which now succeeds as if nothing happened. A read of fresh memory gets a shared page of zeros (cheap). A first write gets a private zeroed page. A write to memory shared after `fork` gets a copy. A swapped-out page is brought back from storage.

## Step by step

### Step 1: The CPU reports the fault
On x86, the CPU raises a page-fault exception, records the faulting address, and encodes some context: was the page missing or was this a protection violation, was it a read or a write, did it happen in user or kernel mode, and was it an instruction fetch from non-executable memory. The kernel's entry point reads all of this.

### Step 2: Kernel address or user address?
- **Kernel address:** it might be a new kernel mapping that hasn't been copied to this CPU's tables yet, which is fixed on the spot. Or it might be an *expected* fault inside the functions that copy to and from user memory (see step 10). Anything else is a kernel bug and produces an oops.
- **User address:** the main path, below.

### Step 3: Find the memory region, without the big lock if possible
The handler needs the VMA covering the address. Since 6.4 it first tries to look it up with only RCU and lock just that one VMA, checking a sequence counter to make sure nothing changed concurrently. If that fails, it falls back to the process-wide memory lock and a normal lookup in the maple tree.

This is a key performance step: on multi-threaded programs, faults in different regions no longer queue behind one process-wide lock.

### Step 4: Check permissions
A write to a region that isn't writable gets SIGSEGV. A fault just below the stack region may grow the stack. Otherwise the handler walks the page tables down to the right entry, allocating intermediate tables if needed.

### Step 5: Decide what kind of fault it is
Looking at the page-table entry and the region:
- **no entry, anonymous memory:** demand-zero (step 6)
- **no entry, file-backed memory:** file fault (step 7)
- **entry says "swapped out":** swap-in (step 9)
- **entry present but read-only, and this is a write:** copy-on-write (step 8)

### Step 6: Anonymous memory: zero on demand
A **read** of never-written memory maps the single, system-wide **zero page** read-only. No allocation at all. This saves a lot of memory for large zeroed areas that are read but never written. A **write** allocates a fresh zeroed page from the page allocator and maps it writable. Physical memory appears only when a byte is actually written.

### Step 7: File-backed memory
- **Read:** look up the page in the page cache. If it's there, map it read-only. If not, trigger readahead and wait for the disk. That makes it a **major fault** (one that needed I/O).
- **Write to a private mapping:** read the file page, copy it into a new private page, map that. The file's cached copy is untouched.
- **Write to a shared mapping:** bring the page into the cache, let the filesystem know it's about to be dirtied, and map it writable. The change reaches the file via writeback.

### Step 8: Copy-on-write
After `fork`, parent and child share every anonymous page read-only. On the first write by either:
- if only one holder remains, flip the mapping to writable in place, no copy
- otherwise allocate a new page, copy the contents, drop a reference to the old page, and map the copy writable. The other process keeps the original.

### Step 9: Swap-in
The entry records which swap device and slot hold the page. The handler first checks the **swap cache**, which holds pages in transit between swap and RAM; a hit avoids I/O entirely. On a miss it reads the page from swap, waits, and installs the mapping. The page stays in the swap cache briefly in case another process faults on the same entry.

### Step 10: Report the outcome, retry, or recover
Every sub-handler returns a set of outcome flags: out of memory (invoke the OOM path), invalid access (SIGBUS), needed I/O (counted as major), or "retry": the per-VMA lock wasn't enough, so the fault is redone under the process-wide lock.

For the kernel's own user-copy functions, a fault at a known location jumps to a recovery stub that returns "bad address" to the caller, instead of crashing. That's how system calls cope with bad user pointers.

## The picture

```text
 CPU: can't translate address X ──▶ page-fault exception (address, read/write, user/kernel)
        │
        ├─ kernel address ─▶ fix kernel mapping │ user-copy recovery │ else oops
        │
        └─ user address ─▶ find VMA (per-VMA lock, else process lock)
                             │ permission bad → SIGSEGV
                             ▼
              ┌──────────────┼───────────────┬─────────────────┐
         no entry,        no entry,        swap entry      present, read-only,
         anonymous        file-backed                       write
     read → zero page  page cache hit/   swap cache or      only holder → make writable
     write → new page  miss → disk I/O   read from swap     else copy → private page
              └──────────────┴───────────────┴─────────────────┘
                             ▼
                 install mapping → re-run the instruction
```

## Tradeoffs

- **What it gives you:** instant `mmap` and `fork`, memory used only when touched, huge savings from the shared zero page, and transparent swap and file mapping.
- **What it costs / requires:** a delay on the first touch of every page, and a complex handler that must cover every case eager allocation would have handled up front.
- **Where it bites:** major faults (disk I/O) are slow and show up as latency spikes. Per-VMA locking added a retry path and a sequence check on every fault, a price accepted because process-lock usage on the fault path dropped to near zero for multi-threaded programs. Before 4.17, fault handlers returned plain integers that were easily confused with error codes; a distinct return type (Christoph Hellwig) now makes the compiler catch that.

## How it got here

- **Linux 1.0:** basic handling of missing pages, write protection and swap-in.
- **2.4:** dispatch through the memory region, with per-region fault functions for file-backed mappings.
- **2.6:** huge-page and NUMA fault paths.
- **4.17 (2018):** a dedicated return type for fault outcomes.
- **6.1 (2022):** VMA lookup via the maple tree, a prerequisite for lock-free lookup.
- **6.4–6.6 (2023):** per-VMA locks on the fault path, then extended to swap and user-space fault handling.

## Related

- Technical version: [[page-fault-handler]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[virtual-memory-areas]], [[maple-tree-explained|Maple tree]]: how the VMA is found
- [[page-cache-explained|Page cache]]: file-backed faults
- [[swap-explained|swap]]: swap-in
- [[buddy-allocator-explained|Buddy allocator]]: where new pages come from
- [[page-table-management-explained|page-table-management]], [[page-reclaim-explained|page-reclaim]], [[oom-killer-explained|OOM killer]]
