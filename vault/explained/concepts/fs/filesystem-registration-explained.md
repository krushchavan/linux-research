---
title: "Filesystem Registration — Explained"
category: explained
original: "[[filesystem-registration]]"
subsystem: fs
tags: [explained, fs, vfs, mount-api, fs-context]
converted: 2026-09-25
---

# Filesystem registration and mounting, explained

> Plain-language companion to [[filesystem-registration|the technical note]]. Same facts, fewer identifiers.

## The problem

VFS knows nothing about ext4, tmpfs or NFS until each one tells it that it exists and how to be mounted. `mount -t ext4 /dev/sda1 /mnt` has to find the code that knows how to turn a block device into a live filesystem.

The original mount interface also had real problems: options arrived as one unparsed text string in a single page-sized buffer, error messages got lost, namespaces couldn't be passed in cleanly, and a remount that failed halfway couldn't be rolled back.

## The idea in one paragraph

Filesystem registration is a **plugin registry**. Each filesystem driver adds a row saying "I'm called ext4, here are my flags and callbacks". A mount looks the row up by name and calls back into the driver to build a **superblock** (one live instance of the filesystem). Since 5.1, mounting happens in **stages** through a *filesystem context*: create a context, feed it options one at a time (each checked and typed as it arrives), then build the superblock, then attach it. User space can drive those stages directly with new system calls.

## Step by step

### Step 1: Register
At module load (or at boot for built-in filesystems) the driver registers a descriptor: its **name**, **flags**, callbacks for setting up a mount context and tearing down a superblock, a description of the mount options it accepts, and the module that owns it. Registration adds it to a global linked list after checking for duplicate names. The list is short (around 100 entries), so a simple list is fine. `/proc/filesystems` shows it; entries marked `nodev` don't need a block device.

Flags set policy, for example: needs a block device; may be mounted by unprivileged users in a user namespace; don't keep cached names or inodes after unmount (for pseudo-filesystems); has a subtype (FUSE shows as `fuse.sshfs`); supports ID-mapped mounts.

Because the descriptor names its owning module, the module can't be unloaded while any mount uses it. Mounting an unknown type can auto-load a module by name.

### Step 2: The old way, still supported
Originally a filesystem had one mount callback that got the flags and the raw option text. It delegated to a helper matching its kind:
- block-device filesystems: find the device, reuse or create its superblock
- virtual filesystems like tmpfs: always a new superblock
- single-instance filesystems like sysfs and procfs: one superblock, shared by every mount
- internal pseudo-filesystems (pipes, sockets) that never appear in the mount table

All of them end in the filesystem's **fill-in** callback, which sets the block size, magic number and superblock operations, and creates the root inode and root directory entry.

### Step 3: The new way: a filesystem context (5.1)
This is the key change, by David Howells. Mounting now goes:
1. **create a context** and let the filesystem fill in its operations and private state
2. **parse options one at a time**: VFS splits the options and converts each to its declared type (number, flag, string), then hands it to the filesystem, which can reject a bad value right away
3. **build the superblock**, usually with a helper for block-device, per-mount virtual, single-instance or keyed filesystems. The helper looks for an existing matching superblock among this type's live instances or makes a new one, then calls the fill-in callback if it's new.
4. **wrap it in a mount** and attach it to the caller's mount namespace
5. **free the context**

The context carries everything before anything is committed: source device or server, credentials, user and network namespaces, flags, subtype, and whether this is a new mount, a remount or a submount. Validating options *before* allocating a superblock means an invalid option is a cheap, clean error, instead of a half-configured superblock needing careful cleanup.

Filesystems not yet converted are wrapped by a compatibility shim that feeds the old callback, so VFS itself uses the new path everywhere. It was a long migration: NFS, with 50+ options and three parallel parsing paths, was converted in 5.11.

### Step 4: Staged mounting from user space (5.2)
The same stages are exposed as system calls: open a context for a filesystem type, set options one by one (each returning its own specific error), create the superblock, turn it into a mount object, and finally move that mount into place in the tree. This gives precise error reporting, a way to pass namespaces as file descriptors, and a two-phase mount: build it first, attach it atomically after.

### Step 5: Tearing down
A superblock lives while any mount references it. When the last mount goes, the standard shutdown evicts its cached inodes, lets the filesystem release private state, removes the superblock from the lists, and calls the type's teardown (which, for block-device filesystems, also releases the device).

## The picture

```text
 module load ──▶ register "ext4" (name, flags, callbacks, options spec, owner)
                         │  global list  → /proc/filesystems

 mount -t ext4 /dev/sda1 /mnt   (or fsopen / fsconfig / fsmount / move_mount)
   │
   ├─ create context ──▶ ext4 sets up its private state
   ├─ option "ro"   ──▶ typed, checked, stored   (bad value → error now)
   ├─ option ...
   ├─ build superblock ──▶ reuse existing for this device, or new + fill-in
   ├─ wrap in a mount ──▶ attach at /mnt in the caller's namespace
   └─ free context

 last unmount ──▶ evict inodes → filesystem cleanup → release device
```

## Tradeoffs

- **What it gives you:** any number of filesystems pluggable by name, auto-loaded on demand, protected from unload while in use; with the context API, typed options, early and specific errors, clean remount, and container-friendly staged mounting.
- **What it costs / requires:** two coexisting APIs during a long migration, with a compatibility shim; a new set of system calls for user space to learn.
- **Where it bites:** the fill-in callback still does the real building work in both worlds, so the split between "prepare and validate" (context) and "commit and build" (fill-in) must be respected by each filesystem.

## How it got here

- **2.4:** a read-superblock callback and the global list.
- **2.6:** the mount callback and helpers for block, virtual, single-instance and pseudo filesystems.
- **3.x:** standard teardown helpers.
- **5.1 (2019):** filesystem contexts and typed option parsing (David Howells, after 14 revisions over several years).
- **5.2 (2019):** the staged mount system calls.
- **5.11 (2021):** NFS converted (Trond Myklebust). **6.x:** ID-mapped mount support declared at registration.

## Related

- Technical version: [[filesystem-registration]]
- [[fs-explained|Filesystem subsystem (VFS)]]
- [[superblock]]: what a mount builds
- [[core-in-memory-structures-explained|Core VFS objects]]
- [[mount-namespace-explained|mount-namespace]], [[lsm-framework|LSM framework]], [[nfs-explained|NFS]], [[fuse-explained|FUSE]]
