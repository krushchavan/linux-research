---
title: "Landlock"
category: concept
tags: [security, landlock, sandboxing, lsm, unprivileged]
subsystem: security
kernel_version: "5.13"
researched: 2026-04-15
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/security/landlock.html
  - https://lwn.net/Articles/698226/
---

# Landlock

## Overview

Landlock is a stackable LSM that allows unprivileged processes to self-impose access restrictions on filesystem paths and network ports. Unlike SELinux or AppArmor (which require root or a privileged policy manager to configure), any process can call the Landlock syscalls to voluntarily limit itself. It fills the gap between seccomp (which filters syscall numbers but not the objects they access) and MAC systems (which require privileged setup). Landlock was merged in Linux 5.13 (2021).

## How It Works

### Conceptual Difference from seccomp

seccomp answers "is this syscall allowed?" Landlock answers "is this object accessible to this syscall?" A Landlock sandbox might allow `read(2)` as a syscall while restricting it to specific files. seccomp cannot express that distinction without encoding path checks in BPF, which is error-prone and does not survive symlink traversal or bind-mount tricks. Landlock operates at the inode level — it tracks the actual filesystem object, not the path string.

### The Three-Step API

**Step 1: Create a ruleset**

```c
struct landlock_ruleset_attr attr = {
    .handled_access_fs = LANDLOCK_ACCESS_FS_READ_FILE |
                         LANDLOCK_ACCESS_FS_WRITE_FILE,
    .handled_access_net = LANDLOCK_ACCESS_NET_BIND_TCP,
};
int ruleset_fd = landlock_create_ruleset(&attr, sizeof(attr), 0);
```

The ruleset declares which access rights it will govern. Any right not listed in `handled_access_fs` is implicitly allowed — Landlock is an allowlist for the rights it handles, not a global deny-all.

**Step 2: Add rules**

```c
/* Allow read-write on /tmp */
struct landlock_path_beneath_attr rule = {
    .allowed_access = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE,
    .parent_fd = open("/tmp", O_PATH),
};
landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &rule, 0);
```

Rules are specified as a file descriptor to a directory (or specific file) plus the allowed operations. Using an fd rather than a path string means symlink traversal attacks are not possible — the fd refers to a specific inode, not a name.

**Step 3: Enforce**

```c
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);  /* required */
landlock_restrict_self(ruleset_fd, 0);
close(ruleset_fd);
```

`landlock_restrict_self()` commits the ruleset to the current task's credentials. From this point, the task's domain includes this ruleset. The ruleset fd is no longer needed.

### Domains and Stacking

When a ruleset is committed, it becomes a **domain** — an immutable, reference-counted ruleset associated with the task's credentials. Domains stack: a task inherits its parent's domains, and each `landlock_restrict_self()` call appends a new domain layer. An access is granted only when **at least one rule in each domain layer** allows it. A child process can only be more restricted than its parent, never less.

This stacking property is fundamental to safe delegation. A container manager can enforce a base domain; the container's init process can add further restrictions; individual services inside the container can add yet more. No process can escape a domain its ancestor imposed.

### Rule Lookup

Rules within a domain are organized in a **red-black tree** keyed on the underlying inode pointer (obtained from the fd at `landlock_add_rule()` time). When an LSM hook fires (e.g. `landlock_file_open()`), Landlock walks up the dentry chain from the target file to the filesystem root, checking at each directory level whether the inode appears in any rule in any active domain layer. This dentry-walk ensures that rules apply to all paths that lead to a given inode, not just the path used to obtain the fd.

### Access Rights

**Filesystem rights** (current as of v6.x):
- `LANDLOCK_ACCESS_FS_READ_FILE`, `WRITE_FILE`, `EXECUTE`
- `LANDLOCK_ACCESS_FS_READ_DIR` — list directory contents
- `LANDLOCK_ACCESS_FS_MAKE_REG`, `MAKE_DIR`, `MAKE_SYM`, `MAKE_SOCK`, etc.
- `LANDLOCK_ACCESS_FS_REMOVE_DIR`, `REMOVE_FILE`
- `LANDLOCK_ACCESS_FS_REFER` — cross-directory file renaming (v5.19)
- `LANDLOCK_ACCESS_FS_TRUNCATE` — `ftruncate(2)` / `open(O_TRUNC)` (v6.2)

**Network rights** (added v6.1):
- `LANDLOCK_ACCESS_NET_BIND_TCP` — `bind(2)` on TCP sockets
- `LANDLOCK_ACCESS_NET_CONNECT_TCP` — `connect(2)` on TCP sockets

### Current Limitations

- No IPC restrictions (pipes, shared memory, signals) — planned for future versions
- No restrictions on already-open file descriptors at enforcement time; the sandbox must close inherited fds before calling `restrict_self` if it wants to prevent their use
- Requires a minimum API version check; userspace must query `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)` to discover supported ABI version and avoid using rights unavailable on older kernels

## Key Data Structures

**`struct landlock_ruleset`** (`security/landlock/ruleset.h`)
- `root_inode` — `struct rb_root_cached` — red-black tree of inode rules
- `root_net_port` — `struct rb_root_cached` — red-black tree of port rules
- `hierarchy` — linked list node for domain stacking
- `access_masks` — which access rights are handled by this ruleset

**`struct landlock_inode_security`** (in inode LSM blob)
- pointer to the set of `landlock_rule` entries for this inode

## Key Functions

- `landlock_create_ruleset(2)` — new ruleset (returns fd)
- `landlock_add_rule(2)` — add rule to ruleset
- `landlock_restrict_self(2)` — commit ruleset to task credentials
- `landlock_file_open()` — LSM hook; checks domain layers against file inode

## Config & Flags

- `CONFIG_SECURITY_LANDLOCK` — enables Landlock (stackable; no `LSM_FLAG_EXCLUSIVE`)
- Must be listed in `CONFIG_LSM` or `lsm=` kernel parameter
- ABI versioning: query via `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)`

## Interactions

- **[[lsm-framework]]** — Landlock is a stackable LSM; explicitly designed to be loaded alongside SELinux or AppArmor
- **[[seccomp-bpf]]** — complementary: seccomp filters syscall numbers; Landlock restricts object access; both should be used together in a complete sandbox
- **[[capabilities]]** — `PR_SET_NO_NEW_PRIVS` is required before `landlock_restrict_self()`
- **[[credentials]]** — domains are stored in the LSM blob attached to `struct cred` and are copy-on-write across `fork()`
