---
title: "Writeback Infrastructure — Explained"
category: explained
original: "[[writeback-infrastructure]]"
subsystem: fs
tags: [explained, fs, writeback, dirty-throttling, cgroups]
converted: 2026-09-25
---

# Writeback, explained

> Plain-language companion to [[writeback-infrastructure|the technical note]]. Same facts, fewer identifiers.

## The problem

If every `write()` waited for the disk, programs would crawl. So Linux writes into memory (the page cache) and returns at once, flushing to disk later. That's **writeback**. But deferring writes raises hard questions:
- When must data finally reach the disk, even if nobody asks?
- What if programs dirty memory faster than the disk can take it?
- How do you stop one slow device, such as a USB stick, from stalling writes to fast ones?
- How does `fsync` guarantee a specific file is safely on disk, and report errors correctly?
- How do per-container I/O limits apply to writes that are flushed later by kernel threads?

## The idea in one paragraph

Run a **write-behind cache** with a **per-device flusher**. Programs write into RAM and return; per-device kernel threads drain dirty data to storage at a rate matched to each device's measured bandwidth. If programs dirty data faster than it can be drained, they're made to **pause briefly**, in proportion to how far over budget things are: back-pressure that matches input to output. `fsync` bypasses the laziness for one file and waits for everything. Container-aware writeback runs a separate flusher per (device, cgroup) pair so limits apply to the right owner.

## Step by step

### Step 1: Marking dirty
Writing a page sets its dirty flag and marks its inode as having dirty pages. If the inode was clean, it moves onto its device's **dirty inode list** and records when it was first dirtied (for the age limit). Metadata-only changes (timestamps, size, block map) set different dirty flags; with the "lazytime" option, timestamp-only changes get their own lighter flag.

### Step 2: One flusher per device
Each block device has a backing-device record holding one or more **writeback engines**, each with lists (dirty inodes, inodes being written, inodes put off till later this round, timestamp-only inodes), a flusher thread, and bandwidth estimates. A slow device's thread blocking on I/O can't hold up an SSD's writeback. That replaced a shared pool of 2–8 "pdflush" threads, which a slow device could tie up; per-device threads brought 25%+ throughput gains on multi-disk systems.

### Step 3: When the flusher runs
- **Periodically:** every 5 seconds (default), writing inodes first dirtied more than 30 seconds ago, however much dirty budget is left.
- **On demand:** for `sync`, `fsync`, or when dirty levels get too high.

Each piece of work specifies which filesystem (or all), how many pages, background or synchronous mode, and a range. For each inode, the filesystem finds dirty pages (via the dirty tag in the page cache index), submits them, and marks them "under writeback" until the I/O completes. Then the inode's own metadata is written. A fully clean inode moves back to the clean list.

### Step 4: Throttling writers smoothly
This is the key step. After roughly every 32 pages it dirties, a writing process checks two thresholds:
- **background** (10% of available RAM by default): wake the flushers
- **foreground** (20%): slow the writers

Between them, a writer is paused for a time **proportional** to how far above the background level the system is, capped at 200 ms. Per-process allowances keep pauses in the 10–100 ms range: if pauses would be under 10 ms, the process may dirty more before checking again; if over 100 ms, less. Above the foreground threshold, writers simply block until things drop back. Absolute byte limits can replace the percentages.

Before this (2.6.37, Wu Fengguang), writers ran freely until the limit and then *all* blocked at once: a cliff that caused bursts of I/O and latency spikes. The hard part was estimating device bandwidth without benchmarks; the answer was a moving average of recent completion rates.

### Step 5: The USB-stick problem
With only a global threshold, writing to a slow USB stick could fill the whole machine's dirty budget, and then every writer, even to the SSD, stalled for seconds while the stick drained. Per-device dirty limits sized by each device's measured bandwidth fixed this.

### Step 6: fsync
`fsync` asks the filesystem to write and wait for every dirty page in the file (or range), write the inode's metadata, and flush the device's write cache when the semantics require it.

Errors must reach the right callers. Each file records a sticky error sequence, and each open file description has its own cursor, so each one sees each error **exactly once**. Before 4.13, `fsync` errors could be missed (another caller cleared them first) or reported repeatedly.

### Step 7: Cgroup-aware writeback (4.2)
Before this, per-container I/O limits didn't work for buffered writes: the I/O controller only saw anonymous flusher-thread I/O. Now each (device, cgroup) pair gets its own writeback engine whose flusher runs on behalf of that cgroup, and throttling applies both the system-wide and the cgroup's own limits, whichever is stricter. Which cgroup owns an inode is decided lazily by a **majority vote** over recent writes to it, rather than tracking an owner per page (which would cost 8+ bytes per page, about 8 MB per 4 GB of RAM). It converges quickly when one writer dominates a file, as is typical.

## The picture

```text
 write() ──▶ page dirty, inode on device's dirty list ──▶ return
                 │ every ~32 pages: check thresholds
                 │   < 10%: fine   10–20%: pause proportionally (≤200 ms)   > 20%: block
                 ▼
 per-device flusher (and per cgroup+device):
     every 5 s: write inodes dirty > 30 s
     on demand: sync / fsync / pressure
          write dirty pages → mark "under writeback" → I/O done → clean
          then write inode metadata
 fsync(file): write + wait for its pages → metadata → device cache flush → error once per open
```

## Tradeoffs

- **What it gives you:** instant writes, merged and batched I/O, steady rather than bursty flushing, isolation between slow and fast devices, per-container accounting, and reliable `fsync` error reporting.
- **What it costs / requires:** data isn't durable until written back or `fsync`ed; one flusher thread per device (and per cgroup pair); bandwidth estimation that can lag real conditions.
- **Where it bites:** heavy writers feel throttling as mysterious pauses. Dirty pages can't be reclaimed until written, so heavy dirtying adds memory pressure. Ownership by majority vote can mis-attribute files written by several cgroups.

## How it got here

- **2.4:** a global flush daemon and one global dirty threshold.
- **2.6.0:** a pool of pdflush threads.
- **2.6.32 (2009):** per-device flusher threads and per-device dirty limits (Jens Axboe, over 18 revisions), replacing pdflush.
- **2.6.37 (2011):** proportional dirty throttling (Wu Fengguang); per-process pause tuning followed.
- **4.2 (2015):** cgroup-aware writeback (Tejun Heo), added alongside the default path rather than as a rewrite.
- **4.13 (2017):** per-open-file error sequences for `fsync`. **5.8 (2020):** lazytime's timestamp-only dirtiness formalised.

## Related

- Technical version: [[writeback-infrastructure]]
- [[page-cache-explained|Page cache]], [[address-space-explained|Address space]]: where dirty pages live
- [[inode-cache-explained|Inode cache]]: dirty inodes can't be evicted
- [[page-reclaim-explained|Page reclaim]]: writing pages under memory pressure
- [[memory-cgroup-explained|Memory cgroups]], [[io-controller|I/O controller]], [[block-explained|Block layer]]
- [[fs-explained|Filesystem subsystem (VFS)]]
