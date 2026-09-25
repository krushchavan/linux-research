---
title: "LSM Framework"
category: concept
tags: [security, lsm, hooks, mac, module-stacking]
subsystem: security
kernel_version: "2.6.0"
researched: 2026-04-15
status: complete
explained: "[[lsm-framework-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/security/lsm.html
  - https://www.kernel.org/doc/html/latest/security/lsm-development.html
  - https://lwn.net/Articles/804906/
  - https://lwn.net/Articles/970070/
---

# LSM Framework

> 📘 Plain-language version: [[lsm-framework-explained]]

## Overview

The Linux Security Module (LSM) framework is the extensibility backbone of the kernel's security subsystem. It inserts lightweight call sites — hooks — at every security-sensitive kernel decision point, allowing independently developed security modules (SELinux, AppArmor, Landlock, etc.) to attach their own enforcement logic without modifying core VFS, networking, or IPC code. The framework was merged in Linux 2.6.0 (2003) and has grown to cover hundreds of hook sites across the kernel.

## How It Works

The story starts with a security-sensitive operation. When a process attempts to open a file, the VFS calls `security_inode_permission(inode, mask)` — a thin wrapper in `security/security.c`. Inside that wrapper, `call_int_hook(inode_permission, 0, inode, mask)` iterates a linked list of registered handlers and returns the first non-zero (denial) result. The important property: the VFS has no idea which security modules are active. It just calls the hook and trusts the answer.

Each active LSM registers its hooks during boot via `security_add_hooks()`:

```c
void security_add_hooks(struct security_hook_list *hooks, int count,
                        const struct lsm_info *lsm)
{
    for (int i = 0; i < count; i++)
        hlist_add_tail_rcu(&hooks[i].list,
                           hooks[i].head);   /* head → global hook list */
}
```

The `head` pointer in each `security_hook_list` element points to the right `struct hlist_head` inside the global `security_hook_heads` structure — one head per hook name. Iteration thus hits only the handlers registered for that specific hook, not all hooks of all modules.

Module loading order is determined by `CONFIG_LSM`, a comma-separated string (e.g. `"lockdown,yama,loadpin,selinux"`) parsed at boot. The LSM core walks the string, finds each named `struct lsm_info` in the linker-populated `__start_lsm_info` array, and calls its `init()` function in order. Hooks are appended to the lists as each module initialises, so the list order matches `CONFIG_LSM` order.

### Security Blobs

LSMs frequently need per-object private state: SELinux needs to store a security ID (SID) alongside every inode; AppArmor needs a profile pointer per task. Early LSM design put a single `void *security` opaque pointer into structures like `struct inode`, `struct task_struct`, and `struct cred`. This worked for one module but broke stacking — two modules would fight over the single pointer.

The v5.1 solution was **infrastructure-managed blobs**. Each LSM declares its storage requirements at registration:

```c
struct lsm_blob_sizes {
    int lbs_cred;        /* bytes needed in struct cred */
    int lbs_file;        /* bytes needed in struct file */
    int lbs_inode;       /* bytes needed in struct inode */
    int lbs_task;        /* bytes needed in struct task_struct */
    int lbs_sock;        /* bytes needed in struct sock */
    int lbs_superblock;
    int lbs_ipc;
    int lbs_msg_msg;
    int lbs_xattr_count;
};
```

The LSM core sums all requests, allocates a single combined blob, and gives each module a fixed byte offset into it. The module accesses its private data via a helper like `selinux_cred(cred)` that does `cred->security + selinux_blob_sizes.lbs_cred`. This removes any per-LSM allocation and deallocation — the framework handles it uniformly during object lifecycle.

### Module Stacking and the Exclusivity Problem

The `LSM_FLAG_EXCLUSIVE` flag marks a module as needing sole ownership of its blob type. SELinux, AppArmor, and Smack historically all set this flag because they each assumed they owned the entire `inode->security` pointer. Blob management made this unnecessary for most types; the exclusivity flag is being removed incrementally so these major modules can eventually stack.

As of 2024, Torvalds raised a concern: the per-hook linked lists require indirect function calls on every hook invocation, and indirect calls are the target of Spectre v2 branch-history injection attacks. He proposed static (compile-time) single-module dispatch instead. The LSM team countered with `static_call()` — a mechanism that patches indirect calls with direct calls at boot — as a way to preserve stacking without the Spectre surface. The debate is ongoing.

### Hook Types and Semantics

Hooks divide into two categories:

- **Management hooks** — called to allocate or free security state (e.g. `security_inode_alloc()`, `security_cred_prepare()`). All registered handlers are called; failure in any aborts the operation.
- **Access-control hooks** — called to make a permit/deny decision (e.g. `security_inode_permission()`). The first denial short-circuits the chain; `call_int_hook` returns immediately on the first non-zero return.

Some hooks aggregate results across all modules (e.g. `security_inode_getsecctx()` which must merge labels from multiple active modules into one string). These use `call_void_hook` or custom aggregation logic rather than the short-circuit pattern.

## Key Data Structures

**`struct security_hook_list`** (`include/linux/lsm_hooks.h`)
- `list` — `struct hlist_node` embedded in the per-hook hlist
- `head` — pointer to the global `struct hlist_head` for this hook
- `hook` — union of all possible function pointer signatures
- `lsm` — module name string

**`struct security_hook_heads`** (`security/security.c`, generated)
- one `struct hlist_head` per hook name
- the global root from which all per-hook lists hang

**`struct lsm_info`** (`include/linux/lsm_hooks.h`)
- `name` — matches the `CONFIG_LSM` token
- `flags` — `LSM_FLAG_EXCLUSIVE`, `LSM_FLAG_LEGACY_MINOR`
- `blobs` — `struct lsm_blob_sizes *`
- `init` — module init function

## Key Functions

- `security_add_hooks(hooks, count, lsm)` — registers a module's hook set during boot
- `call_int_hook(hook_name, default, ...)` — short-circuit iteration for access-control hooks
- `call_void_hook(hook_name, ...)` — full iteration for management hooks
- `lsm_early_cred(cred)` / `lsm_cred_blob(cred, offset)` — blob accessor helpers
- `security_inode_permission()` — canonical access-control hook example
- `security_cred_prepare()` — canonical management hook example

## Config & Flags

- `CONFIG_SECURITY` — enables the LSM framework (required for any LSM)
- `CONFIG_LSM` — compile-time default ordered list; overridable with `lsm=` kernel parameter
- `CONFIG_SECURITY_WRITABLE_HOOKS` — deprecated; allowed runtime hook modification
- `/sys/kernel/security/lsm` — reports active modules at runtime
- `lsm=` kernel command-line parameter — runtime override of `CONFIG_LSM`

## Interactions

- **[[selinux]]**, **[[apparmor]]**, **[[smack]]** — the three "major" LSMs; all register on the LSM hook lists
- **[[capabilities]]** — always loaded; the capabilities module uses the LSM framework even though capabilities are a POSIX standard mechanism
- **[[landlock]]** — stackable minor LSM; designed from the start to coexist
- **[[credentials]]** — credential lifecycle hooks (`security_cred_alloc_blank`, `security_prepare_creds`, `security_commit_creds`) are among the most critical LSM hooks
- **[[linux-audit]]** — many hook implementations call `audit_log_*()` to record access decisions
