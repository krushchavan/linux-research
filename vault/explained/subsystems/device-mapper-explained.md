---
title: "Device Mapper — Explained"
category: explained
original: "[[device-mapper]]"
subsystem: device-mapper
tags: [explained, device-mapper, block, storage]
converted: 2026-09-25
---

# Device mapper, explained

> Plain-language companion to [[device-mapper|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

A filesystem wants one simple thing: a block device, a long array of sectors it can read and write. Real storage is messier. You want to encrypt a disk, stripe across several disks, mirror one onto another, take snapshots, hand out "thin" volumes that only consume space as they fill, or verify checksums.

Hard-coding each of those into the kernel (as early Linux software RAID did) means every new feature touches the core, and features can't be combined freely. What's needed is a way to build *virtual* block devices out of real ones, with transformations applied as I/O flows through, and to stack them.

Device mapper (DM), merged in 2003, is that framework. Every LVM logical volume, every dm-crypt encrypted volume and many software RAID arrays are device-mapper devices underneath.

## The big picture

Think of device mapper as **a programmable pipeline for block I/O**. Each virtual device is described by a **table**: a list of rows, each saying "sectors A to B are handled by plugin X, with these arguments". The plugins are called **targets** (linear, striped, crypt, thin, and so on). A target receives each I/O request (a *bio*) for its range, does whatever it does (remaps the sector, encrypts the data, looks up a snapshot), and passes the modified request down.

Stacking falls out naturally. A thin volume can sit on a mirrored volume that sits on a striped volume. Each is its own DM device whose table points at the one below.

The design has three planes:

```text
  CONTROL PLANE                 DATA PLANE                   SERVICE PLANE
  (user space: LVM, dmsetup)    (every I/O)                  (helpers for targets)

  ioctls on one control   ──▶   filesystem / app I/O
  device: create, load              │
  table, suspend/resume             ▼
         │                    virtual DM device
         ▼                          │ which row covers this sector?
   active table  ◀── swap ──  inactive table
         │                          ▼
         └──────────────────▶  target (linear, crypt, thin...)
                                    │ remap / transform      ──▶ dm-io (metadata I/O)
                                    ▼                        ──▶ kcopyd (bulk copying)
                              real block devices             ──▶ dm-bufio (metadata cache)
                                                             ──▶ persistent-data
                                                                 (transactional B-trees)
```

## The pieces

### The target framework

The plugin contract that makes DM extensible. See [[target-framework]].

1. A module registers a target type under a name such as "linear", "crypt" or "thin".
2. When a table is loaded, the kernel looks up each row's target type and calls its constructor with the row's arguments. The constructor builds that instance's private state.
3. From then on, every I/O in the row's sector range goes to the target's **map** function, the hot path. It can remap the request to another device and sector, clone it, queue it internally, or fail it. Its return value tells the core what to do next: "I've submitted it", "I remapped it, you resubmit it", "retry later", or an error.
4. Suspend and resume hooks let a target flush in-flight work and restore it across a table reload. That is how LVM resizes a volume online without dropping I/O.

### The control interface

Configuration lives entirely in user space (LVM2, dmsetup). The kernel exposes one control device, and everything happens through ioctls on it. See [[ioctl-control-interface]].

The key design is **two table slots per device: active and inactive**. This is the key idea of the control plane.
1. **Load** a new table into the inactive slot. Live I/O is untouched.
2. **Suspend** the device, draining in-flight I/O.
3. **Resume**, which atomically swaps inactive to active, discards the old table, and lets I/O flow again.

If the new table is wrong, it can be cleared from the inactive slot without ever interrupting I/O. LVM uses this sequence constantly for online resize, snapshot creation and moving data between disks. A flag can ask the kernel to wipe its copy of the ioctl data afterwards, which dm-crypt uses so keys don't linger in memory.

### dm-io

A thin I/O layer targets use for their *own* I/O (metadata, copying), separate from user I/O. See [[dm-io-explained|dm-io]].

1. A target creates a client sized for how much I/O it expects in flight. The client has a reserved memory pool, so metadata I/O can always make progress even when memory is tight.
2. Each request names one or more regions (device, start sector, count) and a memory buffer, described as a list of pages, an existing list of page segments, or one contiguous virtual buffer.
3. It can run synchronously or call back when done. Errors come back as a bitmask, one bit per region, so a mirror can tell exactly which copy failed.

### kcopyd

An asynchronous copy engine. Snapshots, mirror resyncs and cache fills all need to copy large amounts of data between devices without stalling normal I/O. See [[kcopyd]].

1. A target asks: copy this source region to up to eight destinations, and call me when done.
2. kcopyd takes pages from its own reserved pool, reads the source, then writes all destinations at once.
3. Large copies are split into sub-jobs that run independently. The caller's callback fires only when every piece is done, with a per-destination error bitmask.
4. Because it pipelines pieces, kcopyd keeps the disks busy without holding the whole transfer in memory. It can also fill regions with zeros (thin provisioning uses that for new blocks), and can be told to keep going if one destination fails, which keeps a degraded mirror alive.

### The persistent-data library

Thin provisioning, dm-cache and dm-era all need complex, crash-safe metadata on disk: maps from virtual to physical blocks, reference counts. This shared library means each target doesn't have to write its own. See [[persistent-data-library]].

1. **Block manager:** a cache of fixed-size (4 KiB) metadata blocks with per-block read/write locks.
2. **Transaction manager:** enforces **copy-on-write**. You can never modify a committed block in place. To write, you get a fresh copy (a *shadow*). Shadowing the same block twice in one transaction returns the same copy. A commit flushes all written blocks and then atomically updates the superblock. If power is lost before the next commit, the on-disk metadata is still consistent as of the last one.
3. **Space maps:** track reference counts and allocate blocks. The one for the metadata device has to track its own blocks inside the space it manages, so it uses a B-tree internally.
4. **B+ trees:** the main key-value store, 64-bit keys to arbitrary values. Trees can nest. Thin provisioning uses two levels: device ID → that device's tree, then virtual block → physical block.

### dm-bufio

A simple buffer cache for targets that need to cache on-disk metadata but can't use the normal page cache, which is tied to files. dm-integrity uses it for its checksum journal. See [[dm-bufio-explained|dm-bufio]].

1. A target creates a client for a device, block size and maximum buffer count.
2. Reading a block returns a cached buffer, or reads it from disk on a miss. The buffer stays pinned until released.
3. Modified buffers are marked dirty and written back in the background, or flushed on demand.
4. Clean buffers are evicted least-recently-used first. Because the cache is separate from the page cache, metadata for DM targets doesn't compete with filesystem data for memory.

## Notable targets

| Target | What it does |
|---|---|
| linear | Concatenates ranges of devices (sector offset arithmetic) |
| striped | Spreads I/O across N devices in chunks |
| mirror | Mirrors writes; uses kcopyd to resync |
| snapshot | Copy-on-write snapshots |
| thin / thin-pool | Thin provisioning on persistent-data B-trees |
| cache | Uses an SSD as a cache tier, with pluggable policies |
| crypt | Block-level encryption (see [[dm-crypt]]) |
| integrity | Per-sector checksums with a journal (see [[dm-integrity]]) |
| verity | Read-only verification against a hash tree |
| multipath | Fails over between paths to the same storage |
| vdo | Deduplication and compression |

## A request's journey

LVM creating a new thin volume and the first write to it:

1. **Load the table.** LVM loads an inactive table with one row: "all sectors → thin target, pool P, device ID N".
2. **Build the target.** The thin target's constructor finds the already-active pool device and keeps a reference to it.
3. **Swap it live.** LVM suspends and resumes the new device, which promotes the table to active.
4. **A write arrives.** A program writes to the new volume. The DM core finds the row covering that sector and calls the thin target's map function.
5. **Look up the block.** The thin target searches its B-tree for this virtual block. It isn't there (never written), so it allocates a physical block from the space map and inserts a new mapping.
6. **Remap and pass down.** The request's sector is changed to the physical block and it is resubmitted to the pool's backing device.
7. **Make it durable.** At the next commit point (a flush from the filesystem, or a one-second timer), the transaction manager commits, and the new mapping is on disk atomically.

## Tradeoffs

- **What it gives you:** composable storage features (encryption, snapshots, thin volumes, RAID, caching, verification) that stack freely, and live reconfiguration with no I/O downtime.
- **What it costs / requires:** some dispatch overhead per I/O; two tables held per device during changes (negligible in practice); and a second buffer cache in the system besides the page cache.
- **Where it bites:** filesystems can't see the stack below them, so a slow or failing layer deep in a stack shows up only as a slow or failing block device. The control interface is a set of ioctls from before netlink became preferred. A 2008 netlink proposal wasn't adopted, and that interface is effectively frozen.

## How it got here

- **2.6.0 (2003):** the core merged with linear, striped, snapshot and mirror targets, as a plugin framework rather than hard-coded storage types.
- **2.6.6–2.6.9 (2004):** dm-crypt encryption and multipath failover.
- **3.2 (2012):** thin provisioning and the shared persistent-data library, the biggest structural addition since the original merge. Before it, each target had its own on-disk metadata code. dm-cache followed in 3.9.
- **4.x–5.x:** dm-integrity (4.6), a persistent-memory write cache (4.16), live device cloning (5.2), and deduplication/compression with dm-vdo (listed as 5.15).
- **6.x (ongoing):** measuring table loads with IMA for attestation, zoned-device support, multipath failover speed, and vdo tuning.

## Related

- Technical version: [[device-mapper]]
- [[block-explained|Block layer]]: DM devices are ordinary block devices to everything above
- [[target-framework]], [[ioctl-control-interface]], [[dm-io-explained|dm-io]], [[kcopyd]], [[persistent-data-library]], [[dm-bufio-explained|dm-bufio]]
- [[dm-crypt]], [[dm-integrity]]: the security targets
- [[kernel-crypto-api|Kernel crypto API]], [[ima|IMA]]
