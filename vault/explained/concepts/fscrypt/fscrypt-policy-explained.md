---
title: "fscrypt Encryption Policy — Explained"
category: explained
original: "[[fscrypt-policy]]"
subsystem: fscrypt
tags: [explained, fscrypt, encryption-policy, key-derivation]
converted: 2026-09-25
---

# fscrypt encryption policies, explained

> Plain-language companion to [[fscrypt-policy|the technical note]]. Same facts, fewer identifiers.

## The problem

When an encrypted filesystem is mounted again later, perhaps after a reboot, the kernel has to know, for every encrypted directory and file: which master key protects it, which ciphers to use, and how to derive each file's own key. None of that can be kept only in memory. It has to be recorded durably on disk, next to the data, without ever storing the secret itself.

It also has to spread automatically. Every file created inside an encrypted directory must be encrypted the same way, yet each must end up with a different key.

## The idea in one paragraph

An **encryption policy** is like a lock model stamped permanently on a safe: "AES-256-XTS, opened by key X, names padded to 32 bytes". The key itself isn't in the safe, but the label tells anyone exactly which key to bring. It's set once on an empty directory and can never change. Everything placed inside inherits the same label plus its own random serial number, a **nonce**, which makes its internal lock different from every other item's.

## Step by step

### Step 1: Setting the policy
A user calls an ioctl on an **empty** directory, passing the cipher modes, flags, and the 16-byte identifier of a master key already added to the filesystem (see [[fscrypt-key-management-explained|key management]]). The identifier is a hash computed from the key, so it names the key without revealing it.

### Step 2: Validate before writing
The kernel checks that the cipher modes are available and compiled in, that the flags make sense together, and that the key really is in the filesystem's keyring. Any failure returns before anything touches the disk.

### Step 3: Store it with a nonce
On success, the kernel generates a random 16-byte nonce, packs it with the policy into an **encryption context**, and writes that as an extended attribute on the directory. The filesystem writes it atomically; ext4 may put it inside the inode or in a separate block, journal-protected either way.

### Step 4: Never change it
A second attempt on a directory that already has a context is refused. Immutability keeps the kernel simple: no migration, no re-encryption, no half-converted states. Changing ciphers or keys means creating a new directory and moving the files.

### Step 5: Children inherit, with a fresh nonce
This is the key step. When a file, directory or symlink is created inside, the filesystem copies the parent's policy to the child but generates a **new random nonce** before the inode is finalised. Every file under one master key therefore derives a different key, because the derivation mixes in each file's nonce.

Storing a 16-byte nonce rather than a per-file random key wrapped by the master key (about 40 bytes) keeps the attribute small enough that ext4 can more often store it inside the inode. The cost: everything derives from one master key, so compromising it compromises every file.

### Step 6: v1 versus v2
- **v1** names the key with an 8-byte label chosen by a person. Nothing binds the label to the key, so a wrong key added under the same label goes undetected and decrypts to garbage. Its derivation used AES-128 in a non-standard way, shown in 2016 (Unterluggauer and Mangard) to be vulnerable to electromagnetic side-channel attacks.
- **v2** names the key by a hash of the key material, so another key can't be slipped in under the same name, and derives with standard HKDF-SHA512. It also verifies the derived key, returning "no key" instead of garbage. The downside: users manage 16-byte hex identifiers rather than friendly names.

The side-channel research was the decisive argument for a clean break rather than extending v1.

### Step 7: Flags for special cases
Three mutually exclusive flags change how keys and IVs work, because their IV schemes can't be combined:
- **direct key:** no per-file derivation; the master key is used directly, with the nonce folded into each IV. Designed for Adiantum.
- **64-bit inode+block IVs:** one shared key for the whole filesystem, with IVs built from the inode number and the block's position, so inline hardware can use one key for all files. Needs a filesystem with at most 2³² inodes.
- **32-bit inode+block IVs:** the same idea squeezed into 32 bits by hashing the inode number, for older eMMC hardware that supports only 32-bit IVs.

Other policy settings choose filename padding (4, 8, 16 or 32 bytes) and, in v2, a data unit size smaller than a block.

### Step 8: Case-insensitive directories
Since 5.17, a directory can be both encrypted and case-insensitive: names are Unicode-normalised before encryption, so equivalent names encrypt identically and case-insensitive lookup works.

## The picture

```text
 set policy on empty dir  ──validate──▶  context xattr on dir:
                                          [v2 · AES-256-XTS · names AES-256-CTS
                                           pad 32 · key id X · nonce N0]
      create file  ──inherit──▶  [same policy · key id X · nonce N1]
      mkdir sub    ──inherit──▶  [same policy · key id X · nonce N2]
                                         │
  per-file key = HKDF(master X, nonce)   different for every file
  set policy again? → refused (already exists)
```

## Tradeoffs

- **What it gives you:** a durable, secret-free record of how each file is protected; automatic inheritance; distinct per-file keys from one master key; wrong-key detection in v2.
- **What it costs / requires:** policies are permanent; v2 identifiers are opaque hex; one master key underlies everything in the tree.
- **Where it bites:** you can only set a policy on an empty directory, and changing it later means copying everything into a new one.

## How it got here

- **4.1:** v1 policies in ext4, with an 8-byte label and an AES-128-based derivation.
- **4.2:** generalised into a shared library, with F2FS support.
- **5.4:** v2 policies: HKDF-SHA512, identifiers computed from the key, and key verification. (Separately, validation was tightened to reject flag combinations that would silently make IVs collide.)
- **5.17:** encryption combined with case-insensitive directories in ext4 and F2FS.
- **6.8:** a data unit size field in v2, for encryption finer than a block.

## Related

- Technical version: [[fscrypt-policy]]
- [[fscrypt-explained|fscrypt subsystem]], [[fscrypt-key-management-explained|Key management]], [[fscrypt-inode-info-explained|Per-inode info]]
- [[fscrypt-contents-encryption-explained|Contents encryption]], [[fscrypt-filenames-encryption-explained|Filename encryption]], [[fscrypt-inline-encryption-explained|Inline encryption]]
- [[extended-attributes-and-acls-explained|Extended attributes]]
