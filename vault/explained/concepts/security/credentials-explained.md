---
title: "Credentials — Explained"
category: explained
original: "[[credentials]]"
subsystem: security
tags: [explained, security, credentials, rcu, copy-on-write]
converted: 2026-09-25
---

# Credentials, explained

> Plain-language companion to [[credentials|the technical note]]. Same facts, fewer identifiers.

## The problem

Every access decision in the kernel (permission bits, capability checks, security-module labels) depends on **who** a task is. That identity is read constantly, from many places, sometimes about other tasks. But it also changes: a service drops root, a setuid program starts, a capability is lowered. If identity could be edited in place, a reader might catch it half-changed, say with the new user ID but the old capabilities, and make a wrong security decision. Locking every read would be far too slow.

## The idea in one paragraph

Keep everything about a task's identity in **one record that is never modified once it's live**. To change identity, make a **copy**, edit the copy where nobody can see it, and then **swap a pointer** to make the new copy current. Readers always see either the whole old record or the whole new one, never a mix, and they need no lock: RCU keeps the old record alive until every reader that might still be looking at it has finished.

## Step by step

### Step 1: What the record holds
A task's credentials record contains:
- **user and group IDs** in four flavours: real, saved, effective, and filesystem (usually the same as effective)
- **supplementary groups**, kept sorted for fast membership checks
- the five **capability sets**
- **keyrings** for the session, process and thread
- the **user namespace** the task lives in
- a slot for **security-module data** (managed by the framework since 5.1)
- **securebits**, flags that change how capabilities behave

### Step 2: Two pointers per task
Each task points to two records: its **real** identity, used for things like signal delivery and reporting in /proc, and its **effective** identity, used for access checks. A task reading its own credentials needs no lock, since nothing else can swap its pointer while it runs. Reading another task's credentials needs the RCU read lock.

### Step 3: Copy
To change identity (during a setuid call, running a setuid program, or adjusting capabilities), the kernel first makes a private, writable copy of the current record.

### Step 4: Edit and check
The copy is modified: a new effective user, a capability lowered, and so on. Nobody else can see it, so this is safe. Security modules then get a chance to inspect and veto the change. If anything fails, the copy is thrown away and nothing has changed.

### Step 5: Swap
This is the key step. The task's pointer is switched to the new record in one atomic step, effective immediately. The old record's reference count drops, and it's freed only after an RCU grace period, once every reader that might hold it has finished. No reader ever sees a half-built identity.

### Step 6: Running a new program
Program execution builds the new credentials up front, applies the setuid and setgid bits, file capabilities and security-module transitions (such as an SELinux domain change) to that pending record, and only then commits it. All those decisions are applied together relative to the swap.

### Step 7: Files remember who opened them
Each open file keeps a snapshot of its **opener's** credentials. That blocks a specific trick: a process opens a sensitive file as root, drops privileges, and passes the file descriptor to unprivileged code. Checks that care about who opened the file use the snapshot, not whoever holds the descriptor now.

### Step 8: Securebits
A few flags change capability rules for a task: stop the kernel clearing capabilities when the user ID changes away from root, or stop setuid-root programs from gaining capabilities at all. Each can be locked permanently. Container runtimes and hardened service launchers use them.

## The picture

```text
 task ──cred──▶ [ record v1: uid 0, caps ALL ]  ◀── readers (lock-free / RCU)
   │
   │  change: copy v1 → v2, edit v2 (uid 1000, caps none), security modules check
   ▼
 task ──cred──▶ [ record v2: uid 1000, caps none ]   (one atomic pointer swap)
                [ record v1 ] freed after RCU grace period

 open file ──▶ snapshot of opener's record (unchanged by later drops)
```

## Tradeoffs

- **What it gives you:** lock-free, always-consistent reads of identity on the hottest security paths; all-or-nothing identity changes; a single place every check reads from.
- **What it costs / requires:** every change allocates a new record, and old ones must wait out an RCU grace period before being freed.
- **Where it bites:** code must follow the protocol (copy, edit, commit, or abort) and never edit a live record. Reading *another* task's credentials without the RCU lock is a bug. The kernel also has an internal way to temporarily override the current credentials, reserved for kernel use only.

## How it got here

- **5.1:** the security-module data slot in the record became framework-managed, part of the groundwork for stacking several security modules.

## Related

- Technical version: [[credentials]]
- [[security-explained|Security subsystem]], [[capabilities-explained|Capabilities]], [[lsm-framework-explained|LSM framework]], [[selinux|SELinux]], [[seccomp-bpf|seccomp]], [[user-namespaces|User namespaces]], [[kernel-keyring-explained|Keyrings]]
- [[rcu-read-copy-update-explained|RCU]]
