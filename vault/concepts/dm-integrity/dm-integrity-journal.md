---
title: "dm-integrity Journal"
category: concept
tags: [dm-integrity, journaling, block, device-mapper, atomicity, crash-consistency]
subsystem: dm-integrity
kernel_version: "4.12"
researched: 2026-04-18
status: complete
explained: "[[dm-integrity-journal-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html
  - https://www.kernel.org/doc/Documentation/device-mapper/dm-integrity.txt
  - https://lwn.net/Articles/517381/
---

# dm-integrity Journal

> 📘 Plain-language version: [[dm-integrity-journal-explained]]

## Purpose

The journal provides the atomicity guarantee for the journaled write mode (`'J'`): when a sector is updated, either both the data and its integrity tag reach their permanent location on disk, or neither does. Without a journal, a crash between the data write and the tag write would leave the device with a valid sector paired with a stale tag, and the next read would return `-EIO` for perfectly good data.

## Mental Model

The journal is a **write-ahead log** at the block level. Before any data reaches its permanent location, it is written to the journal with a commit record. A background worker then copies committed entries to the permanent data and tag areas. This is the same pattern as a filesystem's data journal — the integrity journal just operates one level lower.

## How It Works

### Journaling a write

When a bio arrives in journaled mode, `integrity_map()` does not immediately write to the permanent data area. Instead, the write is placed into the current **journal section** — a fixed-size area that can hold a bounded number of sector writes before it must be committed and flushed.

Each journal section is divided into a **metadata area** (4 KiB) and a **data area**. The metadata area contains one entry per sector being journaled. Each entry holds:
- `u64 logical_sector` — the permanent destination sector on the device
- `u8[8] last_bytes` — the last 8 bytes of the sector's content (the remainder lives in the data area)
- `u8[tag_size] integrity_tag` — the computed or supplied tag for this sector

The "last bytes in metadata" trick is a space-packing optimisation: a standard 512-byte sector can't entirely fit alongside its sector number and tag in a 4-KiB metadata entry. The last 8 bytes are pulled into the metadata entry; the remaining 504 bytes go into the data area. On replay, both pieces are recombined.

### Committing a section

When the section fills or `commit_time` milliseconds elapse or the `journal_watermark` percentage is reached, `integrity_commit()` is called. It writes the current **commit ID** (a per-section monotonically increasing u64) into the last 8 bytes of every 512-byte word of the journal section. This overwrites the space that previously held `last_bytes` data entries — those have already been captured in the metadata entries. After the commit ID write, a **barrier flush** ensures the entire section (including the commit IDs) is durable before the function returns.

The commit ID check is the crash detection mechanism: if the system crashes during a commit write, at least one sector in the section will have a mismatched or stale commit ID. `integrity_journal_replay()` reads every section and checks that all sectors have the same commit ID; partial sections are silently discarded.

### Flushing to permanent locations

After a section is committed, a background **flush worker** (`integrity_flush_data_work`) copies entries from the committed sections to their permanent locations:
1. For each journal entry: submit a bio to write the sector data (504 + 8 reassembled bytes) to `get_data_sector(logical_sector)`.
2. Write the integrity tag via dm-bufio to the tag area for `logical_sector`.
3. Flush dm-bufio to ensure tag writes reach disk.
4. Mark the journal section as free for reuse.

### Journal sections and watermark

Multiple journal sections allow batching: while section N is being flushed, section N+1 can accept new writes. The `journal_watermark` parameter (default 50%) starts the flush when that fraction of sections are full. The `commit_time` (default 250 ms) commits the current section even when it is not full — bounding the latency for small-write workloads.

### Journal protection

If `journal_crypt` is specified, journal entries are encrypted with a stream cipher before being written to disk, so an attacker with disk read access cannot determine which sectors were recently written. If `journal_mac` is specified, an HMAC over the sector number is included in each journal entry; a replay attack that moves a valid entry to a different sector number will fail the HMAC check during `integrity_journal_replay()`.

## Key Data Structures

**Journal entry** (within metadata area, `dm-integrity.c`):
- `u64 logical_sector` — destination sector (packed with tag size in lower bits)
- `u8 last_bytes[8]` — last 8 bytes of sector data
- `u8 tag[tag_size]` — integrity tag

**`struct journal_sector`** — on-disk 512-byte layout; last 8 bytes are the commit ID after commit.

## Key Functions / Entry Points

**`integrity_commit()`** (`dm-integrity.c`) — stamps all sectors in the current section with the commit ID and issues a barrier write. Called when the section is full, on `commit_time` expiry, or on `fsync`.

**`integrity_journal_replay()`** — scans all journal sections on device open; replays valid committed sections to their permanent locations.

**`integrity_flush_data()`** — copies committed journal entries to permanent data area and tag area; runs as a background workqueue job.

**`integrity_workqueue_fn()`** — background timer / workqueue handler that periodically invokes `integrity_commit()` based on `commit_time`.

## Important Flags & Config Options

- `journal_sectors` — total journal size in sectors; set at format time. Larger values allow higher burst write throughput before the flush must catch up.
- `journal_watermark` (default 50%) — fraction of journal used before flush starts. Lower values reduce peak write latency at the cost of more frequent flush I/O.
- `commit_time` (default 250 ms) — maximum delay before an uncommitted section is committed. Lower values reduce data loss window.
- `journal_crypt:<alg>` — stream cipher for journal entry encryption.
- `journal_mac:<alg>:<key>` — HMAC for sector number in each entry (anti-relocation).

## Interactions with Other Subsystems

- **→ [[dm-bufio]]**: tag writes during flush go through the bufio cache client.
- **← [[dm-integrity-bitmap-mode]]**: bitmap mode exists precisely to avoid the journal's write amplification; the two modes are mutually exclusive.
- **← [[dm-integrity-device-config]]**: `dm_integrity_c` holds `journal_sections`, `commit_time`, `journal_watermark`, and the commit ID array.

## Design Decisions & Tradeoffs

The journal halves write throughput — every sector is written twice (once to the journal, once to the permanent location). This is the standard journaling trade-off, accepted because the alternative (direct writes with no atomicity) risks silent data-tag mismatches after a crash. The tradeoff is mitigated in practice by the background flush running asynchronously, so write latency is bounded by the journal commit (one flush) rather than two sequential flushes.

Storing only the last 8 bytes of each sector in the metadata entry, rather than the full 512 bytes, is a deliberate density optimisation: it packs more entries into the 4-KiB metadata area, reducing the journal's sector footprint at the cost of requiring two reads during replay (metadata area + data area).

## How It Has Evolved

- **4.12**: Initial journal design with commit ID validation.
- Later: `journal_mac` added to prevent relocation attacks on journal entries — a previously overlooked active attack vector.
- **4.18**: Bitmap mode added as a lower-overhead alternative, reducing the use cases for the journal to situations requiring strict atomicity guarantees.

## Further Reading

1. [dm-integrity — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html) — journal parameters section
2. [dm-integrity: integrity protection — LWN (2012)](https://lwn.net/Articles/517381/) — design rationale discussion

## LKML Highlights

- **2017 (Milan Broz)**: Journal commit ID design — chose per-section monotonic IDs over per-entry sequence numbers to allow bulk validation with a single sequential scan per section, avoiding the need for an in-memory log replay index.
