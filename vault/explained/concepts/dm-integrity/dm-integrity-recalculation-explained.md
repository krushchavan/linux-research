---
title: "dm-integrity Recalculation — Explained"
category: explained
original: "[[dm-integrity-recalculation]]"
subsystem: dm-integrity
tags: [explained, dm-integrity, recalculation, background-work]
converted: 2026-09-25
---

# dm-integrity recalculation, explained

> Plain-language companion to [[dm-integrity-recalculation|the technical note]]. Same facts, fewer identifiers.

## The problem

A freshly formatted dm-integrity device has no valid tags. Every read would fail verification until each sector had been written at least once. The same gap appears after a bitmap-mode crash (dirty regions have suspect tags) and when a volume switches to a different hash algorithm.

Computing tags for a whole large volume takes a long time, potentially hours. Nobody wants to wait that long before the volume can be used, or start over from the beginning after a reboot halfway through.

## The idea in one paragraph

A **background sweep** walks the volume from start to end, reading each batch of sectors, computing their tags and writing them. A progress marker saved in the superblock after every batch lets the sweep survive reboots and resume where it stopped. Meanwhile the device is fully usable: sectors the sweep has passed are verified, and sectors it hasn't reached yet simply skip verification.

## Step by step

### Step 1: Decide whether a sweep is needed
At startup, dm-integrity compares the saved progress marker with the volume's size. If the marker hasn't reached the end, a sweep is scheduled. That happens when:
- a new device has just been formatted (marker at zero)
- bitmap mode found dirty regions after a crash
- an operator restarted the sweep, for example after changing the hash

If the marker is at the end, the volume is fully initialised and nothing happens.

### Step 2: Process one batch
The background worker:
1. reads a batch of sectors starting at the marker
2. computes a fresh tag for each
3. writes the tags through the tag cache
4. flushes the cache so the tags are really on disk
5. advances the marker by the batch size
6. saves the marker in the superblock with a barrier write
7. queues itself again for the next batch

### Step 3: Survive a crash
If the machine crashes, the next startup reads the last saved marker and resumes there. At worst, one batch gets recalculated twice, which is harmless because recomputing a hash gives the same answer. Saving after every batch costs one superblock write per batch (typically every 64–256 sectors): negligible on NVMe, noticeable over a large volume on slow storage.

### Step 4: Keep the device usable meanwhile
This is the key design choice. The device accepts normal I/O throughout:
- **Behind the marker**, tags are known good and every read is verified.
- **Ahead of the marker**, tags may not exist yet, so verification is skipped to avoid false errors.

A normal write ahead of the marker writes its tag as usual, which initialises that sector early. The cost is that sectors not yet reached have no integrity protection until the sweep gets there. The alternative, blocking I/O until the sweep finished, could leave a big new volume unusable for hours.

### Step 5: Refuse to re-sign keyed tags by default
If tags are keyed hashes (HMAC), recalculation is **disabled** unless explicitly allowed with a separate option, which the standard setup tool doesn't pass.

The reasoning: an attacker who could reset the marker to zero in the superblock would get the kernel to re-sign *every* sector with the secret key at the next startup, blessing whatever tampering they had done. All integrity guarantees would vanish silently. It is a rare case of the kernel refusing something that is usually safe, because misuse would be catastrophic.

### Step 6: Shortcuts and variants
- If discards are allowed, a discarded sector is known to be zeros, so its tag is set to the hash of zeros. The discard counts as initialisation.
- Inline mode, where tags live in the disk's extra per-sector space, uses its own variant of the worker.

## The picture

```text
 volume:  [ verified ✓✓✓✓✓✓✓ | ▶ marker | not yet reached · · · · · · ]
                                  │
       background worker: read batch → compute tags → write tags → flush
                          → advance marker → save superblock → repeat
                                  │
 crash? restart from last saved marker (≤ one batch redone)

 reads behind marker: verified       reads ahead of marker: not verified
 writes anywhere: tag written normally
```

## Tradeoffs

- **What it gives you:** a volume usable immediately after formatting, with tag initialisation that resumes across reboots.
- **What it costs / requires:** one superblock write per batch, and no integrity protection for sectors the sweep hasn't reached yet.
- **Where it bites:** until the sweep finishes, corruption in not-yet-reached sectors goes undetected. With keyed tags, recalculation needs an explicit opt-in, and turning it on reopens the "re-sign tampered data" risk.

## How it got here

- **5.7 (2020):** background recalculation and the separate opt-in for keyed hashes. Before this, a new device had to be initialised entirely from user space before use. The opt-in was debated on the list and driven by the active-attacker threat model.
- **6.11 (2024):** a variant of the worker for inline mode.

## Related

- Technical version: [[dm-integrity-recalculation]]
- [[dm-integrity-explained|dm-integrity]]: the subsystem overview
- [[dm-integrity-bitmap-mode-explained|Bitmap mode]]: triggers recalculation of dirty regions
- [[dm-integrity-device-config-explained|Device configuration]]: holds the progress marker
- [[dm-integrity-on-disk-layout-explained|On-disk layout]]: the superblock that stores it
- [[dm-bufio-explained|dm-bufio]], [[kernel-crypto-api-explained|Kernel crypto API]]
