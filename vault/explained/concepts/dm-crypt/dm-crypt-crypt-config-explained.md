---
title: "dm-crypt Per-Device Encryption State — Explained"
category: explained
original: "[[dm-crypt-crypt-config]]"
subsystem: dm-crypt
tags: [explained, dm-crypt, encryption, per-cpu]
converted: 2026-09-25
---

# dm-crypt's per-device encryption state, explained

> Plain-language companion to [[dm-crypt-crypt-config|the technical note]]. Same facts, fewer identifiers.

## The problem

An encrypted volume handles I/O from many CPUs at once, and every sector needs the cipher, the key, an IV and some memory. If each I/O had to set these up, or lock shared cipher state, encryption would crawl. And the work mustn't fail or stall just because the machine is short of memory, since the machine may be trying to write data out *to* this device to free memory.

## The idea in one paragraph

Build everything once, when the device is set up, and arrange it so I/O never has to lock or wait. One per-device object acts as **a fully configured cipher factory for the volume**: a ready-keyed cipher for every CPU, the IV scheme, reserved memory pools and the worker queues. Every in-flight request just points back to it. Because the ciphers are per-CPU and the key is loaded before the first I/O arrives, there is no shared mutable state on the I/O path.

## Step by step

### Step 1: Parse the cipher specification
When the device's table is loaded, the constructor reads the cipher string. It comes in two forms:
- **Classic:** cipher, mode and IV scheme, such as "aes-xts-plain64".
- **Crypto-API form:** a direct name from the kernel's algorithm catalogue plus an IV scheme, such as "capi:xts(aes)-plain64". This form also allows authenticated modes like AES-GCM.

The IV-scheme name selects a small table of IV functions (see [[dm-crypt-iv-generation]]).

### Step 2: Allocate one cipher per CPU
This is the key step. The constructor loops over all online CPUs and allocates a separate cipher instance for each. At encryption time, a worker uses the instance for the CPU it's running on. No locking, and the cipher's expanded key and working state stay on that CPU, which suits AES hardware acceleration whose state is CPU-local anyway. Authenticated modes get a parallel set.

### Step 3: Load the key into every cipher
The key comes either as a hex string in the table or as a reference to a key in the kernel keyring. It is loaded into every per-CPU cipher. For AES-XTS the 64-byte key is split internally into two 256-bit halves, one for the data and one for the "tweak", and each cipher computes its expanded key schedule once, here. Any temporary copy is then wiped in a way the compiler can't optimise away.

### Step 4: Keep a copy of the raw key, deliberately
The raw key stays in this object for the device's whole lifetime. The reason: if a new CPU comes online later, dm-crypt can create and key a cipher for it without asking user space for the key again. The price is that a kernel memory dump would expose the key. It sits in non-swappable kernel memory and is zeroed on teardown.

### Step 5: Reserve memory
Two reserved pools are created:
- one for per-request tracking objects and their crypto request storage (at least 256), so in-flight I/Os can always be tracked
- one for spare pages to hold ciphertext (at least 32), so encryption never stalls on allocation

### Step 6: Create the worker queues
Two high-priority worker queues are created: one for sending reads to the disk and one for the encryption and decryption work itself.

### Step 7: Teardown
When the device is removed, device mapper first makes sure no I/O is in flight. Then the key is zeroed, each per-CPU cipher is freed, the pools are drained and the queues destroyed. The ordering matters: freeing ciphers while I/O still used them would be a use-after-free.

## Options set here

- **Discard passthrough:** lets TRIM reach the disk, at the cost of revealing which sectors are unused, which leaks filesystem structure.
- **Same-CPU crypto:** encrypt on the submitting CPU to avoid bouncing work between CPUs.
- **Sector size:** the encryption unit, from 512 to 4096 bytes, matching the disk's logical block size or a multiple of it.
- **Integrity:** enables authenticated tags of a given size and mode, for use with dm-integrity.

## The picture

```text
                   ┌──────────── per-device state (built once) ─────────────┐
 table load ──────▶│ cipher spec     IV scheme functions     raw key copy   │
 (cipher + key)    │ CPU0 cipher ─ CPU1 cipher ─ CPU2 cipher ... (keyed)    │
                   │ request pool (≥256)   page pool (≥32)                  │
                   │ read-dispatch queue   crypto work queue                │
                   └───────▲──────────────▲──────────────▲──────────────────┘
                           │ back-pointer │              │
                     request A       request B      request C   (no locks)
```

## Tradeoffs

- **What it gives you:** lock-free encryption on every CPU, guaranteed progress under memory pressure, and CPU hotplug without re-asking for the key.
- **What it costs / requires:** memory grows with the number of CPUs (one keyed cipher each), which is significant on very large machines but acceptable.
- **Where it bites:** the raw key lives in kernel memory for as long as the device exists, so a kernel memory dump reveals it. Enabling discard passthrough quietly leaks which blocks are in use.

## How it got here

- **2003:** one cipher instance shared by all I/O, with lock contention.
- **2.6.x:** per-device cipher allocation and a per-device workqueue.
- **3.x:** per-CPU ciphers, removing locking at encryption time.
- **4.12:** authenticated-mode ciphers and a tag pool for dm-integrity.
- **5.9:** options to skip the workqueues for SSD performance.

## Related

- Technical version: [[dm-crypt-crypt-config]]
- [[dm-crypt-explained|dm-crypt]]: the subsystem overview
- [[dm-crypt-crypt-io]]: the per-request objects that point back here
- [[dm-crypt-iv-generation]], [[dm-crypt-key-management]], [[dm-crypt-crypto-api-integration]]
- [[kernel-crypto-api|Kernel crypto API]], [[kernel-keyring|Kernel keyring]]
