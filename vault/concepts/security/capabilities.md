---
title: "Linux Capabilities"
category: concept
tags: [security, capabilities, privileges, credentials, posix]
subsystem: security
kernel_version: "2.2"
researched: 2026-04-15
status: complete
explained: "[[capabilities-explained]]"
sources:
  - https://kernel-internals.org/security/capabilities/
  - https://www.kernel.org/doc/html/latest/security/credentials.html
---

# Linux Capabilities

> 📘 Plain-language version: [[capabilities-explained]]

## Overview

Linux capabilities decompose the monolithic `root` privilege into approximately 40 discrete, independently grantable powers. Rather than a binary root-or-not model, a process can hold exactly the capabilities it needs — `CAP_NET_BIND_SERVICE` to bind port 80, `CAP_SYS_TIME` to set the clock, `CAP_SYS_MODULE` to load drivers — and nothing more. The model was introduced in Linux 2.2 (1999) based on the withdrawn POSIX.1e draft.

## How It Works

Every process carries five capability bitmasks inside its `struct cred`. The kernel consults these at every privileged operation via `capable(CAP_X)` or `ns_capable(ns, CAP_X)`. The bitmasks form a hierarchy:

```
Bounding ─── ceiling; removing from bounding is permanent
   │
   └── Permitted ─── superset of Effective
          │
          └── Effective ─── what is actually checked during access decisions
                │
                └── Inheritable ─── survive execve() if file also grants them

Ambient ────────── auto-inherit across execve() unconditionally (v4.3+)
```

**Bounding set** — A hard ceiling. Once you `prctl(PR_CAPBSET_DROP, CAP_SYS_MODULE)`, that capability can never return to this process or any descendant, even via `setuid`. Dropping from bounding is the primary mechanism by which privilege-separating daemons guarantee they cannot re-escalate.

**Permitted set** — The pool from which Effective caps are drawn. You can lower Effective without losing Permitted, then raise it again later. You can never raise Permitted beyond Bounding.

**Effective set** — The live set checked by `capable()`. Lowering Effective is a temporary drop (useful during sensitive operations); raising it requires Permitted to already contain the cap.

**Inheritable set** — Caps that survive `execve()`, but only if the executed file's `cap_inheritable` xattr also contains them. Both process and file must agree; this prevents privilege leakage through arbitrary exec.

**Ambient set** (v4.3) — Caps that are automatically inherited by child processes and across `execve()` without the file needing to agree. This solved the problem of launching non-suid helper binaries (e.g. a Python script) that need capabilities from their parent. The ambient set may only contain caps present in both Effective and Inheritable.

### File Capabilities

Executables can have capabilities stored in the `security.capability` extended attribute, set with `setcap(8)`. The fields use the same `e`/`i`/`p` notation (effective, inheritable, permitted). When the kernel executes such a binary via `execve()`, it merges the file's caps with the calling process's caps using the following transformation:

```
P'(permitted)   = (P(inheritable) & F(inheritable)) | (F(permitted) & P(bounding))
P'(effective)   = F(effective) ? P'(permitted) : P'(effective) & P'(inheritable)
P'(inheritable) = P(inheritable)
```

This allows, for example, `ping` to hold `CAP_NET_RAW` via its file capability instead of a setuid bit.

### The Kernel Check Path

At a privileged operation (e.g. binding a port below 1024), the kernel calls:

```c
if (!ns_capable(net->user_ns, CAP_NET_BIND_SERVICE))
    return -EPERM;
```

`ns_capable()` retrieves the current process's `struct cred` via `current_cred()` (an RCU-safe read of `current->cred`) and checks the effective capability bitmask. For namespaced resources, it checks whether the process has the cap in the *user namespace that owns the network namespace*, not necessarily the global namespace — this is what allows containers to have their own privileged operations scoped to their namespace.

### No-New-Privs

`prctl(PR_SET_NO_NEW_PRIVS, 1)` sets a per-process flag in `task_struct` that permanently prevents the process from gaining new privileges via `execve()`. Once set, it cannot be unset. setuid binaries will not grant new uid; file capabilities will not be applied. This flag is required before a process can install seccomp filters without `CAP_SYS_ADMIN`.

### CAP_SYS_ADMIN: the Design Regret

`CAP_SYS_ADMIN` covers 40+ unrelated operations: mounting filesystems, configuring namespaces, ptrace unrestricted, keyring administration, quota management, resource limits, hostname changes, and more. It accumulated organically over 25 years as the "everything else" bucket. Any process that holds `CAP_SYS_ADMIN` is effectively root-equivalent. Modern practice is to avoid it: narrower capabilities (e.g. `CAP_SETFCAP`, `CAP_NET_ADMIN`, specific namespace creation caps) should be preferred, and new privileged operations should be assigned dedicated capabilities.

## Key Data Structures

**`struct cred`** (`include/linux/cred.h`)
- `cap_inheritable` — `kernel_cap_t` (u64 bitmask)
- `cap_permitted`
- `cap_effective`
- `cap_bounding`
- `cap_ambient`

**`kernel_cap_t`** — `__u32[2]` (64-bit bitmask covering all ~64 defined caps, currently ~42 used)

## Key Functions

- `capable(CAP_X)` — check current task's effective set (global namespace)
- `ns_capable(ns, CAP_X)` — check in namespace context (container-safe)
- `cap_raise(set, cap)` / `cap_lower(set, cap)` — bitmask helpers
- `security_capset()` — LSM hook invoked on `capset(2)`
- `cap_task_prctl()` — handles `PR_CAP_AMBIENT_*` prctl calls
- `get_file_caps()` — reads file capability xattr during `execve()`

## Config & Flags

- `CAP_LAST_CAP` — highest defined capability number (currently 40; grows rarely)
- `prctl(PR_SET_NO_NEW_PRIVS, 1)` — permanent privilege elevation block
- `prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, CAP_X, 0, 0)` — raise an ambient cap
- `prctl(PR_CAPBSET_DROP, CAP_X)` — permanently drop from bounding set
- `/proc/<pid>/status` — shows all five sets in hex bitmask format

## Interactions

- **[[credentials]]** — capability sets live inside `struct cred`; all changes go through `prepare_creds()` / `commit_creds()`
- **[[lsm-framework]]** — capability checks are themselves an LSM (`commoncap`), always the first module loaded
- **[[seccomp-bpf]]** — `PR_SET_NO_NEW_PRIVS` is required before installing seccomp filters without `CAP_SYS_ADMIN`
- **[[user-namespaces]]** — `ns_capable()` makes capabilities namespace-scoped; a process root-in-a-user-namespace has caps only within that namespace
