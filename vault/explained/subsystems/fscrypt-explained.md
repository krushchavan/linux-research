---
title: "fscrypt — Explained"
category: explained
original: "[[fscrypt]]"
subsystem: fscrypt
tags: [explained, fscrypt, encryption, filesystems]
converted: 2026-09-25
---

# fscrypt, explained

> Plain-language companion to [[fscrypt|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

If someone gets hold of a disk (a stolen phone, a discarded drive), they can read every file on it. Whole-disk encryption such as [[dm-crypt-explained|dm-crypt]] protects against that, but it has one key for the whole volume: every user's files unlock together, and nothing can stay unencrypted.

Phones and multi-user systems want something finer: **per-directory encryption**, where each user's (or app's) directory has its own key, can be locked while others stay unlocked, and sits on the same volume as unencrypted files. That means encryption has to happen *inside* the filesystem, not beneath it. It also has to protect filenames, not only contents, and ideally use the encryption hardware built into modern phone storage.

## The big picture

fscrypt is a library that filesystems (ext4, F2FS, UBIFS, CephFS, and Btrfs with work in progress) call at key moments. It's built as a **key-derivation tree rooted at a master key**. A user unlocks a directory by giving the kernel a master key. The kernel never encrypts with that key directly: each encrypted file stores a random 16-byte **nonce**, and the kernel derives that file's own key from the master key and the nonce. Locking wipes the derived keys from memory; the encrypted data stays on disk until the master key is added again.

```text
 user space: set policy on empty dir · add / remove master key
                    │
     filesystem keyring (per mounted filesystem): master keys
                    │ derive (HKDF-SHA512) with each file's nonce
          per-file keys ─────────────┬───────────────────────┐
                                      │                       │
 filesystem (ext4, F2FS…) ─ hooks ─▶ software crypto      inline hardware crypto
   open · lookup · read · write      (kernel crypto API)   (block layer, storage controller)
                                      │                       │
                         page cache holds plaintext; disk holds ciphertext
```

What stays in the clear: sizes, timestamps, extended attributes and other filesystem metadata. That's deliberate, so repair tools such as fsck work without the key. The threat model is **offline physical access**: an attacker with the raw disk learns sizes and times, but not contents or names.

## The pieces

### Encryption policies
A **policy** says which ciphers and which master key protect a directory tree. It's set once, by an ioctl on an **empty** directory, and never changes. Every file and subdirectory created underneath inherits it, each with a fresh random nonce.

There are two versions:
- **v1** (legacy) names the key with an 8-byte label chosen by a person, and derives per-file keys with a scheme later shown vulnerable to electromagnetic side-channel attacks.
- **v2** names the key by a hash of the key itself, derives with HKDF-SHA512, and can reliably reject a wrong key.

v1 is kept indefinitely because a huge number of Android devices use it. See [[fscrypt-policy|policies]].

### Key management
Master keys live in a **keyring attached to the mounted filesystem**, not in a process's keyring. With v1, keys sat in per-session or per-user keyrings, so a key added through `sudo` or a helper under another user ID was invisible to the actual user; backup daemons and FUSE helpers hit the same problem. The filesystem keyring is visible to every process on that filesystem.

Adding a key records which users added it (a per-user count) and stores a hash for later verification. Removing it:
1. drops that user's claim; when no claims remain, the key is marked as being removed
2. asks the kernel to evict every cached inode using it, wiping their derived keys
3. if some files are still open they can't be evicted, so the key is reported as **incompletely removed**, and background work retries until they close
4. only then is the master key's secret wiped and freed

See [[fscrypt-key-management|key management]].

### Per-file encryption state
The first time an encrypted file is opened, fscrypt reads its stored policy and nonce, finds the master key, derives the file's key, prepares either a software cipher or a hardware key handle, and attaches the result to the in-memory inode for later opens to reuse. Directories also get a separate filename key. With v2, fscrypt checks the key hash and returns "no key" rather than silently decrypting to garbage when the wrong master key was added. See [[fscrypt-inode-info|per-inode info]].

### Contents encryption
This is the key design choice. fscrypt works at the **page cache boundary**, not at the block device: the page cache holds plaintext, and encryption happens as data moves between memory and disk.
- **Reading:** ciphertext is read from disk into the page cache, then decrypted in place before anyone sees it.
- **Writing:** encrypting in place would destroy the plaintext copy that later reads need. So at writeback, fscrypt encrypts into a temporary **bounce page**, writes that, and keeps the plaintext page cached.

Each data unit's IV comes from its position in the file, optionally mixed with the inode number. Special IV schemes exist for hardware that shares one key across files or only supports 32-bit IVs (some eMMC storage). A "direct key" mode for Adiantum puts the file nonce straight into the IV and skips per-file derivation. See [[fscrypt-contents-encryption|contents encryption]].

### Filename encryption
Directory entries are encrypted with the directory's filename key (derived separately from content keys), each name in one pass. Short names are padded to 16 bytes and longer ones to a configurable boundary, hiding exact lengths. Names that would be too long once encoded as text are stored as a hash prefix, with the full ciphertext kept elsewhere.

Without the key, directory listings still work: they show **no-key names**, encoded ciphertext that programs can pass back to operations that only need to identify a file, not to know its name. See [[fscrypt-filenames-encryption|filename encryption]].

### Inline hardware encryption
With the right mount option, fscrypt hands the key and IV to the block layer alongside each I/O instead of encrypting in software, and the storage controller's crypto engine encrypts or decrypts during the transfer: no CPU cipher work and no bounce pages. If the hardware can't handle the algorithm or IV size, a software fallback does it transparently.

One constraint: each I/O must cover consecutive data-unit numbers, so filesystems split I/O where the numbering breaks. **Hardware-wrapped keys** go further: the raw key never exists in main memory, only a wrapped blob the hardware unwraps internally, with a separate derived secret for filenames. See [[fscrypt-inline-encryption|inline encryption]].

## A request's journey

Opening and reading an encrypted file after the user has unlocked its directory:

1. **Path lookup.** Walking the path, the filesystem uses the directory's filename key to match the plaintext name against encrypted entries.
2. **Open.** On the first open, fscrypt reads the file's stored policy and nonce and looks up the master key in the filesystem keyring.
3. **Derive.** It runs HKDF-SHA512 over the master key and nonce to get the file's key, and prepares a software cipher (or a hardware key handle).
4. **Attach.** The prepared state is attached to the in-memory inode; later opens reuse it.
5. **Read.** A read that misses the cache brings ciphertext from disk, and it is decrypted in the page cache (software), or it arrives already decrypted by the storage controller (inline).
6. **Lock later.** When the key is removed, cached inodes are evicted and derived keys wiped; open files hold things up until they close.

## Tradeoffs

- **What it gives you:** per-directory keys on a shared volume, encrypted names, independent locking, small per-file metadata (a 16-byte nonce rather than a wrapped key of about 40 bytes, which matters for ext4 storing attributes inside the inode), and hardware offload.
- **What it costs / requires:** no authentication, since the ciphers (AES-XTS, Adiantum, HCTR2) don't detect tampering, so corruption detection relies on filesystem checksums; one master key compromise exposes every file derived from it; bounce pages on software writes.
- **Where it bites:** metadata is visible by design, which surprises people expecting full-disk secrecy. A key can't really be removed while files using it are still open.

## How it got here

- **4.1–4.2:** born inside ext4, then generalised into a shared library with F2FS support.
- **5.4:** v2 policies with HKDF-SHA512 and the filesystem keyring, replacing a weak derivation scheme and session keyrings; key status and incomplete-removal reporting followed in 5.7.
- **5.9:** inline hardware encryption through the block layer; hardware-wrapped keys in 5.13.
- **6.6:** CephFS support; around 6.7–6.8, sub-block data units and Btrfs per-extent encryption, still in progress.

## Related

- Technical version: [[fscrypt]]
- [[fscrypt-policy|Policies]], [[fscrypt-key-management|Key management]], [[fscrypt-inode-info|Per-inode info]], [[fscrypt-contents-encryption|Contents encryption]], [[fscrypt-filenames-encryption|Filename encryption]], [[fscrypt-inline-encryption|Inline encryption]]
- [[dm-crypt-explained|dm-crypt]]: whole-device encryption, for contrast
- [[kernel-crypto-api|Kernel crypto API]], [[block-explained|Block layer]], [[page-cache-explained|Page cache]]
