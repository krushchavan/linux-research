---
title: "fscrypt Encryption Policy"
category: concept
tags: [fscrypt, encryption, policy, filesystem, xattr]
subsystem: fscrypt
kernel_version: "4.1"
researched: 2026-04-15
status: complete
explained: "[[fscrypt-policy-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html
  - https://lwn.net/Articles/737274/
  - https://lwn.net/Articles/727845/
---

# fscrypt Encryption Policy

> 📘 Plain-language version: [[fscrypt-policy-explained]]

## Purpose

An encryption policy is the persistent specification of *which cipher suite* and *which master key* protect a directory tree. Without a policy stored durably on the directory inode, the kernel would have no way to know which key to look up, which algorithm to apply, or how to derive the per-file subkeys when the filesystem is later remounted. The policy binds a directory to a master key for the lifetime of that directory.

## Mental Model

Think of the encryption policy as a **lock model stamped permanently on a safe**. The policy says "this safe uses AES-256-XTS, opened by key identifier X, padded to 32-byte boundaries". The actual key isn't stored anywhere in the safe — but this label tells anyone who comes along exactly what kind of key to bring. Every new item placed inside the safe automatically inherits the same label, plus its own unique serial number (the nonce) that ensures its internal mechanism differs from every other item.

## How It Works

The story begins with `FS_IOC_SET_ENCRYPTION_POLICY`. A user calls this ioctl on an empty directory, passing a `fscrypt_policy_v2` struct that specifies the cipher modes, flags, and a 16-byte `master_key_identifier`. The identifier is a cryptographic hash derived from the master key at the time it was added via `FS_IOC_ADD_ENCRYPTION_KEY` — it uniquely identifies which key to load, without embedding any secret material.

`fscrypt_ioctl_set_policy()` in `fs/crypto/policy.c` validates the request: are the cipher modes registered? Are the flags consistent? Does the identifier refer to a key already present in the filesystem keyring? If any check fails, the ioctl returns before touching disk. On success, the kernel generates a random 16-byte *nonce* via `get_random_bytes()`, packs the policy fields plus nonce into a `fscrypt_context_v2`, and writes it as the `security.fscrypt_context` xattr on the directory inode. The xattr is always written atomically by the filesystem's `setxattr` handler — in ext4 it may land inline in the inode structure or in a separate xattr block, but either way it is journal-protected.

From this moment, the directory's fate is sealed: the policy can never change. `fscrypt_ioctl_set_policy()` checks for an existing xattr and returns `EEXIST` if one is found.

**Child propagation** is handled by `fscrypt_inherit_context()`, called from each filesystem's `create()`, `mkdir()`, and `symlink()` VFS callbacks. It reads the parent's `fscrypt_context` xattr, extracts the policy fields (version, modes, flags, identifier), generates a *fresh* random nonce for the new inode, and writes the resulting context to the child's xattr before the inode is finalised. The fresh nonce is the key security property: two files under the same directory use the same master key but derive different subkeys, because `HKDF-SHA512(master_key, nonce_A, ...)` ≠ `HKDF-SHA512(master_key, nonce_B, ...)` when `nonce_A ≠ nonce_B`.

**v1 vs v2 policies** differ in how they identify the master key. v1 uses an 8-byte *descriptor* — an arbitrary human-chosen identifier that lacks any cryptographic binding to the key material. A wrong key could be added under the same descriptor and the kernel would not detect it, silently producing garbage decryption. v1 also used AES-128-ECB as its KDF, which is non-standard and was shown to be vulnerable to electromagnetic side-channel attacks in 2016 (Unterluggauer & Mangard). v2 replaced both: the identifier is a 16-byte HKDF-SHA512 digest of the key material (unforgeable), and the KDF is HKDF-SHA512 (standard, side-channel resistant). Additionally, v2 adds a key hash for post-derivation verification — after the per-file key is derived, the kernel checks the expected hash and returns `ENOKEY` if the master key is wrong, rather than silently proceeding.

**Policy flags** control IV construction and KDF bypass:
- `DIRECT_KEY`: Skip per-file KDF; use the master key directly with an IV that incorporates the 16-byte nonce. Designed for Adiantum, which needs no per-file key isolation trade-off because its security holds under the direct-key model.
- `IV_INO_LBLK_64`: Derive a single shared key for the filesystem and construct IVs as `(inode_num << 32) | data_unit_index`. Allows inline encryption hardware to share one key blob across all files.
- `IV_INO_LBLK_32`: Like `IV_INO_LBLK_64` but folds the inode number through SipHash-2-4 into a 32-bit IV, for eMMC v5.2 hardware that supports only 32-bit DUNs.

These three flags are mutually exclusive — the IV construction semantics are incompatible.

**Casefolding** (kernel 5.17+) interacts with the policy by requiring filename normalisation before encryption. When a directory has both a casefold attribute and an encryption policy, the kernel normalises the filename (Unicode NFD or NFC according to filesystem configuration) before passing it to `fscrypt_fname_encrypt()`. The ciphertext is then stored in the directory entry. This makes case-insensitive lookup work: identical logical names produce identical ciphertexts regardless of input case.

## Key Data Structures

**`struct fscrypt_policy_v2`** (`include/uapi/linux/fscrypt.h`) — the userspace-facing policy descriptor passed to `FS_IOC_SET_ENCRYPTION_POLICY`.
- `version` — must be `FSCRYPT_POLICY_V2` (2); distinguishes from v1
- `contents_encryption_mode` — e.g. `FSCRYPT_MODE_AES_256_XTS`
- `filenames_encryption_mode` — e.g. `FSCRYPT_MODE_AES_256_CTS`
- `flags` — bitmask of `FSCRYPT_POLICY_FLAG_*` constants
- `log2_data_unit_size` — 0 = use filesystem block size; 3–16 = sub-block granularity
- `master_key_identifier[FSCRYPT_KEY_IDENTIFIER_SIZE]` — 16-byte cryptographic hash identifying the master key

**`struct fscrypt_context_v2`** (`fs/crypto/fscrypt_private.h`) — on-disk form stored as `security.fscrypt_context` xattr.
- Same fields as policy_v2
- `nonce[FSCRYPT_FILE_NONCE_SIZE]` — 16-byte random value, unique per inode; the seed for per-file key derivation

**`struct fscrypt_policy_v1`** (`include/uapi/linux/fscrypt.h`) — legacy policy; `master_key_descriptor[8]` replaces the 16-byte identifier.

## Key Functions / Entry Points

**`fscrypt_ioctl_set_policy()`** (`fs/crypto/policy.c`) — validates and commits a policy to a directory's xattr; called from filesystem ioctl handlers.

**`fscrypt_ioctl_get_policy_ex()`** (`fs/crypto/policy.c`) — retrieves the v1 or v2 policy from an inode's `fscrypt_context` xattr; called by `FS_IOC_GET_ENCRYPTION_POLICY_EX`.

**`fscrypt_inherit_context()`** (`fs/crypto/policy.c`) — propagates parent policy to a newly created child inode with a fresh nonce; called by filesystem `create()`/`mkdir()`.

**`fscrypt_policy_to_key_spec()`** (`fs/crypto/policy.c`) — converts a policy's identifier or descriptor into a `fscrypt_key_specifier` for keyring lookup.

**`fscrypt_supported_algorithms()`** (`fs/crypto/policy.c`) — checks that the cipher mode combination requested by a policy is actually compiled in and valid.

## Important Flags & Config Options

**`CONFIG_FS_ENCRYPTION=y`** — compiles the entire fscrypt subsystem. Without this, no filesystem can support encryption.

**`FSCRYPT_POLICY_FLAGS_PAD_4/8/16/32`** — filename length obscuration; pad encrypted names to multiples of 4/8/16/32 bytes.

**`FSCRYPT_POLICY_FLAG_DIRECT_KEY`** — bypasses per-file KDF for Adiantum cipher. Use when the cipher's security doesn't depend on per-file key isolation.

**`FSCRYPT_POLICY_FLAG_IV_INO_LBLK_64`** — enables hardware-shared key mode for 64-bit DUN hardware. Requires filesystem with ≤2^32 inodes.

**`FSCRYPT_POLICY_FLAG_IV_INO_LBLK_32`** — enables hardware-shared key mode for 32-bit DUN hardware (legacy eMMC v5.2). Uses SipHash to fold inode numbers.

## Interactions with Other Subsystems

- **↑ Userspace**: `FS_IOC_SET_ENCRYPTION_POLICY` / `FS_IOC_GET_ENCRYPTION_POLICY_EX` ioctls on directory file descriptors.
- **→ [[fscrypt-key-management]]**: `fscrypt_policy_to_key_spec()` feeds into key lookups; `FS_IOC_SET_ENCRYPTION_POLICY` verifies the referenced key is present in `s_master_keys`.
- **→ [[fscrypt-inode-info]]**: The stored `fscrypt_context` xattr is read back at open time by `fscrypt_get_encryption_info()` to populate the per-inode `fscrypt_info`.
- **← Filesystems**: ext4, F2FS, etc. call `fscrypt_inherit_context()` during `create()`/`mkdir()` and read the `fscrypt_context` xattr during `lookup()`.

## Design Decisions & Tradeoffs

**KDF via nonce rather than wrapped random key** — The alternative was to generate a random per-file key and wrap it with the master key, storing the wrapped blob in the xattr. The nonce approach stores only 16 bytes instead of ~40 bytes (wrapped AES-256 key), reducing xattr size and the probability that ext4 cannot store the xattr inline in the inode table. The cost is that all per-file keys derive from the same master key — compromise of the master key implies compromise of all files.

**v2 identifier as hash, not user-chosen** — v1's 8-byte user-chosen descriptor let administrators name keys arbitrarily, which introduced the wrong-key problem (no verification). Making the v2 identifier a cryptographic hash of the key material means the identifier changes if the key changes, making it impossible to substitute a different key under the same identifier. The downside is that users cannot choose a memorable name — they must manage 16-byte hex blobs.

**Policy immutability** — Once set, a policy can never change. This simplifies the kernel: no migration logic, no re-encryption path, no partial-policy states. The downside is that changing cipher modes or key identifiers requires re-creating the directory and moving all files.

## How It Has Evolved

| Kernel | Change |
|--------|--------|
| 4.1 | v1 policies in ext4; AES-128-ECB KDF; 8-byte descriptor |
| 4.2 | Generalised to `fs/crypto/`; F2FS support |
| 5.4 | v2 policies: HKDF-SHA512, 16-byte identifier, key verification |
| 5.17 | Casefolding + v2 policy co-support in ext4/F2FS |
| 6.8 | `log2_data_unit_size` field in v2 for sub-block granularity |

## Further Reading

1. [fscrypt kernel documentation — policy section](https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html#setting-an-encryption-policy)
2. [v2 policy introduction with HKDF-SHA512 (LWN)](https://lwn.net/Articles/737274/)
3. [KDF improvement and key verification (LWN)](https://lwn.net/Articles/727845/)

## LKML Highlights

- **v2 policy RFC** (`20171023214058.128121-1-ebiggers3@gmail.com`): Introduced HKDF-SHA512 and the 16-byte identifier concept. Debate centred on whether a new policy version was needed or whether v1 could be extended in place. The side-channel research on AES-128-ECB was the decisive argument for a clean break.
- **Policy validation strictness** (`20190402154600.32432-1-ebiggers@kernel.org`): Tightened validation to reject inconsistent flag combinations (DIRECT_KEY + IV_INO_LBLK_64) that would produce silent IV space collisions.
