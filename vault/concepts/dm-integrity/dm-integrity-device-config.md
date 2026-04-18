---
title: "dm-integrity Device Config (dm_integrity_c)"
category: concept
tags: [dm-integrity, device-mapper, block, config, initialization]
subsystem: dm-integrity
kernel_version: "4.12"
researched: 2026-04-18
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html
  - https://github.com/torvalds/linux/blob/master/drivers/md/dm-integrity.c
---

# dm-integrity Device Config (dm_integrity_c)

## Purpose

`dm_integrity_c` is the per-device singleton that holds all state dm-integrity needs for the lifetime of an active volume: operating mode, hash algorithm handles, journal parameters, bitmap state, bufio client for the tag area, and memory pool references. Without a stable config struct, every I/O path operation would have to re-parse the device table line and re-open crypto transforms — impossible under the DM bio submission model.

## Mental Model

`dm_integrity_c` is the **nerve center** for an integrity volume. When `dmsetup create` runs, the Device Mapper core invokes `integrity_ctr()` to construct this struct from the table line. From that point, every bio that enters the device touches the config through a pointer embedded in the device's DM target. When the device is removed, `integrity_dtr()` tears everything down in the reverse order.

## How It Works

`integrity_ctr()` is called with the Device Mapper table line split into argc/argv. It begins by parsing mandatory arguments: the underlying device path, the data start offset (reserved sectors), the tag size in bytes, and the operating mode character (`'J'`, `'D'`, `'B'`, `'I'`, or `'R'`). Optional keyword arguments (`internal_hash`, `journal_crypt`, `journal_mac`, `block_size`, `interleave_sectors`, `journal_sectors`, `buffer_sectors`, `journal_watermark`, `commit_time`, `allow_discards`, `fix_padding`, `fix_hmac`) follow.

From `tag_size` and `block_size` (default 512), `integrity_ctr()` derives the layout parameters: the number of data sectors per interleave chunk, the number of tag area sectors per chunk, and the journal section count. If a superblock already exists on the device (non-zero magic string), the layout values are read from disk and validated against what the table line specifies — a mismatch causes `integrity_ctr()` to return `-EINVAL`.

If `internal_hash` is specified (e.g., `internal_hash:crc32c` or `internal_hash:hmac(sha256):64:<key_hex>`), `integrity_ctr()` calls `crypto_alloc_shash(alg_name, ...)` and stores the `crypto_shash *` in `ic->internal_hash`. The hash state size is used to validate that `tag_size` is large enough to hold the digest output. If `journal_crypt` is specified, a `crypto_skcipher *` is allocated; if `journal_mac`, another `crypto_shash *`.

A `dm_bufio_client` is opened over the tag area of the underlying device via `dm_bufio_client_create()`. This client provides an LRU buffer cache for tag sector I/O — all reads and writes of integrity tags go through dm-bufio rather than raw bio submission, giving hot tag regions a caching benefit.

Two mempools are set up: one for `dm_integrity_io` objects (per-bio work units) and one for page allocations during tag computation. Workqueue handles are allocated for the journal committer and the background data flusher.

On teardown, `integrity_dtr()` flushes the journal, commits the superblock (updating `recalc_sector` if a recalculation was in progress), destroys the crypto transforms, tears down the bufio client, and frees all mempools.

## Key Data Structures

**`struct dm_integrity_c`** (`drivers/md/dm-integrity.c`) — per-device config singleton:
- `dev` — `struct dm_dev *` to the underlying block device
- `start` — sector offset from the start of `dev` to the dm-integrity area
- `tag_size` — bytes per sector tag
- `sector_size` — bytes per logical sector (512 default)
- `sectors_per_block` — `block_size / sector_size`
- `mode` — `char`: `'J'`, `'D'`, `'B'`, `'I'`, or `'R'`
- `internal_hash` — `struct crypto_shash *` for CRC/HMAC computation
- `journal_sections` — count of journal sections
- `provided_data_sectors` — total data sectors the DM target exposes
- `recalc_sector` — last sector for which tags are known-good (persisted in superblock)
- `bufio` — `struct dm_bufio_client *` for the tag area cache
- `commit_ids` — array of per-section commit ID counters

## Key Functions / Entry Points

**`integrity_ctr()`** (`drivers/md/dm-integrity.c`) — Device Mapper constructor; parses table line, opens crypto transforms, initialises bufio, allocates mempools. Called by DM core when the target is created.

**`integrity_dtr()`** — Device Mapper destructor; flushes journal, tears down all resources. Called when the DM device is removed.

**`integrity_superblock_ctr()`** — reads the on-disk superblock into `ic` fields; called during `integrity_ctr()` on an existing device.

## Important Flags & Config Options

- `CONFIG_DM_INTEGRITY` — Kconfig symbol enabling the target.
- `internal_hash:<alg>` table option — enables internal tag computation; without it, tags must arrive via `bio_integrity_payload`.
- `journal_crypt:<alg>` — encrypts journal entries to hide sector addresses.
- `journal_mac:<alg>:<key>` — HMAC-protects sector numbers in journal entries against relocation attacks.

## Interactions with Other Subsystems

- **↑ Userspace**: `integritysetup create` / `dmsetup create` supply the table line via `DM_TABLE_LOAD` ioctl.
- **→ [[kernel-crypto-api]]**: `crypto_alloc_shash()` and `crypto_alloc_skcipher()` obtain the algorithm handles stored in `ic`.
- **→ [[dm-bufio]]**: `dm_bufio_client_create()` opens the cache client; all tag I/O goes through it.
- **← [[device-mapper]]**: DM core calls `integrity_ctr()` / `integrity_dtr()` as part of the target plugin lifecycle.

## Design Decisions & Tradeoffs

The decision to open a single `dm_bufio_client` over the entire tag area (rather than submitting raw bios for each tag access) trades a small extra memory overhead (bufio client metadata) for cache coherence — without bufio, two concurrent bios to adjacent sectors could race on the same tag sector buffer. dm-bufio provides per-buffer locking and LRU eviction, both of which are needed for the tag area access pattern.

## How It Has Evolved

- **4.12**: Initial `dm_integrity_c` with modes `'D'` and `'J'`, `internal_hash`, `journal_crypt`, `journal_mac`.
- **4.18**: Bitmap mode fields (`bitmap_flush_interval`, dirty bitmap pointer) added.
- **5.7**: `allow_discards` field added.
- **6.11**: `mode == 'I'` (inline) handling added; `inline_*` layout fields.

## Further Reading

1. [dm-integrity — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html)
2. [dm-integrity source: dm-integrity.c](https://github.com/torvalds/linux/blob/master/drivers/md/dm-integrity.c)

## LKML Highlights

- **2017 (Milan Broz)**: Original dm-integrity patch series — `integrity_ctr()` design rationale, especially the choice to open `dm_bufio_client` over the tag area rather than using raw block I/O, and the decision to store operating mode as a single character in the superblock for forward-compatible extension.
