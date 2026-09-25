---
title: "Zoned Block Devices"
category: concept
tags: [block, zoned-storage, smr, zns, zone-append]
subsystem: block
kernel_version: "4.10"
researched: 2026-09-25
status: complete
explained: "[[zoned-block-devices-explained]]"
sources:
  - https://zonedstorage.io/docs/linux/overview
  - https://zonedstorage.io/docs/introduction/zoned-storage
  - https://lwn.net/Articles/968580/
  - https://lwn.net/Articles/818709/
  - https://www.mail-archive.com/dm-devel@lists.linux.dev/msg02422.html
---

# Zoned Block Devices

> 📘 Plain-language version: [[zoned-block-devices-explained]]

## Purpose

Some storage media can't overwrite data in place efficiently. **Shingled magnetic recording (SMR)** hard drives overlap tracks like roof shingles to increase density, so writing one track damages the next. **Flash** can only erase in large blocks. Hiding this behind a normal random-write interface costs the device a translation layer, spare capacity and extra internal writes (write amplification). **Zoned block devices** expose the constraint instead: the disk is divided into **zones** that must be written sequentially, and the host software takes responsibility for writing that way. In exchange, SMR drives get higher capacity and ZNS SSDs need less over-provisioning, less internal DRAM and less write amplification. The kernel's zoned support gives filesystems, device-mapper targets and applications a common interface to these devices while guaranteeing the ordering rules are kept.

## Mental Model

A zoned disk is a **notebook with many chapters, each written only in ink, from front to back**. Each chapter has a bookmark, the **write pointer**, showing where the next line must go. You can read any page, but you can only add text at the bookmark. To reuse a chapter, you tear all its pages out at once (**zone reset**). The kernel's job is making sure writes to each chapter arrive at the bookmark in order, even though many writers, queues and CPUs are involved, and to offer a shortcut, **zone append**, where you hand over text to "add to chapter 7" and are told afterwards which page it landed on.

## How It Works

**Device models and zone types.** A drive can be **drive-managed** (it hides zones behind a normal interface and looks like any other disk), **host-aware** (it accepts random writes but prefers sequential ones), or **host-managed** (it rejects writes that aren't at the write pointer). Linux treats host-aware and host-managed drives as zoned. Zones come in types: **conventional** zones accept random writes (handy for metadata); **sequential write required** zones must be written at the write pointer; **sequential write preferred** zones (host-aware) should be. Every zone has a fixed **size** (the same for all zones, a power of two in sectors in Linux) and a **capacity**, the usable part, which can be smaller, notably on ZNS SSDs whose capacity matches the flash erase unit.

**Zone states.** A sequential zone moves between conditions: **empty** → **implicitly open** (after a write) or **explicitly open** (after an open command) → **closed** (partly written, but not currently open) → **full** (write pointer at capacity, or after a *finish* command). Zones can also be **read-only** or **offline** after media failures. Devices limit how many zones can be **open** at once and how many can be **active** (open or closed, i.e. partly written), because each consumes device resources. Software that writes to too many zones at once gets errors.

**Discovering zones.** When a zoned disk is probed, the driver (SCSI ZBC for SAS, ZAC for SATA, NVMe ZNS, null_blk, ublk, virtio-blk, dm) reports the zone model, zone size and the open/active limits. The block layer records them in the queue limits and exposes them in sysfs (`queue/zoned` = `host-managed`/`host-aware`/`none`, `queue/chunk_sectors` = zone size, `nr_zones`, `max_open_zones`, `max_active_zones`, `max_zone_append_sectors`). It then walks all zones through the driver's `report_zones` method (`blkdev_report_zones()`), each described by a `struct blk_zone` with `start`, `len`, `capacity`, `wp` (write pointer), `type` and `cond`, to set up per-zone state such as which zones are conventional.

**Zone management.** Users and filesystems drive zones with operations that travel as ordinary block requests: `REQ_OP_ZONE_RESET` (rewind the write pointer and discard the zone's data), `REQ_OP_ZONE_RESET_ALL`, `REQ_OP_ZONE_OPEN`, `REQ_OP_ZONE_CLOSE` and `REQ_OP_ZONE_FINISH` (mark full). User space reaches them through ioctls (`BLKREPORTZONE`, `BLKRESETZONE`, `BLKOPENZONE`, `BLKCLOSEZONE`, `BLKFINISHZONE`), used by the `blkzone` tool.

**The ordering problem.** A regular write to a sequential zone must start exactly at the write pointer. But the block layer is built for concurrency: writes are split, merged, queued on per-CPU software queues, reordered by schedulers, and dispatched on multiple hardware queues. Two writes issued in order to the same zone can easily reach the device in the wrong order and fail. Applications that write zoned devices directly are told to use direct I/O for this reason, and the kernel must preserve ordering below them.

**Zone write locking (4.10–6.9).** The first solution lived in the **mq-deadline** I/O scheduler: before dispatching a write to a sequential zone it took a per-zone **write lock**, released on completion, so at most one write per zone was ever in flight, and other writes waited in the scheduler. It worked, but it tied zoned devices to mq-deadline (no `none`, no BFQ, no Kyber), limited each zone to queue depth 1, and made waiting writes hold scheduler tags, which could block unrelated I/O.

**Zone write plugging (6.10+).** Damien Le Moal's 28-patch series moved ordering into the block core, at the **bio** level, before any request is allocated. Each zone that has writes in flight gets a **zone write plug**: a small structure holding a spinlock, the zone's cached write-pointer offset, a queue of waiting bios and a work item. When a write bio for a sequential zone is submitted, `blk_zone_plug_bio()` checks the zone's plug. If no write is in flight, the bio goes straight through and the cached write pointer advances by its size. If one is, the bio is **plugged**: added to the zone's queue without holding any tag or request. When the in-flight write completes, the next plugged bio is submitted from the plug's work item. Only writes are serialised; reads and writes to other zones proceed freely. Because plugged bios hold no scheduler resources, any scheduler, including `none`, can now drive a zoned device. Benchmarks showed parity with the old scheme under mq-deadline and up to 180% more throughput on sequential workloads with `none`. Plugs are allocated only for zones with active writes (from a hash table and mempool) to keep memory small on drives with tens of thousands of zones. On a write error, the plug marks the zone as needing a write-pointer update, re-reads the real write pointer from the device, and fails or restarts the queued bios accordingly.

**Zone append.** Serialising writes one per zone limits throughput, especially on SSDs. **Zone append** (5.8) removes the ordering requirement: a `REQ_OP_ZONE_APPEND` bio is addressed to the *start* of the zone; the device writes it at wherever the write pointer currently is and reports back the sector used, which the block layer returns in the completed bio's `bi_iter.bi_sector`. Many appends to one zone can be in flight at once; the device picks the order. The caller must record where each landed, like a filesystem allocator whose decisions are made by the disk. NVMe ZNS supports append natively. For SCSI SMR drives, which lack it, the kernel **emulates** zone append by turning it into a regular write at the cached write pointer; since 6.10 this emulation is part of zone write plugging, so it's available for every zoned device. zonefs uses zone append for synchronous direct writes, and Btrfs uses it for data.

**Who uses it.** 
- **f2fs** (4.10) — log-structured filesystem, a natural fit, with conventional zones or a separate device for metadata.
- **dm-zoned** and **dm-linear** (4.13) — dm-zoned presents a zoned drive as a normal random-write device by staging writes in conventional zones; dm-linear passes zones through.
- **zonefs** (5.6) — exposes each zone as a file whose size is the write pointer; writing means appending; truncating to zero resets the zone.
- **NVMe ZNS** (5.9).
- **Btrfs** (5.12) — copy-on-write fits sequential zones; uses zone append for data, and relocation (garbage collection) to reclaim zones.
- **XFS** (6.15) — native zoned support with its own garbage collection.

## Key Data Structures

**`struct blk_zone`** (`include/uapi/linux/blkzoned.h`) — one zone as reported by the device and by `BLKREPORTZONE`.
- `start`, `len`, `capacity` — zone position, size and usable size in sectors
- `wp` — write pointer
- `type` — conventional / sequential write required / sequential write preferred
- `cond` — empty, implicit open, explicit open, closed, full, read-only, offline

**Zone write plug** (`block/blk-zoned.c`) — per-zone ordering state for zones with writes in flight: lock, cached write-pointer offset, list of plugged bios, flags (plugged, needs write-pointer update) and the work item that submits the next bio.

**Queue limits** — zone size (`chunk_sectors`), `max_open_zones`, `max_active_zones`, `max_zone_append_sectors`, zoned model.

## Key Functions / Entry Points

**`blkdev_report_zones()`** — calls the driver's `report_zones` to enumerate zones.
**`blkdev_zone_mgmt()`** — issues reset/open/close/finish operations.
**`blk_zone_plug_bio()`** — zone write plugging entry at bio submission; passes, plugs or emulates zone-append bios.
**`blk_revalidate_disk_zones()`** — sets up per-zone state after probe or resize.
**`blkdev_report_zones_ioctl()` / `blkdev_zone_mgmt_ioctl()`** — user-space ioctls.

## Important Flags & Config Options

- `CONFIG_BLK_DEV_ZONED` — zoned device support in the block layer.
- `CONFIG_DM_ZONED`, `CONFIG_ZONEFS_FS`, `CONFIG_F2FS_FS`, `CONFIG_BTRFS_FS` (zoned mode), `CONFIG_XFS_RT` (XFS zoned uses the realtime device).
- sysfs `queue/zoned`, `chunk_sectors`, `nr_zones`, `max_open_zones`, `max_active_zones`, `max_zone_append_sectors`.
- `REQ_OP_ZONE_APPEND`, `REQ_OP_ZONE_RESET`, `REQ_OP_ZONE_RESET_ALL`, `REQ_OP_ZONE_OPEN`, `REQ_OP_ZONE_CLOSE`, `REQ_OP_ZONE_FINISH`.
- null_blk `zoned=1` (with `zone_size`, `zone_nr_conv`, `zone_max_open`, `zone_max_active`) for testing without hardware.

## Interactions with Other Subsystems

- **↑ Userspace**: `blkzone`, zone ioctls, sysfs attributes; applications writing raw zones must use direct I/O; io_uring can issue zone append.
- **→ [[bio-layer]]**: zone write plugging intercepts write bios at submission, before splitting into requests; bios are split so they never cross a zone boundary.
- **→ [[blk-mq]]**: plugged bios hold no tags; since 6.10 any blk-mq device can be zoned without special scheduler support.
- **→ [[io-scheduler]]**: until 6.10, zoned devices had to use mq-deadline for its zone write locking; now any scheduler works.
- **← [[device-mapper]]**: dm-zoned, dm-linear, dm-crypt and others pass through or emulate zones.
- **← Filesystems**: f2fs, Btrfs, zonefs and XFS place data to respect write pointers and garbage-collect whole zones before resetting them.

## Design Decisions & Tradeoffs

- **Expose the constraint instead of hiding it.** Host-managed devices push sequential-write discipline into software, trading software complexity (garbage collection, zone-aware allocation) for cheaper, denser, more predictable devices.
- **Ordering in the scheduler vs. in the core.** Zone write locking was simple and contained, but tied every zoned device to one scheduler and one write per zone at the request level. Zone write plugging moved ordering to the bio layer, so any scheduler works and waiting writes don't hog tags, at the cost of more core code and per-zone plug management.
- **Zone append vs. ordered writes.** Append allows high queue depth per zone but hands placement to the device, so software must record where data landed afterwards. Ordered writes keep placement in software but serialise per zone.
- **Emulation for SCSI.** SMR drives have no native append, so the kernel emulates it with the cached write pointer, giving filesystems one code path at the cost of keeping a write-pointer cache in memory (about 208 KB for a 52,000-zone drive in the original design).
- **Power-of-two zone sizes.** Linux requires zone sizes to be a power of two in sectors, making zone lookups cheap shifts; devices with other sizes (possible with ZNS) aren't supported directly.

## How It Has Evolved

- **4.10 (2017)** — zoned block device support (ZBC/ZAC SMR drives) and f2fs; zone write locking in the (legacy) deadline and mq-deadline schedulers.
- **4.13** — device-mapper zoned support: dm-zoned, dm-linear.
- **5.6** — zonefs.
- **5.8** — zone append, with SCSI emulation.
- **5.9** — NVMe ZNS.
- **5.12** — Btrfs zoned mode.
- **6.10 (2024)** — zone write plugging replaces zone write locking; any scheduler can drive zoned devices; append emulation for all.
- **6.15** — XFS native zoned support.

## Further Reading

1. [Zone write plugging — LWN](https://lwn.net/Articles/968580/)
2. [Introduce Zone Append for writing to zoned block devices — LWN](https://lwn.net/Articles/818709/)
3. [Zoned storage introduction — zonedstorage.io](https://zonedstorage.io/docs/introduction/zoned-storage)
4. [Linux zoned storage support overview — zonedstorage.io](https://zonedstorage.io/docs/linux/overview)
5. [Zone write plugging v7 cover letter — dm-devel](https://www.mail-archive.com/dm-devel@lists.linux.dev/msg02422.html)

## LKML Highlights

> lore.kernel.org was unreachable (TLS certificate error) during this session; summarised from list archives and LWN.

- **"[PATCH v7 00/28] Zone write plugging" (Damien Le Moal, 2024)** — argued zone write locking tied zoned devices to mq-deadline and one in-flight write per zone; moved ordering to per-zone bio plugs, reporting parity under mq-deadline and up to 180% gains with `none`.
- **"Introduce Zone Append for writing to zoned block devices" (Johannes Thumshirn, 2020)** — added `REQ_OP_ZONE_APPEND` with SCSI emulation from a compact write-pointer cache, and converted zonefs synchronous direct writes to use it.
