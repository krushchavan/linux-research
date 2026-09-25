---
title: "Linux Audit — Explained"
category: explained
original: "[[linux-audit]]"
subsystem: security
tags: [explained, security, audit, compliance]
converted: 2026-09-25
---

# Linux audit, explained

> Plain-language companion to [[linux-audit|the technical note]]. Same facts, fewer identifiers.

## The problem

Compliance regimes (Common Criteria, PCI-DSS, HIPAA, CISA guidelines) demand evidence of **who did what privileged thing, when, and from where**. Access control decides whether something is allowed, but it doesn't keep a trustworthy record. Syslog isn't good enough either: it's a user-space service, so an attacker who gets far enough can quietly silence it. The record has to come from the kernel, and it must be hard to suppress without anyone noticing.

## The idea in one paragraph

The kernel itself generates **audit records** at security-relevant moments (matching system calls, access denials, identity changes), queues them in a kernel buffer, and ships them to the audit daemon over a netlink socket. Every record carries a **sequence number**, so a missing record shows up as a gap. Short of compromising the kernel itself, the edge of the threat model, an attacker can't make records vanish unnoticed.

## Step by step

### Step 1: Records from system calls
Administrators install rules. When a system call matches one, the kernel records its metadata (system call, process, user and effective user, session, return code) around entry and exit, plus resolved paths and inodes for calls that touch files. Rules can match on system call, architecture, user and group IDs, success or failure, path, or SELinux labels. "Log every failed open", for example, is one rule, evaluated when the call exits.

### Step 2: Records from inside subsystems
Subsystems also emit records directly at decision points: SELinux when it denies access, AppArmor for its events, the credentials code for user, group and capability changes, seccomp for its log and kill actions. One event can produce several records sharing a serial number, e.g. a write might produce the system-call record, the path involved, the working directory, and the process's command line.

### Step 3: Labels in denial records
This is the key step for anyone debugging policy. When SELinux denies an access, it appends the full security context of both the process and the target to the audit record. Without that, an administrator would see only "permission denied" in the application log, with no hint of which rule fired. SELinux denial records are the most common audit event on SELinux systems.

### Step 4: Watch files
A watch rule, such as "record any write or attribute change to /etc/passwd, tagged with a key", attaches a filesystem notification to the inode. Any matching operation produces a full audit record, even if the system call wouldn't otherwise be audited. Watches are the main tool for auditing configuration files.

### Step 5: Buffer, and decide what to do when full
Records queue in an in-kernel buffer (8192 records by default). If records arrive faster than the daemon drains them, the kernel must choose between dropping records, losing completeness, or blocking the system call that caused them, losing availability. A separate failure mode setting decides whether problems are silent, printed to the kernel log, or cause a panic.

### Step 6: Deliver and check
Records travel to the audit daemon over netlink. The daemon checks that sequence numbers keep increasing and reports any gap. It applies its own filters, writes records to rotating log files, and can forward them to a remote audit server. Report and search tools summarise the logs or find records by key.

## The picture

```text
 system call matching a rule ─┐
 SELinux / AppArmor denial ───┼─▶ audit records (shared serial per event)
 setuid / capability change ──┤      SYSCALL + PATH + CWD + PROCTITLE …
 watched file changed ────────┘              │
                                             ▼
                               kernel buffer (8192) ── full? drop │ block │ panic
                                             │ netlink, sequence numbers
                                             ▼
                               audit daemon: gap check, filter, write, forward
```

## Tradeoffs

- **What it gives you:** a kernel-generated, gap-detectable record of privileged activity, with the security labels needed to explain denials.
- **What it costs / requires:** broad rules generate a lot of records and overhead; the buffer size and the drop-versus-block choice have to be tuned for each system.
- **Where it bites:** when the buffer fills, completeness and availability conflict directly. Blocking guarantees the record but can stall the system; dropping keeps things running but leaves a gap. Audit also only observes: it never makes access decisions itself.

## How it got here

- **Today:** records come from system-call rules and file watches, and from SELinux, AppArmor, the credentials code and seccomp, each with its own record types.

## Related

- Technical version: [[linux-audit]]
- [[security-explained|Security subsystem]], [[lsm-framework-explained|LSM framework]], [[selinux|SELinux]], [[apparmor-explained|AppArmor]], [[credentials-explained|Credentials]], [[seccomp-bpf-explained|seccomp]]
