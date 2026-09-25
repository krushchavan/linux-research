---
title: "IMA — Integrity Measurement Architecture — Explained"
category: explained
original: "[[ima]]"
subsystem: security
tags: [explained, security, ima, tpm, attestation]
converted: 2026-09-25
---

# IMA (Integrity Measurement Architecture), explained

> Plain-language companion to [[ima|the technical note]]. Same facts, fewer identifiers.

## The problem

File permissions say who may use a file, but not whether the file is still what it's supposed to be. If an attacker swaps a backdoored binary onto the disk, the kernel will load it without complaint. Two questions need answers:
- **Locally:** has this file been tampered with since it was known good, and if so, should we refuse to use it?
- **Remotely:** can another machine verify exactly what this machine has run, in a way the machine itself can't fake?

## The idea in one paragraph

IMA is a **ledger sealed by a notary**. Each time an important file is used, IMA takes its fingerprint (a hash) and writes it in the ledger (the measurement list). The notary, a TPM chip, seals the ledger with a running cryptographic value that can't be forged without the chip's secret keys. A remote auditor can replay the ledger, recompute the seal, and compare it with a quote signed by the TPM. Separately, in **appraisal** mode, IMA compares each file's hash with a stored good value or signature and refuses access on a mismatch.

## Step by step

### Step 1: Catch files as they're used
IMA hooks in through the security-module framework at three points:
- **program execution**, before control passes to the new binary, so no writer can change it mid-check
- **memory-mapping code as executable**, which catches shared libraries and JIT code
- **opening files**, with the access type (read, write, execute, append) available for filtering

All three lead into one central measurement routine.

### Step 2: Ask the policy
IMA walks its policy rules, a built-in set or one loaded by root after boot, and the first match wins. Each rule says what to do (measure, appraise, audit, or explicitly skip) and when: which hook, which access mode, which user or owner, which SELinux label, and whether a digital signature is required rather than a bare hash. Three built-in presets cover common cases:
- **TCB:** measure everything executed or mapped as code, plus files root opens for reading; the baseline for attesting a production host
- **appraise TCB:** enforce integrity on all root-owned files
- **secure boot:** require signatures on kernel modules, firmware, kexec kernels and IMA policy files

### Step 3: Don't hash twice
Each file's inode carries a small integrity cache: the last hash and which checks have already been done. If a file was already measured and its change counter (**i_version**) hasn't moved, IMA skips re-hashing. Filesystems must be mounted with i_version for this to work; without it the file is re-hashed on every access, though it's still only added to the list once. A write bumps the counter, so the next use takes a fresh hash.

### Step 4: Hash and record
IMA reads the file, hashes it (SHA-256 by default), and builds a log entry using a **template**, a named list of fields such as digest, filename, signature, or file owner and mode. The old default template was capped at a SHA-1 hash and 255-character names; the newer default (3.13) allows any hash algorithm and has no path-length limit. New fields can be added without changing the core.

### Step 5: Extend the TPM
This is the key step. The entry is appended to the in-kernel measurement list (readable from a special filesystem), and its hash is fed into a TPM **platform configuration register** (by default number 10) by **extending** it: new value = hash(old value ‖ new measurement). That's a one-way ratchet: the final register value encodes the whole ordered history. A verifier replays the list, recomputes the register, and checks it against the TPM's signed quote, so nothing can be dropped from the list or slipped in unrecorded. The list's first entry is the **boot aggregate**, a digest of the firmware's own measurements, so the chain of trust runs unbroken from power-on through boot into runtime.

### Step 6: Appraise (enforce locally)
Measuring is passive; appraisal enforces. The file's `security.ima` extended attribute holds either a good hash or a digital signature over it, checked against keys on a dedicated kernel keyring. On a boot option, a mismatch can:
- **enforce:** deny with "access denied"
- **log:** allow but record it
- **fix:** rewrite the attribute with the current hash, used when first provisioning a system
- **off:** skip appraisal

### Step 7: Protect the attributes (EVM)
Appraisal opens a new hole: an attacker with offline disk access could update `security.ima` to match a backdoored file. **EVM** (3.2) closes it by computing an HMAC (or verifying a signature) over the file's security-relevant metadata: inode number and generation, owner, group, mode, and the SELinux, Smack, IMA and capability attributes. The HMAC key comes from a TPM-sealed blob loaded at boot and is never exposed to user space, so an offline attacker can't forge it. EVM updates its value automatically when an approved attribute change happens.

### Step 8: Measure kernel data too
Since around 5.12, kernel subsystems on an allowlist (such as SELinux, AppArmor and dm-crypt) can hash in-memory data like their running policy, so attestation can cover configuration changed after boot, not only files on disk.

## The picture

```text
 exec / mmap-as-code / open
        │
        ▼
 policy: first matching rule → measure? appraise?
        │
        ├─ inode cache fresh (i_version unchanged)? → skip hash
        ▼
 hash file ─▶ template entry {digest, name, sig…}
        ├─▶ measurement list  [boot aggregate, entry1, entry2, …]
        └─▶ TPM register 10 := hash(old ‖ entry)      ← remote verifier replays & compares
 appraise: security.ima (hash or signature) ✓ / ✗ → EACCES
           EVM HMAC over metadata guards security.ima itself
```

## Tradeoffs

- **What it gives you:** detection and, optionally, prevention of file tampering; remote attestation anchored in hardware from firmware to runtime; signed policies for modules and firmware.
- **What it costs / requires:** hashing files on use (reduced by the i_version cache); provisioning `security.ima` attributes on every file before turning on enforcement. Measurement and appraisal were split from the start (2.6.30) so distributions could deploy measurement safely first and add enforcement later.
- **Where it bites:** filesystems without i_version (such as FAT) re-hash on every access, and concurrent writers can trigger time-of-check/time-of-use violations, which are counted. The single global measurement list is a big obstacle for containers: per-namespace IMA has been in progress since 2017, held back by the global TPM register (which can't be virtualised) and by namespacing keyrings and the control filesystem.

## How it got here

- **2005:** first submitted by Reiner Sailer, with debate over whether IMA belonged in the security-module framework at all, which set the precedent for a separate integrity area.
- **2.6.30:** merged with measurement hooks, TPM extension and the measurement log.
- **3.2–3.3:** EVM, then digital signatures for EVM.
- **3.10:** audit mode (hashes written to the audit log). **3.13:** the newer template becomes default.
- **4.x:** appraisal via the built-in policy; a template for appended module signatures.
- **5.12:** measurement of critical kernel data. Namespace support remains in development; its design discussion (2021) made per-namespace TPM extension optional.

## Related

- Technical version: [[ima]]
- [[security-explained|Security subsystem]], [[tpm|TPM]], [[kernel-keyring|Kernel keyring]], [[lsm-framework|LSM framework]], [[securityfs|securityfs]], [[selinux|SELinux]]
- [[dm-crypt-explained|dm-crypt]], [[dm-integrity-explained|dm-integrity]], [[fscrypt-explained|fscrypt]], [[extended-attributes-and-acls-explained|Extended attributes]]
