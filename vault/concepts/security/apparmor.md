---
title: "AppArmor"
category: concept
tags: [security, apparmor, mac, path-based, lsm, ubuntu]
subsystem: security
kernel_version: "2.6.36"
researched: 2026-04-15
status: complete
explained: "[[apparmor-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/security/lsm.html
  - https://lwn.net/Articles/837994/
  - https://lwn.net/Articles/239962/
---

# AppArmor

> 📘 Plain-language version: [[apparmor-explained]]

## Overview

AppArmor (Application Armor) provides path-based Mandatory Access Control using human-readable profiles. Where SELinux requires labels on every object in the system, AppArmor confines applications based on the filesystem path of the file being accessed and the profile of the accessing program. This makes policy authoring accessible to administrators who do not have security expertise. AppArmor has been the default LSM on Ubuntu, Debian, and openSUSE systems since the mid-2010s and is used by default in most systemd-based distributions that are not Red Hat.

## How It Works

### Profile Format and Loading

An AppArmor profile is a text file that names a program and lists what it may do:

```
#include <tunables/global>

/usr/sbin/nginx {
    #include <abstractions/base>
    #include <abstractions/nameservice>

    /var/log/nginx/**  w,
    /var/www/html/**   r,
    /run/nginx.pid     rw,
    network inet stream,
    capability net_bind_service,
    capability setgid,
    capability setuid,
}
```

Permissions are single-letter tokens: `r` (read), `w` (write), `x` (execute), `m` (mmap with PROT_EXEC), `l` (link), `k` (lock). Path patterns support glob wildcards: `*` matches one path component, `**` matches any number.

Profiles are compiled by `apparmor_parser` into a binary policy and loaded into the kernel via `/sys/kernel/security/apparmor/policy/`. The kernel stores loaded profiles in a radix tree keyed by the profile name (which by convention matches the executable path).

### Profile Attachment — Domain Transitions

The kernel attaches a profile to a task during `execve()`. AppArmor checks whether the executed binary's path matches any loaded profile name. If so, the task transitions into that profile's domain. The `aa_profile` field in the task's AppArmor LSM blob is updated to point to the new profile.

Profiles can also define explicit **domain transitions** in their rules:

```
/usr/bin/mail  px -> mail,    # transition task to "mail" profile on exec
/usr/lib/sm**  Cx -> sm_msp,  # child domain transition
```

`px` triggers a profile transition; `ix` means inherit the current profile; `ux` means execute unconfined (no profile). This lets a confined service launch a helper binary that itself gets a more restrictive (or different) profile.

### Per-Hook Enforcement

At each LSM hook site, AppArmor retrieves the current task's profile via `aa_current_profile()` and checks whether the requested operation is permitted by the profile's rules. The primary hooks are:

- `apparmor_file_permission()` — checks path-based file access rules
- `apparmor_task_setrlimit()` — enforces resource limit rules
- `apparmor_socket_create()` / `apparmor_socket_connect()` — network access rules
- `apparmor_ptrace_access_check()` — ptrace confinement

For file checks, AppArmor must compute the path of the file relative to the filesystem root. This is more expensive than SELinux's label lookup because it requires a `d_path()` call to reconstruct the path string from the dentry chain. The result is checked against the profile's compiled DFA (Deterministic Finite Automaton) — the profile's path rules are compiled into a DFA for O(n) matching where n is the path length.

### Complain Mode

Each profile can be in **enforce** or **complain** mode. In complain mode, violations are logged (generating `AUDIT` records tagged with `apparmor="ALLOWED"` for operations that would be denied) but not blocked. This is the AppArmor equivalent of SELinux's permissive mode and is used for policy development.

### Stacking Status

AppArmor carries `LSM_FLAG_EXCLUSIVE` for some object types (primarily socket blobs), preventing it from being loaded alongside SELinux. The long-running stacking effort (tracked as part of the LSM infrastructure-managed blobs work) aims to remove this flag by converting the remaining object types to infrastructure-managed blobs. As of the v5.x series, the work is partially complete: task blobs, credential blobs, and inode blobs are infrastructure-managed, but socket-level objects remain exclusive.

## Key Data Structures

**`struct aa_profile`** (`security/apparmor/include/policy.h`)
- `base` — `struct aa_policy` with name, hname, and count
- `parent` — parent profile for child namespace profiles
- `file` — `struct aa_file_rules` — DFA compiled from path rules
- `caps` — `struct aa_caps` — allowed capability bitmask
- `net` — network access rules
- `mode` — enforce or complain

**`struct aa_task_ctx`** (in task LSM blob)
- `profile` — current confinement profile (`struct aa_profile *`)
- `onexec` — profile to transition into on next exec

## Key Functions

- `aa_file_perm(op, cred, file, request)` — path-based file check
- `aa_current_profile()` — retrieve calling task's profile (lockless via RCU)
- `aa_task_setrlimit()` — rlimit enforcement
- `apparmor_secfs_init()` — sets up `/sys/kernel/security/apparmor/`
- `aa_replace_profiles()` — atomic profile reload

## Config & Flags

- `CONFIG_SECURITY_APPARMOR`
- `apparmor=0` — disable AppArmor at boot
- `/sys/kernel/security/apparmor/profiles` — list loaded profiles and modes
- `aa-status` — show active profiles and their modes
- `aa-enforce <profile>` / `aa-complain <profile>` — switch mode

## Interactions

- **[[lsm-framework]]** — AppArmor is an LSM module; all enforcement is hook-based
- **[[selinux]]** — mutual exclusion via `LSM_FLAG_EXCLUSIVE`; stacking in progress
- **[[linux-audit]]** — AppArmor logs denials and complain-mode events through the kernel audit interface
- **[[capabilities]]** — profile capability rules are checked alongside the kernel's capability system; both must permit the operation
