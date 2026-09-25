---
title: "OverlayFS — Explained"
category: explained
original: "[[overlayfs]]"
subsystem: overlayfs
tags: [explained, overlayfs, union-filesystem, containers, copy-on-write]
converted: 2026-09-25
---

# OverlayFS, explained

> Plain-language companion to [[overlayfs|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Containers start from images: a stack of read-only layers (a base OS, then libraries, then the application). Hundreds of containers may share the same base image, and each needs to write, delete and rename files as if it owned a private copy. Actually copying the image for each container would waste disk space, slow start-up, and stop containers sharing cached file data in memory.

What's needed is a filesystem that *looks* like one ordinary directory tree, but is built from shared read-only layers plus a thin private writable layer on top, where changes never touch the shared layers.

## The big picture

OverlayFS is like **a transparent sheet laid over a printed page**. Reading shows the combined picture. Writing marks the sheet, not the print. Erasing something leaves a smudge on the sheet (a **whiteout**) that hides what's underneath. The print stays pristine and can be shared with the next person, who lays down a sheet of their own.

```text
  process: read / write / rename / unlink
          │
        VFS
          │
      OverlayFS  (merged view)
     ┌────┼────────────────────────────┐
     ▼    ▼                            ▼
  upper layer (writable)   lower 1 (read-only) ▶ lower 2 ▶ … ▶ lower N
     ▲
  work dir (same filesystem as upper: atomic staging for copies)
```

Reads fall through to whichever layer has the file; writes go to the upper layer. If a file exists only below, it's first **copied up**, via the work directory, and then written normally.

## The pieces

### The layer stack
At mount time, OverlayFS takes a list of lower directories, an upper directory and a work directory. Lowers are ordered newest first, like image layers applied in sequence; when a name exists in several, the topmost wins. The upper and work directories must be on the **same filesystem**, so the rename that completes a copy-up never crosses devices. Lowers can be anything, even other overlays. Leaving out upper and work gives a read-only union. See [[layer-stack-explained|the layer stack]].

### Copy-up
This is the key mechanism. Before a lower file is written, truncated or has its metadata changed, it's promoted to the upper layer:
1. make sure every parent directory exists in the upper layer, creating any that are missing
2. create a temporary file in the work directory
3. copy the data across with an in-kernel zero-copy path, then clone the extended attributes
4. **rename** it into place in the upper tree

The rename is the commit, so a half-copied file is never visible; an interrupted copy just leaves a temp file that's abandoned at the next mount. From then on, the overlay inode points at the upper file and ignores the lower one. See [[copy-up-explained|copy-up]].

### Whiteouts and opaque directories
Lower layers can't be changed, so deleting a lower file creates a **whiteout** in the upper layer at the same path: a special device file (0:0), or on supporting filesystems a zero-size file with a marker attribute. Lookup sees it and reports "no such file" without looking further down.

A directory deleted and re-created mustn't reveal the old directory's contents, so the new one is marked **opaque**, which stops lookups from descending into lower layers. A separate hint marks merged directories that contain at least one whiteout, so clean directories don't need scanning. Unprivileged mounts use the `user.` attribute namespace instead of `trusted.`. See [[whiteouts-and-opaque-dirs|whiteouts and opaque directories]].

### Directory merging
Files follow "first match wins", but same-named **directories** are merged: a listing combines every layer's contents, with upper entries hiding lower ones of the same name. Lookup checks the upper layer first (a whiteout ends the search), then gathers matching directories from each lower layer. Every lookup in a merged directory may therefore touch several layers, so directories that exist only in the upper layer skip the lower walk. See [[directory-merging-explained|directory merging]].

### Redirects and the index
Two features close POSIX gaps:
- **Directory renames across layers:** moving a lower directory would mean moving all its lower children, which is impossible. With redirects on, only the directory itself is copied up, and it records its original lower path in an attribute that later lookups follow. Without redirects, such a rename fails with "cross-device".
- **Hard links:** without the index, copying up one name of a hard-linked file creates an independent upper file, and writes through one name no longer show through the others. With the **index** on, each copy-up is recorded under the work directory, keyed by the lower file's handle, so later copy-ups of other names link to the same upper file.

Both need the underlying filesystem to support NFS-style file handles. See [[redirect-dir-and-index|redirects and the index]].

### Inode numbers (xino)
By default, inode numbers aren't stable across remounts and can collide between layers, which confuses tools that identify files by (device, inode). **xino** gives each underlying filesystem a small ID and packs it into the unused high bits of the inode number, making numbers unique and persistent. If a filesystem uses very large inode numbers, xino falls back and warns. When all layers share one filesystem, no encoding is needed. See [[inode-numbering-xino-explained|inode numbering]].

### Metacopy
A container starting up may `chown` thousands of files. A full copy-up for each would copy gigabytes and break sharing of cached file data between containers. With **metacopy**, a metadata change copies up only the metadata, leaving a marked shell file in the upper layer, while reads keep coming from the lower file, so containers still share its cached pages. Data is copied only when the file is first opened for writing. Optionally, a fs-verity digest of the lower data is stored and checked on access (a mismatch gives an I/O error), so tampered lower layers are caught. See [[metacopy|metacopy]].

## A request's journey

A container writes to `/etc/hostname`, which exists only in the shared base image:

1. **Write arrives.** The VFS passes it to OverlayFS, which sees there's no upper copy yet.
2. **Parents first.** Copy-up makes sure `/etc` (and `/`) exist in the upper layer.
3. **Stage.** A temporary file is created in the work directory; the lower file's data is spliced in and its attributes cloned.
4. **Commit.** The temp file is renamed to `/etc/hostname` in the upper layer. The overlay inode now points at it.
5. **Write proceeds** against the upper file. Other containers on the same base image still see the original, untouched.

Deleting `/usr/lib/old.so` from a lower layer works differently: a whiteout appears in the upper layer, and lookups there now report the file missing, while the lower copy remains for everyone else.

## Tradeoffs

- **What it gives you:** cheap, fast container file systems from shared layers, with page-cache sharing across containers; small enough to be merged into mainline and widely adopted.
- **What it costs / requires:** documented POSIX deviations (no access-time updates on lower reads, unstable inode numbers without xino, cross-layer directory renames failing without redirects); a first write to a big lower file costs a full copy; the upper and work directories must share a filesystem.
- **Where it bites:** the index isn't on by default because it ties a mount to its filesystems, so hard links can silently split on copy-up. Metacopy adds attribute lookups on every access and conflicts with some other options. The upper layer can't sit on an fscrypt-encrypted filesystem.

## How it got here

- **2011 debate:** Miklos Szeredi's "good enough" union filesystem was questioned (did this even belong in the kernel, and was it complete enough?). Linus Torvalds backed it, arguing user-space filesystems were too slow for this. Earlier attempts (UnionFS, AUFS) had tried to handle every edge case and never merged.
- **3.18 (2014):** merged with upper/lower/work directories, copy-up, whiteouts and opaque directories. **4.0 (2015):** improvements that enabled Docker's overlay2 driver.
- **4.13–4.19 (2017–2018):** the index, xino, redirects, NFS export and POSIX improvements, and multiple lower layers.
- **5.2 (2019):** metacopy (Amir Goldstein's 28-patch series), fixing page-cache sharing broken by container `chown` storms.
- **5.11 (2021):** unprivileged overlay mounts using user attributes.
- **6.8–6.15 (2024–2025):** appending lower layers through the new mount API, specifying every layer by file descriptor, and stashing mount credentials. fs-verity checking for metacopy files landed around 6.12.

## Related

- Technical version: [[overlayfs]]
- [[layer-stack-explained|Layer stack]], [[copy-up-explained|Copy-up]], [[whiteouts-and-opaque-dirs|Whiteouts]], [[directory-merging-explained|Directory merging]], [[redirect-dir-and-index|Redirects and index]], [[inode-numbering-xino-explained|xino]], [[metacopy|Metacopy]]
- [[fs-explained|Filesystem subsystem (VFS)]], [[mount-namespace-explained|Mount namespaces]], [[user-namespaces|User namespaces]], [[fuse-explained|FUSE]]
- [[fscrypt-explained|fscrypt]], [[page-cache-explained|Page cache]], [[extended-attributes-and-acls-explained|Extended attributes]]
