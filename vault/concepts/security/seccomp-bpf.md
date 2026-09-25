---
title: "seccomp BPF"
category: concept
tags: [security, seccomp, bpf, syscall-filtering, sandboxing]
subsystem: security
kernel_version: "3.5"
researched: 2026-04-15
status: complete
explained: "[[seccomp-bpf-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html
  - https://lwn.net/Articles/443099/
  - https://lwn.net/Articles/488647/
---

# seccomp BPF

> 📘 Plain-language version: [[seccomp-bpf-explained]]

## Overview

seccomp (Secure Computing Mode) allows a process to restrict the set of system calls it may make. In BPF filter mode (merged v3.5, 2012), a process installs a classic BPF program that is evaluated on every syscall, returning an action code that determines whether the kernel should allow, deny, or handle the call specially. It is the primary sandboxing primitive used by browsers (Chrome, Firefox), container runtimes, and systemd's `SystemCallFilter`.

## How It Works

### Installation

A process installs a seccomp filter with:

```c
prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog);
/* or the newer dedicated syscall: */
seccomp(SECCOMP_SET_MODE_FILTER, flags, &prog);
```

`prog` is a `struct sock_fprog` — the same structure used for socket filters — containing a classic BPF bytecode array. Before installation, **the process must either**:
1. Hold `CAP_SYS_ADMIN` in its user namespace, or
2. Have previously called `prctl(PR_SET_NO_NEW_PRIVS, 1)`.

The `NO_NEW_PRIVS` requirement is critical: without it, a process could install a permissive filter and then `execve` a setuid binary. The child would inherit the filter but now have elevated uid, and the filter could allow dangerous syscalls under the assumption that the process is unprivileged.

### Filter Evaluation

On every syscall entry, the kernel calls `__secure_computing()` (inline hot path in `arch/x86/entry/common.c` and equivalents). This runs `seccomp_run_filters()`, which iterates the installed filter chain and evaluates each BPF program against a `struct seccomp_data` snapshot:

```c
struct seccomp_data {
    int     nr;              /* syscall number */
    __u32   arch;            /* AUDIT_ARCH_* constant */
    __u64   instruction_pointer;
    __u64   args[6];         /* syscall arguments (raw register values) */
};
```

The `arch` field is crucial: a 64-bit process calling a 32-bit syscall via `int 0x80` would have a different syscall number for the same logical operation. Filters must check `arch` before trusting `nr` to prevent bypassing the filter by using an alternative calling convention.

### Filter Chaining

Each `prctl` call prepends a new filter to a singly-linked list. All filters run for every syscall. The return value from each filter is 32 bits: the high 16 bits encode the action, the low 16 bits carry optional data (errno value, SIGSYS info, etc.). When multiple filters return conflicting actions, **the highest-precedence action wins** (precedence is defined in the action table below, not by filter position).

This design has an important property: a child process can only add more restrictive filters, never remove or relax existing ones. A sandbox can therefore install a base policy and let sandboxed code install additional refinements safely.

### Return Actions (in decreasing precedence)

| Action | Effect |
|--------|--------|
| `SECCOMP_RET_KILL_PROCESS` | Kill entire process group; no signal handler runs |
| `SECCOMP_RET_KILL_THREAD` | Kill calling thread |
| `SECCOMP_RET_TRAP` | Deliver `SIGSYS` to the process; syscall not executed |
| `SECCOMP_RET_ERRNO` | Return `-errno` to caller; low 16 bits = errno value |
| `SECCOMP_RET_USER_NOTIF` | Suspend; wake a supervisor process via fd (v5.0) |
| `SECCOMP_RET_TRACE` | Notify a `ptrace` tracer; blocks until tracer responds |
| `SECCOMP_RET_LOG` | Allow and log to audit; useful for policy development |
| `SECCOMP_RET_ALLOW` | Allow the syscall unconditionally |

### SECCOMP_RET_USER_NOTIF (v5.0)

This action delivers the syscall decision to a userspace supervisor process via a file descriptor obtained at filter installation. The supervisor reads a `struct seccomp_notif` (containing the blocked process's PID, pidfd, and the `seccomp_data` snapshot), makes a policy decision, and writes a `struct seccomp_notif_resp` back. The blocked process is then either allowed to proceed or returned an error.

User notification enables **seccomp-agent** patterns: a privileged daemon (e.g. a container manager) can handle specific privileged syscalls on behalf of a sandboxed process, injecting the result as if the kernel had processed the call. This allows unprivileged containers to perform operations like `mount(2)` that the kernel would otherwise deny, because the container manager intercepts the call, does the work with its own privileges, and returns success.

### BPF JIT

Classic BPF programs used by seccomp are JIT-compiled on capable architectures (x86-64, arm64, etc.). The JIT output is cached per filter program. The JIT-compiled handler is then called on every syscall, making well-written filters very cheap (typically a handful of nanoseconds per syscall on a hot path).

### Interaction with ptrace

If `SECCOMP_RET_TRACE` fires but no ptrace tracer is attached, the kernel treats it as `SECCOMP_RET_ERRNO` with `ENOSYS`. If a tracer is attached, it gets a `PTRACE_EVENT_SECCOMP` notification. The tracer can then modify the syscall number or arguments, or skip the syscall entirely, before resuming the tracee. This mechanism underpins tools like `strace -e inject` and userspace system call emulation frameworks.

## Key Data Structures

**`struct seccomp_filter`** (kernel-internal, `kernel/seccomp.c`)
- `prog` — JIT-compiled BPF program (`struct bpf_prog *`)
- `prev` — pointer to the previous (outer) filter in the chain
- `users` — reference count for filter sharing across `fork()`

**`struct seccomp_data`** (`include/uapi/linux/seccomp.h`)
- `nr` — syscall number
- `arch` — calling convention identifier (`AUDIT_ARCH_X86_64`, etc.)
- `args[6]` — raw argument registers

## Key Functions

- `__secure_computing(sd)` — hot path called on every syscall entry
- `seccomp_run_filters(sd, match)` — iterates the filter chain, returns winning action
- `do_seccomp()` — handles the `seccomp(2)` syscall
- `seccomp_prepare_user_filter()` — verifies and JITs the BPF program

## Config & Flags

- `CONFIG_SECCOMP` — enables the framework (strict mode)
- `CONFIG_SECCOMP_FILTER` — enables BPF filter mode
- `CONFIG_HAVE_ARCH_SECCOMP_FILTER` — per-arch BPF support
- `SECCOMP_FILTER_FLAG_TSYNC` — synchronise filter to all threads in process
- `SECCOMP_FILTER_FLAG_NEW_LISTENER` — return a notification fd instead of installing normally
- `/proc/sys/kernel/perf_event_paranoid` — indirectly affects ptrace/trace interactions

## Interactions

- **[[capabilities]]** — `CAP_SYS_ADMIN` bypasses the `NO_NEW_PRIVS` requirement; `PR_SET_NO_NEW_PRIVS` is the unprivileged path
- **[[bpf]]** — seccomp uses *classic* BPF (cBPF), not eBPF; the JIT is shared with socket filter programs
- **[[linux-audit]]** — `SECCOMP_RET_LOG` and policy violations (kill/trap) are logged via the audit subsystem
- **[[lsm-framework]]** — seccomp runs before LSM hooks in the syscall path (it is checked at kernel entry, before normal VFS/network code that would trigger hooks)
