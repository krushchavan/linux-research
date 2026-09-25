---
title: "fscrypt Key Management — Explained"
category: explained
original: "[[fscrypt-key-management]]"
subsystem: fscrypt
tags: [explained, fscrypt, keyring, hkdf, key-removal]
converted: 2026-09-25
---

# fscrypt key management, explained

> Plain-language companion to [[fscrypt-key-management|the technical note]]. Same facts, fewer identifiers.

## The problem

Encrypted directories are only as good as the handling of their master keys. The kernel has to accept a key from user space, find it again whenever an encrypted file is opened, and, when the user logs out or locks the directory, make sure every key derived from it is wiped so the files really become unreadable again.

Several things make this hard:
- **Sharing.** Several users (or a user plus `sudo`) may need the same key, and one shouldn't be able to lock out the others.
- **Wrong keys.** A user who typed the wrong passphrase shouldn't silently get garbage; an attacker shouldn't be able to plant a bogus key under a known name.
- **Open files.** Files still open when a key is removed can't simply vanish.

## The idea in one paragraph

Keep a **filesystem-wide key safe with a per-user ledger**. Adding a key puts it in a keyring attached to the mounted filesystem and writes the adding user's name in its ledger; others adding the same key add their names too. Removing a key crosses out only your own name. When the last name goes, the safe is shredded: the secret is wiped, no new files can be unlocked, and every cached inode using it is evicted. Files already open keep working until they close.

## Step by step

### Step 1: Adding a key
A user passes 16–64 bytes of key material to an ioctl. The kernel identifies it with a **key specifier**: for v2, a 16-byte identifier computed from the key itself (so different keys can never share an identifier); for legacy v1, an 8-byte label chosen by the user. If the key is already in the filesystem's keyring, the kernel adds this user to its ledger. Otherwise it creates a new master key record holding the secret, the identifier and a verification hash, and inserts it.

### Step 2: Why a filesystem keyring
v1 kept keys in the process's session keyring. Running `sudo foo` started a different session, so it couldn't see keys the ordinary user had added. The v2 keyring belongs to the mounted filesystem and is visible to every process regardless of user or session. The tradeoff is that keys are no longer inherited from the login session automatically; tools must add them explicitly through the ioctl.

### Step 3: Unlocking files lazily
Files aren't touched when a key is added. The first time an encrypted file is opened, fscrypt reads its stored key identifier, finds the master key, derives the file's own key (see [[fscrypt-inode-info-explained|per-inode info]]) and adds the inode to the master key's list of inodes in use. Each such inode holds a reference that keeps the master key record alive.

### Step 4: Deriving keys with HKDF
Per-file keys come from HKDF-SHA512, a standard two-phase construction: *extract* turns the raw key into a uniform pseudorandom key, and *expand* stretches it into as many bytes as needed. Each expansion uses a label saying what the output is for, plus (for file keys) the file's 16-byte nonce. The key identifier is itself an expansion with a different label, so publishing it reveals nothing about the key.

SHA-512 was chosen over SHA-256 because an AES-256-XTS key is 512 bits, exactly one SHA-512 output; SHA-256 would need two rounds, roughly 30% slower. v1's scheme, built on AES-128 in a non-standard way, was shown vulnerable to electromagnetic side-channel analysis. HKDF costs two HMAC operations per file open, negligible next to disk latency.

### Step 5: Verifying the key (v2)
After derivation, the kernel computes a hash with yet another label and compares it with the hash stored when the key was added. A mismatch means the wrong key, and the open fails with "no key" rather than decrypting to garbage. This also stops an attacker from adding a wrong key under a known identifier to deny access to everyone.

### Step 6: Removing a key
This is the key step. Removal first crosses out only the caller's entry. If other users still hold the key, it stays usable, and the caller is told so. When the last entry goes:
1. the secret is zeroed in memory and the key is marked absent, so no new files can be unlocked
2. every cached inode on the key's list is told to drop, and the kernel evicts each once nothing else refers to it, wiping its derived key and releasing its reference

### Step 7: Files still open
An inode with open file descriptors can't be evicted, so its reference keeps the record alive and the key is reported as **incompletely removed**. A background worker retries eviction periodically; as files close, the inodes go and the key finally becomes **absent**. User space can poll the key status ioctl to watch this. This state exists so users needn't close every file before removing a key.

### Step 8: Hardware-wrapped keys (5.13)
With inline encryption hardware, the stored secret can be a wrapped blob rather than raw bytes. Content keys are passed to the hardware still wrapped. For filenames, which software must encrypt, the hardware derives a separate software secret, and fscrypt's own HKDF starts from that.

## The picture

```text
 filesystem keyring
 ┌──────────────────────────────────────────────────┐
 │ master key record                                 │
 │   secret · identifier · verification hash          │
 │   ledger: alice, bob          ◀── add / remove      │
 │   inodes in use: #12, #57, #90 (refs keep it alive)│
 └──────────────────────────────────────────────────┘
 remove(alice) → bob still listed → key stays
 remove(bob)   → wipe secret · mark absent · evict inodes
                 #57 still open → "incompletely removed" → retry until closed → "absent"
```

## Tradeoffs

- **What it gives you:** keys visible to every process on the filesystem, sharing without lock-outs, clear wrong-key errors, and removal that really wipes derived keys.
- **What it costs / requires:** a per-user ledger, reference tracking per inode, and a background retry path for open files; keys must be added explicitly rather than inherited from login.
- **Where it bites:** until the last open file closes, those files remain readable. Removal isn't complete while anything holds them open.

## How it got here

- **4.1:** v1, with keys in session keyrings and an AES-128-based derivation.
- **5.4:** v2: filesystem keyring, HKDF-SHA512 and identifiers computed from the key.
- **5.7:** the key status ioctl and the incompletely-removed state.
- **5.13:** hardware-wrapped keys with a derived software secret.
- **6.16:** HMAC-SHA512 library functions for HKDF, and SP800-108 standardisation.

## Related

- Technical version: [[fscrypt-key-management]]
- [[fscrypt-explained|fscrypt subsystem]], [[fscrypt-inode-info-explained|Per-inode info]], [[fscrypt-inline-encryption-explained|Inline encryption]], [[fscrypt-policy|Policies]]
- [[inode-cache-explained|Inode cache]], [[kernel-crypto-api|Kernel crypto API]]
