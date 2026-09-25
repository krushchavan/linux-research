---
title: "fscrypt Inode Info — Explained"
category: explained
original: "[[fscrypt-inode-info]]"
subsystem: fscrypt
tags: [explained, fscrypt, key-derivation, inode]
converted: 2026-09-25
---

# fscrypt per-inode encryption info, explained

> Plain-language companion to [[fscrypt-inode-info|the technical note]]. Same facts, fewer identifiers.

## The problem

Every read or write of an encrypted file needs that file's own key, ready to use. Producing it means finding the master key in the filesystem keyring and running a key-derivation function, which costs orders of magnitude more than following a pointer. Doing that on every I/O would be ruinous.

So the derived key has to be cached. But the cache must be built safely when two threads open the same file at once, must not keep keys around after the master key is revoked, and must wipe key material when it's no longer needed.

## The idea in one paragraph

Give each encrypted inode an **encryption passport**. It's issued lazily when the inode first passes through border control (its first open), carried in the inode's pocket for as long as the inode stays in memory, and shredded when the inode is evicted. The passport holds the derived key, the ready-to-use cipher, and a link back to the master key, so revoking the master key can find and cancel every passport issued under it.

## Step by step

### Step 1: First open triggers setup
When an encrypted file is first opened (or needed during lookup), the filesystem asks fscrypt to make sure the inode has its encryption info. At this point there's none attached.

### Step 2: Read the file's encryption context
fscrypt reads the file's stored context, which is kept in an extended attribute and usually already in memory with the inode. It holds the policy version, cipher modes, flags, the master key's identifier and the file's 16-byte **nonce**.

### Step 3: Find the master key
It looks the identifier up in the filesystem's keyring. If the key isn't there, or is being removed, the open fails with "no key".

### Step 4: Derive and verify
It runs HKDF-SHA512 over the master key, the file's nonce and a label saying what the key is for (file contents or filenames), producing a key of the right length for the cipher. With v2 policies it then checks the key against a stored hash, so the wrong master key produces a clear "no key" error rather than silent garbage.

### Step 5: Prepare the cipher
The derived bytes become either a software cipher from the kernel crypto API or a block-layer key for [[fscrypt-inline-encryption-explained|inline hardware encryption]], depending on the policy, the mount options and the hardware.

### Step 6: Install it without a lock
This is the key step. Two threads could be opening the same file for the first time, both doing the expensive derivation. Rather than hold a lock through all that work, each builds its own passport and then tries to install it with a single atomic compare-and-swap. One wins; the loser throws its copy away. That's safe because derivation is deterministic: both copies are identical. After that, every I/O reads the installed passport without any locking.

The inode is also added to the master key's list of inodes using it, so key removal can find it later.

### Step 7: Special cases
- **Direct-key policies** (for Adiantum): no per-file key is derived; the passport points to a shared key made from the master key, and the nonce goes into each IV instead.
- **32-bit IV mode** (a hardware-compatibility scheme): the inode number is hashed once, with SipHash, when the passport is built, and the hash is cached so each I/O doesn't recompute it.

### Step 8: Tear down
When the inode is evicted from the inode cache, its derived key is zeroed and freed, the cipher released, the inode removed from the master key's list, and its reference to the master key dropped. If that was the last reference, the master key itself may be freed. When a master key is being removed, fscrypt tells the kernel to evict inodes using it rather than keep them cached.

## The picture

```text
 first open(file)
   read context (policy, key id, nonce)
   find master key ── missing? → "no key"
   HKDF(master, nonce, "contents") → verify → cipher or hardware key
   install with compare-and-swap ── lost the race? discard own copy
   add inode to master key's list
                    │
   every read/write: use cached passport (no lookup, no lock)
                    │
 inode evicted:  zero key · free cipher · drop master key reference
```

## Tradeoffs

- **What it gives you:** derivation once per inode rather than per I/O, lock-free access afterwards, and a way to revoke everything derived from a master key.
- **What it costs / requires:** memory for keys and ciphers on every cached encrypted inode; duplicated work when threads race on first open.
- **Where it bites:** keys live as long as the inode stays cached, not until the last file is closed, a deliberate choice to avoid re-deriving on every open of small, often-used files. And because setup is lazy, a missing key shows up at open, not during path lookup.

## How it got here

- **4.1:** the per-inode encryption info first attached to inodes.
- **5.4:** a link back to the master key for v2 policies, plus tracking of which inodes use each key, enabling proper key removal.
- **5.9:** it can hold a block-layer key for inline encryption.
- **6.8:** the data unit size is recorded, for sub-block encryption.

## Related

- Technical version: [[fscrypt-inode-info]]
- [[fscrypt-explained|fscrypt subsystem]], [[fscrypt-key-management-explained|Key management]], [[fscrypt-contents-encryption-explained|Contents encryption]], [[fscrypt-filenames-encryption-explained|Filename encryption]], [[fscrypt-inline-encryption-explained|Inline encryption]]
- [[inode-cache-explained|Inode cache]], [[kernel-crypto-api-explained|Kernel crypto API]]
