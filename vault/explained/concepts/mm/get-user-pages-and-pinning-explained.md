---
title: "get_user_pages and Memory Pinning — Explained"
category: explained
original: "[[get-user-pages-and-pinning]]"
subsystem: mm
tags: [explained, mm, gup, pinning, dma]
converted: 2026-09-25
---

# get_user_pages and memory pinning, explained

> Plain-language companion to [[get-user-pages-and-pinning|the technical note]]. Same facts, fewer identifiers.

## The problem

Sometimes kernel code, or hardware on its behalf, has to work directly on a process's own memory: a network card doing RDMA into a user buffer, a disk doing direct I/O, io_uring's registered buffers. Hardware uses *physical* addresses, so for as long as it holds one, that page must stay put. It can't be swapped out, moved by compaction, or reclaimed.

The kernel keeps a reference count on every page, but for years a "reference" meant the same thing no matter who took it. A page with two references might be mapped by two processes, or mapped by one and held by a device, and the kernel couldn't tell. So it couldn't know when it was safe to write a page back, move it, or share it copy-on-write. That ambiguity caused data corruption and at least one security hole.

## The idea in one paragraph

Think of a page as a hotel room and references as key cards. Normal mappings each hold an ordinary card. **get_user_pages** (GUP) is the front desk that also hands out cards to hardware. **Pinning** makes those hardware cards look different: instead of adding 1 to the count, a pin adds a big, recognisable amount (1024), or uses a separate counter for large pages. Now the kernel can ask "is this page pinned by a device?" and avoid renovating a room with hardware still inside.

## Step by step

### Step 1: The fast path, without locks
The quick version walks the process's page tables with interrupts disabled and without taking the process's memory lock. Keeping interrupts off guarantees no one can free a page table mid-walk, the same trick the CPU's own table walker relies on. If it meets anything unusual (a swapped-out page, a protection change, a huge page being split), it gives up and hands over to the slow path. Skipping the lock cut its cost from about 2.8% of cycles to about 0.05%, roughly a 10% speedup for direct-I/O-heavy workloads.

### Step 2: The slow path, which can fault pages in
The slow version takes the memory lock for reading. If a page isn't present, it triggers a normal page fault to bring it in, then checks again. The re-check matters, because another thread could unmap the page right after the fault; the loop either retries or returns fewer pages than asked.

### Step 3: Take the right kind of reference
This is the key step. Both paths end at one function that takes the reference, and it differs by intent:
- **Plain get:** add 1. For code that only needs the page descriptor to stay valid while it inspects metadata.
- **Pin:** for code that will let hardware *read or write the page's contents*. For a single page, add **1024** to the count; any page at or above 1024 counts as pinned. For large pages, where 1024 would overflow after a couple of pins, bump a dedicated **pin counter** instead.

Callers never ask for "pin" directly; they call the pinning functions, so the kernel could change how pins are counted without touching hundreds of drivers.

### Step 4: Long-term pins
An RDMA memory region may stay pinned for minutes or hours. A **long-term** pin adds stricter rules:
- pages on persistent memory accessed directly (DAX) can't be long-term pinned, because the filesystem can't be told its layout is now frozen
- the kernel may first move the page out of a zone meant for movable memory, so the pin doesn't block memory hot-unplug or the balloon driver forever

### Step 5: Release
Every pin must be undone by an unpin, which subtracts the same amount. Filesystems can ask "might this be pinned?" before writeback or truncation that must not race with a device writing.

### Step 6: The zero page
The shared all-zeros page is read-only and can never be moved. Pinning it for writing goes through copy-on-write. Pinning it for reading just returns it without counting, since there's nothing to protect.

### Step 7: The copy-on-write security fix
The old design had a hole (CVE-2020-29374). Pinning a copy-on-write page raised its count, and the kernel could then conclude "only one mapping, so let the write go ahead without copying", while the pinner still held the old physical page. The pinner then saw data written behind its back.

The fix (5.17, David Hildenbrand) marks anonymous pages as **exclusive** when exactly one process maps them writable. Only exclusive pages may be pinned for content access, and a writable anonymous page must always be exclusive. If a shared, read-only page needs pinning, the kernel first makes a private copy and pins that. Pinning therefore always means exclusive ownership, and the race is gone.

## The picture

```text
 driver: "pin these user pages for DMA"
   │
   ├─ fast path: walk page tables, interrupts off, no lock
   │     unusual entry? ─────────────────────┐
   │                                          ▼
   └─ slow path: take memory lock → fault missing pages in → re-check
                     │
                     ▼
        take reference:  plain get → count + 1
                         pin       → count + 1024   (or pin counter for large pages)
                     │
   page count ≥ 1024?  → "pinned by a device": don't move, reclaim or share it
                     │
                     ▼
               hardware DMA ... then unpin (count − 1024)
```

## Tradeoffs

- **What it gives you:** hardware can safely use user memory directly, and the kernel can tell device pins from ordinary references without making every page descriptor bigger.
- **What it costs / requires:** reusing the existing count means a page with 1024+ ordinary references would look pinned; in practice that can't happen. Long-term pins can force page migration first and block memory hot-unplug.
- **Where it bites:** long-term pins on **file-backed** pages remain an unsolved problem. A device can write to a page after the filesystem has made it read-only for writeback; Ted Ts'o documented an ext4 crash from this. Proposals for "leases" (LSFMM 2019) and for refusing such pins outright (Lorenzo Stoakes, 2023) never reached consensus.

## How it got here

- **Early kernels:** GUP with no notion of device versus metadata references; long-term RDMA pins quietly broke writeback and DAX truncation.
- **~4.x–5.0:** the lock-free fast path.
- **5.6 (2020):** John Hubbard's pinning API and the 1024 bias; 300+ call sites audited and converted where appropriate.
- **5.14:** folios arrive, with a dedicated pin counter for large pages.
- **5.17 (2022):** exclusive marking of anonymous pages, fixing the copy-on-write pinning race.
- **6.x:** file-backed long-term pinning still unresolved; 2024–2025 cleanups of the reference-taking function and of zero-page handling.

## Related

- Technical version: [[get-user-pages-and-pinning]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[folio-explained|Folios]]: where reference and pin counts live
- [[page-fault-handler-explained|page-fault-handler]], [[page-table-management-explained|page-table-management]], [[rmap-reverse-mapping-explained|rmap-reverse-mapping]]
- [[address-space-explained|Address space]]: filesystems check for pins before writeback
- [[transparent-huge-pages]]: pinned huge pages can't be split
- [[registered-resources-explained|io_uring registered buffers]], [[dma-mapping-api-explained|DMA mapping API]]
