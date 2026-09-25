---
title: "dm-crypt Crypto API Integration — skcipher and AEAD"
category: concept
tags: [dm-crypt, encryption, crypto-api, aead, skcipher, block]
subsystem: dm-crypt
kernel_version: "2.5"
researched: 2026-04-18
status: complete
explained: "[[dm-crypt-crypto-api-integration-explained]]"
sources:
  - https://kernel-internals.org/security/dm-crypt/
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html
  - https://static.lwn.net/kerneldoc/crypto/api-aead.html
  - https://blog.cloudflare.com/speeding-up-linux-disk-encryption/
---

# dm-crypt Crypto API Integration — skcipher and AEAD

> 📘 Plain-language version: [[dm-crypt-crypto-api-integration-explained]]

## Purpose

dm-crypt delegates all cryptographic computation to the [[kernel-crypto-api]] rather than implementing any cipher logic itself. The integration layer selects the appropriate API surface (skcipher for standard modes, AEAD for authenticated modes), allocates and keys per-CPU transform handles, and handles both synchronous and asynchronous crypto completion. This abstraction means dm-crypt automatically benefits from hardware acceleration (AES-NI, ARMv8 Crypto Extensions, dedicated offload engines) without knowing anything about the underlying implementation.

## Mental Model

The Kernel Crypto API is a **plug-in cipher registry**: algorithm implementations (software AES, AES-NI, hardware engine) register themselves, and consumers like dm-crypt call `crypto_alloc_skcipher("xts(aes)", ...)` to receive the best available implementation for the current CPU. dm-crypt's integration layer is the code that allocates these handles, keys them, constructs per-bio requests, submits them, and handles completion — acting as a thin translation layer between the block-bio world and the crypto-request world.

## How It Works

### Two API surfaces: skcipher and AEAD

dm-crypt uses the Kernel Crypto API through two abstract interfaces, selected based on the cipher string prefix:

**`crypto_skcipher`** handles all length-preserving cipher modes: CBC, XTS, LRW, etc. These modes encrypt `n` bytes of plaintext into exactly `n` bytes of ciphertext — a requirement for block devices where sector size is fixed and non-negotiable. `crypt_alloc_tfms()` allocates one `crypto_skcipher *` per CPU using the cipher string as the algorithm name. The Crypto API's algorithm selection logic resolves the name against all registered implementations and returns the highest-priority match. On x86 with AES-NI, `xts(aes)` resolves to the hardware-accelerated `xts(aes-aesni)` implementation. On ARM with crypto extensions, it resolves to the ARM-specific AES-CE path.

**`crypto_aead`** handles authenticated encryption modes like GCM, ChaCha20-Poly1305, and `authenc(HMAC-SHA256, XTS-AES)`. AEAD modes produce a ciphertext plus an authentication tag — the tag is a MAC over the ciphertext that detects any tampering. For disk encryption this is critical: without authentication, an attacker with physical write access can flip bits in the ciphertext and the decrypted plaintext will be silently corrupted in a predictable, exploitable way. `crypt_alloc_tfms_aead()` performs the analogous per-CPU allocation using `crypto_alloc_aead()`.

### Per-CPU handle allocation

`crypt_alloc_tfms()` iterates `for_each_possible_cpu()` and calls:

```c
cc->tfms[cpu] = crypto_alloc_skcipher(cc->cipher_string, 0, CRYPTO_ALG_ASYNC);
```

The `CRYPTO_ALG_ASYNC` flag allows the Crypto API to return an asynchronous implementation (one that returns `-EINPROGRESS` rather than completing inline). Without this flag, only synchronous implementations are eligible. In practice, AES-NI is synchronous, so this flag mainly matters for dedicated hardware crypto accelerators.

After allocation, each handle is keyed via `crypto_skcipher_setkey(cc->tfms[cpu], cc->key, cc->key_size)`. This computes the AES key schedule (10/12/14 rounds for AES-128/192/256) and stores the expanded round keys inside the transform state — so that each subsequent `encrypt()` call need not re-expand the key. For XTS, the key is split: the first half keys the data cipher and the second half keys the tweak cipher. All of this happens inside the Crypto API implementation; dm-crypt passes the full 64-byte key and the XTS implementation handles the split.

### Per-bio request construction

For each bio, `crypt_convert()` submits one `skcipher_request` per sector (or per AEAD block). The request is allocated from a per-CPU embedded buffer that is part of the `crypt_io` allocation — again avoiding a separate mempool call. The request is initialised:

```c
skcipher_request_set_tfm(req, cc->tfms[cpu]);
skcipher_request_set_crypt(req, src_sg, dst_sg, cc->sector_size, iv);
skcipher_request_set_callback(req, CRYPTO_TFM_REQ_MAY_BACKLOG,
                               kcryptd_async_done, dmreq);
```

`src_sg` and `dst_sg` are scatter-gather lists pointing to the bio's pages. For writes, `src_sg` is the plaintext page from the original bio and `dst_sg` is a bounce page from `cc->page_pool` (because the cipher cannot encrypt in-place for some algorithms). For reads, `src_sg` and `dst_sg` both point to the same bio page (decrypt in-place is allowed by most skcipher implementations).

### Synchronous vs. asynchronous completion

`crypto_skcipher_encrypt(req)` returns:
- `0` — completed synchronously; the result is in `dst_sg` immediately
- `-EINPROGRESS` — hardware accepted the request; `kcryptd_async_done` will be called when done
- `-EBUSY` — hardware queue is full; the request is queued with `CRYPTO_TFM_REQ_MAY_BACKLOG` semantics

For AES-NI, the return is always 0. The cipher runs directly in the calling thread using SIMD instructions; no interrupt or callback is involved. This is why bypassing the workqueue (`no_write_workqueue`) is so effective on AES-NI systems: the "async" workqueue path adds overhead for what is in reality a synchronous, in-CPU operation.

For hardware offload engines (e.g., Intel QuickAssist, Marvell CESA), `-EINPROGRESS` is normal. The callback `kcryptd_async_done()` updates the `convert_context` position and continues `crypt_convert()` for the next sector.

### AEAD and dm-integrity interaction

When an AEAD cipher is configured, `crypt_convert()` uses `crypto_aead_encrypt()` instead of `crypto_skcipher_encrypt()`. The AEAD request includes an additional output buffer for the authentication tag (typically 16 bytes for GCM or Poly1305). dm-crypt writes this tag into a per-sector area allocated from `cc->tag_pool`.

The tags are not stored inline in the data area — that would change the apparent size of the device. Instead, dm-crypt attaches the tags to the bio via `bio_integrity_payload(bio)`. The dm-integrity target, which must be stacked below dm-crypt in this configuration, intercepts these integrity payloads and stores/verifies them in a separate on-disk journal region. On a read, if `crypto_aead_decrypt()` returns `-EBADMSG` (tag mismatch), the bio is failed with `-EIO` — the filesystem above sees an I/O error rather than silently corrupt plaintext.

## Key Data Structures

**`struct crypto_skcipher`** (Kernel Crypto API) — opaque handle to a keyed symmetric cipher transform; one instance per CPU in `cc->tfms[]`.

**`struct skcipher_request`** (`include/crypto/skcipher.h`) — per-encryption request context:
- `tfm` — pointer to the per-CPU `crypto_skcipher` handle
- `src` — scatter-gather list of input (plaintext for encrypt, ciphertext for decrypt)
- `dst` — scatter-gather list of output
- `iv` — pointer to the IV buffer populated by the IV generation component
- `cryptlen` — number of bytes to process (one sector = 512 or 4096 bytes)
- `base.complete` — callback invoked on async completion; set to `kcryptd_async_done`

**`struct aead_request`** (`include/crypto/aead.h`) — analogous to `skcipher_request` for AEAD; adds `authsize` and an `assocdata` scatter-gather for associated data (unused by dm-crypt; sectors have no associated data).

## Key Functions / Entry Points

**`crypt_alloc_tfms()`** (`drivers/md/dm-crypt.c`) — allocates and keys per-CPU skcipher handles; called during `crypt_ctr()`.

**`crypt_alloc_tfms_aead()`** — analogous for AEAD mode.

**`crypto_alloc_skcipher(name, type, mask)`** (Kernel Crypto API) — allocates the best matching cipher implementation from the algorithm registry.

**`crypto_skcipher_setkey(tfm, key, keylen)`** — computes and stores the key schedule.

**`crypto_skcipher_encrypt(req)`** / **`crypto_skcipher_decrypt(req)`** — perform one encrypt/decrypt operation; called per-sector in `crypt_convert()`.

**`crypto_aead_encrypt(req)`** / **`crypto_aead_decrypt(req)`** — authenticated encrypt/decrypt; called per-sector in AEAD mode.

**`kcryptd_async_done()`** (`drivers/md/dm-crypt.c`) — async completion callback; re-queues `crypt_io` work if more sectors remain.

## Important Flags & Config Options

- `CRYPTO_ALG_ASYNC` — passed to `crypto_alloc_skcipher()` to allow async implementations
- `CRYPTO_TFM_REQ_MAY_BACKLOG` — tells the hardware queue to accept requests even when at capacity, queuing them internally
- `capi:` prefix in the cipher string — use the Kernel Crypto API namespace directly; enables AEAD modes like `capi:gcm(aes)-random`
- `CONFIG_CRYPTO_AES_NI_INTEL` / `CONFIG_CRYPTO_AES_ARM64` — hardware AES implementations; enables near-zero-overhead encryption

## Interactions with Other Subsystems

- **← [[dm-crypt-crypt-config]]**: `crypt_config` holds the per-CPU `tfms` and `tfms_aead` arrays and the cipher string used for allocation
- **← [[dm-crypt-crypt-io]]**: `crypt_convert()` (within `crypt_io` processing) constructs and submits `skcipher_request` objects
- **← [[dm-crypt-iv-generation]]**: the IV buffer populated by IV generation is passed to `skcipher_request_set_crypt()`
- **→ [[kernel-crypto-api]]**: dm-crypt calls only public Crypto API functions; the algorithm selection, hardware dispatch, and SIMD management are entirely inside the Crypto API
- **→ [[dm-integrity]]**: in AEAD mode, per-sector authentication tags are passed to dm-integrity via `bio_integrity_payload`

## Design Decisions & Tradeoffs

**Using the Crypto API as a black box**: dm-crypt deliberately avoids calling any cipher-specific functions. This means hardware acceleration, algorithm negotiation, and SIMD context management are handled inside the Crypto API without dm-crypt knowing. The tradeoff is that dm-crypt cannot fine-tune cipher operation for specific hardware; it must rely on the Crypto API's priority system to select the best implementation.

**Per-CPU handles vs. a transform pool**: A pool of `N` transforms (where `N` is less than the CPU count) would reduce memory usage but introduce lock contention when multiple CPUs compete for handles. Per-CPU handles eliminate contention at the cost of memory. For cryptographic workloads where the key schedule is large (AES-256 = 240 bytes of round key material), this matters but is acceptable.

**Bounce pages for encryption**: Many skcipher implementations cannot encrypt in-place (src == dst) due to alignment or aliasing constraints. dm-crypt allocates a bounce page from `cc->page_pool` for the ciphertext output on write paths. On read paths, in-place decryption is generally safe and bounce pages are not needed, saving one memory allocation per sector.

## How It Has Evolved

- **2.5 (2003)**: Initial crypto integration via the old `crypto_tfm` interface; single shared transform
- **2.6.x**: Migration to `crypto_blkcipher` API as it replaced `crypto_tfm` for block ciphers
- **4.x**: Migration to `crypto_skcipher` API (replaced `crypto_blkcipher`); per-CPU handle allocation
- **4.12**: AEAD support added; `crypto_aead` handles and `aead_request` allocation
- **5.9**: Cloudflare's synchronous path (`no_*_workqueue`) makes it clear that AES-NI is always synchronous, exposing the workqueue as pure overhead for that hardware class

## Further Reading

- [Kernel Crypto API — AEAD Interface](https://static.lwn.net/kerneldoc/crypto/api-aead.html)
- [Cloudflare: Speeding up Linux disk encryption](https://blog.cloudflare.com/speeding-up-linux-disk-encryption/)
- [dm-crypt kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html)
