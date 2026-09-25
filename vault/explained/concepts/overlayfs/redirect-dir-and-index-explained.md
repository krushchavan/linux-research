---
title: "OverlayFS Redirect Dir and Index — Explained"
category: explained
original: "[[redirect-dir-and-index]]"
subsystem: overlayfs
tags: [explained, overlayfs, rename, hard-links, nfs-export]
converted: 2026-09-25
---

# OverlayFS redirects and the index, explained

> Plain-language companion to [[redirect-dir-and-index|the technical note]]. Same facts, fewer identifiers.

## The problem

Because [[overlayfs-explained|OverlayFS]] never changes its lower layers, two ordinary POSIX behaviours break:
- **Renaming a directory that has lower-layer contents.** Its children live at the old path in a read-only layer. Moving only the upper entry would leave lookups through the old lower path showing the children as if the rename never happened. So by default the rename fails with "cross-device link", and tools must fall back to copy-then-delete, losing atomicity.
- **Hard links.** Two names can share one lower file. Writing through one triggers a copy-up of that name only, creating a separate upper file; the other name still points at the lower original. From then on, writes through one name don't show through the other. The link is silently broken.

## The idea in one paragraph

Two opt-in features close these gaps. **Redirects** work like **forwarding mail**: after moving a directory, OverlayFS leaves a note on it saying where its lower contents really live, and lookups follow the note. The **index** works like a **library card filed under a book's serial number**: when the first name of a hard-linked file is copied up, a card is filed under the lower file's unique handle. When another name of the same file is copied up later, the card is found, and the new name becomes another link to the already-copied upper file instead of a second copy.

## Step by step

### Step 1: Renaming a directory with redirects on
1. copy up the source directory itself, without its children, which stay in the lower layers
2. rename it in the upper layer
3. record the directory's **original lower path** in a redirect attribute on its new upper entry

From then on, a lookup entering that directory sees the redirect and uses it to find the lower contents, instead of the directory's current path. To the user the directory moved cleanly, contents and all.

### Step 2: Choosing how far to trust redirects
- **on:** create and follow redirects
- **follow:** follow existing ones but don't create new ones, a conservative middle ground
- **nofollow / off:** don't follow redirects at all; renames of directories with lower contents fail with "cross-device"

Redirects are limited to privileged mounts by default: if unprivileged processes could write redirect attributes, they could point lookups at lower paths they shouldn't see. Redirects also change the upper layer in a way that can't be cleanly undone, so disabling the feature later, or moving to an older kernel, can leave inconsistent redirects behind. That's why many distributions ship "follow" rather than "on".

### Step 3: Copying up with the index on
This is the key step for hard links. The index is a directory inside the work directory. Before copying up a file:
1. encode an NFS-style **file handle** for the lower file, written as hex
2. look for an index entry with that name
3. **found:** another name of this file was already copied up, so make a hard link in the upper layer to that upper file, with no data copied and an accurate link count
4. **not found:** copy up as usual, then add an index entry that is itself a hard link to the new upper file

Both names in the upper layer are now true hard links to one file, and writes through either are visible through the other.

### Step 4: Why file handles
File handles survive remounts and work across different filesystems; inode numbers alone aren't stable enough, since a filesystem may reuse them. The same handles let an overlay be exported over NFS: with NFS export enabled, the overlay can turn an NFS client's handle back into the right file after a remount. The catch is that every underlying filesystem must support file handles, which rules out tmpfs and some network filesystems as lower layers. That's the main reason the index is off by default.

## The picture

```text
 REDIRECT:  mv /a/dir /b/dir   (dir has lower contents)
   upper /b/dir  [redirect → "/a/dir"]
   lookup /b/dir/x ─▶ follow redirect ─▶ lower /a/dir/x ✓

 INDEX:     lower: foo ═╗ same file ╔═ foo-link
   write foo:   handle H not in work/index → copy up → upper foo; index/H ⇒ upper foo
   write foo-link: index/H found → link upper foo-link ⇒ same upper file (no copy)
```

## Tradeoffs

- **What it gives you:** atomic directory renames across layers, and hard links that stay links after copy-up; the index also makes NFS export of overlays possible.
- **What it costs / requires:** redirect attribute lookups when entering redirected directories; file-handle support in every underlying filesystem for the index; an index directory to maintain.
- **Where it bites:** without the index, hard links break silently, which has surprised many developers. Redirects permanently mark the upper layer, making downgrades risky. A failed rename was judged better than silently inconsistent state, so both features are opt-in.

## How it got here

- **4.10:** redirects merged, enabling directory renames across layers (after a 2016 debate between Miklos Szeredi and Amir Goldstein over whether the attribute approach was POSIX-safe).
- **4.13:** the index merged, introduced as part of the NFS export work; hard-link preservation turned out to be what most users valued.
- **4.17:** xino and the index share the file-handle encoding.
- **4.19:** NFS export of overlays built on the index.
- **5.x:** "follow" semantics stabilised; "nofollow" added to ignore even existing redirects.

## Related

- Technical version: [[redirect-dir-and-index]]
- [[overlayfs-explained|OverlayFS]], [[copy-up-explained|Copy-up]], [[directory-merging-explained|Directory merging]], [[inode-numbering-xino-explained|xino]], [[metacopy-explained|Metacopy]]
- [[nfs-explained|NFS]], [[nfs-server-explained|NFS server (file handles)]], [[extended-attributes-and-acls-explained|Extended attributes]]
