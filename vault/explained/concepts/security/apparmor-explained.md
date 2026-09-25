---
title: "AppArmor — Explained"
category: explained
original: "[[apparmor]]"
subsystem: security
tags: [explained, security, apparmor, mac, lsm]
converted: 2026-09-25
---

# AppArmor, explained

> Plain-language companion to [[apparmor|the technical note]]. Same facts, fewer identifiers.

## The problem

Mandatory access control confines programs even when they run as root, so a compromised service can only touch what policy allows. SELinux does this by putting a label on every object in the system, which is powerful but hard to write policy for. Many administrators without security expertise still need to say something as plain as "nginx may write its logs and read its web root, and nothing else".

## The idea in one paragraph

AppArmor confines each program with a **readable profile written in terms of file paths**. The profile names a program and lists what it may do: which paths it can read or write, which network access it gets, which capabilities it may use. When the program starts, the kernel attaches its profile, and at every security hook it checks the requested path or operation against that profile. Anything not listed is denied.

## Step by step

### Step 1: Write a profile
A profile lists the program's path and its allowed operations. File rules use single-letter permissions: read, write, execute, memory-map as executable, link, lock. Paths can use wildcards: `*` matches one path component, `**` matches any number. For nginx, that might be "write under the log directory, read under the web root, read/write the PID file, TCP networking, bind to low ports, change user and group". Shared snippets (base system access, name-service lookups) can be included.

### Step 2: Compile and load it
A user-space tool compiles profiles into a binary policy and loads it through a special filesystem. The kernel stores loaded profiles in a tree keyed by profile name, which by convention is the program's path. Profiles can be replaced atomically.

### Step 3: Attach at program start
When a task runs a new program, AppArmor looks for a loaded profile whose name matches the program's path. If it finds one, the task moves into that profile, a **domain transition**. Rules can also control transitions explicitly when launching helpers:
- switch to a named profile
- inherit the current profile
- run unconfined

That way a confined service can start a helper under its own, possibly stricter, profile.

### Step 4: Check at every hook
At each security hook (file access, resource limits, socket creation and connection, ptrace), AppArmor fetches the task's current profile, without locking thanks to RCU, and checks the request against it.

### Step 5: Matching paths quickly
This is the key step, and the main cost of the path-based approach. For a file check, AppArmor first has to **rebuild the file's path** by walking up the directory entries to the root, which is more expensive than SELinux's label lookup. The path is then run through a **state machine (DFA)** compiled from the profile's path rules, which matches in time proportional to the path's length however many rules there are.

### Step 6: Complain mode for writing policy
Each profile is either **enforcing** or in **complain** mode. In complain mode, operations that would be denied are allowed but logged to audit as "allowed", the equivalent of SELinux's permissive mode, used to develop a profile by watching what a program actually does.

## The picture

```text
 exec /usr/sbin/nginx ──▶ profile named "/usr/sbin/nginx" loaded? ──▶ task enters it
                                                                     │
 open("/var/www/html/index.html", read)                              │
   └─ hook ─▶ current profile ─▶ rebuild path ─▶ DFA over path rules ┘
                                         /var/www/html/**  r   ✓ allow
 open("/etc/shadow", read) ──────────────▶ no rule matches      ✗ deny (or log, in complain mode)
```

## Tradeoffs

- **What it gives you:** approachable policy; administrators write rules in terms of paths and capabilities they already understand. It's the default on Ubuntu, Debian and openSUSE and has been since the mid-2010s, and it's common on most non-Red Hat systemd distributions.
- **What it costs / requires:** rebuilding paths on file checks costs more than a label lookup. Profile capability rules are checked *alongside* the kernel's own capability checks, and both must allow an operation.
- **Where it bites:** paths can be fooled by symlinks or overly broad wildcards, unlike labels that follow the object. AppArmor still needs exclusive use of some object types (mainly sockets), so it can't yet run fully stacked with SELinux. Through the 5.x series, task, credential and inode data became framework-managed, but socket-level objects remain exclusive.

## How it got here

- **Mid-2010s:** became the default on Ubuntu, Debian and openSUSE.
- **5.x:** stacking work made task, credential and inode data framework-managed; removing the remaining socket-level exclusivity is still in progress.

## Related

- Technical version: [[apparmor]]
- [[security-explained|Security subsystem]], [[lsm-framework|LSM framework]], [[selinux|SELinux]], [[capabilities-explained|Capabilities]], [[linux-audit|Audit]], [[landlock-explained|Landlock]]
