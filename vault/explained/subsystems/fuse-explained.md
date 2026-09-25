---
title: "FUSE — Explained"
category: explained
original: "[[fuse]]"
subsystem: fuse
tags: [explained, fuse, filesystems, userspace]
converted: 2026-09-25
---

# FUSE (Filesystem in Userspace), explained

> Plain-language companion to [[fuse|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Writing a filesystem normally means writing kernel code: hard to develop, dangerous to get wrong, and needing root to load. But many useful "filesystems" are really adapters: files reached over SSH, a database shown as a directory tree, cloud storage, an overlay. Their authors want ordinary user-space programs with ordinary libraries and debuggers, and ideally without needing privileges at all.

The challenge is making such a program look, to every application and to the kernel's own file machinery, exactly like a real filesystem, while surviving a slow, buggy or crashed program on the other end.

## The big picture

FUSE is a **synchronous request/reply channel** between the kernel and a user-space daemon, dressed up as a filesystem. Every file operation an application performs on a FUSE mount becomes a message the kernel sends to the daemon, which does the work (stat a file, talk to a network server, query a database) and sends a reply. The calling process waits meanwhile, as it would for a disk.

```text
  application: open / read / write / stat
          │
        VFS (the kernel's file layer)
          │
   FUSE kernel module ──▶ request queue ──▶ /dev/fuse ──▶ libfuse ──▶ daemon
          ▲                                     │                      │
          └──────── wake caller ◀── reply ◀─────┘ ◀────── result ◀─────┘
```

The kernel module registers a filesystem type, mounts with a file descriptor for the special device `/dev/fuse`, and implements every file operation by forwarding it as a FUSE message. On the daemon side, the libfuse library handles the message framing and calls the daemon's function for each operation.

## The pieces

### The connection
Each mounted FUSE filesystem has one **connection** object holding the request queues, a reference to the open device, and the capabilities agreed with the daemon. Before any real operation, the daemon and kernel do an **init handshake**: the daemon proposes a protocol version and a set of optional features (asynchronous reads, write-back caching, parallel directory operations and so on), and the kernel replies with what both understand. That agreement governs everything afterwards. See [[fuse-connection-explained|the connection]].

### The request queues
Many processes can be waiting on the daemon at once, so requests are organised into queues:
- **interrupts**, served first
- **forgets** (telling the daemon the kernel has dropped references to inodes), batched together
- **pending**, normal requests not yet read by the daemon
- **processing**, requests the daemon has read but not answered
- **in transfer**, requests being copied through the device

When the daemon reads from the device, it gets the highest-priority request, which moves from pending to processing. When it writes a reply, the kernel matches it to the request by a **unique ID** and wakes the waiting thread. See [[fuse-request-queue|the request queue]].

### The wire protocol
Every message starts with a fixed header. Requests carry length, operation code, unique ID, the target inode's node ID, and the caller's user, group and process IDs; replies carry length, an error code and the same unique ID. Each operation then has its own body: for example, a lookup sends a name and gets back the inode's attributes plus how long they can be cached.

The major version has been 7 since 2008; the minor version grows with each new operation. Operations are added but never removed, and the kernel avoids sending newer operations to an older daemon. See [[fuse-wire-protocol|the wire protocol]].

### Looking like a real filesystem
FUSE fills in the kernel's standard tables of filesystem operations with thin wrappers. Each one:
1. allocates a request with the right operation code
2. fills it from the kernel's arguments (for lookup: the parent's node ID and the name)
3. sends it and waits
4. translates the reply back into kernel structures

The daemon picks its own **node IDs** for inodes, so it can address them any way it likes (paths, database keys). The root is always node 1. Lookups and attribute replies include **time-to-live** values, letting the kernel cache attributes and name lookups for that long instead of asking on every `stat`. See [[fuse-vfs-integration|VFS integration]].

### Interruption and abort
A process stuck waiting for the daemon must still respond to signals, or a crashed daemon would leave threads hung forever:
- a **fatal signal** before the daemon has read the request cancels it at once
- if the daemon already has it, the kernel sends an **interrupt** message naming the request; the daemon should answer the original request with "interrupted" quickly, and after 2 seconds the kernel completes it with that error anyway
- **aborting** the connection (through a control file or a forced unmount) fails every pending and future request with an I/O error

## A request's journey

Opening `/mnt/fuse/file.txt` for reading:

1. **Lookup.** The kernel's path walk reaches `file.txt` and asks FUSE to look it up.
2. **Queue.** FUSE creates a lookup request (parent node ID plus name) and puts it on the pending queue. The calling process sleeps.
3. **Daemon works.** The daemon reads the request from the device, does its job (perhaps a `stat` on some underlying storage) and writes back the file's attributes and cache lifetimes.
4. **Wake.** The kernel matches the reply by unique ID, fills in the inode, and wakes the caller.
5. **Open.** This is the key step. The kernel then sends an open request, a second round trip; the daemon returns its own **file handle**, which the kernel stores with the open file and includes in every later read and write.

If a non-fatal signal arrives during a later read the daemon is already handling, the kernel queues an interrupt, the daemon cancels and replies "interrupted", and the application's `read` returns that error.

## Tradeoffs

- **What it gives you:** real filesystems written as ordinary programs, without kernel changes or (by default) root; flexible caching controlled by the daemon; and the same security-module checks as any other filesystem.
- **What it costs / requires:** at least one round trip between kernel and user space per uncached operation, with the caller blocked throughout. Returning "try again" instead was rejected as incompatible with normal file semantics. Traditional daemons need many threads blocked reading the device.
- **Where it bites:** a slow daemon directly stalls applications. By default only the mounting user can access the mount; letting others in (`allow_other`) and having the kernel check permission bits itself (`default_permissions`) must be enabled in the system's FUSE configuration. Write-back caching boosts performance but is risky for distributed filesystems, whose coherency depends on writes reaching the daemon immediately.

## How it got here

- **2.6.14 (2005):** merged after years out of tree (Miklos Szeredi). Security debates produced the rule restricting mounts to their owner by default.
- **2.6.26 (2008):** protocol 7.10, with access-check and create operations.
- **3.15:** a combined read-directory-plus-attributes operation.
- **4.2:** write-back caching for better write performance.
- **4.20:** server-side file copy. **5.4:** DAX, mapping files directly for persistent-memory-backed FUSE.
- **6.5 onwards:** an io_uring command interface so one thread per core can serve requests without blocking (still maturing); FUSE BPF, to handle some operations in the kernel without a round trip; and passthrough mode, where some operations go straight to an underlying file.

## Related

- Technical version: [[fuse]]
- [[fuse-connection-explained|Connection]], [[fuse-request-queue|Request queue]], [[fuse-wire-protocol|Wire protocol]], [[fuse-vfs-integration|VFS integration]]
- [[fs-explained|Filesystem subsystem (VFS)]], [[path-lookup-explained|Path lookup]], [[page-cache-explained|Page cache]]
- [[io_uring-explained|io_uring]], [[uring-cmd-passthrough-explained|io_uring command passthrough]], [[overlayfs|OverlayFS]]
- [[network-filesystems-overview-explained|Network filesystems]]
