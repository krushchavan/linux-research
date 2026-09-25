---
title: "dm-crypt crypt_io — Per-Bio Encryption Request Context"
category: concept
tags: [dm-crypt, block, encryption, device-mapper, io-path]
subsystem: dm-crypt
kernel_version: "2.5"
researched: 2026-04-18
status: complete
explained: "[[dm-crypt-crypt-io-explained]]"
sources:
  - https://kernel-internals.org/security/dm-crypt/
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html
  - https://lwn.net/Articles/42000/
  - https://lwn.net/Articles/71434/
  - https://blog.cloudflare.com/speeding-up-linux-disk-encryption/
---

# dm-crypt crypt_io — Per-Bio Encryption Request Context

> 📘 Plain-language version: [[dm-crypt-crypt-io-explained]]

## Purpose

`crypt_io` is the per-bio work unit that carries a single I/O request through dm-crypt's encryption or decryption pipeline. It bridges the stateless Device Mapper callback interface — where `crypt_map()` is called with a bio and must return immediately — and the necessarily asynchronous, potentially multi-step crypto work that must happen before the bio reaches its destination. Without `crypt_io`, there would be no place to track which bio is being processed, which stage it is at, or whether an error has occurred midway through a multi-sector request.

## Mental Model

Think of `crypt_io` as a **flight manifest** for one bio. The bio arrives at the gate (`crypt_map()`), a manifest is created, and the bio is tracked from encryption through storage submission through decryption — with the manifest recording any errors along the way. At every handoff point (queueing, completion callback, decryption completion), the manifest travels with the bio. When all sectors are processed and no errors are recorded, the original bio is completed and the manifest is returned to the pool.

## How It Works

### Allocation and queueing in `crypt_map()`

`crypt_map()` is the Device Mapper `map()` callback — the entry point for every bio submitted to the encrypted device. The first thing it does is call `dm_per_bio_data(bio, ...)` to obtain a `crypt_io` embedded in the bio's private data area (pre-allocated by the DM core using `ti->per_io_data_size`). This zero-copy allocation means no separate `mempool_alloc()` call for the `crypt_io` itself — it lives inside the bio's existing allocation.

After initialising `io->cc` (back-pointer to `crypt_config`), `io->base_bio` (the original bio), and `io->error` (to 0), the function diverges based on bio direction:

**Write path**: The bio carries plaintext that must be encrypted before reaching the disk. `crypt_map()` calls `kcryptd_queue_crypt(io)`, which queues the `work` field (`struct work_struct` embedded in `crypt_io`) onto `cc->kcryptd`. The workqueue worker calls `kcryptd_crypt()`, which calls `crypt_convert()` to encrypt all bio segments, builds an encrypted clone bio, and submits it to the underlying device.

**Read path**: The disk holds ciphertext that must be decrypted after reading. `crypt_map()` calls `kcryptd_io_read(io, ...)`, which (depending on `no_read_workqueue` flag) either submits the read bio directly or queues it on `cc->kcryptd_io`. The underlying device read completes asynchronously, triggering `crypt_endio()`.

### Completion via `crypt_endio()`

`crypt_endio()` is installed as the `end_io` callback on the bio submitted to the underlying device. For reads, when the disk completes the read, `crypt_endio()` fires in softirq/completion context. It records any block-level error into `io->error`, then queues the `crypt_io` work on `cc->kcryptd` for decryption. The kcryptd worker picks it up and calls `crypt_convert()` with decryption mode.

For writes, `crypt_endio()` fires after the *encrypted* bio reaches the disk. It propagates any storage error up through `io->error` and calls `bio_endio(io->base_bio, io->error)` to complete the original bio to its caller (the filesystem).

### `crypt_convert()` — the core encryption loop

`crypt_convert()` is the inner loop that does the actual sector-by-sector crypto work. It takes a `convert_context` (embedded in `crypt_io`) that tracks the current position within the bio's scatter-gather list. For each sector:

1. `cc->iv_gen_ops->generator()` is called to populate the IV buffer with a sector-number-derived value.
2. `skcipher_request_set_crypt()` binds the per-CPU skcipher request to the source and destination scatter-gather pages, the IV, and the length (one sector = 512 bytes or `cc->sector_size` bytes).
3. `crypto_skcipher_encrypt()` or `crypto_skcipher_decrypt()` is invoked. If the crypto hardware is synchronous (AES-NI), it returns 0 immediately. If the hardware requires a callback (e.g., an offload engine), it returns `-EINPROGRESS` and the completion fires later.
4. In the async case, the completion handler re-queues the `crypt_io` from where it left off via `kcryptd_async_done()`, which updates `ctx->iter` and calls `crypt_convert()` again for the next segment.

### Error handling

`io->error` accumulates the first non-zero error encountered during the pipeline. If block-layer I/O fails, `crypt_endio()` stores the block error. If crypto fails (a cipher error, or an AEAD authentication tag mismatch in dm-integrity mode), `crypt_convert()` stores the crypto error. Either way, when `bio_endio()` is finally called on the original bio, the accumulated error is passed as the bio's status, surfacing as an `-EIO` to the filesystem.

### Inline (no-workqueue) path

When `no_read_workqueue` or `no_write_workqueue` is set (kernel 5.9+), `crypt_map()` calls `crypt_convert()` synchronously in the submitter's context rather than queuing work. This eliminates two context switches per bio (queue → worker → submitter) and dramatically reduces latency on NVMe SSDs where the crypto cost is small relative to workqueue overhead. `crypt_io` is still used to track state, but the `work` field is never queued.

## Key Data Structures

**`struct crypt_io`** (`drivers/md/dm-crypt.c`) — per-bio request context

- `cc` — back-pointer to `crypt_config`; accessed constantly during I/O
- `base_bio` — the original bio from the Device Mapper core; completed at the end of the pipeline
- `work` — `struct work_struct`; queued on `cc->kcryptd` or `cc->kcryptd_io`; the workhorse that moves the request between stages
- `error` — accumulated error code; written by `crypt_endio()` and `crypt_convert()`; read at final bio completion
- `ctx` — embedded `convert_context`; tracks the current scatter-gather position for `crypt_convert()`'s sector-at-a-time loop

**`struct convert_context`** (embedded in `crypt_io`) — loop position for `crypt_convert()`

- `bio_in` / `bio_out` — source and destination bios for the current conversion
- `iter_in` / `iter_out` — `bvec_iter` tracking progress through the scatter-gather lists
- `cc_sector` — the logical sector number for the next IV computation

## Key Functions / Entry Points

**`crypt_map()`** (`drivers/md/dm-crypt.c`) — Device Mapper `map()` callback; initialises `crypt_io` and routes the bio to either the write-encrypt path or the read-submit path.

**`crypt_endio()`** (`drivers/md/dm-crypt.c`) — `end_io` callback on the underlying-device bio; records storage errors, queues decryption work for reads, completes the original bio for writes.

**`crypt_convert()`** (`drivers/md/dm-crypt.c`) — core sector-at-a-time encryption/decryption loop; calls IV generation and the crypto API for each sector; handles async completion via `kcryptd_async_done()`.

**`kcryptd_crypt()`** (`drivers/md/dm-crypt.c`) — workqueue function for encryption/decryption; calls `crypt_convert()` and handles the result.

**`kcryptd_queue_crypt()`** (`drivers/md/dm-crypt.c`) — queues `crypt_io.work` on `cc->kcryptd`; the fast-path for writes.

## Important Flags & Config Options

- `no_read_workqueue` — process decryption synchronously in `crypt_map()` rather than via `kcryptd_io` + `kcryptd`; critical for NVMe SSD latency
- `no_write_workqueue` — process encryption synchronously; reduces write latency
- `same_cpu_crypt` — older option that pinned crypto work to the submission CPU; largely superseded by the synchronous paths above
- `no_write_submit_workqueue` — prevents offloading the final encrypted bio submission; reduces latency further for synchronous write paths

## Interactions with Other Subsystems

- **↑ Device Mapper core**: the DM core calls `crypt_map()` for every bio; provides pre-allocated per-bio data space for `crypt_io` storage
- **→ [[dm-crypt-crypt-config]]**: `crypt_io` accesses `crypt_config` for per-CPU cipher handles, IV ops, pools, and workqueue handles
- **→ [[dm-crypt-iv-generation]]**: `crypt_convert()` calls `cc->iv_gen_ops->generator()` before each sector's crypto call
- **→ [[dm-crypt-crypto-api-integration]]**: `crypt_convert()` calls `crypto_skcipher_encrypt()` / `crypto_skcipher_decrypt()` with `skcipher_request` objects stored relative to `crypt_io`
- **→ [[dm-crypt-workqueue-io-path]]**: `kcryptd_queue_crypt()` and `kcryptd_io_read()` queue `crypt_io.work` on the two workqueues
- **← Block layer**: `crypt_endio()` is invoked as the bio `end_io` callback by the block layer when the underlying device completes the I/O

## Design Decisions & Tradeoffs

**Per-bio allocation via DM per-bio data vs. mempool**: The `crypt_io` is embedded in the DM per-bio data allocation rather than allocated from a dedicated mempool. This avoids a second allocation per bio and improves cache locality (the `crypt_io` lives adjacent to the bio in memory). The DM core pre-sizes this per-bio data area when the target is registered using `ti->per_io_data_size = sizeof(struct crypt_io)`.

**Async vs. sync completion**: `crypt_convert()` supports both synchronous completion (crypto hardware returns 0 immediately) and asynchronous completion (crypto hardware returns `-EINPROGRESS` and fires a callback). Supporting both paths adds code complexity but is necessary for hardware offload engines that may not be synchronous. AES-NI always completes synchronously, so on x86 the async path is dead code in practice.

**Single error field**: `io->error` uses a simple integer rather than a per-sector error bitmap. This is intentional: dm-crypt does not support partial-sector recovery. Any error in the pipeline aborts the entire bio.

## How It Has Evolved

- **2.5 (2003)**: `crypt_io` introduced with a `work_struct` for the single global workqueue; allocated from a dedicated mempool.
- **3.x**: Migrated to DM per-bio data allocation; workqueue separated into per-device `kcryptd` and `kcryptd_io`.
- **5.9 (2020)**: Synchronous (inline) processing paths added; `crypt_io.work` may never be queued when `no_*_workqueue` flags are set.

## Further Reading

- [dm-crypt kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html)
- [Cloudflare: Speeding up Linux disk encryption](https://blog.cloudflare.com/speeding-up-linux-disk-encryption/) — analyses the per-bio workqueue overhead
- [LWN: dm-crypt kthread design](https://lwn.net/Articles/71434/)
