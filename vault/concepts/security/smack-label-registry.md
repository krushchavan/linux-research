---
title: "Smack Label Registry"
category: concept
tags: [security, smack, lsm, labels, mac]
subsystem: security
kernel_version: "2.6.25"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html
  - https://github.com/torvalds/linux/blob/master/security/smack/smack.h
  - https://docs.huihoo.com/doxygen/linux/kernel/3.7/smack_8h.html
---

# Smack Label Registry

## Purpose

Every Smack label is a short ASCII string, but comparing strings on every access check would be expensive. The label registry solves this by maintaining exactly one canonical `struct smack_known` per unique label string so that all access-check hot paths can compare pointers instead of strings. Without it, the system would either re-parse xattrs on every `open()` or hash-compare labels repeatedly through deep call stacks.

## Mental Model

Think of the label registry as a string-interning table. The first time the system sees label `"app"` — whether from an xattr, a smackfs write, or a CIPSO packet — it allocates one `smack_known` entry for `"app"` and returns its address. Every subsequent reference to `"app"` gets back the same pointer. Two inodes carrying `"app"` point to identical memory, so the access engine can use a single `==` comparison instead of `strcmp()`.

## How It Works

At kernel initialisation, `smack_init()` pre-allocates entries for all five reserved labels: `"*"` (star), `"^"` (hat), `"_"` (floor), `"?"` (invalid/unset), and `"@"` (internet). These cover all the built-in rules and are always available without any administrator action.

When a new label arrives — via `smackfs/load2`, an xattr read in `smack_inode_init_security()`, or a decoded CIPSO packet — the path leads to `smk_import()` in `security/smack/smack_access.c`. The function first calls `smk_find_entry()`, which hashes the string and probes the global `smack_known_hash` table (a `struct hlist_head` array indexed by label hash). If a matching entry exists, its pointer is returned immediately with no allocation.

On a cache miss, `smk_import()` allocates a new `struct smack_known`, copies the label string into `smk_known`, assigns the next `smk_secid` integer (monotonically increasing, used by the audit subsystem), calls `netlbl_secattr_init()` then `smk_netlbl_mls()` to pre-compute the CIPSO wire representation into `smk_netlabel`, initialises an empty RB-tree root for `smk_rules`, initialises `smk_rules_lock`, and finally inserts the entry into both `smack_known_hash` and the linked list `smack_known_list`. The linked list is used by smackfs to enumerate all known labels; the hash table is used for O(1) lookup during access checks.

The reserved-label entries are identified by their pre-allocated pointers. Code that needs `"*"` refers to `&smack_known_star`, never by string lookup, which avoids any hash overhead on the absolute hottest paths.

## Key Data Structures

**`struct smack_known`** (`security/smack/smack.h`) — one entry per unique label string in the system.
- `smk_known` — the label string, NUL-terminated, up to 255 characters
- `smk_secid` — monotonically assigned integer; used by Linux Audit and for SELinux interop via `security_secid_to_secctx()`
- `smk_netlabel` — pre-computed `struct netlbl_lsm_secattr`; built once on import so CIPSO tagging avoids repeated string-to-MLS conversion at send time
- `smk_rules` — `struct rb_root` of `smack_rule` nodes where this label is the subject; populated by rule loads
- `smk_rules_lock` — `struct mutex` protecting concurrent insertions into `smk_rules`
- `list` — `struct list_head` linking into `smack_known_list` (for enumeration)
- `smk_hashed` — `struct hlist_node` for the `smack_known_hash` bucket

## Key Functions / Entry Points

**`smk_import()`** (`security/smack/smack_access.c`) — create-or-return a canonical label; the single allocation point for new labels; called by xattr readers, rule parsers, and NetLabel callbacks.

**`smk_find_entry()`** (`security/smack/smack_access.c`) — hash lookup without allocation; returns NULL if label not found; used in the access-check fast path to avoid lock contention on the write path.

**`smack_init()`** (`security/smack/smack_lsm.c`) — called at kernel security init; pre-allocates entries for the five reserved labels and registers the `smack_hooks` array with the LSM framework.

## Important Flags & Config Options

- `CONFIG_SECURITY_SMACK=y` — enables the entire Smack subsystem, including the registry; there is no per-label configuration.
- Label length is enforced to ≤255 characters (`SMK_LONGLABEL`); labels ≤23 characters (`SMK_LABELLEN`) are recommended for compatibility with older interfaces.

## Interactions with Other Subsystems

- **↑ Userspace**: labels enter via `write(smackfs/load2, ...)` and xattr setters; the label registry is the sink for all incoming label strings
- **→ [[netlabel]]**: on first import, `smk_netlbl_mls()` is called to encode the label into CIPSO MLS categories; the result is cached in `smk_netlabel` and passed to NetLabel on every outgoing packet
- **→ [[linux-audit]]**: `smk_secid` is used as the numeric identity when generating audit log entries
- **← [[smack-access-engine]]**: the access engine calls `smk_find_entry()` to resolve subject and object labels before walking the rule tree
- **← [[smack-inode-and-task-labeling]]**: inode and task labeling call `smk_import()` when reading xattrs or committing new credentials

## Design Decisions & Tradeoffs

Pointer identity rather than string comparison is the central design choice. It shifts all string work to label import time (infrequent) and makes the per-syscall access check as cheap as a single pointer dereference. The cost is that labels cannot be deleted from the registry — once imported, a label occupies memory for the kernel's lifetime. On embedded systems with bounded policy sets this is fine; on systems that dynamically generate many labels it could be a concern.

## How It Has Evolved

- **2.6.25**: initial registry with simple linear list; `smk_find_entry()` was O(n).
- **3.x**: hash table added for O(1) lookups as production deployments (Tizen) grew to hundreds of labels.
- **4.x**: `smk_secid` allocation changed from a protected global counter to an atomic to reduce contention on multi-core systems loading policy in parallel.

## Further Reading

1. [Smack — kernel.org documentation](https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html)
2. [Smack for simplified access control — LWN.net](https://lwn.net/Articles/244531/)
