---
title: "dm-integrity On-Disk Layout — Explained"
category: explained
original: "[[dm-integrity-on-disk-layout]]"
subsystem: dm-integrity
tags: [explained, dm-integrity, on-disk-format, layout]
converted: 2026-09-25
---

# The dm-integrity on-disk layout, explained

> Plain-language companion to [[dm-integrity-on-disk-layout|the technical note]]. Same facts, fewer identifiers.

## The problem

For every sector a program reads through dm-integrity, the tag (checksum) for that sector has to be found and checked. If finding the tag needed a lookup in some index structure, every read would cost an extra I/O just to locate it. And the format has to stay readable by later kernel versions.

## The idea in one paragraph

Lay the device out in three fixed zones, in order: a **superblock** describing everything, a **journal** for crash recovery, and then **chunks** where each run of data sectors is preceded by the tags that cover it. Because the chunk size is a power of two, the position of any sector's tag is pure arithmetic: a shift, a mask and an add. No index, no extra I/O to find it. Everything needed for that arithmetic is recorded in the superblock.

## Step by step

### Step 1: The superblock anchors everything
The first 4 KiB (eight 512-byte sectors) after any reserved space is the superblock. It holds:
- a magic string marking the device as dm-integrity formatted
- a format version, for forward-compatible changes
- the chunk size, stored as a power of two
- the tag size in bytes
- the number of journal sections
- the usable data size, which the virtual device must not exceed
- how far background tag recalculation has progressed

### Step 2: Formatting a new device
If the usable data size in the superblock is zero, the device needs formatting. dm-integrity first loads as a tiny one-sector device, reads (or writes) the superblock, then reloads at the full size recorded there.

### Step 3: The journal comes next
The journal is a series of sections, each with a 4 KiB metadata area and a data area. Metadata entries record each sector's destination, the last 8 bytes of its data, and its tag. The rest of the data goes in the data area. Every 512-byte sector of the journal ends with an 8-byte commit ID, and a section is valid after a crash only if all its commit IDs match. (Details in [[dm-integrity-journal-explained|the journal]].)

### Step 4: Data and tags, interleaved in chunks
After the journal come chunks. Each chunk is:
- a **tag area**: just enough sectors to hold the tags for the chunk's data
- a **data area**: exactly one chunk's worth of data sectors (32,768 by default)

### Step 5: Finding a tag is arithmetic
This is the key step. For logical sector *s*:
1. which chunk: shift *s* right by the chunk size's power of two
2. position within the chunk: mask off the low bits
3. tag location: journal end + chunk number × (tag area + data area) + position × tag size

Because of the power-of-two constraint, the chunk calculation is a shift and a mask instead of a division. At most two I/Os are needed to verify a sector: one for the tag sector, one for the data.

### Step 6: Why tags sit right before their data
On spinning disks, putting each tag area right before the data it covers keeps the tag on the same or a nearby track, so verifying a read barely moves the head. On SSDs position doesn't matter for latency, but the two-I/O bound still holds.

### Step 7: Fixed at format time
Chunk size, block size (512 to 4096 bytes) and journal size are chosen when formatting and recorded in the superblock. A bigger chunk means fewer chunk boundaries but coarser cache misses. A bigger journal allows bigger bursts of writes before background copying must catch up.

## The picture

```text
 ┌──────────┬───────────┬────────────────────────┬─────────────────────────┬───
 │ reserved │superblock │ journal sections        │ chunk 0                 │ chunk 1 ...
 │ (option) │  4 KiB    │ [meta|data][meta|data]  │ [tags][data × 32768]    │ [tags][data...]
 └──────────┴───────────┴────────────────────────┴─────────────────────────┴───

 tag for sector s:
   chunk  = s >> log2(chunk size)
   offset = s & (chunk size − 1)
   tag at  journal_end + chunk × (tag sectors + chunk size) + offset × tag size
```

## Tradeoffs

- **What it gives you:** tag lookup with no index and at most two I/Os per verified read; a format later kernels can open.
- **What it costs / requires:** chunk size must be a power of two, and layout parameters can't change without reformatting. Tag areas consume capacity in proportion to the device size.
- **Where it bites:** a badly chosen chunk size or journal size is permanent for the life of the volume.

## How it got here

- **4.12 (2017):** superblock, journal and interleaved data and tags, format version 1. Milan Broz argued the power-of-two constraint was fine for its target, server storage with large sequential writes.
- **5.x:** the recalculation-progress field added to the superblock.
- **6.11:** inline mode skips the interleave entirely, storing tags in the extra per-sector space some disks provide, so data sectors map one-to-one.

## Related

- Technical version: [[dm-integrity-on-disk-layout]]
- [[dm-integrity-explained|dm-integrity]]: the subsystem overview
- [[dm-integrity-journal-explained|The journal]]: the zone after the superblock
- [[dm-integrity-device-config-explained|Device configuration]]: computes and checks this layout
- [[dm-bufio-explained|dm-bufio]]: caches the tag areas
