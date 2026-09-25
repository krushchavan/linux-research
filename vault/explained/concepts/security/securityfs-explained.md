---
title: "securityfs — Explained"
category: explained
original: "[[securityfs]]"
subsystem: security
tags: [explained, security, securityfs, pseudo-filesystem, lsm]
converted: 2026-09-25
---

# securityfs, explained

> Plain-language companion to [[securityfs|the technical note]]. Same facts, fewer identifiers.

## The problem

Security modules need to talk to user space: load a policy, switch a mode, report status, publish a measurement log. Before 2.6.14, each module either invented its own filesystem or squeezed its files into /proc, producing a pile of incompatible interfaces. And the existing generic options didn't fit:
- **/proc** is organised around processes and awkward for anything else
- **sysfs** insists on one value per file, which clashes with policy files full of structured rules
- **debugfs** is for debugging and promises no stability

## The idea in one paragraph

securityfs is a **shared cork board in a locked room**, mounted at /sys/kernel/security. Any security module can pin up its own files, directories and symlinks, as simple or as elaborate as it needs, because each module supplies its **own file operations**. The room is mounted so nothing there can be executed or used to gain privileges. Each module owns its corner and must take its notices down itself when it leaves.

## Step by step

### Step 1: One filesystem, mounted early
securityfs registers with the VFS at boot. systemd mounts it early at /sys/kernel/security if any security module is present, and modules can trigger the mount themselves if needed. It's always mounted read-write but **no-setuid** and **no-exec**, not configurable per mount. A file at its root lists the active security modules.

### Step 2: Create entries with three calls
The whole API is three creation functions:
- **create a file**, with the module's own file operations and a private data pointer the operations can find later
- **create a directory**, which is how a module claims its subtree (apparmor/, ima/, smack/)
- **create a symlink** (its target string no longer needs a heap copy when it's a constant, since a 2026 change)

The caller must keep the returned handle; it's the only way to remove the entry later.

### Step 3: Module-defined behaviour
This is the key step, and the reason securityfs exists instead of reusing sysfs. Because modules supply full file operations, they can implement any semantics: ioctls, multi-line policy files, or **transactional writes**. IMA's policy file is the classic example: each write appends a rule, and **closing** the file activates the whole new ruleset atomically. sysfs's one-value-per-file model would make that impossible.

### Step 4: Remove explicitly
There's no automatic cleanup: a module must remove its entries itself, either one at a time or with a recursive removal (added in the 5.x series). This was chosen over automatic reference-counted cleanup because that could race with readers, and security data should disappear only when its module deliberately removes it. The cost is that a buggy module can leave stale entries behind.

### Step 5: Its biggest user, IMA
IMA's subtree holds the policy file (write rules, activated on close), human-readable and binary measurement logs (the binary one used for remote attestation), and a violations counter. With TPM support, there are also per-hash-algorithm logs. A 2026 fix stopped a crash when the TPM reported a hash algorithm the kernel didn't know: such algorithms now get generically named files instead of an out-of-bounds lookup.

### Step 6: Containers, not yet
Today securityfs is effectively one global instance. A namespace-keyed mount path (3.18) and permission to mount inside user namespaces lay the groundwork for per-container instances, and proposals exist to give IMA and AppArmor per-namespace trees. The design rule is strict: a namespace's policy must be in place before its first process appears, so the very first process is covered. None of this is in mainline as of 6.x.

## The picture

```text
 /sys/kernel/security/            (rw, nosuid, noexec)
 ├── lsm                          "lockdown,yama,apparmor,…"
 ├── apparmor/                    profiles, modes, loading
 ├── ima/
 │   ├── policy                   write rules … close → activate atomically
 │   ├── ascii_runtime_measurements
 │   ├── binary_runtime_measurements   (for attestation)
 │   └── violations
 └── smack/                       labels and rules
 each module: own file operations, own cleanup
```

## Tradeoffs

- **What it gives you:** one stable, security-scoped place for every module's interface, with full freedom over file behaviour, which an early (2005) discussion decided was more important than sysfs-style structure.
- **What it costs / requires:** each module implements complete file semantics itself, and must clean up after itself.
- **Where it bites:** no per-namespace instances yet, so containers can't have their own security-module policies through it. A 2025–2026 rework of security-module initialisation (Paul Moore, 34 patches) routed all modules' securityfs setup through one start-up sequence, but one regression in it coupled securityfs set-up to unrelated security settings, showing the tension between integration and modularity.

## How it got here

- **2.6.14 (2005):** introduced, replacing per-module filesystems; one early module shed about 88 lines of its own interface code.
- **2.6.30 (2009):** IMA arrives and makes securityfs home to measurement logs.
- **3.18 (2014):** the namespace-keyed mount path, groundwork for container isolation.
- **5.x:** recursive removal of whole subtrees.
- **6.10 (2024):** TPM-related interfaces extended with interposer-attack detection.
- **2025–2026:** the security-module initialisation rework, the IMA hash-algorithm fix, and the constant symlink-target change.

## Related

- Technical version: [[securityfs]]
- [[security-explained|Security subsystem]], [[lsm-framework-explained|LSM framework]], [[ima-explained|IMA]], [[apparmor-explained|AppArmor]], [[smackfs-explained|smackfs]], [[tpm|TPM]], [[kernel-keyring-explained|Kernel keyring]]
- [[vfs-explained|VFS]]
