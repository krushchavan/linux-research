---
title: "fscrypt Filenames Encryption — Explained"
category: explained
original: "[[fscrypt-filenames-encryption]]"
subsystem: fscrypt
tags: [explained, fscrypt, encryption, filenames]
converted: 2026-09-25
---

# fscrypt filename encryption, explained

> Plain-language companion to [[fscrypt-filenames-encryption|the technical note]]. Same facts, fewer identifiers.

## The problem

Encrypting file contents isn't enough. With a raw disk image, an attacker can still read directory listings: project names, personal file names, document titles. Those names often reveal a lot on their own.

Encrypting names creates new difficulties, though. Looking a file up by name has to stay fast, even though the directory stores only ciphertext. Tools like backups should still be able to list and copy files without the key. Encrypted names can grow past the filesystem's name-length limit. And name lengths themselves leak information.

## The idea in one paragraph

Each encrypted directory is like a **card catalogue written in a private cipher**. The cards (entries) sit in their usual slots, but the names on them are unreadable without the key; each room (directory) has its own cipher, derived from the building's master key. With the key, lookup encrypts the name you're looking for and searches for that ciphertext, so no entries need decrypting. Without the key you can still flip through the cards: you see stable, opaque names that you can hand back to the kernel to open or remove a file.

## Step by step

### Step 1: One filename key per directory
Every encrypted directory gets a **filename key**, derived from the master key and the directory's own nonce, with a different label from the one used for content keys. Two directories under the same master key therefore have different filename keys, so ciphertexts can't be matched up across directories.

### Step 2: Padding to hide lengths
When a file, directory or symlink is created, its name is padded with zero bytes before encryption: to at least 16 bytes, then up to the next boundary chosen in the policy (4, 8, 16 or 32 bytes). A 3-character and a 7-character name become indistinguishable. Padding is coarse, though: with 16-byte padding, a 1-byte and a 15-byte name look the same, but a 17-byte name is visibly longer.

### Step 3: Encrypt the whole name at once
The padded name is encrypted in one pass with the directory's key. Every name in a directory uses the same IV, derived from the directory rather than the individual name, because storing a separate IV per entry would add overhead. The consequence is that the same name always produces the same ciphertext within a directory. That's considered acceptable because names are encrypted whole, not in blocks, and keys differ per directory.

The standard cipher is AES-256 in a ciphertext-stealing mode, which needs at least 16 bytes of input; padding guarantees that. HCTR2 (6.0) is a length-preserving alternative that can handle names of any length without the padding overhead.

### Step 4: Lookup with the key
This is the key step. When a program opens a name, the kernel encrypts that plaintext name with the directory's key and searches the directory for the resulting ciphertext. One encryption per lookup; nothing on disk is decrypted. Listing a directory with the key decrypts each entry for display.

### Step 5: Lookup without the key
Without the key, the kernel can't encrypt the name you ask for. So listings return **no-key names**: each entry's ciphertext encoded as URL-safe Base64. If a program passes such a name back (to open, stat, rename and so on), the kernel recognises it, decodes it, and searches for that ciphertext directly. Backup and sync tools get stable identifiers without the key. The alternative, failing all listings without a key, was rejected because it would break those tools.

### Step 6: Names that get too long
Base64 grows data by about a third. Names over roughly 185 bytes would exceed the usual 255-byte limit once encoded. For those, only the first part of the encoded ciphertext goes in the directory entry, and the full ciphertext is stored separately in an extended attribute. Lookups check both, carrying a hash and the partial ciphertext while they search.

### Step 7: Symlinks
A symlink's target path is stored encrypted too: encrypted at creation, decrypted when read. Without the key, reading the link returns the encoded ciphertext.

### Step 8: Case-insensitive directories
Since 5.17, a directory can be both encrypted and case-insensitive. Names are Unicode-normalised before encryption, so that equivalent spellings encrypt the same way and case-insensitive lookup works without decrypting every entry.

## The picture

```text
 create "report.txt"                    lookup "report.txt" (key present)
   pad → "report.txt\0\0\0\0\0\0"          encrypt with dir key
   encrypt with dir key (same IV)           search directory for ciphertext ✓
   store ciphertext in entry

 listing without key:
   entry ciphertext ──Base64──▶ "Vc3kQ…"  (stable no-key name)
   open("Vc3kQ…") ──decode──▶ search for that ciphertext ✓

 name too long?  entry holds prefix; full ciphertext in an extended attribute
```

## Tradeoffs

- **What it gives you:** hidden names, rough hiding of name lengths, fast keyed lookups, and usable listings without the key.
- **What it costs / requires:** padding overhead, extra storage for very long names, and no per-entry IVs (identical names encrypt identically within a directory).
- **Where it bites:** length hiding is only as fine as the padding setting. The number of entries in a directory and their rough sizes stay visible.

## How it got here

- **4.1:** AES-256 ciphertext-stealing filename encryption in ext4.
- **No-key names:** stable encoded names were chosen over errors so backup and sync tools keep working without the key.
- **5.17:** encryption combined with case-insensitive directories, with normalisation before encryption.
- **6.0:** HCTR2, a length-preserving cipher for filenames.

## Related

- Technical version: [[fscrypt-filenames-encryption]]
- [[fscrypt-explained|fscrypt subsystem]], [[fscrypt-contents-encryption-explained|Contents encryption]], [[fscrypt-inode-info-explained|Per-inode encryption info]], [[fscrypt-policy-explained|Policies]]
- [[path-lookup-explained|Path lookup]], [[dentry-explained|Dentries]], [[kernel-crypto-api|Kernel crypto API]]
