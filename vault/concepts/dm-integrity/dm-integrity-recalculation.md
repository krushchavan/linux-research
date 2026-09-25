---
title: "dm-integrity Recalculation"
category: concept
tags: [dm-integrity, recalculation, background, block, device-mapper, initialization]
subsystem: dm-integrity
kernel_version: "5.7"
researched: 2026-04-18
status: complete
explained: "[[dm-integrity-recalculation-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html
  - https://www.mail-archive.com/dm-devel@lists.linux.dev/msg04481.html
  - https://man7.org/linux/man-pages/man8/integritysetup.8.html
---

# dm-integrity Recalculation

> 📘 Plain-language version: [[dm-integrity-recalculation-explained]]

## Purpose

Recalculation is the background process that initialises or repairs the integrity tag store for an entire volume. It is needed in three situations: when a freshly formatted device has no tags yet, when bitmap mode recovers after a crash (dirty regions need fresh tags), and when a volume's hash algorithm is being changed. Without recalculation, a newly formatted volume would return verification errors on every read until all sectors had been written at least once.

## Mental Model

Recalculation is a **background sweep**: a worker walks from `recalc_sector` to `provided_data_sectors`, reading each sector, computing its tag, and writing the tag to the tag area. The progress pointer is persisted in the superblock so the sweep can be interrupted and resumed across reboots without restarting from the beginning.

## How It Works

### Triggering recalculation

Recalculation is started when `integrity_ctr()` sees that `ic->recalc_sector < ic->provided_data_sectors`. This can happen because:
- A fresh `integritysetup format` sets `recalc_sector = 0` and the `recalculate` flag in the superblock.
- Bitmap mode detected dirty bits on mount, setting sectors to recalculate.
- An operator invoked `integritysetup set-recalc` to restart the sweep (e.g., after changing the hash algorithm).

If `recalc_sector == provided_data_sectors`, the device is fully initialised and recalculation is skipped.

### The recalculation worker

`integrity_recalc_work()` is a workqueue item that runs in the background. Each invocation processes a batch of sectors:

1. Reads `RECALC_SECTORS` sectors from `ic->dev` starting at `get_data_sector(ic->recalc_sector)`.
2. Calls `integrity_calculate_tags()` over the batch, computing fresh tags.
3. Writes the tags to the tag area via dm-bufio for each sector in the batch.
4. Flushes dm-bufio to ensure tags are durable.
5. Advances `ic->recalc_sector` by the batch size.
6. Calls `integrity_commit_superblock()` to persist the new `recalc_sector` to disk.
7. Re-queues itself to process the next batch.

If the machine crashes between steps 6 and 7 for the same batch, the next mount re-reads the last persisted `recalc_sector` from the superblock and resumes from there. A batch may be recalculated twice in this edge case (idempotent for internal hash, harmless).

### Concurrent I/O during recalculation

The device is available for normal I/O while recalculation is in progress. The I/O path tracks which sectors have been recalculated:
- Sectors with index < `recalc_sector`: tags exist and are verified on read.
- Sectors with index ≥ `recalc_sector`: tags may not exist yet; verification is skipped for these sectors to avoid spurious errors.

When the I/O path writes a sector in the not-yet-recalculated range, it writes the tag as usual — the write effectively advances the tag initialisation for that sector without waiting for the background worker to reach it.

### Security restriction for HMAC recalculation

By default, recalculation with HMAC keys is **disabled** even if `recalculate` is set. The rationale: if an attacker can reset `recalc_sector` to zero in the superblock, the kernel would re-sign all sectors with the HMAC key on the next mount — effectively endorsing any data the attacker may have tampered with. An operator must explicitly pass `recalculate_key` in the table line to permit HMAC recalculation. This option is absent from the default `integritysetup` invocation.

### Inline mode recalculation

In inline mode (`'I'`), the recalculation worker uses `integrity_recalc_inline_work()` instead, which handles the extended-sector layout where tags are embedded in the device's extra sector bytes rather than in a separate tag area.

## Key Data Structures

**`ic->recalc_sector`** (u64, in `dm_integrity_c`) — progress pointer; persisted in the superblock.

**`ic->recalc_work`** (`struct work_struct`) — the work item scheduled on the dm-integrity workqueue.

## Key Functions / Entry Points

**`integrity_recalc_work()`** (`dm-integrity.c`) — main recalculation worker: reads sectors, computes tags, advances `recalc_sector`, re-queues itself.

**`integrity_recalc_inline_work()`** — variant for inline mode devices.

**`integrity_commit_superblock()`** — persists `recalc_sector` to the on-disk superblock after each batch; uses a barrier write to guarantee ordering.

## Important Flags & Config Options

- `recalculate` — table line option that enables background recalculation; required for fresh devices.
- `recalculate_key` — permits HMAC re-signing; **opt-in only** for security reasons.
- `allow_discards` — when combined with `internal_hash`, discarded sectors receive the `hash(zeros)` tag, so they do not need recalculation — the discard itself counts as initialisation.

## Interactions with Other Subsystems

- **← [[dm-integrity-bitmap-mode]]**: bitmap mode triggers targeted recalculation of dirty regions on mount; the recalculation worker processes these regions.
- **← [[dm-integrity-device-config]]**: `recalc_sector` is stored in `dm_integrity_c` and updated by the worker; `integrity_commit_superblock()` flushes it.
- **→ [[dm-bufio]]**: tag writes during recalculation go through the bufio client, just like normal tag writes.
- **→ [[kernel-crypto-api]]**: `integrity_calculate_tags()` calls `crypto_shash_digest()` for each batch sector.

## Design Decisions & Tradeoffs

Persisting `recalc_sector` to the superblock after every batch (rather than only on clean shutdown) guarantees that no batch is ever recalculated more than twice. The trade-off is extra superblock writes — one per batch, typically every 64–256 sectors. On NVMe this is negligible; on high-latency storage (SAN, spinning disk) these writes can add up for large volumes.

The decision to allow concurrent I/O during recalculation (with verification skipped for unrecalculated sectors) allows the volume to be used immediately after formatting, at the cost of no integrity protection for unrecalculated sectors. An alternative design would hold off I/O until recalculation was complete — but this would make the first mount of a large volume unusable for potentially hours.

Disabling HMAC recalculation by default is a rare case where the kernel explicitly refuses to perform an operation that *could* be safe, because the consequences of the operation being triggered by an attacker are catastrophic (all integrity guarantees are silently voided). This is a defence-in-depth choice analogous to requiring explicit `--force` flags for destructive operations.

## How It Has Evolved

- **5.7**: `recalculate` and `recalculate_key` options introduced; prior to this, fresh devices needed to be initialised entirely from userspace before mounting.
- **6.11**: `integrity_recalc_inline_work()` added for inline mode devices.

## Further Reading

1. [dm-integrity — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html) — `recalculate` option documentation
2. [PATCH: dm-integrity recalculation in 'I' mode](https://www.mail-archive.com/dm-devel@lists.linux.dev/msg04481.html) — inline recalculation patch discussion

## LKML Highlights

- **2020 (Milan Broz / Mikulas Patocka)**: `recalculate_key` restriction discussion — the patch thread debated whether to allow HMAC recalculation by default; the decision to require explicit opt-in was driven by the active-attacker threat model where resetting `recalc_sector` would void all integrity guarantees without the user knowing.
