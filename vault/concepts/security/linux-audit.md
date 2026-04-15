---
title: "Linux Audit"
category: concept
tags: [security, audit, compliance, syscall-auditing, netlink]
subsystem: security
kernel_version: "2.6.6"
researched: 2026-04-15
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/security/lsm.html
---

# Linux Audit

## Overview

The Linux audit subsystem provides a tamper-resistant kernel-level record of security-relevant events. It is designed for compliance requirements (Common Criteria, PCI-DSS, HIPAA, CISA guidelines) that demand evidence of who performed what privileged operation, when, and from which terminal or network address. Unlike syslog (which is a userspace service that can be silenced), audit records flow through a Netlink socket and are tracked with sequence numbers — gaps in the sequence are detectable, making quiet suppression difficult.

## How It Works

### Event Generation

Audit records originate from two places:

1. **Syscall auditing**: When a syscall matches an active audit rule (set via `auditctl`), the kernel records metadata about the call — syscall number, pid, uid, euid, session id, return code — both at entry and exit. The record for a file-path-accessing syscall also includes the resolved path and the inode. This is implemented by `audit_syscall_entry()` and `audit_syscall_exit()` wrapper hooks in the syscall dispatch path.

2. **Explicit audit log calls**: Kernel subsystems call `audit_log_start()` / `audit_log_format()` / `audit_log_end()` to emit records at specific decision points. SELinux calls `audit_log_secctx()` when it denies an access (emitting an `AVC` record). AppArmor emits `APPARMOR` type records. The credential layer emits records for `setuid`/`setgid` changes.

Each event may consist of multiple audit records (different `type` values, same `serial` number). For example, a `write(2)` that is audited might generate:
- `SYSCALL` — basic syscall metadata
- `PATH` — the file path resolved at the time of the call
- `CWD` — the current working directory
- `PROCTITLE` — the process command line

### In-Kernel Buffer

Records are assembled into `struct audit_buffer` objects and queued to an in-kernel ring buffer. The `audit_backlog_limit` sysctl controls the buffer size (default 8192 records). If the buffer fills faster than `auditd` drains it, the kernel can either drop records (losing audit completeness) or block the offending syscall (guaranteeing completeness at the cost of availability). The policy is controlled by `audit_failure` mode (0=silent, 1=printk, 2=panic).

### Delivery to auditd

The kernel ships records to the `auditd(8)` daemon via `NETLINK_AUDIT` Netlink socket. Each message includes a sequence number; auditd verifies monotone increase and reports gaps. This makes it impossible for an attacker to silently suppress records without either compromising the kernel (which is the threat model's boundary) or generating a detectable gap.

`auditd` applies filter rules configured by `auditctl`: it can drop records that match exclusion patterns, hash record streams to multiple files, or forward to a remote audit server via `audisp`.

### Watch Rules

`auditctl -w /etc/passwd -p wa -k passwd_changes` installs a filesystem watch. Internally this creates an `audit_fsnotify` watch on the inode. Any `write` or `attribute-change` operation on that inode causes the kernel to emit a full audit record even if the syscall would not otherwise be audited. Watch rules are the primary tool for auditing configuration file access in compliance environments.

### Audit and LSM Integration

LSMs integrate with audit through a dedicated interface, not by generating syslog messages. When SELinux denies an access, `selinux_inode_permission()` calls:

```c
audit_log_secctx(ab, isec->sid);
```

This appends the security context string to an open audit buffer, so the denial record contains the full `user:role:type:level` label of both the process and the target. Without this integration, an administrator would only see `Permission denied` in the application log with no indication of which SELinux rule caused it.

### Syscall Filtering

`auditctl -a always,exit -F arch=b64 -S open,openat -F success=0` audits all failed open-family syscalls. The filter is evaluated at syscall exit using the `audit_filter_syscall()` function. Filters can match on:
- Syscall number (`-S`)
- Architecture (`-F arch`)
- uid/gid/euid/egid (`-F uid=`, `-F euid=`)
- Return value (`-F success=0` for failures)
- Object path (`-F path=`, requires string matching)
- SELinux context (`-F subj_type=`, `-F obj_type=`)

## Key Data Structures

**`struct audit_context`** (per-task, in `task_struct`)
- `in_syscall` — whether a syscall audit record is in flight
- `serial` — event serial number
- `names[]` — array of path names collected during the syscall
- `tree` — reference to watched inodes

**`struct audit_rule_data`** (userspace→kernel via Netlink)
- `flags` / `action` — filter flags and action (ALWAYS/NEVER)
- `fields[]` — array of filter field comparisons

## Key Functions

- `audit_log_start(ctx, gfp, type)` — allocate an audit buffer
- `audit_log_format(ab, fmt, ...)` — append formatted text to buffer
- `audit_log_end(ab)` — finalise and enqueue for delivery
- `audit_syscall_entry()` / `audit_syscall_exit()` — syscall hook wrappers
- `audit_filter_syscall()` — evaluates active rules against current syscall

## Config & Flags

- `CONFIG_AUDIT`, `CONFIG_AUDITSYSCALL`
- `auditctl -l` — list active rules
- `auditctl -D` — delete all rules
- `/proc/sys/kernel/audit_backlog_limit` — ring buffer size
- `auditd.conf` — `max_log_file`, `num_logs`, `dispatcher` settings
- `aureport` — summary reports from audit logs
- `ausearch -k passwd_changes` — search by audit key

## Interactions

- **[[lsm-framework]]** — LSMs call `audit_log_secctx()` and related helpers to annotate their decisions
- **[[selinux]]** — the primary LSM consumer of audit; AVC denial records are the most common audit event type in SELinux environments
- **[[credentials]]** — credential changes (`setuid`, `setgid`, capability changes) generate `CRED_CHANGE` audit records
- **[[seccomp-bpf]]** — `SECCOMP_RET_LOG` and kill actions produce `SECCOMP` type audit records
