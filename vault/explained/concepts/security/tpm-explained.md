---
title: "TPM (Trusted Platform Module) — Explained"
category: explained
original: "[[tpm]]"
subsystem: security
tags: [explained, security, tpm, measured-boot, trusted-keys]
converted: 2026-09-25
---

# The TPM, explained

> Plain-language companion to [[tpm|the technical note]]. Same facts, fewer identifiers.

## The problem

Software can only vouch for the software beneath it, and that chain bottoms out at firmware and bootloader with nothing underneath to guarantee they weren't tampered with. Two things are impossible without a hardware anchor:
- **proving** to a remote machine exactly which software stack this machine booted
- **locking secrets**, such as a disk-encryption key, so they only open when the machine booted unmodified software

## The idea in one paragraph

A TPM is a small, tamper-resistant security chip acting as a **one-way ratchet**. As each piece of boot software runs, its hash is **extended** into a register: new value = hash(old value ‖ new measurement). Registers can only be extended, never set, so the final values are a fingerprint of everything that ran, in order. A secret can be **sealed** so the TPM releases it only when the registers match known-good values. The TPM can't stop malicious firmware from loading, but it makes loading it cryptographically visible.

## Step by step

### Step 1: The hardware
TPMs come in three forms:
- **discrete:** a separate chip on the board, once on the LPC bus, now usually SPI
- **integral:** on the CPU die but a separate processor (Intel's Management Engine, AMD's Platform Security Processor)
- **firmware:** running in a secure enclave such as ARM TrustZone on the main CPU; cheapest, but it shares side-channel risks with that CPU

The kernel talks to them through one of two register interfaces: a FIFO interface with prioritised "localities" (the kernel uses the lowest), or a simpler flat command/response buffer.

### Step 2: Registers that only ratchet forward
A PC TPM has 24 **platform configuration registers**: 0–7 belong to firmware, 8–15 to the bootloader and OS, 16–23 to other uses. [[ima-explained|IMA]] extends register 10 at runtime. TPM 1.2 uses SHA-1; TPM 2.0 can keep SHA-256 and SHA-384 banks at once. Firmware measures each boot stage before running it (management engine, firmware stages, bootloader, kernel), so by the time Linux starts, the registers fingerprint everything before it. Only a hard reset clears them.

### Step 3: The kernel driver
Each TPM is represented by one device object; bus-specific drivers supply the low-level operations (claim a locality, wake the chip, send and receive bytes). A common submission path retries when a TPM 2.0 chip signals "busy, try again", and a lock that's checked on every command prevents use after the device is unbound. Registration also connects the TPM to the kernel's **hardware random number** framework, exposes the firmware's event log, and creates a device node for user space.

### Step 4: Sharing one small chip (4.12+)
A TPM holds very few objects at once (typically 3 transient key slots). Originally a user-space daemon had to multiplex access. Since 4.12, the kernel has its own **resource manager**: each open of the managed device gets a private **space** of objects and sessions, which is swapped into the chip only while one of its commands runs, like software paging for the TPM's tiny handle table. Handles are virtualised so each space sees only its own. Containers can also get virtual TPMs backed by a user-space emulator.

### Step 5: Protecting the bus (6.10+)
This is the key step for physical security. An attacker with an **interposer** on the TPM's bus can snoop secrets or tamper with commands, and such attacks have been demonstrated on production hardware. Since 6.10, the kernel protects every one of its own TPM commands by default. It derives a key from the TPM's **null hierarchy**, which needs no password and whose seed changes on every TPM reset, so a key stolen in one boot is useless in the next. Each command then runs in a session salted with that key:
- an **HMAC** over each command detects changes in transit
- secret payloads (seal, unseal, key import, random numbers) are **encrypted** with AES-128, so a bus sniffer sees only ciphertext

The key's public fingerprint is published so user space can check it against the manufacturer's endorsement certificate.

### Step 6: Trusted keys
Through the [[kernel-keyring-explained|kernel keyring]], the kernel can create **trusted keys**: 32–128 random bytes generated in the kernel and sealed by the TPM, optionally bound to register values. User space only ever holds the **sealed blob**. On a later boot, the blob is handed back; the TPM checks the register policy, decrypts inside itself, and gives the plaintext to the kernel, never to user space. Trusted keys can then protect **encrypted keys** or unlock disk encryption. Storing blobs outside the chip scales to thousands of keys, but a lost blob means a permanently sealed secret.

### Step 7: Event logs and attestation
Firmware records every extend in an **event log**, which the kernel exposes through [[securityfs-explained|securityfs]]. Tools replay the log and recompute the register values; a match proves the log is genuine. IMA continues the chain at runtime, so attestation services such as Keylime can check both the boot chain and every program run since.

## The picture

```text
 power on ─▶ firmware ─▶ bootloader ─▶ kernel ─▶ (IMA: each program)
     │ measure-then-run   │               │         │
     ▼                    ▼               ▼         ▼
 PCR[0-7] := H(old‖m)   PCR[8-15] (bootloader, OS; IMA uses 10)
                                     event log ─▶ verifier replays → matches PCRs?

 seal(disk key, policy: PCRs = good values) → blob stored on disk
 next boot: blob → TPM → PCRs match? → key to kernel : refuse
 kernel ⇄ TPM bus: HMAC + AES session salted from null-hierarchy key
```

## Tradeoffs

- **What it gives you:** a hardware root of trust; remote attestation from firmware through runtime; secrets that open only on an unmodified system; bus protection against interposers; a hardware entropy source.
- **What it costs / requires:** registers depend on **order**, so a legitimate change in boot order changes the values, which makes attestation policies fragile. The in-kernel resource manager (about 600 lines of swapping code) removed a privileged daemon and simplified containers, but made kernel TPM code more complex.
- **Where it bites:** turning bus protection on by default required AES support in the TPM, and broke some marginal older hardware at first. The null-seed design assumes an attacker can't survive a TPM reset mid-attack, which is rare in practice. Firmware TPMs inherit the main CPU's side channels.

## How it got here

- **2.6.12 (2005):** the first TPM driver, for TPM 1.2 over LPC.
- **2.6.37 (2010–2011):** trusted and encrypted keys in the kernel keyring.
- **4.0 (2015):** TPM 2.0 command support.
- **4.12 (2017):** in-kernel resource manager and TPM spaces (Jarkko Sakkinen's series, arguing the daemon approach was too fragile for containers).
- **5.4 (2019):** event log export stabilised for user space. **5.13 (2021):** groundwork for session-based bus protection.
- **6.10 (2024):** bus protection on by default. Post-quantum algorithms in the TPM 2.0 specification are still in development, and the kernel will need to follow.

## Related

- Technical version: [[tpm]]
- [[security-explained|Security subsystem]], [[ima-explained|IMA]], [[kernel-keyring-explained|Kernel keyring]], [[securityfs-explained|securityfs]]
- [[dm-crypt-explained|dm-crypt]], [[dm-integrity-explained|dm-integrity]]
