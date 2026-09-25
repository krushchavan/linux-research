---
title: "OverlayFS Metacopy — Explained"
category: explained
original: "[[metacopy]]"
subsystem: overlayfs
tags: [explained, overlayfs, metacopy, page-cache-sharing, fs-verity]
converted: 2026-09-25
---

# OverlayFS metacopy, explained

> Plain-language companion to [[metacopy|the technical note]]. Same facts, fewer identifiers.

## The problem

In [[overlayfs-explained|OverlayFS]], changing anything about a lower file normally triggers a full [[copy-up-explained|copy-up]]: data and metadata are copied to the upper layer first. That's fine for a write, but wasteful for a permission or ownership change. Container start-up often runs `chown -R` or `chmod -R` over thousands of files. A single `chmod` on a 500 MB shared library would copy all 500 MB.

Worse than the disk use, it breaks sharing. Containers built on the same base image normally share one cached copy of each file in memory. Once every container has its own upper copy, each needs its own cached pages.

## The idea in one paragraph

Metacopy is like updating a **library checkout card without taking the book off the shelf**. The record in your name (the metadata: owner, permissions, times, attributes) moves to the upper layer, but the book itself (the file data) stays on the shelf where everyone else can still read it. Only when you want to write in the book does the librarian photocopy it for you: the full data copy happens on the first write.

## Step by step

### Step 1: Copy only the metadata
With metacopy enabled, a metadata-only change to a lower file (permissions, owner, times, or an extended attribute) takes a shortcut:
1. create a new file in the upper layer carrying the new owner and permissions
2. mark it with a **metacopy** attribute meaning "I have no data of my own; get it from below"
3. optionally (with verity on), store a digest of the lower file's data in that same attribute

The 500 MB of data is never read. The upper layer holds a tiny record, and the lower layer still holds the data.

### Step 2: Read from below
This is the key step. When a process reads a metacopy file, OverlayFS sees the marker and hands out the **lower** file for the data. The page cache fills from the lower layer, and since every container on that image uses the same lower file, they all **share the same cached pages**. Nothing is duplicated. The main win was never disk space: it's the CPU, I/O and memory saved during container start-up. With 100 containers from one image, a full copy-up on every `chmod` of a shared library would mean 100 cached copies instead of one.

### Step 3: Copy the data on first write
When a metacopy file is first opened for writing, OverlayFS promotes the data:
1. create a temporary file in the work directory
2. splice the lower data into it
3. remove the metacopy marker
4. rename it over the metadata-only shell in the upper layer

This uses the same atomic work-directory-and-rename pattern as ordinary copy-up, so it's crash-safe too. Afterwards the upper file is self-contained and the lower one is no longer consulted.

### Step 4: Catch tampering (verity)
With **verity** turned on, the digest stored at metadata-copy time is checked when the file is read through the overlay, and a mismatch gives an I/O error. The upper layer can then be trusted while the lower layers (say, downloaded container images) are treated as possibly tampered with. **Require** mode refuses the mount if the lower layer can't be verified.

It's a whole-file digest kept in an attribute, rather than the block-by-block checking of fs-verity proper, because OverlayFS doesn't own the block layer. That's simpler, but weaker: a change to part of the lower file goes unnoticed until the next full-file read.

### Step 5: Keep metadata and data apart
Data-only lower layers (the double-colon syntax) exist mainly for metacopy: a metacopy file's data can come from a data-only layer at the bottom of the stack, so metadata and data can sit on different storage devices.

## The picture

```text
 chmod 644 /usr/lib/libbig.so   (500 MB, lower only)
   upper: libbig.so [owner, mode, times] + marker "metacopy (digest)"   ← a few bytes
   lower: libbig.so [500 MB data]  ◀── reads from every container (one shared cache)

 first open for write:
   work/#tmp ◀─ splice 500 MB ─ lower;  drop marker;  rename over upper shell
   from now on: upper file is self-contained
```

## Tradeoffs

- **What it gives you:** cheap `chown`/`chmod` storms, shared page cache across containers, and optional tamper detection for untrusted lower layers.
- **What it costs / requires:** an extra attribute check on every access, a more complex copy path, and incompatibility with NFS export and some redirect modes.
- **Where it bites:** until the first write, `stat` shows the upper file's inode number while data comes from the lower one. Tools that identify files by (device, inode), such as rsync and backup software, can misbehave, which is why metacopy is opt-in.

## How it got here

- **5.2:** metacopy merged: metadata-only copy-up for permission, owner, time and attribute changes (Amir Goldstein's 28-patch series; the inode-number change was the main debate, settled by making it opt-in).
- **5.8:** metacopy skipped for temporary unnamed files and private anonymous mappings.
- **6.8:** data-only lower layers, so metacopy data can live on separate devices.
- **6.12:** verity support: the marker attribute can carry a digest of the file (Amir Goldstein and Vivek Goyal, after debating whole-file versus per-block checking).

## Related

- Technical version: [[metacopy]]
- [[overlayfs-explained|OverlayFS]], [[copy-up-explained|Copy-up]], [[layer-stack-explained|Layer stack]], [[inode-numbering-xino-explained|xino]], [[redirect-dir-and-index|Redirects and index]]
- [[page-cache-explained|Page cache]], [[extended-attributes-and-acls-explained|Extended attributes]], [[fscrypt-explained|fscrypt]]
