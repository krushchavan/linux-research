---
title: "LSM Framework — Explained"
category: explained
original: "[[lsm-framework]]"
subsystem: security
tags: [explained, security, lsm, hooks, stacking]
converted: 2026-09-25
---

# The LSM framework, explained

> Plain-language companion to [[lsm-framework|the technical note]]. Same facts, fewer identifiers.

## The problem

Different users want very different security policies: labels everywhere (SELinux), per-program path profiles (AppArmor), self-imposed sandboxes (Landlock). Building each directly into the filesystem, networking and IPC code would tangle every policy into the core kernel and make adding a new one a huge patch. And several policies may need to be active at once, each with private data attached to the same kernel objects.

## The idea in one paragraph

Put small **hooks** at every security-sensitive decision point in the kernel (opening a file, creating a socket, changing credentials), and let security modules **attach callbacks** to them. The core code calls the hook and trusts the answer without knowing which modules are listening. Each hook keeps its own list of callbacks, so a module only runs where it registered. Merged in 2.6.0 (2003), the framework now covers hundreds of hook sites.

## Step by step

### Step 1: The core calls a hook
When a process opens a file, the filesystem code calls the "inode permission" hook. That thin wrapper walks the list of callbacks registered for *that* hook and returns the first denial. The filesystem has no idea which modules are active; it asks and obeys.

### Step 2: Modules register at boot
The kernel configuration (overridable on the command line) gives an ordered list of modules, for example lockdown, yama, loadpin, selinux. At boot the framework initialises each in turn, and each appends its callbacks to the relevant hook lists, so callbacks run in that configured order. The capabilities module is always loaded and uses the same framework. Hooks can't be changed after boot; an old option that allowed runtime changes is deprecated.

### Step 3: Two kinds of hooks
- **Management hooks** allocate or free security state as objects are created and destroyed (for example when credentials are prepared). Every module's callback runs; a failure in any aborts the operation.
- **Access-control hooks** make allow/deny decisions. The first denial stops the chain.

A few hooks merge results from all modules instead, such as combining several modules' labels for an inode into one string.

### Step 4: Private data in shared blobs
This is the key step for stacking. Modules need private state attached to objects: SELinux stores a security ID per inode, AppArmor a profile per task. Originally each object had a **single** opaque pointer for security data, and two modules would fight over it. Since 5.1 the framework manages the data itself: each module declares how many bytes it needs per object type (credentials, files, inodes, tasks, sockets, superblocks, IPC), the framework allocates **one combined blob**, and each module gets a fixed offset into it. Allocation and freeing are handled uniformly for everyone.

### Step 5: Toward stacking the big modules
SELinux, AppArmor and Smack were each marked **exclusive**, because each assumed it owned the whole security pointer. With shared blobs that's no longer needed for most object types, and the exclusive flag is being removed step by step so these major modules can eventually run together. Landlock was designed to stack from the start.

## The picture

```text
 open("/etc/shadow")
    └─ filesystem ─▶ "inode permission" hook
                        list for this hook (boot order):
                        capabilities ─▶ SELinux ─▶ Landlock
                        first denial wins ──▶ EACCES

 inode's security blob:  [ SELinux: security ID | Landlock: rules ptr | … ]
                          each module reads at its own fixed offset
```

## Tradeoffs

- **What it gives you:** policies developed independently of the core kernel; several modules active at once; uniform handling of per-object security data.
- **What it costs / requires:** a hook call on every security-sensitive operation, and a walk of each hook's callback list.
- **Where it bites:** those callback lists are **indirect function calls**, the target of Spectre v2 branch-history attacks. In 2024 Linus proposed static, single-module dispatch fixed at build time; the security-module maintainers proposed static calls, which patch indirect calls into direct ones at boot, to keep stacking without the speculative-execution risk. The debate is ongoing.

## How it got here

- **2.6.0 (2003):** the framework merged.
- **Later:** a single global table of hook pointers gave way to per-hook lists so several modules could register.
- **5.1 (2019):** framework-managed blobs, removing the main barrier to stacking.
- **2024:** the indirect-call debate over how stacked hooks should be dispatched.

## Related

- Technical version: [[lsm-framework]]
- [[security-explained|Security subsystem]], [[selinux-explained|SELinux]], [[apparmor-explained|AppArmor]], [[smack-explained|Smack]], [[landlock-explained|Landlock]], [[capabilities-explained|Capabilities]], [[credentials-explained|Credentials]], [[linux-audit-explained|Audit]]
