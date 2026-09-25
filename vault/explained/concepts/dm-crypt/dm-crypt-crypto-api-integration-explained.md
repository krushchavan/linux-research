---
title: "dm-crypt Crypto API Integration — Explained"
category: explained
original: "[[dm-crypt-crypto-api-integration]]"
subsystem: dm-crypt
tags: [explained, dm-crypt, crypto-api, aead]
converted: 2026-09-25
---

# How dm-crypt uses the kernel crypto API, explained

> Plain-language companion to [[dm-crypt-crypto-api-integration|the technical note]]. Same facts, fewer identifiers.

## The problem

dm-crypt has to encrypt every sector as fast as the hardware allows, on x86 with AES instructions, on ARM with its crypto extensions, and on machines with dedicated crypto offload cards. Writing and tuning cipher code for each of those inside dm-crypt would be a maintenance nightmare.

There is a second problem too. Ordinary disk encryption hides data but doesn't *protect* it: someone with write access to the disk can flip bits in the ciphertext, and the decrypted data changes in predictable, exploitable ways without anyone noticing. Detecting that needs authentication tags, which don't fit in a fixed-size sector.

## The idea in one paragraph

dm-crypt contains no cipher code at all. It asks the kernel's crypto API, a **plug-in registry of cipher implementations**, for an algorithm by name ("xts(aes)"), and gets back the best one registered for this machine. dm-crypt's job is to allocate and key those ciphers, turn each sector of an I/O request into a crypto request, and handle the answer, whether it comes back instantly or later. For tamper detection, it switches to authenticated ciphers and hands the resulting tags to dm-integrity to store.

## Step by step

### Step 1: Pick the kind of cipher
Two interfaces are used, chosen by the cipher specification:
- **Length-preserving ciphers** (CBC, XTS, LRW): n bytes in, exactly n bytes out. That's a must for block devices, where a sector's size can't change.
- **Authenticated ciphers** (AEAD: GCM, ChaCha20-Poly1305, or XTS combined with an HMAC): ciphertext *plus* a tag, a short checksum keyed by the secret that detects any tampering.

### Step 2: Let the registry choose the implementation
dm-crypt asks for an algorithm by name. The registry picks the highest-priority registered implementation. On x86 with AES-NI, "xts(aes)" becomes the hardware-accelerated version; on ARM with crypto extensions, the ARM-specific one; otherwise generic software. dm-crypt allows asynchronous implementations too, which mainly matters for dedicated crypto accelerator cards.

### Step 3: One keyed cipher per CPU
One cipher instance is allocated for every CPU, and the key is loaded into each. Loading the key computes the AES **key schedule**, the expanded round keys (10, 12 or 14 rounds for 128-, 192- or 256-bit AES), once, so each encryption doesn't redo it. For XTS, the full 64-byte key goes in and the XTS code splits it into its data key and tweak key.

### Step 4: Build a request per sector
For each sector, dm-crypt fills in a crypto request: which CPU's cipher, the input pages, the output pages, the sector length, the IV, and a callback for asynchronous completion. The request storage lives inside the per-request tracking object, so no extra allocation is needed.

- **Writes** encrypt into a separate spare page, because many cipher implementations can't safely encrypt in place.
- **Reads** decrypt in place, into the same page, which most implementations allow. That saves an allocation per sector.

### Step 5: Handle the answer
The cipher either:
- **finishes immediately**, and the result is ready now
- **accepts the job for later**, and calls back when done
- **reports its queue full**, in which case the request is still accepted into a backlog

This is the key insight. With AES-NI the answer is *always* "finished immediately": the cipher runs on the current CPU with SIMD instructions, with no interrupt or callback. That is why skipping dm-crypt's workqueues helps so much on such machines: the queueing was built for asynchronous work that never happens there. Offload cards (Intel QuickAssist, Marvell CESA) really do answer later, and their callback continues with the next sector.

### Step 6: Authenticated mode with dm-integrity
With an authenticated cipher, each sector's encryption also produces a tag, typically 16 bytes. The tags can't go inside the sector, because that would change the device's apparent size. Instead dm-crypt attaches them to the I/O request as integrity data, and dm-integrity, stacked *below* dm-crypt, stores them in its own area on disk.

On a read, if the tag doesn't match, decryption reports a bad message and the read fails with an I/O error. The filesystem sees an error instead of silently corrupted plaintext.

## The picture

```text
 dm-crypt: "give me xts(aes)"
      │
      ▼
 ┌──────── crypto API registry ─────────┐
 │  xts(aes-aesni)   priority high   ◀── chosen on x86 with AES-NI
 │  xts(aes-ce)      (ARM)                │
 │  xts(aes-generic) priority low         │
 └──────────────────────────────────────┘
      │ one keyed instance per CPU
      ▼
 per sector: request {input pages, output pages, length, IV, callback}
      │
      ├── instant (AES-NI): result ready now
      └── later (offload card): callback → next sector

 authenticated mode:  ciphertext ─▶ disk data area
                      tag ────────▶ dm-integrity (separate area)
                      read: tag mismatch → I/O error
```

## Tradeoffs

- **What it gives you:** automatic use of the best hardware acceleration on every platform, with no cipher code in dm-crypt; optional tamper detection.
- **What it costs / requires:** dm-crypt can't fine-tune for specific hardware and must trust the registry's priorities. Per-CPU instances cost memory (AES-256's expanded key alone is 240 bytes per instance), traded for zero lock contention. Encrypting writes needs a spare page per sector.
- **Where it bites:** without authenticated mode, dm-crypt gives confidentiality only; ciphertext bit-flips go undetected. Authenticated mode needs dm-integrity underneath, with its extra I/O.

## How it got here

- **2003:** an old cipher interface with a single shared instance.
- **2.6.x:** moved to a newer block-cipher interface.
- **4.x:** moved to the current length-preserving cipher interface, with per-CPU instances.
- **4.12:** authenticated cipher support.
- **5.9:** Cloudflare's inline path made clear that AES-NI is always synchronous, so queueing is pure overhead there.

## Related

- Technical version: [[dm-crypt-crypto-api-integration]]
- [[dm-crypt-explained|dm-crypt]]: the subsystem overview
- [[dm-crypt-crypt-config-explained|Per-device encryption state]]: holds the per-CPU ciphers
- [[dm-crypt-crypt-io-explained|Per-request context]]: builds and submits the requests
- [[dm-crypt-iv-generation]]: supplies each sector's IV
- [[kernel-crypto-api|Kernel crypto API]], [[dm-integrity]]
