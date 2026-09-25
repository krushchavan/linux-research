---
title: "dm-integrity Tag Management"
category: concept
tags: [dm-integrity, tags, checksums, bio_integrity_payload, block, device-mapper]
subsystem: dm-integrity
kernel_version: "4.12"
researched: 2026-04-18
status: complete
explained: "[[dm-integrity-tag-management-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html
  - https://docs.kernel.org/block/data-integrity.html
  - https://github.com/torvalds/linux/blob/master/drivers/md/dm-integrity.c
---

# dm-integrity Tag Management

> 📘 Plain-language version: [[dm-integrity-tag-management-explained]]

## Purpose

Tag management is the layer that computes, stores, retrieves, and verifies the per-sector integrity tags that are dm-integrity's fundamental guarantee. It abstracts the difference between two tag sources — tags computed internally from the data (via CRC or HMAC) and tags supplied externally by dm-crypt's AEAD cipher — so the I/O path does not need to know which source is active.

## Mental Model

Every sector has a small companion: its **integrity tag**. On write, the tag is either computed from the sector data or received from dm-crypt, then stored alongside the sector. On read, the tag is fetched and compared against the expected value (or handed back to dm-crypt for AEAD verification). Correct tag → data is intact. Incorrect tag → `-EIO`.

## How It Works

### Write path: internal hash

When `internal_hash` is configured, `integrity_calculate_tags()` is called before any data hits the journal or the permanent area. For each sector in the bio, it calls `crypto_shash_digest(ic->internal_hash, sector_data, sector_size, tag_buffer)`. The tag length equals `crypto_shash_digestsize(ic->internal_hash)`, which must be ≤ `tag_size` configured at format time (extra bytes are zero-padded).

For HMAC algorithms (`hmac(sha256)`), the hmac key is set once during `integrity_ctr()` via `crypto_shash_setkey()`. The same key is applied to every sector — the sector number itself is not included in the HMAC input unless `journal_mac` is separately configured. If per-sector key derivation is needed, the user can include the sector number in a prehashed input, but this is not done automatically.

The computed tag bytes are written to:
- **Journaled mode**: the tag field of the journal entry for this sector.
- **Direct/bitmap mode**: directly to the dm-bufio tag buffer for the sector's tag area position.

### Write path: external AEAD tags (dm-crypt)

When `internal_hash` is *not* configured, dm-integrity expects tags to arrive via `bio_integrity_payload` (bip) attached to the bio by dm-crypt. `dm_integrity_get_extra_data()` extracts the tag bytes from the bip's `bip_vec` scatter-gather list and copies them into the journal entry or dm-bufio tag buffer. dm-integrity is a passive relay in this path — it stores whatever bytes dm-crypt provides.

The `bio_integrity_payload` is the standard block layer carrier for per-sector integrity metadata. `bio_integrity_alloc()` allocates a bip and attaches it to the bio; `bio_integrity_add_page()` adds pages holding the tag bytes. dm-crypt uses this API to pass AEAD tags downward to dm-integrity without any custom side channel.

### Read path: internal hash verification

After the sector data arrives from the underlying device, `integrity_verify_tags()` runs. For each sector it:
1. Fetches the stored tag from the dm-bufio cache for the sector's tag area position.
2. Computes `crypto_shash_digest()` over the just-read sector data.
3. Compares the two tag values with `memcmp()`.
4. If they differ: sets the bio's error to `-EILSEQ`, which propagates to the filesystem as an I/O error.

The error is silent at the dm-integrity layer — no kernel log message by default. Userspace can detect integrity failures via `integritysetup status` which polls an error counter.

### Read path: external AEAD tags

When `internal_hash` is absent, `integrity_verify_tags()` does *not* verify anything itself. Instead, it fetches the stored tag bytes and attaches them to the bio via `bio_integrity_alloc()` + `bio_integrity_add_page()`, ready for dm-crypt to consume. dm-crypt's `crypt_endio()` calls `crypto_aead_decrypt()` which performs authenticated decryption — if the tag does not match, AEAD returns an error that propagates as `-EIO`.

### Tag area storage: dm-bufio

All tag sector reads and writes go through the `dm_bufio_client` opened over the tag area. `dm_bufio_read()` returns a locked buffer covering the tag sector; the tag bytes are read from or written to the buffer's data pointer. `dm_bufio_mark_buffer_dirty()` schedules a writeback. The LRU eviction policy means frequently accessed tag sectors (e.g., tags for a filesystem journal area) stay in memory. Cold sectors are fetched on demand, adding a small latency bump on the first write to a cold area.

## Key Data Structures

**`struct bio_integrity_payload`** (`include/linux/bio.h`) — block-layer container for per-sector integrity metadata:
- `bip_vec` — `struct bio_vec *` array of pages holding tag bytes
- `bip_sector` — starting sector for the tags
- `bip_vcnt` / `bip_max_vcnt` — vector count and capacity

## Key Functions / Entry Points

**`integrity_calculate_tags()`** (`dm-integrity.c`) — computes internal-hash tags for all sectors in a bio; called before writing to journal or permanent area.

**`integrity_verify_tags()`** — verifies internal-hash tags on read; sets bio error on mismatch; attaches stored tags to bip for AEAD mode.

**`dm_integrity_get_extra_data()`** — extracts AEAD tags from an inbound bio's `bio_integrity_payload`.

**`bio_integrity_alloc()`** (`block/bio-integrity.c`) — allocates and attaches a bip to a bio.

**`bio_integrity_add_page()`** — adds a page of tag data to a bip.

## Important Flags & Config Options

- `internal_hash:<alg>[:<key>]` — enables internal tag computation. Absence means AEAD/external tags.
- `fix_hmac` — corrects a historical HMAC key handling bug; enables secure per-sector HMAC when upgrading existing volumes.
- `tag_size` (format-time) — must be ≥ digest size of the hash algorithm.

## Interactions with Other Subsystems

- **→ [[kernel-crypto-api]]**: `crypto_shash_digest()` is the core call; algorithm selection delegated entirely to the Crypto API.
- **→ [[dm-bufio]]**: stored tag bytes live in bufio-managed buffers; all tag sector I/O goes through the bufio client.
- **← [[dm-crypt]]**: when dm-crypt is stacked above, it populates `bio_integrity_payload` with AEAD tags; dm-integrity stores and retrieves them as opaque bytes.
- **← [[dm-integrity-journal]]**: journal entries carry the tag alongside the sector data; the tag bytes are written by `integrity_calculate_tags()` or `dm_integrity_get_extra_data()` before the entry is committed.

## Design Decisions & Tradeoffs

The decision to accept external AEAD tags via the standard `bio_integrity_payload` API rather than a custom dm-integrity interface means dm-integrity and dm-crypt are loosely coupled — neither module has a direct call into the other. This allows both to be updated independently and avoids a compile-time circular dependency. The cost is a small indirection: dm-crypt must allocate bip structures even though the tags will ultimately live in dm-integrity's journal.

Using `memcmp()` for internal tag comparison (rather than a constant-time comparison) is intentional: the attacker's goal is to submit a wrong tag that passes verification, which requires guessing the hash output — a preimage problem with no timing oracle advantage.

## How It Has Evolved

- **4.12**: Internal-hash and external-AEAD paths both present from day one.
- Later: `fix_hmac` option added after a bug was found in how HMAC keys were handled for the per-sector HMAC; old volumes need to opt in to the fix to avoid breaking existing data.

## Further Reading

1. [Block layer data integrity — kernel.org](https://docs.kernel.org/block/data-integrity.html) — `bio_integrity_payload` API details
2. [dm-integrity — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html) — `internal_hash` parameter reference

## LKML Highlights

- **2017 (Milan Broz)**: AEAD integration design — chose `bio_integrity_payload` as the tag carrier rather than a new ioctl or DM message because the block integrity framework already provided the right abstraction and would work transparently across block layer boundaries including RAID stacks.
