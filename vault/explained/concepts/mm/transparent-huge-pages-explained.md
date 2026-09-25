---
title: "Transparent Huge Pages — Explained"
category: explained
original: "[[transparent-huge-pages]]"
subsystem: mm
tags: [explained, mm, thp, huge-pages, tlb]
converted: 2026-09-25
---

# Transparent huge pages, explained

> Plain-language companion to [[transparent-huge-pages|the technical note]]. Same facts, fewer identifiers.

## The problem

Covering 2 MB of memory with ordinary 4 KB pages takes 512 page-table entries, and potentially 512 slots in the CPU's translation cache (TLB), plus up to 512 page faults to fill them in. Programs that walk large areas of memory miss the TLB constantly.

Explicit huge pages (hugetlbfs) fix that but require applications to be changed and memory to be reserved in advance. Most programs will never do that. The question is whether the kernel can use big pages *automatically*, without breaking anything, and without wasting memory when a program only touches a bit of a big page.

## The idea in one paragraph

Back large regions of memory with 2 MB pages **silently**, whenever it looks worthwhile, and fall back to normal pages whenever it doesn't work out. One 2 MB mapping means one TLB entry and one page fault instead of 512 of each. Two paths create huge pages: at fault time, if a 2 MB block is available, and later, by a background thread that merges runs of small pages. When a huge page gets in the way (partial unmap, protection change, pinning), it's split back into small pages. The tension to manage: one used page inside an otherwise empty 2 MB page wastes 2044 KB.

## Step by step

### Step 1: At fault time, try for 2 MB
When anonymous memory is first touched, the kernel checks: is the address in an aligned 2 MB slot, is the region big enough, and does the system policy allow huge pages here? If so, it asks the page allocator for a 2 MB block, possibly triggering compaction depending on the "defrag" setting. On success it sets up the block as one unit (a head page plus 511 tails, with the head's count authoritative) and installs a **single 2 MB entry** in the page table. On failure, it quietly falls back to a normal 4 KB page. The program sees no difference either way.

### Step 2: Reads can use a shared huge zero page
A *read* of never-written memory can map a single, system-wide, pre-zeroed 2 MB page read-only, delaying real allocation until the program writes.

### Step 3: Merge later in the background
Regions that grew through small faults aren't caught at fault time. A kernel thread, **khugepaged**, periodically scans registered regions for runs of 512 small pages it could merge. For each, it takes the process's memory lock for writing, allocates a 2 MB block, copies the 512 pages in, replaces their 512 entries with one 2 MB entry, and frees the originals. It can tolerate some gaps (unmapped entries become zeros) and some swapped-out pages (brought back in first), each up to a tunable limit; more tolerance means more successful merges but more wasted memory.

Since 5.18 a program can also ask for an immediate, synchronous merge of a region it knows has become hot and stable (useful for JIT compilers).

### Step 4: Splitting when needed
Sometimes a huge page must become small pages again:
- **changing protection or unmapping part of it:** part of one 2 MB entry can't be changed
- **pinning part of it for I/O**
- **reclaim** of a huge page that's only partly hot (though since 4.13, a huge page used by one process can be swapped out whole)

There are two kinds of split. A cheap one (4.5) splits only one process's 2 MB *mapping* into 512 small entries, leaving the underlying huge page intact for others. A full split breaks up the huge page itself; it fails if any part is pinned.

### Step 5: Defer splitting until memory is tight
This is the key balance between speed and waste. Since 5.18, a huge page that has been partly unmapped isn't split immediately. It goes on a **deferred split queue**, and a background scan every second sorts up to 256 huge pages by how much of them is used (0–25%, 25–50%, 50–75%, 75–100%); the half-empty ones are queued. Under memory pressure, a shrinker splits them and recovers the unused parts. Splitting eagerly on every partial unmap would churn the allocator.

### Step 6: Sizes between 4 KB and 2 MB (6.8)
2 MB is all or nothing: if the allocation fails, the fallback is straight to 4 KB. **Multi-size THP** adds intermediate sizes, any power of two from 16 KB to 1 MB, each with its own on/off setting. Allocation tries the largest enabled size and steps down. This keeps fewer faults and fewer TLB entries even when 2 MB blocks can't be found; on Ampere Altra servers, Memcached ran about 20% faster with 64 KB pages.

### Step 7: Files and shared memory
The original version (2.6.38) was for anonymous memory only, which is private and self-contained. tmpfs/shared memory came next (3.8). Huge pages in the page cache for regular files is an ongoing effort, not yet available for every filesystem.

### Step 8: Why walkers must be careful
A 2 MB entry sits at the level where a pointer to a page of small entries would normally be. Any code walking page tables must check for a huge entry first; following it as if it pointed to a table would be a guaranteed crash.

## The picture

```text
 NORMAL:  2 MB region = 512 small entries → up to 512 TLB slots, 512 faults
 THP:     2 MB region = 1 huge entry      → 1 TLB slot, 1 fault

 fault in aligned 2 MB slot ──▶ 2 MB block available? ── yes → map huge
                                        │ no
                                        ▼
                                 map 4 KB page (fallback)
 khugepaged (later): 512 small pages ──copy──▶ 1 huge page, 1 entry

 partial unmap ──▶ deferred split queue ──(memory pressure)──▶ split, free unused parts
 mTHP: try 1 MB → 512 KB → ... → 16 KB → 4 KB
```

## Tradeoffs

- **What it gives you:** fewer TLB misses and far fewer page faults for large working sets, with no application changes.
- **What it costs / requires:** needs contiguous 2 MB blocks, hence compaction work; khugepaged spends CPU copying pages; partly used huge pages waste memory until split.
- **Where it bites:** setting it to "always" can hurt workloads with many small, short-lived allocations (Redis, some databases): pages get merged only to be freed, and allocation latency suffers from compaction. Many distributions now default to "only where the program asks" (madvise), and there are per-process controls to turn it off, or off except where requested.

## How it got here

- **2.6.38 (2011):** anonymous THP and khugepaged, 2 MB only (Andrea Arcangeli), after debate about whether "always" was safe for latency-sensitive workloads.
- **3.8 (2013):** tmpfs/shared memory. **4.5 (2016):** splitting one process's mapping without splitting the page.
- **4.13 (2017):** swapping a huge page out whole (Ying Huang).
- **5.4 (2019):** experimental huge pages for read-only ext4 files in the page cache.
- **5.18–6.1 (2022):** explicit synchronous merging, the deferred split shrinker, and a per-process "off except where advised" option.
- **6.8 (2024):** multi-size THP (Ryan Roberts), after debate over its complexity and fragmentation risk.

## Related

- Technical version: [[transparent-huge-pages]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[huge-pages-hugetlbfs-explained|hugetlbfs]]: the explicit, reserved alternative
- [[folio-explained|Folios]]: the large-page type underneath
- [[memory-compaction-explained|Memory compaction]], [[buddy-allocator-explained|Buddy allocator]]: where 2 MB blocks come from
- [[page-fault-handler-explained|Page fault handler]], [[page-reclaim-explained|Page reclaim]], [[swap-explained|Swap]]
- [[page-table-management-explained|Page table management]]
