---
title: "Btrfs Balance and Device Management — Explained"
category: explained
original: "[[balance-and-device-management]]"
subsystem: btrfs
tags: [explained, btrfs, balance, multi-device, raid]
converted: 2026-09-25
---

# Btrfs balance and device management, explained

> Plain-language companion to [[balance-and-device-management|the technical note]]. Same facts, fewer identifiers.

## The problem

Btrfs can span several disks. You'll eventually want to add a disk, remove one, swap a failing one, or switch from "one copy of everything" to "mirrored". All of this should happen while the filesystem stays mounted and in use.

Here's the catch: adding a disk doesn't move any existing data. New writes can land on it, but everything already stored stays where it was. Removing a disk means its data must go somewhere first. And changing the redundancy level means rewriting data in a new layout. Something has to physically move data around, safely, possibly for hours, surviving crashes along the way.

## The idea in one paragraph

Btrfs stores data in large allocation units called **block groups**, each backed by a *chunk* that says which disks and offsets hold it. **Balance** is one general-purpose mover: it walks every block group, asks a set of **filters** "should this one move?", and for each yes, copies its contents into a freshly allocated chunk elsewhere and frees the old one. Adding, removing and changing redundancy are all expressed in terms of this mover. **Replace** is a special case that copies one disk to another while keeping both in sync.

## Step by step

### Step 1: Only one big operation at a time
Balance, add/remove and replace all rearrange where chunks live. If two ran at once, they'd fight over the same chunks. So before any of them starts, it atomically claims a single "exclusive operation" slot; if it's taken, the request fails with "busy". This keeps the chunk logic simple, and since these operations are rare, it hasn't been a real pain point.

### Step 2: Balance picks block groups with filters
You tell balance what to move, separately for data, metadata and system block groups. Filters are combined with AND; no filter means "everything". The common ones:
- **usage**: only block groups at most N% full. `usage=0` reclaims empty ones cheaply.
- **devid**: only block groups with a piece on a given disk. Used when removing that disk.
- **physical or logical range**: only those overlapping a range. Used when shrinking.
- **limit**: at most N block groups this run, so you can balance a little at a time.
- **profiles** and **stripes**: only those with a given RAID layout or stripe count.
- **convert**: rewrite the moved block groups into a new RAID layout. With **soft**, skip ones already converted, so a resumed conversion doesn't redo work.

### Step 3: Relocate one block group
This is the key step. For each block group chosen:
1. Mark it read-only so no new writes land there.
2. Create a special internal file whose contents *are* every extent in that block group.
3. Write that file back through the normal writeback path. Because the old block group is read-only, the allocator puts the data somewhere else.
4. Update every reference in the extent tree to point at the new location.
5. Delete the old chunk and give its disk space back.

Reusing the ordinary write path means relocation gets checksums, RAID layout and copy-on-write for free.

### Step 4: Survive crashes and reboots
Each block group moves inside its own transaction, so a crash leaves some moved and some not, but never a half-moved mess. Balance also saves its filters and state in the filesystem. At the next mount it resumes automatically (unless you mount with the option to skip that), so a many-hour balance isn't lost to a reboot.

### Step 5: Run in the background, and stop on request
Balance runs in a kernel thread; the command returns immediately and you can query progress (block groups done out of total). Pause and cancel are checked between relocations. Since 5.7 that check happens often enough that cancelling takes seconds rather than waiting for a whole block group.

### Step 6: Adding a disk
The kernel checks the disk isn't already part of a btrfs filesystem, gives it an ID, and records it in the chunk tree. If this is the second disk and metadata was single-copy, it also puts a system chunk on the new disk.

**No data moves.** The disk shows 0% used until writes or a balance put chunks on it. That's deliberate, to avoid surprise I/O load, but it means you must run balance yourself if you want the data spread out.

### Step 7: Removing a disk
1. Check there's enough room on the remaining disks for everything, under the current RAID layout. If not, fail with "no space".
2. Stop sending new I/O to the disk.
3. Run balance filtered to that disk, evacuating every block group with a piece on it. This is the slow part, possibly hours.
4. Remove the disk's record and close it.

If a disk has already died, you mount in *degraded* mode and remove the "missing" disk. Its data is gone (or was read from mirrors), and a later balance rebuilds the lost redundancy.

### Step 8: Replacing a disk, safely
Add-then-remove has a dangerous window: redundancy drops while data is in flight. Replace avoids it.
1. Open the new disk (it must be at least as big) and save the replace state on disk so it survives a crash.
2. **Dual-write:** from now on, every write aimed at the old disk is also sent to the matching place on the new one.
3. **Copy what's already there** using the scrub engine: read each extent, verify its checksum, and write it to the new disk. It reads from the last committed snapshot of the metadata, so it sees a consistent view.
4. **Finish:** point the chunk map at the new disk, have the new disk take over the old one's identity, remove the old disk, and clear the saved state.

The old disk stays live until the new one is fully populated, so redundancy never drops. After a crash, replace resumes where the copy left off. If the old disk is failing, you can tell replace to read from mirror copies on other disks instead.

## The picture

```text
 BALANCE (general mover)
   for each block group ──▶ filters? (usage, devid, range, limit, profile)
                               │ yes
                               ▼
      mark read-only ─▶ write its extents via normal writeback ─▶ lands elsewhere
                      ─▶ update references ─▶ free old chunk
      (one transaction per block group; progress saved on disk)

 ADD     new disk ─▶ recorded ─▶ available for FUTURE chunks only
 REMOVE  balance(devid = disk) ─▶ disk empty ─▶ forget disk
 REPLACE ┌ new writes ─▶ old disk AND new disk   (dual-write)
         └ scrub copies existing data old ─▶ new (checksum-verified)
           ─▶ swap identities ─▶ drop old disk
```

## Tradeoffs

- **What it gives you:** online growth, shrink, device swaps and RAID conversion, all resumable after crashes, all built on one relocation engine.
- **What it costs / requires:** even small jobs, like reclaiming a few empty block groups, run through the full relocation machinery; the `limit` filter exists to keep that manageable. While a block group is being moved, both old and new copies take space. During replace, every write goes to two places.
- **Where it bites:** people expect data to spread out after adding a disk. It doesn't, until you balance. And removing a disk from a nearly full filesystem can fail for lack of space on the others.

## How it got here

- **2.6.29 (2009):** adding and removing disks from the start; balance was a crude "rewrite everything".
- **3.3 (2012):** filtered balance, by Ilya Dryomov, with per-type filters because converting profiles needs separate targets for data and metadata.
- **3.9 (2013):** device replace, by Stefan Behrens. Dual-write won over copy-then-switch because it keeps full redundancy and restarts cleanly after a crash.
- **4.x:** more filters (limit, stripes) and sturdier saved state.
- **5.7 (2020):** much faster cancellation.
- **6.0 (2022):** send (for backups) can finally run at the same time as balance or disk removal.
- **6.4+ (2023–2024):** automatic background reclaim of under-used block groups, reusing the relocation engine.

## Related

- Technical version: [[balance-and-device-management]]
- [[btrfs-explained|Btrfs overview]]
- [[space-accounting-and-block-groups-explained|Space accounting and block groups]]: what balance reclaims
- [[raid-and-multi-device-support-explained|RAID and multiple devices]]: the layouts balance converts between
- [[transaction-model|Transactions]]: why a crash mid-balance is safe
- [[checksumming-and-data-integrity-explained|Checksums]]: verified during replace
