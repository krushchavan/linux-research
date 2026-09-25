---
title: "The bio Layer — Explained"
category: explained
original: "[[bio-layer]]"
subsystem: block
tags: [explained, block, bio, io-submission, stacking]
converted: 2026-09-25
---

# The bio layer, explained

> Plain-language companion to [[bio-layer|the technical note]]. Same facts, fewer identifiers.

## The problem

Everything that does disk I/O (filesystems, page-cache writeback, swap, direct I/O, device-mapper, software RAID) needs one common way to say: "move these pieces of memory to or from these sectors of that device, and tell me when it's done." Without it, every filesystem would need to know every device's size, alignment and segment limits. It gets harder with **stacked** devices (dm on top of RAID on top of NVMe), where each layer submits new I/O to the layer below. Naive recursion could overflow the kernel stack, and since writeback is how memory gets freed, the I/O path must keep working even when memory has run out.

## The idea in one paragraph

The unit of I/O is a **bio**, a **shipping manifest**: a list of memory pieces to pick up from or deliver to (a scatter-gather list), one destination range on disk (a start sector and a length), the operation (read, write, discard, flush…), and a return address (a completion callback). Once handed off, the manifest's list is **never rewritten**. Each handler keeps its own small **progress card** saying how much is left. So one manifest can be split into pieces, or cloned, cheaply: each piece gets its own progress card pointing into the same list.

## Step by step

### Step 1: Allocate from a reserve
Bios come from a **bio set**: a slab cache plus a **mempool** of reserved bios, so a bio needed to write out memory under pressure can always be allocated eventually. Stacking drivers keep **their own** bio set so they don't drain the pool the layer above depends on. Small bios keep their memory list inline; larger ones get a separate list of up to 256 entries.

### Step 2: Fill in the manifest
The submitter sets the start sector and completion callback, then adds memory page by page or folio by folio. Since 5.1, one list entry can cover **several physically contiguous pages**, so a 2 MB folio is one entry rather than 512. Adding refuses when the bio is full, telling the caller to submit it and start another. Direct I/O pins the user's pages and fills the list straight from the user's buffer description.

### Step 3: Never rewrite the list
Since 3.13, the memory list is frozen once submitted; all progress (current sector, bytes left, position in the list) lives in a small iterator. Before that, drivers edited the list in place as they worked through it, which made sharing a list between bios impossible and splitting awkward. Now advancing only moves the iterator, and helpers hand out single-page or multi-page segments from it.

### Step 4: Submit, asynchronously
Submission accounts the I/O, then runs generic checks: past the end of the device? A partition sector to remap to the whole disk? An unsupported operation? If the device has no volatile write cache, flush and force-unit-access flags are stripped (an empty flush finishes immediately). cgroup hooks may hold the bio back to enforce I/O limits. Submission returns straight away; a waiting variant exists for callers that need it.

### Step 5: Flatten stacked submissions
This is the key step for stacking. The outermost submission sets up a **per-task list** and loops. When a stacked driver submits new bios from inside its handler, they're only **appended** to that list, and the outer loop processes them one after another. Stack depth stays constant however deep the device stack is.

That created a deadlock: a driver could split a bio, queue the first half (sitting unsubmitted on the list), then block allocating a bio for the second half from a pool whose bios were all sitting on that same list. The first fix gave every bio set a **rescuer** thread to push queued bios along, which meant dozens of mostly idle threads per machine (28 on a small notebook in one 2017 report). NeilBrown's 4.11 fix solved the ordering instead: each round processes bios for **lower** devices before those at the **same** level, and splitting drivers resubmit the remainder rather than keep it. That guarantees depth-first progress; rescuers became opt-in.

### Step 6: Two kinds of destination
Before dispatch, the bio takes a reference on the device's queue, which is how a queue can be **frozen** while its settings change (a no-wait bio fails with "try again" instead of sleeping). Then:
- **bio-based** devices (dm, RAID, RAM disks, zram, pmem, NVMe multipath) receive the raw bio and do what they like with it
- **request-based** devices send it to [[blk-mq-explained|blk-mq]], where it's merged into, or becomes, a request

### Step 7: Split late, near the device
Since 4.3, filesystems may build bios **as large as they like**. Just before a bio becomes a request, it's checked against the device's limits (maximum size, segment count and size, boundary rules, alignment for discard or atomic writes). If it's too big, the front part is split off as a new bio **sharing the same memory list** with its own iterator, which is possible only because the list is immutable. The split is chained to the original and the rest resubmitted. Split bios come from the queue's own pool, so splitting can't deadlock on the submitter's pool.

### Step 8: Complete once
A chained parent counts its outstanding pieces; each piece's completion decrements it, and the parent's callback runs only when all are done, so the filesystem sees **one completion** however many pieces the device needed. The first error is kept. The driver sets a small status code (an enum since 4.13, translated to an errno only at the top, so transport errors can guide multipath retries) and completes the bio, often from interrupt context; for page-cache I/O the callback marks folios up to date or ends writeback. Integrity metadata can ride along and be checked at completion.

### Step 9: Fast paths
**Per-CPU bio caches** (5.15) let io_uring and polled direct I/O, which complete in task context, reuse bios without touching the slab allocator, about a 10% throughput gain above 3.5 million IOPS per core. **Plugging** lets a task batch a burst of bios, flushing them together when it finishes the batch or goes to sleep, so it can never deadlock on I/O it's still holding.

## The picture

```text
 filesystem builds bio: [page][page][2 MB folio] → sectors 1000–5095, WRITE, callback
        │ submit (async): checks, cgroup limits
        ▼
 per-task list (no recursion): lower-level bios first
        │
   bio-based driver (dm/md/zram) ──clone/remap──▶ new bios appended to list
   request-based ──▶ split to device limits (pieces share the list, own iterators)
                     └─ chained: parent completes once, when all pieces are done
```

## Tradeoffs

- **What it gives you:** one uniform I/O unit for everyone; cheap splitting and cloning; constant stack depth with deep device stacks; guaranteed forward progress under memory pressure.
- **What it costs / requires:** every stacking layer must own its own reserve pool, or layers can starve each other. Splitting late costs extra allocations when upper layers build bios bigger than the device takes. The immutable-list conversion was a large, tree-wide change, and some old fields became untrustworthy for drivers.
- **Where it bites:** bio-based drivers skip blk-mq's request allocation, merging and scheduling, but also lose its tag-based back-pressure and must provide their own. The flattening that bounds stack use introduced ordering deadlocks that took two attempts to fix.

## How it got here

- **2.5.1 (2001–2002):** Jens Axboe's bio replaced queuing one buffer head per block; one large I/O became one object.
- **2.6.39:** per-task plugging.
- **3.13–3.14:** immutable memory lists and iterators (Kent Overstreet).
- **4.3:** arbitrary-size bios, split in one place near the device instead of asking "may I add this page?" for every page.
- **4.11:** NeilBrown's depth-sorted processing; rescuer threads optional. **4.13:** status enum instead of errno.
- **5.1:** multi-page list entries (Ming Lei, a years-long series). **5.15:** per-CPU bio cache. **5.18:** allocation binds device and operation up front; cloning helper.
- **6.x:** folio-native interfaces, block sizes larger than a page, atomic writes (6.11), and exploration of physical-range entries to decouple I/O from page structures.

## Related

- Technical version: [[bio-layer]]
- [[blk-mq-explained|blk-mq]], [[io-scheduler|I/O scheduler]], [[io-controller-explained|I/O controller]], [[block-explained|Block layer]], [[device-mapper-explained|Device mapper]], [[dm-integrity-explained|dm-integrity]]
- [[page-cache-explained|Page cache]], [[writeback-infrastructure-explained|Writeback]], [[swap-explained|Swap]], [[folio-explained|Folio]], [[get-user-pages-and-pinning-explained|Page pinning]], [[io-uring-internals-explained|io_uring internals]]
