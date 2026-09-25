---
title: "Smack Access Engine"
category: concept
tags: [security, smack, lsm, mac, access-control]
subsystem: security
kernel_version: "2.6.25"
researched: 2026-04-16
status: complete
explained: "[[smack-access-engine-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html
  - https://github.com/torvalds/linux/blob/master/security/smack/smack_lsm.c
  - https://docs.huihoo.com/doxygen/linux/kernel/3.7/smack__access_8c.html
---

# Smack Access Engine

> 📘 Plain-language version: [[smack-access-engine-explained]]

## Purpose

The access engine is the single authoritative function that all ~100 Smack LSM hooks reduce to: does subject label S hold mode M access to object label O? Without a centralised decision function, each hook would re-implement its own rule-walking logic, causing policy inconsistencies. By funnelling every decision through `smk_access()`, Smack guarantees that the same rule semantics apply whether the check is for a file open, a signal send, or a socket connect.

## Mental Model

The access engine is a firewall rule lookup with a built-in special-case table. Before consulting the administrator's rules it evaluates five hard-wired cases in order (star, hat, floor, star-object, same-label). If none match, it walks the subject's personal rule list for an explicit grant. If nothing grants the access, default deny. The administrator cannot override the hard-wired cases — they are invariants of the label system.

## How It Works

Every Smack LSM hook resolves the subject and object labels into `struct smack_known` pointers (via `smack_cred()` and `smack_inode()` helpers) and then calls either `smk_access()` or its convenience wrapper `smk_curacc()`.

`smk_access()` (`security/smack/smack_access.c`) evaluates in strict order:

1. **Star subject** — if the subject pointer equals `&smack_known_star`, deny everything. The star label is Smack's quarantine label: a process labelled `"*"` is completely isolated and can reach nothing. This rule cannot be overridden by any capability or rule.

2. **Hat subject** — if the subject pointer equals `&smack_known_hat`, grant `MAY_READ | MAY_EXEC` and deny `MAY_WRITE | MAY_APPEND`. The hat label is for observer processes that need read-only access to everything (e.g., monitoring daemons) without administrator-written rules.

3. **Floor object** — if the object pointer equals `&smack_known_floor`, grant `MAY_READ | MAY_EXEC` to any subject. The floor label marks public resources accessible to all (analogous to world-readable files, but enforced by MAC).

4. **Star object** — if the object pointer equals `&smack_known_star`, grant all access to any subject. Star on an object means "universally writable"; it is used for shared IPC endpoints and pipes where all domains must communicate.

5. **Same label** — if subject and object pointers are identical, grant all requested access. A process can always access its own files without explicit self-rules.

If none of the special cases match, the engine locks `subject->smk_rules_lock` (read-side) and walks the `smk_rules` RB-tree. Each node is a `struct smack_rule`; the tree is ordered by `smk_object` pointer value. A binary search finds the node whose `smk_object == object_label`. If found, the engine ANDs `rule->smk_access & requested_access`; if the result equals `requested_access`, access is granted (return 0). Otherwise it is denied (return `-EACCES`). If no node is found, default deny applies.

`smk_curacc()` is the thin wrapper used by most hooks. It sets the subject label from `smack_cred(current_cred())->smk_task`, calls `smk_access()`, and — before returning the denial — checks `capable(CAP_MAC_OVERRIDE)`. If the task holds this capability, the denial is overturned and a note is made for the audit record. `CAP_MAC_ADMIN` is a separate capability that governs *writing* policy (loading rules, changing labels); `CAP_MAC_OVERRIDE` governs *bypassing* policy at access time.

After the decision, `smack_log()` is called when auditing is enabled. It constructs a `struct smk_audit_info` containing subject label string, object label string, the requested access bitmask, the decision, and the name of the calling function (e.g., `"smack_inode_permission"`). This is emitted as a Linux Audit event of type `AUDIT_AVC` with Smack-specific key-value pairs.

The audit verbosity is controlled by the `smackfs/logging` knob: 0 = silent, 1 = log denials, 2 = log grants, 3 = log everything. On production systems, mode 1 is typical.

## Key Data Structures

**`struct smack_rule`** (`security/smack/smack.h`) — one node per subject→object permission grant.
- `smk_subject` — pointer to the subject `smack_known` entry; the entry whose `smk_rules` tree this node lives in
- `smk_object` — pointer to the object `smack_known` entry; the RB-tree key
- `smk_access` — bitmask combining `MAY_READ (1)`, `MAY_WRITE (2)`, `MAY_EXEC (4)`, `MAY_APPEND (8)`, `MAY_TRANSMUTE (16)`, `MAY_LOCK (32)`, `MAY_BRINGUP (64)`
- `list` — `struct rb_node` linking into the subject's `smk_rules` RB-tree

**`struct smk_audit_info`** (`security/smack/smack.h`) — passed to `smack_log()`; aggregates all fields needed for one audit record without multiple lookups.

## Key Functions / Entry Points

**`smk_access()`** (`security/smack/smack_access.c`) — core permit/deny logic; takes subject `smack_known*`, object `smack_known*`, access bitmask, and optional audit info; returns 0 or `-EACCES`.

**`smk_curacc()`** (`security/smack/smack_access.c`) — `current`-context convenience wrapper; resolves subject from `current_cred()`, calls `smk_access()`, checks `CAP_MAC_OVERRIDE` on denial.

**`smack_log()`** (`security/smack/smack_access.c`) — builds and emits an `AUDIT_AVC` audit record; called by `smk_access()` when `smack_logging` != 0.

**`smk_write_rules_list()`** (`security/smack/smackfs.c`) — serialises all rules in the `smk_rules` RB-tree to userspace for `cat /sys/fs/smackfs/load2`.

## Important Flags & Config Options

- `smackfs/logging` — integer 0–3 controlling audit verbosity; no Kconfig equivalent, changed at runtime
- `CONFIG_AUDIT` — must be set for any audit records to be emitted; without it `smack_log()` is a no-op
- `CONFIG_SECURITY_SMACK_BRINGUP` — adds `MAY_BRINGUP` mode bit; rules with this bit grant access while emitting a bringup audit event, enabling incremental policy development
- `smackfs/onlycap` — if set, restricts `CAP_MAC_ADMIN` and `CAP_MAC_OVERRIDE` to processes carrying a specific label; other processes with those capabilities are still denied

## Interactions with Other Subsystems

- **↑ Userspace**: rules loaded via `smackfs/load2`; access queries via `smackfs/access2`
- **→ [[linux-audit]]**: `smack_log()` calls `audit_log_start()` / `audit_log_format()` / `audit_log_end()`
- **← [[smack-label-registry]]**: both subject and object labels must be canonical `smack_known` entries before `smk_access()` is called; the registry provides the pointers
- **← [[lsm-framework]]**: every `security_*()` call dispatches to a Smack hook that eventually calls `smk_access()` or `smk_curacc()`
- **← [[capabilities]]**: `smk_curacc()` calls `capable(CAP_MAC_OVERRIDE)` to allow privileged bypass

## Design Decisions & Tradeoffs

**No transitivity** — Smack rules are not transitive: if `A → B` and `B → C`, A cannot reach C unless there is an explicit `A → C` rule. This is simpler to reason about than SELinux type-enforcement transitions but means large policies require many explicit rules.

**RB-tree per subject** — early Smack stored all rules in a single list. Moving to per-subject RB-trees reduced worst-case lookup from O(n_rules) to O(log n_rules_for_subject), which mattered as Tizen deployments grew beyond 1000 rule entries.

**Hard-wired special labels** — the five reserved labels cannot be removed or repurposed. This was a deliberate choice to guarantee predictable defaults: every Smack system behaves the same way for `"*"` and `"_"` regardless of administrator configuration.

## How It Has Evolved

- **2.6.25**: single linked list for all rules; O(n) lookup.
- **3.x**: per-subject RB-tree; reduced hot-path cost on large policies.
- **4.x**: `MAY_TRANSMUTE` and `MAY_LOCK` mode bits added; `MAY_BRINGUP` added with `CONFIG_SECURITY_SMACK_BRINGUP`.
- **5.x**: per-task rule lists (`task_smack.smk_rules`) added to support temporary rules scoped to a single process (used by `relabel-self`).

## Further Reading

1. [Smack — kernel.org documentation](https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html)
2. [Smack for simplified access control — LWN.net](https://lwn.net/Articles/244531/)
3. [security/smack/smack_access.c — kernel source](https://github.com/torvalds/linux/blob/master/security/smack/smack_access.c)
