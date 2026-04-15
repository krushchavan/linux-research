---
title: "fscrypt Filenames Encryption"
category: concept
tags: [fscrypt, encryption, filenames, dentry, directory]
subsystem: fscrypt
kernel_version: "4.1"
researched: 2026-04-15
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html
  - https://lwn.net/Articles/811990/
---

# fscrypt Filenames Encryption

## Purpose

Even when file contents are encrypted, an attacker with the raw disk image can infer a great deal from directory entry names — project names, personal filenames, sensitive document titles. Encrypting filenames closes this information channel: directory entries appear as opaque byte strings until the key is provided. This component handles the per-directory encryption and decryption of directory entry names during all filesystem operations that involve filenames.

## Mental Model

Think of an encrypted directory as a **card catalogue where every card is written in a private cipher**. Each card still has the same physical slot (the inode), but the name printed on the card is unreadable without the cipher key. When a visitor arrives with the right key, the librarian can decrypt each card and provide the human-readable index. Without the key, the visitor can still count the cards and flip through them — they just see opaque sequences of bytes. The cipher is the same for all cards in a given catalogue room (same directory), but each room has its own cipher key derived from the building's master key.

## How It Works

Every encrypted directory has a *filenames key* derived from the master key and the directory's inode nonce (using a separate HKDF info label from the contents key). This means two encrypted directories under the same master key use different filenames keys — an attacker cannot correlate filename ciphertexts across directories.

**Encryption** happens at file creation time. When a process calls `open(..., O_CREAT)`, `mkdir()`, or `symlink()`, the filesystem's VFS callback calls `fscrypt_fname_encrypt()` (`fs/crypto/fname.c`) on the filename before writing it to the directory block. `fscrypt_fname_encrypt()` first applies padding: filenames shorter than 16 bytes are NUL-padded to 16 bytes; all filenames receive additional NUL-padding to the next configured boundary (4, 8, 16, or 32 bytes, set by `FSCRYPT_POLICY_FLAGS_PAD_*`). This length obscuration makes it harder to distinguish a 3-character filename from a 7-character one after encryption. The padded buffer is then fed to `crypto_skcipher_encrypt()` with the filenames key and an IV derived from the directory's encryption context.

The IV for filename encryption uses the *same* value for all entries within a directory (typically all-zeroes, or incorporating the inode number for `IV_INO_LBLK_64` policies). This is a deliberate trade-off: using per-filename IVs would require storing them somewhere, adding per-entry overhead. The security impact is that two identical filenames in the same directory produce identical ciphertexts — but since filenames are encrypted atomically (not in block chunks), and the plaintext space is enormous relative to the number of files in a directory, this is acceptable in practice.

**Cipher choice** matters for filenames: AES-256-CTS (Ciphertext Stealing) is the standard choice, but CTS requires the input to be at least one block (16 bytes). After padding, all filenames meet this requirement. AES-256-HCTR2 (a length-preserving cipher introduced in kernel 6.0) can handle filenames of any length without padding overhead, making it attractive for systems where metadata overhead is a concern.

**Lookup** is the most performance-critical path. When `lookup()` is called, the kernel does not know in advance whether the directory has a key loaded. `fscrypt_setup_filename()` (`fs/crypto/fname.c`) handles both cases:

*With key*: The provided plaintext filename is encrypted using `fscrypt_fname_encrypt()`, and the resulting ciphertext is used as the search key for the directory entry lookup. This is fast — one encryption call per lookup.

*Without key (no-key names)*: If no key is loaded, fscrypt cannot encrypt the name. Instead, for listing (`getdents()`), it Base64url-encodes each ciphertext entry name and returns the encoded form to userspace. The kernel recognises these no-key names: a subsequent `open()` or `stat()` passing back such a name goes through `fscrypt_setup_filename()` which detects the Base64url encoding, decodes the ciphertext, and searches for it directly in the directory. This allows userspace tools to enumerate and operate on encrypted files by name even without the key — they just see opaque, stable identifiers rather than human-readable names.

**Long filename handling**: After encryption and Base64url encoding, a filename might exceed the filesystem's maximum dentry name length (typically 255 bytes). AES-256-CTS ciphertext is the same length as the plaintext; Base64url adds ~4/3 overhead. A 187-byte filename becomes 250 bytes after encoding — still within limits. But names longer than ~185 bytes overflow. For these, fscrypt uses a **strong hash** approach: the first part of the Base64url-encoded ciphertext is stored in the dentry name slot, and the full ciphertext is stored in a separate extended attribute. On lookup, both the abbreviated dentry and the full xattr are verified using SipHash. The `fscrypt_nokey_name` struct on the stack carries the hash and the partial ciphertext during the lookup.

**Symlinks** are handled specially: the target path of an encrypted symlink is stored as ciphertext in the symlink target field. `fscrypt_encrypt_symlink()` encrypts the target at creation time; `fscrypt_get_symlink()` decrypts it at readlink time. If the key is unavailable, readlink returns the Base64url-encoded ciphertext.

**Casefolding interaction** (kernel 5.17+): In directories with both encryption and casefolding enabled, filenames are first Unicode-normalised (NFD or NFC according to filesystem settings), then encrypted. The normalisation is deterministic, so "Café" and "café" both normalise to the same form before encryption, producing the same ciphertext. This makes case-insensitive lookup work without decrypting all directory entries.

`fscrypt_free_filename()` is called after each lookup to free any buffers allocated by `fscrypt_setup_filename()`.

## Key Data Structures

**`struct fscrypt_str`** (`include/linux/fscrypt.h`) — a mutable string buffer passed between fscrypt and filesystem code.
- `name` — pointer to the name buffer (plaintext or ciphertext depending on context)
- `len` — current length of the name

**`struct fscrypt_name`** (`include/linux/fscrypt.h`) — setup by `fscrypt_setup_filename()`; contains both the disk name (for search) and the crypto buffer.
- `usr_fname` — the original userspace-provided name
- `disk_name` — the name as it appears on disk (encrypted, or original if unencrypted directory)
- `crypto_buf` — allocated buffer holding encrypted name; freed in `fscrypt_free_filename()`
- `is_nokey_name` — true if this is a no-key Base64url name

**`struct fscrypt_nokey_name`** (`fs/crypto/fname.c`) — on-stack representation of a no-key filename.
- `dirhash[2]` — `u32[2]`; directory hash for filesystems that hash dentry names
- `bytes[FSCRYPT_NOKEY_NAME_MAX]` — Base64url-encoded ciphertext

## Key Functions / Entry Points

**`fscrypt_fname_encrypt()`** (`fs/crypto/fname.c`) — encrypts a plaintext filename with the directory's filenames key; called during file creation and rename.

**`fscrypt_fname_decrypt()`** (`fs/crypto/fname.c`) — decrypts a ciphertext dentry name; called during directory listing with an active key.

**`fscrypt_setup_filename()`** (`fs/crypto/fname.c`) — top-level entry point for lookup; encrypts the target name if the key is present, or parses a no-key name if not; called from filesystem `lookup()`.

**`fscrypt_free_filename()`** (`include/linux/fscrypt.h`) — frees the `crypto_buf` allocated by `fscrypt_setup_filename()`.

**`fscrypt_match_name()`** (`include/linux/fscrypt.h`) — compares a dentry name to a search target (handles both keyed and no-key cases); called from filesystem `dir_entry` matching code.

**`fscrypt_encrypt_symlink()`** (`fs/crypto/symlink.c`) — encrypts a symlink target at creation time.

**`fscrypt_get_symlink()`** (`fs/crypto/symlink.c`) — decrypts or returns no-key name for symlink target at readlink time.

## Important Flags & Config Options

**`FSCRYPT_POLICY_FLAGS_PAD_4/8/16/32`** — pad encrypted filenames to the next multiple of 4/8/16/32 bytes. 32-byte padding provides the best length obscuration; 4-byte padding minimises overhead.

**`FSCRYPT_MODE_AES_256_CTS`** — standard filename encryption cipher; CBC with ciphertext stealing; minimum input 16 bytes.

**`FSCRYPT_MODE_AES_256_HCTR2`** — length-preserving wide-block cipher; no padding needed; introduced kernel 6.0.

**`FSCRYPT_MODE_ADIANTUM`** — used for filenames on ARM devices without AES hardware; same cipher as for contents.

## Interactions with Other Subsystems

- **↑ Userspace**: `getdents()` returns encrypted (Base64url) names when key absent; `open()`/`stat()`/`rename()` accept both plaintext and no-key names.
- **→ [[fscrypt-inode-info]]**: `ci_enc_key` provides the filenames cipher transform for the directory.
- **→ [[kernel-crypto-api|Kernel Crypto API]]**: `fscrypt_fname_encrypt()` uses `crypto_skcipher_encrypt()` with the filenames key transform.
- **← Filesystems**: ext4, F2FS, UBIFS call `fscrypt_setup_filename()` during `lookup()` and `fscrypt_fname_encrypt()` during `create()`/`mkdir()`.

## Design Decisions & Tradeoffs

**Shared per-directory IV** — All filenames in a directory share the same IV (or an IV derived only from the directory, not from the individual name). Using per-filename random IVs would require storing them, increasing per-entry overhead. The security impact is minimal because the filenames key is already per-directory (different directories use different keys), so cross-directory correlation is still infeasible.

**No-key names as stable identifiers** — Exposing Base64url-encoded ciphertexts as no-key names was a deliberate usability choice: tools like `backup` can enumerate and copy files by stable opaque names even without the key. The alternative (returning errors for directory listing without key) would break backup tools and similar utilities that should not require key access.

**Length obscuration via padding** — Padding to power-of-two boundaries was chosen over storing arbitrary-length encrypted names because it's simple, deterministic, and avoids variable-length xattr overhead. The tradeoff is limited granularity: a 1-byte and a 15-byte filename both encrypt to a 16-byte ciphertext, indistinguishable in length. But a 1-byte and a 17-byte filename are distinguishable (16 vs 32 bytes) with 16-byte padding.

## How It Has Evolved

| Kernel | Change |
|--------|--------|
| 4.1 | AES-256-CTS filenames encryption in ext4 |
| 5.17 | Casefolding + encryption co-support; normalisation before encryption |
| 6.0 | HCTR2 cipher for length-preserving filename encryption |

## Further Reading

1. [fscrypt kernel docs — filenames encryption](https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html#filenames-encryption)
2. [Casefolding and encryption (LWN)](https://lwn.net/Articles/811990/) — Unicode normalisation interaction with filename encryption

## LKML Highlights

- **No-key name design** (`20180911204516.23020-1-ebiggers@kernel.org`): Introduced the no-key name concept. Debate: should encrypted directories be completely opaque without the key (return errors) or provide stable no-key names? The backup/sync tooling use case drove the decision to provide stable names.
- **HCTR2 addition** (`20211126082857.487988-1-ebiggers@google.com`): Added HCTR2 as a length-preserving alternative to CTS. Key argument: HCTR2 avoids all padding overhead and is a proven wide-block construction; CTS requires ≥16-byte input which forced the padding requirement.
