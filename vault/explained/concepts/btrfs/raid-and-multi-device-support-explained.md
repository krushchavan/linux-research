---
title: "Btrfs RAID and Multi-Device Support — Explained"
category: explained
original: "[[raid-and-multi-device-support]]"
subsystem: btrfs
tags: [explained, btrfs, raid, multi-device, chunks]
converted: 2026-09-25
---

# Btrfs RAID and multi-device support, explained

> Plain-language companion to [[raid-and-multi-device-support|the technical note]]. Same facts, fewer identifiers.

## The problem

Classic Linux RAID (MD) sits *below* the filesystem and presents several disks as one. It can't tell data from metadata, so it can't protect them differently. And when two mirror copies disagree, it has no way to know which one is correct: it just returns whatever is on disk.

Btrfs wanted redundancy that knows about the filesystem: different protection for metadata and data on the same disks, disks added, removed or replaced while mounted, and repair that knows which copy is bad.

## The idea in one paragraph

Build RAID into the filesystem. The disks form a pool of space carved into **chunks**: large regions (1 GiB for data, 256 MiB for metadata by default). Each chunk maps a range of btrfs's **logical addresses** (the addresses all trees and file extents use) to one or more physical locations. Mirroring means a chunk has two or more copies on different devices; striping means its range is interleaved across devices. The **chunk tree** is the only translator between logical and physical, and because every block is checksummed, btrfs always knows which copy is good.

## Step by step

### Step 1: Allocate space in chunks
When btrfs needs more room for data or metadata, it allocates a chunk from the device pool. The chunk's record says how big it is, whether it's data, metadata or system space, its RAID profile, and the list of physical **stripes**: which device and at what offset. A RAID1 chunk has two stripes; RAID0 on four disks has four; RAID5 on four disks has four (three data plus one parity).

### Step 2: Two-way maps, and a bootstrap
The chunk tree maps logical ranges to physical stripes and describes the devices. The device tree holds the reverse: for each device, which chunk owns each physical range, which is what lets device removal find everything on a disk. The chunk tree is itself stored at logical addresses that need translating, so the superblock carries a small built-in array (2 KiB) mapping the chunks that hold the chunk tree. That's loaded first at mount, and everything else follows.

In memory, the chunk mappings sit in an interval tree, and **every** read and write is translated through it into per-device I/O.

### Step 3: Choose profiles, separately for data and metadata
| Profile | Minimum devices | Copies | Survives |
|---|---|---|---|
| single | 1 | 1 | nothing |
| DUP | 1 | 2 on the same device | bad sectors, not a dead disk |
| RAID0 | 2 | 1, striped | nothing |
| RAID1 | 2 | 2 on different devices | 1 device |
| RAID1C3 / RAID1C4 | 3 / 4 | 3 / 4 | 2 / 3 devices |
| RAID10 | 4 | 2, striped | 1 per mirror pair |
| RAID5 | 3 | distributed parity | 1 (with caveats) |
| RAID6 | 4 | double parity | 2 (with caveats) |

This is the key advantage over MD RAID: data and metadata can differ. A single disk defaults to single data with DUP metadata, so a bad sector can't destroy a tree node (a common failure on spinning disks). Multi-device volumes default to RAID1 metadata and RAID0 data, protecting metadata without halving usable capacity. Profiles can be changed later, online.

### Step 4: Mirrored reads and writes
A RAID1 write is sent to both devices. A read goes to one copy, spreading load. If the data fails its checksum, btrfs reads the other copy and, if that one is good, rewrites the bad one.

### Step 5: RAID5/6 and the write hole
Writing less than a full stripe means **read-modify-write**: read the rest of the stripe, recompute parity, write the changed parts. If power fails after the data is written but before the parity is, the stripe is inconsistent: the **write hole**. Later, a scrub would see a mismatch but couldn't tell which device is stale.

Since about 6.1, btrfs keeps a **write-intent bitmap** on each device (at 1 MiB in): before writing a stripe, it marks that stripe and flushes the bitmap. After a crash, it re-scrubs only the marked stripes, and because every block has a checksum, it can work out which device is stale and fix it (as long as no device is missing). A full journal was considered and rejected, because checksums make this targeted recovery possible. RAID5/6 is still marked experimental.

### Step 6: Adding, removing and replacing disks
- **add:** new chunks can now come from the new disk, but existing data isn't moved until a balance runs
- **remove:** relocates everything off the disk onto the others (fails if there isn't room)
- **replace:** copies the old disk's contents to a new one in the background and only then drops the old one; more reliable than add-then-remove for hot swaps
- **balance:** the general tool for redistributing data, converting profiles (one chunk at a time, online, but with heavy I/O) and cleaning up

Mounting with a "degraded" option allows a volume with a missing device to be used; operations needing that device fail.

### Step 7: A stripe tree for zoned devices (6.7)
Zoned devices must be written sequentially within each zone, which clashes with RAID5/6's read-modify-write and with the simple chunk mapping. A new **RAID stripe tree** maps logical extents to per-device locations directly, so writes can stay sequential. It's optional on ordinary devices.

## The picture

```text
 logical address space (what btrfs trees see)
 ┌──── chunk A: metadata, RAID1 ────┐┌──── chunk B: data, RAID0 ────┐
 └───────┬───────────────┬──────────┘└──────┬────────────┬─────────┘
         ▼               ▼                  ▼            ▼
      disk 1 @x       disk 2 @y          disk 1 @z    disk 2 @w
      (copy 1)        (copy 2)          (stripe 1)   (stripe 2)

 read chunk A block → disk 1 → checksum bad → disk 2 → good → rewrite disk 1
 superblock holds the mapping for the chunk tree itself (bootstrap)
```

## Tradeoffs

- **What it gives you:** per-copy checksum verification and self-repair, different protection for data and metadata, and online add, remove, replace and profile changes.
- **What it costs / requires:** btrfs has to reimplement scrub, replace and parity recovery itself instead of reusing the mature MD layer. Striping per chunk (not per file extent) keeps metadata small, but a device can't be removed until whole chunks can be relocated elsewhere.
- **Where it bites:** RAID5/6 spent a decade as experimental because of the write hole and missing scrub repair; the bitmap addresses the hole, but device-replace support and tooling are still catching up. Adding a disk doesn't rebalance existing data on its own.

## How it got here

- **2.6.29 (2009):** RAID0, RAID1 and RAID10 at btrfs's first merge.
- **3.9 (2013):** RAID5/6 merged as experimental; Chris Mason called the write hole "the big missing piece".
- **4.12 (2017):** better replacement of missing devices on RAID5/6.
- **5.5 (2020):** three- and four-copy mirroring.
- **6.1 (2022):** the write-intent bitmap for RAID5/6 (Qu Wenruo).
- **6.7 (2024):** the RAID stripe tree for zoned devices.

## Related

- Technical version: [[raid-and-multi-device-support]]
- [[btrfs-explained|Btrfs]]: the subsystem overview
- [[checksumming-and-data-integrity-explained|Checksumming and data integrity]]: how the good copy is identified
- [[balance-and-device-management-explained|Balance and device management]]
- [[multiple-b-trees-explained|Btrfs B-trees]]: the chunk tree among the others
- [[transaction-model]], [[block-explained|Block layer]]
