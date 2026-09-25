---
title: "fscrypt Inline Encryption — Explained"
category: explained
original: "[[fscrypt-inline-encryption]]"
subsystem: fscrypt
tags: [explained, fscrypt, inline-encryption, blk-crypto, hardware-wrapped-keys]
converted: 2026-09-25
---

# fscrypt inline encryption, explained

> Plain-language companion to [[fscrypt-inline-encryption|the technical note]]. Same facts, fewer identifiers.

## The problem

Encrypting file data in software costs CPU time, and on writes it costs an extra copy of every page (the bounce page described in [[fscrypt-contents-encryption-explained|contents encryption]]). On phones and embedded chips (Qualcomm, Mediatek), the storage controller already contains an **inline crypto engine** that can encrypt and decrypt data as it streams to and from storage, at hardware speed and with no extra copies.

To use it, the kernel needs a way to tell the hardware "this I/O belongs to this key, starting at this position", without filesystems having to care whether the hardware exists. And for high-security devices there's a further wish: keep the real encryption key out of main memory entirely.

## The idea in one paragraph

Think of a **tollbooth with a built-in currency converter**. Instead of converting your money first (encrypting in software), you hand over your cash and the booth converts it as the gate lifts. fscrypt attaches the file's key and the starting IV to each I/O request; the block layer programs the controller's engine, which encrypts or decrypts every data unit during the transfer. If the hardware can't do what's asked, a software stand-in **pretends to be the hardware**, so nothing above it knows the difference.

## Step by step

### Step 1: Opt in per mount
Inline encryption is turned on with a mount option. On such a filesystem, when a file's key is prepared, fscrypt creates a **block-layer key** (a key object the block layer understands) instead of, or as well as, a software cipher.

### Step 2: Attach the key to each I/O
When ext4 or F2FS builds an I/O request for file data, fscrypt attaches a small crypto context to it: a pointer to the file's block-layer key and the **data unit number**, the IV of the first data unit in the request.

### Step 3: The block layer programs the hardware
If the storage driver registered inline-crypto support, the block layer loads the key and starting number into the engine before issuing the I/O. The engine applies AES-XTS (or the configured mode) to each data unit during the transfer, incrementing the number automatically. Data is encrypted on the way to storage, decrypted on the way back, with no software involved.

### Step 4: Keep the numbering continuous
This is the key step. Because the hardware increments the data unit number itself and can't skip values, every request must cover **consecutive** numbers: units 5, 6, 7, 8… A request that jumped from 5 to 10 would get the wrong IVs for everything after the jump.

Filesystems are responsible for this, because only they know where holes and differently keyed extents are. Before building each request, they ask fscrypt how many blocks can go in it before the numbering would break, and they split there. Pushing this to the filesystem avoids teaching the block layer about extent layouts.

### Step 5: Merging requests
The I/O scheduler likes to merge adjacent requests. With inline encryption, two requests can merge only if they use the same key and their numbers follow on from each other.

### Step 6: Software fallback
If the hardware supports inline crypto but not the needed algorithm or key size, the block layer's fallback takes over: it allocates bounce pages, encrypts or decrypts in a background worker using the kernel crypto API, and sends on plain I/O. fscrypt can't tell the difference, so filesystems can always mount with inline encryption on. The catch is that the fallback may be *slower* than fscrypt's own software path, because of the worker overhead.

### Step 7: Hardware-wrapped keys (5.13)
For the strongest protection, the real key never appears in main memory:
1. at provisioning, the hardware produces a **wrapped key**: the real key encrypted under a secret held only inside the engine
2. the operating system stores only the wrapped blob and passes it to the engine
3. the engine unwraps it internally and uses the real key only inside the hardware
4. for filenames and other non-content keys, which software must handle, the hardware derives a *different* software secret (using a standard SP800-108 derivation with AES-256-CMAC), and fscrypt derives its keys from that

This defends against memory-extraction attacks such as cold boot or DMA-based reads. Even a fully compromised kernel can't pull the content key out. The cost is that wrapped keys are tied to that hardware (and boot session), so a filesystem image can't be decrypted on another machine. They also need the inline mount option and a policy where all files share one hardware key, distinguished only by IV (the inode-number IV schemes); today only ext4 and F2FS support them.

## The picture

```text
 file write (inline mount)
   filesystem builds I/O ── split where unit numbers break ──┐
   fscrypt attaches: [key, start unit #5]                     │
                         │                                    │
                    block layer                               │
             hardware can do it? ──yes──▶ program engine ──▶ controller encrypts
                   │ no                     units 5,6,7,8… during transfer
                   ▼
          fallback worker: bounce pages + software cipher ──▶ plain I/O

 wrapped key:  engine holds secret ─ unwraps blob inside hardware
               software gets only a derived secret (for filenames)
```

## Tradeoffs

- **What it gives you:** encryption at hardware speed with no CPU cipher work and no bounce pages, the same code path whether or not hardware is present, and optionally content keys that never touch main memory.
- **What it costs / requires:** filesystems must keep unit numbers continuous and split requests to match; merges are more restricted; wrapped keys lock data to one device.
- **Where it bites:** the fallback may be slower than plain software encryption, so enabling the mount option on unsupported hardware can cost performance.

## How it got here

- **5.9:** initial inline encryption through the block layer. The design debate over who owns keys settled on fscrypt owning the key's lifetime, with the block layer as a pure transport.
- **5.13:** hardware-wrapped keys and derivation of the software secret by the engine; the derivation was standardised on SP800-108 with AES-256-CMAC.
- **5.18:** the "how far until the numbering breaks" helper for ext4 and F2FS.
- **6.16:** SP800-108 standardisation for wrapped-key derivation.

## Related

- Technical version: [[fscrypt-inline-encryption]]
- [[fscrypt-explained|fscrypt subsystem]], [[fscrypt-contents-encryption-explained|Contents encryption]], [[fscrypt-key-management-explained|Key management]], [[fscrypt-inode-info-explained|Per-inode info]]
- [[block-explained|Block layer]], [[blk-mq-explained|Multi-queue block layer]], [[kernel-crypto-api-explained|Kernel crypto API]]
