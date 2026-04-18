---
title: "dm-integrity Bitmap Mode"
category: concept
tags: [dm-integrity, bitmap, block, device-mapper, crash-recovery, performance]
subsystem: dm-integrity
kernel_version: "4.18"
researched: 2026-04-18
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html
  - https://people.redhat.com/mpatocka/patches/kernel/dm-integrity-bitmap/dm-integrity-bitmap.patch
  - https://www.kernel.org/doc/Documentation/device-mapper/dm-integrity.txt
---

# dm-integrity Bitmap Mode

## Purpose

Bitmap mode (`'B'`) provides the write throughput of direct writes (no journal double-write) while still detecting data/tag inconsistencies caused by crashes. It is applicable only when dm-integrity computes tags internally (`internal_hash`) — because internal tags are deterministically recomputable from the data content, a post-crash recalculation pass can always recover a correct tag.

## Mental Model

Instead of a write-ahead journal, bitmap mode uses a **dirty region map**: every write marks its region as dirty before committing to disk. If the machine crashes with a region marked dirty, that region is flagged for tag recalculation on next mount. Because the tag is just a hash of the data, "recalculate" simply means "re-read the data and re-derive the tag" — no journal replay needed.

## How It Works

The bitmap is stored in the superblock area and tracks the device at a fixed granularity (each bit covers a range of sectors). When a bio arrives in bitmap mode, `integrity_map()`:

1. **Sets the dirty bit** for the region covering the destination sectors, before submitting any I/O.
2. **Submits the data write** directly to the permanent location (not to a journal).
3. **Submits the tag write** via dm-bufio to the permanent tag area.
4. **Clears the dirty bit** after both writes have completed.

The dirty-bit-set step happens *before* I/O, so a crash between step 1 and step 4 leaves the bit set. The dirty-bit-clear step only happens after the write has landed on disk — there is no window where the bit is clear but the data is not yet committed.

### Crash recovery

On mount after a crash, `integrity_ctr()` reads the bitmap. Any region with a dirty bit is flagged for recalculation. The **recalculation worker** (`integrity_recalc()`) scans these regions: it reads the sector data, computes `crypto_shash_digest()` over it, and writes the fresh tag to the tag area. After the tag write, the dirty bit is cleared and the superblock is updated.

This approach is safe because the internal hash is a deterministic function of the data. If the data write completed before the crash but the tag write did not, recalculation fixes the tag. If the data write itself was partial (torn write), recalculation writes a tag that matches the partial data — the data corruption is already present, but the integrity system's tag will now match that corrupted data. This is the accepted limitation of bitmap mode: it cannot detect corruption that was present *before* the crash, only corruption introduced by the crash itself.

### Bitmap flush interval

The bitmap is kept in memory and periodically flushed to disk via `integrity_bitmap_flush()`. The `bitmap_flush_interval` parameter (default 10,000 ms) controls how often this happens. If the machine crashes while the bitmap has dirty bits in memory but the last flush occurred long ago, the on-disk bitmap may not reflect all dirty regions — some regions might not be recalculated on recovery, potentially missing a corrupted tag. A shorter `bitmap_flush_interval` reduces this window at the cost of more frequent metadata writes.

### Limitations vs. journaled mode

Bitmap mode cannot be used with external tags (from dm-crypt AEAD). AEAD tags are not recomputable without the decryption key and the plaintext in scope — if a crash occurs between the data write and the tag write in this scenario, there is no way to regenerate the correct AEAD tag during recovery. Journaled mode is required when dm-crypt is stacked above dm-integrity.

## Key Data Structures

**In-memory dirty bitmap** (array of `unsigned long` within `dm_integrity_c`):
- One bit per `bitmap_area_sectors` region
- Flushed to a dedicated on-disk bitmap region within the superblock area

## Key Functions / Entry Points

**`integrity_bitmap_flush()`** (`dm-integrity.c`) — writes the in-memory bitmap to its on-disk location with a barrier; scheduled by a timer every `bitmap_flush_interval` ms.

**`integrity_recalc()`** — background workqueue function; reads sectors, recomputes tags, writes updated tags, clears dirty bits.

**`integrity_bitmap_dirty()`** — sets a dirty bit before a write; called from `integrity_map()` in bitmap mode.

**`integrity_bitmap_clean()`** — clears dirty bits after a successful write completion.

## Important Flags & Config Options

- `bitmap_flush_interval` (default 10000 ms) — lower values shrink the crash-recovery gap but increase metadata write I/O.
- Bitmap mode requires `internal_hash` — the two options must be specified together.
- `recalculate` option at table creation time initiates an initial tag-calculation pass for freshly formatted devices.

## Interactions with Other Subsystems

- **← [[dm-integrity-recalculation]]**: the recalculation worker is the primary consumer of dirty bitmap bits; it clears bits as it recalculates regions.
- **← [[dm-integrity-journal]]**: bitmap mode and journaled mode are mutually exclusive; `integrity_ctr()` validates that mode `'B'` is not combined with external tags.
- **→ [[dm-bufio]]**: tag writes during normal I/O still go through dm-bufio; only the journal is absent.

## Design Decisions & Tradeoffs

Bitmap mode was motivated by the observation that the journal's write doubling cost was unacceptable for large sequential workloads (e.g., backup storage, database data files) where throughput matters more than sub-second crash consistency. By accepting that tags may be stale for up to `bitmap_flush_interval` milliseconds of writes after a crash, bitmap mode trades a small recovery window for full write throughput.

The decision to require `internal_hash` for bitmap mode is a hard constraint, not a convenience — without a deterministic tag function, recalculation is impossible, making the "set dirty bit before write" approach logically unsound.

## How It Has Evolved

- **4.18**: Bitmap mode introduced by Mikulas Patocka.
- **5.x**: `bitmap_flush_interval` added as a runtime-tunable parameter (previously was a fixed default).
- **5.7**: Improved interaction between bitmap mode and `allow_discards`: discarded sectors get their tags set to the hash of zeros, avoiding a full recalculation pass.

## Further Reading

1. [dm-integrity — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html) — bitmap mode parameters
2. [Bitmap mode patch](https://people.redhat.com/mpatocka/patches/kernel/dm-integrity-bitmap/dm-integrity-bitmap.patch) — Mikulas Patocka's original patch with design rationale

## LKML Highlights

- **2018 (Mikulas Patocka)**: Bitmap mode introduction — argued that for backup/archive workloads the 2× write overhead of the journal made dm-integrity impractical, and that the recalculation guarantee was sufficient for these use cases; the patch thread settled on making `internal_hash` mandatory as a hard dependency.
