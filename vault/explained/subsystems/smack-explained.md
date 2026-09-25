---
title: "Smack Subsystem — Explained"
category: explained
original: "[[smack]]"
subsystem: smack
tags: [explained, security, smack, mac, lsm]
converted: 2026-09-25
---

# Smack, explained

> Plain-language companion to [[smack|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Embedded products and single-purpose appliances often need strong **compartments**: the media player can't touch the phone book, a compromised network service can't read other apps' data, even when things run as root. SELinux can do this, but its policy language, compiler and toolchain are a lot to carry for a small system, and a policy daemon on an appliance is itself something to secure. What's wanted is mandatory access control whose whole policy fits in a short text file and needs no daemon.

## The big picture

Smack (Simplified Mandatory Access Control Kernel) puts a **postage stamp** (a short text label) on every process, file, socket and network packet, and keeps a **whitelist of allowed sender→receiver pairs**. A process stamped "A" can reach something stamped "B" only if a rule like "A B rw" allows it; otherwise access is denied. The kernel enforces it from the moment init starts.

```text
 system call (open / connect / kill …)
        │ LSM hook (~100 of them)
        ▼
  Smack hooks ── label lookup ──▶ label registry (one entry per label)
        │
        ├─ access engine: special labels, then subject's rule tree ── allow / deny ──▶ audit
        └─ network labels ──▶ NetLabel (CIPSO / CALIPSO) ──▶ packets
  admin ──▶ smackfs (/sys/fs/smackfs): rules, labels, network settings
```

## The pieces

### The label registry
Every label has exactly **one** canonical entry, so two files with the same label point to the same entry, and checks compare pointers instead of strings. The first time a label is seen (in a rule, a file attribute or a packet) the registry creates its entry once, pre-computing its network form and giving it an empty rule tree. Five reserved labels exist from boot. See [[smack-label-registry-explained|label registry]].

### The access engine
Every hook boils down to "may label S have access M to label O?". The engine first applies five built-in rules: star subject is denied everything, hat subject may read everything, floor objects are readable by all, star objects are open to all, and a label may always access itself. Otherwise it looks for an explicit rule in the subject's rule tree, and denies if there isn't one. A MAC-override capability can overturn a denial, and decisions can be audited. See [[smack-access-engine-explained|access engine]].

### Inode and task labelling
Files carry their label in an extended attribute, set to the creator's label when made, and cached on first read. Processes carry theirs in their credentials, copied on fork. Extra attributes add an **exec label** (switch label when running this program, with no setuid needed) and an **mmap label**. **Transmuting** directories make new files inherit the directory's label, so shared directories don't sprout a mix of labels. Untrusted filesystems must carry their root's label throughout. See [[smack-inode-and-task-labeling-explained|inode and task labelling]].

### smackfs
The administration interface: write "subject object rwxat" to load a rule, which takes effect immediately; ask whether an access would be allowed; map labels to network CIPSO values; set fixed labels for hosts; choose the ambient label for untagged packets; restrict who counts as a Smack administrator; and list labels a process may switch to itself. Writes need the MAC-admin capability. See [[smackfs-explained|smackfs]].

### Network labelling
Outgoing packets carry the sender's label in a CIPSO (IPv4) or CALIPSO (IPv6) option, encoded by [[netlabel-explained|NetLabel]]. On arrival, the label is decoded (or the ambient label used if there is none) and checked. Smack treats **sending as writing**: the sender's label needs write access to the receiver's. Hosts that don't speak CIPSO can be given fixed labels by address. See [[smack-network-labeling-explained|network labelling]].

## A request's journey

A process labelled "app" connects to a service labelled "server" on another Smack host:

1. **Connect.** The connect hook checks locally: may "app" write to the peer's label "server"? If not, the call fails before any packet leaves.
2. **Tag.** Outgoing packets carry a CIPSO option saying "app" (domain of interpretation 3 by default).
3. **Decode.** The receiving kernel decodes the tag back to its canonical "app" entry.
4. **Check.** This is the key moment: the receiver applies the **same** access engine it uses for files. May "app" write to "server"? The rule tree is consulted.
5. **Deliver or drop.** Allowed packets reach the server; others are dropped, and the decision can be audited.

The same engine answers a local file open: the file's cached label is the object, the process's label the subject, and one rule lookup decides.

## Tradeoffs

- **What it gives you:** mandatory access control that fits in a text file and needs only basic shell tools; fast pointer-based checks even with hundreds of labels; the same policy model for files, processes and the network.
- **What it costs / requires:** no roles, no type enforcement, no transitivity. Labels are only ever compared for equality, with no hierarchy, so every permission must be spelled out. Processes change labels only by running a labelled program or through an approved relabel list. That suits appliances, not general-purpose desktops.
- **Where it bites:** Smack still can't run fully alongside SELinux. The remaining obstacles are interfaces that can show only one module's label at a time (a process's current label in /proc, the peer-security socket option) and the single label a CIPSO packet can carry.

## How it got here

- **2.6.25 (2008):** merged as the second security module after SELinux (Casey Schaufler). Its arrival ended the debate over whether the LSM framework should stay, with Linus ruling that it would.
- **2.6.30:** CIPSO labelling through NetLabel, for cross-host policy.
- **3.x:** transmute settled; exec and mmap labels; long-label smackfs interfaces replacing the 7-character originals.
- **4.x:** relabel-self, IPv6 labelling with CALIPSO, and a bring-up mode that logs rather than blocks, to build policy incrementally.
- **5.x:** framework-managed blobs as part of the stacking work; per-network-namespace smackfs discussed but not merged.
- **Ongoing:** Schaufler's stacking patches, reviewed by Paul Moore. Smack is the main security module on Tizen, so Samsung and Intel work tends toward embedded and IoT needs.

## Related

- Technical version: [[smack]]
- [[smack-label-registry-explained|Label registry]], [[smack-access-engine-explained|Access engine]], [[smack-inode-and-task-labeling-explained|Inode and task labelling]], [[smackfs-explained|smackfs]], [[smack-network-labeling-explained|Network labelling]]
- [[security-explained|Security subsystem]], [[lsm-framework-explained|LSM framework]], [[selinux-explained|SELinux]], [[netlabel-explained|NetLabel]], [[linux-audit-explained|Audit]], [[credentials-explained|Credentials]], [[vfs-explained|VFS]]
