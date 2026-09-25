---
title: "dm-crypt — Explained"
category: explained
original: "[[dm-crypt]]"
subsystem: dm-crypt
tags: [explained, dm-crypt, encryption, device-mapper, luks]
converted: 2026-09-25
---

# dm-crypt, explained

> Plain-language companion to [[dm-crypt|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

If a laptop is stolen or a disk is thrown away, everything on it can be read by whoever gets it. Full-disk encryption fixes that. But you don't want every filesystem (ext4, XFS, btrfs...) to implement its own encryption, and you want *everything* on the disk hidden, including file names, directory structure and free space, not only file contents.

dm-crypt solves this one level down, at the block device. It is a device-mapper target that encrypts every sector on its way to disk and decrypts it on the way back. It is the standard mechanism for full-disk encryption on Linux, used by LUKS, cryptsetup and systemd-cryptsetup.

The hard parts are performance (every byte of I/O goes through a cipher), the fact that decryption can't run in the interrupt context where disk reads complete, and keeping the key safe.

## The big picture

Think of dm-crypt as **a transparent encryption lens** between the disk and everything above it. A write comes in as plaintext and leaves as ciphertext. A read arrives from disk as ciphertext and is handed up as plaintext. Nothing above (filesystem, page cache, applications) knows encryption is happening; the virtual device behaves like any other disk.

The kernel only does the encryption and I/O mechanics. Everything about passphrases, key slots and on-disk headers lives in user space in `cryptsetup`, which hands the kernel the raw key when it sets the device up.

```text
 cryptsetup (user space): passphrase → master key → table load (cipher + key)
                                   │
                                   ▼
                    per-device state: key, per-CPU ciphers, IV scheme, pools
                                   │
 WRITE: plaintext I/O ──▶ worker: for each sector, IV from sector number
                                   → encrypt → new request ──▶ disk
 READ:  request ──▶ disk (ciphertext) ──▶ completion ──▶ worker: IV → decrypt
                                   ──▶ plaintext back to caller
                                   │
                          kernel crypto API (AES-NI, ARM crypto, or software)
```

## The pieces

### Per-device state

One object per encrypted device holds everything for its lifetime. See [[dm-crypt-crypt-config-explained|dm-crypt-crypt-config]].

1. When the table is loaded, dm-crypt parses the cipher specification (for example "aes-xts-plain64") and allocates **one cipher instance per CPU**. Each worker uses the one for its own CPU, so there is no lock contention.
2. The master key is stored in this object. AES-256-XTS needs 64 bytes (two 256-bit keys). The key is pushed into every per-CPU cipher and the staging copy is wiped.
3. Two reserved memory pools supply per-request tracking objects (at least 256) and spare pages for ciphertext. So even under memory pressure, a minimum number of I/Os can always proceed without deadlock.
4. When the device is removed, the key is zeroed and the ciphers destroyed.

### Per-request work unit

Each incoming I/O request gets a small tracking object that carries it through the pipeline. See [[dm-crypt-crypt-io-explained|dm-crypt-crypt-io]].

1. **Writes** are queued to a worker that walks each sector, computes its IV, encrypts it, and collects the ciphertext into a new request aimed at the real disk.
2. **Reads** go straight to the disk first, with nothing to decrypt yet. When the disk completes the read, a completion callback queues decryption work.
3. The asymmetry is deliberate: decryption must not run in the interrupt-like context where the read completes, because the crypto code may need to sleep (for example, when waiting on a hardware accelerator).

### IV generation

Each sector needs its own **initialization vector** (IV). Otherwise two sectors holding the same plaintext would produce the same ciphertext, which leaks information. See [[dm-crypt-iv-generation-explained|dm-crypt-iv-generation]].

1. **plain64** uses the sector number itself as the IV. It's fast but predictable. It is the recommended choice with XTS mode, because XTS's own "tweak" already isolates sectors from each other.
2. **ESSIV** encrypts the sector number under a key derived from a hash of the master key, so the IV can't be predicted without the key. It was the safe choice for the older CBC mode, where predictable IVs allow "watermarking" attacks, but costs an extra encryption per sector.
3. **TCW** exists only for compatibility with TrueCrypt volumes.
4. An offset can shift the sector numbering, so a dm-crypt device can sit inside a larger disk without IV collisions with a neighbouring encrypted volume.

The modern recommendation, **AES-256-XTS with plain64**, sidesteps most IV pitfalls.

### Crypto API integration

dm-crypt doesn't implement ciphers; it uses the kernel's crypto API. See [[dm-crypt-crypto-api-integration-explained|dm-crypt-crypto-api-integration]].

1. The cipher name picks the best available implementation. On x86, "xts(aes)" resolves to the AES-NI accelerated version if present, otherwise to software. With AES-NI, encryption typically costs under 5% of raw device throughput.
2. With an **authenticated** cipher (AEAD, for example AES-GCM), each sector also gets an authentication tag. dm-crypt hands the tag to dm-integrity, which stores it separately. On read, a bad tag means the data was tampered with, and the read fails with an I/O error instead of returning corrupted plaintext.
3. If the crypto hardware works asynchronously, completion arrives through a callback; otherwise the operation finishes immediately.

### The workqueue I/O path

Work is moved off the submitting thread and out of completion context onto kernel worker threads. See [[dm-crypt-workqueue-io-path]].

1. One high-priority queue only dispatches reads to the disk, so reads keep reaching the disk even when the crypto workers are busy.
2. A main queue does the encryption and decryption, using the per-CPU ciphers.
3. Early dm-crypt (2003) had one global queue that serialized all crypto work, which was terrible on multi-core machines. Later versions use per-device queues that spread across CPUs.
4. **The Cloudflare finding (2020):** on NVMe SSDs the queueing itself became the bottleneck. A request passed through up to four queues before reaching the device, and Cloudflare measured a 7× throughput loss against the raw device, when the cipher alone should cost about 5%. Their fix let encryption and decryption run inline, skipping the workqueues. It was upstreamed in **5.9** as two table options, one for reads and one for writes.

### Key management

The key has to reach the kernel somehow, ideally without ever sitting in plain user-space memory. See [[dm-crypt-key-management-explained|dm-crypt-key-management]].

1. **Simplest:** the key is written in hex directly in the table. That is risky if the table is logged or visible, so it's mostly for testing.
2. **Production:** the table names a key in the **kernel keyring** instead. dm-crypt fetches it from there. Key types include kernel-only "logon" keys, user keys, TPM-backed "trusted" keys, and "encrypted" keys decrypted inside the kernel. With trusted or encrypted keys, the raw AES key never appears in user space at all.
3. **LUKS2**, handled entirely by cryptsetup, stores a JSON header with the cipher, layout and **key slots**. Each slot holds the master key encrypted with a key derived from a passphrase, using PBKDF2 or Argon2id (memory-hard, resistant to GPU cracking), tuned to take about one second. An anti-forensic splitter spreads each slot across stripes, so wiping a slot's area destroys that access path without affecting other slots.

## A request's journey

A filesystem writing a dirty page, then reading it back:

1. **Write arrives.** The filesystem submits a write for the page. Device mapper hands it to dm-crypt.
2. **Queue for encryption.** dm-crypt takes a tracking object from its reserved pool and queues the work, or does it inline if the "no write queue" option is set.
3. **Encrypt sector by sector.** For each sector (512 bytes, or a larger configured sector size) the worker computes the IV from the sector number and encrypts it with the CPU's own cipher.
4. **Submit ciphertext.** The encrypted pages go out in a new request to the real disk. The original write completes once the disk acknowledges.
5. **Later, a read.** The read is sent straight to the disk. No crypto yet, since the ciphertext has to arrive first.
6. **Read completes.** The completion callback, running in a context where it can't sleep, queues decryption work.
7. **Decrypt and return.** A worker decrypts each sector into the caller's pages. The filesystem's page cache sees plaintext and never knew.

With an authenticated cipher stacked on dm-integrity, step 3 also produces a tag per sector, and step 7 checks it, failing the read if the data was altered.

## Tradeoffs

- **What it gives you:** encryption of every byte, including filesystem metadata and free space, for any filesystem, with nearly free performance on hardware with AES acceleration.
- **What it costs / requires:** one master key per volume, so no per-user or per-directory keys (that is what fscrypt offers, at the price of leaking some metadata). Per-CPU cipher instances multiply memory by the CPU count, which is noticeable on a 256-core machine but acceptable. Authenticated mode roughly doubles storage I/O because of dm-integrity's journal and tag area.
- **Where it bites:** plain dm-crypt gives confidentiality, **not integrity**. AES-XTS is malleable: flipping ciphertext bits corrupts the plaintext in a predictable way, undetected. Only the AEAD + dm-integrity stack catches that. On NVMe, the default workqueue path can cost far more than the cipher; the 5.9 inline options fix it but weren't made the default, because HDD workloads still benefit from the queueing and inline mode shifts CPU cost to the submitting thread. "Plain" mode, with no LUKS header, gives deniability (the disk looks like random data) but no key slots, no integrity and no recovery if the key is lost.

## How it got here

- **2003:** Christophe Saout introduced dm-crypt as a device-mapper target, replacing the loop-device-plus-cryptoloop approach. One global workqueue, CBC-mode AES, sector-number IVs. The workqueue model was chosen over alternatives for brevity.
- **2004–2008:** ESSIV to stop watermarking attacks on CBC (2.6.10), then LRW and finally XTS mode (2.6.24), today's recommendation.
- **3.x:** per-device workqueues replaced the global one for multi-core throughput.
- **4.12 (2017):** dm-integrity arrives, enabling authenticated encryption when stacked with dm-crypt.
- **5.x:** trusted and encrypted keyring keys (TPM-backed, no plaintext key in user space); **5.9 (2020)** the inline no-workqueue options; **5.17+** larger encryption sectors up to 4096 bytes.
- **Ongoing:** a target that uses hardware inline-encryption engines instead of the CPU, pluggable LUKS2 tokens (FIDO2, TPM2, smart cards), and properly encrypting hibernation images, which otherwise bypass dm-crypt.

## Related

- Technical version: [[dm-crypt]]
- [[device-mapper-explained|Device mapper]]: the framework dm-crypt plugs into
- [[dm-crypt-crypt-config-explained|dm-crypt-crypt-config]], [[dm-crypt-crypt-io-explained|dm-crypt-crypt-io]], [[dm-crypt-iv-generation-explained|dm-crypt-iv-generation]], [[dm-crypt-crypto-api-integration-explained|dm-crypt-crypto-api-integration]], [[dm-crypt-workqueue-io-path]], [[dm-crypt-key-management-explained|dm-crypt-key-management]]
- [[dm-integrity]]: stores authentication tags for authenticated mode
- [[kernel-crypto-api|Kernel crypto API]], [[kernel-keyring|Kernel keyring]]
- [[fscrypt]]: file-level encryption, the per-directory alternative
