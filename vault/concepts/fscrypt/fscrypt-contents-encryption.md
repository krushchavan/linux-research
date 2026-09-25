---
title: "fscrypt Contents Encryption"
category: concept
tags: [fscrypt, encryption, page-cache, aes-xts, writeback]
subsystem: fscrypt
kernel_version: "4.1"
researched: 2026-04-15
status: complete
explained: "[[fscrypt-contents-encryption-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html
  - https://lwn.net/Articles/824841/
  - https://lwn.net/Articles/788932/
---

# fscrypt Contents Encryption

> 📘 Plain-language version: [[fscrypt-contents-encryption-explained]]

## Purpose

File contents must be encrypted before they hit persistent storage and decrypted after they are read back, transparently to userspace. This component handles that transformation at the page cache boundary — the layer between the in-memory plaintext that processes read and write, and the ciphertext that filesystems write to block devices. Without content encryption, raw disk images would expose all file data to an attacker with physical access.

## Mental Model

Imagine the page cache as a **clean room** where all documents are stored in plaintext. The storage device is the **outside world** where everything must be in sealed envelopes (ciphertext). fscrypt contents encryption is the **mailroom**: every page leaving the clean room gets sealed; every page arriving from outside gets unsealed. The original plaintext pages stay in the clean room undisturbed — the sealing is done on copies, not in-place.

## How It Works

**The data unit** is the fundamental encryption granularity. By default it equals the filesystem block size (typically 4096 bytes). A v2 policy with `log2_data_unit_size` set can request smaller units (down to 512 bytes), enabling sub-block encryption useful for Btrfs compressed extents or UBIFS variable-size chunks. Each data unit within a file has a unique IV, derived from its zero-based index within the file. This prevents an attacker from detecting that two different positions within a file contain identical plaintext (which would produce identical ciphertext if the IV were reused).

**Read path (decryption)**: The filesystem calls its block I/O routines to bring encrypted pages from disk into the page cache. Before marking those pages uptodate and releasing them for VFS use, it calls `fscrypt_decrypt_pagecache_blocks()` (`fs/crypto/bio.c`). This function iterates over the page in data-unit-sized chunks. For each chunk it computes the IV — `data_unit_index` as a 64-bit little-endian integer for the standard case; with `IV_INO_LBLK_64` it's `(inode_num << 32) | data_unit_index`; with `IV_INO_LBLK_32` it's `ci_inode_hash + data_unit_index` (modular 32-bit). Then it calls `crypto_skcipher_decrypt()` with the `tfm` from the inode's `fscrypt_info`, decrypting in-place. The whole process happens while the folio lock is held, preventing concurrent access to partially-decrypted data. For inline encryption the decryption does not happen here at all — the hardware decrypts during DMA from storage, and the pages arrive already decrypted.

**Write path (encryption — software)**: The fundamental challenge is that the page cache must remain plaintext — future reads need the unmodified original. Encrypting in-place would corrupt the cache. Instead, `fscrypt_encrypt_pagecache_blocks()` allocates a *bounce folio* from `fscrypt_bounce_page_pool`, copies the plaintext from the original page into the bounce folio, then encrypts the bounce folio in-place. The filesystem then submits the bounce folio for writeback instead of the original page. After I/O completes, `fscrypt_finalize_bounce_page()` frees the bounce folio and wakes up the original page so it can be freed if no longer needed.

The bounce-folio approach has a memory cost: during peak writeback, the kernel may hold two copies of the data simultaneously (plaintext page + encrypted bounce). `fscrypt_bounce_page_pool` is a mempool that pre-allocates pages to avoid writeback stalling when the allocator is under pressure.

**Write path (encryption — inline)**: With `-o inlinecrypt`, `fscrypt_set_bio_crypt_ctx()` attaches the `blk_crypto_key` and the starting IV to the bio before submission. The block layer programs the storage controller's ICE register with the key and IV; the hardware encrypts the data during DMA to the drive. No bounce folio is needed — the plaintext page is sent directly. The IV must be *contiguous* across all segments in the bio (DUN continuity requirement): ext4 and F2FS split bios at encryption boundary discontinuities rather than letting the block layer guess.

**UBIFS (non-block, MTD path)**: UBIFS uses variable-size data nodes and operates directly on MTD devices (not block devices), so the page-oriented encrypt/decrypt functions don't apply. Instead it uses `fscrypt_encrypt_block_inplace()` and `fscrypt_decrypt_block_inplace()`, which operate on arbitrary-length buffers. The IV construction for UBIFS uses the filesystem logical address as the data unit index.

**Direct I/O**: Direct I/O with encryption requires inline encryption (hardware or blk-crypto-fallback). It further requires that the file offset, I/O length, and buffer address are all multiples of the data unit size. Misaligned direct I/O falls back to buffered I/O. This constraint is checked in `fscrypt_limit_io_blocks()` which adjusts I/O limits at the start of the read/write path.

**Hole handling**: Sparse files have holes — ranges with no backing storage. When a hole is allocated (e.g., via `fallocate()`), `fscrypt_zeroout_range()` encrypts zero-filled pages and writes them, so the on-disk representation of a hole matches what AES-XTS would produce for an all-zero plaintext. This ensures `read()` on a freshly-fallocated range returns zeroes, not ciphertext garbage.

**Operations prohibited on encrypted inodes**:
- `FALLOC_FL_COLLAPSE_RANGE` and `FALLOC_FL_INSERT_RANGE` — would shift data unit indices, invalidating IVs
- Online defragmentation — same IV-shift problem
- `O_DIRECT` without inline encryption — buffer misalignment would require partial data-unit encryption, which AES-XTS cannot do safely
- DAX (Direct Access) — DAX bypasses the page cache, making the bounce-folio path impossible
- Data journaling (ext4) — journaling encrypted data would log ciphertext, making journal recovery require the key

## Key Data Structures

**`struct fscrypt_prepared_key`** (`fs/crypto/fscrypt_private.h`) — holds the encryption transform; see [[fscrypt-inode-info]] for field details.

**Bounce folio** (unnamed `struct folio *`) — temporary page allocated from `fscrypt_bounce_page_pool`; holds encrypted copy of plaintext during writeback; freed in I/O completion.

## Key Functions / Entry Points

**`fscrypt_encrypt_pagecache_blocks()`** (`fs/crypto/bio.c`) — encrypts plaintext page data into a bounce folio for writeback; called from filesystem writeback paths (e.g., `ext4_writepage()`).

**`fscrypt_decrypt_pagecache_blocks()`** (`fs/crypto/bio.c`) — decrypts ciphertext data in-place after a page read completes; called from filesystem `readahead` / `readpage` completion.

**`fscrypt_encrypt_block_inplace()`** (`fs/crypto/crypto.c`) — encrypts an arbitrary-length buffer in-place; used by UBIFS for variable-size data nodes.

**`fscrypt_decrypt_block_inplace()`** (`fs/crypto/crypto.c`) — counterpart to the above for decryption.

**`fscrypt_set_bio_crypt_ctx()`** (`fs/crypto/inline_crypt.c`) — attaches `(blk_crypto_key, start_iv)` to a bio for hardware-offloaded encryption; called by ext4/F2FS during bio construction.

**`fscrypt_zeroout_range()`** (`fs/crypto/crypto.c`) — writes encrypted zeroes for a file range (hole initialisation); called during `fallocate()`.

**`fscrypt_limit_io_blocks()`** (`fs/crypto/inline_crypt.c`) — clamps an I/O request's length to maintain DUN continuity for inline encryption.

## Important Flags & Config Options

**`CONFIG_FS_ENCRYPTION_INLINE_CRYPT`** — enables the blk-crypto integration path; without it, inline encryption hardware cannot be used.

**`-o inlinecrypt`** mount option — activates the inline encryption path for the mounted filesystem.

**`SB_INLINECRYPT`** superblock flag — set when `-o inlinecrypt` is active; consulted by `fscrypt_inode_uses_inline_crypto()`.

**`CONFIG_BLK_INLINE_ENCRYPTION_FALLBACK`** — enables the blk-crypto-fallback software path that emulates inline encryption in a workqueue; allows `-o inlinecrypt` to work on hardware that lacks native support.

**`FSCRYPT_MODE_AES_256_XTS`** — recommended contents mode; XTS is a wide-block cipher designed for disk encryption (no ciphertext expansion, parallelisable).

**`FSCRYPT_MODE_ADIANTUM`** — software-only, optimised for ARM devices without AES hardware; uses ChaCha20 + Poly1305 + NH as the basis.

## Interactions with Other Subsystems

- **↑ Userspace**: reads and writes via `read()`/`write()`, `mmap()`, `readahead`; userspace sees plaintext.
- **→ [[fscrypt-inode-info]]**: `ci_enc_key.tfm` or `ci_enc_key.blk_key` provides the cipher transform; `ci_data_unit_bits` determines IV granularity.
- **→ [[block-layer|Block Layer]]**: software path submits bounce folios via normal `submit_bio()`; inline encryption path additionally programs the bio's `bi_crypt_context` via `fscrypt_set_bio_crypt_ctx()`.
- **→ [[kernel-crypto-api|Kernel Crypto API]]**: software decryption/encryption calls `crypto_skcipher_encrypt()`/`crypto_skcipher_decrypt()` with the prepared skcipher transform.
- **← [[fscrypt-inline-encryption]]**: inline encryption replaces the software bounce-folio path end-to-end.

## Design Decisions & Tradeoffs

**Bounce folios rather than in-place writeback** — In-place encryption would corrupt the page cache, forcing every subsequent read to re-encrypt (nonsensical) or re-read from disk. The bounce-folio approach doubles memory usage during writeback peaks but preserves cache coherency. An alternative (encrypt the page before writeback, decrypt it back after) would be fragile under concurrent readers.

**Page cache holds plaintext** — This is both a feature (applications see plaintext naturally) and a limitation (any root process can read decrypted data from the inode's page cache even without the encryption key, as long as the inode is in cache). fscrypt's threat model is offline attacks; for online multi-process isolation, mandatory access control (SELinux, etc.) is the correct layer.

**AES-XTS for contents** — XTS (XEX-based Tweaked CodeBook mode with ciphertext Stealing) was designed specifically for disk encryption. It is length-preserving (no overhead per block), parallelisable (blocks are independent), and uses the data unit index as the "tweak" naturally. The alternative (CBC) had problems with IV reuse for seek-and-write patterns; XTS avoids these because the tweak is deterministic and not reusable across logical positions.

## How It Has Evolved

| Kernel | Change |
|--------|--------|
| 4.1 | AES-256-XTS contents encryption in ext4 |
| 4.8 | Adiantum cipher support for ARM without AES hardware |
| 5.0 | UBIFS: `fscrypt_encrypt/decrypt_block_inplace()` for MTD path |
| 5.9 | Inline encryption: `fscrypt_set_bio_crypt_ctx()`; bounce folio path removed for `inlinecrypt` mounts |
| 6.8 | `log2_data_unit_size` support for sub-block data units |

## Further Reading

1. [Inline encryption for fscrypt (LWN)](https://lwn.net/Articles/824841/) — blk-crypto integration, DUN continuity, hardware requirements
2. [blocksize != PAGE_SIZE preparation (LWN)](https://lwn.net/Articles/788932/) — sub-block data unit groundwork
3. [fscrypt kernel docs — contents encryption](https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html#contents-encryption)

## LKML Highlights

- **Inline encryption integration** (`20200717014540.59122-1-satyat@google.com`): Added `blk_crypto_key` to bios. Core debate was key ownership (fscrypt vs block layer); settled on fscrypt owning the key and just attaching it to the bio at submission time.
- **sub-block data unit size** (`20230205062827.1038823-1-ebiggers@kernel.org`): Introduced `log2_data_unit_size` to v2 policies. Required reworking IV calculation to use data-unit indices rather than block indices, and adding `ci_data_unit_bits` to `fscrypt_info`.
