---
title: "dm-crypt Key Management — Explained"
category: explained
original: "[[dm-crypt-key-management]]"
subsystem: dm-crypt
tags: [explained, dm-crypt, luks, keyring, tpm]
converted: 2026-09-25
---

# dm-crypt key management, explained

> Plain-language companion to [[dm-crypt-key-management|the technical note]]. Same facts, fewer identifiers.

## The problem

An encrypted disk is only as safe as its key. That key has to come from somewhere (a passphrase, a TPM chip, a security token), be turned into the exact bytes the cipher needs, reach the kernel without leaking along the way, and be destroyed properly when the volume is closed.

Each of those steps has its own traps. Keys typed into a command line end up in logs and shell history. Passphrases are weak and need slowing down against brute-force guessing. A process holding the key can be read by another compromised process. And a compiler may quietly skip "zero this memory" if nothing reads it afterwards.

## The idea in one paragraph

Draw a sharp line. The kernel only ever knows "here are N bytes of key for this cipher". It never sees passphrases, key-derivation functions or on-disk headers. All of that lives in user space in `cryptsetup` and the **LUKS2** format, which turns a passphrase (or TPM, or token) into the master key. The kernel's jobs are *safe delivery* (preferably through the kernel keyring, so the key needn't pass through user-space memory at all) and *safe destruction* (zeroing that can't be optimised away).

## Step by step

### Step 1: The simple way, hex in the table (testing only)
The key can be written as a hex string directly in the device's table line. The kernel decodes it. It works, but the table can show up in kernel status output, audit logs or shell history, so it's used only for testing or by tools that protect the key some other way.

### Step 2: The production way, a keyring reference
Instead of the key, the table carries a *reference*: key size, key type and a name. The kernel looks the key up in the calling process's keyrings (session, then process, then user, then system) and copies its bytes in. Key types:
- **logon:** held in kernel memory, only usable within the session. The most common for LUKS.
- **user:** similar, tied to the user's ID.
- **trusted:** backed by the TPM. The key is **sealed** to measurements of the boot state and unsealed by the TPM only if the machine booted as expected.
- **encrypted:** stored encrypted on disk under a master key (which may itself be a trusted key) and decrypted inside the kernel.

This is the key security win. With trusted or encrypted keys, the real AES key never exists in plain user-space memory, so a compromised process can't grab it by reading another process's memory or attaching a debugger after the volume is opened.

### Step 3: The LUKS2 layout (user space)
cryptsetup lays out a LUKS2 device in zones:
1. a small **binary header** (4 KB): magic bytes, version, sizes, a checksum
2. a **JSON metadata area** (16 KB by default): key slots, encrypted segments and their cipher, verification digests, and **tokens** for external unlock methods such as TPM2 or FIDO2
3. a **key slot area** (about 16 MB by default): copies of the master key, each encrypted differently
4. the **encrypted data** itself

### Step 4: Turning a passphrase into a key slot key
Each key slot holds a copy of the master key, encrypted under a key derived from a passphrase. The derivation is deliberately slow:
- **PBKDF2:** repeated hashing, tuned to take about one second on the machine. Resists CPU guessing, but GPUs can run many guesses in parallel.
- **Argon2id** (the modern default): **memory-hard**, needing a large working memory (64 MB by default) per guess. A GPU can't afford 64 MB per thread, so mass parallel guessing becomes impractical.

### Step 5: Anti-forensic splitting
The master key in each slot is spread across many stripes (4000 by default), mixed with a hash chain so that *all* stripes are needed to rebuild it. Overwrite any stripe and that slot's key is gone for good, even with the right passphrase. So "delete this passphrase" means wiping a few kilobytes, without touching the data or other slots.

### Step 6: Check before you mount
LUKS2 stores a digest, a slow hash of the master key. cryptsetup checks the derived key against it before loading anything into the kernel. Without it, a wrong passphrase would produce a garbage key and a volume that seems to open but returns nonsense.

### Step 7: Opening a volume, end to end
1. cryptsetup (or systemd at boot) reads the LUKS2 header.
2. Argon2id derives the slot key from the passphrase and the slot's salt.
3. The slot key decrypts the slot's copy of the master key.
4. The stripes are recombined into the master key, and it's checked against the digest.
5. cryptsetup adds the master key to the session keyring as a logon key and wipes its own copy.
6. It creates the device-mapper device with a table that *references* that keyring key.
7. The kernel fetches the key and loads it into its per-CPU ciphers.

For TPM2-bound volumes (enrolled with systemd's tool), step 2 is replaced by the TPM unsealing the key, if the boot measurements match. The key goes into the kernel's trusted key store without passing through user space.

### Step 8: Wiping the key
When the device is closed, the kernel zeroes its copy of the key using a special zeroing call with a compiler barrier. An ordinary zeroing could be removed by the optimiser as a "dead store", since nothing reads the memory afterwards. Kernel memory isn't swapped, so the key doesn't leak to swap in normal operation.

## The picture

```text
 USER SPACE (cryptsetup / systemd)                KERNEL
 ─────────────────────────────────                ──────
 passphrase ─▶ Argon2id (64 MB, ~1 s) ─▶ slot key
 slot key ─▶ decrypt slot ─▶ join stripes ─▶ master key ─▶ check digest
                                             │
                                             ▼
                              add to keyring as "logon" key ──▶ keyring
                              table: "use keyring key X"     ──▶ dm-crypt looks up X
                                                                  ─▶ per-CPU ciphers
 TPM2 path:  TPM unseals key if boot measurements match ────────▶ trusted key store
                                                                  (never in user space)
 close: zero key with a barrier the compiler can't remove
```

## Tradeoffs

- **What it gives you:** key formats and derivation methods can evolve (LUKS1 to LUKS2, new KDFs, tokens) without kernel changes; TPM-sealed keys that never touch user space; passphrase deletion by wiping a few kilobytes.
- **What it costs / requires:** the kernel can't enforce derivation strength; a badly configured cryptsetup can use a weak setting and the kernel won't know. TPM binding adds complexity.
- **Where it bites:** a TPM-sealed volume becomes unopenable if the boot configuration changes (kernel update, firmware change) unless a recovery passphrase slot was set up. Hibernation writes RAM, key included, to swap in plaintext; encrypted hibernation is still being developed. The key can also linger in CPU caches after wiping.

## How it got here

- **2003:** only hex keys in the table.
- **2004:** LUKS1 in cryptsetup, with anti-forensic splitting and PBKDF2 (all in user space).
- **3.x:** kernel keyring support with logon and user keys.
- **4.x:** trusted (TPM-backed) and encrypted key types.
- **2018 (cryptsetup 2.0):** LUKS2 with Argon2id, JSON metadata, multiple segments and hardware tokens (FIDO2, TPM2).
- **5.x and later:** systemd's enrollment tool makes TPM2 binding easy, stored as LUKS2 tokens.

## Related

- Technical version: [[dm-crypt-key-management]]
- [[dm-crypt-explained|dm-crypt]]: the subsystem overview
- [[dm-crypt-crypt-config-explained|Per-device encryption state]]: where the key is held and zeroed
- [[kernel-keyring-explained|Kernel keyring]]: how keys are stored and looked up
- [[tpm|TPM]]: the chip behind trusted keys
- [[kernel-crypto-api-explained|Kernel crypto API]]
