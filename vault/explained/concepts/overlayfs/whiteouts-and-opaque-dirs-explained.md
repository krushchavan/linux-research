---
title: "OverlayFS Whiteouts and Opaque Directories — Explained"
category: explained
original: "[[whiteouts-and-opaque-dirs]]"
subsystem: overlayfs
tags: [explained, overlayfs, whiteouts, deletion, xattrs]
converted: 2026-09-25
---

# OverlayFS whiteouts and opaque directories, explained

> Plain-language companion to [[whiteouts-and-opaque-dirs|the technical note]]. Same facts, fewer identifiers.

## The problem

In [[overlayfs-explained|OverlayFS]] the lower layers are never modified, so a file that lives in a lower layer can't actually be deleted. Yet when a container deletes it, it must vanish from the container's view. The same goes for replacing a directory: if a container removes `/opt/app` and creates a new, empty `/opt/app`, the old lower contents mustn't reappear inside it.

Deletion therefore has to be recorded *somewhere else*, in the writable upper layer, in a way lookups can't miss and that stays cheap to check.

## The idea in one paragraph

Picture a whiteboard covered in **permanent marker** (the lower layer). You can't erase it, so you stick **white paper patches** over the drawings you want gone (whiteouts). From a distance, the drawing underneath has ceased to exist. To blank out a whole region, you cover it with a fresh sheet (an **opaque directory**), and nothing from underneath shows through that area at all.

## Step by step

### Step 1: Deleting a lower file creates a whiteout
When a lower-only file or directory is unlinked or removed, OverlayFS creates a **whiteout** in the upper layer at the same path. It takes one of two forms:
- a **character device numbered 0:0**, the traditional Unix convention inherited from earlier union filesystems. It's cheap and unambiguous, since nothing else would create a 0:0 device.
- a **zero-size regular file marked with a whiteout attribute**, for upper filesystems that can't hold device files (such as some network filesystems)

### Step 2: Lookup stops at a whiteout
This is the key step. During path lookup, each name is checked; a 0:0 device or a file carrying the whiteout attribute is treated as "deleted", and lookup reports that the name doesn't exist **without looking in the lower layers**. To programs, the file is simply gone. Security modules still see the whiteout being created and label it like any new file in that directory.

### Step 3: Replacing a directory makes it opaque
A new upper directory must not let the old lower directory's children show through as phantom entries the user thought were deleted. So when a directory is removed and re-created, or copied up in a way that should hide what's below, OverlayFS marks the upper directory **opaque**. When lookup enters an opaque directory, it doesn't descend into any lower layer for more contents.

### Step 4: Only scan where there are whiteouts
A second marker, the **impure** hint, is set on a directory as soon as a whiteout is created inside it. Directories without it are known to be clean, so lookups and listings skip the whiteout scan entirely. The cost moves from read time to write time (setting the hint when a whiteout is created), a big win for read-heavy container workloads where most directories are clean.

### Step 5: Unprivileged mounts
Normally these markers live in the `trusted.` attribute namespace, which only privileged processes can read or write, so ordinary users can't forge whiteouts. For unprivileged mounts inside user namespaces (5.11+), the same markers use the `user.` namespace instead. The logic is identical, but because `user.` attributes are visible to ordinary users, OverlayFS itself interprets them and never passes them through as-is, preventing privilege escalation through crafted attributes.

The upper filesystem must support whichever attribute namespace is used; filesystems like FAT, which have no extended attributes, can't be upper layers.

## The picture

```text
 lower /etc:  motd  passwd  hosts          lower /opt/app:  a  b  c
 upper /etc:  [motd = whiteout 0:0]         upper /opt/app: [opaque]  new.conf
 upper /etc marked "impure" (contains a whiteout)

 merged /etc:     passwd  hosts             (motd hidden)
 merged /opt/app: new.conf                  (a, b, c hidden: opaque stops the descent)
```

## Tradeoffs

- **What it gives you:** deletion and directory replacement without ever touching shared layers, and a cheap way to skip clean directories.
- **What it costs / requires:** an attribute-capable upper filesystem, extra entries in the upper layer for every deletion, and a careful security model for unprivileged mounts.
- **Where it bites:** deleting a lower file doesn't free any space, since the lower copy remains and a whiteout is added. Images whose layers delete many files still carry all of them.

## How it got here

- **3.18:** whiteouts (as 0:0 devices) and opaque directories from the first merge.
- **4.19:** the impure hint, avoiding whole-directory whiteout scans (Amir Goldstein; the thread debated whether the saving was measurable).
- **5.11:** `user.` attributes for unprivileged mounts, after long discussion of the security model.
- **5.15:** the attribute-marked regular-file whiteout, for upper filesystems without device files.

## Related

- Technical version: [[whiteouts-and-opaque-dirs]]
- [[overlayfs-explained|OverlayFS]], [[directory-merging-explained|Directory merging]], [[copy-up-explained|Copy-up]], [[layer-stack-explained|Layer stack]], [[redirect-dir-and-index-explained|Redirects and index]]
- [[extended-attributes-and-acls-explained|Extended attributes]], [[user-namespaces|User namespaces]], [[path-lookup-explained|Path lookup]]
