---
title: "smackfs — Explained"
category: explained
original: "[[smackfs]]"
subsystem: security
tags: [explained, security, smack, smackfs, policy]
converted: 2026-09-25
---

# smackfs, explained

> Plain-language companion to [[smackfs|the technical note]]. Same facts, fewer identifiers.

## The problem

Smack's engine is in the kernel, but its policy (which label may do what to which, how labels map onto network packets, who counts as a Smack administrator) has to come from somewhere. Without an administration interface, Smack could only apply its built-in special-label rules plus whatever labels were already on files. And Smack often runs on small embedded systems that may not have Python, Go or elaborate policy tools.

## The idea in one paragraph

smackfs is the **control panel** for Smack, presented as a small pseudo-filesystem (mounted at /sys/fs/smackfs, built on the same machinery as [[securityfs-explained|securityfs]]). Every file is a knob or a readout: write a line to one file to add a rule, write to another to map a network label, read a file to dump the policy. Changes take effect **immediately** on write: no compile step, no reload daemon, no commit. Because it's all plain files, a shell script with `echo` and `cat` is enough to manage policy.

## Step by step

### Step 1: Mount it early
smackfs registers when Smack starts, and is mounted early in boot (from fstab or by systemd), before most daemons run. Mounting creates all the control files, each with its own read and write handling.

### Step 2: Load rules
This is the key step. Writing a line like "subject object rwxat" to the main rule file:
1. imports both labels into the [[smack-label-registry-explained|label registry]] (creating them if new)
2. looks up the subject's rule tree for that object
3. updates the existing rule, or adds a new one

The mode letters are read, write, execute, append, transmute, lock and bringup; "-" revokes everything. The rule is live the moment the write returns. Reading the same file dumps every rule in the system. An older version of the file only takes labels up to 7 characters, kept for early deployments.

### Step 3: Ask "would this be allowed?"
Writing "subject object mode" to the access-query file and reading it back returns 1 or 0. Scripts use it while developing policy, and PAM modules use it to make access decisions in user space.

### Step 4: Configure networking
- **CIPSO mappings:** tie a combination of DOI, level and categories to a Smack label, so labelled incoming packets are recognised
- **host overrides:** give an address or subnet a fixed label, bypassing CIPSO for peers that don't speak it
- **DOI:** the domain of interpretation used on all outgoing packets (default 3); every Smack peer must agree
- **ambient:** the label for packets arriving without a tag (default floor, "\_")

See [[smack-network-labeling-explained|network labelling]].

### Step 5: Control privilege and logging
- **only-cap label:** processes must carry this label for their MAC admin and MAC override capabilities to count in Smack. A leaked capability alone then isn't enough.
- **logging:** off, denials, grants, or both; changes apply at once.
- **relabel-self:** gives a process a list of labels it may switch itself to without MAC admin, which session managers use in login flows.
- **unconfined** (development builds only): processes with a chosen label get every access, but each one is logged, to discover which rules a program needs without breaking it.
- **ptrace:** whether tracing requires an exact label match or only the override capability.

### Step 6: Who may write
Every write requires the MAC admin capability, except relabel-self, which enforces its own per-process list. Reading is open to anyone with read permission on the file.

### Step 7: Filesystem-wide defaults
Separately, mount options on other filesystems set default, root, floor, hat and transmute labels for a whole mount without touching individual files. A filesystem can also be marked untrusted, so every file must carry the root's label.

## The picture

```text
 /sys/fs/smackfs/
   load2        echo "App Server rw" > load2    → rule live immediately
   access2      echo "App Server r" > access2; cat access2 → 1
   cipso2       label ↔ DOI/level/categories
   netlabel     "@192.168.1.5/32 webserver"
   doi          3        ambient   _
   onlycap      label required for MAC capabilities to count
   logging      0 | 1 | 2 | 3
   relabel-self per-process list of allowed self-transitions
```

## Tradeoffs

- **What it gives you:** policy managed with nothing but a shell, immediate effect, the ability to test decisions before relying on them, and fine control over who counts as a Smack administrator.
- **What it costs / requires:** no transactions. A half-loaded policy is visible to the running system. In practice, init scripts load all rules before starting applications, so this rarely matters, but atomic updates on a live system aren't possible.
- **Where it bites:** smackfs is global: every process in every namespace shares one Smack policy. That fits Smack's original design, where one administrator controls the whole system, but not containers wanting their own policies; per-namespace smackfs has been proposed but not merged.

## How it got here

- **2.6.25:** the first smackfs, with short-label interfaces.
- **3.x:** long-label interfaces, with labels growing from 7 to 255 characters; only-cap and logging controls.
- **4.x:** relabel-self, host overrides, the unconfined development mode and the ptrace control.
- **5.x:** per-namespace smackfs proposed, still a work in progress.

## Related

- Technical version: [[smackfs]]
- [[smack-explained|Smack]], [[smack-access-engine-explained|Access engine]], [[smack-label-registry-explained|Label registry]], [[smack-inode-and-task-labeling-explained|Inode and task labelling]], [[smack-network-labeling-explained|Network labelling]]
- [[securityfs-explained|securityfs]], [[netlabel-explained|NetLabel]], [[capabilities-explained|Capabilities]]
