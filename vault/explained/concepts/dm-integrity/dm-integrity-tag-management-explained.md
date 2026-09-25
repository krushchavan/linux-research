---
title: "dm-integrity Tag Management — Explained"
category: explained
original: "[[dm-integrity-tag-management]]"
subsystem: dm-integrity
tags: [explained, dm-integrity, tags, aead, checksums]
converted: 2026-09-25
---

# dm-integrity tag management, explained

> Plain-language companion to [[dm-integrity-tag-management|the technical note]]. Same facts, fewer identifiers.

## The problem

dm-integrity's whole guarantee rests on per-sector **tags**, small checksums stored next to the data. But tags can come from two quite different places:
- dm-integrity can compute them itself, as a CRC or a keyed hash (HMAC) of each sector.
- dm-crypt, stacked on top in authenticated mode, produces them as part of encryption, using a key dm-integrity doesn't have.

The rest of dm-integrity (journal, bitmap, layout) shouldn't have to care which one is in use. And the two modules shouldn't need to call into each other directly.

## The idea in one paragraph

Put one layer in charge of tags that hides where they come from. With an internal hash, it computes tags on write and checks them on read. With external tags, it acts as a **passive courier**: it stores whatever bytes dm-crypt sends down attached to the write, and on read attaches the stored bytes to the request going back up so dm-crypt can do the checking. The tags travel through the block layer's standard way of carrying per-sector integrity data, so neither module calls the other.

## Step by step

### Step 1 (write, internal hash): compute the tag
Before anything reaches the journal or the data area, dm-integrity computes a hash over each sector's data. The hash output must fit in the tag size chosen at format time (extra bytes are zero-padded). For HMAC, the key is set once when the device is created and the same key is used for every sector. The sector number isn't mixed in automatically; the journal MAC is a separate option.

### Step 2 (write, external tags): take what dm-crypt sends
Without an internal hash, dm-integrity expects each write to arrive with tags already attached, as standard block-layer integrity data. It copies those bytes out and stores them. It doesn't interpret them at all.

### Step 3: Store the tag
Either way, the tag goes into the journal entry (journaled mode) or straight into the cached tag-area buffer for that sector (direct and bitmap modes).

### Step 4 (read, internal hash): verify
After the data arrives from disk, dm-integrity:
1. fetches the stored tag from the tag cache
2. recomputes the hash of the data it just read
3. compares the two
4. on a mismatch, fails the request, which reaches the filesystem as an I/O error

This is the key step for detecting silent corruption. There's no kernel log message by default; the setup tool can report an error counter.

### Step 5 (read, external tags): hand the tag back up
Without an internal hash, dm-integrity doesn't verify anything. It fetches the stored tag and attaches it to the read request. dm-crypt, above, performs authenticated decryption with it, and a mismatch becomes an I/O error there.

### Step 6: The tag cache
All tag sectors are read and written through a block cache (dm-bufio). Frequently touched tags, such as those covering a filesystem's journal, stay in memory. The first write to a cold region pays a small fetch.

### Step 7: Why a plain comparison is fine
The comparison isn't constant-time, and that's deliberate. Timing attacks help when an attacker can learn a secret bit by bit, but here the attacker would need to produce data whose hash matches, which is a preimage problem that timing doesn't help with.

## The picture

```text
                 INTERNAL HASH                        EXTERNAL TAGS (dm-crypt above)
 write:  data ─▶ hash ─▶ tag ─▶ store         dm-crypt attaches tag ─▶ store as-is
 read:   data + stored tag                    stored tag ─▶ attach to request
           │ recompute hash, compare                  │
           ▼                                          ▼
       match → data │ mismatch → I/O error     dm-crypt decrypts & checks
                                                mismatch → I/O error

 storage for both:  journal entry  or  tag area (via tag cache)
```

## Tradeoffs

- **What it gives you:** one tag layer for both CRC/HMAC and authenticated-encryption tags, with dm-integrity and dm-crypt loosely coupled through a standard block-layer mechanism. They can change independently and there's no circular dependency, and it works across other block layers such as RAID.
- **What it costs / requires:** dm-crypt has to wrap its tags in block-layer integrity structures even though they'll end up in dm-integrity's storage.
- **Where it bites:** tag failures are quiet by default (no log line), so they must be monitored. A historical bug in HMAC key handling means older volumes need an explicit opt-in fix, since changing behaviour silently would break existing data.

## How it got here

- **4.12 (2017):** both the internal-hash and external-tag paths present from the start. Milan Broz chose the block layer's integrity mechanism as the carrier instead of a new ioctl or message.
- **Later:** an opt-in fix for HMAC key handling on existing volumes.

## Related

- Technical version: [[dm-integrity-tag-management]]
- [[dm-integrity-explained|dm-integrity]]: the subsystem overview
- [[dm-crypt-explained|dm-crypt]]: the source of external tags
- [[dm-crypt-crypto-api-integration-explained|dm-crypt's authenticated mode]]
- [[dm-integrity-journal-explained|The journal]]: where tags are stored in journaled mode
- [[dm-bufio-explained|dm-bufio]], [[kernel-crypto-api-explained|Kernel crypto API]]
