---
title: "dm-crypt Per-Request Context — Explained"
category: explained
original: "[[dm-crypt-crypt-io]]"
subsystem: dm-crypt
tags: [explained, dm-crypt, encryption, bio]
converted: 2026-09-25
---

# dm-crypt's per-request context, explained

> Plain-language companion to [[dm-crypt-crypt-io|the technical note]]. Same facts, fewer identifiers.

## The problem

Device mapper hands dm-crypt each I/O request through a callback that must return quickly. But the work dm-crypt has to do is slow and multi-stage: encrypt many sectors, send the result to disk, wait, and for reads, decrypt afterwards. Some of those stages happen on other threads or in completion callbacks, and any of them can fail partway through a multi-sector request.

Something has to remember, across all those hand-offs, which original request this is, how far along it is, and whether anything has gone wrong.

## The idea in one paragraph

Each request gets a small tracking object, like **a flight manifest** that travels with the luggage. It's created when the request arrives, goes with it through every hand-off (queue, disk, completion, decryption), and records the first error seen. When all sectors are done, the original request is completed with whatever error the manifest recorded, and the manifest is recycled.

## Step by step

### Step 1: Create the manifest, for free
When a request arrives, dm-crypt finds its tracking object in a spare area that device mapper already allocated alongside the request, sized for exactly this purpose. There's no separate allocation per request, and the object sits right next to the request in memory, which helps the cache. It records a pointer to the device's encryption state, the original request, and "no error yet".

### Step 2a: Writes: encrypt first, then send
A write carries plaintext that must be encrypted before it reaches the disk. The tracking object is queued to a crypto worker. The worker encrypts every segment, builds a new request holding the ciphertext, and sends that to the real disk.

### Step 2b: Reads: send first, decrypt later
A read can't be decrypted until the ciphertext arrives. So the request goes to the disk right away (directly, or via the read-dispatch queue).

### Step 3: The completion callback
When the disk finishes, a completion callback runs, in a context where sleeping isn't allowed.
- **For a read**, it records any disk error and queues the tracking object for decryption on a crypto worker.
- **For a write**, it records any disk error and completes the original request back to the filesystem.

### Step 4: The core loop, sector by sector
This is the key step, shared by encryption and decryption. The loop keeps a cursor into the request's pages and, for each sector (512 bytes, or the configured sector size):
1. computes the sector's IV from its sector number
2. points the CPU's cipher at the input pages, output pages, IV and length
3. encrypts or decrypts

With a synchronous cipher like AES-NI, this finishes immediately. With a hardware offload engine, the cipher may say "in progress" and call back later; the callback resumes the loop from the saved cursor. On x86 with AES-NI, the asynchronous path never happens in practice.

### Step 5: Errors: first one wins
The tracking object holds one error value. A disk failure or a crypto failure (including an authentication-tag mismatch in authenticated mode) is recorded there, and the original request completes with it, which reaches the filesystem as an I/O error. There is no per-sector error map: dm-crypt doesn't do partial recovery, so any failure fails the whole request.

### Step 6: The inline shortcut (5.9+)
With the "no read queue" or "no write queue" options, the crypto loop runs directly in the submitting thread instead of being queued. That removes two context switches per request, which is a big latency win on NVMe, where queueing cost dwarfs the cipher cost. The tracking object is still used, it just never goes onto a queue. A further option also skips a queue for submitting the final encrypted write.

## The picture

```text
 WRITE                                       READ
 request ─▶ manifest (in spare area)         request ─▶ manifest
    │ queue (or inline)                         │ send to disk now
    ▼                                           ▼
 crypto worker: for each sector              disk returns ciphertext
   IV → encrypt                                 │ completion callback
    │                                           │ (can't sleep) → queue
    ▼                                           ▼
 ciphertext request ─▶ disk                  crypto worker: for each sector
    │ completion callback                      IV → decrypt
    ▼                                           │
 complete original (with first error)        complete original (with first error)
```

## Tradeoffs

- **What it gives you:** one small object that follows a request through every stage, costs no extra allocation, and supports both instant and callback-style crypto hardware.
- **What it costs / requires:** supporting asynchronous crypto hardware adds code that is dead on typical x86 machines.
- **Where it bites:** one error anywhere fails the whole request. And on fast SSDs, the default queued path adds context switches that cost far more than the encryption itself unless the inline options are used.

## How it got here

- **2003:** the tracking object introduced, queued on a single global workqueue and allocated from its own pool.
- **3.x:** moved into device mapper's per-request spare area; separate per-device crypto and read-dispatch queues.
- **5.9 (2020):** inline processing, so the object may never be queued at all.

## Related

- Technical version: [[dm-crypt-crypt-io]]
- [[dm-crypt-explained|dm-crypt]]: the subsystem overview
- [[dm-crypt-crypt-config-explained|Per-device encryption state]]: what each tracking object points back to
- [[dm-crypt-iv-generation]], [[dm-crypt-crypto-api-integration]], [[dm-crypt-workqueue-io-path]]
- [[block-explained|Block layer]]: where completions come from
