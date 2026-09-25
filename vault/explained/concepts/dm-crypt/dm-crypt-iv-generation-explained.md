---
title: "dm-crypt IV Generation — Explained"
category: explained
original: "[[dm-crypt-iv-generation]]"
subsystem: dm-crypt
tags: [explained, dm-crypt, iv, xts, essiv]
converted: 2026-09-25
---

# dm-crypt IV generation, explained

> Plain-language companion to [[dm-crypt-iv-generation|the technical note]]. Same facts, fewer identifiers.

## The problem

If a disk's encryption turns the same plaintext into the same ciphertext wherever it appears, an attacker learns something without ever knowing the key: "sector 100 and sector 9000 hold identical data", or "this sector hasn't changed since last week". The standard fix is an **initialization vector** (IV): an extra input to the cipher that makes identical plaintext encrypt differently in different contexts.

For disk encryption, the IV has awkward constraints:
- It can't be random and stored next to the data. That would need space per sector and an extra read before every decryption, breaking the fixed-size sector a block device promises.
- It must be computable from the sector's position alone, so any sector can be read without touching its neighbours.
- For some cipher modes, it must also be **unpredictable without the key**, or an attacker who can choose what gets written can mount attacks.

## The idea in one paragraph

Derive each sector's IV from its sector number. That number is a natural "disambiguator": the attacker knows it exists but can't control it. Different schemes differ in how much work they do on it: pass it through as is (fine with XTS mode, which scrambles it internally), or encrypt it under a key derived from the master key (needed for the older CBC mode). The scheme is a small plug-in chosen by name in the cipher specification, such as "plain64" in "aes-xts-plain64".

## Step by step

### Step 1: Pick the scheme when the device is set up
The IV name in the cipher string selects a small set of functions: set up, initialise after the key is loaded, wipe on key wipe, generate an IV for a sector, and tear down.

### Step 2: Generate an IV before every sector
During I/O, just before each sector is encrypted or decrypted, the chosen generator fills in the IV for that sector number. The number includes an optional offset from the table, so an encrypted volume that starts partway into a disk doesn't produce the same IVs as a neighbouring volume.

### Step 3: plain64: the sector number itself
The simplest scheme writes the 64-bit sector number into the IV. That's the whole thing, with no cryptographic work at all. It is correct with XTS, but **not safe with CBC**: a predictable IV lets an attacker who can choose plaintexts mount a "watermarking" attack, planting data whose encrypted pattern is recognisable.

### Step 4: ESSIV: an IV you can't predict without the key
ESSIV was the standard safe choice for CBC before XTS existed. After the master key is loaded, it hashes the key (typically with SHA-256) to make a second key, and loads that into a separate AES cipher. Each sector's IV is then that sector number encrypted with the second key. Without the master key, the IVs look random, which defeats watermarking. The cost is one extra AES block encryption per sector, about a nanosecond with AES-NI, but strictly more work than plain64. Its specification looks like "aes-cbc-essiv:sha256"; the hash is only used once, at setup.

### Step 5: TCW: TrueCrypt compatibility
This scheme reproduces TrueCrypt's per-sector "whitening", mixing a value derived from the sector number and a second key into the data before CBC encryption and after decryption. It exists to open TrueCrypt volumes and is rarely used otherwise.

### Step 6: Why XTS makes it easy
This is the key insight. XTS mode has a built-in **tweak**: it encrypts the sector number with its own second key internally and mixes the result into every block. So with XTS, "plain64" doesn't really compute an IV; it passes the sector number through, and XTS does the unpredictable part itself. The name "plain64" is a bit misleading here.

### Step 7: Larger encryption sectors
If the encryption unit is set to 4096 bytes (to match the filesystem block size), the IV counts in 4096-byte blocks instead of 512-byte sectors. Each IV covers 4096 bytes.

## The picture

```text
 sector number ──(+ offset)──┐
                             ▼
   plain64:   IV = sector number                         (no work)
   ESSIV:     IV = AES( hash(master key), sector number ) (1 extra AES block)
   TCW:       whitening for TrueCrypt volumes

 XTS mode:  sector number ─▶ XTS encrypts it with its own 2nd key (tweak)
            ─▶ every 16-byte block of the sector is mixed with the tweak
            → identical data in different sectors encrypts differently
```

## Tradeoffs

- **What it gives you:** per-sector uniqueness without storing anything extra on disk, and random access to any sector.
- **What it costs / requires:** ESSIV adds an encryption per sector; plain64 costs nothing but depends on XTS to be safe.
- **Where it bites:** pairing a predictable IV (plain64) with CBC mode is unsafe. CBC also chains blocks inside a sector, so decryption within a sector is sequential; XTS can process a sector's blocks in parallel. XTS was standardised (IEEE P1619) specifically for disk encryption.

## How it got here

- **2003:** only 32-bit and 64-bit sector-number IVs, with CBC mode assumed.
- **2.6.10 (2004):** ESSIV added to stop watermarking attacks on CBC.
- **2.6.20 (2007):** LRW mode.
- **2.6.24 (2008):** XTS mode. plain64 becomes the correct pairing, and new LUKS setups move away from CBC with ESSIV.
- **Today:** AES-256-XTS with plain64 is the LUKS2 default; ESSIV and CBC are legacy.

## Related

- Technical version: [[dm-crypt-iv-generation]]
- [[dm-crypt-explained|dm-crypt]]: the subsystem overview
- [[dm-crypt-crypt-config-explained|Per-device encryption state]]: stores the chosen scheme and its state
- [[dm-crypt-crypt-io-explained|Per-request context]]: calls the generator before each sector
- [[dm-crypt-crypto-api-integration-explained|Crypto API integration]], [[kernel-crypto-api|Kernel crypto API]]
