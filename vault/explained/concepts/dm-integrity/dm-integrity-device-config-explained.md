---
title: "dm-integrity Device Configuration — Explained"
category: explained
original: "[[dm-integrity-device-config]]"
subsystem: dm-integrity
tags: [explained, dm-integrity, device-mapper, configuration]
converted: 2026-09-25
---

# dm-integrity's per-device configuration, explained

> Plain-language companion to [[dm-integrity-device-config|the technical note]]. Same facts, fewer identifiers.

## The problem

Every I/O through a dm-integrity device needs to know a lot: which mode the device runs in, how big tags are, where the tag for a given sector lives, which hash to use, how the journal is laid out. Working that out from the table text on every request, or opening a hash algorithm per request, would be impossibly slow. And settings must agree with what's already on disk, or tags will be read from the wrong place.

## The idea in one paragraph

Build a single per-device object, **the nerve centre of the volume**, once, when the device is created. It parses the configuration, checks it against the on-disk superblock, opens the hash and cipher algorithms, opens a cache over the tag area, and sets up memory pools and background workers. Every I/O then works through a pointer to it. When the device is removed, everything is torn down in reverse.

## Step by step

### Step 1: Parse the table
Device mapper calls dm-integrity's constructor with the table line. The required parts are the backing device, the number of reserved sectors at the front, the tag size in bytes, and the mode: journaled, direct, bitmap, inline, or a recovery mode. Optional settings follow: internal hash, journal encryption and authentication, block size, chunk size, journal size, cache size, journal fill threshold, commit interval, discard support, and a couple of compatibility fixes.

### Step 2: Work out the layout
From the tag size and block size (512 bytes by default), the constructor computes how many data sectors go in each chunk, how many sectors of tags each chunk needs, and how many journal sections there are.

### Step 3: Check against the disk
This is the key safety step. If the device already has a superblock, its layout values are read from disk and compared with the table. Any mismatch fails setup. Otherwise tags would be looked for in the wrong places and every read would look corrupt, or worse.

### Step 4: Open the algorithms
If an internal hash is given (for example CRC32C, or HMAC-SHA256 with a key), it's opened once and kept. The constructor checks that the tag size can hold the hash's output. If journal encryption or a journal MAC is requested, those algorithms are opened too.

### Step 5: Open a cache over the tag area
All tag reads and writes go through a block cache (dm-bufio) over the tag region, rather than raw I/O. Besides keeping hot tags in memory, this avoids a real race: two requests for neighbouring sectors often need the *same* tag sector, and the cache gives per-buffer locking so they don't clobber each other.

### Step 6: Reserve memory and start workers
Two reserved memory pools are set up, one for per-request work objects and one for pages used while computing tags. Worker queues are created for the journal committer and the background task that copies journal data to its final place.

### Step 7: Teardown
When the device is removed, the journal is flushed, the superblock is saved (including how far any recalculation has progressed), the algorithms are closed, the cache is torn down and the pools freed.

## The picture

```text
 table line ──▶ constructor
                  │ parse: device, reserved sectors, tag size, mode, options
                  │ compute layout ──▶ compare with on-disk superblock (mismatch → fail)
                  │ open hash / journal cipher / journal MAC
                  │ open tag-area cache (locking + LRU)
                  │ reserve pools, start committer + flusher
                  ▼
     ┌──── per-device object ────┐
     │ mode · tag size · layout  │ ◀── every I/O uses this
     │ hash · cache · recalc pos │
     └───────────────────────────┘
 removal ──▶ flush journal, save superblock, close everything
```

## Tradeoffs

- **What it gives you:** all configuration work done once, with the on-disk format enforced, and safe concurrent access to shared tag sectors.
- **What it costs / requires:** the cache adds some memory and bookkeeping over raw I/O.
- **Where it bites:** layout settings can't be changed on an existing device; a table that disagrees with the superblock is refused, and changing them means reformatting.

## How it got here

- **4.12 (2017):** the original object, with direct and journaled modes, internal hash and journal protection. Milan Broz chose to go through the block cache rather than raw I/O, and to store the mode as a single character for future extension.
- **4.18:** bitmap-mode fields.
- **5.7:** discard support.
- **6.11:** inline-mode handling.

## Related

- Technical version: [[dm-integrity-device-config]]
- [[dm-integrity-explained|dm-integrity]]: the subsystem overview
- [[dm-integrity-on-disk-layout-explained|dm-integrity-on-disk-layout]]: the layout this object computes and checks
- [[dm-integrity-bitmap-mode-explained|Bitmap mode]], [[dm-integrity-journal-explained|dm-integrity-journal]]
- [[dm-bufio-explained|dm-bufio]]: the tag-area cache
- [[device-mapper-explained|Device mapper]], [[kernel-crypto-api-explained|Kernel crypto API]]
