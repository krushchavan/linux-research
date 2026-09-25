---
title: "OverlayFS Layer Stack — Explained"
category: explained
original: "[[layer-stack]]"
subsystem: overlayfs
tags: [explained, overlayfs, layers, mount-options]
converted: 2026-09-25
---

# The OverlayFS layer stack, explained

> Plain-language companion to [[layer-stack|the technical note]]. Same facts, fewer identifiers.

## The problem

An [[overlayfs-explained|overlay]] is built from several directories: which ones take part, in what order, and which (if any) accepts writes? Without a clear answer fixed at mount time, there'd be no principled way to decide whose copy of a file wins when names collide, or where writes should go so the read-only layers stay untouched and shareable.

## The idea in one paragraph

Think of **transparencies stacked on an overhead projector**. The top one is the writable **upper** layer, the only one you can draw on. Below it are read-only **lower** layers. Looking down through the stack you see everything combined; where several transparencies have something in the same place, the uppermost wins. The lower transparencies never change, so another projector using the same lowers, with its own top sheet, shows its own picture. A **work directory** beside the upper layer gives scratch space for making changes atomically.

## Step by step

### Step 1: Name the layers at mount
The mount takes three things:
- **lower directories**, a colon-separated list ordered newest first. The leftmost matches the topmost image layer and the rightmost the base image, as in OCI container images. When a name appears in several lowers, the leftmost wins.
- an **upper directory**, the one writable layer, conceptually above all lowers. Every write, copy-up and whiteout lands here. Leave it out and the overlay is read-only, which is handy for merging several source trees (say, a squashfs root) without allowing writes.
- a **work directory**, which must be on the **same filesystem** as the upper.

### Step 2: Validate
The options are parsed and checked: upper and work are on the same filesystem, no layer sits inside another, and the underlying filesystems have what's needed (extended attributes, and file handles if the index is requested). Security modules also get to inspect the layer paths during the mount.

### Step 3: Build the stack
The layers go into an array: the upper at position 0, lowers at 1 to N. Each entry holds a reference to its filesystem's mount (keeping it alive for the overlay's lifetime) and a small filesystem ID used for [[inode-numbering-xino-explained|inode numbering]]. To find a real file, OverlayFS walks the array from top to bottom and stops at the first layer that has the name.

### Step 4: Why the work directory must sit next to the upper
This is the key step. When a lower file is first modified, a copy is built in the work directory and then **renamed** into the upper layer. A rename within one filesystem is a single atomic operation, so other processes see either no copy or a complete one, and a crash leaves at most an orphan in the work directory, cleaned up at the next mount. A copy across filesystems couldn't be atomic, and would be far more complex. The same-filesystem rule is the price. See [[copy-up-explained|copy-up]].

### Step 5: Data-only lower layers
Newer kernels allow lower layers, marked with a double colon, that hold only file **data**, not directory structure. They sit at the bottom of the stack and are consulted only for the data of metadata-only copies whose metadata lives in a normal layer above, letting metadata and data live on different devices.

## The picture

```text
            ┌──────────────────────┐
  writes ─▶ │ upper (writable)      │ ◀─ rename ─ work dir (same filesystem)
            ├──────────────────────┤
            │ lower 1  (newest)     │   lowerdir=L1:L2:L3
            │ lower 2               │   leftmost = topmost
            │ lower 3  (base image) │
            ├──────────────────────┤
            │ data-only lowers      │   only for metadata-only copies
            └──────────────────────┘
  lookup: top ─▶ down, first layer with the name wins
```

## Tradeoffs

- **What it gives you:** a simple, ordered stack that maps directly onto container image layers, clear rules for which copy wins, and crash-safe copies.
- **What it costs / requires:** upper and work on one filesystem; a flat ordered stack with merging done per directory at lookup, less general than older designs (AUFS, UnionFS) that merged trees recursively.
- **Where it bites:** colons in paths used to make the lower list ambiguous, which the newer mount API fixes by passing each layer separately. Read-only overlays weren't in the original design, so the code checks for a missing upper everywhere.

## How it got here

- **3.18:** one upper, one lower and a work directory, all required.
- **4.19:** multiple lower layers in a colon-separated list, prompted by Docker's need to stack many image layers.
- **5.11:** lower layers can use `user.` attributes, enabling unprivileged mounts.
- **6.8:** lower layers added one at a time through the new mount API, with no colon escaping.
- **6.13:** every layer (upper, work and lowers) can be given as an open file descriptor.

## Related

- Technical version: [[layer-stack]]
- [[overlayfs-explained|OverlayFS]], [[copy-up-explained|Copy-up]], [[directory-merging-explained|Directory merging]], [[inode-numbering-xino-explained|xino]], [[metacopy-explained|Metacopy]]
- [[filesystem-registration-explained|Filesystem registration and mounting]], [[mount-namespace-explained|Mount namespaces]]
