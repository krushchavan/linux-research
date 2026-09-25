---
title: "Smack Inode and Task Labeling"
category: concept
tags: [security, smack, lsm, xattr, credentials, mac]
subsystem: security
kernel_version: "2.6.25"
researched: 2026-04-16
status: complete
explained: "[[smack-inode-and-task-labeling-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html
  - https://github.com/torvalds/linux/blob/master/security/smack/smack.h
  - https://github.com/torvalds/linux/blob/master/security/smack/smack_lsm.c
---

# Smack Inode and Task Labeling

> 📘 Plain-language version: [[smack-inode-and-task-labeling-explained]]

## Purpose

Access control requires that every subject (task) and object (file, directory, IPC) carry a label. Inode labeling attaches a persistent Smack label to filesystem objects via extended attributes so the label survives across reboots. Task labeling attaches a label to each process credential so the kernel knows the subject identity for every access check. Without both halves, the access engine has nothing to compare.

## Mental Model

Think of inode labeling as a sticky note on every file that says "I belong to domain X". Think of task labeling as the badge a process carries saying "I am domain Y". The access engine looks at both badge and sticky note, checks the rule book, and decides whether Y can touch X. The badge is copied on `fork()` and optionally swapped on `exec()` if the executable has its own sticky note (`SMACK64EXEC`).

## How It Works

### Inode labeling

When a new inode is created (file, directory, symlink), VFS calls `security_inode_init_security()`, which dispatches to `smack_inode_init_security()`. This hook reads the creating task's current Smack label (`smack_cred(current_cred())->smk_task`) and sets it as the `security.SMACK64` xattr on the new inode. It also checks the parent directory for `SMACK64TRANSMUTE=TRUE`: if the directory is marked as transmuting *and* the access rule for the creator→directory pair includes the `MAY_TRANSMUTE` bit, the new inode inherits the *directory's* label instead of the creator's. This transmute mechanism lets shared directories force all new files into a common domain regardless of which process created them.

On the first `open()` or `permission()` check of an existing inode, `smack_inode_smk()` reads the `security.SMACK64` xattr from disk and calls `smk_import()` to resolve it to a canonical `smack_known` pointer, which is cached in `smack_inode(inode)->smk_inode`. Subsequent checks use the cached pointer directly — no xattr read, no string comparison.

The `SMACK64MMAP` xattr adds a third label: the "mmap label". `smack_mmap_file()` verifies that the current task has write access to this label before allowing a memory mapping. This prevents a confined process from mapping a file owned by a less-trusted domain and using it as a covert write channel.

On filesystems mounted with the `SMACK_SB_UNTRUSTED` superblock flag (set via `smackfs` or mount options), an additional constraint applies: the inode's `smk_inode` must equal the filesystem root's label. This prevents a hostile disk image from carrying arbitrary labels that could grant unintended access.

### Task labeling

Every `struct cred` has a Smack blob allocated by the LSM infrastructure. The blob contains a `struct task_smack`:

- `smk_task` — the task's current effective Smack label; used as the subject in all access checks via `smack_cred(cred)->smk_task`.
- `smk_forked` — a snapshot of the label at the time the process was forked; preserved for audit purposes and used to detect label transitions.
- `smk_transmuted` — if the task has undergone a transmute-based label change, the new label is recorded here.
- `smk_relabel` — a list of `smack_known` pointers that this task is permitted to transition to via `relabel-self` without `CAP_MAC_ADMIN`.
- `smk_rules` / `smk_rules_lock` — a per-task rule list that can augment the global rules; used in `relabel-self` scenarios.

On `fork()`, `smack_cred_prepare()` copies the parent's `task_smack` in full, including `smk_task`, `smk_forked`, and the `smk_relabel` list. The child begins with the exact same label as the parent.

On `execve()`, after the new binary's credentials are committed, `smack_bprm_committing_creds()` runs. It reads the `SMACK64EXEC` xattr from the executable inode (`bprm->file`). If present, the executing task's `smk_task` is changed to the exec label. This is how privilege-transitions are expressed in Smack — no setuid bit required — and it requires the binary itself to carry the target label, not just a policy rule, which reduces accidental escalation.

The task's current label is visible to userspace at `/proc/self/attr/current`. `smack_getprocattr()` reads it; `smack_setprocattr()` allows changing it, but only with `CAP_MAC_ADMIN` or if the target label appears in the task's `smk_relabel` list.

## Key Data Structures

**`struct inode_smack`** (`security/smack/smack.h`) — the Smack security blob for an inode.
- `smk_inode` — pointer to the file's canonical `smack_known`; the primary access-check label
- `smk_task` — label of the task that created the inode; used by `smack_mmap_file()`
- `smk_mmap` — label for mmap access control (from `SMACK64MMAP` xattr)
- `smk_flags` — `SMK_INODE_INSTANT` (label already cached) and `SMK_INODE_TRANSMUTE` (directory is transmuting)

**`struct task_smack`** (`security/smack/smack.h`) — the Smack security blob embedded in `struct cred`.
- `smk_task` — effective Smack label for this task; the subject in all access checks
- `smk_forked` — label at fork time; used to detect post-fork transitions in audit records
- `smk_transmuted` — label acquired via a transmute rule change
- `smk_rules` / `smk_rules_lock` — per-task augment rules used by `relabel-self`
- `smk_relabel` — `list_head` of `smack_known` pointers this task may self-transition to

## Key Functions / Entry Points

**`smack_inode_init_security()`** (`security/smack/smack_lsm.c`) — sets `SMACK64` xattr on new inodes; checks for transmute; called from `security_inode_init_security()` at inode creation.

**`smack_inode_permission()`** (`security/smack/smack_lsm.c`) — main file permission hook; resolves inode label, calls `smk_curacc()`; also enforces `SMACK_SB_UNTRUSTED` constraint.

**`smack_bprm_committing_creds()`** (`security/smack/smack_lsm.c`) — handles exec-label transitions by reading `SMACK64EXEC` from the executable and updating `smk_task`.

**`smack_cred_prepare()`** (`security/smack/smack_lsm.c`) — copies parent `task_smack` on fork; ensures label continuity across process creation.

**`smack_setprocattr()`** (`security/smack/smack_lsm.c`) — allows privileged label changes via `/proc/self/attr/current`; enforces `CAP_MAC_ADMIN` or `smk_relabel` check.

## Important Flags & Config Options

- `SMACK64` xattr (`security.SMACK64`) — primary inode label; set by the kernel on creation, changeable by `CAP_MAC_ADMIN` processes
- `SMACK64EXEC` xattr — executable's exec-transition label; applied to task on `execve()`
- `SMACK64MMAP` xattr — mmap access control label; checked by `smack_mmap_file()`
- `SMACK64TRANSMUTE` xattr — `"TRUE"` on a directory enables transmutation for new children
- Mount options: `smackfsdef=<label>` (default for unlabeled inodes), `smackfsroot=<label>`, `smackfsfloor=<label>`, `smackfshat=<label>`, `smackfstransmute=<label>`
- `smackfs/relabel-self` — per-process list of permitted self-transitions, writable only with `CAP_MAC_ADMIN`

## Interactions with Other Subsystems

- **↑ Userspace**: processes read their label from `/proc/self/attr/current`; `attr` command sets `security.SMACK64` on files; session managers use `/proc/self/attr/current` writes for transitions
- **→ [[smack-label-registry]]**: `smk_import()` is called whenever an xattr is read to resolve the string to a canonical pointer
- **→ [[smack-access-engine]]**: `smk_curacc()` is called with resolved task and inode labels as subject/object
- **← [[vfs]]**: VFS calls `security_inode_init_security()`, `security_inode_permission()`, `security_inode_setxattr()`, `security_mmap_file()`, and `security_bprm_committing_creds()` at the right points
- **← [[credentials]]**: `task_smack` is stored in the LSM blob of `struct cred`; the blob infrastructure allocates and copies it on credential operations

## Design Decisions & Tradeoffs

**xattr-backed persistence** — storing labels in xattrs makes them filesystem-resident and independent of the process. Any filesystem that supports xattrs can carry Smack labels without modification. The cost is that filesystems without xattr support (FAT, some network filesystems) require the `smackfsdef` mount option to assign a uniform default label.

**Exec-label transitions as the only lateral move** — a running process cannot change its label arbitrarily; it must execute a labeled binary. This prevents a compromised process from silently escalating by writing its own label. The `relabel-self` interface is a controlled exception that allows session managers to drive transitions without full `CAP_MAC_ADMIN`.

**Transmute for shared directories** — the transmute bit solves the common problem of multiple processes in different domains all writing to a shared data directory. Without transmutation, the directory would fill up with files carrying heterogeneous labels, requiring per-file rules. With transmutation, all files automatically carry the directory label and a single rule governs access.

## How It Has Evolved

- **2.6.25**: basic `SMACK64` xattr and `smk_task` in credentials.
- **3.x**: `SMACK64EXEC`, `SMACK64MMAP`, and `SMACK64TRANSMUTE` added; exec-label transitions enabled without setuid.
- **4.x**: `relabel-self` smackfs interface added; per-task rule lists introduced for `relabel-self` transitions; `smk_forked` field added for richer audit records.
- **5.x**: LSM blob infrastructure refactor; `task_smack` moved from a raw pointer in `cred->security` to an infrastructure-managed blob with proper allocation/copy hooks.

## Further Reading

1. [Smack — kernel.org documentation](https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html)
2. [Smack: label for task objects — LWN.net](https://lwn.net/Articles/415590/)
3. [Smack for simplified access control — LWN.net](https://lwn.net/Articles/244531/)
