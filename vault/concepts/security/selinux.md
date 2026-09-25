---
title: "SELinux"
category: concept
tags: [security, selinux, mac, type-enforcement, lsm]
subsystem: security
kernel_version: "2.6.0"
researched: 2026-04-15
status: complete
explained: "[[selinux-explained]]"
sources:
  - https://kernel-internals.org/security/selinux/
  - https://www.kernel.org/doc/html/latest/security/lsm.html
---

# SELinux

> 📘 Plain-language version: [[selinux-explained]]

## Overview

SELinux (Security-Enhanced Linux) implements Mandatory Access Control (MAC) — a system-wide policy governs every access decision, and even a root-privileged process is constrained to the operations its security context permits. It was originally developed by the NSA and contributed to the kernel in Linux 2.6.0 (2003), making it the oldest and most widely deployed major LSM. Red Hat Enterprise Linux, Fedora, and Android use SELinux as their default MAC system.

## How It Works

The core insight of SELinux is that traditional Unix permissions decide based on *who* the requester is (uid, gid). SELinux instead decides based on *what type of process* is making the request and *what type of object* it is accessing. This type enforcement is independent of ownership.

### Security Contexts and Types

Every subject (process) and every object (file, socket, IPC object, port) carries a security context: a four-part label `user:role:type:level`. The type component is the primary currency. A web server process might have type `httpd_t`; the files it serves might have type `httpd_content_t`. The policy contains explicit allow rules:

```
allow httpd_t httpd_content_t:file { read open getattr };
```

There is no catch-all "allow" — the default is deny. Every permission not covered by an explicit allow rule is blocked, regardless of the process's uid or capabilities.

### Policy Enforcement Path

When `selinux_inode_permission()` fires (via the LSM hook on every file permission check), the sequence is:

1. Retrieve the process's **Security ID (SID)** — a small integer that is the in-kernel representation of its security context. The SID is stored in `task_struct`'s LSM blob and computed from the context string during task creation or context change.
2. Retrieve the inode's SID (stored in `inode->i_security`'s LSM blob, set when the inode is read from disk or created).
3. Query the **Access Vector Cache (AVC)** with the tuple `(source SID, target SID, object class, requested permissions)`.

```c
static int selinux_inode_permission(struct inode *inode, int mask)
{
    const struct cred *cred = current_cred();
    u32 sid = cred_sid(cred);
    struct inode_security_struct *isec = inode->i_security;

    return avc_has_perm(sid, isec->sid, isec->sclass,
                        file_mask_to_av(mask), &ad);
}
```

### Access Vector Cache (AVC)

The AVC is a hash table mapping `(ssid, tsid, tclass)` tuples to cached `struct av_decision` entries. An `av_decision` contains two bitmasks: `allowed` (which permissions are permitted) and `auditallow` (which permitted operations should also be logged). On a **cache hit** (typically ~97% of accesses), the check is a hash lookup and a bitmask test — extremely cheap. On a **cache miss**, the AVC calls into the policy decision engine, which traverses the in-kernel policy database, inserts the result into the AVC, and returns. The AVC is flushed when the policy is reloaded (via `semanage` or `load_policy`).

### Security Context Labelling

Files get their contexts from:
1. The filesystem's extended attribute `security.selinux` (set by `restorecon` or `chcon`)
2. Policy `file_contexts` mappings applied during filesystem labelling
3. Type transitions: when `httpd_t` creates a file in a `httpd_var_run_t` directory, a transition rule can automatically label the new file `httpd_var_run_t`

Network sockets are labelled by the creating process's context. Network packets can carry labels via NetLabel (CIPSO IPv4 or CALIPSO IPv6 extensions), enabling label-based filtering at the network layer.

### Multi-Level Security (MLS)

The `level` field in a context (e.g. `s0:c0,c15` or `Secret:Confidential`) supports Bell-LaPadula confidentiality: a process at sensitivity `s0` cannot read files labelled `s1`, even with type-compatible labels. MLS is used in high-assurance environments (government, defence); most commercial deployments use the simpler targeted policy that sets all levels to `s0`.

### SELinux Modes

- **Enforcing** — policy violations are denied and logged to the audit subsystem
- **Permissive** — violations are logged but not denied (used for policy development with `audit2allow`)
- **Disabled** — completely inactive; requires reboot to re-enable

The mode can be toggled between Enforcing and Permissive at runtime via `/sys/fs/selinux/enforce`. Switching to Disabled requires a reboot and kernel parameter `selinux=0`.

### Audit Integration

Every denial triggers an `avc: denied` audit record containing the source context, target context, object class, and denied permissions. The `audit2allow` tool analyses these records and generates `allow` rules. This workflow — run in permissive mode, collect denials, generate policy — is the standard approach for writing SELinux policy for a new application.

## Key Data Structures

**`struct task_security_struct`** (in LSM blob off `task_struct`)
- `sid` — current security ID
- `exec_sid` — SID to transition to on next `execve()`
- `create_sid` — SID for newly created files

**`struct inode_security_struct`** (in LSM blob off `inode`)
- `sid` — security ID of the object
- `sclass` — security class (SECCLASS_FILE, SECCLASS_SOCKET, etc.)
- `initialized` — whether the label has been loaded from xattr

**`struct avc_entry`** (internal to `security/selinux/avc.c`)
- `ssid`, `tsid`, `tclass` — the cache key
- `avd` — `struct av_decision` with `allowed` and `auditallow` bitmasks

## Key Functions

- `avc_has_perm(ssid, tsid, tclass, requested, auditdata)` — AVC lookup; main enforcement path
- `security_sid_to_context(sid, ctx, len)` — SID → human-readable label string
- `security_context_to_sid(ctx, len, sid)` — label string → SID
- `sel_write_enforce()` — `/selinuxfs/enforce` write handler
- `selinux_inode_permission()` — file access control hook
- `selinux_socket_connect()` — network access control hook

## Config & Flags

- `CONFIG_SECURITY_SELINUX`
- `CONFIG_SECURITY_SELINUX_BOOTPARAM` — allows `selinux=0` kernel parameter
- `selinux=0` — disable at boot
- `enforcing=0` — start in permissive mode
- `/etc/selinux/config` — `SELINUX=enforcing|permissive|disabled` and `SELINUXTYPE=targeted|mls`

## Interactions

- **[[lsm-framework]]** — SELinux is an LSM; all its enforcement is done via LSM hook registrations
- **[[linux-audit]]** — AVC denials are the primary source of audit records in SELinux-enabled systems
- **[[credentials]]** — task security context is stored in the LSM blob attached to `struct cred`; context transitions happen via `commit_creds()`
- **[[apparmor]]** — both are major LSMs; they cannot currently stack due to `LSM_FLAG_EXCLUSIVE`, but stacking work is ongoing
