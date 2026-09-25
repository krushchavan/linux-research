---
title: "Process Security Model — Explained"
category: explained
original: "[[process-model]]"
subsystem: security
tags: [explained, security, execve, ptrace, no-new-privs]
converted: 2026-09-25
---

# The process security model, explained

> Plain-language companion to [[process-model|the technical note]]. Same facts, fewer identifiers.

## The problem

Processes constantly act on each other and change who they are: they fork children, run new programs (some setuid, some carrying file capabilities), send signals, and attach debuggers. Without clear rules for how identity is inherited, transformed and compared, any of these could become a privilege escalation: a program gaining powers it shouldn't, a signal reaching a process it shouldn't, or a debugger reading secrets out of a privileged program's memory.

## The idea in one paragraph

Each process carries **two identity envelopes**: a **real** one (who it is, which others check when they act *on* it) and an **effective** one (what it may do when *it* acts on others). Forking gives the child the same sealed envelopes. Running a new program is the one place the effective envelope is reopened and resealed, following rules from the program file's metadata, and it's done as a **staged pipeline** that commits all at once. Every interaction between processes (signals, tracing, reading /proc) compares these envelopes.

## Step by step

### Step 1: Two identities per process
A process's **objective** identity is what others see when they try to signal or inspect it. Its **subjective** identity is what the kernel checks when it opens files, binds sockets or uses capabilities. They're usually identical. They differ during identity changes, and when a kernel service temporarily acts under other credentials: the split lets the kernel override the acting identity without disturbing how others see the process.

### Step 2: Fork shares, doesn't copy
A child gets a reference to **exactly the same** immutable [[credentials-explained|credentials record]] as its parent, with nothing copied until the child changes something. Everything is inherited: user and group IDs, all five capability sets, securebits, keyrings, security-module data. The **dumpable** flag is inherited too.

### Step 3: Running a program, stage by stage
This is the key step. Running a new program is where identity changes most, so the kernel builds the new identity in a separate, pending record and only commits it at the end:
1. **Prepare:** start a fresh pending record.
2. **setuid and setgid:** if the program file has these bits, its owner becomes the new effective user or group, unless the "no new privileges" flag is set or the filesystem is mounted nosuid.
3. **File capabilities:** the new permitted set is what both the process and file allow to be inherited, plus what the file grants outright **limited by the bounding set**, plus any ambient capabilities. So running a file with capabilities can never give a process a power outside its bounding set.
4. **Ambient capabilities:** for ordinary (non-privileged) programs, ambient capabilities carry across and are added to permitted and effective. If the program is privileged (setuid, setgid or file capabilities), the ambient set is **cleared** so it can't leak across a privilege boundary.
5. **Security modules:** they compute any change of their own, such as SELinux choosing the program's new domain from the old domain, the file's label and policy, and get a final go/no-go.
6. **Commit:** the pending record is swapped in atomically.

### Step 4: Privileged programs become non-dumpable
Whenever a program gains privileges (through setuid, setgid or file capabilities), its **dumpable** flag is reset to the system default, normally "not dumpable". A non-dumpable process doesn't write core dumps, and its /proc memory and maps can't be read or traced without a special capability, until it chooses to re-enable dumping. That's why a debugger can't attach to a setuid program. Reusing this one flag for /proc access closed a whole class of leaks from setuid programs.

### Step 5: "No new privileges"
A one-way flag, inherited forever and never cleared (3.5). With it set, setuid and setgid bits are ignored, file capabilities add nothing, and security-module transitions that would grant privilege are blocked. The program runs with what the process already had. That's what makes it safe to let unprivileged users install seccomp filters: a filter can't be used to confuse a setuid program, because that program won't gain privilege anyway.

### Step 6: Who may send a signal
Sending a signal passes several gates in order:
1. the target must be visible in the sender's PID namespace tree
2. the sender's effective or real user ID must match the target's real or saved user ID (the saved ID lets a setuid program that temporarily dropped privileges still be signalled by its original owner)
3. otherwise, the sender needs the "kill" capability in the target's user namespace
4. finally, security modules can veto

The "continue" signal skips the ID check within the same session, a leftover from POSIX job control.

### Step 7: Who may trace
Tracing can read and write another process's memory and registers, so it's the most tightly guarded. Attaching requires the target to be dumpable (or the tracing capability), matching user IDs (or that capability in the target's user namespace), and the security modules' approval. Yama can narrow this further: only a direct parent may trace, only processes with the capability may, or nobody may attach at all. If a process runs a new program while traced, security modules are told, and can refuse a privileged transition that the tracer could otherwise intercept.

## The picture

```text
 fork:   child ──▶ same credentials record as parent (refcount+1)

 exec(setuid binary):
   pending record ─▶ setuid/setgid? ─▶ file caps (≤ bounding) ─▶ ambient (cleared if privileged)
                  ─▶ LSM (e.g. new SELinux domain) ─▶ commit atomically
                  ─▶ dumpable = off  (no core, no /proc memory, no ptrace)
   "no new privileges" set? → setuid bits and file caps ignored

 kill(target):  namespace ─▶ uid match ─▶ kill capability ─▶ LSM
 ptrace(target): dumpable? ─▶ uid match / trace capability ─▶ LSM / Yama
```

## Tradeoffs

- **What it gives you:** one consistent model for inheritance, privilege gain and inter-process control; lock-free identity checks; safe self-sandboxing thanks to "no new privileges".
- **What it costs / requires:** every identity change allocates and copies a record, accepted because changes are rare compared to reads. Five interacting capability sets and the program-execution formula take careful reading to predict what a child will end up with.
- **Where it bites:** ambient capabilities made least privilege practical for non-root launchers but added a fifth set to reason about. Dumpability is a coarse flag doing double duty for core dumps, /proc and tracing.

## How it got here

- **2.6.26:** securebits became per-process instead of global, making capability restrictions container-safe.
- **2.6.29:** the separate credentials record (David Howells's 2008 series), replacing IDs and capabilities scattered through the task, and banning one task from changing another's credentials.
- **2.6.33:** file capabilities always built in.
- **3.5:** "no new privileges".
- **4.3:** ambient capabilities (Andy Lutomirski's 2015 proposal), after showing that a non-root launcher couldn't pass even one capability to a script.
- **5.1:** security-module data in credentials became framework-managed, so several modules can keep per-credential state.

## Related

- Technical version: [[process-model]]
- [[security-explained|Security subsystem]], [[credentials-explained|Credentials]], [[capabilities-explained|Capabilities]], [[lsm-framework-explained|LSM framework]], [[seccomp-bpf-explained|seccomp]], [[user-namespaces|User namespaces]], [[selinux-explained|SELinux]]
