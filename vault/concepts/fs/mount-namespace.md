---
title: "Mount Namespace"
category: concept
tags: [fs, namespaces, mount, vfs, containers, propagation]
subsystem: fs
kernel_version: "2.4.19"
researched: 2026-04-05
status: complete
sources:
  - https://lwn.net/Articles/689856/
  - https://lwn.net/Articles/690679/
  - https://lwn.net/Articles/159077/
  - https://docs.kernel.org/filesystems/sharedsubtree.html
  - https://man7.org/linux/man-pages/man7/mount_namespaces.7.html
---

# Mount Namespace

## Purpose

A mount namespace gives a process its own isolated view of the filesystem mount tree. Without namespaces, every process on a system shares a single global mount table — mounting or unmounting a filesystem affects all processes. Mount namespaces allow containers, sandboxes, and per-user environments to have entirely different filesystem topologies while sharing the same kernel and the same underlying storage.

## Mental Model

Think of the mount tree as a directed graph whose nodes are mount points (`struct mount`) and whose edges represent parent-child relationships within each namespace. The global kernel manages the *underlying* filesystems (superblocks, inodes, data), but each namespace maintains its own *view* — its own copy of the graph. Shared-subtree propagation is the mechanism for selectively synchronising parts of that graph across namespace boundaries: when a new filesystem is mounted under a `shared` node in one namespace, corresponding nodes in peer namespaces automatically grow the same branch.

## How It Works

### Creating a mount namespace

A process inherits its parent's mount namespace at `fork()`. A new, independent namespace is created by calling `clone(CLONE_NEWNS)` or `unshare(CLONE_NEWNS)`. Both paths ultimately call `copy_mnt_ns()` in `fs/namespace.c`, which:

1. Allocates a new `struct mnt_namespace` via `alloc_mnt_ns()`.
2. Calls `copy_tree()` to walk the current namespace's mount tree and clone every `struct mount` reachable from the root. `clone_mnt()` copies each individual mount.
3. Wires the new mounts into the same parent-child relationships they had in the source namespace.
4. Assigns the new namespace to the process's `nsproxy->mnt_ns`.

After this, the child process has an independent copy of the mount tree. Mounts it performs are invisible to the parent unless shared-subtree propagation is configured.

### struct mnt_namespace: the per-process mount table

```c
struct mnt_namespace {
    struct ns_common   ns;          /* generic namespace header (inum, ops) */
    struct mount       *root;       /* the root mount of this namespace */
    struct list_head   list;        /* all mounts in this namespace (via mnt_list) */
    spinlock_t         ns_lock;     /* protects the list */
    struct user_namespace *user_ns; /* owning user namespace */
    u64                seq;         /* monotonic sequence for /proc/self/mountinfo */
    wait_queue_head_t  poll;        /* polled by /proc/self/mountinfo readers */
    u64                event;       /* event counter for poll() wakeups */
    unsigned int       mounts;      /* number of mounts in this namespace */
    unsigned int       pending_mounts; /* mounts waiting to be propagated */
};
```

Each `struct mnt_namespace` owns a flat list of all its `struct mount` objects via `mount->mnt_list`. The `root` field points to the mount at `/`. All namespace-wide operations (listing mounts, cloning, pivot_root) iterate this list.

### struct mount: one mount instance

The kernel's internal mount structure (defined in `fs/mount.h`, not exported to drivers) represents one mounted filesystem at one location in one namespace:

```c
struct mount {
    struct hlist_node  mnt_hash;       /* in the global mount hash (mnt, dentry) → mount */
    struct mount       *mnt_parent;    /* parent mount */
    struct dentry      *mnt_mountpoint;/* dentry in parent where this is mounted */
    struct vfsmount    mnt;            /* the public part: mnt_root + mnt_sb + mnt_flags */
    struct mnt_namespace *mnt_ns;      /* containing namespace */
    struct mountpoint  *mnt_mp;        /* struct mountpoint at mnt_mountpoint */
    /* … propagation fields … */
    struct list_head   mnt_share;      /* peer group cyclic list (shared mounts) */
    struct list_head   mnt_slave_list; /* list of slave mounts */
    struct list_head   mnt_slave;      /* slave list entry (links to master) */
    struct mount       *mnt_master;    /* master mount (for slave) */
    int                mnt_group_id;   /* peer group ID shown in /proc/PID/mountinfo */
    /* … */
    struct list_head   mnt_list;       /* entry in mnt_namespace->list */
    struct list_head   mnt_child;      /* entry in parent->mnt_mounts */
    struct list_head   mnt_mounts;     /* list of child mounts */
    int                mnt_id;         /* unique mount ID */
    int                mnt_expiry_mark;/* for NFS expiry */
};
```

The public `struct vfsmount` (embedded in `struct mount`) carries only `mnt_root` (the dentry at the top of this mount), `mnt_sb` (the superblock), and `mnt_flags`. Path resolution uses `vfsmount` pointers to represent position; `container_of()` recovers the full `struct mount`.

The global mount hash table (`mount_hashtable`) maps `(parent vfsmount, mountpoint dentry)` → `struct mount`, enabling O(1) mount-point crossing during path lookup.

### Mount tree structure

The mount tree within one namespace is a forest of `struct mount` nodes. The root of the forest is `mnt_ns->root`. Each mount's `mnt_mounts` list contains its direct child mounts, and each mount's `mnt_child` is its entry in its parent's `mnt_mounts`. `mnt_parent` and `mnt_mountpoint` say *where* this mount is attached.

When a new filesystem is mounted (`do_mount()` → `do_new_mount()`), the kernel creates a new `struct mount`, attaches it under the target mount/dentry, and calls `attach_mnt()`. When the mount propagation system is engaged, `propagate_mnt()` additionally clones and attaches the new mount into peer and slave namespaces.

### Mount propagation: shared, slave, private, unbindable

Each mount has a propagation type stored in `mnt.mnt_flags`:

| Type | Flag | Behaviour |
|------|------|-----------|
| **Shared** | `MNT_SHARED` | Mount/unmount events propagate bidirectionally among all peers in the same peer group |
| **Slave** | `MNT_SLAVE` | Receives events from the master peer group; does not propagate back |
| **Private** | (default, no flag) | Neither sends nor receives propagation events |
| **Unbindable** | `MNT_UNBINDABLE` | Private + cannot be used as a bind-mount source |

The propagation type is set with `mount --make-shared`, `mount --make-slave`, `mount --make-private`, `mount --make-unbindable`, or equivalently via `mount(MS_SHARED/MS_SLAVE/MS_PRIVATE/MS_UNBINDABLE)`.

The kernel default is **private**. Modern Linux distributions (systemd) change the root to **shared** on boot, so that mounts made by system services become visible everywhere.

### Peer groups: shared mount implementation

All `struct mount` objects in the same peer group are linked in a cyclic doubly-linked list through `mnt_share`. The `mnt_group_id` is an integer assigned from a monotonic counter (`mnt_group_ida`); all members of a peer group share the same `mnt_group_id`. This ID is what `/proc/PID/mountinfo` reports as `shared:N`.

A new peer is added to a peer group when:
- A new mount namespace is cloned (`copy_mnt_ns`): `clone_mnt()` links the cloned mount into the source's `mnt_share` list.
- A bind mount is made on a shared mount: `bind_mount()` links the new mount into the source's peer group.

When a mount or unmount event occurs on a shared mount, `propagate_mnt()` / `propagate_umount()` iterate the peer group's `mnt_share` ring and perform the same operation on every peer.

### Slave mounts: one-way propagation

A slave mount does *not* join the master's `mnt_share` ring. Instead:
- `mount->mnt_master` points to some member of the master peer group.
- `mount->mnt_slave` links it into `mnt_master->mnt_slave_list`.

All slaves of a peer group are discovered by iterating `mnt_slave_list` on *every member* of the master's peer group (because `mnt_master` can point to any member). This means propagation algorithms must walk the full peer ring and collect all slaves, not just those directly on one member's slave list.

When an event occurs in the master peer group, `propagate_mnt()` uses a three-phase algorithm:

1. **Prepare**: For each destination (peer or slave), create a new `struct mount` tree without attaching it. Link all new mounts into a temporary list.
2. **Commit**: Attach all prepared mount trees to their destinations atomically.
3. **Abort**: If allocation failed in prepare, free all prepared mounts.

The three-phase design ensures that either all propagations succeed or none are committed, preventing partial states where some namespaces have the new mount and others don't.

### Unbindable: the "mount explosion" problem

Without unbindable mounts, repeated `rbind` on a namespace containing bind mounts would cause exponential growth. Consider:
- `/` is shared; `/mnt` has a bind of `/proc`; `/tmp` has a bind of `/mnt`.
- Cloning the namespace would clone `/mnt` and `/tmp`, then propagate them, then the propagated mounts would trigger further propagations.

An unbindable mount is excluded from `copy_tree()` / `rbind` operations, breaking the recursion. Systemd marks some internal mounts unbindable specifically to prevent this.

### pivot_root

`pivot_root(new_root, put_old)` swaps the mount at `/` for a new root. This is used by container runtimes (Docker, runc) to enter a container image:

1. The new root (the container's root filesystem) is bind-mounted inside the current root.
2. `pivot_root()` moves the current root to `put_old` and makes `new_root` the namespace's root.
3. The old root is unmounted, removing the host filesystem from the container's view.

`pivot_root()` is safer than `chroot()` because it updates both the namespace's mount table and the process's `fs->root` consistently. It is restricted to the initial user namespace (or user namespaces with `CAP_SYS_ADMIN`).

### Locking

Mount namespace operations use two locks:

- **`namespace_sem`** (`fs/namespace.c`): a read-write semaphore. Exclusive for all modifications to the mount tree (mount, umount, propagation, clone). Shared for reads that need a stable tree (e.g. `/proc/PID/mountinfo` generation). This is the primary lock for correctness.
- **`mount_lock`** (`fs/namespace.c`): a sequence lock (`seqlock_t`). Held briefly during mount-point crossings in path lookup and during `mntget`/`mntput`. Used by RCU-walk to detect mount table changes via `nd->m_seq`.

### /proc/PID/mountinfo

Each entry in `/proc/PID/mountinfo` shows:

```
36 35 98:0 /mnt1 /mnt2 rw,noatime master:1 - ext3 /dev/root rw
```

Fields: mount ID, parent ID, major:minor, root, mountpoint, options, optional tags (shared:N, master:N, peer:N, unbindable), separator, filesystem type, source, super options. The `shared:N` and `master:N` tags expose the peer group IDs, making propagation topology visible to userspace tools.

## Key Data Structures

**`struct mnt_namespace`** (`fs/mount.h`) — per-namespace state: root mount, flat list of all mounts, event counter for `poll()`.

**`struct mount`** (`fs/mount.h`) — one mount instance: parent, mountpoint dentry, embedded `vfsmount`, propagation lists (`mnt_share`, `mnt_slave_list`, `mnt_slave`, `mnt_master`), group ID, namespace pointer.

**`struct vfsmount`** (`include/linux/mount.h`) — the public, exported part of a mount: `mnt_root` dentry, `mnt_sb` superblock, `mnt_flags`.

**`struct mountpoint`** (`fs/mount.h`) — reference-counted wrapper around a mountpoint dentry; allows multiple mounts at the same dentry (stacked mounts).

## Key Functions / Entry Points

**`copy_mnt_ns(flags, ns, user_ns, new_fs)`** (`fs/namespace.c`) — creates a new namespace by cloning the source; called from `create_new_namespaces()`.

**`clone_mnt(old, root, flag)`** (`fs/namespace.c`) — clones one `struct mount`; links it into the source's peer group if `CL_PROPAGATION` is set.

**`do_mount(dev_name, dir_name, type, flags, data)`** (`fs/namespace.c`) — top-level mount syscall handler; dispatches to `do_new_mount()`, `do_remount()`, `do_bind_mount()`, etc.

**`propagate_mnt(dest_mnt, dest_mp, source_mnt, tree_list)`** (`fs/pnode.c`) — the three-phase propagation algorithm; walks peer groups and slave chains.

**`pivot_root(new_root, put_old)`** (`fs/namespace.c`) — swaps the namespace root.

**`mntget(mnt)` / `mntput(mnt)`** (`fs/namespace.c`) — increment/decrement `mnt->mnt_count`; `mntput` triggers lazy unmount when count reaches zero.

## Important Flags & Config Options

| Flag / Config | Meaning |
|---------------|---------|
| `CLONE_NEWNS` | `clone()`/`unshare()` flag to create a new mount namespace |
| `MS_SHARED` | make mount shared (joins or forms a peer group) |
| `MS_SLAVE` | make mount a slave of its current peer group |
| `MS_PRIVATE` | make mount private (no propagation) |
| `MS_UNBINDABLE` | make mount private + non-bindable |
| `MS_REC` | apply propagation type recursively to whole subtree |
| `MNT_SHARED` | internal `mnt_flags` bit indicating shared mount |
| `MNT_SLAVE` | internal `mnt_flags` bit indicating slave mount |
| `MNT_UNBINDABLE` | internal `mnt_flags` bit indicating unbindable mount |
| `/proc/PID/mountinfo` | human-readable view of a process's mount namespace |
| `/proc/PID/mounts` | legacy mount list (less detail than mountinfo) |

## Interactions with Other Subsystems

- **↑ Userspace**: `mount(2)`, `umount(2)`, `unshare(2)`, `clone(2)` with `CLONE_NEWNS`, `pivot_root(2)`; container runtimes (Docker, Podman, runc) are the primary consumers.
- **→ [[Path Lookup]]**: path resolution crosses mount boundaries via the `(vfsmount, dentry)` → `struct mount` hash table; `nd->m_seq` (sampled from `mount_lock`) validates mount table stability during RCU-walk.
- **→ [[Filesystem Registration]]**: `do_new_mount()` calls `get_fs_type()` to find the registered filesystem type and `vfs_get_tree()` to instantiate the superblock.
- **← User Namespace**: `FS_USERNS_MOUNT` allows mounts inside user namespaces; `pivot_root` requires initial namespace or `CAP_SYS_ADMIN`; the owning `user_namespace` is stored in `mnt_namespace->user_ns`.
- **→ Cgroups**: cgroupfs uses `MS_SLAVE` mounts extensively to allow each container to see only its own cgroup subtree.

## Design Decisions & Tradeoffs

**Shared subtrees over per-namespace mount events**: The 2006 shared-subtrees design (Viro, Ram Pai) rejected the simpler approach of just having fully isolated namespaces and instead added propagation so that system daemons (e.g. udev) mounting a new device in the host namespace could automatically populate mount points in all container namespaces. The cost is the complex propagation algorithm and the three-phase commit.

**Slave as one-way filter**: Slave mounts solve the "I want to see host mounts but not expose container mounts to the host" use case that `MS_SHARED` alone cannot satisfy. The asymmetry (slave receives but doesn't send) is exactly what a container runtime needs: the container sees new devices the host mounts, but the host doesn't see the container's internal mounts.

**Cyclic list for peer groups vs. a central registry**: Peer groups are represented as a circular linked list through `mnt_share`, not as a central list with a group ID pointing into it. This means adding/removing a peer is O(1) but iterating "all peers of mount X" requires a full ring walk. The tradeoff favours the common case (propagation is rare; most walks are short).

**mount_lock as a seqlock**: Path lookup crosses mount boundaries millions of times per second. Using a full spinlock for every mount crossing would be catastrophic for performance. The seqlock approach (`nd->m_seq`) lets path lookup read the mount table without taking any lock in the common case, at the cost of a retry when a mount table change is detected.

## How It Has Evolved

- **2.4.19** (2002): First implementation of mount namespaces (`CLONE_NEWNS`); namespaces were fully isolated with no propagation.
- **2.6.15** (2006): Shared subtrees introduced (Ram Pai, Al Viro): `MS_SHARED/SLAVE/PRIVATE/UNBINDABLE`, peer groups, `propagate_mnt()`.
- **2.6.26** (2008): `/proc/PID/mountinfo` added, replacing `/proc/PID/mounts` with richer propagation data.
- **3.8** (2013): User namespaces allowed unprivileged mounts of certain filesystems (`FS_USERNS_MOUNT`).
- **4.x**: `mount_lock` seqlock refined; `mntget`/`mntput` made SMP-scalable.
- **5.x**: `open_tree()`/`move_mount()` syscalls (part of the new mount API) allow detached mount trees to be built and atomically attached, integrating with the `fs_context` machinery.
- **6.5** (2023): "mount beneath" patches (`fs: allow to mount beneath top mount`) added `MOUNT_ATTR_BENEATH` to support inserting a mount below an existing one without unmounting it first.

## Further Reading

1. [Mount namespaces and shared subtrees — LWN.net](https://lwn.net/Articles/689856/)
2. [Mount namespaces, mount propagation, and unbindable mounts — LWN.net](https://lwn.net/Articles/690679/)
3. [Shared subtrees — LWN.net](https://lwn.net/Articles/159077/)
4. [Shared Subtrees — kernel.org docs](https://docs.kernel.org/filesystems/sharedsubtree.html)
5. [mount_namespaces(7) — Linux manual page](https://man7.org/linux/man-pages/man7/mount_namespaces.7.html)

## LKML Highlights

- **Shared subtrees introduction** — Ram Pai (2006): The original motivation was the "files-as-directories" use case for Reiser4 but the design was immediately recognised as the correct solution for container namespaces. The thread debated whether peer groups should be explicit objects vs. implicit cyclic lists (cyclic lists won for simplicity).
- **mount beneath** — Christian Brauner (2023, `lwn.net/Articles/927586/`): "Mount beneath" allows stacking a new mount below an existing one, enabling overlay mounts without umount/remount cycles. The key design debate was whether this should be a new mount flag or a new syscall; it became a new `open_tree()`/`move_mount()` flag.
