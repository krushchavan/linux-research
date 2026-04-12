---
title: "Btrfs Send/Receive Protocol"
category: concept
tags: [btrfs, send-receive, backup, incremental, stream-format]
subsystem: btrfs
kernel_version: "3.6"
researched: 2026-04-12
status: complete
sources:
  - https://lwn.net/Articles/506244/
  - https://lwn.net/Articles/505111/
  - https://lwn.net/Articles/581558/
  - https://lwn.net/Articles/873232/
  - https://lwn.net/Articles/829312/
  - https://archive.kernel.org/oldwiki/btrfs.wiki.kernel.org/index.php/Design_notes_on_Send/Receive.html
  - https://docs.bugs.cc/btrfs/en/stable/dev/dev-send-stream.html
  - https://www.phoronix.com/news/Linux-6.0-Btrfs
---

# Btrfs Send/Receive Protocol

## Purpose

Btrfs send/receive exists to make snapshot-based incremental backup and replication practical. Given two read-only snapshots of the same subvolume — one already present at the destination and one to be transferred — the kernel can compute exactly what changed and emit a compact instruction stream that the receiver replays to produce the new snapshot. Without this mechanism every backup tool is forced to scan the entire directory tree comparing timestamps or checksums, which is slow and cannot take advantage of btrfs's internal extent-sharing metadata.

## Mental Model

Think of btrfs send like a database changelog or git diff applied at the filesystem level. The kernel walks both the parent snapshot tree and the new snapshot tree simultaneously, finds each differing item, and translates it into one of about twenty VFS operations: `mkfile`, `mkdir`, `write`, `clone`, `rename`, `unlink`, `chmod`, and so on. The result is a binary stream — written to a pipe or file — that reads as "to get from snapshot A to snapshot B, replay these operations in order." The receiver side (`btrfs receive` in userspace) simply calls the corresponding syscalls.

The critical insight is that **only the send side is in-kernel**. The receiver is a userspace program; it does not need its own ioctl. The stream is a self-contained instruction tape.

## How It Works

### Triggering a send: `BTRFS_IOC_SEND`

A send is initiated with the `BTRFS_IOC_SEND` ioctl on the read-only snapshot's mounted directory. The caller passes a `struct btrfs_ioctl_send_args`:

```c
struct btrfs_ioctl_send_args {
    __s64 send_fd;          /* writable fd to receive the stream */
    __u64 clone_sources_count;
    __u64 __user *clone_sources; /* subvol IDs that exist on destination */
    __u64 parent_root;      /* parent snapshot for incremental; 0 = full */
    __u64 flags;            /* BTRFS_SEND_FLAG_* bitmask */
    __u32 version;          /* requested stream version (0 = kernel default) */
    __u8  reserved[28];
};
```

`send_fd` is a writable file descriptor — typically the write end of a pipe — that the kernel feeds the stream into. `parent_root` names the snapshot that is assumed to already exist at the destination; the kernel will perform an incremental diff against it. `clone_sources` lists additional subvolume IDs whose extents the receiver has, enabling the kernel to emit `CLONE` commands instead of `WRITE` commands when copying data that already exists in those subvolumes. Omitting these and `parent_root` produces a **full send**: the entire snapshot is serialised from scratch.

The kernel validates that both the source and parent snapshots are read-only (`BTRFS_ROOT_SUBVOL_RDONLY`). Writable subvolumes are rejected because the tree-comparison algorithm requires a stable snapshot to compute a coherent diff.

### Tree comparison: `btrfs_compare_trees()`

For an incremental send the kernel calls `btrfs_compare_trees()` (in `fs/btrfs/ctree.c`), which walks both the parent B-tree and the send B-tree in parallel, comparing each leaf item by key. Three callbacks handle the three cases:

- **item only in the send tree** → new item, must be created at the destination.
- **item only in the parent tree** → deleted item, must be removed.
- **item in both trees with different content** → changed item, must be updated.

For a full send, `btrfs_compare_trees()` is called with a null parent; every item in the send tree is treated as new.

The callback for changed items is `changed_cb()` (in `fs/btrfs/send.c`). It dispatches based on item type — inode items, inode references, directory items, extent data, xattr items — and accumulates the set of changes for each inode before deciding what instructions to emit.

### Inode ordering and the orphan-inode problem

The tree walk proceeds in **inode-number order**, which is the natural key order of the btrfs tree. This creates a structural problem: when inode 1000 (a directory) is encountered, inode 999 (its parent directory) might not have been created yet in the output stream if 999 is a new inode with a higher creation order. More concretely: the path `/a/b/c` cannot be materialised until `/a/b` exists in the receiving filesystem, but `/a/b` might itself depend on a directory with a lower inode number that arrives later in the stream.

The solution is **orphan inodes** (called "waiting" or "delayed" inodes internally). When a file or directory cannot yet be placed at its final path — because some ancestor directory has not been created — it is first created at the filesystem root under a generated temporary name like `o<ino>-<gen>-0`. Later, when all dependencies are satisfied, a `RENAME` command moves it to its real path. The send code tracks these pending placements in a red-black tree (`pending_dir_moves`) keyed by inode number.

Directory renames are the trickiest case. If directory A is renamed to become a subdirectory of B, and B is also being renamed, the operations must be sequenced correctly or the receiver would try to move A into a path that does not exist yet. The kernel detects these cycles by recursively checking whether any ancestor of the target path also has a pending rename, deferring the current rename until its dependencies are resolved.

### Stream encoding: the send stream format

The stream written to `send_fd` begins with a 17-byte header:

```
"btrfs-stream\0"  (13 bytes)
version           (u32, little-endian; 1 or 2)
```

Following the header is an ordered sequence of **commands**. Each command has a 10-byte header:

```
length   (u32)  — total byte count of the command body, excluding this header
type     (u16)  — BTRFS_SEND_C_* constant identifying the operation
crc32c   (u32)  — CRC of the entire command (header + body), checksum field treated as 0 during computation
```

The command body is a sequence of **TLV (Type-Length-Value) attributes**:

```
attr_type  (u16) — BTRFS_SEND_A_* constant
attr_len   (u16) — byte count of the value that follows (v1 limit: 64 KiB)
value      (variable)
```

All integers are little-endian. The order of attributes within a command is not mandated; the receiver locates each attribute by type. Unknown attribute types may be silently ignored, providing forward compatibility.

### Commands: the instruction vocabulary

Version 1 defines the following commands:

| Command | Purpose |
|---|---|
| `SUBVOL` | Start-of-stream marker for a full send; carries subvol UUID and ctransid |
| `SNAPSHOT` | Start-of-stream marker for an incremental send; carries parent UUID |
| `MKFILE` | Create a regular file (at a temporary name if needed) |
| `MKDIR` | Create a directory |
| `MKNOD` | Create a device node |
| `MKFIFO` | Create a named pipe |
| `MKSOCK` | Create a Unix socket |
| `SYMLINK` | Create a symbolic link |
| `RENAME` | Rename or move a path |
| `LINK` | Create a hard link |
| `UNLINK` | Remove a file |
| `RMDIR` | Remove a directory |
| `SET_XATTR` | Set an extended attribute |
| `REMOVE_XATTR` | Remove an extended attribute |
| `WRITE` | Write file data at a given offset |
| `CLONE` | Clone a byte range from a source file/subvolume |
| `TRUNCATE` | Set file size |
| `CHMOD` | Change file permissions |
| `CHOWN` | Change file ownership |
| `UTIMES` | Set access, modification, and change timestamps |
| `END` | End of stream marker |
| `UPDATE_EXTENT` | Mark a range as present without data (used with `NO_FILE_DATA` flag) |

Version 2 (Linux 6.0) adds:

| Command | Purpose |
|---|---|
| `FALLOCATE` | Preallocate space, punch holes, or zero a range |
| `FILEATTR` | Transfer inode flags (FS_NODUMP_FL, FS_NOATIME_FL, etc.) |
| `ENCODED_WRITE` | Write a compressed or encrypted extent without decompressing |
| `ENABLE_VERITY` | Enable fs-verity on a file |

### Extent cloning vs. data writes

When the source snapshot shares extents with one of the listed `clone_sources`, the kernel emits `CLONE` commands rather than `WRITE` commands. A `CLONE` attribute bundle contains the source path, byte offset, and length; the receiver issues a `BTRFS_IOC_CLONE_RANGE` ioctl, which creates an extent sharing relationship on the destination filesystem without copying data. This is the mechanism that keeps incremental backups both small on the wire and space-efficient on disk.

The kernel finds clone opportunities by following extent backreferences (via `btrfs_find_all_roots()`) from the logical extent address of each data extent back to the inodes that reference it, then checking whether any of those inodes belong to the declared clone sources.

### Version 2 and `ENCODED_WRITE`

Protocol v1 has a hard limit of 64 KiB per TLV attribute because the length field is a `u16`. Compressed extents in btrfs can be up to 128 KiB, so they cannot be sent in a single v1 `WRITE` command when unmodified. The solution in v2 is to make the `DATA` attribute special: in a v2 command the `DATA` TLV has **no length field** at all; its size is calculated implicitly as `command_length - (header_size + sizes_of_preceding_tlvs)`. The command's 32-bit length field provides sufficient range. The `ENCODED_WRITE` command carries additional TLV attributes describing the compression algorithm, disk size, unencoded length, and offset so the receiver can write the extent using `BTRFS_IOC_ENCODED_WRITE` without decompressing.

To negotiate the version, the caller sets `flags |= BTRFS_SEND_FLAG_VERSION` and fills `version` in `btrfs_ioctl_send_args`. Old kernels ignore the unknown flag and produce a v1 stream; new kernels honour the request.

### Receiving the stream

`btrfs receive` is a userspace tool from btrfs-progs. It reads command headers from the stream, parses TLVs, and translates each command into the appropriate syscall or ioctl:

- `MKFILE` → `open(O_CREAT)`
- `WRITE` → `pwrite()`
- `CLONE` → `BTRFS_IOC_CLONE_RANGE` ioctl
- `ENCODED_WRITE` → `BTRFS_IOC_ENCODED_WRITE` ioctl
- `UTIMES` → `utimensat()`
- `SET_XATTR` → `setxattr()`
- `CHMOD` → `chmod()`

The receiver verifies the per-command CRC32C checksum before executing each command, so a truncated or corrupted stream fails safely rather than leaving the destination in a corrupt state.

## Key Data Structures

**`struct btrfs_ioctl_send_args`** (`include/uapi/linux/btrfs.h`) — passed to `BTRFS_IOC_SEND`; specifies the output fd, parent snapshot, and clone sources.

**`struct send_ctx`** (`fs/btrfs/send.c`) — large internal context struct tracking all state during a single send operation.
- `send_root` — the snapshot being sent
- `parent_root` — the reference snapshot (null for full send)
- `send_filp` — file pointer for `send_fd`
- `pending_dir_moves` — red-black tree of directory moves awaiting dependency resolution
- `waiting_dir_moves` — moves blocked on a specific inode
- `orphan_dirs` — set of dirs created at a temporary path

**`struct btrfs_send_stream`** (conceptual, described in `send.h`) — the on-wire format: a magic header followed by a sequence of length-prefixed, CRC'd command blocks, each containing TLV attributes.

## Key Functions / Entry Points

**`btrfs_ioctl_send()`** (`fs/btrfs/ioctl.c`) — ioctl handler; validates arguments, allocates `send_ctx`, calls `btrfs_send_subvol()`.

**`btrfs_send_subvol()`** (`fs/btrfs/send.c`) — top-level entry; emits `SUBVOL`/`SNAPSHOT` header, calls `full_send_tree()` or invokes `btrfs_compare_trees()` for incremental, then emits `END`.

**`btrfs_compare_trees()`** (`fs/btrfs/ctree.c`) — parallel B-tree walker; calls `changed_cb()` for each differing item.

**`changed_cb()`** (`fs/btrfs/send.c`) — dispatches per-item-type handler; accumulates per-inode changes; calls `process_recorded_refs()` to emit path-level operations.

**`process_recorded_refs()`** (`fs/btrfs/send.c`) — resolves renames, orphan placements, and hard links for one inode; emits `RENAME`, `LINK`, `UNLINK`, and `RMDIR` commands.

**`send_write_or_clone()`** (`fs/btrfs/send.c`) — decides whether to emit `WRITE` or `CLONE` for a data extent by following backrefs through clone sources.

**`send_cmd()`** (`fs/btrfs/send.c`) — serialises one command (header + TLVs) to the output buffer, finalises CRC, and calls `write_buf()` to flush to `send_fd`.

## Important Flags & Config Options

**`BTRFS_SEND_FLAG_NO_FILE_DATA`** — emit `UPDATE_EXTENT` instead of `WRITE` commands; used for change detection without transferring data content.

**`BTRFS_SEND_FLAG_OMIT_STREAM_HEADER`** — skip the magic header; useful for concatenating streams or testing.

**`BTRFS_SEND_FLAG_OMIT_END_CMD`** — skip the final `END` command; symmetric with the above.

**`BTRFS_SEND_FLAG_VERSION`** — honour the `version` field in `btrfs_ioctl_send_args` to negotiate protocol version (v1 or v2).

**`BTRFS_SEND_FLAG_COMPRESSED`** — (v2 only) enable `ENCODED_WRITE` for compressed extents.

## Interactions with Other Subsystems

- **↑ Userspace**: `btrfs send` issues `BTRFS_IOC_SEND`; `btrfs receive` calls `pwrite()`, `BTRFS_IOC_CLONE_RANGE`, `BTRFS_IOC_ENCODED_WRITE`, etc.
- **→ [[cow-b-tree-engine]]**: send traverses the CoW B-tree (the extent tree, inode tree, directory tree) via `btrfs_compare_trees()` and extent-item lookup.
- **→ [[multiple-b-trees]]**: the inode ref tree (`BTRFS_INODE_REF_KEY`) and dir item tree are the primary input to path reconstruction.
- **→ [[checksumming-and-data-integrity]]**: `ENCODED_WRITE` transfers pre-checksummed compressed extents, bypassing the normal write path and its checksum recalculation.
- **→ [[transaction-model]]**: the send ioctl takes a read lock on the subvolume root and reads within a consistent view of one transaction generation; it does not create or modify any transaction.
- **← [[subvolumes-and-snapshots]]**: send requires read-only snapshots; the snapshot infrastructure maintains the parent UUID and `ctransid` that identify the incremental base.

## Design Decisions & Tradeoffs

**Custom binary format over tar**: The original prototype used ustar/pax. Tar cannot represent btrfs-specific operations: clone ranges, inode flags, btrfs-specific xattrs, and stream versioning. The switch to a custom TLV format gave full control over the vocabulary of commands and attribute types, at the cost of needing a dedicated receiver tool instead of standard `tar`.

**Send-in-kernel, receive-in-userspace**: Kernel involvement is limited to tree traversal and stream generation, which requires deep access to internal B-trees and backreference resolution. The receive side is a sequence of standard VFS calls that any userspace program can issue. This asymmetry keeps the kernel attack surface small: a buggy or malicious stream cannot do anything the receiver's uid cannot already do.

**Inode-order traversal**: Walking in inode order is the natural order of the B-tree and avoids random seeks through large trees. The cost is the orphan-inode machinery to decouple creation order from path order. An alternative (tree order matching directory hierarchy) was considered but would require a second pass or significant buffering to handle arbitrary directory depths.

**64 KiB data limit in v1**: The TLV `u16` length cap was a pragmatic simplification when send was first written. It became a real constraint only when compressed extents (up to 128 KiB) needed to be forwarded verbatim in v2. The v2 fix (implicit trailing-data length) is backward-incompatible but cleanly solves the problem.

**No kernel receive ioctl**: There is no `BTRFS_IOC_RECEIVE`. Replaying the stream entirely in userspace was an intentional choice to avoid privileged stream processing in the kernel and to allow the receive tool to implement per-command error handling, logging, and transformation.

## How It Has Evolved

**3.6 (2012)**: Initial send/receive introduced by Alexander Block. Full and incremental sends, BTRFS_IOC_SEND, stream v1.

**3.8–3.15**: Series of correctness fixes for incremental send edge cases: premature `rmdir`, invalid rename ordering when both parent and child directories are renamed, orphan-inode path cache invalidation bugs.

**4.4**: `NO_FILE_DATA` flag added for faster change detection without data transfer.

**5.7**: `chattr` attributes (`FILEATTR`) added to the stream so inode flags like `NODUMP` survive round-trips.

**6.0 (2022)**: Stream v2 protocol introduced. Adds `ENCODED_WRITE`, `FALLOCATE`, `FILEATTR`, and `ENABLE_VERITY`; 32-bit command length field removes 64 KiB data limit; compressed-send support (`BTRFS_SEND_FLAG_COMPRESSED`) avoids decompress/recompress cycle.

**6.1**: Protocol v2 stabilised in btrfs-progs; send and receive tools gain `--proto` flag to negotiate version explicitly.

## Further Reading

1. [Btrfs send/receive — LWN.net (2013)](https://lwn.net/Articles/506244/) — original introduction, design rationale, and the tar-vs-custom-format decision.
2. [Experimental btrfs send/receive (kernel side) — LWN.net (2012)](https://lwn.net/Articles/505111/) — early patch series overview and operational model.
3. [Btrfs send/receive and ioctl() — LWN.net (2013)](https://lwn.net/Articles/581558/) — ioctl interface deep dive and incremental workflow.
4. [btrfs send stream v2 — LWN.net (2021)](https://lwn.net/Articles/873232/) — v2 protocol design and OTIME attribute.
5. [Send/receive compressed extents without decompressing — LWN.net (2021)](https://lwn.net/Articles/829312/) — ENCODED_WRITE background.
6. [Design notes on Send/Receive — btrfs Wiki](https://archive.kernel.org/oldwiki/btrfs.wiki.kernel.org/index.php/Design_notes_on_Send/Receive.html) — internal algorithm notes, orphan inodes, pending move trees.
7. [Send stream format — BTRFS docs](https://docs.bugs.cc/btrfs/en/stable/dev/dev-send-stream.html) — authoritative wire-format specification.

## LKML Highlights

- **Original send/receive patch series (2012)** — Alexander Block's initial RFC introduced `btrfs_compare_trees()`, `BTRFS_IOC_SEND`, and the custom stream format; the debate centred on whether to keep receive in-kernel or userspace (userspace won on security grounds).
- **Incremental send directory rename bugs (2013–2016)** — Multiple threads on linux-btrfs@vger.kernel.org addressed cases where renames of parent and child directories generated invalid operation sequences; each fix refined the `pending_dir_moves` logic.
- **Stream v2 and ENCODED_WRITE (2022)** — Omar Sandoval's series (`20220322013545.3framedatarev@suse.de` area) introduced the 32-bit length encoding and compressed send; key debate was around backward compatibility guarantees and whether the kernel should auto-negotiate version or require explicit opt-in (explicit opt-in won).
