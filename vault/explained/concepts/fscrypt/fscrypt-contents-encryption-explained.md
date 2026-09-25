---
title: "fscrypt Contents Encryption — Explained"
category: explained
original: "[[fscrypt-contents-encryption]]"
subsystem: fscrypt
tags: [explained, fscrypt, encryption, page-cache]
converted: 2026-09-25
---

# fscrypt contents encryption, explained

> Plain-language companion to [[fscrypt-contents-encryption|the technical note]]. Same facts, fewer identifiers.

## The problem

With [[fscrypt-explained|fscrypt]], the data of an encrypted file must be ciphertext whenever it's on disk, yet programs reading and writing it must see ordinary plaintext without doing anything special. Somewhere between memory and storage, every block has to be sealed on the way out and unsealed on the way in.

The awkward part is the page cache. It's shared by every reader of the file and must stay plaintext. So on the way *out* you can't encrypt the cached page where it sits, or the next read would get gibberish. And each block has to be encrypted differently from every other, or identical plaintext in two places would show up as identical ciphertext.

## The idea in one paragraph

Treat the page cache as a **clean room** where everything is plaintext, the disk as the **outside world** where everything is in sealed envelopes, and contents encryption as the **mailroom** between them. Pages arriving from disk are unsealed in place before anyone sees them. Pages leaving are sealed **on a copy** (a bounce page), so the plaintext in the clean room is never disturbed. Each block's seal is unique because its IV comes from its position in the file. If the storage controller can do the sealing itself (inline encryption), the copy isn't needed.

## Step by step

### Step 1: The data unit and its IV
Encryption works in **data units**, by default one filesystem block (typically 4096 bytes). v2 policies can choose smaller units, down to 512 bytes, which helps Btrfs compressed extents and UBIFS's variable-size chunks.

Each unit's IV (the value that makes its encryption unique) is its index within the file. So the same plaintext at two positions gives different ciphertext. Variants exist for hardware: one combines the inode number with the unit index so files can share a hardware key, another fits a 32-bit limit by adding the index to a hash of the inode number.

### Step 2: Reading
The filesystem reads encrypted blocks from disk into the page cache. Before marking the pages valid, it walks each page unit by unit, computes each IV, and decrypts in place with the file's cipher. The page stays locked throughout, so nobody can see half-decrypted data. With inline encryption this step disappears: the storage controller decrypts during the transfer and pages arrive as plaintext.

### Step 3: Writing, in software
This is the key step. At writeback, fscrypt takes a **bounce page** from a pre-reserved pool, copies the plaintext into it, encrypts the copy, and the filesystem writes the bounce page instead of the original. When the I/O completes, the bounce page is freed. The plaintext page stays in the cache for future reads.

The cost is memory: during heavy writeback, data can exist twice at once, plain and encrypted. The pool is reserved in advance so writeback doesn't stall when memory is tight, which is exactly when writeback most needs to make progress.

### Step 4: Writing, with inline encryption
With the inline-encryption mount option, fscrypt attaches the key and starting IV to each I/O request. The block layer hands them to the storage controller, whose crypto engine encrypts during the transfer. No bounce page is needed, and the plaintext page goes to the device directly.

The IVs across a single request must be consecutive, so ext4 and F2FS split requests wherever the numbering breaks rather than leaving it to the block layer.

### Step 5: Filesystems without pages (UBIFS)
UBIFS runs on raw flash rather than a block device and stores variable-size data nodes, so the page-based routines don't fit. It uses routines that encrypt or decrypt any buffer in place, using the filesystem's logical address as the unit index.

### Step 6: Direct I/O
Direct I/O skips the page cache, so there's nowhere to put a bounce page. It works only with inline encryption (in hardware or the software fallback), and only when the file offset, length and buffer address all line up with data units. Otherwise it falls back to buffered I/O.

### Step 7: Holes
When space is allocated for a hole (for example with `fallocate`), fscrypt writes encrypted zeros, so reading that range returns zeros rather than ciphertext garbage.

### Step 8: What's forbidden
Some operations would break the scheme and are refused on encrypted files:
- collapsing or inserting ranges, and online defragmentation: these move data to different positions, which changes the IVs it should have
- direct I/O without inline encryption: misaligned buffers would need partial-unit encryption, which XTS can't do safely
- DAX (direct memory access to storage), which bypasses the page cache and so the bounce-page path
- ext4 data journaling, which would log ciphertext and make journal recovery need the key

## The picture

```text
          page cache = plaintext ("clean room")
   ┌──────────────────────────────────────────────┐
   │  plaintext page ───copy──▶ bounce page        │
   │        ▲                      │ encrypt       │
   │ decrypt in place              │ (IV = unit #) │
   └────────┼──────────────────────┼───────────────┘
            │ read                 │ write
         ciphertext on disk ◀──────┘

 inline mode:  plaintext page ──(key + IV attached)──▶ controller encrypts during transfer
```

## Tradeoffs

- **What it gives you:** transparent plaintext for programs, unique ciphertext per position, no size overhead (AES-XTS preserves length and each unit is independent), and optional hardware offload.
- **What it costs / requires:** double memory for data under software writeback; restrictions on direct I/O, DAX, range shifting and data journaling.
- **Where it bites:** the cache holds plaintext, so while a file is cached, a process with enough privilege can read its contents without the key. fscrypt defends against offline attacks; isolating live processes is a job for access control such as SELinux.

## How it got here

- **4.1:** AES-256-XTS contents encryption in ext4.
- **4.8:** Adiantum, for ARM devices without AES hardware.
- **5.0:** UBIFS support through buffer-level routines.
- **5.9:** inline encryption; bounce pages no longer needed on inline-crypto mounts.
- **6.8:** sub-block data units, which meant reworking IVs to count data units rather than blocks.

## Related

- Technical version: [[fscrypt-contents-encryption]]
- [[fscrypt-explained|fscrypt subsystem]], [[fscrypt-inode-info-explained|Per-inode encryption info]], [[fscrypt-inline-encryption-explained|Inline encryption]]
- [[page-cache-explained|Page cache]], [[writeback-infrastructure-explained|Writeback]], [[block-explained|Block layer]], [[kernel-crypto-api|Kernel crypto API]]
- [[dm-crypt-explained|dm-crypt]]: encryption below the filesystem, for contrast
