---
title: "Smack Inode and Task Labeling — Explained"
category: explained
original: "[[smack-inode-and-task-labeling]]"
subsystem: security
tags: [explained, security, smack, labels, xattr]
converted: 2026-09-25
---

# Smack inode and task labelling, explained

> Plain-language companion to [[smack-inode-and-task-labeling|the technical note]]. Same facts, fewer identifiers.

## The problem

Smack's [[smack-access-engine-explained|access engine]] compares two labels: the subject's and the object's. That only works if **every process** and **every file** actually carries a label. File labels must also survive reboots, new files need sensible labels automatically, and processes need a controlled way to move between labels without letting a compromised one relabel itself at will.

## The idea in one paragraph

Files get a **sticky note** saying "I belong to domain X", stored as an extended attribute on disk. Processes carry a **badge** saying "I am domain Y", stored in their credentials. The access engine compares badge and note against the rules. A child copies its parent's badge on fork. The badge changes only in controlled ways: running a program that carries its own "exec" label, or an explicit, permitted relabel.

## Step by step

### Step 1: New files take the creator's label
When a file, directory or symlink is created, Smack writes the **creating process's label** into the file's `security.SMACK64` attribute.

### Step 2: Shared directories can override that (transmute)
If the parent directory is marked **transmuting**, and the rule from the creator to the directory includes the transmute permission, the new file takes the **directory's** label instead. Without this, a shared directory written by processes from several domains fills up with a mix of labels, each needing its own rules. With it, everything in the directory carries one label and one rule governs access.

### Step 3: Read once, then cache
This is the key step for performance. The first time an existing file is checked, Smack reads its label attribute from disk and resolves the string to a canonical entry in the [[smack-label-registry-explained|label registry]]. That pointer is cached with the inode, so later checks need no attribute read and no string comparison.

### Step 4: Extra labels on files
- **mmap label:** before a process may memory-map the file, it must have **write** access to this label. This stops a confined process mapping a file from a less-trusted domain and using it as a hidden write channel.
- **exec label:** see Step 6.

### Step 5: Distrusting disks
On a filesystem marked **untrusted**, every file must carry the same label as the filesystem root. A hostile disk image can't bring in arbitrary labels that would grant access. Filesystems without extended attributes (FAT, some network filesystems) get a default label from a mount option; others set the root, floor, hat and transmute labels.

### Step 6: Process labels, fork and exec
Each process's credentials hold its current label (the subject in every check), a snapshot of its label at fork time (for audit), any label gained through a transmute change, a list of labels it may switch to by itself, and optional extra rules for itself. On **fork**, all of this is copied, so the child starts with exactly its parent's label. On **exec**, if the program file carries an **exec label**, the process switches to it. That's Smack's privilege transition, with no setuid bit needed, and because the *binary itself* must carry the target label, not only a policy rule, accidental escalation is less likely.

### Step 7: Changing labels explicitly
A process's label can be read, and written, through /proc. Writing requires the **MAC admin** capability, **or** the new label must be on the process's own list of permitted self-transitions (**relabel-self**), which only an administrator can set. That lets session managers drive label changes without holding full admin power.

## The picture

```text
 process [badge: "App"] ──create──▶ /data/shared/  (label "Shared", transmute on)
                                       └─ new file gets "Shared" (rule App→Shared has t)
 process [badge: "App"] ──create──▶ /home/app/     (no transmute)
                                       └─ new file gets "App"

 fork:  child badge = parent badge
 exec /usr/bin/helper  (exec label "Helper") ──▶ badge becomes "Helper"
 write /proc/self/attr/current "Other" ──▶ needs MAC admin or "Other" in relabel-self list
```

## Tradeoffs

- **What it gives you:** labels that persist with files on any filesystem supporting extended attributes; cheap checks after the first lookup; label changes only through deliberate, visible mechanisms; shared directories without rule sprawl.
- **What it costs / requires:** extended-attribute support, or a single default label for filesystems without it.
- **Where it bites:** a running process can't change its label freely. It must run a labelled binary or be on an administrator-approved relabel list. That's the point, but it means transitions must be planned into how programs are installed and launched.

## How it got here

- **2.6.25:** file label attribute and process labels in credentials.
- **3.x:** exec, mmap and transmute labels; exec transitions without setuid.
- **4.x:** the relabel-self interface with per-process rules, and the fork-time label snapshot for richer audit records.
- **5.x:** process label data moved into framework-managed security blobs.

## Related

- Technical version: [[smack-inode-and-task-labeling]]
- [[smack|Smack]], [[smack-access-engine-explained|Access engine]], [[smack-label-registry-explained|Label registry]], [[smack-network-labeling-explained|Network labelling]], [[smackfs|smackfs]]
- [[credentials-explained|Credentials]], [[process-model-explained|Process security model]], [[vfs-explained|VFS]], [[extended-attributes-and-acls-explained|Extended attributes]]
