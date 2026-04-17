---
title: "Process Security Model"
category: concept
tags: [security, process, credentials, capabilities, execve, fork, ptrace]
subsystem: security
kernel_version: "2.6.29"
researched: 2026-04-17
status: complete
sources:
  - https://www.kernel.org/doc/html/v4.15/security/credentials.html
  - https://www.kernel.org/doc/html/v5.3/userspace-api/no_new_privs.html
  - https://man7.org/linux/man-pages/man7/capabilities.7.html
  - https://lwn.net/Articles/251469/
  - https://lwn.net/Articles/211883/
  - https://lwn.net/Articles/280279/
  - https://lwn.net/Articles/636533/
  - https://www.kernel.org/doc/Documentation/prctl/no_new_privs.txt
---

# Process Security Model

## Purpose

The Linux process security model defines how a task's security attributes are established at creation, transformed during `execve()`, and used to govern inter-process operations like signal delivery and tracing. Without it, the kernel would have no principled way to reason about which process may influence another — privilege escalation, signal injection, and covert inspection would all be uncontrolled.

## Mental Model

Think of each process as carrying two security envelopes: a *real* envelope (who the process actually is, used when other processes act on it) and an *effective* envelope (what the process may do when it acts on others). `fork()` hands the child sealed copies of both. `execve()` reopens and reseals the effective envelope according to rules encoded in the binary's file metadata. Every inter-process operation — `kill()`, `ptrace()`, `/proc` reads — checks one or both envelopes against each other.

## How It Works

### Dual-Credential Architecture

Every task holds two pointers in `task_struct`:

```c
struct task_struct {
    const struct cred  *real_cred;   /* who we really are (objective) */
    const struct cred  *cred;        /* what we may do (subjective) */
    ...
};
```

`real_cred` is the *objective context* — the identity that other processes check when they want to act on this task (e.g., signal delivery looks at `tcred->uid`). `cred` is the *subjective context* — what the kernel uses when *this* task initiates an operation on something else (file opens, socket binds, capability checks). In practice both pointers are usually identical; they diverge only during credential transitions and for special kernel services that temporarily operate under elevated credentials via `override_creds()`.

Both pointers are RCU-protected. To read another task's credentials, a caller must hold the RCU read lock and use `rcu_dereference(__task_cred(t))`; to read its own, it calls `current_cred()` locklessly. The immutability-after-commit guarantee (see [[credentials]]) ensures a reader under RCU never sees a partially updated credential.

### fork(): Sealed Copies

`copy_process()` calls `copy_creds()`, which calls `get_cred()` on the parent's cred and assigns it to both `real_cred` and `cred` in the child. The child starts with an incremented reference count on the *exact same* `struct cred` — no copying occurs unless the child later modifies its credentials. All five capability sets (permitted, inheritable, effective, bounding, ambient), all UID/GID fields, securebits, keyrings, and the LSM blob are inherited verbatim.

The `dumpable` flag (`MM_FLAGS_DUMPABLE` in `mm->flags`) is also inherited, subject to the rule that it resets to `suid_dumpable` (a sysctl, default 0) whenever privilege is gained.

### execve(): The Credential Transformation Pipeline

`execve()` is the point where credentials change most dramatically. The kernel separates the transformation into a multi-stage pipeline to allow LSMs and binary loaders to participate atomically:

**Stage 1 — Prepare.** `prepare_bprm_creds()` allocates a fresh `struct cred` via `prepare_creds()` and attaches it to `linux_binprm.cred`. This in-flight credential is the sandbox where all exec-time decisions are accumulated before any take effect.

```c
struct linux_binprm {
    struct cred *cred;        /* new creds being built */
    int unsafe;               /* PTRACE_UNSAFE_* flags */
    unsigned int per_clear;   /* personality bits to clear */
    ...
};
```

**Stage 2 — Identity adjustment.** If the binary has the setuid bit, `prepare_binprm()` copies the file's owner UID into `bprm->cred->euid`. If the setgid bit is set, the file's owner GID goes into `bprm->cred->egid`. Both operations check for the `no_new_privs` bit and for mounted `nosuid` — either blocks the adjustment.

**Stage 3 — File capability transformation.** `get_file_caps()` reads the `security.capability` xattr from the binary. The kernel then applies the POSIX-like transformation:

```
P'(ambient)     = (file is privileged) ? 0 : P(ambient)
P'(permitted)   = (P(inheritable) & F(inheritable))
                | (F(permitted) & P(bounding))
                | P'(ambient)
P'(effective)   = F(effective) ? P'(permitted) : P'(ambient)
P'(inheritable) = P(inheritable)    [unchanged]
P'(bounding)    = P(bounding)       [unchanged]
```

Where `P` is the thread's pre-exec sets, `P'` is post-exec, and `F` is the file's capability sets. The critical insight is that `F(permitted)` is masked by `P(bounding)`, so a process can never gain a capability that is not in its bounding set just by executing a file-capped binary — even root is bound by this rule when `SECURE_NOROOT` is set.

If the file has either setuid/setgid bits *or* file capabilities, it is considered "privileged" and the ambient set is cleared for the new process. This prevents ambient capabilities from leaking across a privilege boundary.

**Stage 4 — Ambient capabilities (Linux 4.3+).** Ambient capabilities (`cap_ambient`) solve the inheritance problem that plagued unprivileged service launching. Before Linux 4.3, if a non-root process had a capability in `cap_permitted` and `cap_inheritable` and executed a binary with that capability in `F(inheritable)`, the child still could not gain it in `P'(effective)` unless `F(effective)` was set. This meant every binary that needed even one capability had to be explicitly annotated — impossible for scripts and dynamically-typed programs.

The ambient set is a fifth mask that passes through `execve()` automatically for non-privileged binaries: `P'(ambient) = P(ambient)` when the file is not privileged. Ambient caps are added directly to both `P'(permitted)` and `P'(effective)`, bypassing the file-capability lookup entirely. The invariant `cap_ambient ⊆ cap_permitted ∩ cap_inheritable` is maintained by the kernel; dropping a cap from either `permitted` or `inheritable` automatically drops it from `ambient` as well.

**Stage 5 — LSM hooks.** LSMs participate via `security_bprm_set_creds()` (called after the binary loader processes setuid/caps, before execution starts) and `security_bprm_check()` (final go/no-go). SELinux uses `bprm_set_creds` to compute the post-exec domain based on the source domain, the binary's file security label, and the transition rules in policy. If a domain transition is required, the LSM stores the new SID in `bprm->cred->security` at this stage.

**Stage 6 — Commit.** `commit_bprm_creds()` calls `commit_creds(bprm->cred)`, atomically swapping the task's `cred` pointer via RCU. The previous credential is released. At this point the new identity is live and the process runs under its new credential.

The `dumpable` flag is reset to `suid_dumpable` whenever any privilege elevation occurred — whether via setuid, setgid, or file capabilities. This is a security backstop: a newly-elevated process cannot be read through `/proc` or traced via ptrace until it explicitly re-enables dumpability.

### no_new_privs (Linux 3.5+)

`prctl(PR_SET_NO_NEW_PRIVS, 1)` sets a flag in `task_struct` that is inherited across `fork()`, `clone()`, and `execve()` and can never be cleared. Its effect is simple but powerful: it cuts the Stage 2 and Stage 3 paths short.

When `no_new_privs` is set:
- The setuid and setgid bits on an exec'd binary are ignored — UIDs and GIDs do not change.
- File capabilities on the binary are not added to `P'(permitted)` (the `F(permitted) & P(bounding)` term becomes zero).
- The binary executes with whatever capabilities the *current* thread already holds — it cannot gain more.
- LSM transitions that would grant new privileges are blocked.

`no_new_privs` is the prerequisite for unprivileged seccomp filter installation (`SECCOMP_MODE_FILTER`): a filter installed by an unprivileged process could restrict future exec'd setuid binaries, which would be a denial-of-service against them — `no_new_privs` makes this safe because setuid binaries won't gain privilege in the first place.

### Signal Delivery: kill Permission

When a process calls `kill(pid, sig)`, the kernel's `check_kill_permission()` (in `kernel/signal.c`) runs three checks in sequence:

1. **Namespace membership** — the target must be visible to the sender (in the same PID namespace tree).
2. **Credential match via `kill_ok_by_cred()`** — the check passes if:
   - `sender->euid == target->suid || sender->euid == target->uid`, *or*
   - `sender->uid  == target->suid || sender->uid  == target->uid`
   
   These comparisons use the *real* UID of the target (`real_cred->uid`) as its objective context, and the *effective* UID of the sender (`cred->euid`) as the subjective context. The "saved set-UID" check allows a process that has temporarily dropped privileges (e.g., a setuid binary that called `seteuid(0)` then `seteuid(original)`) to still be signalled by its original owner.
   
3. **CAP_KILL** — if the credential check fails, `ns_capable(tcred->user_ns, CAP_KILL)` grants permission if the sender holds CAP_KILL in the target's user namespace.
4. **LSM check** — `security_task_kill()` gives SELinux, Smack, and other LSMs a veto based on policy labels.

`SIGCONT` bypasses step 2 when sender and target share the same session — a design inherited from POSIX job control.

### ptrace: Process Inspection Access Control

`ptrace()` is the most powerful inter-process interface; it can read/write arbitrary memory, registers, and signal state. Access control is gated by `ptrace_may_access(target, mode)`:

- **Dumpability check**: if `target->mm->dumpable == 0` (non-dumpable), access in `PTRACE_MODE_ATTACH` is denied unless the caller holds `CAP_SYS_PTRACE`. A process becomes non-dumpable after exec'ing a setuid binary or after `prctl(PR_SET_DUMPABLE, 0)`. This is what prevents `gdb` from attaching to suid binaries.
- **Credential check**: in `PTRACE_MODE_ATTACH`, the caller's euid and uid must match the target's uid/suid (like signal delivery), or the caller must hold `CAP_SYS_PTRACE` in the target's user namespace.
- **PTRACE_MODE_READ vs PTRACE_MODE_ATTACH**: read-only checks (e.g., reading `/proc/<pid>/mem`) are slightly less restrictive but still gate on dumpability and LSM checks.
- **no_new_privs ptrace safety**: `bprm->unsafe` is set to `LSM_UNSAFE_PTRACE` when a traced process execs. LSMs check this flag in `bprm_set_creds` and may block a privileged exec (e.g., SELinux blocks domain transitions when the tracer could intercept privileged operations).
- **LSM veto**: `security_ptrace_access_check()` gives Yama and other LSMs a final veto. Yama's `ptrace_scope` sysctl can restrict all ptrace to the direct parent or require CAP_SYS_PTRACE globally.

### /proc Visibility and Dumpability

`dumpable` controls more than core dumps. `/proc/<pid>/mem`, `/proc/<pid>/maps`, and related files check dumpability before granting access. The `proc_pid_permission()` function enforces this: if the target is not dumpable and the caller does not hold `CAP_SYS_PTRACE`, access is denied.

The three dumpable states are:
- `0` — SUID_DUMP_DISABLE: no core, no /proc access
- `1` — SUID_DUMP_USER: core dump enabled, /proc accessible to owner
- `2` — SUID_DUMP_ROOT: core dump to root-only location, /proc accessible (controlled by `fs.suid_dumpable` sysctl)

## Key Data Structures

**`struct linux_binprm`** (`include/linux/binfmts.h`) — the per-exec workspace carrying the new credential under construction, the binary's file, the privilege-related `unsafe` flags, and the `mm` being set up.
- `cred` — in-flight credential; committed or aborted atomically
- `unsafe` — `LSM_UNSAFE_SHARE` / `LSM_UNSAFE_PTRACE` flags set when exec occurs under shared file tables or while being traced

**`struct task_struct`** (relevant fields, `include/linux/sched.h`)
- `real_cred` — objective identity, RCU-protected
- `cred` — subjective identity, RCU-protected
- `no_new_privs:1` — the no_new_privs bit, packed in task flags

For `struct cred` internals (all UID/GID/cap/securebits fields), see [[credentials]].

## Key Functions / Entry Points

**`copy_creds()`** (`kernel/cred.c`) — called by `copy_process()` during `fork()`; increments refcount on parent's cred and assigns it to child.

**`prepare_bprm_creds()`** (`fs/exec.c`) — allocates a fresh `struct cred` for `bprm->cred` at the start of exec.

**`prepare_binprm()`** (`fs/exec.c`) — applies setuid/setgid bit to `bprm->cred`.

**`get_file_caps()`** (`security/commoncap.c`) — reads `security.capability` xattr and applies the file capability transformation formula to `bprm->cred`.

**`cap_bprm_set_creds()`** (`security/commoncap.c`) — the capabilities LSM's `bprm_set_creds` hook; applies inheritable/bounding/ambient logic.

**`commit_bprm_creds()`** (`fs/exec.c`) — calls `commit_creds(bprm->cred)`, making the new credential live.

**`check_kill_permission()`** (`kernel/signal.c`) — namespace + credential + capability + LSM gating for signal delivery.

**`kill_ok_by_cred()`** (`kernel/signal.c`) — the UID-match predicate for signal permission.

**`ptrace_may_access()`** (`kernel/ptrace.c`) — combined dumpability + credential + LSM access check for ptrace.

**`__ptrace_may_access()`** (`kernel/ptrace.c`) — core logic; checks `PTRACE_MODE_ATTACH` vs `PTRACE_MODE_READ` path differences.

## Important Flags & Config Options

**`fs.suid_dumpable`** (sysctl) — controls default dumpability after privilege change. `0` = non-dumpable (default), `1` = dumpable (insecure), `2` = dumpable but core goes to a root-owned directory.

**`kernel.yama.ptrace_scope`** (sysctl, requires `CONFIG_SECURITY_YAMA`) — restricts ptrace: `0` = classic, `1` = restricted (parent only or CAP_SYS_PTRACE), `2` = CAP_SYS_PTRACE required, `3` = no attach at all.

**`CONFIG_SECURITY_YAMA`** — enables the Yama LSM which adds `ptrace_scope` and ancestor checks.

**`CONFIG_SECURITY_FILE_CAPABILITIES`** — enables file capability xattr support; built-in since 2.6.33.

**`prctl(PR_SET_NO_NEW_PRIVS, 1)`** — set no_new_privs; inherited, irrevocable.

**`prctl(PR_SET_DUMPABLE, 0|1|2)`** — explicitly control dumpability.

**`prctl(PR_SET_SECUREBITS, bits)`** — set securebits (requires `CAP_SETPCAP`); controls NOROOT, NO_SETUID_FIXUP, KEEP_CAPS.

## Interactions with Other Subsystems

- **↑ Userspace**: `execve()`, `fork()`, `prctl()`, `kill()`, `ptrace()` are the primary entry points; userspace can read credential state via `/proc/self/status` (UID/GID/caps) and `/proc/self/attr/current` (LSM label).
- **→ [[credentials]]**: the process model orchestrates the cred lifecycle; `struct cred` is the data structure, the process model defines when and how it changes.
- **→ [[capabilities]]**: capability set transformation during exec is the most complex part of the process model; the bounding set, ambient set, and file caps interact in the transformation formula.
- **→ [[lsm-framework]]**: LSM hooks at `bprm_set_creds`, `bprm_check_security`, `task_kill`, and `ptrace_access_check` integrate mandatory policy into the process model.
- **→ [[seccomp-bpf]]**: `no_new_privs` is the prerequisite for unprivileged seccomp filter installation; seccomp filters are checked before any credential logic on each syscall.
- **→ [[user-namespaces]]**: capability checks are namespace-relative (`ns_capable()`); a process can hold CAP_KILL in its own user namespace without having it in the init namespace.
- **← Scheduler**: the scheduler has no security semantics, but context switches set `current`, making `current_cred()` always return the right credential for the running task.

## Design Decisions & Tradeoffs

**Immutable-after-commit credentials.** The alternative — mutable credentials protected by a lock — would require locking on every capability check. Given that capability checks happen on nearly every sensitive operation, the RCU / copy-on-write approach was chosen to make reads lockless at the cost of an allocation and copy on every credential change. Credential changes are rare compared to reads.

**Dual cred pointers (real_cred / cred).** This was introduced to support the case where a kernel service needs to perform operations under its own credentials while the task is in the middle of a credential transition. Previously, overriding credentials in `task_struct.cred` was unsafe because ptrace and other code read the same field. The split makes it possible to override the subjective cred via `override_creds()` without interfering with the task's objective identity.

**Ambient capabilities tradeoff.** The ambient set makes it easy for a launcher to grant a non-root child process capabilities without file-capping every binary. The invariant `ambient ⊆ permitted ∩ inheritable` is enforced in-kernel. The price is complexity: there are now five interacting sets instead of four, and the transformation formula requires careful reading to predict what a child will inherit.

**no_new_privs as an escape valve.** The `no_new_privs` flag allows unprivileged users to install seccomp filters and run sandboxed code without requiring kernel changes for each new sandboxing strategy. The key insight is that once a process declares it cannot gain new privileges, the kernel can safely allow it to alter its own execution environment (install strict filters, drop to a chroot, exec restricted binaries) without opening privilege escalation paths.

**Dumpability as ptrace proxy.** Rather than duplicating ptrace access control logic inside `/proc`, the kernel reuses `dumpable` as a unified flag. This means any privilege gain automatically restricts `/proc` visibility — a defensive default that closed a class of information leaks from setuid programs before formal LSM-based `/proc` access control was added.

## How It Has Evolved

- **2.6.26**: Securebits moved from a global variable to per-process `task_struct` flags, enabling container-safe capability restriction.
- **2.6.29**: `struct cred` introduced, separating credentials from `task_struct`. Prior to this, UIDs, GIDs, and capabilities were scattered across `task_struct` fields and protected by a per-task lock; a task modifying another's credentials was permitted. The new model prohibits cross-task cred modification entirely.
- **2.6.33**: `CONFIG_SECURITY_FILE_CAPABILITIES` removed (file caps always compiled in); simplifies the capability model by eliminating a build-time branch.
- **3.5**: `no_new_privs` added (`prctl(PR_SET_NO_NEW_PRIVS)`), providing a clean interface for sandboxing tools.
- **4.3**: Ambient capabilities added (`cap_ambient`), solving the non-root capability inheritance problem that made practical least-privilege deployment difficult.
- **5.1**: LSM stacking infrastructure reworked; credential security blobs become offset-based so multiple LSMs can coexist with their own per-cred storage.

## Further Reading

- [Credentials in Linux (kernel.org)](https://www.kernel.org/doc/html/v4.15/security/credentials.html) — canonical documentation for `struct cred`, lifecycle, and access rules
- [Credential records — LWN.net](https://lwn.net/Articles/251469/) — David Howells' original proposal separating credentials from task_struct
- [File-based capabilities — LWN.net](https://lwn.net/Articles/211883/) — explains file capability xattr format and the privilege escalation model
- [Restricting root with per-process securebits — LWN.net](https://lwn.net/Articles/280279/) — per-process NOROOT, NO_SETUID_FIXUP design rationale
- [Ambient capabilities — LWN.net](https://lwn.net/Articles/636533/) — Andy Lutomirski's RFC; explains why four sets weren't enough
- [No New Privileges Flag (kernel.org)](https://www.kernel.org/doc/html/v5.3/userspace-api/no_new_privs.html) — official documentation for the no_new_privs bit
- [capabilities(7) man page](https://man7.org/linux/man-pages/man7/capabilities.7.html) — complete execve transformation formulas and per-set semantics

## LKML Highlights

- **`[PATCH] Add credentials [2008]`** (David Howells) — the series that introduced `struct cred` and the `prepare_creds()` / `commit_creds()` API. The cover letter explains why cross-task credential modification was problematic and what the copy-on-write model achieves. Message-id: `20080212164755.GJ4762@agnus.demon.co.uk`.
- **`[RFC] Ambient capabilities`** (Andy Lutomirski, 2015) — demonstrated the inheritance failure with a simple example (`sh -c 'cap_net_bind_service+ip $1'` fails for non-root) and introduced the fifth capability set. The thread has good discussion on invariant enforcement. Message-id: `20150312181825.GE26739@altlinux.org`.
