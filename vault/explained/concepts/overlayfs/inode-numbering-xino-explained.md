---
title: "OverlayFS Inode Numbering (xino) — Explained"
category: explained
original: "[[inode-numbering-xino]]"
subsystem: overlayfs
tags: [explained, overlayfs, xino, inode-numbers]
converted: 2026-09-25
---

# OverlayFS inode numbering (xino), explained

> Plain-language companion to [[inode-numbering-xino|the technical note]]. Same facts, fewer identifiers.

## The problem

Every file has an inode number, and many tools treat the pair (device, inode number) as a file's identity: `find -samefile`, rsync, backup software, hard-link detection. In [[overlayfs-explained|OverlayFS]], files come from different underlying filesystems, each numbering its inodes independently from its own starting point. Two different files from different layers can therefore show the same inode number, and a file's number can change across remounts. Tools then think unrelated files are the same, or miss files they've already seen.

## The idea in one paragraph

Give each filesystem a **department prefix**. Imagine each underlying filesystem as a company department issuing badge numbers from 1: without coordination, two employees from different departments both have badge 42. xino puts a small department code in front: department 1 issues 1-00042, department 2 issues 2-00042. Concretely, each filesystem gets a small ID, and OverlayFS packs that ID into the **unused high bits** of the real inode number. Numbers stop colliding, and you can tell at a glance which filesystem a file came from.

## Step by step

### Step 1: Number the filesystems
At mount time, each underlying filesystem that contributes to the overlay gets a small integer ID (0 for the upper layer), recorded with its layer.

### Step 2: Pack the ID into the inode number
This is the key step. When an overlay inode is first created, OverlayFS takes the real inode number and puts the filesystem ID into the top bits of the 64-bit number, keeping the real number in the lower bits. Most filesystems never use those top bits (ext4, XFS and btrfs fit comfortably in the low 48), so nothing is lost, and the calculation is pure arithmetic with no I/O. The result becomes the inode number that `stat` reports.

### Step 3: Stay stable across remounts
The ID comes from stable properties of the filesystem (its device number and UUID), not from mount order, so every mount produces the same numbers. Tools that remember (device, inode) pairs keep working across container restarts.

### Step 4: Degrade gracefully
If a filesystem's real inode numbers are so large that they already use the reserved top bits, those particular inodes fall back to unencoded, possibly non-unique numbers, and the kernel logs a warning. Failing outright would make xino unusable on such filesystems; in practice overflow only happens with billions of files, which is rare in container images.

### Step 5: Skip it when it's not needed
If all layers are on the same filesystem, inode numbers are already unique and no encoding is needed. The `auto` setting detects this and turns xino on at no cost, which is the usual case on developer machines.

### Step 6: Choose a mode
- **on:** always encode; mounting fails if a filesystem's inode numbers are too large
- **auto:** encode when it's safe (one shared filesystem, or all filesystems support file handles and have compatible inode sizes), otherwise fall back quietly
- **off:** raw numbers from each filesystem; collisions are possible

A kernel build option makes `auto` the default.

## The picture

```text
 upper   (ID 0):  real inode 42  ──▶  0 │ 42   = 42
 lower 1 (ID 1):  real inode 42  ──▶  1 │ 42   = 2^k·1 + 42
 lower 2 (ID 2):  real inode 42  ──▶  2 │ 42   = 2^k·2 + 42
                                  top bits│low bits
 three different files, three different numbers, same every mount
```

## Tradeoffs

- **What it gives you:** unique, remount-stable inode numbers with constant-time, stateless computation, so identity-based tools work inside containers.
- **What it costs / requires:** a cap on how many distinct filesystems one overlay can span (practically 16 to 64, far more than real workloads need); spare high bits in the underlying filesystems' inode numbers. A lookup table would avoid the cap but cost memory per inode and not survive remounts.
- **Where it bites:** with `off`, or when numbers overflow under `auto`, collisions can reappear, and tools may silently treat different files as the same.

## How it got here

- **4.17:** xino merged with the on/auto/off modes and single-filesystem detection (Amir Goldstein). The debate over always encoding (and failing on large-inode filesystems) versus auto-detecting ended with `auto` as the compromise.
- **4.19:** works with multiple lower layers, each with its own ID.
- **5.x:** the index feature's file handles also carry the filesystem ID, for remount stability.
- **6.x:** the auto default is enabled in most distribution builds.

## Related

- Technical version: [[inode-numbering-xino]]
- [[overlayfs-explained|OverlayFS]], [[layer-stack|Layer stack]], [[redirect-dir-and-index|Redirects and index]], [[copy-up-explained|Copy-up]]
- [[inode-cache-explained|Inode cache]], [[fs-explained|Filesystem subsystem (VFS)]]
