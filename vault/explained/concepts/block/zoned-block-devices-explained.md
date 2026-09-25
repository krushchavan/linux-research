---
title: "Zoned Block Devices — Explained"
category: explained
original: "[[zoned-block-devices]]"
subsystem: block
tags: [explained, block, zoned-storage, smr, zns]
converted: 2026-09-25
---

# Zoned block devices, explained

> Plain-language companion to [[zoned-block-devices|the technical note]]. Same facts, fewer identifiers.

## The problem

Some storage can't overwrite data in place cheaply. **Shingled (SMR) hard drives** overlap tracks like roof shingles to fit more data, so rewriting one track damages its neighbour. **Flash** can only erase in large blocks. Pretending these are ordinary random-write devices costs the device a translation layer, spare capacity and extra internal writes. **Zoned** devices stop pretending: they split the disk into **zones** that must be written front to back, and the host takes responsibility for that. In return, SMR drives get more capacity, and zoned (ZNS) SSDs need less spare space, less internal memory and fewer internal rewrites.

The hard part is on the host side: the Linux block layer is built for concurrency (splitting, merging, per-CPU queues, reordering schedulers, several hardware queues), and all of those can shuffle writes that must arrive in order.

## The idea in one paragraph

A zoned disk is a **notebook with many chapters, each written in ink, front to back**. Each chapter has a bookmark, the **write pointer**, marking where the next line must go. You can read any page but only write at the bookmark, and to reuse a chapter you tear all its pages out at once (a **reset**). The kernel's job is to make sure writes to each chapter reach the bookmark in order, however many writers and queues are involved, and to offer a shortcut, **zone append**: hand over text for "chapter 7" and be told afterwards which page it landed on.

## Step by step

### Step 1: Kinds of devices and zones
A drive may be **drive-managed** (hides zones; looks like a normal disk), **host-aware** (accepts random writes but prefers sequential ones) or **host-managed** (rejects writes that aren't at the write pointer). Linux treats the latter two as zoned. Zones are **conventional** (random writes allowed, handy for metadata), **sequential write required** or **sequential write preferred**. Every zone has the same **size**, a power of two in Linux, and a **capacity**, the usable part, which can be smaller, notably on ZNS SSDs where it matches the flash erase unit.

### Step 2: Zone states and limits
A sequential zone goes from **empty** to **open** (implicitly by writing, or explicitly by command), may be **closed** (partly written but not currently open), and becomes **full** when written to capacity or explicitly finished. Failing media can leave zones **read-only** or **offline**. Devices limit how many zones may be **open** and how many **active** (partly written) at once, so software that writes to too many zones at once gets errors.

### Step 3: Discovery and management
At probe time the driver (SCSI or SATA SMR, NVMe ZNS, virtual devices, device-mapper) reports the zone model, zone size and limits. The block layer publishes them in sysfs and reads every zone's position, type, condition and write pointer. Zones are managed with operations that travel like normal I/O (reset, reset all, open, close, finish), which user space reaches through ioctls and the `blkzone` tool.

### Step 4: The ordering problem, first solution
Two writes to one zone issued in order can easily arrive out of order after the block layer is done with them, and the drive would reject them. (Applications writing zones directly are told to use direct I/O for this reason.) From 4.10 to 6.9, the fix lived in the **mq-deadline** scheduler: a per-zone **write lock** allowed only one write per zone in flight, with the others waiting. It worked, but it tied every zoned device to that one scheduler, limited each zone to one write at a time, and let waiting writes hold scheduler tags that could block unrelated I/O.

### Step 5: Zone write plugging
This is the key step. Since 6.10 (Damien Le Moal's 28-patch series), ordering lives in the block core at the **bio** level, before any request is created. Each zone with a write in flight gets a **write plug**: a lock, a cached write-pointer position, a queue of waiting bios and a work item. A write bio arriving for a zone with nothing in flight goes straight through, and the cached write pointer advances; if a write is already in flight, the bio is **plugged** onto the queue, holding no tags or requests. When the in-flight write completes, the next plugged bio is sent. Reads, and writes to other zones, flow freely. Because plugged bios hold no scheduler resources, **any** scheduler, including none, now works. Results matched the old scheme under mq-deadline and gained up to 180% on sequential workloads with none. Plugs exist only for zones with active writes, keeping memory small on drives with tens of thousands of zones. After a write error, the plug re-reads the true write pointer from the device and fails or restarts the queued bios accordingly.

### Step 6: Zone append
One write per zone at a time limits speed, especially on SSDs. **Zone append** (5.8) removes the ordering requirement: the bio is addressed to the *start* of the zone, the device writes it wherever the write pointer currently is, and the completion reports the sector used. Many appends to one zone can be in flight at once, and the caller records where each landed, like a filesystem whose allocator lives in the disk. NVMe ZNS supports append natively. SCSI SMR drives don't, so the kernel **emulates** it by turning an append into a normal write at the cached write pointer; since 6.10 this emulation is built into zone write plugging and works for every zoned device.

### Step 7: Who uses zones
- **f2fs** (4.10): a log-structured filesystem, a natural fit
- **dm-zoned** and **dm-linear** (4.13): dm-zoned makes a zoned drive look like a normal one by staging writes in conventional zones
- **zonefs** (5.6): each zone is a file whose size is the write pointer; writing means appending, and truncating to zero resets the zone
- **NVMe ZNS** (5.9)
- **Btrfs** (5.12): copy-on-write fits sequential zones; it uses zone append for data and relocation to reclaim zones
- **XFS** (6.15): native zoned support with its own garbage collection

## The picture

```text
 zone 7: [written ███████|wp→ empty .......]  (write only at wp; reset wipes the zone)

 before 6.10: mq-deadline zone lock → 1 write/zone in flight, mq-deadline only
 since 6.10:  bio ─▶ zone 7 plug: idle? send, advance cached wp
                                   busy? queue bio (no tags held) → send on completion
 zone append: write "to zone 7" ─▶ device places at wp ─▶ completion says sector 123456
```

## Tradeoffs

- **What it gives you:** denser SMR drives and leaner, more predictable SSDs; one kernel interface for filesystems, device-mapper and applications; ordering guaranteed without tying devices to a particular scheduler.
- **What it costs / requires:** software must write sequentially, garbage-collect whole zones before resetting them, and respect open/active zone limits. Zone append gives high queue depth per zone but hands placement to the device, so software must record locations afterwards. Emulating append on SCSI means keeping a write-pointer cache in memory (about 208 KB for a 52,000-zone drive in the original design).
- **Where it bites:** Linux requires power-of-two zone sizes, which keeps zone lookups to cheap shifts but excludes devices with other sizes, possible with ZNS. Before 6.10, forgetting to use mq-deadline on a zoned device meant write errors.

## How it got here

- **4.10 (2017):** zoned support for SMR drives, f2fs, and zone write locking in the deadline schedulers.
- **4.13:** device-mapper zoned targets. **5.6:** zonefs.
- **5.8:** zone append with SCSI emulation (Johannes Thumshirn).
- **5.9:** NVMe ZNS. **5.12:** Btrfs zoned mode.
- **6.10 (2024):** zone write plugging replaces zone write locking.
- **6.15:** native XFS zoned support.

## Related

- Technical version: [[zoned-block-devices]]
- [[bio-layer-explained|bio layer]], [[blk-mq-explained|blk-mq]], [[io-scheduler-explained|I/O schedulers]], [[device-mapper-explained|Device mapper]], [[block-explained|Block layer]]
