---
title: "fscrypt Inline Encryption"
category: concept
tags: [fscrypt, encryption, inline-encryption, blk-crypto, hardware]
subsystem: fscrypt
kernel_version: "5.9"
researched: 2026-04-15
status: complete
explained: "[[fscrypt-inline-encryption-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html
  - https://lwn.net/Articles/824841/
---

# fscrypt Inline Encryption

> 📘 Plain-language version: [[fscrypt-inline-encryption-explained]]

## Purpose

Encrypting file contents in software (bounce folios + kernel crypto API) consumes CPU cycles and requires an extra memory copy per page written. On mobile and embedded SoCs (Qualcomm, Mediatek), the storage controller has a hardware Inline Crypto Engine (ICE) that can encrypt and decrypt data during the DMA transfer to/from storage — at hardware speeds, with no extra copies. The inline encryption component is the bridge that lets fscrypt exploit these engines, falling back to software when hardware is absent.

## Mental Model

Think of inline encryption as **a tollbooth with a built-in currency converter**. Without it, you stop before the tollbooth, convert your money yourself (encrypt in software), then hand over the converted amount (ciphertext). With the tollbooth doing the conversion (ICE), you hand over your original cash and the converter handles it automatically as the gate lifts — you never see the converted form at all. The fallback path is: the tollbooth *pretends* to be a hardware converter (software emulation in a workqueue), so the upstream code never knows the difference.

## How It Works

Inline encryption is activated per-mount via the `-o inlinecrypt` mount option. When this option is set, the filesystem sets `SB_INLINECRYPT` on the superblock. `fscrypt_inode_uses_inline_crypto()` returns true for inodes on such filesystems, and `fscrypt_prepare_key()` initialises a `blk_crypto_key` instead of (or in addition to) a software `crypto_skcipher`.

**Key attachment to bios** is the core operation. When ext4 or F2FS constructs a bio for file data (read or write), it calls `fscrypt_set_bio_crypt_ctx()`. This function attaches a `blk_crypto_bio_crypt_ctx` to the bio's `bi_crypt_context` field. The context holds a pointer to the `blk_crypto_key` (from the inode's `fscrypt_info`) and the *Data Unit Number* (DUN) — the starting IV for the first data unit in this bio.

**The block layer** (`block/blk-crypto*.c`) processes the bio after submission. If the storage device driver registered hardware inline encryption capabilities (`blk_crypto_register()`), the block layer programs the ICE with the key and starting DUN before submitting the I/O to the hardware. The ICE applies AES-XTS (or the configured mode) to each data unit during DMA, incrementing the DUN counter automatically. The resulting storage transfer is encrypted (write) or decrypted (read) without any software involvement.

**DUN continuity** is a hard requirement. A bio sent to the ICE must have *contiguous* DUNs: if the first data unit in the bio is DUN=5, the subsequent units must be 6, 7, 8, … in order. A gap — say, a bio that starts at DUN=5, skips to DUN=10 — would cause the hardware to apply wrong IVs to the skipped range. Filesystems must ensure DUN continuity by splitting bios at any discontinuity. ext4 and F2FS do this in `fscrypt_limit_io_blocks()`, which computes the maximum number of contiguous blocks from a given starting position before a DUN gap would occur (e.g., a file hole or a different-keyed extent boundary). This function is called at the start of each bio assembly.

**Bio merging** in the I/O scheduler is also affected. The block layer calls `fscrypt_get_mergeable_bio_crypt_ctx()` to check whether an incoming bio can be merged with an existing bio in the elevator queue. Two bios are mergeable only if they use the same `blk_crypto_key` and have contiguous DUNs. This is checked in `blk_crypto_req_bio_prep()` and `blk_crypto_bio_crypt_ctx_compatible()`.

**The fallback path** (`CONFIG_BLK_INLINE_ENCRYPTION_FALLBACK=y`) handles hardware that advertises inline encryption capability but doesn't support the specific algorithm or key size required. `blk-crypto-fallback` intercepts the bio, allocates bounce pages, encrypts/decrypts in a workqueue using the kernel crypto API, and resubmits without encryption context. This fallback is transparent to fscrypt — from its perspective, every bio submitted to a filesystem with `-o inlinecrypt` is handled by "inline encryption", whether hardware or fallback.

**Hardware-wrapped keys** (kernel 5.13+) are an extension of inline encryption. In this model, the key material is never raw in DRAM. Instead:
1. During provisioning, the hardware generates a *wrapped key blob* — the raw key encrypted under a hardware-internal key stored only in the ICE's secure enclave.
2. The wrapped blob is stored by the OS (in `mk_secret` of `fscrypt_master_key`) and passed to the ICE at mount time.
3. For content encryption, the ICE receives the wrapped blob, unwraps it internally, and uses the raw key only within hardware.
4. For filenames and other non-content keys, the kernel calls `blk_crypto_hw_wrapped_key_derive_sw_secret()`. The hardware derives a *software secret* (a different key, not the content key) using SP800-108 counter-mode KDF with AES-256-CMAC. This software secret is returned to fscrypt, which then uses it as the input to its own HKDF-SHA512 derivation for filename keys and other non-hardware operations.
5. The raw content key is never in DRAM.

This protects against DRAM-extraction attacks (cold boot, DMA-based memory reads) — even a fully compromised kernel cannot extract the content key. The tradeoff: wrapped keys are tied to the specific hardware and boot session; filesystem images cannot be moved to another machine for decryption.

**Restrictions on hardware-wrapped keys**:
- Only compatible with `IV_INO_LBLK_64` or `IV_INO_LBLK_32` policies (the ICE uses a single key for all files, distinguished only by IV)
- Requires `-o inlinecrypt`
- Incompatible with portable filesystem images
- Only ext4 and F2FS support it today

## Key Data Structures

**`struct blk_crypto_key`** (`include/linux/blk-crypto.h`) — represents a key for the block-layer inline encryption API.
- `crypto_cfg` — `blk_crypto_config`: algorithm, key size, data unit size
- `raw[BLK_CRYPTO_MAX_KEY_SIZE]` — raw or wrapped key bytes
- `hash` — used by the ICE driver for key deduplication in hardware key slots

**`struct blk_crypto_bio_crypt_ctx`** (internal, per-bio) — attached to `bio->bi_crypt_context`.
- `bc_key` — pointer to `blk_crypto_key`
- `bc_dun[BLK_CRYPTO_DUN_ARRAY_SIZE]` — the starting DUN for this bio

**`struct fscrypt_prepared_key`** — contains `blk_key` pointer for the inline encryption path; see [[fscrypt-inode-info]] for full field description.

## Key Functions / Entry Points

**`fscrypt_set_bio_crypt_ctx()`** (`fs/crypto/inline_crypt.c`) — attaches `(blk_crypto_key, start_DUN)` to a bio; called from ext4/F2FS bio construction code.

**`fscrypt_get_mergeable_bio_crypt_ctx()`** (`fs/crypto/inline_crypt.c`) — checks if an incoming bio's crypto context is compatible with an existing one for merging.

**`fscrypt_inode_uses_inline_crypto()`** (`fs/crypto/inline_crypt.c`) — returns true if the inode is on an `-o inlinecrypt` filesystem; used to select the inline vs software path.

**`fscrypt_limit_io_blocks()`** (`fs/crypto/inline_crypt.c`) — computes the maximum contiguous block range from a given LBA before a DUN discontinuity; called during bio assembly in ext4/F2FS.

**`blk_crypto_init_key()`** (`block/blk-crypto.c`) — initialises a `blk_crypto_key` from raw or wrapped bytes; called from `fscrypt_prepare_key()`.

**`blk_crypto_hw_wrapped_key_derive_sw_secret()`** (`block/blk-crypto.c`) — asks the ICE to produce the software secret from a wrapped key; called during `FS_IOC_ADD_ENCRYPTION_KEY` for wrapped keys.

## Important Flags & Config Options

**`CONFIG_FS_ENCRYPTION_INLINE_CRYPT`** — compile-time enablement of the blk-crypto integration in fscrypt.

**`-o inlinecrypt`** — per-mount activation; without this, even hardware-capable filesystems use the software bounce-folio path.

**`SB_INLINECRYPT`** — superblock flag; set when `-o inlinecrypt` is active; checked by `fscrypt_inode_uses_inline_crypto()`.

**`CONFIG_BLK_INLINE_ENCRYPTION_FALLBACK`** — enables the blk-crypto-fallback workqueue for software emulation of inline encryption on hardware without native support.

**`FSCRYPT_ADD_KEY_FLAG_HW_WRAPPED`** — flag for `FS_IOC_ADD_ENCRYPTION_KEY` indicating the provided key material is hardware-wrapped.

## Interactions with Other Subsystems

- **→ [[block-layer|Block Layer / blk-crypto]]**: `fscrypt_set_bio_crypt_ctx()` populates `bio->bi_crypt_context`; the block layer routes bios to hardware ICE or software fallback based on this context.
- **→ [[fscrypt-inode-info]]**: `fscrypt_prepare_key()` populates `ci_enc_key.blk_key`; `fscrypt_set_bio_crypt_ctx()` reads it.
- **→ [[fscrypt-key-management]]**: Hardware-wrapped keys extend `fscrypt_master_key.mk_secret` to store wrapped blobs; `blk_crypto_hw_wrapped_key_derive_sw_secret()` is called during `fscrypt_ioctl_add_key()`.
- **← ext4/F2FS**: These filesystems call `fscrypt_set_bio_crypt_ctx()`, `fscrypt_limit_io_blocks()`, and `fscrypt_get_mergeable_bio_crypt_ctx()` during bio lifecycle management.
- **↓ Hardware**: Qualcomm ICE and Mediatek ICE hardware; UFS/eMMC storage controllers with inline encryption capability.

## Design Decisions & Tradeoffs

**fscrypt owns the key lifecycle, block layer owns the transport** — An alternative design would have the block layer own `blk_crypto_key` allocation and expose a higher-level API to fscrypt. The chosen approach — fscrypt allocates and owns the key, just attaches it to each bio — keeps the ownership semantics clear and avoids a complex shared lifecycle. The block layer is a pure transport: it receives the key attached to the bio and either programs hardware or runs the fallback.

**DUN continuity as a filesystem responsibility** — The hardware ICE increments DUNs automatically and cannot skip values within a single bio. Rather than having the block layer split bios at DUN gaps (which would require it to understand filesystem extent layout), the responsibility was placed on filesystems via `fscrypt_limit_io_blocks()`. This is a form of "pushing knowledge to the layer that has it" — the filesystem knows about its extent layout; the block layer does not.

**Software fallback transparency** — Making the fallback path transparent to both fscrypt and filesystems was a deliberate choice: it allows filesystems to always mount with `-o inlinecrypt` regardless of hardware availability, simplifying deployment configurations. The cost is that the fallback (workqueue-based bounce encryption) may actually be *slower* than the direct software path in `fscrypt_encrypt_pagecache_blocks()` due to workqueue overhead.

## How It Has Evolved

| Kernel | Change |
|--------|--------|
| 5.9 | Inline encryption initial implementation: blk-crypto, `fscrypt_set_bio_crypt_ctx()` |
| 5.13 | Hardware-wrapped key support; software-secret derivation via ICE |
| 5.18 | `fscrypt_limit_io_blocks()` for DUN continuity enforcement in ext4/F2FS |
| 6.16 | SP800-108 KDF standardisation for hardware-wrapped key derivation |

## Further Reading

1. [Inline encryption support for fscrypt (LWN)](https://lwn.net/Articles/824841/) — the definitive introduction to blk-crypto integration
2. [Inline encryption kernel docs](https://www.kernel.org/doc/html/latest/block/inline-encryption.html) — blk-crypto architecture from the block layer side
3. [fscrypt hardware-wrapped keys (Android)](https://source.android.com/docs/security/features/encryption/hw-wrapped-keys) — Android's hardware-wrapped key usage

## LKML Highlights

- **blk-crypto inline encryption** (`20200717014540.59122-1-satyat@google.com`): The initial inline encryption series. Key debate: whether fscrypt or the block layer should own key allocation. Landed with fscrypt owning the key lifecycle and the block layer as a transport.
- **Hardware-wrapped keys** (`20210210202336.349924-1-ebiggers@kernel.org`): Added `FSCRYPT_ADD_KEY_FLAG_HW_WRAPPED` and the software-secret derivation path. Debate: how to standardise the KDF across vendor ICE implementations — settled on SP800-108 Counter Mode with AES-256-CMAC as the required algorithm.
