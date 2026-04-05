---
title: "Btrfs RAID and Multi-Device Support"
category: concept
tags: [btrfs, raid, multi-device, chunk-tree, striping, parity]
subsystem: btrfs
kernel_version: "2.6.29"
researched: 2026-04-05
status: complete
sources:
  - https://lwn.net/Articles/577961/
  - https://lwn.net/Articles/536038/
  - https://lwn.net/Articles/341026/
  - https://lwn.net/Articles/900054/
  - https://lwn.net/Articles/944631/
  - https://dxuuu.xyz/btrfs-internals-2.html
---

# Btrfs RAID and Multi-Device Support

## Purpose

Btrfs integrates redundancy and striping directly into the filesystem rather than delegating to a separate MD RAID layer. This allows data and metadata to have independent RAID profiles on the same set of devices — for example, RAID1 metadata with RAID0 data — and enables online device add/remove/replace without unmounting. Checksums stored per-extent allow btrfs to detect and repair silent corruption, which MD RAID cannot do at the data level.

## Mental Model

Think of a btrfs multi-device volume as a pool of device space divided into **chunks** — large (≥256 MB) contiguous regions on one or more devices. Each chunk maps a range of **logical addresses** (the address space btrfs B-trees and file extents use) to one or more **physical stripe** locations on actual devices. RAID mirroring means a chunk has two or more stripes on different devices holding identical data; RAID striping means a chunk's logical range is interleaved across multiple device stripes. The **chunk tree** and its in-memory **chunk map** are the sole translation layer between logical and physical.

## How It Works

### Chunks: the unit of allocation and RAID

When btrfs needs more space for data or metadata, it allocates a new **chunk** from the device pool. A chunk is a contiguous logical address range (fixed at 1 GiB for data, 256 MiB for metadata in current defaults) backed by one `btrfs_chunk` item in the chunk tree. The `btrfs_chunk` struct describes the chunk's RAID profile and lists the physical stripes:

```c
struct btrfs_chunk {
    __le64 length;          /* logical size of this chunk */
    __le64 owner;           /* tree that owns this chunk (always chunk tree) */
    __le64 stripe_len;      /* size of each stripe segment */
    __le64 type;            /* BTRFS_BLOCK_GROUP_DATA | _METADATA | _SYSTEM
                               combined with BTRFS_BLOCK_GROUP_RAID0 etc. */
    __le32 io_align;
    __le32 io_width;
    __le32 sector_size;
    __le16 num_stripes;     /* how many physical stripe locations follow */
    __le16 sub_stripes;     /* for RAID10: stripes per mirror group */
    struct btrfs_stripe stripe;  /* first stripe; more follow contiguously */
};

struct btrfs_stripe {
    __le64 devid;           /* which device */
    __le64 offset;          /* physical byte offset on that device */
    __u8   dev_uuid[BTRFS_UUID_SIZE];
};
```

For a RAID1 chunk `num_stripes == 2`; for RAID0 on four devices `num_stripes == 4`; for RAID5 on four devices `num_stripes == 4` (3 data + 1 parity).

### The chunk tree and device tree

The **chunk tree** (tree ID 3) serves dual purposes: it holds `BTRFS_CHUNK_ITEM_KEY` entries (logical→physical maps) and `BTRFS_DEV_ITEM_KEY` entries (device descriptors). The device tree (tree ID 4, sometimes called the "dev tree") holds `BTRFS_DEV_EXTENT_KEY` entries — the inverse map: which logical chunk owns each physical range on each device. Together they form a bidirectional address space.

Because the chunk tree itself must be readable before any other tree can be used, the superblock contains a `sys_chunk_array` — a fixed 2 KiB array of bootstrap chunk items that maps the chunk tree's own blocks. This breaks the circularity: at mount time, the bootstrap array is loaded first, enabling chunk tree lookup, which enables everything else.

At runtime, the kernel keeps an **in-memory chunk map** (`btrfs_fs_info::mapping_tree`) as an interval tree. Every logical→physical translation goes through `btrfs_map_block()`, which looks up the interval tree and returns a `btrfs_bio_stripe` array describing where to send each IO.

### RAID profiles

| Profile | `type` flags | Minimum devices | Copies | Surviving failures |
|---|---|---|---|---|
| `single` | none | 1 | 1 | 0 |
| `DUP` | `BLOCK_GROUP_DUP` | 1 | 2 (same device) | 0 device failures; protects against sector loss |
| `RAID0` | `BLOCK_GROUP_RAID0` | 2 | 1 | 0 |
| `RAID1` | `BLOCK_GROUP_RAID1` | 2 | 2 (different devices) | 1 |
| `RAID1C3` | `BLOCK_GROUP_RAID1C3` | 3 | 3 | 2 |
| `RAID1C4` | `BLOCK_GROUP_RAID1C4` | 4 | 4 | 3 |
| `RAID10` | `BLOCK_GROUP_RAID10` | 4 | 2+stripe | 1 per mirror pair |
| `RAID5` | `BLOCK_GROUP_RAID5` | 3 | distributed parity | 1 (with caveats) |
| `RAID6` | `BLOCK_GROUP_RAID6` | 4 | double distributed parity | 2 (with caveats) |

Metadata and data have independent profiles within the same volume, set at `mkfs` time or converted online via `btrfs balance`.

The default for a single-device filesystem is `single` data, `DUP` metadata. DUP writes two copies of each metadata block to different regions of the same device, protecting against a bad sector corrupting a B-tree node — a common failure mode for spinning disks.

For multi-device volumes the default is `RAID1` metadata, `RAID0` data.

### Read and write paths — RAID1

For a RAID1 chunk write, `btrfs_map_block()` returns two `btrfs_bio_stripe` entries. The bio is cloned and submitted to both devices. On read, btrfs selects one stripe (rotating for load balancing or choosing the device whose read queue is shortest via the `BTRFS_RAID_ALLOC_CHUNK_BALANCE` logic). If a read returns a checksum mismatch, btrfs retries from the mirror and, if the mirror succeeds, schedules a repair write to the failed stripe.

### RAID5/6 — the write hole problem

RAID5/6 in btrfs uses a stripe size of `chunk.stripe_len` bytes across N−1 data devices plus 1 (or 2 for RAID6) parity device. A write that doesn't fill an entire stripe must perform a **read-modify-write (RMW)**: read the existing stripe data, XOR in the new data, recompute parity, write all modified sectors. This creates the **write hole**: if a crash occurs after writing data but before writing updated parity, the array is in an inconsistent state — scrub will see a checksum mismatch but cannot determine which device has the bad data.

Btrfs's solution (merged ~6.1): a **write-intent bitmap** stored at physical offset 1 MiB on each device. Before submitting a stripe write, btrfs sets the bitmap bit for that stripe and flushes the bitmap to all writable devices. On remount after a crash, btrfs reads the bitmap, identifies stripes that were in-flight, and re-scrubs only those ranges. Since btrfs checksums every data and metadata block, it can determine which device has the stale data and recover accordingly (provided no device is missing).

RAID5/6 remains marked **experimental** for production use as of kernel 6.x due to residual correctness concerns and incomplete tooling for RAID5/6 device replace.

### Device operations

**Add device** (`btrfs device add`): allocates new block groups from the new device for subsequent writes. Existing data is not redistributed; `btrfs balance` must be run to spread data.

**Remove device** (`btrfs device delete`): triggers a balance operation restricted to the target device — all its extents are relocated to the remaining devices. Fails if insufficient space remains.

**Replace device** (`btrfs replace start`): copies extents from the source device to a replacement device in the background without removing the old device from the array until copying is complete. More reliable than add+delete for hot-swap scenarios.

**Balance** (`btrfs balance`): the general-purpose data redistribution tool. Can filter by block group type, RAID profile, usage percentage, and device; used for profile conversion, space rebalancing, and RAID5/6 device add.

Online profile conversion works by running balance with `-dconvert=` / `-mconvert=` flags, which relocates each block group one at a time into a new chunk with the target profile. No downtime required, but high IO overhead.

### RAID stripe tree (6.7+)

The RAID stripe tree is a new tree (ID `BTRFS_RAID_STRIPE_TREE_OBJECTID`) introduced for zoned devices and RAID56. On zoned devices, physical writes must be sequential within a zone, so the simple logical→physical mapping of the chunk tree is insufficient for RAID5/6 (which needs RMW). The stripe tree maps logical extents to per-device physical locations, allowing the zoned block layer to manage sequential writes correctly. For non-zoned devices the stripe tree is optional.

## Key Data Structures

**`btrfs_chunk`** (`include/uapi/linux/btrfs_tree.h`) — on-disk chunk descriptor; RAID profile and stripe list.

**`btrfs_stripe`** — embedded in `btrfs_chunk`; physical location (devid + offset) of one stripe copy.

**`btrfs_dev_item`** (`include/uapi/linux/btrfs_tree.h`) — per-device descriptor stored in the chunk tree.
- `devid` — monotonically assigned device ID
- `total_bytes` / `bytes_used` — capacity accounting
- `uuid` / `fsid` — binding a device to a specific filesystem

**`btrfs_dev_extent`** — stored in the device tree; marks physical range on a device as belonging to a specific chunk. Enables `btrfs device delete` to find all extents on a device.

**`btrfs_bio_stripe`** (`fs/btrfs/volumes.h`) — runtime per-stripe IO descriptor returned by `btrfs_map_block()`.

**`btrfs_fs_devices`** (`fs/btrfs/volumes.h`) — runtime list of all devices in a filesystem; links `btrfs_device` structs.

## Key Functions / Entry Points

**`btrfs_map_block(fs_info, op, logical, length, bbio)`** (`fs/btrfs/volumes.c`) — translates a logical address range to a set of physical stripe IOs; the hot path for every read/write.

**`btrfs_alloc_chunk(trans, type)`** (`fs/btrfs/volumes.c`) — allocates a new chunk from the device pool for the given block group type (data/metadata/system).

**`btrfs_add_device(trans, fs_devices, device)`** (`fs/btrfs/volumes.c`) — registers a new device in the chunk and device trees.

**`btrfs_balance(fs_info, bargs, bctl)`** (`fs/btrfs/volumes.c`) — drives the balance operation; iterates block groups matching filter criteria and relocates them.

**`btrfs_scrub_dev(fs_info, devid, start, end, progress, readonly, is_dev_replace)`** (`fs/btrfs/scrub.c`) — reads every extent on a device, verifies checksums, and repairs from mirrors if possible.

**`raid56_parity_write()` / `raid56_rmw_stripe()`** (`fs/btrfs/raid56.c`) — RAID5/6 IO paths; the RMW path that reads existing stripe data, updates parity, and submits all modified sectors.

## Important Flags & Config Options

| Flag / Option | Effect |
|---|---|
| `mkfs.btrfs -d <profile>` | Sets data RAID profile at creation |
| `mkfs.btrfs -m <profile>` | Sets metadata RAID profile at creation |
| `btrfs balance start -dconvert=<p> -mconvert=<p>` | Online profile conversion |
| `BTRFS_BLOCK_GROUP_RAID5` / `_RAID6` | Type flags in `btrfs_chunk.type`; also used in `btrfs_block_group_item` |
| `-o degraded` | Mount flag: allow mounting with missing device(s); operations that require the missing device will fail |
| `raid56` module param (historical) | Was used to enable experimental RAID5/6; now enabled by default with warnings |

## Interactions with Other Subsystems

- **↑ Userspace**: `btrfs(8)` CLI wraps all device ioctls (`BTRFS_IOC_ADD_DEV`, `BTRFS_IOC_RM_DEV`, `BTRFS_IOC_DEV_REPLACE`, `BTRFS_IOC_BALANCE_V2`, `BTRFS_IOC_SCRUB`).
- **→ [[transaction-model]]**: Device add/remove and balance all run inside btrfs transactions. Chunk allocation writes chunk tree items transactionally.
- **→ [[checksumming-and-data-integrity]]**: Checksums are the mechanism that makes RAID1 repair deterministic (identify the bad mirror) and makes RAID5/6 recovery possible after a write-hole event.
- **→ Block layer**: `btrfs_map_block()` produces per-device bios that are submitted via `submit_bio()` to independent block devices; btrfs handles the scatter/gather itself rather than relying on the block layer's bio splitting.
- **← MM**: Large balance and scrub operations work through the page cache and block layer; memory pressure during scrub can cause backpressure on btrfs's internal stripe cache.

## Design Decisions & Tradeoffs

**RAID inside the filesystem vs MD RAID below it**: Integrating RAID lets btrfs checksum data at the extent level before striping, enabling per-copy checksum verification and silent corruption detection. MD RAID has no concept of "this copy has bad data" — it just serves whatever is on disk. The cost is implementation complexity: every RAID feature (scrub, replace, RAID56 recovery) must be reimplemented in btrfs rather than reusing the battle-hardened MD layer.

**Independent metadata and data profiles**: This is the primary advantage of in-filesystem RAID. RAID1 metadata + RAID0 data gives metadata redundancy on a two-device setup without halving usable data capacity. MD RAID cannot distinguish data from metadata.

**Chunk-level rather than extent-level striping**: btrfs stripes at the chunk level (256 MiB–1 GiB chunks) rather than per-extent. This reduces metadata overhead (one `btrfs_chunk` per chunk, not per file extent) but means a device cannot be removed if it has a chunk with no suitable target; balance must relocate the entire chunk.

**RAID5/6 as experimental for a decade**: The write hole problem and missing scrub-repair capability kept RAID5/6 experimental from 3.9 (2013) through kernel 6.x. The write-intent bitmap (6.1) addresses the write hole; full production readiness is still pending complete device-replace support and tooling.

## How It Has Evolved

- **2.6.29 (2009)**: Multi-device support (RAID0, RAID1, RAID10) present at initial merge.
- **3.9 (2013)**: RAID5/6 merged as experimental.
- **4.12 (2017)**: `btrfs replace` for RAID5/6 missing device improved.
- **5.5 (2020)**: `RAID1C3` and `RAID1C4` (triple and quad mirror) added.
- **6.1 (2022)**: Write-intent bitmap for RAID56 merged, addressing the write hole.
- **6.7 (2024)**: RAID stripe tree merged for zoned device + RAID56 support.

## Further Reading

1. **LWN — "Btrfs: Working with multiple devices"** (2013): https://lwn.net/Articles/577961/ — Admin-level overview of multi-device operations.
2. **LWN — "RAID 5/6 code merged into Btrfs"** (2013): https://lwn.net/Articles/536038/ — Design decisions and known limitations at merge.
3. **LWN — "btrfs: introduce write-intent bitmaps for RAID56"** (2022): https://lwn.net/Articles/900054/ — The write-hole fix.
4. **LWN — "btrfs: introduce RAID stripe tree"** (2023): https://lwn.net/Articles/944631/ — Stripe tree for zoned RAID56.
5. **dxuuu.xyz — "Understanding btrfs internals part 2"**: https://dxuuu.xyz/btrfs-internals-2.html — Chunk tree struct walkthrough.

## LKML Highlights

- **RAID5/6 initial merge** (Chris Mason, 2013): discussion around `[PATCH] Btrfs: Add initial btrfs RAID5 and RAID6 support` — Mason acknowledged the write hole as "the big missing piece" and the decision to merge as experimental rather than wait for a full solution.
- **Write-intent bitmap** (Qu Wenruo, ~2022): thread debating bitmap-based approach vs full journal for RAID56 consistency; bitmap chosen because btrfs checksums allow targeted recovery without needing to log full stripe state.
