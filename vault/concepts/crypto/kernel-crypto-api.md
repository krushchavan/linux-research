---
title: "Kernel Crypto API"
category: concept
tags: [crypto, encryption, kernel-api, scatterlist, hardware-acceleration]
subsystem: crypto
kernel_version: "2.5.45"
researched: 2026-04-17
status: complete
explained: "[[kernel-crypto-api-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/crypto/architecture.html
  - https://www.kernel.org/doc/html/latest/crypto/api-intro.html
  - https://www.kernel.org/doc/html/latest/crypto/devel-algos.html
  - https://www.kernel.org/doc/html/latest/crypto/crypto_engine.html
  - https://static.lwn.net/kerneldoc/crypto/architecture.html
  - https://lwn.net/Articles/770750/
  - https://lwn.net/Articles/619972/
  - https://blog.cloudflare.com/the-linux-crypto-api-for-user-applications/
  - https://www.linuxjournal.com/article/6451
---

# Kernel Crypto API

> 📘 Plain-language version: [[kernel-crypto-api-explained]]

## Purpose

The kernel crypto API provides a unified, algorithm-agnostic interface for all cryptographic operations performed inside the kernel — ciphers, hashes, authenticated encryption, random number generation, and asymmetric key operations. Without it, every subsystem (IPsec, dm-crypt, fscrypt, TLS, WireGuard) would carry its own private copies of AES or SHA, making hardware acceleration impossible to share and security audits intractable.

## Mental Model

Think of the crypto API as a **driver model for algorithms**: just as the block layer abstracts spinning disks from SSDs, the crypto API abstracts software AES from AES-NI from an ARM crypto coprocessor. Callers allocate a *transform handle*, which is like opening a device file — it resolves to the highest-priority available implementation of the requested algorithm. The caller never knows or cares whether operations execute on a CPU instruction, an on-chip accelerator, or a software fallback; the transform handles dispatch.

## How It Works

### Bootstrapping: Algorithm Registration

The story begins at module load time. Every cipher implementation — whether a pure-C AES, an architecture-optimized assembly routine, or a hardware driver — calls `crypto_register_alg()` (or type-specific variants like `crypto_register_skcipher()`, `crypto_register_shash()`) to publish itself. The registration populates a `struct crypto_alg` (or its typed substructure) with metadata: a generic name like `"aes"`, a unique driver name like `"aes-aesni"`, a priority integer, the algorithm type constant (`CRYPTO_ALG_TYPE_CIPHER`, `CRYPTO_ALG_TYPE_SKCIPHER`, `CRYPTO_ALG_TYPE_SHASH`, etc.), and the type-specific operation callbacks (`setkey`, `encrypt`, `decrypt`, `digest`, and so on).

The priority field is the algorithm's **bid for selection**. When multiple implementations register the same generic name — for example, both `aes-generic` (priority 100) and `aes-aesni` (priority 300) register as `"aes"` — the crypto API's internal lookup always picks the highest priority. A caller can bypass this by using the unique driver name to request a specific implementation. All registered algorithms appear in `/proc/crypto` with their type, priority, key sizes, block size, digest size, reference count, and self-test status.

### Transform Allocation: From Name to Handle

A caller creates a **transform** by calling an allocator such as `crypto_alloc_skcipher("cbc(aes)", 0, 0)`. This name is not just a string — it encodes the algorithm's *composition*. The crypto API parses `cbc(aes)` as: apply the `cbc` template wrapping the `aes` cipher. Templates are registered separately and combine with primitive ciphers to form multi-block or keyed constructs. The template instantiation process looks up both the `cbc` template and the best `aes` implementation, then creates a composed transform object. Similarly `hmac(sha256)` instantiates an HMAC template over the SHA-256 hash, and `authenc(hmac(sha1),cbc(aes))` builds a nested AEAD out of two sub-transforms.

The returned `struct crypto_skcipher *` (or `struct crypto_aead *`, `struct crypto_shash *`, etc.) is the **transform handle** — an opaque object that maintains all key material, per-instance state, and a pointer to the algorithm's dispatch table. Freeing it via `crypto_free_skcipher()` returns the reference.

### Request Objects and the Scatter-Gather Model

Allocating the handle does not execute any crypto — it only binds an algorithm and stores the key. To actually encrypt or decrypt, the caller allocates a **request object** with `skcipher_request_alloc(tfm, GFP_KERNEL)`. The request holds: the scatter-gather input list (`sg_in`), the scatter-gather output list (`sg_out`), the IV, the data length, and (for async) a completion callback with private data.

The scatter-gather design is intentional and comes from the API's original motivation: IPsec processing of network packets. Network buffers (`sk_buff`) are already non-contiguous page vectors. Requiring callers to linearize them before encryption would waste memory and CPU time. Instead, `struct scatterlist` entries each hold `{page, offset, length}` tuples; the crypto implementation uses `scatterwalk_map()` to iterate through them and process the data in place. Block-aligned fragments are processed one block at a time; the scatterwalk handles straddling a fragment boundary transparently.

The cipher operation is invoked with `crypto_skcipher_encrypt(req)` or `crypto_skcipher_decrypt(req)`. This calls into the transform's `->encrypt` function pointer, which may return 0 (completed synchronously) or `-EINPROGRESS` / `-EBUSY` (pending asynchronous completion). If asynchronous, the caller must handle the completion callback, which is invoked from softirq context.

### Synchronous vs. Asynchronous Dispatch

Most software implementations complete synchronously and always return 0. Hardware-accelerated implementations — those backed by a DMA engine or crypto coprocessor — submit the request to the hardware and return `-EINPROGRESS` immediately. The calling code must not touch the request buffers until the callback fires. The API provides no implicit locking around request data, so callers are responsible for serializing access.

This dual-mode design allows the same call site to handle both paths. Code like:

```c
ret = crypto_skcipher_encrypt(req);
if (ret == -EINPROGRESS || ret == -EBUSY)
    wait_for_completion(&done); // or handle async
```

works whether the underlying algorithm is software or hardware. The `CRYPTO_ALG_ASYNC` type mask can be used at allocation time to restrict selection to asynchronous implementations only.

### The Crypto Engine: Queue Management for Hardware

Hardware drivers that need to serialize DMA requests use the **crypto engine** (`crypto/crypto_engine.c`). Rather than managing their own work queues, drivers embed a `struct crypto_engine` in their transform context and configure three callbacks: `prepare_*_request` (set up DMA descriptors), `*_one_request` (submit to hardware), and `unprepare_*_request` (clean up after completion). When a request arrives, the driver calls `crypto_transfer_skcipher_request_to_engine()`, and the engine serializes it through the queue. This separates the hardware driver's job (talking to registers and DMA) from the scheduling job (managing backpressure and ordering).

### The AF_ALG User-Space Bridge

Subsystems that need crypto stay inside the kernel. But tools like OpenSSL, dm-crypt management, and key derivation utilities sometimes benefit from access to kernel accelerators without reimplementing algorithms in user space. The `AF_ALG` socket family (merged in 2.6.38) exposes the crypto API via sockets.

A user-space caller opens an `AF_ALG` socket with `socket(AF_ALG, SOCK_SEQPACKET, 0)`, binds it with a `struct sockaddr_alg` specifying the algorithm type and name (e.g., `salg_type = "skcipher"`, `salg_name = "cbc(aes)"`), sets the key via `setsockopt(AF_ALG_SET_KEY)`, then calls `accept()` to get an operation socket. Actual data flows through `sendmsg()` (with the IV in cmsg ancillary data) and `read()` on the operation socket. A zero-copy path via `splice()`/`vmsplice()` avoids one copy when data is already in page cache, though it caps at 16 pages (~64 KB) per operation. Throughput is roughly half of OpenSSL's own AES-NI paths because of the extra system-call overhead, making AF_ALG best suited for hardware-only scenarios where the kernel has exclusive access to accelerators.

## Key Data Structures

**`struct crypto_alg`** (`include/linux/crypto.h`) — the core registration record shared by all algorithm types.
- `cra_name[CRYPTO_MAX_ALG_NAME]` — generic algorithm name (e.g., `"aes"`), used for priority-based lookup
- `cra_driver_name[]` — unique implementation name (e.g., `"aes-aesni"`), used for explicit targeting
- `cra_priority` — integer; higher wins when multiple implementations share `cra_name`
- `cra_flags` — type flags (`CRYPTO_ALG_TYPE_*`) plus `CRYPTO_ALG_ASYNC` if HW-backed
- `cra_blocksize` — cipher block size in bytes
- `cra_ctxsize` — size of per-transform private context to allocate
- `cra_module` — owning module for reference counting
- `cra_u` — union of type-specific operation tables (`cipher_alg`, `compress`, etc.)

**`struct skcipher_alg`** (`include/crypto/skcipher.h`) — registration struct for multi-block (length-preserving) symmetric ciphers.
- `setkey` — stores and validates the key; called once before any encrypt/decrypt
- `encrypt` / `decrypt` — operate on a `struct skcipher_request` with scatter-gather I/O
- `min_keysize`, `max_keysize` — key length range; callers query via `crypto_skcipher_keysize()`
- `ivsize` — IV byte length for modes that need one

**`struct skcipher_request`** — per-operation context; allocated on the heap (not stack) because it may outlive the calling function in async paths.
- `src`, `dst` — scatter-gather lists for input and output
- `cryptlen` — number of bytes to process
- `iv` — pointer to IV buffer (caller manages lifetime)
- `base.complete` — callback invoked on async completion

**`struct aead_request`** — like `skcipher_request` but adds `assoclen` for the Associated Data length in AEAD operations.

## Key Functions / Entry Points

**`crypto_alloc_skcipher(name, type, mask)`** (`crypto/skcipher.c`) — allocates and returns a transform handle; triggers name lookup, template instantiation, and priority selection.

**`crypto_skcipher_setkey(tfm, key, keylen)`** — copies key material into the transform's private context; returns `-EINVAL` if the length is unsupported.

**`skcipher_request_alloc(tfm, gfp)`** — heap-allocates a request plus driver-private trailing space (size from `crypto_skcipher_reqsize()`).

**`crypto_skcipher_encrypt(req)`** / **`crypto_skcipher_decrypt(req)`** — dispatches to the algorithm's `->encrypt`/`->decrypt` callback; returns 0, `-EINPROGRESS`, or an error.

**`crypto_register_alg(alg)`** / **`crypto_register_skcipher(alg)`** — called by algorithm providers at module init to publish their implementation.

**`crypto_register_template(tmpl)`** (`crypto/algapi.c`) — registers a template (e.g., `cbc`, `hmac`); templates instantiate lazily when a caller requests a composed name.

**`scatterwalk_map(walk)`** / **`scatterwalk_advance(walk, n)`** (`crypto/scatterwalk.c`) — used inside algorithm implementations to iterate over scatter-gather lists without materializing a contiguous buffer.

## Important Flags & Config Options

| Symbol | Effect |
|---|---|
| `CONFIG_CRYPTO` | Enables the crypto subsystem; required by essentially everything |
| `CONFIG_CRYPTO_AES` | Software AES implementation (fallback for non-AES-NI CPUs) |
| `CONFIG_CRYPTO_AES_NI_INTEL` | AES-NI accelerated AES+CBC/CTR/GCM for x86 |
| `CONFIG_CRYPTO_GHASH_CLMUL_NI_INTEL` | Carryless-multiply GHASH for GCM on x86 |
| `CONFIG_CRYPTO_ENGINE` | The crypto engine queue manager; needed by hardware drivers |
| `CONFIG_CRYPTO_USER_API_SKCIPHER` | Enables `AF_ALG` for symmetric ciphers |
| `CONFIG_CRYPTO_USER_API_AEAD` | Enables `AF_ALG` for AEAD ciphers |
| `CONFIG_CRYPTO_FIPS` | Enables FIPS 140-2/3 mode; restricts available algorithms and forces self-tests |
| `CONFIG_CRYPTO_MANAGER_DISABLE_TESTS` | Skips self-tests on registration (speeds up boot; not for production) |

`CRYPTO_ALG_ASYNC` — runtime type mask; when passed to `crypto_alloc_*()`, restricts lookup to asynchronous (hardware) implementations only, useful when the caller cannot handle synchronous fallbacks.

## Interactions with Other Subsystems

- **↑ Userspace**: AF_ALG socket family (`socket(AF_ALG, ...)`) exposes the full crypto API; `libkcapi` wraps this for user-space applications
- **→ [[fscrypt]]**: uses `crypto_alloc_skcipher()` for per-file encryption keys (AES-256-XTS, AES-256-CTS-CBC, ChaCha20) and `crypto_alloc_shash()` for key derivation (HKDF via HMAC-SHA512)
- **→ [[dm-crypt]]**: allocates `skcipher` transforms for full-disk encryption; uses `crypto_engine` when hardware accelerators are present
- **→ [[net]] / IPsec**: the original motivation for the scatter-gather design; `xfrm` uses AEAD transforms (GCM-AES, ChaCha20-Poly1305) for ESP
- **→ [[kernel-keyring]]**: asymmetric key operations (`akcipher`) integrate with the key retention service; RSA and ECDSA verifications route through the crypto API
- **← Hardware drivers**: ARM crypto extensions, Intel AES-NI, IBM z/Architecture CP Assist, and dedicated crypto ASICs register with `crypto_register_skcipher()` at driver probe time

## Design Decisions & Tradeoffs

**Scatter-gather over linear buffers.** The core design choice that distinguishes the kernel crypto API from user-space libraries. Network stack buffers (`sk_buff`) and block I/O buffers are inherently fragmented; requiring linearization before encryption would double memory pressure and CPU time. The cost is higher implementation complexity: every algorithm must implement `scatterwalk` iteration rather than a simple pointer loop.

**Priority-based polymorphism without recompilation.** When AES-NI is available, it automatically wins over the generic C implementation without any caller change. This is elegant — drivers simply register at higher priority — but creates a subtle hazard: if an optimized driver is buggy, all callers are silently affected. The `CRYPTO_MANAGER_DISABLE_TESTS` option (which skips self-tests at boot) compounds this risk.

**Synchronous/asynchronous duality.** The same `crypto_skcipher_encrypt()` call can complete synchronously or schedule an async callback depending on the underlying implementation. This is maximally flexible but requires callers to handle both paths, which has historically led to bugs (missed `-EINPROGRESS` handling, use-after-free in async callbacks).

**The Zinc rejection.** Jason Donenfeld's 2018 WireGuard-driven proposal "Zinc" argued for replacing the crypto API's elaborate indirection with simple, inlined C functions organized by algorithm. The community debated tradeoffs: Zinc offered simplicity, auditability, and formally verified implementations (HACL*, fiat-crypto), while the existing API offered hardware acceleration, FIPS compliance infrastructure, and broader algorithm coverage. The result was a pragmatic compromise: formally verified implementations of Curve25519, ChaCha20, Poly1305, and Blake2s were merged into `lib/` as direct-call libraries, used by WireGuard without touching the full crypto API. The main API retained its architecture for everything else.

**FIPS 140 pressure.** The `CONFIG_CRYPTO_FIPS` mode enforces algorithm restrictions and conditional self-tests (CAVS), but the entire kernel image traditionally had to be certified as a unit — making non-crypto kernel updates potentially invalidating. Amazon Linux's 2026 "standalone crypto module" patch series addresses this by converting the crypto subsystem into a loadable module that can be certified independently.

## How It Has Evolved

**2.5.45 (2002)** — Initial "Scatterlist Crypto API" merged, motivated by IPsec. Primitive CIPHER type, early DIGEST type. Transform object model with `crypto_alloc_tfm()`.

**2.6.x (2003–2010)** — Expansion of algorithm coverage. Addition of BLKCIPHER (synchronous multi-block) and ABLKCIPHER (asynchronous multi-block) types. Template system introduced. Hardware driver integration (ARM, Intel PADLOCK, IBM z/arch).

**2.6.38 (2011)** — AF_ALG user-space socket interface merged (Herbert Xu).

**3.x–4.x (2012–2017)** — AEAD cipher type (`crypto_aead`) consolidated. HASH and AHASH types unified. `crypto_engine` introduced to standardize hardware driver queue management. SKCIPHER interface introduced as the modern replacement for BLKCIPHER/ABLKCIPHER.

**5.0 (2018–2019)** — WireGuard's Zinc proposal triggers productive debate. Formally verified ChaCha20, Poly1305, Blake2s merged into `lib/` (outside the main crypto API) for use by WireGuard and other in-kernel callers. Template instantiation infrastructure cleaned up.

**5.5 (2020)** — ABLKCIPHER API fully removed after completing driver migration to SKCIPHER. Trims >1000 lines.

**6.x (2022–present)** — LSKCIPHER (linear skcipher) type added to support algorithms that operate on linear buffers rather than scatter-gather lists, simplifying driver code for cases where contiguous data is guaranteed. `akcipher` extended with `SIG` type for asymmetric signature operations. Active push to convert hardware drivers.

## Further Reading

1. [Kernel Crypto API Architecture — kernel.org](https://www.kernel.org/doc/html/latest/crypto/architecture.html) — canonical reference for cipher types, naming, and layering
2. [Scatterlist Crypto API Introduction — kernel.org](https://www.kernel.org/doc/html/latest/crypto/api-intro.html) — original design rationale and caller model
3. [Zinc: a new kernel cryptography API — LWN.net (2018)](https://lwn.net/Articles/770750/) — best source for understanding the API's weaknesses and the community debate
4. [The Linux Crypto API for user applications — Cloudflare Blog](https://blog.cloudflare.com/the-linux-crypto-api-for-user-applications/) — AF_ALG performance analysis and practical usage
5. [Developing Cipher Algorithms — kernel.org](https://www.kernel.org/doc/html/latest/crypto/devel-algos.html) — how to implement and register new algorithms
6. [Crypto Engine — kernel.org](https://www.kernel.org/doc/html/latest/crypto/crypto_engine.html) — hardware offload architecture
7. [The Linux Kernel Cryptographic API — Linux Journal](https://www.linuxjournal.com/article/6451) — early design explanation with code examples

## LKML Highlights

- **Zinc proposal (2018)**: Jason Donenfeld's cover letter for the initial 24,000-line Zinc patch is the canonical statement of the existing API's flaws — complex allocation, mandatory scatter-gather, per-instance key locking, and a "museum of ciphers" — and triggered a productive discussion that ultimately shaped how `lib/` crypto arrived. Search LKML archives for "[RFC PATCH 00/21] zinc: a new cryptography API".

- **ABLKCIPHER removal (5.5, 2019)**: Herbert Xu's cleanup series completing the SKCIPHER migration, removing over 1,000 lines of deprecated code. Subject: "crypto: remove deprecated and unused ablkcipher support".

- **Standalone FIPS crypto module (2026)**: Jay Wang / Amazon Linux's ongoing patch series (`20260212032117.9166-1-wanjay@amazon.com`) to convert the crypto subsystem into a loadable module for independent FIPS 140-3 certification — a concrete example of how FIPS compliance pressure shapes API architecture.
