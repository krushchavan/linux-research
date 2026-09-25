---
title: "OverlayFS Copy-Up — Explained"
category: explained
original: "[[copy-up]]"
subsystem: overlayfs
tags: [explained, overlayfs, copy-on-write, atomicity]
converted: 2026-09-25
---

# OverlayFS copy-up, explained

> Plain-language companion to [[copy-up|the technical note]]. Same facts, fewer identifiers.

## The problem

In [[overlayfs-explained|OverlayFS]], the lower layers are read-only and shared, often by many containers at once. Yet processes expect to be able to write to any file they see. Making the lower layers writable would destroy the sharing; refusing writes ("read-only filesystem") would make the overlay useless.

The answer is to copy a file to the private upper layer the first time it's modified. That copy must never be seen half-done, even if the machine crashes in the middle, and it must bring along the file's parent directories and attributes.

## The idea in one paragraph

Copy-up is like a **fresh notepad laid over a printed form**. You never write on the form. The first time you want to write, you put the pad down (the copy-up); after that, all writing goes straight onto the pad, and the form stays clean for the next guest. To make the copy safe, OverlayFS builds it off to the side in a **work directory** and then **renames** it into place in one atomic step, so other processes see either no upper copy or a complete one.

## Step by step

### Step 1: Notice that a copy is needed
Every modifying path (writing, truncating, changing permissions or owner, making a hard link) first checks whether the file already has an upper copy. If not, it lives only in the lower layers and must be copied up before the operation continues.

### Step 2: Build the parent directories first
Copy-up doesn't start with the file itself. It walks from the file up towards the overlay's root, noting every directory missing from the upper layer, then creates them on the way back down. Where a new upper directory should hide lower contents, it's marked opaque.

Earlier versions created only the immediate parent, which allowed a race: a lookup could find the file while its parent didn't yet exist in the upper layer. Creating the whole ancestry first removes the race.

### Step 3: Copy off to the side
1. create a temporary file in the work directory, on the upper filesystem
2. move the data from the lower file with an in-kernel splice, a zero-copy path that avoids user-space buffers and double copying
3. copy permissions, owner, timestamps and extended attributes; security labels come along with the attributes

### Step 4: Commit with a rename
This is the key step. The temporary file is renamed to its final place in the upper layer. Because the work directory and the upper layer are on the same filesystem, the rename is a single atomic directory operation:
- a crash before the rename leaves an orphan in the work directory, cleaned up at the next mount
- a crash after it leaves a complete, valid upper file

Nothing half-copied is ever visible. The alternative, locking the parent directory for the whole copy, would have caused contention in busy multi-threaded container workloads.

### Step 5: Switch over
The overlay inode now points at the upper file, and a version counter is bumped so stale cached pages are dropped. From then on, every operation goes straight to the upper file; the lower one is ignored.

### Step 6: Making it durable
After copying the data, OverlayFS syncs the upper file before the rename, so a crash right afterwards doesn't lose it. A strict mode extends this to directories and metadata-only copies; a volatile mode skips syncing entirely for speed.

### Step 7: The metadata-only shortcut
With **metacopy** enabled, changes to metadata alone (permissions, owner, times) copy only the metadata, marked as a shell. Reads still come from the lower file, so containers keep sharing its cached pages, and the data is copied only when the file is first opened for writing. It's opt-in because, until that first write, the file's inode number differs from its data inode's, which can surprise tools such as rsync and backup software. See [[metacopy|metacopy]].

## The picture

```text
 write("/etc/foo")  — no upper copy yet
   1. ensure /etc exists in upper (create missing parents, top down)
   2. work/#tmp ◀── splice data ── lower /etc/foo
                ◀── copy mode, owner, times, xattrs
   3. fsync(work/#tmp)
   4. rename(work/#tmp → upper /etc/foo)      ← atomic commit
   5. overlay inode → upper file; bump version
   6. the write proceeds on the upper file
```

## Tradeoffs

- **What it gives you:** writes that never touch shared layers, crash-safe copies with no partial states, and attributes and security labels carried along.
- **What it costs / requires:** the first write to a big file copies all of it; the work and upper directories must share a filesystem; syncing costs latency unless turned off.
- **Where it bites:** a container that touches many large lower files pays a large one-off copy cost. Copy-up can't run on an fscrypt-encrypted upper layer, because the lower and upper directories' encryption contexts may differ.

## How it got here

- **3.18:** copy-up as the basic copy-on-write mechanism, always copying all data.
- **4.13:** with the index enabled, copy-up reconnects hard links instead of creating independent upper files.
- **5.2:** metacopy, deferring data until the first write (Amir Goldstein's 28-patch series, justified with container `chown` benchmarks).
- **5.8:** unnecessary copy-ups avoided for temporary unnamed files and anonymous mappings.
- **6.12:** fs-verity integration, with a digest of the lower file stored and checked.

## Related

- Technical version: [[copy-up]]
- [[overlayfs-explained|OverlayFS]], [[layer-stack|Layer stack]], [[metacopy|Metacopy]], [[whiteouts-and-opaque-dirs|Whiteouts and opaque directories]], [[redirect-dir-and-index|Redirects and index]]
- [[fs-explained|Filesystem subsystem (VFS)]], [[extended-attributes-and-acls-explained|Extended attributes]], [[fscrypt-explained|fscrypt]]
