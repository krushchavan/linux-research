---
title: "Mount Namespace — Explained"
category: explained
original: "[[mount-namespace]]"
subsystem: fs
tags: [explained, fs, namespaces, containers, mount-propagation]
converted: 2026-09-25
---

# Mount namespaces, explained

> Plain-language companion to [[mount-namespace|the technical note]]. Same facts, fewer identifiers.

## The problem

Originally every process on a Linux system saw one global tree of mounts: mount a USB stick and every process sees it. Containers and sandboxes need their own filesystem view: a different root, their own `/proc` and `/tmp`, and no view of the host's private mounts, while still sharing the same kernel and storage.

But complete isolation isn't always wanted either. When the host mounts a newly plugged-in device, containers may need to see it too. And the host shouldn't necessarily see what containers mount inside themselves.

## The idea in one paragraph

Give each process a **mount namespace**: its own copy of the tree of mounts. The filesystems underneath (superblocks, files, data) are shared; only the *view*, which mount is attached where, is per-namespace. **Shared-subtree propagation** then selectively keeps parts of these trees in sync: mounts marked **shared** pass new mounts back and forth among their peers, **slave** mounts receive from their master but don't send back, and **private** mounts do neither.

## Step by step

### Step 1: Creating a namespace
A child normally inherits its parent's namespace. Asking for a new one (through `clone` or `unshare`) copies the current tree: every mount is cloned and wired to the same parent-child relationships. From then on, mounts in one namespace are invisible in the other, unless propagation says otherwise.

### Step 2: What's in a namespace and a mount
A namespace holds its root mount, a list of all its mounts, its owning user namespace, a count, and an event counter that wakes anyone polling the mount list for changes.

Each mount records its parent mount, the directory it's attached to, the filesystem root and superblock it shows, its flags, its namespace, its children, its propagation links, a peer group number, and a unique mount ID. A global hash table maps (parent mount, directory) to the mount attached there, so path lookup crosses into a mount in constant time.

### Step 3: Propagation types
| Type | Behaviour |
|---|---|
| shared | mounts and unmounts propagate both ways among all peers |
| slave | receives from its master group, never sends back |
| private | neither sends nor receives (the kernel default) |
| unbindable | private, and can't be the source of a bind mount |

systemd switches the root to **shared** at boot, so mounts made by system services appear everywhere.

### Step 4: Peer groups
Shared mounts that should stay in sync form a **peer group**: they're linked in a ring and share a group number (shown as `shared:N` in the mount info file). A mount joins a peer group when its namespace is cloned or when it's bind-mounted from a shared mount. When something is mounted under one peer, the kernel walks the ring and does the same under every peer. Adding or removing a peer is cheap; finding all peers means walking the ring, which is fine because propagation is rare.

### Step 5: Slaves: one-way sync
A slave doesn't join the ring. It points at a member of its master group and sits on that member's list of slaves. To reach all slaves, propagation has to walk the whole master ring and each member's slave list. This is exactly the container case: the container sees devices the host mounts, but the host doesn't see the container's own mounts.

### Step 6: All or nothing
This is the key step for correctness. Propagating a mount to many places could fail partway (out of memory). So propagation runs in three phases:
1. **prepare** a new mount tree for every destination, without attaching any
2. **commit**: attach them all
3. or **abort**: free everything prepared if anything failed

No namespace ends up with the new mount while others don't.

### Step 7: Unbindable prevents mount explosions
With shared mounts, repeated recursive bind mounts can feed on each other and multiply exponentially. Marking a mount **unbindable** excludes it from recursive copies and breaks the cycle. systemd marks some internal mounts this way.

### Step 8: Switching root for containers
Container runtimes use `pivot_root`: bind-mount the container's root filesystem, swap it in as the namespace's root with the old root moved underneath, then unmount the old root so the host's filesystem disappears from the container's view. Unlike `chroot`, this updates both the namespace's mount table and the process's idea of its root consistently. It requires admin rights in the relevant user namespace.

### Step 9: Locking
A read/write semaphore protects every change to mount trees (and stable reads, such as generating the mount info file). Path lookup, which crosses mounts millions of times a second, doesn't take it: it samples a sequence lock and retries if the mount table changed meanwhile.

## The picture

```text
 host namespace                 container namespace (slave of host "/")
 /  (shared:1) ◀────peer ring───▶ /  (master:1)
 ├─ /mnt/usb  ← host mounts       ├─ /mnt/usb   ← propagated in (one way)
 └─ /home                         └─ /app  ← container mounts: host doesn't see it

 propagate: prepare trees for all peers & slaves → commit all | abort all
```

## Tradeoffs

- **What it gives you:** per-container filesystem views over shared storage, with controllable syncing so host events can reach containers without leaking container mounts back.
- **What it costs / requires:** a complex propagation algorithm with all-or-nothing commits, and propagation topologies that are hard to reason about.
- **Where it bites:** recursive bind mounts on shared trees can explode unless something is unbindable. The difference between shared, slave and private (and systemd's shared default) regularly surprises people setting up containers.

## How it got here

- **2.4.19 (2002):** mount namespaces, fully isolated with no propagation.
- **2.6.15 (2006):** shared subtrees (Ram Pai and Al Viro), originally motivated by a Reiser4 use case but immediately seen as right for containers; cyclic peer lists chosen for simplicity.
- **2.6.26 (2008):** the detailed mount info file showing propagation.
- **3.8 (2013):** unprivileged mounts of some filesystems inside user namespaces.
- **5.x:** detached mount trees built with the new mount API and attached atomically.
- **6.5 (2023):** mounting *beneath* an existing mount without unmounting it first (Christian Brauner).

## Related

- Technical version: [[mount-namespace]]
- [[fs-explained|Filesystem subsystem (VFS)]], [[core-in-memory-structures-explained|Core VFS objects]]
- [[filesystem-registration-explained|Filesystem registration and mounting]]
- [[path-lookup-explained|path-lookup]]: crossing mount points
- [[user-namespaces]], [[cgroups-explained|Control groups]], [[overlayfs-explained|OverlayFS]]
