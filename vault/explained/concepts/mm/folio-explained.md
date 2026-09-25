---
title: "Folio — Explained"
category: explained
original: "[[folio]]"
subsystem: mm
tags: [explained, mm, folio, page-cache, thp]
converted: 2026-09-25
---

# Folios, explained

> Plain-language companion to [[folio|the technical note]]. Same facts, fewer identifiers.

## The problem

The kernel describes every 4 KB page of RAM with a small descriptor. When it needs a bigger unit (say 16 pages, or 2 MB for a huge page), it chains descriptors into a **compound page**: a "head" descriptor followed by "tail" descriptors. The important information (reference count, owning file, position in the file) lives only in the head.

The trouble: code receiving a page pointer couldn't tell from the type whether it had a head or a tail. So it had to keep asking "is this a tail? then jump to the head", and that check was scattered across thousands of places. Forgetting it meant silently reading garbage from a tail. Even when remembered, the check hid inside almost every page-flag test, and the compiler couldn't reuse its result between tests. On hot paths that extra lookup ran tens of millions of times a second.

## The idea in one paragraph

Introduce a new type, the **folio**, with one hard rule: **a folio pointer always points at the head. There are no tail folios.** Picture the old compound page as a receipt whose pages might be handed to you out of order, so you always had to check "am I holding page 1?". A folio is the same receipt, stapled at the corner, and you always hold the first page. If a function takes a folio, it has the whole unit and can ask how big it is, and the compiler enforces that.

## Step by step

### Step 1: Overlay, don't replace
This is the key design choice. The folio type sits at exactly the same memory address as the head page's descriptor (enforced at compile time). A folio pointer can therefore be treated as a head-page pointer and back again, always correctly. That let the kernel convert code **gradually**, one function at a time, instead of in one enormous flag-day rewrite: converted code uses folios, unconverted code uses pages, and passing between them is safe.

### Step 2: Cross the boundary once
Two helpers bridge old and new code:
- **page to folio:** given *any* page, head or tail, find its folio. For ordinary single pages this is free; for compound pages it follows the head link once.
- **folio to page N:** pointer arithmetic to get the Nth page inside a folio, for legacy code that needs a page.

Converted functions do the page-to-folio step once at the top and use folio operations from then on, so the head lookup is paid once instead of inside every flag test.

### Step 3: Ask how big it is
Each folio records its **order** (size as a power of two) in the head's flags. An order-0 folio is one 4 KB page, the common case. An order-9 folio is 2 MB on a 4 KB-page system, the size of a huge-page mapping.

### Step 4: Reference counting only at the folio level
Tail pages have no reference counts of their own. There are two ways to take a reference:
- **get:** only allowed if you already hold a reference. Using it on a folio whose count might be zero is a use-after-free bug.
- **try-get:** atomically bump the count only if it isn't already zero, and report failure otherwise. This is for when you found the folio in a shared structure (for example walking the page cache under RCU) and don't own it yet, because reclaim could be freeing it at that very moment.

### Step 5: The page cache stores folios
The page cache's index now holds folios. Readahead can allocate **large folios** covering many pages, so there are fewer cache entries and fewer faults. Filesystems implement their read and write operations on folios; unconverted ones go through compatibility shims.

### Step 6: Reclaim and writeback work per folio
A 2 MB folio is one entry on the LRU lists, not 512. On workloads with many large folios, LRU lists shrank by a factor of about 1000, making reclaim scans far cheaper. The flip side: reclaim can't evict *part* of a folio. It must **split** it first, which is expensive (every mapping must be torn down and rebuilt) but rare.

Dirty tracking is per folio too: dirtying one byte of a 2 MB folio writes back all 2 MB. That was accepted because most real workloads write large regions, copy-on-write filesystems need whole-unit writes anyway, and fewer, larger writebacks save more than they cost. On simple append workloads, large folios can double write throughput.

### Step 7: Large folios for anonymous memory
**Multi-size huge pages** (mTHP, 6.6) bring the same idea to process memory. On a fault, the kernel tries to allocate a larger folio (64 KB by default on arm64) instead of one 4 KB page, falling back gracefully if memory is fragmented. One fault then covers 16 pages, and on arm64 a hardware "contiguous" bit lets a 64 KB folio use a single TLB entry. That alone cut kernel compile time by about 5%.

## The picture

```text
 BEFORE: compound page                   AFTER: folio
 [head][tail][tail][tail]                [head][    ][    ][    ]
   ▲     ▲                                 ▲
   │     └ code handed a tail must         └ a folio pointer is ALWAYS here;
   │       remember to jump to head          no tail folios exist
   refcount, owner, index live here

 page (head or tail) ──"page to folio", once──▶ folio ──▶ folio operations
 folio ──"page N"──▶ individual page (for legacy code)

 LRU list:  one entry per folio   (2 MB folio = 1 entry, not 512)
```

## Tradeoffs

- **What it gives you:** type-checked "whole unit" handling, removal of countless head-page checks, much shorter LRU lists, fewer faults and TLB entries with large folios. The initial merge removed about 5 KB of kernel code.
- **What it costs / requires:** a years-long, incremental conversion across filesystems, drivers and the block layer.
- **Where it bites:** large folios bring write amplification (dirty one byte, write 2 MB) and expensive splitting when only part of a folio must be reclaimed. According to Matthew Wilcox's analysis, 80% of folio-related bugs before 5.16 came from functions that were handed tail pages and forgot to find the head, which is exactly the class the strict "no tail folios" rule removes.

## How it got here

- **5.16 (Jan 2022):** the folio type lands (Matthew Wilcox); the page cache returns folios; network filesystem and iomap code convert.
- **5.17–5.18:** the block layer, XFS, writeback, slab and most file operations converted; large folios enabled in readahead.
- **6.0–6.5:** btrfs, ext4, f2fs and tmpfs convert; folio splitting added for partial reclaim.
- **6.6 (Nov 2023):** multi-size huge pages for anonymous memory, opt-in with per-size controls; filesystems can advertise preferred folio sizes.
- **6.7–6.9:** the arm64 contiguous-entry optimisation; 1000× shorter LRU lists seen in production.
- **2025 direction:** separate folios from page descriptors entirely and shrink the per-page descriptor toward 8 bytes, recovering about 1.6% of RAM now spent on page metadata.

## Related

- Technical version: [[folio]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[page-cache-explained|page-cache]], [[address-space-explained|Address space]]: where folios are cached
- [[transparent-huge-pages]]: the compound-page machinery large folios build on
- [[page-reclaim]], [[rmap-reverse-mapping]], [[memory-cgroup-explained|memory-cgroup]]
