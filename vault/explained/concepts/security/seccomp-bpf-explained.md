---
title: "seccomp BPF — Explained"
category: explained
original: "[[seccomp-bpf]]"
subsystem: security
tags: [explained, security, seccomp, sandboxing, bpf]
converted: 2026-09-25
---

# seccomp BPF, explained

> Plain-language companion to [[seccomp-bpf|the technical note]]. Same facts, fewer identifiers.

## The problem

Every system call is a doorway into the kernel, and a program that parses untrusted input (a browser renderer, a container workload) is a doorway an attacker may be standing in. Most such programs need only a small fraction of the hundreds of available system calls. If a compromised process can't make the others at all, kernel bugs behind them are out of reach. Programs need a way to say "from now on, I only use these calls, with these arguments", and it must not be possible to abuse that to trick privileged programs.

## The idea in one paragraph

A process installs a small **filter program**, written in classic BPF, that the kernel runs on **every system call** before doing anything else. The filter sees the call's number, the CPU architecture/calling convention, the instruction pointer and the raw arguments, and returns a verdict: allow, fail with an error, send a signal, kill, log, hand to a debugger, or ask a supervisor process. Filters can only be added, never removed, so restrictions only ever get tighter. It's the main sandboxing tool for Chrome, Firefox, container runtimes and systemd's system-call filters.

## Step by step

### Step 1: Install a filter
A process hands the kernel a classic BPF program, the same format used for socket filters. To do so it must either hold the system-administration capability in its user namespace, or have set the **"no new privileges"** flag first. Without that rule, a process could install a filter and then run a setuid program, which would inherit the filter while running with elevated privileges, under a policy written on the assumption that the process was unprivileged.

### Step 2: Run on every system call
On each system-call entry, the kernel runs the filters against a snapshot of the call. They're compiled to native code (JIT) on common architectures, so a well-written filter costs only a handful of nanoseconds per call.

### Step 3: Check the architecture first
The same number means different system calls under different calling conventions: a 64-bit process can still make 32-bit-style calls. A filter must check the **architecture** before trusting the number, or an attacker can slip past it by switching conventions.

### Step 4: Stack filters, strictest verdict wins
This is the key step. Each new filter is added to a chain, and **all** of them run on every call. Each returns a verdict plus a small data value, such as the error number to return. When they disagree, the most severe verdict wins, whatever order the filters were added in. From most to least severe:
1. kill the whole process
2. kill the calling thread
3. send a "bad system call" signal (the call doesn't run)
4. return a chosen error
5. hand the call to a user-space supervisor (5.0)
6. notify an attached debugger
7. allow and log to audit (useful while writing a policy)
8. allow

So a sandbox can install a base policy and let sandboxed code add its own restrictions, but never loosen the base one. A flag can apply a filter to all threads in the process at once.

### Step 5: Ask a supervisor
With the supervisor verdict, the blocked call's details (process, a process handle, the call snapshot) go to another process over a file descriptor. The supervisor decides, and can **do the work itself** with its own privileges and report the result as if the kernel had done it. That lets an unprivileged container perform something like a mount the kernel would otherwise refuse: the container manager intercepts it, performs it, and returns success.

### Step 6: Hand to a debugger
With the debugger verdict, an attached tracer is notified and can change the call number or arguments, or skip the call, before resuming. With no tracer attached, the call fails with "not implemented". Tools that inject faults into system calls, and user-space system-call emulators, are built on this.

## The picture

```text
 system call ─▶ snapshot {number, arch, ip, args[6]}
                    │ run every filter in the chain (JIT, ~ns)
                    ▼
   filter C (added last)   ─▶ ERRNO(EPERM)
   filter B                ─▶ ALLOW
   filter A (base policy)  ─▶ KILL_PROCESS      ← most severe wins → process killed
                    │ allow?
                    ▼
            normal kernel path (then LSM hooks, permissions…)
```

## Tradeoffs

- **What it gives you:** a cheap, unprivileged way to shrink the kernel surface a process can reach, with restrictions that only tighten and flexible outcomes, including handing decisions to a supervisor.
- **What it costs / requires:** the "no new privileges" flag or the admin capability; filters written against raw numbers and register values, which must check the architecture. It uses *classic* BPF, not the extended BPF used elsewhere, though it shares the socket-filter JIT.
- **Where it bites:** filters see only the call and its raw arguments, not the objects they refer to; checking paths this way is error-prone and fooled by symlinks, which is the gap Landlock fills. A mistake in a filter can leave a dangerous call reachable. seccomp runs at kernel entry, before any security-module hook, so it complements those checks rather than replacing them.

## How it got here

- **3.5 (2012):** BPF filter mode merged, extending the original strict mode.
- **5.0:** the user-space supervisor verdict, enabling seccomp-agent patterns for containers.
- A dedicated seccomp system call later joined the original prctl interface for installing filters.

## Related

- Technical version: [[seccomp-bpf]]
- [[security-explained|Security subsystem]], [[capabilities-explained|Capabilities]], [[process-model-explained|Process security model]], [[landlock-explained|Landlock]], [[lsm-framework-explained|LSM framework]], [[linux-audit-explained|Audit]]
- [[bpf-explained|BPF]], [[bpf-jit-compiler-explained|BPF JIT compiler]]
