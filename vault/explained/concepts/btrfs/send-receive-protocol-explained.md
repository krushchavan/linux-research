---
title: "Btrfs Send/Receive Protocol — Explained"
category: explained
original: "[[send-receive-protocol]]"
subsystem: btrfs
tags: [explained, btrfs, send-receive, backup, snapshots]
converted: 2026-09-25
---

# Btrfs send/receive, explained

> Plain-language companion to [[send-receive-protocol|the technical note]]. Same facts, fewer identifiers.

## The problem

Backing up or replicating a filesystem incrementally usually means scanning every file and comparing timestamps or checksums against the last copy. That's slow on big trees, and it can't take advantage of what btrfs already knows: which data blocks are shared between snapshots, and exactly which metadata changed between them.

Given two read-only snapshots, an old one the destination already has and a new one, btrfs should be able to say precisely what changed, and send only that.

## The idea in one paragraph

Treat it like **`git diff` for a filesystem**. The kernel walks the old and new snapshots' trees side by side, finds every item that differs, and turns the differences into a stream of about twenty ordinary file operations: make a file, make a directory, write these bytes, clone this range, rename, unlink, change permissions, set times. The receiving side is a plain user-space program that replays the stream with normal system calls. Only the sending side lives in the kernel.

## Step by step

### Step 1: Start a send
A program asks the kernel to send a read-only snapshot, giving a writable file descriptor (often a pipe) for the output. Optionally it names a **parent** snapshot the destination already has (for an incremental send) and a list of other subvolumes the destination has (**clone sources**). With no parent, it's a full send of everything. Both snapshots must be read-only; comparing live, changing trees would not produce a coherent diff.

### Step 2: Compare the trees
The kernel walks both snapshots' B-trees in parallel, comparing items key by key, with three cases:
- in the new tree only: something to create
- in the old tree only: something to delete
- in both but different: something to change

Changes are gathered per inode (metadata, names, directory entries, file extents, extended attributes) before deciding which operations to emit.

### Step 3: Solve the ordering puzzle
This is the key difficulty. The walk goes in inode-number order, the tree's natural order, but paths don't follow that order: `/a/b/c` can't be created until `/a/b` exists, and `/a/b` may have a higher inode number that comes later in the walk.

So when something can't be put at its final path yet, it's created at the top with a temporary name, an **orphan**, and later a rename moves it into place once its parents exist. Pending moves are tracked in a tree. Directory renames are the hardest case: if A moves under B while B is also being renamed, the kernel checks for pending renames among the target's ancestors and delays A's move until they're done, so the receiver never tries to move something into a path that doesn't exist yet.

### Step 4: Share data instead of copying it
For file data, if the destination already has the same extent in one of the clone sources, the stream says **clone this range from that file** instead of sending the bytes. The receiver then creates a shared extent on its side, with no data copied. The kernel finds these by following each extent's back-references to the files that use it. This keeps incremental streams small and the backup space-efficient.

### Step 5: Encode the stream
The stream starts with a magic string and a version number, followed by commands. Each command has a length, a type and a CRC32C checksum, followed by **type-length-value** attributes in any order. Unknown attribute types can be ignored, so newer streams stay readable by older tools where possible.

Commands include: start of stream (full or incremental), make file, directory, device node, FIFO, socket or symlink; rename; hard link; unlink; remove directory; set or remove an extended attribute; write; clone; truncate; chmod; chown; set times; "range present but data omitted"; and end.

### Step 6: Version 2 (6.0)
Version 1 capped each attribute at 64 KiB, but btrfs compressed extents can be up to 128 KiB, so they couldn't be forwarded as they were. Version 2 lets the data attribute run to the end of the command without its own length field (the command's 32-bit length covers it). It adds **encoded write**, which sends a compressed extent without decompressing and recompressing it, plus preallocation and hole punching, inode flags, and enabling fs-verity. The caller opts in explicitly; older kernels ignore the request and produce version 1.

### Step 7: Receive
The user-space receiver reads each command, checks its CRC, and runs the matching system call: create and open for new files, positional writes, the clone-range call for clones, the encoded-write call for compressed extents, `utimensat`, `setxattr`, `chmod`, and so on. A truncated or corrupted stream fails cleanly rather than half-applying.

## The picture

```text
 old snapshot (destination has it)     new snapshot
         │                                  │
         └──── walk both trees in parallel ─┘
                        │ differing items, per inode
                        ▼
        ordering: not placeable yet? → create as orphan, rename later
        data: shared with a clone source? → CLONE, else WRITE (or ENCODED_WRITE)
                        │
                        ▼
  stream: [magic, version] [cmd len|type|crc] [attrs...] ... [END]
                        │  (pipe, file, ssh)
                        ▼
  btrfs receive (user space): open / pwrite / clone-range / rename / chmod / ...
```

## Tradeoffs

- **What it gives you:** incremental backups computed from the filesystem's own metadata, with shared data cloned instead of re-sent, and compressed data sent as-is (v2).
- **What it costs / requires:** read-only snapshots on both ends, a dedicated receiver instead of standard `tar` (tar can't express clones, inode flags or btrfs-specific attributes, which is why the early tar-based prototype was dropped), and complex ordering logic in the kernel.
- **Where it bites:** incremental sends with directories renamed into each other have produced a long series of edge-case bugs over the years. Keeping the receiver in user space means a bad stream can't do anything the receiving user couldn't already do, a deliberate security choice.

## How it got here

- **3.6 (2012):** send/receive introduced by Alexander Block, with full and incremental sends and the custom stream format; the receiver was kept in user space on security grounds.
- **3.8–3.15 and on to about 2016:** a run of fixes for incremental edge cases (premature directory removal, rename ordering, stale path caches).
- **4.4:** a "no file data" option for fast change detection without transferring content.
- **5.7:** inode flags carried in the stream.
- **6.0 (2022):** stream version 2 with compressed sends (Omar Sandoval), with explicit opt-in chosen over auto-negotiation. **6.1:** version 2 stabilised in the user-space tools.

## Related

- Technical version: [[send-receive-protocol]]
- [[btrfs-explained|Btrfs]]: the subsystem overview
- [[subvolumes-and-snapshots-explained|subvolumes-and-snapshots]]: the read-only snapshots being compared
- [[multiple-b-trees-explained|Btrfs B-trees]]: the trees being walked and the back-references used for clones
- [[checksumming-and-data-integrity-explained|Checksumming]]: encoded writes carry pre-checksummed compressed extents
- [[transaction-model-explained|transaction-model]]
