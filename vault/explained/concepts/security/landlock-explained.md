---
title: "Landlock — Explained"
category: explained
original: "[[landlock]]"
subsystem: security
tags: [explained, security, landlock, sandboxing, lsm]
converted: 2026-09-25
---

# Landlock, explained

> Plain-language companion to [[landlock|the technical note]]. Same facts, fewer identifiers.

## The problem

A program that handles untrusted input, such as a document parser or a network service, would like to lock itself down: "from now on, I only touch these directories and bind this port." The existing tools don't quite fit:
- **SELinux and AppArmor** can express that, but only an administrator with root can configure them
- **seccomp** can be used by anyone, but it filters *which system calls* run, not *which files* they touch. Checking paths inside a seccomp filter is error-prone and can be fooled by symlinks and bind mounts.

What's missing is a way for an **unprivileged** process to restrict its own access to specific **objects**.

## The idea in one paragraph

Landlock lets any process **sandbox itself**. It builds a ruleset ("I want to control file reads, file writes and TCP binding; allow reads and writes under /tmp"), then applies it to itself. From then on, the process and all its children can use those rights only where the rules allow. Rulesets stack like layers of locks: each new layer can only take access away, never give it back. Where seccomp asks "is this system call allowed?", Landlock asks "may this system call touch *this* object?"

## Step by step

### Step 1: Declare what you're controlling
The process creates a ruleset naming the access rights it wants to govern, such as reading files, writing files, or binding TCP ports. Rights **not** named stay allowed. Landlock is an allowlist for the rights it handles, not a blanket deny-all.

### Step 2: Add rules by file descriptor
Each rule pairs a directory (or file) with the operations allowed beneath it. The directory is passed as an **open file descriptor**, not a path string. The descriptor refers to a specific inode, so later symlink tricks or renames can't redirect the rule somewhere else. Network rules name port numbers.

### Step 3: Lock yourself in
The process sets the "no new privileges" flag (required) and applies the ruleset to itself. It becomes a **domain**: an immutable layer attached to the process's credentials, copied to children on fork. The ruleset's descriptor can then be closed.

### Step 4: Layers only tighten
This is the key step. Each time a process applies another ruleset, a new layer is added on top of those inherited from its parent. An access is allowed only if **every** layer has at least one rule permitting it. So a child can only ever be more restricted than its parent. A container manager can set a base layer, the container's init can add more, and individual services can add still more, and none of them can escape a layer an ancestor imposed.

### Step 5: Checking an access
When, for example, a file is opened, Landlock's hook walks **up the directory tree** from the file to the root, checking at each level whether that directory appears in a rule in each active layer. Rules are kept in a sorted tree keyed by inode, so each check is fast. Walking up means a rule covers the inode however it's reached, not only through the path that was used to name it.

### Step 6: What can be controlled
- **files:** read, write, execute, list directories, create each kind of file, remove files and directories, move files between directories (5.19), truncate (6.2)
- **network:** binding and connecting TCP ports (6.1)

Programs must ask the kernel which Landlock version it supports, and use only rights that version knows about, so the same program works on older kernels.

## The picture

```text
 parent process ─ layer 1 (container base): /srv/** read, /tmp/** read+write
        │ fork
        ▼
 service ─ adds layer 2: /tmp/app/** read+write, TCP bind 8080

 open("/tmp/app/x", write):  layer 1 ✓ (/tmp)   layer 2 ✓ (/tmp/app)  → allowed
 open("/tmp/other", write):  layer 1 ✓          layer 2 ✗             → denied
 open("/etc/passwd", read):  read handled, no rule in layer 1        → denied
```

## Tradeoffs

- **What it gives you:** self-sandboxing without root or administrator policy; restrictions tied to real objects, not strings; safe delegation through stacked layers. It stacks with SELinux or AppArmor rather than competing with them.
- **What it costs / requires:** the "no new privileges" flag, and a version check to discover which rights the kernel supports. It's meant to be used alongside seccomp: seccomp cuts down which system calls are reachable, and Landlock limits which objects those calls can touch.
- **Where it bites:** descriptors already open when the sandbox is applied aren't restricted, so a program must close inherited descriptors first if it wants them covered. There are no IPC restrictions yet (pipes, shared memory, signals); those are planned.

## How it got here

- **5.13 (2021):** merged, with filesystem rules.
- **5.19:** control over moving files between directories.
- **6.1:** TCP bind and connect rules.
- **6.2:** control over truncation.
- IPC restrictions are planned for later versions.

## Related

- Technical version: [[landlock]]
- [[security-explained|Security subsystem]], [[lsm-framework-explained|LSM framework]], [[seccomp-bpf-explained|seccomp]], [[capabilities-explained|Capabilities]], [[credentials-explained|Credentials]], [[apparmor-explained|AppArmor]], [[selinux-explained|SELinux]]
