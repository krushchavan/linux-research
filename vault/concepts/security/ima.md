---
title: "IMA — Integrity Measurement Architecture"
category: concept
tags: [security, integrity, tpm, attestation, trusted-computing]
subsystem: security
kernel_version: "2.6.30"
researched: 2026-04-18
status: complete
explained: "[[ima-explained]]"
sources:
  - https://lwn.net/Articles/137306/
  - https://lwn.net/Articles/488906/
  - https://lwn.net/Articles/753276/
  - https://lwn.net/Articles/835855/
  - https://lwn.net/Articles/829035/
  - https://lwn.net/Articles/722481/
  - https://www.kernel.org/doc/html/latest/security/IMA-templates.html
  - https://sourceforge.net/p/linux-ima/wiki/Home/
  - https://wiki.gentoo.org/wiki/Integrity_Measurement_Architecture
  - https://github.com/torvalds/linux/blob/master/security/integrity/ima/ima.h
  - https://github.com/torvalds/linux/blob/master/security/integrity/ima/ima_main.c
---

# IMA — Integrity Measurement Architecture

> 📘 Plain-language version: [[ima-explained]]

## Purpose

IMA answers a fundamental question that filesystem permissions alone cannot: *has this file been tampered with since it was last known good?* It hooks into file-access paths to hash files before use, records those hashes in a tamper-evident log anchored to a [[TPM]] hardware register, and can enforce local access denial when a hash no longer matches. Without IMA, a compromised binary could be swapped onto disk and the kernel would load it without complaint — IMA detects that substitution and, in appraise mode, blocks it.

## Mental Model

Think of IMA as a paper ledger sealed by a notary. Every time an important document is filed, a fingerprint is taken and written into the ledger. The notary (TPM) stamps the ledger with a cryptographic seal that can only be forged if you own the notary's private key — a secret locked inside the hardware. A remote auditor asks for the ledger and re-derives the seal; if it matches, they know the ledger was not altered. IMA is that ledger, the `process_measurement()` path is the act of taking a fingerprint, and PCR extension is the notary's stamp.

## How It Works

### Entry Points and Hook Dispatch

IMA registers callbacks via the [[LSM Framework]] at three primary interception points. `ima_bprm_check()` fires when `execve()` is about to load an ELF binary — the kernel has not yet transferred control so IMA can hash the file while no concurrent writer can change it. `ima_file_mmap()` fires when a process requests `PROT_EXEC` on a mapping, catching shared libraries and JIT-compiled code. `ima_file_check()` is the most general hook, triggered by `open()` calls; the `mask` argument encodes `MAY_READ`, `MAY_WRITE`, `MAY_EXEC`, and `MAY_APPEND` so IMA can filter by access type. All three converge on `process_measurement()` (`security/integrity/ima/ima_main.c`), passing an `enum ima_hooks func` value to identify which hook triggered.

### Policy Evaluation

`process_measurement()` first calls `ima_get_action()`, which walks the policy rule list — either the built-in policy or one loaded by root after boot via `securityfs`. Each rule specifies an *action* (`measure`, `appraise`, `audit`, `dont_measure`, `dont_appraise`) and zero or more *conditions*: `func=` to match the hook type, `mask=` to match access mode, `fsuid=`/`fowner=` to restrict by identity, `obj_type=` to match an SELinux label, or `appraise_type=imasig` to require digital signatures rather than bare hashes. The first rule that matches wins. Three built-in policy presets cover common cases:

- **`ima_policy=tcb`** — measures all executed files, all exec-mmap'd files (shared libraries, firmware, kernel modules), plus files root opens for reading. This is the attestation baseline for a production host.
- **`ima_policy=appraise_tcb`** — appraises (enforces) all root-owned files, turning measurement into access control.
- **`ima_policy=secure_boot`** — appraises kernel modules, firmware, kexec kernels, and IMA policy files, requiring digital `imasig` signatures rather than bare hashes.

### Per-inode Integrity Cache

After policy evaluation, `process_measurement()` looks up or allocates an `ima_iint_cache` for the file's inode. This structure lives in the inode's LSM security blob (accessed via `ima_inode_get_iint()`) and caches the last-computed hash plus status flags for each measurement context:

```c
struct ima_iint_cache {           /* security/integrity/ima/ima.h */
    struct mutex mutex;           /* serialises hash recomputation   */
    struct integrity_inode_attributes real_inode;
    unsigned long flags;          /* IMA_MEASURED, IMA_APPRAISED … */
    unsigned long measured_pcrs;  /* bitmask of PCRs already extended */
    unsigned long atomic_flags;
    enum integrity_status ima_file_status:4;   /* appraisal result   */
    enum integrity_status ima_mmap_status:4;
    enum integrity_status ima_bprm_status:4;
    enum integrity_status ima_read_status:4;
    enum integrity_status ima_creds_status:4;
    struct ima_digest_data *ima_hash;          /* cached digest       */
};
```

The `flags` field avoids redundant hashing: if `IMA_MEASURED` is already set for this inode and the inode's `i_version` counter has not changed, `process_measurement()` skips rehashing. Filesystems must be mounted with the `i_version` option for this optimisation to work; without it, the file is re-hashed every access but the measurement list entry is only added once. If the inode has been written since the last measurement (detected via `i_version` mismatch), `IMA_MEASURED` is cleared and a fresh hash is taken.

### Hash Computation and Template Construction

When a new measurement is needed, `ima_collect_measurement()` reads the file's contents and computes a digest using the algorithm configured in `ima_template` (default: SHA256 via the `ima-ng` template). The result is stored in `iint->ima_hash` and wrapped in an `ima_event_data` struct that also carries the filename, any xattr value (`security.ima`), and an optional module signature (`modsig`).

The template system determines *what* ends up in the measurement log. A template is a named list of field IDs, each backed by an `ima_template_field` with an `init()` callback that serialises one datum:

| Template | Fields | Notes |
|---|---|---|
| `ima` | `d\|n` | Legacy: SHA1 only, 255-char filename |
| `ima-ng` | `d-ng\|n-ng` | Default since 3.13; arbitrary hash algo |
| `ima-sig` | `d-ng\|n-ng\|sig` | Includes RSA/EC signature from xattr |
| `ima-modsig` | `d-ng\|n-ng\|sig\|d-modsig\|modsig` | Appended module signatures |
| `evm-sig` | full metadata | Inode UID/GID/mode plus xattrs |

The filled fields are packed into an `ima_template_entry`:

```c
struct ima_template_entry {       /* security/integrity/ima/ima.h */
    int pcr;                      /* PCR index to extend (default 10) */
    struct tpm_digest *digests;   /* per-bank TPM digests             */
    struct ima_template_desc *template_desc;
    u32 template_data_len;
    struct ima_field_data template_data[]; /* serialised field data   */
};
```

### Measurement List and PCR Extension

The completed `ima_template_entry` is handed to `ima_add_template_entry()`, which takes two actions atomically. First, it hashes the entire template entry and appends an `ima_queue_entry` — a wrapper holding an hlist node for the in-memory hash table (for deduplication) and a list_head for the `ima_measurements` linked list that `securityfs` exposes at `/sys/kernel/security/ima/ascii_runtime_measurements`. Second, if a TPM is present, it calls `ima_pcr_extend()`, which passes the template hash to `tpm_pcr_extend()` against PCR 10 (configurable via `CONFIG_IMA_MEASURE_PCR_IDX`).

PCR extension is a one-way ratchet: `PCR_new = SHA1(PCR_old || new_hash)`. This means the final PCR value encodes the *entire ordered history* of measurements. A remote attestation service can replay the measurement list, recompute the PCR, and compare with the TPM-signed quote to verify nothing was measured that does not appear in the list and nothing was omitted.

The very first entry in the list is the **boot aggregate** — a SHA1 digest of PCR 0–7, imported from the BIOS/UEFI measurement log. This anchors the IMA measurement chain to the platform's firmware integrity, creating an unbroken trust chain from reset vector through kernel boot into runtime.

### Appraisal — Enforcing Integrity Locally

Measurement is passive; appraisal enforces. When the policy action is `appraise`, `process_measurement()` calls `ima_appraise_measurement()` after computing the hash. This reads the `security.ima` xattr from the file's inode, which contains either a bare hash or an RSA/EC digital signature over the hash. A bare hash is compared directly against `iint->ima_hash`; a signature is verified against public keys on the `_ima` kernel keyring.

The `ima_appraise=` kernel command-line parameter controls enforcement behaviour:
- **`enforce`** (default when `CONFIG_IMA_APPRAISE_BOOTPARAM=n`) — mismatch → `EACCES`
- **`log`** — mismatch logged but access permitted
- **`fix`** — mismatch causes the xattr to be rewritten with the current hash (initial provisioning mode)
- **`off`** — appraisal disabled

### EVM — Protecting the Security Attributes Themselves

Appraisal creates a new attack surface: an adversary who can write to the disk offline can just update `security.ima` to match a backdoored file. EVM (Extended Verification Module, merged 3.2) closes this gap. At each appraisal check, EVM computes an HMAC-SHA1 (or verifies an RSA signature) over the file's *security-relevant metadata*: the inode number, inode generation, UID, GID, file mode, `security.selinux`, `security.SMACK64`, `security.ima`, and `security.capability`. The result is stored in `security.evm`. Because the HMAC key is loaded from a TPM-sealed blob at boot and never exposed to userspace, an offline attacker cannot compute a valid `security.evm` for a modified inode without access to the TPM.

EVM also auto-updates `security.evm` whenever an LSM-approved attribute change occurs, ensuring the two xattrs stay consistent during normal operation.

### Critical Kernel Data Measurement

Since ~5.12 (merged via the `CRITICAL_DATA` hook), non-file kernel subsystems can call `ima_measure_critical_data()` to hash in-memory data structures. The caller passes a `source` string that IMA validates against a compile-time allowlist (e.g., `"selinux"`, `"apparmor"`, `"dm-crypt"`). This enables remote attestation of kernel subsystem configuration state — not just binaries on disk, but running policy — extending IMA's coverage to a class of attacks that modify the kernel heap after boot.

## Key Data Structures

**`struct ima_iint_cache`** (`security/integrity/ima/ima.h`) — per-inode integrity metadata cached in the LSM blob to avoid repeated hashing.
- `flags` / `measured_pcrs` — track which measurements have been performed per inode
- `ima_*_status` — per-hook appraisal result (file, mmap, bprm, read, creds)
- `ima_hash` — pointer to the last computed `ima_digest_data`

**`struct ima_template_entry`** (`security/integrity/ima/ima.h`) — one measurement log record.
- `pcr` — PCR to extend; usually 10
- `digests` — array of `tpm_digest` covering all active TPM hash banks
- `template_data[]` — flexible array of serialised template fields

**`struct ima_queue_entry`** (`security/integrity/ima/ima.h`) — node in both the `ima_measurements` linked list and the deduplication hash table.

**`struct ima_event_data`** (`security/integrity/ima/ima.h`) — ephemeral context threaded through `process_measurement()`.
- `iint` — the inode's integrity cache
- `xattr_value` / `xattr_len` — `security.ima` contents read by appraisal
- `buf` / `buf_len` — used for critical kernel data measurements (no `file`)

**`struct ima_template_desc`** (`security/integrity/ima/ima.h`) — named template with a `fmt` string (e.g. `"d-ng|n-ng|sig"`) and an array of `ima_template_field` callbacks.

## Key Functions / Entry Points

**`process_measurement()`** (`security/integrity/ima/ima_main.c`) — the central measurement+appraisal engine; called by all hooks after populating `ima_event_data`.

**`ima_get_action()`** (`security/integrity/ima/ima_policy.c`) — walks the policy rule list and returns the combined action bitmask for a given hook+inode+cred.

**`ima_collect_measurement()`** (`security/integrity/ima/ima_crypto.c`) — reads the file and computes the digest; stores result in `iint->ima_hash`.

**`ima_add_template_entry()`** (`security/integrity/ima/ima_queue.c`) — appends to `ima_measurements` list and extends the TPM PCR.

**`ima_appraise_measurement()`** (`security/integrity/ima/ima_appraise.c`) — validates `security.ima` xattr against the just-computed hash or verifies its digital signature.

**`ima_measure_critical_data()`** (`security/integrity/ima/ima_main.c`) — entry point for kernel subsystems to hash in-memory data; validates `source` against the allowlist.

**`ima_bprm_check()`** / **`ima_file_mmap()`** / **`ima_file_check()`** (`security/integrity/ima/ima_main.c`) — LSM hooks; prepare `ima_event_data` and call `process_measurement()`.

## Important Flags & Config Options

| Config | Effect |
|---|---|
| `CONFIG_IMA` | Enable IMA; required for all below |
| `CONFIG_IMA_MEASURE_PCR_IDX` | PCR index to extend (default 10, range 8–14) |
| `CONFIG_IMA_DEFAULT_TEMPLATE` | Template name baked into the kernel (default `ima-ng`) |
| `CONFIG_IMA_APPRAISE` | Enable local enforcement of `security.ima` xattrs |
| `CONFIG_IMA_APPRAISE_BOOTPARAM` | Allow `ima_appraise=` to override at boot (useful for provisioning) |
| `CONFIG_IMA_TRUSTED_KEYRING` | Require appraisal signatures be on the `_ima` trusted keyring |
| `CONFIG_IMA_KEYRINGS_PERMIT_SIGNED_BY_BUILTIN_OR_SECONDARY` | Constrain which keys can populate the `_ima` keyring |
| `CONFIG_EVM` | Enable Extended Verification Module |
| `CONFIG_IMA_NS` | Per-namespace IMA measurement lists (in-development; adds `CLONE_NEWIMA`) |

**Kernel command-line parameters:**

| Parameter | Values | Effect |
|---|---|---|
| `ima=on` | — | Activate IMA (required if not built-in) |
| `ima_policy=` | `tcb`, `appraise_tcb`, `secure_boot` | Load a built-in policy |
| `ima_appraise=` | `enforce`, `log`, `fix`, `off` | Appraisal enforcement mode |
| `ima_template=` | `ima`, `ima-ng`, `ima-sig`, … | Override default template |
| `ima_hash=` | `sha1`, `sha256`, `sha512` | Override default digest algorithm |

**securityfs interface:**

| Path | Purpose |
|---|---|
| `/sys/kernel/security/ima/ascii_runtime_measurements` | Human-readable measurement list |
| `/sys/kernel/security/ima/binary_runtime_measurements` | TPM binary log used by attestation tools |
| `/sys/kernel/security/ima/policy` | Write a custom policy file after boot |
| `/sys/kernel/security/ima/violations` | Count of TOCTOU and open-writer violations |

## Interactions with Other Subsystems

- **↑ Userspace**: `evmctl` (from `ima-evm-utils`) provisions `security.ima` and `security.evm` xattrs; attestation agents (e.g., Keylime) read the binary measurement log and compare against a reference policy.
- **→ [[TPM]]**: `tpm_pcr_extend()` extends PCR 10 with each new measurement hash; `tpm_pcr_read()` + TPM quotes allow remote attestation.
- **→ [[Kernel Keyring]]**: RSA/EC public keys loaded onto the `_ima` and `_evm` keyrings at boot (via `ima-evm-utils` or `keyctl`) are used by appraisal to verify digital signatures.
- **→ [[LSM Framework]]**: IMA registers as an LSM; `inode_post_setxattr` and `inode_getxattr` hooks allow EVM to intercept xattr operations. IMA policy conditions can match SELinux and SMACK object labels.
- **← [[securityfs]]**: The `ima` securityfs directory provides the measurement log, the policy write interface, and violation counters to userspace.
- **← [[dm-crypt]] / [[dm-integrity]]**: Device-mapper targets can call `ima_measure_critical_data()` to attest their in-memory key and policy state.
- **← [[fscrypt]]**: Encrypted file keys can be measured to detect key-substitution attacks.

## Design Decisions & Tradeoffs

**Measurement-only vs. enforcement separation**: The original 2.6.30 merge deliberately split measurement (passive, always safe) from appraisal (active enforcement), letting distributions adopt IMA incrementally. Measurement can be deployed on production systems without risk of breakage; appraise mode is added only after all files have `security.ima` xattrs provisioned.

**PCR extension is order-independent**: IMA deliberately uses the TPM's cumulative-hash property so that the PCR value is deterministic regardless of which order files are measured. A remote verifier needs only the list contents, not the order, to replay the computation.

**`i_version` dependency**: Tying cache invalidation to `i_version` was a pragmatic choice — constant-time lookup from the LSM blob avoids the original rbtree and keeps the fast path cheap. The downside is that filesystems without `i_version` (e.g., FAT) always re-hash, and overlapping writers can cause TOCTOU violations recorded as `/sys/kernel/security/ima/violations`.

**Template extensibility**: The field-ID + callback design of templates was introduced to break the `ima` template's hard limits (20-byte SHA1, 255-char path) without forking the log format. New fields (`iuid`, `igid`, `xattrnames`) can be composed without modifying core code.

**Namespace isolation debt**: IMA's global measurement list is a significant obstacle to containerised workloads. Work on `CONFIG_IMA_NS` (`CLONE_NEWIMA`) has been in-flight since 2017 — the per-inode `measured_pcrs` field was partly designed with per-namespace PCR bitmasks in mind — but the complexity of namespace-scoped keyrings and securityfs interfaces has delayed upstreaming.

## How It Has Evolved

| Version | Change |
|---|---|
| 2.6.30 | Initial IMA: measurement hooks, TPM PCR extension, securityfs log |
| 3.2 | EVM merged: HMAC protection of security xattrs |
| 3.3 | Digital signature support in EVM; RSA keys on `_evm` keyring |
| 3.10 | IMA-audit mode: hashes written to audit log |
| 3.13 | `ima-ng` template becomes default (SHA256; no path-length limit) |
| 4.0 | Appraisal of files from the `appraise_tcb` built-in policy |
| 4.5 | `ima-modsig` template; appended module signature measurement |
| 5.12 | `CRITICAL_DATA` hook; `ima_measure_critical_data()` for in-kernel state |
| 5.x+ | Ongoing namespace (`ima_ns`) work; per-namespace measurement lists |

## Further Reading

1. [The Integrity Measurement Architecture (LWN, 2005)](https://lwn.net/Articles/137306/) — original design article explaining the attestation model
2. [IMA appraisal extension (LWN, 2012)](https://lwn.net/Articles/488906/) — describes the transition from passive measurement to enforcement
3. [A kernel integrity subsystem update (LWN, 2018)](https://lwn.net/Articles/753276/) — broader overview of measurement + appraisal + EVM after years of development
4. [IMA: Infrastructure for measurement of critical kernel data (LWN, 2020)](https://lwn.net/Articles/835855/) — the `CRITICAL_DATA` hook and in-memory attestation
5. [IMA namespace support (LWN, 2021)](https://lwn.net/Articles/829035/) — namespace isolation design
6. [IMA Templates kernel.org doc](https://www.kernel.org/doc/html/latest/security/IMA-templates.html) — reference for template syntax and field IDs
7. [linux-ima project wiki](https://sourceforge.net/p/linux-ima/wiki/Home/) — upstream project documentation and user guides

## LKML Highlights

- **[ima: Linux Security Module implementation](https://lwn.net/Articles/136837/)** (2005) — the original submission thread; Reiner Sailer's debate with the LSM maintainers over whether IMA belonged in the LSM framework at all, establishing the precedent for integrity subsystems living under `security/integrity/`.
- **[ima: Introduce IMA namespace](https://lwn.net/Articles/829035/)** (2021) — reveals the tension between per-namespace measurement lists (needed for containers) and the global TPM PCR, which cannot be virtualised; the thread shaped the decision to make namespace PCR extension optional.
