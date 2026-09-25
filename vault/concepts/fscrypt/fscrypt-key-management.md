---
title: "fscrypt Key Management"
category: concept
tags: [fscrypt, encryption, key-management, keyring, hkdf]
subsystem: fscrypt
kernel_version: "5.4"
researched: 2026-04-15
status: complete
explained: "[[fscrypt-key-management-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html
  - https://lwn.net/Articles/737274/
  - https://lwn.net/Articles/795378/
---

# fscrypt Key Management

> 📘 Plain-language version: [[fscrypt-key-management-explained]]

## Purpose

The key management component owns the secure lifecycle of master encryption keys: adding them to the kernel, tracking which inodes they protect, and ensuring that when a key is removed, the derived subkeys are wiped from memory and the encrypted files become inaccessible. Without a dedicated lifecycle manager, encrypted files would either stay permanently decryptable after the user logs out (key never evicted) or the kernel would have no reliable way to verify that the correct key was supplied (wrong-key attacks).

## Mental Model

Think of the key management system as a **filesystem-wide key safe with a per-user ledger**. When a user adds a master key, their name is entered in the ledger alongside the key. Another user adding the same key adds their name too — neither can lock the others out. When a user removes their entry, the ledger shrinks; only when the last name is crossed out does the key safe door close and the safe contents get shredded. Until then, all previously unlocked files remain open for anyone who already has a file descriptor — but no new files can be opened after the shredding starts.

## How It Works

**Adding a key** begins with `FS_IOC_ADD_ENCRYPTION_KEY`. The kernel calls `fscrypt_ioctl_add_key()` in `fs/crypto/keyring.c`, which copies the raw key bytes (16–64 bytes) from userspace, validates the length and type, and then asks: is this key already in `s_master_keys`, the filesystem-level keyring attached to the superblock?

The lookup uses `fscrypt_key_specifier` — either an 8-byte *descriptor* (v1) or a 16-byte *identifier* (v2). For v2 keys the identifier is a cryptographic hash of the key material, derived via HKDF-SHA512 at add time, so two different key materials can never produce the same identifier. If the key is already present, the kernel creates a new per-UID user entry in the `mk_users` sub-keyring inside `fscrypt_master_key` — effectively a reference count per user. If the key is not present, a new `fscrypt_master_key` is allocated, the raw key bytes are copied into `mk_secret`, the identifier/hash is computed, and the structure is inserted into `s_master_keys`.

The `fscrypt_master_key` struct is the central data structure. Its `mk_secret` field holds the raw key bytes. `mk_users` is a sub-keyring containing one entry per UID that has added the key; its size is the effective "how many users currently hold this key" count. `mk_decrypted_inodes` is a spinlock-protected list of every inode currently using this key — these are the inodes that would need to be evicted when the key is removed. `mk_active_refs` is a reference count: one for the key being present, plus one for each inode in `mk_decrypted_inodes`. When `mk_active_refs` reaches zero, the structure can be freed.

**Inode unlock** happens lazily on first access. When any file operation (typically `open()`) touches an encrypted inode, `fscrypt_get_encryption_info()` reads the inode's `fscrypt_context` xattr, extracts the master key identifier, calls `fscrypt_get_master_key()` to find the matching `fscrypt_master_key` in `s_master_keys`, and links the inode into `mk_decrypted_inodes`. This bump to `mk_active_refs` is what keeps the key structure alive for the duration of the inode's life.

**Key derivation** uses HKDF-SHA512 (RFC 5869), implemented in `fs/crypto/hkdf.c`. HKDF has two phases: *Extract* (converts the raw key into a uniform pseudorandom key using HMAC-SHA512) and *Expand* (stretches that into output keying material of any desired length). For each per-file key, `hkdf_expand()` is called with an info string that encodes the purpose (`"fscrypt\0file key\0"`), and the 16-byte inode nonce. For the key identifier, a different info string (`"fscrypt\0key identifier\0"`) produces the 16-byte hash. Because HMAC-SHA512 output is computationally indistinguishable from random, deriving the per-file key from the identifier is infeasible — the identifier leaks nothing about the master key.

SHA-512 was chosen over SHA-256 deliberately: the AES-256-XTS key is 512 bits (two 256-bit keys), which fits in exactly one SHA-512 output block, whereas SHA-256 would require two expand iterations — roughly 30% slower.

**v2 key verification** adds one more step after derivation. The kernel runs HKDF-Expand with the key hash info string, producing a fixed hash, and compares it against the `mk_hash` stored in `fscrypt_master_key` at add time. If the master key that was added is wrong (e.g., a user typed the wrong passphrase and their KDF produced the wrong bytes), the hash comparison fails and `fscrypt_get_encryption_info()` returns `ENOKEY` rather than silently proceeding with garbage decryption. This also prevents denial-of-service: an attacker cannot add a wrong key under a known identifier and lock everyone out.

**Removing a key** proceeds through `fscrypt_ioctl_remove_key()`. The caller's UID entry is removed from `mk_users`. If other UIDs still have entries, the function returns 0 with `FSCRYPT_KEY_REMOVAL_STATUS_FLAG_OTHER_USERS_ADDED_KEY` set in the output — the key remains usable. Only when the last user entry is removed does removal proceed to the next phase: `mk_secret` is zeroed (wiped from DRAM), `mk_present` is cleared atomically, and `fscrypt_evict_inodes()` walks `mk_decrypted_inodes` calling `fscrypt_drop_inode()` for each. The VFS will call `evict_inode()` when the inode has no remaining references; at that point `fscrypt_free_inode()` frees the `fscrypt_info` and drops `mk_active_refs`.

Inodes with open file descriptors cannot be evicted. These remain in `mk_decrypted_inodes`, keeping `mk_active_refs > 0`. The key enters the **INCOMPLETELY_REMOVED** state. A background workqueue (`fscrypt_retryable_eviction_work`) retries eviction periodically. As userspace closes the remaining file descriptors, the VFS eventually evicts those inodes, and the workqueue completes the transition to **ABSENT**. Userspace can poll `FS_IOC_GET_ENCRYPTION_KEY_STATUS` to observe the transition.

**Hardware-wrapped keys** (`FSCRYPT_ADD_KEY_FLAG_HW_WRAPPED`, kernel 5.13+) extend the model for inline encryption hardware. Instead of raw key bytes, the kernel receives a hardware-wrapped blob — the actual key material encrypted by a hardware-internal key that never leaves the chip. The `mk_secret` field stores the wrapped blob rather than raw bytes. When per-file keys are needed for filename encryption (which cannot use hardware), the kernel asks the inline encryption hardware to derive a *software secret* via SP800-108 counter mode KDF; this software secret then keys fscrypt's own HKDF-SHA512. For file content keys, blk-crypto passes the wrapped blob directly to the hardware for use in inline encryption.

## Key Data Structures

**`struct fscrypt_master_key`** (`fs/crypto/fscrypt_private.h`) — one per unique master key per filesystem.
- `mk_spec` — `fscrypt_key_specifier` (descriptor or identifier); used for lookup
- `mk_secret` — raw key bytes (or wrapped blob); wiped on removal
- `mk_users` — sub-keyring of per-UID user entries; length = number of users holding the key
- `mk_decrypted_inodes` — spinlock-protected list of inodes currently using this key
- `mk_decrypted_inodes_lock` — spinlock guarding the list
- `mk_active_refs` — refcount: 1 if present, +1 per inode in `mk_decrypted_inodes`
- `mk_struct_refs` — structural refcount; freed when both reach zero
- `mk_hash` — HKDF-derived key hash for v2 verification
- `mk_present` — atomic bool; cleared when secret is wiped to prevent new unlocks
- `mk_serial_number` — monotonically increasing per-key value; detects stale `fscrypt_prepared_key` references

**`struct fscrypt_key_specifier`** (`include/uapi/linux/fscrypt.h`) — identifies a master key for lookup.
- `type` — `FSCRYPT_KEY_SPEC_TYPE_DESCRIPTOR` (v1) or `FSCRYPT_KEY_SPEC_TYPE_IDENTIFIER` (v2)
- `u.descriptor[8]` / `u.identifier[16]` — the actual lookup token

**`struct fscrypt_add_key_arg`** (`include/uapi/linux/fscrypt.h`) — userspace argument to `FS_IOC_ADD_ENCRYPTION_KEY`.
- `key_spec` — which key to add
- `raw_size` — number of raw key bytes following
- `key_id` — optional kernel keyring key ID (instead of inline raw bytes)
- `flags` — `FSCRYPT_ADD_KEY_FLAG_HW_WRAPPED`

## Key Functions / Entry Points

**`fscrypt_ioctl_add_key()`** (`fs/crypto/keyring.c`) — adds a master key to `s_master_keys`; called from filesystem ioctl handlers for `FS_IOC_ADD_ENCRYPTION_KEY`.

**`fscrypt_ioctl_remove_key()`** (`fs/crypto/keyring.c`) — removes the calling user's claim; may initiate inode eviction; called for `FS_IOC_REMOVE_ENCRYPTION_KEY`.

**`fscrypt_ioctl_get_key_status()`** (`fs/crypto/keyring.c`) — returns ABSENT / PRESENT / INCOMPLETELY_REMOVED; called for `FS_IOC_GET_ENCRYPTION_KEY_STATUS`.

**`fscrypt_get_master_key()`** (`fs/crypto/keyring.c`) — looks up a key in `s_master_keys` by `fscrypt_key_specifier`; called from `fscrypt_get_encryption_info()`.

**`fscrypt_derive_key()`** (`fs/crypto/hkdf.c`) — runs HKDF-SHA512 Extract+Expand to produce a per-file key from master key + nonce; called during `fscrypt_get_encryption_info()`.

**`fscrypt_evict_inodes()`** (`fs/crypto/keyring.c`) — walks `mk_decrypted_inodes` calling `fscrypt_drop_inode()` for each; called during key removal and by the retryable eviction workqueue.

**`hkdf_expand()`** (`fs/crypto/hkdf.c`) — performs the HKDF-Expand phase; used for both per-file keys and the key identifier hash.

## Important Flags & Config Options

**`FSCRYPT_KEY_SPEC_TYPE_IDENTIFIER`** — use the cryptographic hash as the key identifier (v2; recommended).

**`FSCRYPT_KEY_SPEC_TYPE_DESCRIPTOR`** — use an 8-byte user-chosen descriptor (v1; legacy, avoid for new deployments).

**`FSCRYPT_ADD_KEY_FLAG_HW_WRAPPED`** — the provided key material is hardware-wrapped; requires inline encryption hardware and `IV_INO_LBLK_64/32` policy.

## Interactions with Other Subsystems

- **↑ Userspace**: `FS_IOC_ADD_ENCRYPTION_KEY`, `FS_IOC_REMOVE_ENCRYPTION_KEY`, `FS_IOC_GET_ENCRYPTION_KEY_STATUS` ioctls.
- **→ [[kernel-keyring|Kernel Keyring]]**: `s_master_keys` and `mk_users` use the kernel keyring subsystem for storage and garbage collection.
- **→ [[fscrypt-inode-info]]**: `fscrypt_get_master_key()` feeds into `fscrypt_get_encryption_info()`, which populates the per-inode `fscrypt_info`.
- **→ [[fscrypt-inline-encryption]]**: Hardware-wrapped keys rely on `blk_crypto_hw_wrapped_key_derive_sw_secret()` for software-secret derivation from inline encryption hardware.
- **← VFS**: Inode eviction calls `fscrypt_free_inode()`, which decrements `mk_active_refs` and removes the inode from `mk_decrypted_inodes`.

## Design Decisions & Tradeoffs

**Filesystem keyring over process keyring (v2)** — v1 stored keys in the process-subscribed session keyring (`@s`). This meant `sudo foo` would not see keys added by the unprivileged user, because `sudo` runs in a different session. The filesystem keyring is scoped to the superblock, visible to all processes regardless of UID or session. The tradeoff: the filesystem keyring does not automatically inherit keys from parent processes, so tools must explicitly add keys via the ioctl rather than inheriting them from the PAM login session.

**Per-UID reference counting** — allowing multiple users to add the same key and requiring each to remove their own entry was chosen over a simpler single-user model. This supports multi-user environments (e.g., a shared server where multiple admins encrypted the same directory). The cost is additional complexity: the INCOMPLETELY_REMOVED state arises partly because userspace might forget to close files before removing a key.

**HKDF-SHA512 over AES-128-ECB (v2)** — the v1 KDF used AES-128-ECB in a non-standard way that research showed was vulnerable to electromagnetic side-channel analysis. HKDF-SHA512 is standardised (RFC 5869), auditable, and has no known such vulnerabilities. Performance was a concern — HKDF requires two HMAC-SHA512 operations per file open — but benchmarks showed it added negligible overhead compared to the disk I/O latency.

## How It Has Evolved

| Kernel | Change |
|--------|--------|
| 4.1 | v1: session keyring storage, AES-128-ECB KDF |
| 5.4 | v2: filesystem keyring, HKDF-SHA512, key identifier hash |
| 5.7 | `FS_IOC_GET_ENCRYPTION_KEY_STATUS`, INCOMPLETELY_REMOVED state |
| 5.13 | Hardware-wrapped key support, software-secret derivation |
| 6.16 | HMAC-SHA512 library functions for HKDF; SP800-108 KDF standardisation |

## Further Reading

1. [fscrypt key management improvements (LWN)](https://lwn.net/Articles/795378/) — covers FS_IOC_GET_ENCRYPTION_KEY_STATUS and partial-removal
2. [v2 policy and filesystem keyring RFC (LWN)](https://lwn.net/Articles/737274/) — the original v2 proposal explaining the v1 shortcomings
3. [fscrypt kernel docs — key management](https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html#key-management)

## LKML Highlights

- **Filesystem keyring introduction** (`20171023214058.128121-1-ebiggers3@gmail.com`): Proposed moving from per-process keyrings to a superblock keyring. Debate: whether the kernel keyring subsystem should be extended vs. a custom implementation. Landed as a kernel keyring wrapper.
- **Key removal partial state** (`20190402154600.32432-9-ebiggers@kernel.org`): Added the `INCOMPLETELY_REMOVED` state and the per-file-key wipe-on-eviction mechanism. Key discussion: how to handle the race between `close()` and key removal without requiring userspace to close all files before calling the ioctl.
