---
title: "dm-crypt Workqueue I/O Path — Explained"
category: explained
original: "[[dm-crypt-workqueue-io-path]]"
subsystem: dm-crypt
tags: [explained, dm-crypt, workqueue, nvme, performance]
converted: 2026-09-25
---

# dm-crypt's workqueue I/O path, explained

> Plain-language companion to [[dm-crypt-workqueue-io-path|the technical note]]. Same facts, fewer identifiers.

## The problem

A disk read finishes in an interrupt-like completion context. That is a bad place to decrypt: sleeping isn't allowed, the CPU's vector (SIMD) registers may not be usable, and the stack is small. The crypto code wants the opposite: a normal thread that can use SIMD instructions, wait on a hardware accelerator, and allocate memory.

So dm-crypt moves its crypto work onto kernel worker threads. That was a clear win on spinning disks. On NVMe SSDs it turned out to be the single biggest cost of disk encryption.

## The idea in one paragraph

Think of **two rooms in a mail-sorting facility**. Reads first go to a loading dock (one queue), whose only job is to get requests to the disk. When the data comes back, it moves to the sorting room (a second queue) to be decrypted. Writes go straight to the sorting room to be encrypted, then out. Keeping the loading dock separate means reads keep flowing to the disk even when the sorting room is swamped. Since 5.9, fast-storage users can skip both rooms and do the crypto inline.

## Step by step

### Step 1: Create two worker queues
When the device is set up, dm-crypt creates two high-priority queues whose workers can run on any CPU, so encryption spreads across all cores:
- the **read-dispatch queue**, which only sends reads to the disk
- the **crypto queue**, which encrypts writes and decrypts reads

### Step 2: Writes: queue, encrypt, submit
A write arrives, gets its tracking object, and is queued on the crypto queue; dm-crypt returns to its caller right away. A worker then encrypts every sector (IV, then cipher), gathers the ciphertext into a new request aimed at the real disk, and submits it. When the disk finishes, the completion callback records any error and completes the original write.

### Step 3: Reads, stage 1: get them to the disk
This is the key design choice for reads. A read is dispatched through its own queue, not the crypto queue. If reads shared the crypto queue, a burst of writes could fill it, and reads would sit waiting while the disk was idle, ready to serve them.

### Step 4: Reads, stage 2: decrypt in a worker
When the disk completes the read, the completion callback runs where crypto isn't allowed. It queues the request on the crypto queue. A worker decrypts each sector in place, and the original read completes with plaintext.

### Step 5: Why this hurts on NVMe
The queues were built for hard disks, where:
- each I/O takes 5–10 ms, so about 10 µs of queueing is negligible
- ordering requests by position helped throughput
- few requests were outstanding at once

NVMe flips all three: I/O takes 50–100 µs, so 10 µs is a big fraction; the controller reorders internally; and 64–128 outstanding requests are normal, which a worker thread serializes.

Cloudflare's 2020 measurements on a RAM disk (no device latency at all) showed dm-crypt cutting throughput from about 1,126 MB/s to about 147 MB/s, a 7× loss, caused almost entirely by queueing and context switches across four queue levels, not by AES.

### Step 6: The fix: inline paths (5.9)
Two per-device options let you bypass the queues:
- **No write queue:** encrypt directly in the submitting thread, build the ciphertext request and submit it before returning. With AES-NI this is pure on-CPU work with no context switch.
- **No read queue:** send the read to the disk immediately, and when it completes, decrypt right in the completion context. That's safe because the block layer calls completion in a context where this is allowed, and AES-NI decryption never sleeps.

With both, writes pass through two queue levels and reads through one. Cloudflare measured about 640 MB/s, 4.3× better than the default path. cryptsetup and the crypttab file can turn both on. A further option skips one more hand-off when submitting encrypted writes.

## The picture

```text
 DEFAULT
 write ─▶ [crypto queue] ─▶ encrypt ─▶ disk ─▶ done
 read  ─▶ [read-dispatch queue] ─▶ disk ─▶ completion ─▶ [crypto queue] ─▶ decrypt ─▶ done
           (separate, so write bursts can't block reads from reaching the disk)

 INLINE (5.9 options, for SSD/NVMe)
 write ─▶ encrypt in caller's thread ─▶ disk ─▶ done
 read  ─▶ disk ─▶ decrypt in completion ─▶ done

 Cloudflare, RAM disk:  raw ~1,126 MB/s │ default ~147 MB/s │ inline ~640 MB/s
```

## Tradeoffs

- **What it gives you:** crypto runs in a safe context, spread across all CPUs, and reads can't be starved by writes.
- **What it costs / requires:** every request pays context switches and queue hops, about 10 µs each, which dominates on fast storage.
- **Where it bites:** the inline options are not the default. Changing the default could have regressed hard-disk workloads, which still benefit from queueing, so the kernel left existing behaviour alone and made inline an explicit opt-in. SSD users who don't turn it on pay a large, invisible penalty.

## How it got here

- **2003:** one global, ordered workqueue serialized all crypto work, devastating multi-core throughput.
- **2.6:** a workqueue per device, with encryption and decryption separated.
- **3.x:** workers free to run on any CPU, and a separate read-dispatch queue to stop writes starving reads.
- **5.9 (2020):** the inline read and write options, upstreamed from Cloudflare's work.

## Related

- Technical version: [[dm-crypt-workqueue-io-path]]
- [[dm-crypt-explained|dm-crypt]]: the subsystem overview
- [[dm-crypt-crypt-io-explained|Per-request context]]: the objects these queues carry
- [[dm-crypt-crypt-config-explained|Per-device encryption state]]: holds the queues and options
- [[dm-crypt-crypto-api-integration-explained|Crypto API integration]]: why AES-NI never needs the asynchronous path
- [[block-explained|Block layer]]
