---
title: "TPM (Trusted Platform Module)"
category: concept
tags: [tpm, security, trusted-computing, attestation, trusted-keys]
subsystem: security
kernel_version: "2.6.12"
researched: 2026-04-18
status: complete
explained: "[[tpm-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/security/tpm/index.html
  - https://docs.kernel.org/security/tpm/tpm-security.html
  - https://www.kernel.org/doc/html/latest/security/tpm/tpm_vtpm_proxy.html
  - https://www.kernel.org/doc/html/latest/security/tpm/tpm_tis.html
  - https://www.kernel.org/doc/html/latest/security/keys/trusted-encrypted.html
  - https://lwn.net/Articles/674751/
  - https://lwn.net/Articles/768419/
  - https://lwn.net/Articles/716259/
  - https://lwn.net/Articles/408439/
  - https://lwn.net/Articles/1032026/
  - https://github.com/torvalds/linux/blob/master/drivers/char/tpm/tpm-chip.c
  - https://github.com/torvalds/linux/blob/master/drivers/char/tpm/tpm2-cmd.c
---

# TPM (Trusted Platform Module)

> 📘 Plain-language version: [[tpm-explained]]

## Purpose

The TPM is a hardware security module that provides a tamper-resistant root of trust anchored in silicon. Without it, software must trust the software layer below it—a chain that bottoms out in the bootloader with no hardware guarantee. With a TPM, the firmware can cryptographically record every step of the boot sequence in tamper-evident registers, enabling the system to prove to a remote verifier which software stack it ran, and to protect secrets (like disk-encryption keys) so they are only accessible when the system booted from an unmodified software chain.

## Mental Model

Think of the TPM as a one-way ratchet: every binary that runs at boot clicks the ratchet forward by extending a cryptographic hash into a Platform Configuration Register (PCR). Once the ratchet has moved, it cannot go backward—you can only read where it ended up. If the expected final position matches what you sealed a disk key against, the key unlocks; otherwise it doesn't. The TPM cannot stop a bad actor from loading malicious firmware, but it makes the act of doing so cryptographically visible.

## How It Works

### Hardware Variants and Physical Interface

Three physical forms exist. A *discrete TPM* is a dedicated chip soldered to the motherboard, historically connected over the LPC bus (shared with the super-I/O); modern systems use SPI. An *integral TPM* lives on the same die as the CPU but runs as a separate processor—Intel's Management Engine and AMD's Platform Security Processor fall into this category. A *firmware TPM* (fTPM) runs on the application processor inside a secure enclave such as ARM TrustZone; it is cheapest to deploy but inherits side-channel risks from the host CPU.

The TCG Platform TPM Profile (PTP) specification defines two register-level interfaces. The *FIFO* interface (used by `tpm_tis_core` and its descendents) works through a 20 KiB shared buffer split into five 4 KiB *localities*. The kernel acquires Locality 0 (lowest priority; Locality 5 is highest) by setting the `requestUse` bit in `TPM_ACCESS` and waiting for the chip to clear it before transferring a command. The *CRB* (Command/Response Buffer) interface uses a flat buffer that holds the entire command or response, avoiding the sequenced FIFO read/write dance.

### Platform Configuration Registers

A standard PC TPM has 24 PCRs. PCRs 0–7 are owned by firmware (measuring bootloaders and OS kernels); PCRs 8–15 are handed to the bootloader and OS; PCRs 16–23 are reserved for other uses. PCR 10 is where the [[IMA]] subsystem extends runtime measurements.

A PCR can only be changed via the *extend* operation:

```
new_PCR = Hash(old_PCR || new_data)
```

For TPM 1.2 this is SHA-1; TPM 2.0 supports SHA-256 and SHA-384 banks simultaneously. Extending is irreversible until the next hard reset. The firmware measures each stage of the boot chain before executing it: management engine → first-stage firmware → second-stage firmware → bootloader → kernel. By the time Linux takes over, the PCRs contain a cryptographic fingerprint of everything that ran before it.

### Linux Kernel Driver Architecture

The kernel TPM subsystem lives in `drivers/char/tpm/`. The central object is `struct tpm_chip` (`drivers/char/tpm/tpm-chip.c`), which represents one physical (or virtual) TPM device. Every driver allocates one via `tpm_chip_alloc()`, which assigns a device number through an IDR radix tree, initializes synchronization primitives (`tpm_mutex`, `ops_sem`), and pre-allocates a work buffer for TPM 2.0 operations.

The hardware-specific layer is expressed through `struct tpm_class_ops`, a vtable that every transport driver must implement:

- `request_locality()` / `relinquish_locality()` — acquire/release a bus locality
- `cmd_ready()` / `go_idle()` — bring the chip out of or into low-power mode
- `clk_enable()` — optional clock management for SoC-integrated TPMs
- `recv()` / `send()` — transfer the raw command/response bytes

`tpm_transmit()` in `tpm-interface.c` wraps `tpm_try_transmit()`: it issues the command, then loops retrying on `TPM2_RC_RETRY` (a TPM 2.0 backpressure signal) until either success or a per-command timeout. `tpm_try_get_ops()` acquires `ops_sem` and checks that `chip->ops` is non-null (it is zeroed during device teardown), preventing use-after-free during driver unbind.

After `tpm_chip_alloc()`, the driver calls `tpm_chip_register()` which:
1. Bootstraps the chip (reads capabilities, selects interface).
2. Registers the chip with sysfs.
3. Sets up BIOS event log access.
4. Registers the TPM as a hardware RNG source (`hwrng` framework), so `tpm2_get_random` feeds the kernel entropy pool.
5. Creates the character device `/dev/tpm<n>` for direct userspace access.

### Resource Manager and TPM Spaces (Linux 4.12+)

Early Linux required a userspace daemon (`tpm2-abrmd`) to multiplex access and manage volatile handles. Starting in Linux 4.12, the kernel includes an in-kernel resource manager. Each open of `/dev/tpmrm<n>` gets an isolated *TPM space*: a private set of transient object handles and HMAC/policy sessions. The implementation (`tpm2-space.c`) swaps a space into TPM volatile memory only when a command is issued under it, and swaps it back out immediately afterward—a software-managed paging system for the TPM's limited handle table.

Virtual handle substitution in `ContextSave` and `GetCapability` hides the physical handle identifiers from callers; each space sees a private namespace. This lets multiple processes (and containers) use the TPM concurrently without interfering with each other's sessions. Containers get virtual TPMs via `/dev/vtpmx`: an ioctl creates a (`/dev/tpmX`, fd) pair; the container uses the character device while a userspace TPM emulator talks over the fd.

### Session-Based Bus Security

A long-standing physical threat is the *interposer attack*: an adversary taps the TPM's SPI bus to snoop secrets or replay/alter commands. Starting with Linux 6.10, `CONFIG_TCG_TPM2_HMAC` is enabled by default, and the kernel enforces session-based protection on every in-kernel TPM command.

The mechanism centres on the *null primary key*: the kernel derives an elliptic-curve primary key from the TPM's null hierarchy (null seed), which has no authorization requirement and resets every time the TPM is power-cycled—so a stolen null seed from a previous boot is useless. The null primary key is created once and kept as a saved volatile context inside `tpm_chip`. For every subsequent in-kernel operation, the kernel opens a *null-primary-salted HMAC session*. This session:

- Provides **command integrity**: an HMAC over the serialized command detects alteration in transit.
- Provides **parameter encryption/decryption**: for operations that move secrets—`TPM2_Seal`, `TPM2_Unseal`, key import, `TPM2_GetRandom`—the payload is encrypted with AES-128-CFB, so a bus sniffer sees only ciphertext.

The null primary key's *name* (its public-key fingerprint) is exported via sysfs so that a userspace verifier can certify it against the TPM manufacturer's endorsement certificate, establishing end-to-end trust.

### Trusted Keys

The kernel integrates TPM-backed cryptographic keys through the `trusted` key type in the key retention service (`security/keys/trusted-keys/`). A trusted key is 32–128 bytes of random material generated inside the kernel. Userspace never sees the plaintext; it only receives an opaque *blob* that only this specific TPM can decrypt.

**Creation**: `keyctl add trusted mykey "new 64" @s` instructs the kernel to:
1. Ask the kernel's CSPRNG for 64 bytes of random data.
2. Seal the data to the TPM's Storage Root Key (TPM 1.2) or an explicitly stored persistent key (TPM 2.0).
3. Optionally bind the seal to current PCR values, so unsealing only succeeds when the system booted from the same software.
4. Return the encrypted blob to userspace.

**Unsealing**: On next boot, `keyctl add trusted mykey "load <blob>" @s` passes the blob to the TPM. The TPM checks the PCR policy (if any), decrypts the blob inside its boundary, and returns the plaintext to the kernel—never to userspace. The key then lives in the kernel keyring and can be used to encrypt other keys (Encrypted Keys) or to unlock a LUKS volume.

**Encrypted Keys** complement trusted keys on systems without hardware TPMs: they are AES-encrypted blobs, where the master key is either a trusted key (hardware-backed) or a user key. The design means that even on a TPM-less server, the symmetric key material can still be protected against offline extraction if a trusted key exists.

### Event Log and Measured Boot

During early boot, the firmware records every PCR extend into a *TPM event log* structured per the TCG EFI Platform Specification. The kernel reads this from an ACPI/EFI table and exposes it at `/sys/kernel/security/tpm0/binary_bios_measurements` via [[securityfs]]. Userspace tools replay the log (`tpm2_eventlog`) and recompute expected PCR values; if the recomputed value matches the live PCR, the log has not been tampered with.

[[IMA]] extends this into runtime: every executable measured by IMA is hashed and extended into PCR 10, and the hash+filename pair is appended to IMA's own event log. Remote attestation servers (e.g. Keylime) can therefore verify not just the boot chain but the set of binaries that ran after boot.

## Key Data Structures

**`struct tpm_chip`** (`drivers/char/tpm/tpm.h`) — one per physical or virtual TPM device.
- `ops` — pointer to `struct tpm_class_ops`; zeroed on unbind, checked by `tpm_try_get_ops()`
- `flags` — `TPM_CHIP_FLAG_TPM2`, `TPM_CHIP_FLAG_FIRMWARE_POWER_MANAGED`, etc.
- `dev`, `cdev` — kernel device and character device for sysfs and `/dev/tpm*`
- `tpm_mutex` — serialises direct-access commands
- `ops_sem` — rwsem that prevents unbind races; readers hold it during command submission
- `work_space` — pre-allocated buffer for TPM 2.0 context save/restore
- `auth` — null primary key context for HMAC sessions
- `hwrng`, `hwrng_name` — registration with the hardware RNG framework

**`struct tpm_class_ops`** (`include/linux/tpm.h`) — vtable implemented by every bus driver.
- `recv()`, `send()` — raw byte transfer
- `request_locality()`, `relinquish_locality()` — FIFO locality management
- `status()` — poll chip readiness

**`struct trusted_key_payload`** (`security/keys/trusted-keys/`) — kernel-side representation of a trusted key.
- `key` — plaintext key material (kernel-only)
- `key_len` — length (32–128 bytes)
- `blob`, `blob_len` — TPM-encrypted form returned to userspace

## Key Functions / Entry Points

**`tpm_chip_alloc()`** (`drivers/char/tpm/tpm-chip.c`) — allocates and initialises a `tpm_chip`; bus drivers call this first.

**`tpm_chip_register()`** (`drivers/char/tpm/tpm-chip.c`) — completes registration: sysfs, event log, hwrng, `/dev/tpm*`.

**`tpm_try_get_ops()`** (`drivers/char/tpm/tpm-chip.c`) — acquires `ops_sem` read lock and verifies `chip->ops != NULL`; gate for all command submission paths.

**`tpm_transmit()`** (`drivers/char/tpm/tpm-interface.c`) — the common command submission path; retries on `TPM2_RC_RETRY`.

**`tpm2_get_random()`** (`drivers/char/tpm/tpm2-cmd.c`) — reads random bytes from the TPM; called by the hwrng framework to seed the kernel entropy pool.

**`trusted_instantiate()`** (`security/keys/trusted-keys/trusted_tpm2.c`) — handles `keyctl add trusted`; generates or loads a trusted key blob via the TPM.

## Important Flags & Config Options

| Kconfig | Effect |
|---|---|
| `CONFIG_TCG_TPM` | Core TPM driver framework |
| `CONFIG_TCG_TIS` | FIFO/MMIO driver (`tpm_tis`) |
| `CONFIG_TCG_TIS_SPI` | SPI bus transport for `tpm_tis_core` |
| `CONFIG_TCG_CRB` | CRB interface driver |
| `CONFIG_TCG_VTPM_PROXY` | Virtual TPM proxy for containers |
| `CONFIG_TCG_TPM2_HMAC` | Session-based bus security (default since 6.10) |
| `CONFIG_TRUSTED_KEYS` | Trusted key type in kernel keyring |
| `CONFIG_ENCRYPTED_KEYS` | Encrypted key type (uses trusted keys as master) |

## Interactions with Other Subsystems

- **↑ Userspace**: `/dev/tpm0` for raw command access; `/dev/tpmrm0` for resource-managed access; `keyctl` for trusted/encrypted keys; `/sys/kernel/security/tpm0/binary_bios_measurements` for event log.
- **→ [[IMA]]**: IMA extends PCR 10 with runtime file measurements and reads the BIOS event log for appraisal policy.
- **→ [[kernel-keyring]]**: Trusted key type anchors encrypted key hierarchy; `keyctl` is the primary interface.
- **→ [[dm-crypt]] / LUKS**: Trusted keys unseal disk encryption keys; `systemd-cryptsetup` uses this to automate LUKS unlock.
- **→ hwrng framework**: TPM is registered as a hardware entropy source; `tpm2_get_random` feeds `/dev/random`.
- **→ [[securityfs]]**: Binary BIOS event log and null primary key name exported under `/sys/kernel/security/tpm0/`.
- **← [[dm-integrity]]**: Integrity metadata can be sealed to the TPM as part of a full-disk trust chain.

## Design Decisions & Tradeoffs

**Extend-only PCRs vs. settable registers**: PCRs cannot be set directly—only extended via hash chaining. This means you cannot forge a specific PCR value without knowing the entire prefix sequence, but it also means *order dependency*: reaching a given PCR value requires not just the right binaries but the right execution order. This makes attestation policies fragile when boot order changes legitimately.

**Null seed for bus security**: The null hierarchy was chosen because it requires no authorization (unlike the storage or endorsement hierarchies, which need a password) and its seed rotates on every TPM reset—so any session key derived from it is automatically invalidated after a power cycle. The tradeoff is that a sophisticated interposer that survives a reset could still attack; in practice, physical TPM resets are rare mid-attack.

**In-kernel resource manager vs. userspace daemon**: The userspace `tpm2-abrmd` daemon predated kernel 4.12. The kernel resource manager (`tpmrm`) removed the dependency on a privileged daemon, simplified container deployments, and reduced the attack surface—at the cost of adding ~600 lines of space-swapping code to the kernel and making kernel TPM logic more complex.

**Key blob model vs. internal key storage**: The TPM has very little volatile memory (typically 3 transient key slots). Rather than storing keys inside the chip, the Linux design wraps them in TPM-encrypted blobs and lets userspace store the blobs. This scales to thousands of keys but requires callers to handle blob storage; a lost blob means a permanently sealed secret.

**`CONFIG_TCG_TPM2_HMAC` default-on (6.10)**: Previously, kernel TPM commands were sent in plaintext over the bus. Enabling HMAC sessions by default requires that TPMs support AES-128-CFB; very old or minimal TPMs may fail. The kernel treats the inability to establish a session as non-fatal where possible, but the change broke some marginal hardware at first.

## How It Has Evolved

- **2.6.12 (2005)**: First TPM device driver (`tpm_tis`) landed, supporting TPM 1.2 over LPC.
- **2.6.37 (2010–2011)**: Trusted and Encrypted Keys introduced—kernel keyring types backed by TPM.
- **4.0 (2015)**: TPM 2.0 command support added; new `tpm2-cmd.c` layer alongside TPM 1.2 code.
- **4.12 (2017)**: In-kernel resource manager (`/dev/tpmrm0`) and TPM spaces, eliminating the dependency on `tpm2-abrmd`.
- **5.4 (2019)**: Event log export to securityfs (`binary_bios_measurements`) stabilised for userspace consumption.
- **5.13 (2021)**: HMAC session framework skeleton added; groundwork for bus attack mitigation.
- **6.10 (2024)**: `CONFIG_TCG_TPM2_HMAC` enabled by default, mandating null-primary-salted sessions with AES-128-CFB encryption for all in-kernel TPM 2.0 operations.
- **Ongoing**: Post-quantum algorithm support in TPM 2.0 specification is under active development; kernel TPM layer will need to follow.

## Further Reading

1. [Protecting systems with the TPM — LWN.net (2015)](https://lwn.net/Articles/674751/) — comprehensive walkthrough of PCRs, sealing, remote attestation, and AEM.
2. [Secure key handling using the TPM — LWN.net (2018)](https://lwn.net/Articles/768419/) — practical coverage of TPM key blobs and the resource manager.
3. [Don't fear the TPM — LWN.net (2025)](https://lwn.net/Articles/1032026/) — modern overview including fTPMs, tpm2-tools, and LUKS integration.
4. [TPM Security — kernel.org](https://docs.kernel.org/security/tpm/tpm-security.html) — official documentation on HMAC sessions and null-seed key hierarchy.
5. [Trusted and Encrypted Keys — kernel.org](https://www.kernel.org/doc/html/latest/security/keys/trusted-encrypted.html) — kernel keyring integration reference.
6. [In-kernel resource manager — LWN.net (2016)](https://lwn.net/Articles/716259/) — design rationale for `/dev/tpmrm0` and TPM spaces.
7. [Trusted and encrypted keys — LWN.net (2010)](https://lwn.net/Articles/408439/) — original introduction of the key types.

## LKML Highlights

- **[in-kernel resource manager, 2016](https://lwn.net/Articles/716259/)**: Jarkko Sakkinen posted the TPM spaces patchset, arguing that the userspace daemon approach was too fragile for containers; the thread debated handle namespace isolation strategies.
- **CONFIG_TCG_TPM2_HMAC default-on (2024)**: FOSDEM 2024 talk (Jarkko Sakkinen) covered the motivation for making HMAC sessions mandatory by default—bus interposer attacks were demonstrated against production hardware, making opt-in security insufficient.
