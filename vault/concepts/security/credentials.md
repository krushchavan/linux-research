---
title: "Credentials"
category: concept
tags: [security, credentials, cred, rcu, capabilities, identity]
subsystem: security
kernel_version: "2.6.29"
researched: 2026-04-15
status: complete
explained: "[[credentials-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/security/credentials.html
---

# Credentials

> 📘 Plain-language version: [[credentials-explained]]

## Overview

`struct cred` is the single authoritative record of a task's identity and privilege. Every access control decision in the kernel — capability checks, UID comparisons, LSM label lookups — reads from the task's credential structure. The design is immutable-after-commit with copy-on-write semantics: once a cred is live, nobody modifies it in place; changes require allocating a new copy, modifying it offline, then atomically swapping it in via RCU. This makes credential reads lockless and races practically impossible.

## How It Works

### Structure Layout

```c
struct cred {
    atomic_t    usage;              /* reference count */

    /* Traditional UNIX identity */
    kuid_t      uid, gid;           /* real uid/gid */
    kuid_t      suid, sgid;         /* saved-set uid/gid */
    kuid_t      euid, egid;         /* effective uid/gid */
    kuid_t      fsuid, fsgid;       /* filesystem uid/gid (usually = euid/egid) */

    /* Supplementary groups */
    struct group_info *group_info;

    /* Capability sets */
    kernel_cap_t    cap_inheritable;
    kernel_cap_t    cap_permitted;
    kernel_cap_t    cap_effective;
    kernel_cap_t    cap_bounding;
    kernel_cap_t    cap_ambient;

    /* Keyrings */
    struct key  *session_keyring;
    struct key  *process_keyring;
    struct key  *thread_keyring;

    /* Namespaces */
    struct user_namespace *user_ns;

    /* LSM-private data */
    void        *security;          /* or offset-based blob */

    /* Secure management flags */
    unsigned    securebits;         /* SECBIT_NOROOT etc. */
};
```

`task_struct` holds two cred pointers:
- `real_cred` — actual identity (used for signal delivery, `/proc` reporting)
- `cred` — effective identity (used for access control checks)

Both are RCU-protected. Code that reads another task's credentials must hold the RCU read lock and use `__task_cred(task)`. Code that reads its *own* credentials can use `current_cred()` directly without any lock, because the current thread cannot concurrently change its own cred pointer.

### Copy-on-Write Lifecycle

To change credentials (e.g., during `setuid(2)`, `execve()` with setuid bit, or capability manipulation), the kernel follows a strict protocol:

```c
/* 1. Duplicate current cred, lock replacement mutex */
struct cred *new = prepare_creds();
if (!new)
    return -ENOMEM;

/* 2. Modify the copy (safe — nobody else can see it yet) */
new->euid = target_uid;
cap_lower(new->cap_effective, CAP_SYS_ADMIN);

/* 3. LSM validation hooks */
retval = security_prepare_creds(new, old, GFP_KERNEL);
if (retval < 0) {
    abort_creds(new);
    return retval;
}

/* 4. Atomic swap — takes effect immediately for this task */
return commit_creds(new);   /* RCU-assigns task->cred, puts old */
```

`commit_creds()` uses `rcu_assign_pointer(task->cred, new)` to swap the pointer. The old cred's reference count is decremented; when it reaches zero (after the RCU grace period, so all RCU readers have finished), `put_cred()` frees it. The immutability guarantee ensures no reader ever sees a partially-modified credential.

`abort_creds(new)` is the error path — it simply decrements the reference count on the copy without committing, freeing it if nobody else holds a reference.

### The `f_cred` Field

`struct file` contains `f_cred` — a snapshot of the opener's credentials at the time `open(2)` returned. This prevents a specific privilege escalation: a process opens `/etc/shadow` while root, drops privileges, then passes the fd to unprivileged code. Without `f_cred`, the recipient could use the fd for operations that check the current cred (which is now unprivileged). With `f_cred`, operations that care about the opener's identity (e.g., `/proc` reporting, some LSM checks) use the opener's cred, not the current task's.

### Credential Override (BPRM and exec)

During `execve()`, the kernel builds new credentials via `prepare_bprm_creds()` and processes the binary's setuid bit and file capabilities before calling `commit_bprm_creds()`. The `linux_binprm` structure carries the in-flight credentials through the exec sequence so that all relevant decisions (setuid, setgid, file caps, LSM transitions) are made atomically relative to the credential swap.

### Securebits

The `securebits` field in `struct cred` stores `SECBIT_*` flags that modify how capabilities work:

- `SECBIT_NO_SETUID_FIXUP` — suppress the normal clearing of effective caps when uid changes to non-root
- `SECBIT_NOROOT` — prevent the kernel from granting capabilities to setuid-root binaries
- `SECBIT_NO_SETUID_FIXUP_LOCKED` / `SECBIT_NOROOT_LOCKED` — make the corresponding bits permanent

These bits are set via `prctl(PR_SET_SECUREBITS)` and are used by container runtimes and hardened service launchers.

## Key Data Structures

**`struct cred`** (`include/linux/cred.h`) — described above

**`struct group_info`** (`include/linux/cred.h`)
- `ngroups` — count of supplementary gids
- `gid[]` — sorted array for O(log n) membership check via `groups_search()`

## Key Functions

- `prepare_creds()` — allocate a mutable copy of `current_cred()`; increments old cred's refcount
- `commit_creds(new)` — RCU-swap task's `cred` pointer; decrement old cred
- `abort_creds(new)` — drop the mutable copy without committing
- `current_cred()` — lockless read of `current->cred` (safe for current task only)
- `__task_cred(task)` — read another task's cred (requires RCU read lock)
- `get_cred(cred)` / `put_cred(cred)` — reference counting
- `override_creds(cred)` — temporarily replace current task's cred (kernel internal use only)

## Config & Flags

- `SECBIT_NO_SETUID_FIXUP`, `SECBIT_NOROOT` — securebits via `prctl(PR_SET_SECUREBITS)`
- `kernel.dmesg_restrict`, `kernel.kptr_restrict` — sysctl flags that affect what credential-checking code reveals in logs
- `/proc/self/status` — shows UID, GID, groups, and capability sets

## Interactions

- **[[capabilities]]** — capability sets are fields within `struct cred`; all capability checks read from the effective cred
- **[[lsm-framework]]** — the `security` field in `struct cred` is the LSM blob; every LSM that needs per-task state uses this blob (managed by blob infrastructure since v5.1)
- **[[selinux]]** — stores task SID in the cred blob; domain transitions happen by committing a new cred with a different SID
- **[[seccomp-bpf]]** — the seccomp filter chain is stored in `struct task_struct`, not in cred, but `NO_NEW_PRIVS` status is checked via the cred's capability perspective
