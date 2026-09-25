---
title: "dm-integrity Bitmap Mode — Explained"
category: explained
original: "[[dm-integrity-bitmap-mode]]"
subsystem: dm-integrity
tags: [explained, dm-integrity, bitmap, crash-recovery]
converted: 2026-09-25
---

# dm-integrity bitmap mode, explained

> Plain-language companion to [[dm-integrity-bitmap-mode|the technical note]]. Same facts, fewer identifiers.

## The problem

dm-integrity keeps a tag (checksum) for every sector, and the tag must match the data even after a crash. Its journaled mode guarantees that by writing everything twice: once to a journal, once to its final place. That halves write throughput.

For big sequential workloads, such as backup storage or database data files, halving throughput makes dm-integrity impractical. Is there a cheaper way to survive a crash?

## The idea in one paragraph

If the tag is a plain hash of the data, it can always be **recomputed** from the data. So instead of making data and tag update atomically, just remember *which regions were being written* when the crash happened, and afterwards recompute their tags. A **dirty-region map** (a bitmap, one bit per region) does the remembering: set the bit before writing, clear it after. After a crash, every region still marked dirty gets its tags recalculated. No journal, no double write.

## Step by step

### Step 1: Mark the region dirty first
When a write arrives, dm-integrity sets the bit for the region it touches *before* sending any I/O. This ordering is the whole trick: if a crash happens at any point after this, the region is known to be suspect.

### Step 2: Write data and tag directly
The data goes straight to its permanent location and the tag to the tag area (through the tag cache). No journal.

### Step 3: Clear the bit once it's safely down
After both writes have completed, the bit is cleared. There is never a moment where the bit is clear but the data isn't yet on disk.

### Step 4: Save the bitmap now and then
The bitmap lives in memory and is written to its own area on disk periodically, every 10 seconds by default. This is the one weakness: if the machine crashes long after the last save, the on-disk bitmap may not show every region that was dirty, and some tags could be missed on recovery. A shorter interval narrows that gap at the cost of more metadata writes.

### Step 5: After a crash, recalculate
At startup, dm-integrity reads the saved bitmap. A background worker visits every dirty region, reads the data, recomputes each tag, writes it, and then clears the bit and updates the superblock.

This is the key step. Because the tag is a deterministic function of the data, recomputing always yields a correct tag for whatever data is on disk.

### Step 6: Know what it can't catch
If a data write itself was torn by the crash, recalculation writes a tag that matches the torn data. The integrity system then agrees with data that is actually wrong. Bitmap mode repairs *tag* inconsistency caused by the crash; it doesn't detect data damaged by it. That is the accepted limitation.

### Step 7: Why dm-crypt can't use it
When dm-crypt sits on top in authenticated mode, its tags are produced with the encryption key over the plaintext. dm-integrity can't regenerate them during recovery. So bitmap mode requires dm-integrity's own internal hash, and dm-crypt stacks must use journaled mode.

## The picture

```text
 write to region R:
   1. set bit R = 1      (before any I/O)
   2. write data ──▶ final location
      write tag  ──▶ tag area
   3. both done → set bit R = 0

 bitmap saved to disk every ~10 s

 crash with bit R = 1 on disk
   └─▶ at startup: read R's data → recompute tags → write tags → clear bit
```

## Tradeoffs

- **What it gives you:** full direct-write throughput, with crash-induced tag mismatches repaired automatically.
- **What it costs / requires:** an internal hash (CRC or HMAC computed by dm-integrity); a recalculation pass after crashes; periodic bitmap writes.
- **Where it bites:** tags can end up "blessing" torn data, and a crash long after the last bitmap save can leave some dirty regions unrecalculated. Not usable under dm-crypt's authenticated mode.

## How it got here

- **4.18 (2018):** introduced by Mikulas Patocka, who argued the journal's 2× write cost made dm-integrity impractical for backup and archive workloads. The review settled on making the internal hash a hard requirement.
- **5.x:** the bitmap save interval became tunable at runtime.
- **5.7:** discarded sectors get the tag for all-zero data directly, avoiding a full recalculation.

## Related

- Technical version: [[dm-integrity-bitmap-mode]]
- [[dm-integrity-explained|dm-integrity]]: the subsystem overview
- [[dm-integrity-journal-explained|dm-integrity-journal]]: the double-write alternative
- [[dm-integrity-recalculation-explained|dm-integrity-recalculation]]: the worker that repairs dirty regions
- [[dm-bufio-explained|dm-bufio]]: the tag cache
- [[dm-crypt-explained|dm-crypt]]: why its tags need journaled mode
