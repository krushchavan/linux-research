---
title: "smackfs"
category: concept
tags: [security, smack, lsm, pseudo-filesystem, policy]
subsystem: security
kernel_version: "2.6.25"
researched: 2026-04-16
status: complete
explained: "[[smackfs-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html
  - https://github.com/torvalds/linux/blob/master/security/smack/smackfs.c
  - https://wiki.tizen.org/Security:SmackConfiguration
---

# smackfs

> 📘 Plain-language version: [[smackfs-explained]]

## Purpose

smackfs is the administration interface for Smack: a `securityfs`-backed pseudo-filesystem mounted at `/sys/fs/smackfs` where privileged processes load access rules, configure network labeling, and inspect policy state. Without smackfs, the Smack policy is limited to the hard-wired special-label rules and whatever labels were applied before the filesystem was available; there is no way to load custom rules or configure network label assignments.

## Mental Model

Think of smackfs as the control panel for the Smack policy engine. Every file in `/sys/fs/smackfs` is a knob or readout: write to `load2` to add a rule, write to `cipso2` to define a network label mapping, read `load2` to dump the full policy. The kernel evaluates rules immediately on write — there is no commit step, no policy reload daemon, no compile phase.

## How It Works

smackfs is registered during `smack_init()` via `register_filesystem(&smk_fs_type)`. When the filesystem is first mounted (which happens early in `init` before most daemons run, via `/etc/fstab` or `systemd`), `smk_fill_super()` in `security/smack/smackfs.c` is called to create the directory tree. It registers each policy interface as an `inode` with dedicated `file_operations` structs — effectively the same pattern as `procfs` and `debugfs`.

The key interfaces and how they work:

**`load2`** — the primary rule interface. A write of `"subject_label object_label rwxat"` (or `"subject object -"` to revoke all) is parsed by `smk_parse_long_rule()`. Both labels are imported via `smk_import()` (creating canonical `smack_known` entries if needed). A `smack_rule` node is then searched for in the subject's `smk_rules` RB-tree. If found, its `smk_access` bitmask is updated; if not, a new node is allocated and inserted. The access mode string is parsed bit-by-bit: `r`→`MAY_READ`, `w`→`MAY_WRITE`, `x`→`MAY_EXEC`, `a`→`MAY_APPEND`, `t`→`MAY_TRANSMUTE`, `l`→`MAY_LOCK`, `b`→`MAY_BRINGUP`. A `-` clears all modes. The older `load` interface accepts only labels up to 7 characters but is otherwise identical; it exists for backward compatibility with early Smack deployments.

**`access2`** — a policy simulation interface. Write `"subject object mode"` and read back `"1\n"` or `"0\n"` indicating whether the access would be permitted. This is used by shell scripts during policy development (`echo "app server r" > /sys/fs/smackfs/access2; cat /sys/fs/smackfs/access2`) and by PAM modules that need to make access decisions in userspace.

**`cipso2`** — maps CIPSO DOI/level/category combinations to Smack labels for inbound packet classification. A write of `"label doi level categories"` is stored in the NetLabel MLS tables and associated with the canonical `smack_known` entry for `label` so that the access engine recognises incoming CIPSO-tagged packets as carrying that label. The older `cipso` interface again accepts only short labels.

**`netlabel`** — per-host label overrides bypassing CIPSO. A write of `"@192.168.1.5/32 webserver"` creates a `struct smk_net4addr` entry (IPv4) or `struct smk_net6addr` entry (IPv6) that is consulted in `smack_socket_sock_rcv_skb()` before CIPSO decoding. Packets from the specified address range are assigned the given label regardless of their CIPSO content.

**`doi`** — the CIPSO Domain of Interpretation number used on all outgoing packets (default: 3). All networked peers running Smack must agree on this value.

**`ambient`** — the label given to packets received without a CIPSO header. Default is `"_"` (floor). Changing this is the primary way to integrate Smack with network segments that do not support CIPSO.

**`onlycap`** — restricts who may hold `CAP_MAC_ADMIN` and `CAP_MAC_OVERRIDE` at the Smack level. Writing a label here means that processes without that label, even if they hold those Linux capabilities, will be denied Smack privilege. This is a defence-in-depth measure for systems where a leaked capability should not automatically grant MAC admin.

**`logging`** — runtime audit verbosity control: 0 (off), 1 (log denials), 2 (log grants), 3 (log both). Changes take effect immediately with no restart.

**`relabel-self`** — writes a label to a per-process allow-list stored in `task_smack.smk_relabel`. A process may then transition to any listed label via `write(/proc/self/attr/current, ...)` without `CAP_MAC_ADMIN`. Session managers use this to drive label transitions as part of login flows.

**`unconfined`** (requires `CONFIG_SECURITY_SMACK_BRINGUP`) — write a label here to place it in "bringup mode": processes carrying that label receive all accesses as if permitted, but every decision is logged as a bringup event. Used during initial policy development to discover what rules are needed without causing visible application breakage.

**`ptrace`** — controls whether `ptrace()` is restricted by Smack; two modes: 0 = exact-label match required, 1 = tracer must only have `CAP_MAC_OVERRIDE`.

All write operations require `CAP_MAC_ADMIN`, except `relabel-self` which enforces its own per-process allowlist check and the read operations which are available to any process with read permission on the file.

## Key Data Structures

**`struct superblock_smack`** (`security/smack/smack.h`) — Smack security blob for a mounted filesystem; consulted on every inode permission check on that mount.
- `smk_root` — label of the filesystem root directory
- `smk_floor` — label readable by any task on this filesystem
- `smk_hat` — label that can read all labels on this filesystem
- `smk_default` — label for unlabeled inodes (from `smackfsdef=` mount option)
- `smk_flags` — `SMACK_SB_INITIALIZED` (mount options processed) and `SMACK_SB_UNTRUSTED` (require root-label on all inodes)

**`struct smk_net4addr`** / **`struct smk_net6addr`** (`security/smack/smack.h`) — per-host CIPSO bypass entries.
- `smk_host` / `smk_mask` — IPv4/IPv6 address and network mask
- `smk_label` — canonical `smack_known*` to assign to matching packets

## Key Functions / Entry Points

**`smk_fill_super()`** (`security/smack/smackfs.c`) — populates `/sys/fs/smackfs` at mount time; creates all policy interface files.

**`smk_parse_long_rule()`** (`security/smack/smackfs.c`) — parses a `"subject object mode"` write to `load2`; handles both the `"–"` revoke form and the mode-bit form.

**`smk_write_rules_list()`** (`security/smack/smackfs.c`) — called on read of `load2`; iterates all `smack_known` entries and serialises their `smk_rules` RB-trees.

**`smk_netlabel_audit_set()`** — called after CIPSO mapping changes; synchronises the NetLabel tables with the updated Smack label attributes.

## Important Flags & Config Options

- `CONFIG_SECURITY_SMACK=y` — required
- `CONFIG_SECURITY_SMACK_BRINGUP=y` — enables `unconfined` and `bringup` audit modes
- Mount options on non-smackfs filesystems: `smackfsdef`, `smackfsroot`, `smackfsfloor`, `smackfshat`, `smackfstransmute`; set filesystem-wide defaults without touching individual inodes

## Interactions with Other Subsystems

- **↑ Userspace**: policy tools write rules, read current policy state, test hypothetical access decisions
- **→ [[smack-label-registry]]**: `smk_import()` is called for every new label encountered in writes to `load2`, `cipso2`, `netlabel`, etc.
- **→ [[smack-access-engine]]**: rules written to `load2` populate the per-subject RB-trees that `smk_access()` walks
- **→ [[netlabel]]**: CIPSO mappings written to `cipso2` and `netlabel` are synchronised into the NetLabel subsystem tables
- **← [[securityfs]]**: smackfs is mounted as a subdirectory of `securityfs`; it reuses the same VFS infrastructure as SELinux's `selinuxfs`

## Design Decisions & Tradeoffs

**No transaction semantics** — rules take effect immediately on write. There is no "begin transaction / commit / rollback" model. This simplifies the kernel implementation significantly but means that partially-loaded policy is visible to the running system. In practice, init scripts load all rules before starting application daemons, making this a non-issue; but it would matter if policy needed to be atomically updated on a live system.

**Single filesystem, no per-namespace isolation** — smackfs is global. All processes in all namespaces share the same Smack policy. This is intentional: Smack was designed for systems where the administrator controls the entire policy; per-namespace policy is a container-era requirement that is actively being worked on.

**File-per-interface** — rather than a single `ioctl()` or netlink interface, Smack uses one file per operation. This makes the interface accessible from shell scripts without any special tooling, which is important for embedded targets that may not have Python or Go available.

## How It Has Evolved

- **2.6.25**: initial smackfs with short-label interfaces (`load`, `access`, `cipso`).
- **3.x**: long-label interfaces (`load2`, `access2`, `cipso2`) added; label length increased from 7 to 255 characters; `onlycap` and `logging` added.
- **4.x**: `relabel-self` and `netlabel` added; `unconfined` interface added under `CONFIG_SECURITY_SMACK_BRINGUP`; `ptrace` control knob added.
- **5.x**: per-namespace smackfs proposed but not yet merged; mount-namespace isolation remains a work in progress.

## Further Reading

1. [Smack — kernel.org documentation](https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html)
2. [SmackConfiguration — Tizen Wiki](https://wiki.tizen.org/Security:SmackConfiguration)
3. [security/smack/smackfs.c — kernel source](https://github.com/torvalds/linux/blob/master/security/smack/smackfs.c)
