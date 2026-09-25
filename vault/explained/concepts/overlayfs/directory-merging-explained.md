---
title: "OverlayFS Directory Merging — Explained"
category: explained
original: "[[directory-merging]]"
subsystem: overlayfs
tags: [explained, overlayfs, lookup, readdir, union]
converted: 2026-09-25
---

# OverlayFS directory merging, explained

> Plain-language companion to [[directory-merging|the technical note]]. Same facts, fewer identifiers.

## The problem

In [[overlayfs-explained|OverlayFS]], a file with the same name in several layers is easy: the highest layer's copy wins. Directories can't work that way. If an upper `/etc` simply hid the lower `/etc`, every file that existed only in the base image's `/etc` would vanish the moment the container created anything in `/etc`. A layered filesystem is only useful if same-named directories are **combined**.

Combining them has costs: lookups may have to search several layers, listings must remove duplicates, and deleted entries must stay hidden.

## The idea in one paragraph

Picture each layer as a **drawer in a filing cabinet**, with its own `/etc` folder. Opening the overlay's `/etc` is like tipping every matching folder onto one desk. If two drawers hold a file with the same name, the higher drawer's copy lies on top and the lower one stays hidden. Something in only one drawer shows up as is. If the top drawer contains a note saying "this file is deleted" (a **whiteout**), that name is left out entirely.

## Step by step

### Step 1: Look up one name
For every step of a path walk, OverlayFS resolves the name across layers:
1. **Check the upper layer first.** A whiteout means "deleted": stop and report that the name doesn't exist.
2. Otherwise, remember whatever the upper layer has.
3. **Walk the lower layers, topmost first.** Skip layers without the name. A non-directory counts only if nothing higher has been found (first match wins). A directory is always collected, since it may contribute entries.
4. **Build the result.** If directories were found in several layers, the overlay entry keeps a list of every contributing lower directory: a **merged directory**. If only one layer contributed, it refers to just that one.
5. **Follow redirects.** If the upper directory carries a redirect (left by a cross-layer rename), lookup follows it to the original lower path before collecting lower contributions.

The kernel's path walker receives one ordinary entry and never sees the layers.

### Step 2: List a merged directory
Listing combines every contributing layer and removes duplicates using a **set of names already shown**:
- walk the upper layer first, showing each entry that isn't a whiteout and recording its name
- walk each lower layer in order, skipping names already shown (from a higher layer) or whited out above, and showing the rest

A set, rather than sorting everything and merging, keeps the work proportional to the total number of entries and avoids buffering the whole listing first. The catch is that the order is upper-first rather than alphabetical, which POSIX allows but differs from a single-layer filesystem.

### Step 3: Skip the work when possible
This is the key step for performance. A directory created fresh in the upper layer, with no lower counterpart, is **pure upper**. A quick check of flags on the entry spots this, and lookup skips the lower layers entirely. In a running container most directories are created after start-up, so the common case costs almost nothing.

### Step 4: Only look for whiteouts where there are some
Directories that contain at least one whiteout carry an **impure** mark. Only for those does listing check the upper layer for a whiteout before showing each lower entry. Clean directories skip the check for free.

## The picture

```text
 upper /etc:   hostname*   [whiteout: motd]            (* = shadows lower)
 lower1 /etc:  hostname    motd     passwd
 lower2 /etc:  passwd      services

 lookup "passwd": upper? no → lower1 has it → first match wins → lower1/passwd
 lookup "motd":   upper has whiteout → "no such file"

 ls /etc (upper first, set of shown names):
   hostname(upper) · passwd(lower1) · services(lower2)
   skipped: lower1 hostname (already shown), motd (whited out), lower2 passwd (already shown)
```

## Tradeoffs

- **What it gives you:** the defining feature of layered images: each layer adds or changes files, and the directory tree is the union of all of them.
- **What it costs / requires:** lookups in merged directories may touch several layers; listings build a set of names; carefully ordered locking on the overlay and lower entries.
- **Where it bites:** listing order differs from single-layer filesystems. Deep stacks of lower layers make merged-directory lookups more expensive, which the pure-upper shortcut only partly hides. Merging file *contents* was never an option, since it would be meaningless for binary files.

## How it got here

- **3.18:** basic merging of one upper and one lower layer, with a linear scan for listings.
- **4.19:** multiple lower layers; entries hold a list of lower paths, and listings walk every layer.
- **5.x:** the impure mark and set-based duplicate removal, avoiding whiteout scans in clean directories.
- **6.8:** redirect handling refined so directories moved across layers merge correctly.

## Related

- Technical version: [[directory-merging]]
- [[overlayfs-explained|OverlayFS]], [[whiteouts-and-opaque-dirs|Whiteouts and opaque directories]], [[redirect-dir-and-index|Redirects and index]], [[layer-stack-explained|Layer stack]], [[copy-up-explained|Copy-up]]
- [[path-lookup-explained|Path lookup]], [[dentry-cache-explained|Dentry cache]], [[fs-explained|Filesystem subsystem (VFS)]]
