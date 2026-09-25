---
title: "dm-integrity Journal — Explained"
category: explained
original: "[[dm-integrity-journal]]"
subsystem: dm-integrity
tags: [explained, dm-integrity, journal, atomicity, crash-consistency]
converted: 2026-09-25
---

# The dm-integrity journal, explained

> Plain-language companion to [[dm-integrity-journal|the technical note]]. Same facts, fewer identifiers.

## The problem

dm-integrity stores data in one place on disk and its tag (checksum) in another. A disk can't write two separate places atomically. If the machine crashes after the data is written but before the tag is, the next read finds a mismatch and reports an I/O error for data that is actually fine. Crash the other way round and the same happens.

So dm-integrity needs a way to make "update this sector's data *and* its tag" all-or-nothing.

## The idea in one paragraph

Use a **write-ahead log** at the block level, the same trick a journaling filesystem uses, one level lower. Every write goes first into a journal, together with its tag and destination, and the journal is "committed" in a way that reveals whether the commit completed. Only then is the data copied to its permanent place in the background. After a crash, completed journal sections are replayed and incomplete ones ignored, so data and tag always move together.

## Step by step

### Step 1: Write into the current journal section
In journaled mode, a write doesn't go to its permanent location. It goes into the current **journal section**, a fixed-size area that holds a limited number of sector writes. Each section has a 4 KiB metadata area plus a data area. For each sector, the metadata area holds:
- the destination sector number
- the last 8 bytes of the sector's content
- the sector's tag

The other 504 bytes of the sector go in the data area.

### Step 2: Why split off the last 8 bytes?
Those 8 bytes are about to be overwritten by the commit stamp (next step), so they are saved in the metadata entry first. It also packs more entries into the metadata area. On replay, the two pieces are put back together.

### Step 3: Commit the section
A section is committed when it fills up, when 250 ms have passed (by default), or when the journal passes its fill threshold. Committing writes the section's **commit ID**, a number that only ever increases, into the last 8 bytes of every 512-byte sector of the section. Then a barrier flush makes sure the whole section is really on disk.

This is the key step. If the machine crashes during the commit write, some sectors will carry the new ID and some won't.

### Step 4: Replay after a crash
When the device is opened, every journal section is read and checked. A section is replayed only if *all* its sectors carry the same commit ID. A torn section, with mismatched IDs, is silently discarded. Either way the result is consistent: a sector's data and tag both come from a completed commit, or neither changes. Checking per section, rather than per entry, allows validation with one sequential scan and no in-memory index.

### Step 5: Copy to the permanent place in the background
After a section is committed, a background worker processes each entry: reassemble the sector and write it to its permanent location, write its tag into the tag area through the tag cache, flush the cache, then mark the section free for reuse. The original write already completed at step 3, so this copying doesn't add to write latency.

### Step 6: Several sections keep things flowing
With multiple sections, one can be copied home while the next accepts new writes. Copying starts when half the sections are full (by default). The commit timer bounds how long a small write waits, and so how much could be lost in a crash.

### Step 7: Protect the journal itself
The journal reveals which sectors were recently written, and entries could be tampered with. Two options help:
- **Journal encryption** hides the entries, so an attacker reading the disk can't tell which sectors were written.
- **Journal MAC** adds a keyed hash over each entry's sector number, so an attacker can't move a valid entry to a different sector; replay would fail the check. This was added later, after the relocation attack was recognised.

## The picture

```text
 write(sector S, data, tag)
        │
        ▼
 ┌──────────── journal section N ────────────┐
 │ metadata: [S | last 8 bytes | tag] ...    │
 │ data:     [first 504 bytes of S] ...      │
 └───────────────────────────────────────────┘
        │ full, or 250 ms, or threshold
        ▼
 commit: stamp ID=42 into every sector's last 8 bytes → barrier flush
        │                                   → write completes to caller
        ▼  (background)
 copy S home ─▶ data area      tag ─▶ tag area (via cache) ─▶ section free

 after crash:  all sectors ID=42 → replay   │   mixed IDs → discard
```

## Tradeoffs

- **What it gives you:** data and tag always consistent after a crash, with write latency bounded by one journal commit rather than two sequential writes.
- **What it costs / requires:** every sector is written twice, halving write throughput. Replay needs two reads per section (metadata and data).
- **Where it bites:** the double write is why bitmap mode exists; for workloads that can recompute tags, it avoids the journal entirely. Without the journal MAC, an attacker with disk access could relocate journal entries.

## How it got here

- **4.12 (2017):** the original journal with per-section commit IDs, by Milan Broz.
- **Later:** the journal MAC, closing a previously overlooked relocation attack.
- **4.18:** bitmap mode arrived as a cheaper alternative, leaving the journal for cases that need strict atomicity, including dm-crypt's authenticated mode.

## Related

- Technical version: [[dm-integrity-journal]]
- [[dm-integrity-explained|dm-integrity]]: the subsystem overview
- [[dm-integrity-bitmap-mode-explained|Bitmap mode]]: the no-journal alternative
- [[dm-integrity-device-config-explained|Device configuration]]: holds the journal settings
- [[dm-integrity-on-disk-layout]]: where the journal sits
- [[dm-bufio-explained|dm-bufio]]: the tag cache used during copy-home
