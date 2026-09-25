---
title: "Linux Security Subsystem — Explained"
category: explained
original: "[[security]]"
subsystem: security
tags: [explained, security, lsm, capabilities, seccomp]
converted: 2026-09-25
---

# The Linux security subsystem, explained

> Plain-language companion to [[security|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Classic Unix security is all or nothing: a process is either root and can do anything, or it's limited to ordinary file permissions. That's too coarse in both directions. A web server that needs one privileged operation shouldn't get all of root's power. And once an attacker is running code as root, nothing else stands in the way. Meanwhile different organisations want different policy models (label-based, path-based, self-imposed sandboxes), and nobody wants to patch the core filesystem, networking and IPC code for each one.

What's needed is **defence in depth**: several independent layers, each limiting the damage of a compromise in a different way, plugged in without rewriting the kernel.

## The big picture

Think of **concentric gates** around every sensitive kernel operation, and a request must get through every gate it meets:
- **seccomp** filters at the system-call boundary, before a request is even processed
- **discretionary access control (DAC):** the usual user, group and permission-bit checks, always enforced
- **capabilities:** root's power split into about 40 separate privileges
- **security module hooks (LSM):** where SELinux, AppArmor, Smack or Landlock apply their own policy

Alongside sit **credentials** (who a task is), **audit** (a record of what happened), and **hardening** (making bugs harder to exploit).

```text
 process ──syscall──▶ seccomp filter ──✗──▶ kill / signal / error
                         │ allow
                         ▼
                      DAC (user/group/mode) ──✗──▶ EPERM
                         ▼
                      capability check ──✗──▶ EPERM
                         ▼
                      LSM hooks: SELinux/AppArmor/Smack → Landlock → capabilities ──✗──▶ EPERM
                         ▼
                      kernel operation ──▶ audit log
```

## The pieces

### The LSM framework
This is the extensibility backbone. At every security-relevant decision point (opening a file, creating a socket, forking), the kernel calls a **hook**. Each hook has a list of callbacks from the active security modules; the kernel runs them in order and stops at the first denial (a few hooks merge results instead). Modules register at boot, in an order set by the kernel configuration, and the lists are frozen afterwards; removing hooks at runtime is deliberately unsupported.

Modules need to attach private data to inodes, tasks, sockets and credentials. Since 5.1, instead of a separate pointer per module in every structure, the framework allocates **one combined blob** per object and gives each module a fixed slice of it. That's what makes **stacking** (several major modules active at once) possible for most object types; modules still marked "exclusive" can't stack yet. See [[lsm-framework-explained|LSM framework]].

### Capabilities
Capabilities break root into about 40 powers: binding to low ports, loading modules, bypassing file permissions, and so on. Each task has five capability sets:
- **permitted:** the ceiling of what it may use
- **effective:** what is actually checked; can be dropped and raised again within the permitted set
- **inheritable:** carried across program execution, but only if the program file also grants them
- **bounding:** a hard limit; once removed, never regained, even via setuid
- **ambient** (4.3): carried across execution unconditionally, for non-setuid helper programs that need a parent's powers

Executables can carry capabilities in an extended attribute, so they don't need to be setuid root. The notorious weak spot is the **system-administration capability**, which grew over 25 years to cover dozens of unrelated operations and is effectively a second root. A "no new privileges" flag stops any later program from gaining privileges through setuid or file capabilities. See [[capabilities-explained|capabilities]].

### seccomp
A process can **restrict its own system calls**. It installs a small BPF filter program that sees each call's number, architecture and arguments, and returns a verdict: kill the process or thread, send a signal, return an error, notify a tracer, log, or allow. Filters stack, all of them run, and the most severe verdict wins. Installing one needs either privilege or the "no new privileges" flag, so an unprivileged user can't filter a setuid program to confuse it. A newer verdict (5.0) hands the decision to a **user-space supervisor** over a file descriptor. Container runtimes and browsers depend on seccomp. See [[seccomp-bpf-explained|seccomp BPF]].

### SELinux
SELinux, developed by the NSA and merged in 2.6.0, is **mandatory access control by label**. Every process and object carries a security context, mainly a *type*, and a central policy lists what's allowed: "processes of the web-server type may read files of the web-content type". Anything not allowed is denied, even for root. Decisions are cached in the **access vector cache**, which hits about 97% of the time; misses go to the policy engine, and denials are sent to audit. Modes: enforcing, permissive (log only, for writing policy), and disabled (needs a reboot to undo). Its multi-level-security option adds clearance levels so that lower levels can't read higher ones. See [[selinux-explained|SELinux]].

### AppArmor
AppArmor does mandatory access control by **path**, with readable per-program profiles ("this browser may read the home directory, write to /tmp, use TCP"). A profile attaches when a matching program is executed, and a task can also switch profiles explicitly. It's the default on Ubuntu and Debian-based systems. It can't yet fully stack with SELinux, since both still need exclusive use of some object types. See [[apparmor-explained|AppArmor]].

### Landlock
Landlock lets **unprivileged** processes sandbox themselves. A process builds a ruleset (which file trees and, later, network ports it may use), then applies it to itself. Rulesets are immutable and stack: children inherit them and can only add restrictions. Unlike seccomp, Landlock restricts *objects*, not system calls: a read of an allowed file works, a read of a forbidden one fails. That suits programs that use many system calls but should touch only a few files. See [[landlock-explained|Landlock]].

### Credentials
Everything about a task's identity (user and group IDs, capability sets, security labels, keyrings, user namespace) lives in one **immutable, reference-counted credentials record**. To change it, the kernel copies the record, edits the copy, lets the security modules check it, then swaps it in atomically, freeing the old one after an RCU grace period. Readers always see a consistent snapshot without locking. Open files remember the **opener's** credentials, so a file opened with privilege and handed to less-privileged code is still judged by who opened it. See [[credentials-explained|credentials]].

### Kernel hardening
These aren't access controls but safety nets that make memory bugs harder to exploit:
- **address randomisation (KASLR):** the kernel loads at a random address, which is why kernel pointers are hidden from users
- **stack canaries:** a random value before the return address; corruption triggers a panic
- **SMEP and SMAP** (and PXN and PAN on Arm): the kernel faults if it executes, or unexpectedly touches, user memory
- **checked copies to and from user space**, and compile-time bounds checks on memory functions
- **control-flow integrity:** indirect calls must land on a function of the right type
- **Spectre and Meltdown defences:** separate kernel page tables, speculation-safe array indexing, retpolines

See [[kernel-hardening-explained|kernel hardening]].

### Audit
Audit is a tamper-resistant record of security-relevant events for compliance. Records come from system-call entry and exit and from explicit calls inside subsystems (for example, an SELinux denial with the exact labels involved). They flow over netlink to the audit daemon, which filters and writes them; sequence numbers expose any gaps. See [[linux-audit-explained|audit]].

## A request's journey

A sandboxed browser renderer opens a file in /tmp:

1. **System call.** The renderer calls open.
2. **seccomp.** The browser's filter allows open.
3. **DAC.** The file's permission bits allow the renderer's user and group.
4. **Capabilities.** None needed for an ordinary open.
5. **LSM hooks.** AppArmor checks the renderer's profile: /tmp is allowed.
6. **Landlock.** The renderer had sandboxed itself to read only under /tmp; this file qualifies. This is the key moment: several independent layers, each configured separately, all had to agree.
7. **Done.** The file descriptor is returned; no audit rule matches, so nothing is logged.

A denial runs the other way: a web server whose SELinux type isn't allowed to read the password shadow file is refused by the hook; the cache misses, the policy says no, an audit record naming both labels goes to the daemon, and the process gets "permission denied".

## Tradeoffs

- **What it gives you:** layered protection, where each layer shrinks the blast radius of a compromise differently; pluggable policy models without touching core code; self-sandboxing for unprivileged programs.
- **What it costs / requires:** labels (SELinux) survive renames and moves but are hard to author; paths (AppArmor) are readable but can be fooled by symlinks or broad wildcards. BPF filters are flexible, but a mistake can leave dangerous system calls reachable.
- **Where it bites:** stacking needs per-hook lists of **indirect calls**, exactly the kind of branch Spectre v2 attacks target. In 2024 Linus objected on those grounds; static calls have been proposed as a middle ground, but there's no consensus yet. io_uring's asynchronous operations also bypassed some hooks in early versions, which is being fixed.

## How it got here

- **2.2 (1999):** capabilities, a superset of the withdrawn POSIX.1e draft.
- **2.6.0 (2003):** the LSM framework, with SELinux as the first major module. The original single table of hook pointers was later replaced by per-hook lists to allow stacking.
- **2.6.12 (2005):** seccomp strict mode (only read, write, exit, sigreturn); **3.5 (2012):** BPF filters.
- **4.3 (2015):** ambient capabilities. **5.1 (2019):** framework-managed blobs (James Morris's series), the groundwork for stacking.
- **5.x:** Landlock (Mickaël Salaün), chosen over extending seccomp with path rules; its merge and user API are dated between 5.7 and 5.12, with network rules added later (dates vary by source). BPF security modules (5.7) let hooks be written in BPF, now used in production by projects like Tetragon and KubeArmor.
- **6.x:** stacking work continues through the 2024 indirect-call debate; Landlock is growing toward IPC and other object types, and confidential-computing integration is under way.

## Related

- Technical version: [[security]]
- [[lsm-framework-explained|LSM framework]], [[capabilities-explained|Capabilities]], [[seccomp-bpf-explained|seccomp]], [[selinux-explained|SELinux]], [[apparmor-explained|AppArmor]], [[landlock-explained|Landlock]], [[credentials-explained|Credentials]], [[kernel-hardening-explained|Kernel hardening]], [[linux-audit-explained|Audit]]
- [[smack|Smack]], [[user-namespaces|User namespaces]], [[process-model-explained|Process model]], [[netlabel-explained|NetLabel]]
- [[vfs-explained|VFS]], [[net-explained|Networking]], [[bpf-explained|BPF]], [[io_uring-explained|io_uring]], [[rcu-read-copy-update-explained|RCU]]
