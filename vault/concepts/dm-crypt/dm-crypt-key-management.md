---
title: "dm-crypt Key Management — Keyring, LUKS2, and Trusted Keys"
category: concept
tags: [dm-crypt, key-management, keyring, luks2, tpm, encryption, security]
subsystem: dm-crypt
kernel_version: "2.5"
researched: 2026-04-18
status: complete
sources:
  - https://kernel-internals.org/security/dm-crypt/
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html
  - https://lwn.net/Articles/870194/
  - https://en.wikipedia.org/wiki/Linux_Unified_Key_Setup
  - https://wiki.archlinux.org/title/Dm-crypt/Device_encryption
---

# dm-crypt Key Management — Keyring, LUKS2, and Trusted Keys

## Purpose

dm-crypt receives raw key material from userspace and uses it to key its per-CPU cipher handles. The key management layer covers two distinct concerns: (1) how the raw key bytes reach the kernel safely and (2) how those bytes are derived and protected in userspace via LUKS2. The kernel's job is limited to receiving a key, loading it into cipher handles, and wiping it on teardown. All key derivation, passphrase handling, and on-disk format management happen in userspace via `cryptsetup`.

## Mental Model

The boundary between userspace and kernel key management is sharp: the kernel knows only "here are N bytes of key material for an AES cipher". It never handles passphrases, key derivation functions, or on-disk header formats. LUKS2 is a userspace format that produces those N bytes; the `trusted` and `encrypted` key types are kernel mechanisms that shield those bytes from ever appearing in plaintext userspace memory. The kernel's key management role is primarily *protection in flight* (secure loading) and *protection at rest* (secure zeroing).

## How It Works

### Direct hex key specification

The simplest mechanism passes the key as a hexadecimal string in the `dmsetup` table line:

```
0 1953125 crypt aes-xts-plain64 babecafe... 0 /dev/sda 0
```

`crypt_ctr()` calls `crypt_decode_key()` to parse the hex string into `cc->key`. This is straightforward but dangerous: the table line may appear in `/proc/*/dm/*/table`, kernel audit logs, or shell history. `cryptsetup` avoids this path in production by using the `--key-file` or keyring methods; the direct hex path is used only for testing or by tools that manage key security externally.

### Kernel keyring integration

The production path passes a keyring *reference* instead of the raw key bytes. The reference format is:

```
:<key_size_bytes>:<key_type>:<key_description>
```

For example: `:64:logon:cryptsetup:my-volume-uuid`.

`crypt_ctr()` detects the leading colon and calls `crypt_get_keyring_key()`, which calls:

```c
key = request_key(&key_type_logon, "cryptsetup:my-volume-uuid", NULL);
```

`request_key()` searches the calling process's keyrings (session → process → user → system) for a key matching the type and description. If found, the key's payload (the raw key bytes) is copied into `cc->key`. Supported key types:

- **`logon`**: kernel session key — stored in kernel memory, accessible only within the session; most common for LUKS usage
- **`user`**: user keyring — similar to logon but tied to the user's UID
- **`trusted`**: TPM-backed key — raw bytes never appear in userspace; key is sealed to a TPM PCR measurement (boot state); unsealed by the TPM only when the PCR matches
- **`encrypted`**: kernel-managed encrypted key — the key is stored encrypted under a master key on disk; the master key may itself be a trusted key; allows offline storage of encrypted volume keys

With `trusted` and `encrypted` key types, the actual AES master key never exists in plaintext userspace memory — it is delivered directly from the TPM or decrypted inside the kernel. This closes the attack window where a compromised userspace process could read `/proc/<pid>/mem` or use `ptrace` to extract the key after LUKS opens the volume.

### LUKS2 — on-disk key management format

LUKS2 (Linux Unified Key Setup, version 2) is a userspace format managed entirely by `cryptsetup`. It structures the encrypted device into zones:

1. **Binary header** (4 KB): magic bytes (`LUKS\xba\xbe`), version (2), header size, sequence number, and the JSON area checksum.
2. **JSON metadata area** (variable, default 16 KB): a JSON object describing keyslots, segments (which areas of the device are encrypted and with which cipher), digests (verification hashes), and tokens (external keyslot handlers like TPM2 or FIDO2 modules).
3. **Keyslot area** (~16 MB default): stores the volume master key, encrypted by passphrase-derived keys, split across multiple keyslots.
4. **Encrypted data area**: the actual filesystem content, encrypted with the volume master key starting at a configurable offset.

#### Keyslot key derivation

Each LUKS2 keyslot contains a copy of the volume master key, encrypted under a *keyslot key* derived from a passphrase. The key derivation uses either:

- **PBKDF2** (Password-Based Key Derivation Function 2): HMAC-SHA256 with a configurable iteration count; iteration count is tuned to consume ~1 second on the target machine; resistant to brute force on CPUs but vulnerable to GPU parallelism.
- **Argon2id** (default in modern `cryptsetup`): memory-hard KDF; requires a large working memory (default 64 MB) per attempt; GPU parallelism becomes impractical because each GPU thread needs 64 MB of RAM. This is the recommended choice against offline brute-force.

The derived keyslot key is used to decrypt the keyslot's encrypted master key copy. The master key is stored using AFsplitter:

#### AFsplitter anti-forensic key splitting

AFsplitter (Anti-Forensics Splitter) splits the master key into `N` stripes (default 4000). Each stripe is one key-size block. The stripes are derived from the master key using a hash chain, so that recovering the master key requires *all* stripes. If any stripe is overwritten or erased, the master key is unrecoverable — even with the passphrase. This enables secure key slot destruction: overwriting just the keyslot's stripe area (a few kilobytes) cryptographically destroys that passphrase's access path without touching the encrypted data or other keyslots.

#### Key verification

LUKS2 includes a *digest* — a PBKDF2-derived verification hash of the master key — that lets `cryptsetup` confirm the correct key was derived before attempting to mount the volume. Without this, a wrong passphrase would produce a garbage master key, and the volume would appear to mount but return corrupt data. The digest fails fast before the DM target is loaded.

### Key loading flow end-to-end

A typical boot sequence with LUKS2 and a passphrase:

1. `systemd-cryptsetup` (or `cryptsetup open`) is invoked with the LUKS2 device and passphrase.
2. `cryptsetup` reads the LUKS2 JSON header.
3. Argon2id derives the keyslot key from the passphrase + per-keyslot salt.
4. The keyslot ciphertext is decrypted using the keyslot key.
5. AFsplitter reassembles the master key from its stripes.
6. The master key is verified against the LUKS2 digest.
7. `cryptsetup` calls `add_key(KEY_SPEC_SESSION_KEYRING, "logon", master_key, key_size, "cryptsetup:uuid")` to load the key into the session keyring.
8. `cryptsetup` calls `dmsetup create` with the crypt table line using a keyring reference.
9. The kernel calls `crypt_ctr()`, which calls `request_key()` to retrieve the key and loads it into the per-CPU cipher handles.
10. The raw key is zeroed from the userspace buffer immediately after `add_key()`.

For TPM2-bound volumes (using `systemd-cryptenroll --tpm2-device=auto`):

- Step 3 is replaced by a TPM2 unsealing operation. The volume master key is stored sealed in the TPM against PCR values representing the expected boot state (secure boot policy, kernel signature).
- If PCR values match (trusted boot chain), the TPM releases the key directly to the kernel's `trusted` key store, never passing through userspace.

### Key protection in kernel memory

Once `crypt_setkey()` loads the key into per-CPU cipher handles, the raw key bytes sit in `cc->key`. The kernel does not swap kernel memory to disk, so the key is not exposed via swap. However, hibernation (`/sys/power/state = disk`) writes RAM to a swap partition in plaintext — a known limitation. `CONFIG_ENCRYPTED_HIBERNATION` is under development to address this.

`crypt_wipe_key()` uses `memzero_explicit(cc->key, cc->key_size)` which uses a compiler barrier to prevent the optimizer from removing the zeroing as a dead store. However, the key may remain in CPU caches after wiping; on cold-boot attacks, hardware memory initialization prevents practical key recovery from DRAM within a few seconds of power removal.

## Key Data Structures

**`struct key`** (`include/linux/key.h`) — kernel keyring entry:
- `type` — `&key_type_logon`, `&key_type_trusted`, `&key_type_encrypted`, etc.
- `payload.data` — opaque key material; accessed via `key_payload_reserve()` for type-specific access

**LUKS2 JSON object** (userspace, `cryptsetup`) — on-disk metadata:
- `keyslots` — indexed object; each keyslot has `type` (pbkdf2/argon2id), `kdf` parameters, encrypted key material
- `segments` — defines the encrypted data region(s); `encryption` field specifies the cipher string
- `digests` — verification hash of the master key
- `tokens` — external keyslot handlers (TPM2, FIDO2, systemd-tpm2)

## Key Functions / Entry Points

**`crypt_get_keyring_key()`** (`drivers/md/dm-crypt.c`) — called from `crypt_ctr()` when the key argument starts with `:` ; calls `request_key()` and copies the payload into `cc->key`.

**`crypt_decode_key()`** (`drivers/md/dm-crypt.c`) — called from `crypt_ctr()` for direct hex key arguments; parses hex string into `cc->key`.

**`crypt_setkey()`** (`drivers/md/dm-crypt.c`) — calls `crypto_skcipher_setkey()` on each per-CPU handle with the contents of `cc->key`.

**`crypt_wipe_key()`** (`drivers/md/dm-crypt.c`) — zeroes `cc->key` with `memzero_explicit()`; called from `crypt_dtr()` and on explicit wipe requests.

**`request_key()`** (`security/keys/request_key.c`) — kernel keyring API; searches process keyrings for a matching key.

## Important Flags & Config Options

- `CONFIG_TRUSTED_KEYS` — enables `trusted` key type (TPM-backed keys)
- `CONFIG_ENCRYPTED_KEYS` — enables `encrypted` key type (kernel-decrypted stored keys)
- `CONFIG_KEY_DH_OPERATIONS` — optional; enables Diffie-Hellman key operations in the keyring subsystem
- `--pbkdf=argon2id` / `--pbkdf=pbkdf2` in `cryptsetup luksFormat` — selects the KDF for new keyslots
- `--pbkdf-memory=`, `--pbkdf-time=` — Argon2id tuning parameters

## Interactions with Other Subsystems

- **← [[dm-crypt-crypt-config]]**: `crypt_config` stores `cc->key` and provides `crypt_get_keyring_key()` / `crypt_setkey()` calls during `crypt_ctr()`
- **→ [[kernel-keyring]]**: `request_key()` is the bridge between dm-crypt and the kernel keyring subsystem; supports logon, user, trusted, and encrypted key types
- **→ [[kernel-crypto-api]]**: the loaded key bytes are passed to `crypto_skcipher_setkey()` which implements the cipher-specific key schedule
- **↑ Userspace**: `cryptsetup` manages LUKS2 header parsing, KDF execution, AFsplitting, and key injection via `add_key()` + `DM_TABLE_LOAD`

## Design Decisions & Tradeoffs

**Separation of key format from encryption**: The kernel knows nothing about LUKS2, Argon2id, or AFsplitter. These are entirely userspace concerns. The kernel only sees raw key bytes. This clean separation allows the key format to evolve independently (LUKS1 → LUKS2, new KDFs) without kernel changes. The tradeoff is that the kernel cannot enforce KDF strength — a poorly configured `cryptsetup` can use a weak KDF without the kernel knowing.

**Trusted keys for TPM binding**: Using `trusted` key type means the volume master key is never in userspace memory, eliminating the risk of a userspace exploit extracting the key after volume open. The downside is complexity: TPM PCR binding means the volume becomes unrecoverable if the boot configuration changes (kernel update, firmware change), unless the operator has provisioned a recovery keyslot with a passphrase.

**`memzero_explicit` vs. ordinary zero**: Compilers optimize away writes to memory that is never subsequently read (dead-store elimination). `memzero_explicit` uses a compiler barrier to prevent this, ensuring the key bytes actually reach memory before the function returns. This protection is necessary because the key in `cc->key` is sensitive even after the per-CPU cipher handles are keyed.

## How It Has Evolved

- **2.5 (2003)**: Direct hex key only; no keyring support
- **LUKS (2004)**: `cryptsetup` introduced LUKS1 format on-disk; AFsplitter and PBKDF2 for passphrase-based key derivation (userspace only)
- **3.x**: Kernel keyring integration added; `logon` and `user` key types supported
- **4.x**: `trusted` and `encrypted` key types added, enabling TPM-backed key delivery
- **LUKS2 (2018, cryptsetup 2.0)**: Argon2id KDF, extended JSON metadata, multiple segments, hardware token support (FIDO2, TPM2)
- **5.x+**: `systemd-cryptenroll` provides ergonomic TPM2 binding for systemd-managed volumes; enrolled keys stored as LUKS2 tokens

## Further Reading

- [dm-crypt kernel documentation — key specification](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html)
- [Authenticated Boot and Disk Encryption on Linux — LWN](https://lwn.net/Articles/870194/) — Poettering's proposal for TPM-bound authenticated disk encryption
- [Linux Unified Key Setup — Wikipedia](https://en.wikipedia.org/wiki/Linux_Unified_Key_Setup) — LUKS2 structure overview
- [ArchWiki: dm-crypt/Device encryption](https://wiki.archlinux.org/title/Dm-crypt/Device_encryption) — practical key management workflows
