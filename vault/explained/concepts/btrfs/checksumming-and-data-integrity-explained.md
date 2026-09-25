---
title: "Btrfs Checksumming and Data Integrity — Explained"
category: explained
original: "[[checksumming-and-data-integrity]]"
subsystem: btrfs
tags: [explained, btrfs, checksums, scrub, data-integrity]
converted: 2026-09-25
---

# Btrfs checksumming and data integrity, explained

> Plain-language companion to [[checksumming-and-data-integrity|the technical note]]. Same facts, fewer identifiers.

## The problem

Most filesystems trust that what they read back from disk is what they wrote. It usually is, but not always. A failing disk, flaky RAM or buggy firmware can flip bits silently, and the filesystem then hands corrupted data to applications without complaint. With two mirror copies that disagree, a traditional filesystem can't even tell which copy is the good one.

## The idea in one paragraph

Btrfs **checksums every block**, metadata and data, and checks the checksum on every read. On a redundant layout (RAID1, RAID10, RAID5/6), a mismatch is repaired automatically from a good copy, and the application never sees the corruption. Metadata blocks carry their checksum in their own header; file data checksums live in a separate **checksum tree**, looked up by the data's logical position. A periodic **scrub** reads everything and repairs problems before anyone asks for the damaged data.

## Step by step

### Step 1: Metadata blocks check themselves
Every B-tree block begins with a header whose first field is a checksum (up to 32 bytes) covering the rest of the block. The header also holds the filesystem's ID (catching reads from the wrong device) and the address the block *should* be at (catching a good block written to the wrong place). Every metadata read recomputes the checksum and checks both; every metadata write computes the checksum just before the block goes to disk.

### Step 2: Data checksums in their own tree
File data checksums live in a dedicated **checksum tree**, keyed by the logical byte position of the data. Each entry holds a packed run of per-sector checksums (one per 4 KiB). A 1 MiB extent with CRC32C needs 256 × 4 = 1024 bytes of checksums; long runs are split across entries.

- **Writing:** once file data has been written to disk, the kernel computes a checksum per sector and inserts them into the checksum tree, inside the same transaction as the data's extent records, so a crash can't leave new data with old checksums.
- **Reading:** before a data read goes out, the expected checksums are fetched and attached to it. When the read completes, each sector is checked. A mismatch triggers repair.

Small files stored inline inside metadata leaves are already covered by the leaf's own header checksum. Compressed extents are checksummed in their compressed, on-disk form.

### Step 3: Repair on every read
This is the key step. When a sector fails its check on a redundant filesystem, btrfs reads the mirror copy. If that copy's checksum matches, the bad sector is rewritten from it, and the application gets correct data, with nothing but a kernel log message to show for it. Metadata blocks retry from mirrors the same way.

Checksums are what make mirroring trustworthy: without them there's no way to tell which of two differing copies is right. They also identify the damaged device when RAID5/6 recovers from a write-hole event.

### Step 4: Choose an algorithm at creation time
| Algorithm | Size | Notes |
|---|---|---|
| CRC32C | 4 bytes | the default; hardware-accelerated on x86 and ARM; not cryptographic |
| xxHash64 | 8 bytes | faster in software on some platforms; not cryptographic |
| SHA-256 | 32 bytes | cryptographic; slow without hardware help |
| BLAKE2b | 32 bytes | cryptographic; faster than SHA-256 in software |
| HMAC-SHA256 | 32 bytes | keyed: detects deliberate tampering |

The choice is fixed when the filesystem is created. CRC32C is the default because btrfs's main goal is catching hardware faults, not attackers, and it's nearly free with hardware acceleration.

### Step 5: Authenticated btrfs
With HMAC-SHA256 (around 5.12), checksums depend on a secret key supplied through the kernel keyring at mount time. Someone who can write to the raw disk offline can't forge valid checksums, so tampering is detected when the data is read. It doesn't protect against a compromised running kernel, and it isn't a substitute for full-disk encryption.

### Step 6: Scrub: find corruption before anyone reads it
A scrub walks each device:
1. list the allocated chunks on the device
2. find every allocated extent in each chunk
3. fetch the expected checksums (data) or rely on header checksums (metadata)
4. read extents sequentially, which is friendly to disk seeks
5. check every sector
6. repair mismatches from a mirror, or rebuild from parity on RAID5/6

Scrub looks things up in the state as of the last committed transaction, so it has a stable view while the filesystem stays in use. When a new transaction commits, it pauses briefly and continues from the new state. Status reports count errors found, corrected, and uncorrectable (every copy bad).

## The picture

```text
 METADATA BLOCK                      FILE DATA
 [ checksum | fs id | own address |  data extent at logical offset L
   ...rest of block... ]                   │
   read → recompute & compare        checksum tree: L → [c0][c1][c2]... (one per 4 KiB)
                                             │
 read sector ──▶ compare with expected checksum
                  │ match → return data
                  │ mismatch → read mirror copy → good? rewrite bad sector, return good data
                  │            all copies bad → I/O error ("uncorrectable")

 scrub: chunks → extents → sectors → verify → repair  (using last committed state)
```

## Tradeoffs

- **What it gives you:** detection and automatic repair of silent corruption, repair at single-sector granularity, and optional tamper detection.
- **What it costs / requires:** a second tree lookup on every data read (checksums are kept apart from extent records to keep those small and scale lookups independently); CPU for checksums, negligible with CRC32C acceleration, noticeable with SHA-256.
- **Where it bites:** swap files can't be checksummed, because the kernel writes swap pages outside the normal file-write path, so they need copy-on-write and checksums turned off. Scrub doesn't see extents allocated since the last commit until the next one. Repair only works where a redundant copy exists; on a single disk, btrfs can detect corruption but not fix file data.

## How it got here

- **2.6.29 (2009):** CRC32C checksums for data and metadata from btrfs's first merge.
- **2011:** scrub introduced. **3.16 (2014):** scrub repair from RAID5/6 parity.
- **5.5 (2020):** xxHash64, SHA-256 and BLAKE2b, after a 2015 SHA-256 proposal was deferred for a cleaner multi-algorithm design.
- **5.12 (2021):** authenticated btrfs with HMAC-SHA256 (Johannes Thumshirn), after debate about key management and what it actually protects.
- **6.x:** a scrub rewrite for performance and a whole-filesystem scrub interface.

## Related

- Technical version: [[checksumming-and-data-integrity]]
- [[btrfs-explained|Btrfs]]: the subsystem overview
- [[multiple-b-trees-explained|multiple-b-trees]]: every tree block is checksummed
- [[raid-and-multi-device-support]]: the mirrors and parity that repair uses
- [[transaction-model]]: why checksums and data stay in step
- [[dm-integrity-explained|dm-integrity]]: per-sector checksums at the block layer instead
