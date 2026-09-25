---
title: "Extended Attributes and ACLs — Explained"
category: explained
original: "[[extended-attributes-and-acls]]"
subsystem: fs
tags: [explained, fs, xattr, acl, security]
converted: 2026-09-25
---

# Extended attributes and ACLs, explained

> Plain-language companion to [[extended-attributes-and-acls|the technical note]]. Same facts, fewer identifiers.

## The problem

Classic Unix file metadata is fixed: one owner, one group, nine permission bits, some timestamps. Modern systems need much more attached to files: finer-grained permissions ("Alice can read, Bob can write"), security labels for SELinux, encryption policies, markers for overlay filesystems, and whatever applications want to record. None of these fit in the fixed fields, and none of them should need to know about the others.

## The idea in one paragraph

Let any file carry **name-value pairs**, called **extended attributes** (xattrs). Picture a file's inode as a manila folder: the front has the standard fields; extended attributes are **sticky notes on the back**, each with a labelled name like `user.comment`, `security.selinux` or `system.posix_acl_access` and an arbitrary value. The part before the dot (the **namespace**) decides who handles the note: one handler stores it, another enforces permissions, another passes it to a security module. **POSIX ACLs**, per-user and per-group permission lists, are the biggest user.

## Step by step

### Step 1: Four namespaces
| Namespace | Who may write | Typical use |
|---|---|---|
| user. | anyone with write access to the file | application metadata |
| system. | kernel / privileged | POSIX ACLs |
| security. | security modules | SELinux and AppArmor labels |
| trusted. | administrators only | container runtimes, overlay filesystem markers |

### Step 2: Dispatch by prefix
Each filesystem registers a small table of **handlers** at mount time, each claiming a prefix (or an exact name). When a program sets or reads an attribute, the kernel scans that table for the matching handler; if none matches, the operation isn't supported. The kernel itself never needs to understand what any attribute means.

### Step 3: The path of a `setxattr`
1. Resolve the file's path.
2. Check the privileges required for that namespace.
3. Find the handler by prefix.
4. **Ask the security module** (SELinux, AppArmor, Smack) whether this is allowed. This hook runs for *every* attribute operation, even `user.` ones, so security modules can veto or transform anything.
5. Call the handler, which writes the attribute its own way: a filesystem's normal storage, a security module's label logic, or the ACL parser.

Reading reverses this. Listing asks each handler which names to show, so some internal attributes (like encryption bookkeeping) stay hidden.

### Step 4: How ext4 stores them
- **Inside the inode:** modern inodes are bigger than the old 128 bytes, and leftover space at the end holds small attributes, costing no extra I/O beyond reading the inode.
- **In a separate block:** when that fills, the inode points to a 4 KiB attribute block. Entry descriptions grow from the front, values are packed from the back. Huge values (over 64 KiB) can spill into dedicated inodes.
- Namespace prefixes are stored as small numbers instead of text, to save space.
- Attribute blocks are **reference-counted and shared**: many files with identical attributes (say, all files in a container with the same SELinux label) can point at one block.

Btrfs, by contrast, stores attributes as ordinary items in its B-trees.

### Step 5: POSIX ACLs
An ACL is a list of entries, each a tag (file owner, a named user, owning group, a named group, the **mask**, or everyone else) plus read/write/execute bits. A file has an **access ACL** checked on every permission test; a directory can also have a **default ACL** that new files inherit.

### Step 6: Checking an ACL
This is the key step.
1. If the ACL only has owner, group and other entries, it's equivalent to ordinary permission bits and is checked that way at no extra cost.
2. Otherwise: the owner is checked against the owner entry. A matching **named user** entry is limited by the **mask**, and if that grants access, done. If no user entry matched, the group entries (owning group and named groups) that match the caller's groups are checked, again limited by the mask. Finally, "everyone else".

The mask bounds named users and all groups, but not the owner. That's a compatibility measure: old tools that change the group permission bits end up changing the mask, so they can't accidentally open up every group ACL entry.

### Step 7: Caching and inheritance
Parsing an ACL from its attribute on every permission check would be slow, so the parsed ACL is cached on the in-memory inode. Anything that could change it (`chmod`, `setfacl`) clears the cache. When a file is created in a directory with a default ACL, the kernel reads it, combines it with the process's umask, and writes the result onto the new file.

### Step 8: Security labels
Security modules both *check* every attribute operation and *store* their own labels in `security.` attributes. When a file is created, SELinux computes its label from the parent directory and the creating process and writes it automatically, which is how every file gets labelled with no user-space involvement.

## The picture

```text
 setxattr(file, "security.selinux", value)
      │
      ▼  privilege check for namespace
 handler table:  user. │ system. (ACLs) │ security. │ trusted.
      │ match "security."
      ▼
 security module hook: allowed? ──no──▶ error
      │ yes
      ▼
 handler stores it ──▶ in the inode's spare space, or a shared attribute block

 permission check with ACL:
   owner? → owner entry
   named user? → entry ∧ mask
   groups? → group entries ∧ mask
   else → other
```

## Tradeoffs

- **What it gives you:** arbitrary, independent metadata on any file; fine-grained permissions; persistent security labels; shared storage for identical attribute sets.
- **What it costs / requires:** every filesystem must register handlers (a small linear scan per operation); ACL caching needs careful invalidation.
- **Where it bites:** `user.` attributes aren't allowed on symlinks and device files, because anyone able to write `/dev/null` could otherwise pin unlimited data on it; relaxing that was debated in 2021 without resolution. The mask rules are genuinely non-obvious and often surprise administrators.

## How it got here

- **Before 2.6:** XFS, ReiserFS and ext2/3 each implemented ACLs separately.
- **2.6.0 (2003):** shared ACL infrastructure in the kernel, with one representation and one checking algorithm; the four-namespace model and security-label use followed during 2.6.
- **~3.8 (2013):** ext4 enabled ACLs by default when the filesystem supports them.
- **4.5 (2016):** handlers can match exact names, not just prefixes.
- **2020–2023:** Christian Brauner moved ACL handling from per-filesystem attribute handlers into one VFS-level API, centralising caching.
- **5.15 (2021):** extended attributes over NFSv4.2. A 2022 summit discussed using the attribute interface to query kernel objects such as mounts.

## Related

- Technical version: [[extended-attributes-and-acls]]
- [[fs-explained|Filesystem subsystem (VFS)]]
- [[lsm-framework|LSM framework]], [[selinux|SELinux]], [[smack|Smack]]
- [[fscrypt]]: stores encryption policies as hidden attributes
- [[overlayfs|OverlayFS]]: uses trusted. markers
- [[nfs|NFS]], [[btrfs-explained|Btrfs]], [[inode]]
