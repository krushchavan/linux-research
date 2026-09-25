---
title: "dm-crypt crypt_config — Per-Device Encryption State"
category: concept
tags: [dm-crypt, block, encryption, device-mapper, data-structures]
subsystem: dm-crypt
kernel_version: "2.5"
researched: 2026-04-18
status: complete
explained: "[[dm-crypt-crypt-config-explained]]"
sources:
  - https://kernel-internals.org/security/dm-crypt/
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html
  - https://lwn.net/Articles/42000/
---

# dm-crypt crypt_config — Per-Device Encryption State

> 📘 Plain-language version: [[dm-crypt-crypt-config-explained]]

## Purpose

`crypt_config` is the central per-device singleton in dm-crypt that holds everything needed to encrypt and decrypt I/O for a single encrypted block device: the master key, per-CPU cipher transform handles, IV generation vtable, memory pools, and workqueue references. It is allocated once when the DM target is loaded and persists until the device is torn down, making it the stable anchor around which all transient `crypt_io` request objects orbit.

## Mental Model

Think of `crypt_config` as a **fully-configured cipher factory** for one volume. Once constructed, every I/O worker thread can grab what it needs — its per-CPU cipher handle, the IV generation function, the memory pools — without locking or waiting. Correctness is guaranteed by the fact that cipher handles are per-CPU and the master key is loaded before the first bio arrives; there is no shared mutable state at I/O time.

## How It Works

### Construction via `crypt_ctr()`

When userspace calls `DM_TABLE_LOAD` with a crypt target table line, the Device Mapper core calls `crypt_ctr()`. This function is responsible for parsing the table line, allocating `crypt_config`, and preparing every resource needed for I/O.

`crypt_ctr()` begins by parsing the cipher string. The string may be in one of two formats:

- **Legacy format**: `cipher-mode-ivmode[:ivopts]`, e.g., `aes-xts-plain64`
- **CAPI format**: `capi:cipher_api_spec-ivmode[:ivopts]`, e.g., `capi:xts(aes)-plain64`

The CAPI format gives direct access to the kernel's crypto algorithm namespace, enabling authenticated modes like `capi:gcm(aes)-random`. After parsing, `crypt_ctr()` selects the IV generation operations by matching the IV mode name against a table of `crypt_iv_operations` structs.

Next, `crypt_alloc_tfms()` is called. This loops over all online CPUs and calls `crypto_alloc_skcipher(cc->cipher_string, ...)` for each, storing the resulting handles in `cc->tfms[cpu]`. The per-CPU allocation is the key design choice that eliminates locking at encryption time: each workqueue worker picks the handle for the CPU it is currently running on. For AEAD modes, `crypt_alloc_tfms_aead()` performs the analogous allocation into `cc->tfms_aead`.

The key is parsed from the table line argument — either a hex string (decoded by `crypt_decode_key()`) or a keyring reference (resolved by `crypt_get_keyring_key()`). `crypt_setkey()` then pushes the key bytes into every per-CPU cipher handle via `crypto_skcipher_setkey()`. After all handles are keyed, any staging buffer is wiped with `memzero_explicit()`.

Finally, two mempools are created:
- `cc->req_pool`: supplies `crypt_io` objects plus embedded `skcipher_request` storage (minimum 256 elements), ensuring in-flight I/Os can always be tracked even under memory pressure
- `cc->page_pool`: supplies bounce pages for ciphertext (minimum 32 pages), preventing allocation failures from stalling the encryption pipeline

The workqueues `cc->kcryptd_io` and `cc->kcryptd` are also created here as unbound high-priority work queues.

### Key loading and security

`crypt_setkey()` calls `crypto_skcipher_setkey()` on each per-CPU handle. For AES-XTS, the 64-byte key is split internally by the XTS algorithm into two 256-bit subkeys — the cipher key and the tweak key. Key schedule computation (8 rounds for AES) happens inside `setkey()`, so the per-CPU state becomes a pre-expanded key schedule rather than the raw key material.

After `setkey()` completes, `cc->key` continues to hold the raw key bytes so that new CPU hotplug events can add a new per-CPU handle and key it without asking userspace. This is a security tradeoff: the raw key lives in kernel memory for the device lifetime. `crypt_wipe_key()` calls `memzero_explicit(cc->key, cc->key_size)` to clear it on teardown, relying on the kernel's memory model to prevent dead-store elimination.

### Destruction via `crypt_dtr()`

When the DM device is removed, `crypt_dtr()` first calls `crypt_wipe_key()` to zero the in-memory key, then destroys each per-CPU skcipher handle with `crypto_free_skcipher()`, drains the mempools, and destroys the workqueues. The sequence must ensure no I/O is in flight before the cipher handles are freed — the Device Mapper core serialises this by quiescing all bios before invoking `crypt_dtr()`.

## Key Data Structures

**`struct crypt_config`** (`drivers/md/dm-crypt.c`) — per-device encryption configuration

- `cc_cipher_string` — copy of the cipher spec from the dmsetup table line; used to re-allocate handles on CPU hotplug
- `tfms` — `crypto_skcipher **`; array of per-CPU skcipher transform handles; indexed by `smp_processor_id()`
- `tfms_aead` — `crypto_aead **`; parallel array used when an AEAD cipher is selected
- `key_size` — number of raw key bytes (e.g., 64 for AES-256-XTS)
- `key[0]` — flexible array member at end of struct; holds raw master key bytes
- `iv_size` — size of the IV buffer in bytes; determined by the algorithm
- `iv_offset` — added to the bio sector number before IV generation; allows placing an encrypted partition at a non-zero offset without IV collision
- `iv_gen_ops` — pointer to `crypt_iv_operations` vtable selected by IV mode name
- `iv_gen_private` — IV-mode-specific state (e.g., the ESSIV encryption key)
- `req_pool` — mempool for `crypt_io` and `skcipher_request` objects
- `page_pool` — mempool for bounce pages
- `kcryptd_io` — unbound workqueue for read I/O submission
- `kcryptd` — unbound workqueue for encryption/decryption work
- `start` — starting sector of the DM target within the underlying device
- `tag_pool` — mempool for AEAD authentication tags (AEAD mode only)
- `integrity_tag_size` — per-sector authentication tag length in bytes (AEAD only)

## Key Functions / Entry Points

**`crypt_ctr()`** (`drivers/md/dm-crypt.c`) — DM target constructor; parses table line, allocates all resources, called by DM core on `DM_TABLE_LOAD`.

**`crypt_dtr()`** (`drivers/md/dm-crypt.c`) — DM target destructor; zeroes key, frees per-CPU handles and pools.

**`crypt_alloc_tfms()`** (`drivers/md/dm-crypt.c`) — allocates one `crypto_skcipher` per CPU using the parsed cipher string.

**`crypt_setkey()`** (`drivers/md/dm-crypt.c`) — calls `crypto_skcipher_setkey()` on each per-CPU handle; wiping the staging buffer afterward.

**`crypt_wipe_key()`** (`drivers/md/dm-crypt.c`) — zeros `cc->key` with `memzero_explicit()`; called during teardown and on explicit key wipe requests.

## Important Flags & Config Options

- `allow_discards` — passes TRIM/DISCARD requests through to the underlying device; risks leaking information about which sectors are unused (filesystem structure leakage)
- `same_cpu_crypt` — forces encryption to run on the submission CPU rather than dispatching to the workqueue; reduces cross-CPU bouncing
- `sector_size:<bytes>` — sets the encryption unit (512 to 4096); must match or be a multiple of the underlying device's logical block size
- `integrity:<tag_size>:<mode>` — enables AEAD integrity tagging with the given tag size and mode (e.g., `aead`, `hmac(sha256)`)
- `CONFIG_DM_CRYPT` — Kconfig symbol enabling the dm-crypt target

## Interactions with Other Subsystems

- **↑ Userspace**: `cryptsetup` / `dmsetup` provide the cipher string and key via the `DM_TABLE_LOAD` ioctl; key may arrive via `add_key()` syscall into the kernel keyring
- **→ [[kernel-crypto-api]]**: `crypt_config` holds handles into the Crypto API; `crypto_alloc_skcipher()` and `crypto_alloc_aead()` are the entry points
- **→ [[kernel-keyring]]**: `crypt_get_keyring_key()` resolves a keyring key reference during `crypt_ctr()` if the key argument begins with `:`
- **← [[dm-crypt-crypt-io]]**: every `crypt_io` holds a back-pointer to `crypt_config` to access the cipher handles, IV ops, and pools

## Design Decisions & Tradeoffs

**Per-CPU transform handles vs. a pool**: Using exactly one handle per CPU eliminates lock contention but increases memory proportional to CPU count. A shared pool with a mutex would use less memory but would become a bottleneck at high I/O parallelism. For cryptographic workloads, the CPU-pinned approach wins because AES-NI state (key schedule, SIMD registers) is already CPU-local.

**Raw key in kernel memory**: The raw master key lives in `cc->key` for the device's lifetime rather than being immediately discarded after `setkey()`. This allows CPU hotplug to add a new per-CPU handle at any time. The tradeoff is that a kernel memory dump exposes the key. Mitigations: key is in non-swappable kernel memory; `mlock()` semantics apply; `crypt_wipe_key()` zeroes it on unmount.

## How It Has Evolved

- **2.5 (2003)**: Initial design; single global `crypto_tfm` shared across all I/O (lock contention).
- **2.6.x**: Per-device cipher allocation; workqueue per device.
- **3.x**: Per-CPU `tfms` array to eliminate locking at encryption time.
- **4.12**: AEAD mode added `tfms_aead` array and `tag_pool` for dm-integrity integration.
- **5.9**: `no_read_workqueue` / `no_write_workqueue` flags added as `crypt_config` booleans, bypassing the workqueue dispatch for SSD performance.

## Further Reading

- [dm-crypt kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html)
- [kernel-internals.org: dm-crypt](https://kernel-internals.org/security/dm-crypt/)
- [Cloudflare: Speeding up Linux disk encryption](https://blog.cloudflare.com/speeding-up-linux-disk-encryption/)
