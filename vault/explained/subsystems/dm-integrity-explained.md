---
title: "dm-integrity — Explained"
category: explained
original: "[[dm-integrity]]"
subsystem: dm-integrity
tags: [explained, dm-integrity, device-mapper, checksums, journal]
converted: 2026-09-25
---

# dm-integrity, explained

> Plain-language companion to [[dm-integrity|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Disks sometimes return data that is silently wrong: a flipped bit, a misdirected write, or, with an attacker who has physical access, deliberately altered data. Most filesystems never notice; they hand back whatever the disk says.

The fix sounds simple: store a checksum (a **tag**) for every sector and check it on every read. The hard part is keeping the data and its tag **in step across a crash**. If power fails after the data is written but before its tag is, the next read sees a mismatch and reports corruption that never happened. And, unlike dm-verity, this has to work on a *writable* device.

dm-integrity is a device-mapper target that does exactly this. It is also the required storage underneath dm-crypt's authenticated mode: dm-crypt produces a tag per sector, and dm-integrity stores it.

## The big picture

Think of dm-integrity as **a checksum ledger** between the filesystem and the disk. Every sector (512 bytes or larger) is paired with a small tag: a CRC, an HMAC (a keyed hash) or an authentication code from dm-crypt. On write, the tag is computed and the pair is committed together. On read, the tag is checked and a mismatch returns an I/O error instead of bad data. A journal (or cheaper alternatives) makes sure the ledger entry and the data are never left half-written.

```text
 integritysetup / dmsetup ──▶ table: mode + hash
                                 │
 write ──▶ dm-integrity ─── mode? ─┬─ Journaled: data+tag to journal, commit,
                                   │               then copy to final place
                                   ├─ Direct:    data and tag written separately
                                   ├─ Bitmap:    mark region dirty, write, clear
                                   └─ Inline:    tag in the disk's extra per-sector space
                                 │
                        tag cache (dm-bufio) ──▶ disk
 read  ──▶ data + tag ──▶ recompute & compare ──▶ ok, or I/O error
```

## The pieces

### Per-device configuration

One object per device holds its mode, hash functions, journal settings, bitmap and buffers. See [[dm-integrity-device-config-explained|dm-integrity-device-config]].

1. At setup, the table names the backing device, how many sectors are reserved at the front, the tag size, and options.
2. From the tag size and block size, dm-integrity works out the layout: how many data sectors per chunk, how much tag space, how big the journal is.
3. If an internal hash is named (for example CRC32C or HMAC-SHA256), it's allocated for computing tags on write and checking them on read. Optional ciphers can encrypt and authenticate the journal itself, so journal entries don't reveal which sectors were written.
4. A tag cache (dm-bufio) is opened over the tag area, so hot tags stay in memory.

### On-disk layout

Everything is at fixed, computable positions. See [[dm-integrity-on-disk-layout-explained|dm-integrity-on-disk-layout]].

1. The order is: reserved sectors, a 4 KiB **superblock**, the **journal**, then **data and tags interleaved**.
2. The superblock holds a magic string, format version, chunk size (as a power of two), tag size, journal size and usable data size.
3. The data area alternates a run of tags with the chunk of data sectors those tags cover. Because chunk size is a power of two, finding any sector's tag is a shift and an add. No lookup table needed.
4. Chunk size (default 32,768 sectors) and block size are fixed when the device is formatted.

### The journal

The journal gives atomicity: a sector's data and tag are both updated, or neither. See [[dm-integrity-journal-explained|dm-integrity-journal]].

1. In journaled mode, a write goes first into a journal section: data plus tag, with the destination sector.
2. The section is **committed**: every sector in it is stamped with the same commit ID, written with a barrier so it's really on disk.
3. Only then is the data copied to its permanent place and the tag to the tag area.
4. After a crash, each journal section is checked. A section is replayed only if *all* its sectors carry the same commit ID. A half-written section has mismatched IDs and is skipped. Replay finishes before the device accepts I/O.
5. Flushing to the permanent area starts when the journal is half full (by default) or every 250 ms, bounding how much can be lost.
6. A journal MAC (keyed hash over each entry's sector number) stops an attacker from moving journal entries to different sectors.

### Bitmap mode

A faster alternative when doubling every write is too expensive. See [[dm-integrity-bitmap-mode-explained|dm-integrity-bitmap-mode]].

1. Before writing, the bit for that region is set in a dirty bitmap. Data and tag are written directly. After the write is flushed, the bit is cleared.
2. After a crash, every region with a dirty bit is **recalculated**: read the data, recompute the tag, write it.
3. This only works with an internal hash, because then the tag can always be recomputed from the data. It can't be used with dm-crypt's tags, which need the key and the plaintext.
4. The bitmap itself is flushed every 10 seconds by default. A crash before that can miss a dirty mark, so a lower interval is safer but costs more metadata writes.

### Tag management

This layer hides where tags come from. See [[dm-integrity-tag-management-explained|dm-integrity-tag-management]].

1. **Internal hash:** on write, a hash of each sector is computed and stored; on read, recomputed and compared. Mismatch is an error.
2. **External tags from dm-crypt:** tags arrive attached to the I/O request as integrity data, and dm-integrity stores them. On read, it attaches the stored tag, and dm-crypt's authenticated decryption does the checking.
3. Tags live in the cache, so frequently written sectors' tags stay hot. The first write to a cold region pays a fetch.

### Recalculation

A background pass that builds or repairs tags for the whole volume: after formatting, after a bitmap-mode crash, or after changing the hash. See [[dm-integrity-recalculation-explained|dm-integrity-recalculation]].

1. The superblock records how far recalculation has got. At startup, if it isn't finished, a background worker resumes from there.
2. The worker reads a batch, computes and writes tags, advances the marker and saves the superblock. A crash resumes from the last saved position.
3. The device stays usable: sectors already done are verified; sectors not yet reached skip verification.
4. With keyed hashes (HMAC), recalculation is **off by default**. If an attacker could reset the marker to zero, the kernel would re-sign tampered data with the key. It needs an explicit opt-in.

## A request's journey

A write in journaled mode with an internal hash, then a read:

1. **Write arrives.** The filesystem submits a write; device mapper hands it to dm-integrity.
2. **Compute tags.** A tag (CRC or HMAC) is computed for each sector.
3. **Journal it.** Data and tags go into the current journal section.
4. **Commit.** When the section fills or the timer fires, every sector of the section is stamped with the commit ID and written with a barrier. The write completes to the filesystem only now.
5. **Copy home in the background.** A worker copies data to its permanent place and updates the tag in the cache, which writes it back.
6. **Read later.** The data is read from disk, its tag fetched from the cache, the hash recomputed and compared. A match returns data; a mismatch returns an I/O error.

With dm-crypt stacked on top in authenticated mode, dm-crypt makes the tag in step 2 and checks it after step 6; dm-integrity just stores and fetches it.

## Tradeoffs

- **What it gives you:** silent-corruption (and, with keyed tags, tamper) detection for any filesystem, on a writable device, with crash-consistent data and tags.
- **What it costs / requires:** journaled mode writes everything twice, halving write throughput. Tag space scales with the device: a 4-byte CRC per 512-byte sector is about 0.8% overhead; a 32-byte HMAC is about 6.3%.
- **Where it bites:** direct mode skips the journal and can leave data and tag mismatched after a crash, so it's only right when the layer above tolerates that. Bitmap mode can't be used with dm-crypt's tags. Filesystems with built-in checksums (btrfs) may do better, since they protect only real data rather than every sector including free space.

## How it got here

- **4.12 (2017):** introduced by Milan Broz with direct and journaled modes, enabling dm-crypt's authenticated encryption. dm-crypt was kept separate, sitting above.
- **4.18 (2018):** bitmap mode, argued by Mikulas Patocka on the grounds that recomputable internal-hash tags make journaling unnecessary.
- **5.2–5.13:** discard support, background recalculation (with opt-in for keyed hashes), tag padding fixes, and better recalculation alongside live I/O.
- **6.11 (2024):** inline mode, storing tags in the extra per-sector space some disks provide (for example 520-byte sectors), with zero overhead in the data area.
- **Ongoing:** inline mode with hardware protection-information sectors, tag-cache tuning, and stacking under dm-raid.

## Related

- Technical version: [[dm-integrity]]
- [[device-mapper-explained|Device mapper]]: the framework
- [[dm-crypt-explained|dm-crypt]]: supplies tags in authenticated mode
- [[dm-bufio-explained|dm-bufio]]: the tag cache
- [[dm-integrity-device-config-explained|dm-integrity-device-config]], [[dm-integrity-on-disk-layout-explained|dm-integrity-on-disk-layout]], [[dm-integrity-journal-explained|dm-integrity-journal]], [[dm-integrity-bitmap-mode-explained|dm-integrity-bitmap-mode]], [[dm-integrity-tag-management-explained|dm-integrity-tag-management]], [[dm-integrity-recalculation-explained|dm-integrity-recalculation]]
- [[kernel-crypto-api-explained|Kernel crypto API]], [[checksumming-and-data-integrity-explained|btrfs checksumming]]
