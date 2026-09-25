---
title: "SELinux — Explained"
category: explained
original: "[[selinux]]"
subsystem: security
tags: [explained, security, selinux, mac, type-enforcement]
converted: 2026-09-25
---

# SELinux, explained

> Plain-language companion to [[selinux|the technical note]]. Same facts, fewer identifiers.

## The problem

Traditional Unix permissions decide based on **who** is asking: the user and group IDs. That means a compromised web server running as root can do anything root can, and a user can hand out access to their own files however they like. For high-assurance systems, and for limiting the damage from any compromised service, the rules need to be set centrally and enforced whatever the requester's user ID, capabilities or file ownership.

## The idea in one paragraph

SELinux decides based on **what kind of process** is asking and **what kind of object** it's touching. Every process and every object (file, socket, IPC object, port) carries a **label**, and a central policy lists exactly which kinds may do what to which kinds: "web-server processes may read, open and stat web-content files". Anything not explicitly allowed is **denied**, even for root. Decisions are cached so the common case costs a hash lookup. Developed by the NSA and merged in 2.6.0 (2003), it's the oldest major security module and the default on Red Hat Enterprise Linux, Fedora and Android.

## Step by step

### Step 1: Everything gets a label
A label (a **security context**) has four parts: user, role, type and level. The **type** does almost all the work: a web server process might be of type "httpd", and the files it serves of type "httpd content". Policy rules are written between types, independently of who owns what.

### Step 2: Where labels come from
- **Files:** stored in a `security.selinux` extended attribute, set by relabelling tools using the policy's path-to-label mappings.
- **New files:** **type transition** rules can label them automatically, e.g. a file the web server creates in its runtime directory gets the runtime type.
- **Processes:** get their type when they start, and can move to a new type (domain) when running a new program.
- **Sockets:** take the creating process's label. Packets can carry labels between machines through NetLabel.

### Step 3: Turn labels into numbers
Inside the kernel, each label is represented by a small integer, the **security ID**, stored in the process's and the inode's security data. Comparing integers is far cheaper than comparing strings.

### Step 4: Check through the cache
This is the key step. When a process opens a file, SELinux's hook takes the process's security ID, the file's security ID, the object class (file, socket, …) and the requested permissions, and looks them up in the **access vector cache**. A cached entry holds two bitmasks: what's allowed, and what should be logged even when allowed. About 97% of lookups hit the cache, costing a hash lookup and a bit test. On a miss, the policy engine searches the in-kernel policy, caches the answer, and returns it. Reloading policy flushes the cache.

### Step 5: Deny and record
A denial produces an audit record with both labels, the object class and the denied permissions. Policy authors often run a new application in **permissive** mode, collect these records, and use a tool to turn them into allow rules.

### Step 6: Modes
- **enforcing:** violations are denied and logged
- **permissive:** violations are only logged, for policy development
- **disabled:** off entirely; turning it back on needs a reboot

Enforcing and permissive can be switched at runtime; disabling needs a boot option.

### Step 7: Multi-level security (optional)
The **level** part of the label supports classified-style rules (Bell-LaPadula): a process at a lower sensitivity can't read files labelled higher, even when the types would allow it. Government and defence deployments use this; most commercial systems run the simpler **targeted** policy with every level the same.

## The picture

```text
 process  system_u:system_r:httpd_t:s0      ──open, read──▶  file  …:httpd_content_t:s0
     │ security ID 412                                          │ security ID 977
     └──────────────▶ access vector cache (412, 977, file) ◀────┘
                         hit (~97%): allowed bits ∋ read → OK
                         miss: policy engine → cache → answer
 policy: allow httpd_t httpd_content_t:file { read open getattr };
 /etc/shadow (shadow_t): no rule → denied + audit record with both labels
```

## Tradeoffs

- **What it gives you:** central, mandatory policy that even root can't bypass; labels that follow objects through renames and moves; fine-grained control per object class and permission; mature tooling and wide deployment.
- **What it costs / requires:** every object must be labelled correctly and policy must cover every legitimate action, which is hard to write, hence permissive mode and the tools that generate rules from denials.
- **Where it bites:** a mislabelled file or missing rule shows up as a mysterious "permission denied"; the audit record is the only explanation. SELinux still needs exclusive use of some object types, so it can't yet run fully stacked with AppArmor; that work is ongoing.

## How it got here

- **2.6.0 (2003):** contributed by the NSA as the first major security module on the new LSM framework.
- Since then it has become the default mandatory access control on Red Hat Enterprise Linux, Fedora and Android, with stacking alongside other major modules still in progress.

## Related

- Technical version: [[selinux]]
- [[security-explained|Security subsystem]], [[lsm-framework-explained|LSM framework]], [[linux-audit-explained|Audit]], [[credentials-explained|Credentials]], [[apparmor-explained|AppArmor]], [[process-model-explained|Process security model]]
- [[netlabel-explained|NetLabel]], [[extended-attributes-and-acls-explained|Extended attributes]]
