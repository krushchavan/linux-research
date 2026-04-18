---
title: "dm-crypt Workqueue I/O Path — kcryptd and kcryptd_io"
category: concept
tags: [dm-crypt, workqueue, io-path, block, encryption, performance]
subsystem: dm-crypt
kernel_version: "2.5"
researched: 2026-04-18
status: complete
sources:
  - https://kernel-internals.org/security/dm-crypt/
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html
  - https://lwn.net/Articles/71434/
  - https://blog.cloudflare.com/speeding-up-linux-disk-encryption/
  - https://bugzilla.redhat.com/show_bug.cgi?id=2154817
---

# dm-crypt Workqueue I/O Path — kcryptd and kcryptd_io

## Purpose

The workqueue I/O path decouples the encryption and decryption work from the contexts in which block I/O arrives and completes. Without this decoupling, decryption would run inside a hardware interrupt completion handler — a context where sleeping is prohibited, per-CPU SIMD registers may not be valid, and stack depth is limited. The workqueue provides a process context in which the crypto API can safely call SIMD instructions, sleep waiting for hardware accelerators, and allocate memory as needed.

## Mental Model

Think of the workqueues as **two staging areas** in a mail-sorting facility. Incoming reads go to `kcryptd_io` (the loading dock — just get the mail off the truck). Once the mail arrives from the truck (disk I/O completes), it moves to `kcryptd` (the sorting room — open and process each item). Outgoing writes go directly to `kcryptd` (encrypt and then dispatch). The two-stage separation for reads prevents the sorting room from being flooded by requests waiting on the truck; the truck and the sorting room operate independently.

## How It Works

### Two workqueues, two roles

`crypt_config` holds two workqueue handles created during `crypt_ctr()`:

- **`cc->kcryptd_io`** — an unbound high-priority workqueue used exclusively for the initial submission of read bios to the underlying block device. The separation from crypto work means that even when crypto workers are busy, new read requests can still reach the disk promptly.

- **`cc->kcryptd`** — the main crypto workqueue. It handles both encryption of write bios and decryption of read bios after their data has arrived from disk.

Both are created with `alloc_workqueue()` using `WQ_UNBOUND | WQ_HIGHPRI`. `WQ_UNBOUND` means the kernel scheduler can run workers on any CPU, automatically load-balancing encryption work across available cores. `WQ_HIGHPRI` elevates the workers' scheduling priority, reducing latency when competing with normal-priority background work.

### Write path

A write bio arrives at `crypt_map()`. The function initialises a `crypt_io`, then calls `kcryptd_queue_crypt(io)` which calls `queue_work(cc->kcryptd, &io->work)`. The bio is now queued; `crypt_map()` returns `DM_MAPIO_SUBMITTED` immediately.

The kcryptd worker picks up the work item and calls `kcryptd_crypt_write_io_submit()`. This function:
1. Calls `crypt_convert()` which loops over bio segments, generates the sector IV, and calls `crypto_skcipher_encrypt()` for each sector.
2. Accumulates the encrypted pages into a new "clone" bio targeting the underlying device.
3. When all sectors are encrypted, submits the clone bio via `dm_submit_bio_remap()`.

The underlying device completes the clone bio asynchronously. `crypt_endio()` fires, records any storage error, and calls `bio_endio()` on the original bio to signal completion to the filesystem above.

### Read path

The read path is deliberately split into two stages to avoid a latency inversion. If dm-crypt queued reads on `kcryptd` immediately (like writes), a burst of writes could fill `kcryptd` and delay read completions while the disk sits idle waiting to be asked.

**Stage 1 — Dispatch**: `crypt_map()` calls `kcryptd_io_read()`. If `no_read_workqueue` is not set, this queues `io->work` on `cc->kcryptd_io`. The `kcryptd_io` worker submits the read bio to the underlying block device. If `no_read_workqueue` is set, the read bio is submitted inline without a workqueue hop.

**Stage 2 — Decrypt**: The block device completion fires `crypt_endio()` in interrupt/softirq context. `crypt_endio()` must not do crypto work here (interrupt context: no SIMD, no sleep). Instead, it queues `io->work` on `cc->kcryptd` for decryption. The kcryptd worker calls `kcryptd_crypt_read_done()`, which calls `crypt_convert()` with `crypto_skcipher_decrypt()`. Decrypted plaintext is in the original bio's pages, and `bio_endio()` completes the bio.

### The NVMe performance problem

The workqueue design was ideal for spinning disks (HDDs), where:
- I/O latency is 5–10 ms, making workqueue overhead (~10 µs) negligible
- I/O ordering matters — sorting requests by sector improved throughput
- Block depths were low — one outstanding request per queue was typical

On NVMe SSDs, the picture reverses:
- I/O latency is 50–100 µs, making workqueue overhead (~10 µs) a significant fraction
- I/O ordering is irrelevant — NVMe controllers handle reordering internally
- Queue depths of 64–128 are normal — one worker thread becomes a serialisation bottleneck

Cloudflare's 2020 analysis showed that on a ramdisk (pure CPU/memory, zero device latency), dm-crypt reduced throughput from ~1,126 MB/s to ~147 MB/s — a 7× degradation attributable almost entirely to workqueue overhead and context-switch latency across four queue levels, not the AES cipher itself.

### The fix: synchronous paths (kernel 5.9)

Two flags added in kernel 5.9 allow operators to bypass the workqueues entirely:

**`no_write_workqueue`**: `crypt_map()` calls `crypt_convert()` directly in the submitter's context rather than queuing on `kcryptd`. The encryption happens synchronously, the encrypted bio is built, and `dm_submit_bio_remap()` is called before `crypt_map()` returns. For AES-NI this is pure in-CPU work with no context switch.

**`no_read_workqueue`**: `kcryptd_io_read()` submits the read bio inline rather than queuing on `kcryptd_io`. After the disk completes (still asynchronous — the disk I/O itself cannot be made synchronous), `crypt_endio()` calls `crypt_convert()` and decrypts inline in the completion context. This is safe because `crypt_endio()` is called in a softirq-safe context by the block layer, and `crypto_skcipher_decrypt()` with AES-NI does not sleep.

**Result**: With both flags, the write path has two queue levels (crypto inline + block layer), and the read path has one level (block layer only). Cloudflare measured ~640 MB/s throughput, a 4.3× improvement over the unmodified dm-crypt path.

### Practical recommendation

For SSDs and NVMe devices, enable both flags via cryptsetup:

```bash
cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue open /dev/nvme0n1 myvolume
```

Or via `/etc/crypttab`:

```
myvolume UUID=... none luks,no-read-workqueue,no-write-workqueue
```

For HDDs with a high-latency workload, the default workqueue path is still appropriate.

## Key Data Structures

**`struct workqueue_struct`** (kernel workqueue) — one per `kcryptd_io` and `kcryptd`; created by `alloc_workqueue()` with `WQ_UNBOUND | WQ_HIGHPRI`.

**`struct work_struct`** (embedded in `crypt_io`) — the work item queued to either workqueue; its function pointer points to `kcryptd_crypt` or `kcryptd_io_read`.

## Key Functions / Entry Points

**`kcryptd_queue_crypt(io)`** — queues `io->work` on `cc->kcryptd`; called by `crypt_map()` for writes.

**`kcryptd_io_read(io, GFP_NOWAIT)`** — submits the read bio (inline or via `kcryptd_io` depending on flags); called by `crypt_map()` for reads.

**`kcryptd_crypt(work)`** — kcryptd workqueue function; determines direction (read or write) and calls `crypt_convert()`.

**`kcryptd_io_read_work(work)`** — `kcryptd_io` workqueue function; submits the read bio to the underlying device.

**`crypt_endio(bio)`** — `end_io` callback; queues decryption on `kcryptd` or calls `crypt_convert()` inline for `no_read_workqueue`.

## Important Flags & Config Options

- `no_read_workqueue` — bypass `kcryptd_io` and inline decrypt in completion; best for NVMe
- `no_write_workqueue` — bypass `kcryptd` for writes; inline encrypt in submitter context
- `same_cpu_crypt` — older flag; pinned crypto work to submission CPU; largely superseded
- `no_write_submit_workqueue` — prevents offloading the final encrypted bio submission to a separate thread; reduces write latency further
- `high_priority` — set `WQ_HIGHPRI` on workqueues (this is the default; the flag allows explicit confirmation)
- Module parameters `max_read_size` / `max_write_size` — limit bio splitting; controls the granularity at which work is distributed across workqueue workers

## Interactions with Other Subsystems

- **← [[dm-crypt-crypt-io]]**: `crypt_io` holds the `work_struct` queued by these functions; the workqueue workers process `crypt_io` objects
- **← [[dm-crypt-crypt-config]]**: `crypt_config` holds the workqueue handles and the `no_*_workqueue` flags
- **← [[dm-crypt-crypto-api-integration]]**: `crypt_convert()` (called by workqueue workers) submits crypto requests to the Crypto API
- **→ Block layer**: the read bio is submitted to and completed by the block layer; `crypt_endio()` is the block layer callback

## Design Decisions & Tradeoffs

**Unbound workqueue vs. bound**: Early dm-crypt used a single ordered global workqueue (equivalent to `alloc_ordered_workqueue`). This serialised all crypto work through a single thread, devastating multi-core throughput. Switching to unbound workqueues allows the kernel scheduler to spread workers across all CPUs, using as many hardware threads as are available.

**Two workqueues vs. one**: Separating `kcryptd_io` (read dispatch) from `kcryptd` (crypto) prevents writes from blocking reads at the queue level. Without this separation, a write burst fills `kcryptd`, delaying read completions and effectively halting the read path even when the disk is idle and ready to serve reads.

**Synchronous override via flags**: Rather than changing the default (which would break HDD workloads), the 5.9 kernel exposed the synchronous paths as explicit per-device flags. Operators who have profiled their specific workload can opt in. This is a deliberate "leave the existing behaviour alone" policy to avoid surprising regressions.

## How It Has Evolved

- **2.5 (2003)**: Single global `_kcryptd_workqueue` (ordered); all crypto work serialised
- **2.6**: Per-device workqueue; encryption and decryption separated
- **3.x**: Unbound (`WQ_UNBOUND`) workqueues; automatic CPU-balancing
- **3.x**: `kcryptd_io` separated from `kcryptd` to avoid write-blocking-read starvation
- **5.9 (2020)**: `no_read_workqueue` and `no_write_workqueue` flags added, upstreamed from Cloudflare's performance work

## Further Reading

- [Cloudflare: Speeding up Linux disk encryption](https://blog.cloudflare.com/speeding-up-linux-disk-encryption/) — the definitive analysis of the workqueue bottleneck
- [LWN: dm-crypt kthread](https://lwn.net/Articles/71434/) — the original 2003 thread discussing workqueue vs. kthread vs. semaphore models
- [Red Hat BZ 2154817](https://bugzilla.redhat.com/show_bug.cgi?id=2154817) — `no_read_workqueue` for dm-crypt on SSDs; practical performance discussion
