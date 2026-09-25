---
title: "dm-crypt IV Generation — Sector Initialization Vectors"
category: concept
tags: [dm-crypt, encryption, iv, essiv, xts, block]
subsystem: dm-crypt
kernel_version: "2.5"
researched: 2026-04-18
status: complete
explained: "[[dm-crypt-iv-generation-explained]]"
sources:
  - https://kernel-internals.org/security/dm-crypt/
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html
  - https://en.wikipedia.org/wiki/Disk_encryption_theory
---

# dm-crypt IV Generation — Sector Initialization Vectors

> 📘 Plain-language version: [[dm-crypt-iv-generation-explained]]

## Purpose

Disk encryption must produce distinct ciphertexts for identical plaintext sectors located at different positions on disk. If two sectors contain the same plaintext and are encrypted with the same IV, an attacker can detect this identity — even without knowing the key. The IV generation component derives a unique initialization vector for each sector from its logical sector number, ensuring that even repeated writes of the same data to the same sector produce ciphertext that reveals nothing about the plaintext history.

## Mental Model

An IV is a **disambiguator**: it makes the same plaintext look different in every context. For disk encryption the natural disambiguator is the sector's physical address — a value the attacker already knows exists but cannot control. The challenge is making the IV unpredictable without the key (to prevent chosen-plaintext attacks) while still being efficiently computable from the sector number alone (because random access must work without reading adjacent sectors).

## How It Works

### The vtable: `crypt_iv_operations`

dm-crypt expresses IV generation as a vtable of function pointers: `struct crypt_iv_operations`. At `crypt_ctr()` time, the IV mode string from the cipher specification (e.g., `plain64` in `aes-xts-plain64`) is matched against a static table of `crypt_iv_operations` structs. The selected vtable is stored in `cc->iv_gen_ops`. During I/O, `crypt_convert()` calls `cc->iv_gen_ops->generator(cc, iv_buf, sector)` before each `crypto_skcipher_encrypt()` or `crypto_skcipher_decrypt()` call.

The vtable has five function pointers:
- `ctr` — parse IV-mode-specific options from the cipher string; set up any state
- `init` — called after the master key is loaded; used by ESSIV to derive its sub-key
- `wipe` — clear IV-mode state when the key is wiped
- `generator` — compute the IV for a given sector number (called per-sector)
- `dtr` — deallocate any IV-mode state on device destruction

### plain64 — simplest possible IV

`iv_plain64_gen()` writes the 64-bit sector number directly into the IV buffer as a little-endian integer:

```c
*(__le64 *)iv = cpu_to_le64(sector);
```

That is the entire function. The sector number includes `iv_offset` from the table line (to handle volumes starting at a non-zero offset). plain64 is fast — zero cryptographic work — and correct when used with XTS mode, because XTS provides its own sector-isolation guarantee via the tweak value. plain64 is **not** safe with CBC mode: since the IV is predictable, an attacker who can submit chosen plaintexts can distinguish different IV values and perform a watermarking attack.

### essiv — Encrypted Salt-Sector IV

ESSIV was the standard safe IV mode for CBC before XTS existed. The key insight is that the IV should depend on the sector number in a way that requires the master key to predict. `iv_essiv_init()` — called after `crypt_setkey()` — computes a secondary key:

```
essiv_key = Hash(master_key)
```

where Hash is configured as part of the ESSIV specification (typically SHA-256). This secondary key is loaded into a separate AES cipher handle (`cc->iv_gen_private.essiv.tfm`). Then, `iv_essiv_gen()` encrypts the sector number under this secondary key:

```
IV = AES_encrypt(essiv_key, sector_number)
```

The IV is now a pseudorandom function of the sector number, indistinguishable from random without the master key. This defeats the watermarking attack against CBC. The cost is one additional AES block encryption per sector. With AES-NI this is fast (~1 ns), but it is still strictly more work than plain64.

ESSIV with AES-CBC is specified as `aes-cbc-essiv:sha256`. The SHA-256 hash is used to derive the ESSIV secondary key during `init`, not during I/O.

### tcw — TrueCrypt Whitening

`tcw` (Tweak-CBC-Wide) implements TrueCrypt's per-sector whitening scheme for backward compatibility with TrueCrypt-formatted volumes. It applies a whitening value derived from the sector number and a secondary key to the plaintext before CBC encryption, and to the ciphertext after decryption. This prevents a specific chosen-plaintext attack against CBC that ESSIV does not fully address. tcw is rarely used for new volumes.

### XTS tweak — built into the cipher

AES-XTS does not need an external IV generation mode in the traditional sense — the tweak (analogous to an IV) is the sector number, computed internally by the XTS algorithm as `E(key2, sector_number)`. When dm-crypt uses `aes-xts-plain64`, the plain64 generator writes the sector number as the "IV", but the XTS kernel algorithm ignores the first 8 bytes as a raw counter and instead computes the tweak internally using its second AES key. The `plain64` label in the cipher string is thus somewhat misleading for XTS: it simply signals "pass the sector number through as-is" rather than doing any IV computation.

### Sector size and IV

When `sector_size` is set to 4096 (matching filesystem block size), IV generation uses the *4096-byte block number* rather than the 512-byte sector number. This means the IV counter advances more slowly, but each IV covers 4096 bytes — matching the filesystem's natural I/O granularity.

## Key Data Structures

**`struct crypt_iv_operations`** (`drivers/md/dm-crypt.c`) — IV generation vtable

- `ctr` — parse IV mode options; e.g., ESSIV records the hash algorithm name
- `init` — post-key-load setup; ESSIV derives its secondary AES key here
- `wipe` — zero IV-specific state during key wipe
- `generator` — populate the IV buffer for the given logical sector number; called per sector in `crypt_convert()`
- `dtr` — release IV-specific resources

**`struct iv_essiv_private`** (within `crypt_config`) — ESSIV state

- `hash_tfm` — hash transform used during `init` to derive the secondary key
- `tfm` — AES cipher handle keyed with `H(master_key)`, used per-sector during IV generation

## Key Functions / Entry Points

**`iv_plain64_gen()`** (`drivers/md/dm-crypt.c`) — writes `sector` as LE64 into `iv`; zero overhead.

**`iv_essiv_init()`** (`drivers/md/dm-crypt.c`) — computes `H(master_key)` and loads it into the ESSIV cipher handle; called once per key load.

**`iv_essiv_gen()`** (`drivers/md/dm-crypt.c`) — calls `crypto_cipher_encrypt_one(essiv_tfm, iv, sector_bytes)` to produce the IV.

**`iv_tcw_gen()`** (`drivers/md/dm-crypt.c`) — TrueCrypt whitening IV generation; used only for TrueCrypt compatibility.

## Important Flags & Config Options

- `iv_offset` in the table line — added to the logical sector number before IV generation; prevents IV collision when an encrypted volume starts at a non-zero offset within a physical device
- `sector_size:<bytes>` — changes the unit of IV computation; 4096 causes IV to count in 4096-byte blocks
- ESSIV requires specifying the hash: `aes-cbc-essiv:sha256`; the hash is parsed during `crypt_ctr()`

## Interactions with Other Subsystems

- **↑ [[dm-crypt-crypt-config]]**: the IV vtable and IV-specific state are stored in `crypt_config`; `iv_gen_ops` points to the selected vtable
- **← [[dm-crypt-crypt-io]]**: `crypt_convert()` calls `generator()` before each `crypto_skcipher_encrypt/decrypt()` call
- **→ [[kernel-crypto-api]]**: ESSIV uses a separate `crypto_cipher` handle (AES ECB) from the Crypto API for the sector-number encryption

## Design Decisions & Tradeoffs

**Why not a random IV per sector?** A random IV would require storing the IV alongside each sector, increasing storage overhead and requiring an extra read before any decryption — incompatible with the fixed sector-size abstraction that block devices provide. Deterministic IV derivation from the sector number enables random access without any per-sector metadata.

**Why ESSIV over plain64 for CBC?** Without key-dependent IV generation for CBC, an adversary with write access who knows what plaintext will be written can craft a write that, combined with a known existing ciphertext, reveals information about the prior content of a sector. ESSIV's key-dependent IV closes this attack. XTS's built-in tweak mechanism achieves the same goal without requiring a separate cipher pass, which is why ESSIV is no longer recommended for new deployments.

**CBC vs. XTS**: CBC encrypts each 512-byte sector block by chaining cipher blocks, making decryption within a sector sequential. XTS (XEX-based Tweaked-CodeBook mode with ciphertext Stealing) allows parallel per-block encryption within a sector and adds a tweak derived from the sector number, providing sector isolation. IEEE P1619 standardised XTS specifically for disk encryption. The kernel added XTS support in 2.6.24 (2008), after which new LUKS deployments migrated away from CBC-ESSIV.

## How It Has Evolved

- **2.5 (2003)**: plain (32-bit sector number) and plain64 only; CBC mode assumed
- **2.6.10 (2004)**: ESSIV added (`iv_essiv_gen`), addressing watermarking attacks against CBC
- **2.6.20 (2007)**: LRW mode and IV support
- **2.6.24 (2008)**: XTS mode introduced; plain64 becomes the correct IV mode for XTS
- **Present**: AES-256-XTS with plain64 is the LUKS2 default cipher; ESSIV and CBC are legacy

## Further Reading

- [dm-crypt kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html)
- [Disk encryption theory — Wikipedia](https://en.wikipedia.org/wiki/Disk_encryption_theory) — covers XTS, LRW, CBC-ESSIV tradeoffs
- [kernel-internals.org: dm-crypt](https://kernel-internals.org/security/dm-crypt/)
