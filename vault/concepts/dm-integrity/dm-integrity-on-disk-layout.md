---
title: "dm-integrity On-Disk Layout"
category: concept
tags: [dm-integrity, block, device-mapper, layout, superblock, format]
subsystem: dm-integrity
kernel_version: "4.12"
researched: 2026-04-18
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html
  - https://www.kernel.org/doc/Documentation/device-mapper/dm-integrity.txt
  - https://mjmwired.net/kernel/Documentation/device-mapper/dm-integrity.txt
---

# dm-integrity On-Disk Layout

## Purpose

The on-disk layout defines exactly where every byte of metadata, journal, and data lives on the underlying block device. A fixed, derivable layout means that locating any sector's integrity tag requires only arithmetic — no additional index structures, no extra I/O just to find the tag. Every parameter that affects layout is either recorded in the superblock or derivable from it, so a device formatted on one kernel version can be opened on any later version.

## Mental Model

Think of the device as divided into three zones laid down sequentially: a **superblock** that describes the whole structure, a **journal** that provides crash recovery, and a **data+tag interleave** where each chunk of data sectors is immediately preceded by the tag sector covering it. Finding the tag for sector *N* is the same arithmetic every time: divide by chunk size to find which chunk, then look at the tag area sector at the start of that chunk.

## How It Works

The formatted layout, starting from the first sector of the dm-integrity area (after any user-reserved sectors):

```
[superblock: 4 KiB (8 × 512-byte sectors)]
[journal: journal_sections × (metadata_area + data_area)]
[chunk 0: tag_area sectors | data sectors (interleave_sectors)]
[chunk 1: tag_area sectors | data sectors (interleave_sectors)]
...
```

### Superblock (4 KiB)

The superblock is the anchor for everything else. It contains:
- Magic string `"integrt\0"` (8 bytes) — identifies the device as dm-integrity formatted
- Format version (u32) — allows forward-compatible changes
- `log2(interleave_sectors)` (u8) — power-of-two encoding of chunk size; used to compute layout at load time
- Integrity tag size in bytes (u16) — per-sector, fixed at format time
- Number of journal sections (u32)
- `provided_data_sectors` (u64) — total usable data sectors; the DM target size must not exceed this
- `recalc_sector` (u64) — progress pointer for background tag recalculation

The superblock is read during `integrity_ctr()`. If `provided_data_sectors` is zero, the device needs formatting: `integrity_ctr()` loads with a one-sector target, reads the superblock, then reloads with the full `provided_data_sectors` size.

### Journal sections

Each journal section consists of:
- **Metadata area (4 KiB)**: one entry per data sector in the section, each entry containing: `[u64 logical_sector | u8[8] last_bytes | u8[tag_size] integrity_tag]`. The `logical_sector` field records *where* this sector should ultimately be written; `last_bytes` holds the last 8 bytes of the sector's data content (since only 8 bytes fit alongside sector number and tag in one metadata entry, the rest of the sector data lives in the data area below).
- **Data area**: raw sector data for the sectors described in the metadata area, minus the last 8 bytes that are in the metadata entry.

Every 512-byte word of the journal ends with an 8-byte **commit ID** — a monotonically increasing counter per section. After `integrity_commit()` runs, all sectors in the section are overwritten with the current commit ID in the last 8 bytes. On replay after a crash, a section is valid only if every sector's last 8 bytes carry the same commit ID. A partial write (commit ID mismatch on any sector) means the section was never fully committed and is skipped.

### Data+tag interleave

Each "chunk" contains:
- A **tag area** of `ceil(interleave_sectors * tag_size / sector_size)` sectors, holding the integrity tags for all sectors in the following data chunk.
- A **data area** of exactly `interleave_sectors` sectors.

`interleave_sectors` is always a power of two (stored as `log2` in the superblock), so given a logical sector `s`:
```
chunk_index  = s >> log2_interleave
chunk_offset = s & (interleave_sectors - 1)
tag_sector   = journal_end
             + chunk_index * (tag_area_sectors + interleave_sectors)
             + (chunk_offset * tag_size) / sector_size
tag_offset   = (chunk_offset * tag_size) % sector_size
```

This arithmetic is all that `get_data_sector()` and `integrity_sector_tag_area()` do. No additional index read is needed.

## Key Data Structures

**`struct superblock`** (internal, `dm-integrity.c`) — on-disk superblock layout:
- `magic[8]` — `"integrt\0"`
- `version` — format version
- `log2_interleave_sectors` — `log2(interleave_sectors)`
- `tag_size` — bytes per sector tag
- `journal_sections` — section count
- `provided_data_sectors` — total data capacity
- `recalc_sector` — recalculation progress

## Key Functions / Entry Points

**`get_data_sector()`** (`dm-integrity.c`) — converts a logical data sector number to its physical location on the underlying device, accounting for the journal and tag area offsets.

**`integrity_sector_tag_area()`** — returns the dm-bufio buffer and byte offset within it for a given sector's tag.

**`integrity_format_header()`** — writes a fresh superblock during `integritysetup format`, setting all fields and zero-filling reserved areas.

**`integrity_commit_superblock()`** — writes updated superblock fields (especially `recalc_sector`) to disk with a barrier.

## Important Flags & Config Options

- `interleave_sectors` (default 32768) — set at format time; larger values mean larger tag areas and slightly fewer chunk boundaries, but also larger granularity for dm-bufio cache misses.
- `block_size` (512/1024/2048/4096) — affects `sectors_per_block` and minimum I/O granularity.
- `journal_sectors` — sets journal size at format time; larger journals allow higher burst write rates before the background flush must catch up.

## Interactions with Other Subsystems

- **→ [[dm-bufio]]**: tag area sectors are accessed exclusively through dm-bufio; the bufio client covers the range `[journal_end, device_end)`.
- **← [[dm-integrity-journal]]**: journal section boundaries are computed from `journal_sections` and the per-section size, both stored in or derived from the superblock.

## Design Decisions & Tradeoffs

The interleaved layout (tag area immediately before the data it covers) minimises seek distance on spinning disks — a read that needs to verify a sector fetches the tag sector in the same or adjacent track. On SSDs the layout is irrelevant for latency but still reduces the worst-case I/O count per verified read to two (one tag sector + one data sector).

Storing `log2(interleave_sectors)` rather than the raw value constrains `interleave_sectors` to powers of two, but makes chunk boundary arithmetic branchless shift-and-mask operations rather than divides.

## How It Has Evolved

- **4.12**: Initial layout with superblock, journal, and interleaved data+tag. Superblock version 1.
- **5.x**: `recalc_sector` added to superblock for background recalculation progress tracking.
- **6.11**: Inline mode uses the device's extended sector space rather than the interleaved layout — `provided_data_sectors` maps 1:1 to physical sectors in this mode.

## Further Reading

1. [dm-integrity — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html) — layout section with field descriptions
2. [dm-integrity.txt (v4.12) — LWN](https://lwn.net/Articles/721738/) — original layout documentation

## LKML Highlights

- **2017 (Milan Broz)**: Superblock design thread — rationale for the `log2(interleave_sectors)` encoding and why a power-of-two constraint was acceptable given the target use cases (server storage with large sequential writes).
