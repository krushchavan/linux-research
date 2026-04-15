---
title: "fscrypt Inode Info"
category: concept
tags: [fscrypt, encryption, inode, key-derivation, per-file]
subsystem: fscrypt
kernel_version: "4.1"
researched: 2026-04-15
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html
  - https://lwn.net/Articles/795378/
---

# fscrypt Inode Info

## Purpose

Every open encrypted inode needs rapid access to its derived symmetric key and ready-to-use cipher transform. The `fscrypt_info` structure caches this per-inode encryption context so that every read and write doesn't re-run the key derivation function. Without this cached context, each I/O operation would require a keyring lookup and HKDF invocation — orders of magnitude more expensive than a pointer dereference.

## Mental Model

Think of `fscrypt_info` as the **per-inode encryption passport**: issued lazily when the inode first passes through border control (its first `open()`), kept in the inode's pocket for its entire lifetime, and shredded when the inode is evicted from memory. The passport contains the pre-computed derived key, the cipher transform handle ready to go, and a back-reference to the master key so the passport can be invalidated if the master key is revoked.

## How It Works

The lifecycle starts on the first access to an encrypted inode — typically `open()` or `lookup()`. The filesystem calls `fscrypt_file_open()` (`fs/crypto/crypto.c`), which calls `fscrypt_get_encryption_info()`. At this point the inode's `i_crypt_info` pointer is still NULL.

`fscrypt_get_encryption_info()` begins by reading the `security.fscrypt_context` xattr from the inode (using the inode's own backing storage, not an extra disk read if the inode is already cached). It extracts the policy version, cipher modes, flags, master key identifier, and the 16-byte *nonce* unique to this inode.

Next it calls `fscrypt_get_master_key()` to find the `fscrypt_master_key` in `s_master_keys` matching the identifier. If no such key exists, the function returns `ENOKEY` and the open fails. If the key is found but `mk_present` is false (the key is in INCOMPLETELY_REMOVED state), it also returns `ENOKEY`.

With the master key in hand, `fscrypt_derive_key()` runs HKDF-SHA512 with the master key's Extract output as the PRK, the inode nonce as part of the info string, and the appropriate context label ("file key" or "filenames key"). This produces a derived key of the correct length for the chosen cipher (32 bytes for AES-256-XTS contents key, 64 bytes for the full AES-256-XTS key pair).

**Key verification** (v2 only): after derivation, the kernel checks the derived key hash against `mk_hash`. A mismatch returns `ENOKEY` rather than silently using a wrong key.

`fscrypt_prepare_key()` then converts the derived bytes into either a software `crypto_skcipher` transform handle (via `crypto_alloc_skcipher()`) or a `blk_crypto_key` for inline encryption — depending on whether the policy has `DIRECT_KEY`, whether `-o inlinecrypt` is active, and hardware capabilities. The transform handle is stored in `ci_enc_key.tfm` or `ci_enc_key.blk_key`.

The fully-populated `fscrypt_info` is then atomically stored into `inode->i_crypt_info` via `cmpxchg()`. The cmpxchg is important: two threads could race to open the same inode for the first time. The loser's `fscrypt_info` is freed immediately; the winner's remains. All subsequent operations on the inode use the cached `i_crypt_info` without any locking.

The inode is also added to `mk_decrypted_inodes` at this point, bumping `mk_active_refs`. This addition is protected by the `mk_decrypted_inodes_lock` spinlock.

**Special handling for DIRECT_KEY policies**: no per-file derived key is computed; instead, `ci_direct_key` points to the master key's material used directly. The nonce is embedded in IVs at encryption time rather than in key derivation.

**IV_INO_LBLK_32 optimisation**: For this hardware-compatibility mode, the inode number is hashed through SipHash-2-4 at `fscrypt_info` creation time and cached in `ci_inode_hash`. The hash is used to construct 32-bit IVs at every subsequent I/O request, avoiding per-request inode number hashing.

**Cleanup** happens in two places. `fscrypt_free_inode()` is called by the VFS when an inode is evicted from the inode cache (`clear_inode()` path). It zeroes and frees `ci_enc_key` (the derived key material), frees the `crypto_skcipher` or `blk_crypto_key`, releases the reference to `fscrypt_master_key` (decrementing `mk_active_refs`), and removes the inode from `mk_decrypted_inodes`. If `mk_active_refs` reaches zero in `fscrypt_put_master_key_activeref()`, the master key itself may be freed.

## Key Data Structures

**`struct fscrypt_info`** (`fs/crypto/fscrypt_private.h`) — per-inode encryption context, pointed to by `inode->i_crypt_info`.
- `ci_policy` — `fscrypt_policy_union`: the stored policy (v1 or v2)
- `ci_enc_key` — `fscrypt_prepared_key`: the derived, ready-to-use symmetric key (tfm or blk_key)
- `ci_master_key` — pointer to `fscrypt_master_key`; keeps the master key alive while the inode exists
- `ci_direct_key` — `fscrypt_direct_key *`; non-NULL for DIRECT_KEY policies; caches the shared direct key
- `ci_data_unit_bits` — `u32`; log2 of the data unit size (0 = filesystem block size)
- `ci_inode_hash` — `u32`; SipHash of inode number for `IV_INO_LBLK_32` IV construction

**`struct fscrypt_prepared_key`** (`fs/crypto/fscrypt_private.h`) — holds either a software or hardware key handle.
- `tfm` — `crypto_skcipher *`; software AES transform; NULL when using inline encryption
- `blk_key` — `blk_crypto_key *`; hardware inline encryption key; NULL when using software

## Key Functions / Entry Points

**`fscrypt_file_open()`** (`fs/crypto/crypto.c`) — top-level entry point; ensures `fscrypt_info` is populated before the first VFS operation; called from filesystem `open()` and `atomic_open()` handlers.

**`fscrypt_get_encryption_info()`** (`fs/crypto/crypto.c`) — allocates and populates `fscrypt_info`; does xattr read, key lookup, HKDF derivation, transform init; called from `fscrypt_file_open()` and `fscrypt_prepare_symlink()`.

**`fscrypt_prepare_key()`** (`fs/crypto/keysetup.c`) — converts raw derived key bytes into a usable `fscrypt_prepared_key`; selects software or hardware path.

**`fscrypt_free_inode()`** (`fs/crypto/crypto.c`) — called by `clear_inode()` on eviction; zeroes derived keys, drops master key reference, frees the `fscrypt_info`.

**`fscrypt_drop_inode()`** (`fs/crypto/crypto.c`) — returns 1 to the VFS (prompting eviction) when the inode's master key has been removed; called from the VFS `drop_inode` hook.

## Important Flags & Config Options

**`ci_data_unit_bits`** (runtime, not Kconfig) — controls encryption granularity; 0 means filesystem block size; 3–16 for sub-block encryption per `log2_data_unit_size` in the v2 policy.

**`CONFIG_FS_ENCRYPTION_INLINE_CRYPT`** — when enabled, `fscrypt_prepare_key()` may initialise a `blk_crypto_key` instead of a `crypto_skcipher`.

## Interactions with Other Subsystems

- **← VFS**: `clear_inode()` calls `fscrypt_free_inode()`; the `drop_inode` hook calls `fscrypt_drop_inode()`.
- **← Filesystems**: ext4/F2FS call `fscrypt_file_open()` before any inode operations; they also call `fscrypt_get_encryption_info()` during directory lookup for encrypted dentries.
- **→ [[fscrypt-key-management]]**: `fscrypt_get_encryption_info()` calls `fscrypt_get_master_key()` to find the `fscrypt_master_key` and bumps `mk_active_refs`.
- **→ [[fscrypt-contents-encryption]]**: `ci_enc_key` is used by `fscrypt_encrypt_pagecache_blocks()` / `fscrypt_decrypt_pagecache_blocks()`.
- **→ [[fscrypt-filenames-encryption]]**: `ci_enc_key` or `ci_direct_key` is used by `fscrypt_fname_encrypt()`.
- **→ [[kernel-crypto-api|Kernel Crypto API]]**: `fscrypt_prepare_key()` calls `crypto_alloc_skcipher()` to obtain the software transform handle.

## Design Decisions & Tradeoffs

**Lazy initialisation** — `fscrypt_info` is allocated on first access, not at inode creation. This avoids paying the HKDF cost for directories that are traversed but not read (e.g., path lookup through an encrypted directory hits many inodes). The downside is that ENOKEY can surface late — during `open()` rather than during `lookup()`.

**cmpxchg for race safety without locking** — Two threads racing to `open()` the same inode would both compute `fscrypt_info`. Rather than holding a lock for the entire HKDF computation (expensive), both compute independently and the cmpxchg picks a winner. The loser's context is freed. This is safe because HKDF is deterministic — both contexts are identical.

**Per-inode derived key caching** — Derived keys are cached indefinitely while the inode is in the inode cache, even if the corresponding file descriptors are closed. This means the inode cache expiry (not file descriptor close) is when keys are released. This was a deliberate choice: re-deriving the key on every open would add perceptible latency for small files accessed repeatedly.

## How It Has Evolved

| Kernel | Change |
|--------|--------|
| 4.1 | Initial `fscrypt_info` attached to inode |
| 5.4 | Added `ci_master_key` back-reference for v2; `mk_decrypted_inodes` tracking |
| 5.9 | `ci_enc_key` extended to hold `blk_crypto_key` for inline encryption |
| 6.8 | `ci_data_unit_bits` added for sub-block data unit support |

## Further Reading

1. [fscrypt kernel docs — per-file encryption](https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html#per-file-encryption-keys)
2. [Key management improvements (LWN)](https://lwn.net/Articles/795378/) — covers the `mk_decrypted_inodes` eviction mechanism
