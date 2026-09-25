---
title: "Btrfs Checksumming and Data Integrity"
category: concept
tags: [btrfs, checksums, data-integrity, scrub, crc32c, xxhash64]
subsystem: btrfs
kernel_version: "2.6.29"
researched: 2026-04-05
status: complete
explained: "[[checksumming-and-data-integrity-explained]]"
sources:
  - https://lwn.net/Articles/432083/
  - https://lwn.net/Articles/818842/
  - https://lwn.net/Articles/623836/
  - https://lwn.net/Articles/802827/
  - https://lwn.net/Articles/797956/
  - https://archive.kernel.org/oldwiki/btrfs.wiki.kernel.org/index.php/Btrfs_design.html
  - https://wiki.tnonline.net/w/Btrfs/Checksum_Algorithms
---

# Btrfs Checksumming and Data Integrity

> 📘 Plain-language version: [[checksumming-and-data-integrity-explained]]

## Purpose

Most filesystems trust that data read from disk matches data written to disk. Btrfs does not: every data block and every metadata block carries a checksum. When a block is read, btrfs verifies it against the stored checksum and, if a mismatch is detected on a redundant filesystem (RAID1, RAID10, RAID5/6), automatically repairs it from a good copy. This makes btrfs capable of detecting and correcting **silent corruption** — bit-flips caused by failing disks, faulty DRAM, or buggy firmware — that traditional filesystems would serve to applications without complaint.

## Mental Model

Btrfs checksums work in two tiers. For **metadata** (every B-tree node and leaf), the checksum is stored inline in the block header — reading any B-tree block automatically verifies it. For **file data** extents, checksums are stored externally in a dedicated **checksum tree** keyed by logical byte offset. When a file extent is read, btrfs looks up the checksum(s) for that logical range, reads the data blocks, and verifies each block-sized slice. A periodic **scrub** operation reads every allocated extent from disk sequentially, verifies checksums, and repairs from mirrors — catching corruption before it propagates.

## How It Works

### Metadata checksums — inline in the block header

Every `extent_buffer` (the in-memory representation of a B-tree block) begins with `struct btrfs_header`:

```c
struct btrfs_header {
    u8   csum[BTRFS_CSUM_SIZE]; /* checksum of the rest of this block */
    u8   fsid[BTRFS_FSID_SIZE]; /* filesystem UUID — guards against wrong-device reads */
    __le64 bytenr;              /* expected disk address — guards against misplaced writes */
    __le64 flags;
    u8   chunk_tree_uuid[BTRFS_UUID_SIZE];
    __le64 generation;
    __le64 owner;               /* which tree owns this block */
    __le32 nritems;
    u8   level;                 /* 0 = leaf, >0 = internal */
};
```

`BTRFS_CSUM_SIZE` is 32 bytes — large enough for SHA-256 or BLAKE2b; CRC32C and xxHash64 use only 4 or 8 bytes of the field. The checksum covers all bytes in the block after the `csum` field itself.

When a block is read from disk by `read_extent_buffer_pages()`, the kernel calls `btrfs_validate_metadata_buffer()` which recomputes the checksum and compares it to the stored value. It also verifies `bytenr` matches where the block was actually read from — catching transposition errors (a good block written to the wrong location).

On write, `btrfs_mark_buffer_dirty()` queues the block; at IO submission `csum_tree_block()` recomputes and stores the checksum before the page hits the block layer.

### Data checksums — the checksum tree

File data checksums are stored in the **checksum tree** (tree ID `BTRFS_CSUM_TREE_OBJECTID = 7`). Items use key type `BTRFS_EXTENT_CSUM_KEY` with the key offset equal to the **logical byte offset** of the data extent. A single `btrfs_csum_item` contains a contiguous run of per-sector checksums packed end-to-end:

```
Key: (BTRFS_EXTENT_CSUM_OBJECTID, BTRFS_EXTENT_CSUM_KEY, logical_offset)
Value: [ csum_0 | csum_1 | csum_2 | ... ]
       one entry per sector (4096 bytes) in the contiguous run
```

A CRC32C checksum is 4 bytes; xxHash64 is 8 bytes; SHA-256/BLAKE2b are 32 bytes. For a 1 MiB extent with 4 KiB sectors and CRC32C, the csum item holds 256 × 4 = 1024 bytes of checksum data. If an item would exceed leaf capacity, the run is split into multiple items.

**Write path**: when an ordered extent completes (file data has been written to disk), `btrfs_csum_file_blocks()` walks the written range, computes per-sector checksums, and inserts/updates `btrfs_csum_item` entries in a transaction.

**Read path**: `btrfs_lookup_bio_sums()` is called from `btrfs_submit_bio()` for data reads. It looks up the checksum items covering the read range and attaches the expected checksums to the bio. After the IO completes, `btrfs_verify_data_csum()` iterates through each sector's page, computes the checksum, and compares to the expected value. On mismatch it calls `btrfs_repair_one_sector()`.

**Inline data**: data stored inline in B-tree leaves (small files using `BTRFS_INLINE_DATA_KEY`) is not stored in the checksum tree — it is protected by the metadata block's own header checksum.

### Checksum algorithms

| Algorithm | ID | Output size | Characteristic |
|---|---|---|---|
| CRC32C | 1 | 4 bytes | Default; hardware-accelerated on x86/ARM; not cryptographic |
| xxHash64 | 2 | 8 bytes | Faster in software than CRC32C on some platforms; not cryptographic |
| SHA-256 | 3 | 32 bytes | Cryptographic; slow without hardware acceleration |
| BLAKE2b | 4 | 32 bytes | Cryptographic; faster than SHA-256 in software |
| HMAC(SHA-256) | 5 | 32 bytes | Authenticated — requires a secret key; guards against deliberate tampering |

The algorithm is chosen at `mkfs` time with `--csum <name>` and stored in `btrfs_super_block.csum_type`. It cannot be changed after creation. All algorithms use the same 32-byte `csum` field in `btrfs_header`; smaller algorithms are zero-padded.

HMAC(SHA-256) (added ~5.12) requires a key supplied via the kernel keyring at mount time (`btrfs --auth-key`). Without the key, an attacker who can write to the raw device cannot forge valid checksums — any tampering is detected at read time. This protects against offline attacks; a kernel-level compromise can still bypass verification.

### Scrub — proactive integrity verification

Scrub (`btrfs scrub start /mnt`) is the mechanism for finding corruption before it is requested by an application. It runs per-device and proceeds as follows:

1. **Chunk enumeration**: the scrub thread iterates allocated chunks on the target device using the device tree.
2. **Extent enumeration**: for each chunk, it walks the extent tree to find all allocated extents within the chunk's physical range.
3. **Checksum fetch**: for data extents, it looks up checksums from the checksum tree. For metadata blocks, the inline header checksum suffices.
4. **Sequential read**: extents are read sequentially (optimised for disk seek patterns) via `btrfs_submit_bio()` with a scrub-specific endio handler.
5. **Verification**: each sector is checked against its expected checksum.
6. **Repair**: on mismatch, a good copy is fetched from a mirror (RAID1/10) or reconstructed from parity (RAID5/6) and the bad sector is rewritten.

Scrub uses **commit roots** (the roots from the last committed transaction) for all B-tree lookups. This ensures a stable view even while the filesystem is mounted and active. When a transaction commits during scrub, the scrub threads pause briefly and then resume from the new commit roots.

Scrub statistics are reported via `btrfs scrub status` and include counts of errors found, errors corrected, and uncorrectable errors (where all copies were bad).

### Repair on read

Even without scrub, btrfs repairs silently on every read of a RAID-redundant extent. When `btrfs_verify_data_csum()` detects a mismatch:

1. `btrfs_repair_one_sector()` submits a read to the mirror device(s).
2. If a mirror read succeeds and its checksum matches, the bad sector on the original device is rewritten from the good copy.
3. The application receives the correct data — the corruption is transparent.

For metadata, `btrfs_read_tree_block()` attempts mirror reads on checksum failure in the same way.

## Key Data Structures

**`btrfs_header`** (`include/uapi/linux/btrfs_tree.h`) — first bytes of every B-tree block; `csum[]` covers everything after itself; `bytenr` provides write-location verification.

**`btrfs_csum_item`** (`include/uapi/linux/btrfs_tree.h`) — variable-length leaf item in the checksum tree; a packed array of per-sector checksums for a contiguous logical range.

**`btrfs_super_block.csum_type`** — `u16`; identifies which algorithm the entire filesystem uses; cannot be changed after creation.

**`struct btrfs_scrub_progress`** (`include/uapi/linux/btrfs.h`) — userspace-visible stats returned by `BTRFS_IOC_SCRUB_PROGRESS`: `data_extents_scrubbed`, `tree_extents_scrubbed`, `data_bytes_scrubbed`, `corrected_errors`, `uncorrectable_errors`, `unverified_errors`.

## Key Functions / Entry Points

**`btrfs_validate_metadata_buffer()`** (`fs/btrfs/disk-io.c`) — called after every metadata page read; recomputes checksum and verifies `bytenr` and `fsid`.

**`btrfs_csum_file_blocks(trans, root, sums)`** (`fs/btrfs/file-item.c`) — inserts/updates checksum tree items for a range of just-written file data sectors.

**`btrfs_lookup_bio_sums()`** (`fs/btrfs/file-item.c`) — fetches expected checksums from the checksum tree for a data read bio; attaches them to the bio for post-IO verification.

**`btrfs_verify_data_csum()`** (`fs/btrfs/inode.c`) — per-sector checksum verification called in the read endio; triggers repair on failure.

**`btrfs_repair_one_sector()`** (`fs/btrfs/extent_io.c`) — fetches a good copy from a mirror and rewrites the bad sector.

**`scrub_enumerate_chunks()` → `scrub_extent()`** (`fs/btrfs/scrub.c`) — the scrub main loop; iterates device chunks → extents → sectors, verifying and repairing each.

## Important Flags & Config Options

| Flag / Option | Effect |
|---|---|
| `mkfs.btrfs --csum crc32c\|xxhash\|sha256\|blake2` | Choose checksum algorithm at creation (default: `crc32c`) |
| `mkfs.btrfs --csum hmac-sha256 --auth-key <hex>` | Enable authenticated btrfs |
| `btrfs scrub start -B /mnt` | Run scrub in foreground (blocks until complete) |
| `btrfs scrub start -r /mnt` | Read-only scrub: detect but do not repair errors |
| `BTRFS_IOC_SCRUB` / `BTRFS_IOC_SCRUB_CANCEL` | Ioctls for starting, cancelling, and querying scrub |
| `nodatasum` mount option | Disables data checksumming for specific subvolumes (not recommended for data files; used for swap files) |
| `nodatacow` mount option | Disables CoW and checksumming for a file/subvolume (mutually required for swap) |

## Interactions with Other Subsystems

- **↑ Userspace**: `btrfs scrub`, `btrfs check`, `btrfs rescue` all operate on checksum data. Applications see correct data transparently; corruption events can be observed via dmesg and `btrfs scrub status`.
- **→ [[multiple-b-trees]]**: Every B-tree block written goes through checksum computation; every B-tree block read goes through verification. Checksumming is inseparable from B-tree IO.
- **→ [[raid-and-multi-device-support]]**: Checksums are the mechanism that makes RAID1 repair deterministic — without per-sector checksums, there is no way to know which mirror copy is the good one after a divergence. RAID5/6 recovery after a write-hole event also relies on checksums to identify the corrupted device.
- **→ [[transaction-model]]**: Checksum tree updates are written inside a transaction. The new checksums are committed atomically with the extent items that reference the data; a crash cannot leave new data with old checksums or vice versa.
- **→ Block layer**: Data checksums are computed and stored after compression, reflecting bytes actually on disk. Compressed extents have checksums over the compressed form; the decompression layer does not re-verify post-decompress (the compressed-level checksum is sufficient).

## Design Decisions & Tradeoffs

**Per-block checksums rather than per-file**: Btrfs checksums every 4 KiB sector individually, not the file as a whole. This allows repair at sector granularity (only the bad sector needs to be rewritten) and enables scrub to verify without reading entire files.

**Checksum tree separate from extent tree**: Storing checksums in a dedicated B-tree keeps extent tree items small and allows checksum lookup to scale independently. The cost is a second B-tree lookup on every data read. An alternative (storing checksums inline in extent items) was considered but rejected because it would bloat the extent tree and complicate batch checksum insertion.

**CRC32C as default**: CRC32C is not cryptographic — a malicious actor who can write to the device can forge it. But btrfs's primary goal is hardware fault detection, not tamper resistance. CRC32C has hardware acceleration on x86 (`sse4.2`) and ARM, making it nearly free in the IO path. BLAKE2b and SHA-256 are available for environments where cryptographic integrity matters.

**`nodatasum` for swap**: Btrfs checksums are incompatible with swap files because swap file pages are written by the kernel without going through the normal file write path and without updating the checksum tree. `nodatacow` (which implies `nodatasum`) is required for swap.

**Scrub uses commit roots for consistency**: Scrub reads B-tree state from commit roots, not the live tree. This means scrub sees a slightly stale view of the filesystem but never sees a partially-committed transaction state. The tradeoff is that extents allocated after the last commit are not scrubbed until the next transaction commits.

## How It Has Evolved

- **2.6.29 (2009)**: CRC32C checksums present at initial btrfs merge. Data and metadata both checksummed.
- **3.16 (2014)**: Scrub gains the ability to repair from parity on RAID5/6.
- **5.5 (2020)**: xxHash64 added as a faster software checksum alternative.
- **5.5 (2020)**: SHA-256 added as a cryptographic option.
- **5.5 (2020)**: BLAKE2b added as a faster cryptographic option.
- **5.12 (2021)**: HMAC(SHA-256) ("authenticated btrfs") merged, enabling tamper detection with a secret key.
- **6.x**: Scrub rewrite for improved performance and new ioctl family (`BTRFS_IOC_SCRUB_FS`) covering full-filesystem scrub in a single ioctl.

## Further Reading

1. **LWN — "btrfs: scrub"** (2011): https://lwn.net/Articles/432083/ — Initial scrub implementation design.
2. **LWN — "Authenticated Btrfs"** (2021): https://lwn.net/Articles/818842/ — HMAC-SHA256 design and limitations.
3. **LWN — "btrfs: support xxhash64 checksums"** (2019): https://lwn.net/Articles/797956/ — Rationale for adding a second fast algorithm.
4. **LWN — "Btrfs: Add BLAKE2 checksumming support"** (2020): https://lwn.net/Articles/802827/
5. **wiki.tnonline.net — Btrfs Checksum Algorithms**: https://wiki.tnonline.net/w/Btrfs/Checksum_Algorithms — Concise reference on algorithm IDs and sizes.

## LKML Highlights

- **SHA-256 checksum option** (2015, `[PATCH] Btrfs: add sha256 checksum option`): debate on whether cryptographic checksums belong in a filesystem or at a higher layer; the outcome deferred to 5.5 with a cleaner multi-algorithm framework.
- **HMAC-SHA256 authenticated btrfs** (Johannes Thumshirn, 2021): thread debating key management (keyring vs kernel command line) and scope of protection; consensus that it protects against offline attacks only and should not be compared to full disk encryption.
