---
title: "Filesystem Registration"
category: concept
tags: [fs, vfs, file_system_type, mount, superblock, fs_context]
subsystem: fs
kernel_version: "2.4+"
researched: 2026-04-05
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://www.kernel.org/doc/html/latest/filesystems/mount_api.html
  - https://lwn.net/Articles/780267/
  - https://lwn.net/Articles/753473/
  - https://lwn.net/Articles/57369/
  - https://linux-kernel-labs.github.io/refs/heads/master/labs/filesystems_part1.html
---

# Filesystem Registration

## Purpose

Every filesystem driver must announce its existence to the VFS before it can be mounted. Registration is the mechanism by which a driver supplies its name, flags, and callbacks to the kernel's global filesystem table, making it mountable by name (e.g. `mount -t ext4`). Without registration, the VFS has no way to locate the code that knows how to build a superblock from a block device or memory.

## Mental Model

Think of filesystem registration as a plugin registry. The VFS is the plugin host — it defines the contract (struct file_system_type, struct super_operations, struct file_operations) but knows nothing about ext4 or tmpfs until each driver registers. Registration installs a row in the registry. Mount requests look up that row by name and call back into the driver to instantiate a superblock. Unmount tears down the instance; unregistration removes the row when the module unloads.

## How It Works

### Registration: adding to the global filesystem table

A filesystem driver calls `register_filesystem(struct file_system_type *fs)` at module init (or at boot for built-ins). This function acquires `filesystem_lock` (a simple spinlock) and walks a singly-linked list rooted at `file_systems` to check for name collisions, then appends the new entry by updating the `next` pointer of the last element. Each `file_system_type` has a `next` pointer that serves as the list link. The entire list is protected by `filesystem_lock` for writes and by `file_systems_lock` (a read-write lock) for reads.

`unregister_filesystem()` reverses the process: it finds the entry by name, splices it out of the linked list, and returns. If any superblock instance of this filesystem is still live, the caller is responsible for ensuring none exist before unregistering (module refcounting via `owner = THIS_MODULE` handles this automatically: the module cannot be unloaded while any mount holds a reference to its code).

Registered filesystems are visible at `/proc/filesystems`. A line beginning with `nodev` indicates the filesystem does not require a block device (`FS_REQUIRES_DEV` is absent).

### struct file_system_type: the registration descriptor

```c
struct file_system_type {
    const char   *name;          /* "ext4", "tmpfs", "nfs", … — key used by mount(2) */
    int           fs_flags;      /* FS_REQUIRES_DEV, FS_USERNS_MOUNT, FS_NO_DCACHE, … */
    int           (*init_fs_context)(struct fs_context *);  /* modern API: populate fc->ops */
    const struct fs_parameter_spec *parameters;             /* option spec for fs_parse() */
    struct dentry *(*mount)(struct file_system_type *, int, /* legacy API: superceded by */
                            const char *, void *);          /* init_fs_context in 5.1 */
    void          (*kill_sb)(struct super_block *);         /* unmount cleanup */
    struct module *owner;        /* THIS_MODULE — prevents unload while mounted */
    struct file_system_type *next;    /* linked list link (managed by register/unregister) */
    struct hlist_head fs_supers; /* all live super_blocks of this type */
    /* … lock class keys omitted … */
};
```

`fs_flags` controls VFS policy:

| Flag | Effect |
|------|--------|
| `FS_REQUIRES_DEV` | mount(2) must supply a block device; VFS rejects deviceless mounts |
| `FS_USERNS_MOUNT` | unprivileged (user-namespace) mounts allowed |
| `FS_NO_DCACHE` | do not keep dentries across umount (used by procfs-style pseudo-fses) |
| `FS_NO_ICACHE` | do not keep inodes across umount |
| `FS_HAS_SUBTYPE` | filesystem has a subtype (e.g. FUSE uses "fuse.sshfs") |
| `FS_BINARY_MOUNTDATA` | legacy: mount data is a binary blob, not a text option string |
| `FS_RENAME_DOES_D_MOVE` | filesystem handles the dentry tree rearrangement itself |
| `FS_ALLOW_IDMAP` | filesystem supports idmapped mounts |

### The mount lifecycle: legacy path (pre-5.1)

In the legacy design (still supported today via a wrapper), `file_system_type.mount()` was the single callback. When the kernel received a `mount(2)` syscall, it called the registered `mount()` function, passing the flags and the raw text option string from userspace.

The `mount()` function delegated to one of four VFS-provided helpers depending on the filesystem's requirements:

- **`mount_bdev(type, flags, dev, data, fill_super)`** — for block-device filesystems (ext4, xfs). Looks up the block device, allocates or reuses a superblock via `sget()`, then calls `fill_super` if the superblock is new.
- **`mount_nodev(type, flags, data, fill_super)`** — for virtual filesystems with no persistent device (tmpfs, ramfs). Always allocates a new superblock.
- **`mount_single(type, flags, data, fill_super)`** — for filesystems with a single global instance (sysfs, procfs). Creates one superblock at first mount; subsequent mounts increment the refcount and return the same superblock.
- **`mount_pseudo(type, name, ops, dops, magic)`** — for kernel-internal pseudo-filesystems (pipefs, sockfs) that never appear in the mount table.

All of these eventually call `fill_super(sb, data, silent)`, the filesystem's callback to initialise the superblock struct:

```c
static int myfs_fill_super(struct super_block *sb, void *data, int silent)
{
    struct inode *root_inode;

    sb->s_blocksize      = PAGE_SIZE;
    sb->s_blocksize_bits = PAGE_SHIFT;
    sb->s_magic          = MYFS_MAGIC;
    sb->s_op             = &myfs_super_ops;   /* superblock operations vtable */
    sb->s_time_gran      = 1;

    root_inode = new_inode(sb);
    /* initialise root inode … */
    sb->s_root = d_make_root(root_inode);     /* creates the root dentry */
    return 0;
}
```

After `fill_super` returns, the VFS installs the returned dentry as the mount point and the superblock is live.

### The modern path: fs_context and init_fs_context (5.1+)

The legacy `mount()` + text-string interface had deep problems: mount options were unparsed text passed through a single PAGE_SIZE buffer, error messages were lost, namespace references couldn't be passed programmatically, and remount couldn't roll back on failure. Linux 5.1 introduced the `fs_context` API to fix all of these.

A filesystem now implements `init_fs_context(struct fs_context *fc)` instead of (or in addition to) `mount()`. When the VFS needs to mount or remount, it allocates a `struct fs_context`, calls `init_fs_context()` to let the filesystem populate `fc->ops` (its operation table) and `fc->fs_private` (private parsed state), then drives the following lifecycle:

```
fs_context_for_mount()          ← allocate + init_fs_context()
  vfs_parse_fs_param()  ×N      ← per-option calls to fc->ops->parse_param()
  vfs_get_tree()                ← fc->ops->get_tree() → builds superblock
  vfs_create_mount()            ← wraps the superblock in a mount struct
put_fs_context()                ← calls fc->ops->free(); releases fc
```

The `struct fs_context` carries all configuration before the superblock is committed:

```c
struct fs_context {
    const struct fs_context_operations *ops;  /* filesystem vtable */
    struct file_system_type *fs_type;
    void             *fs_private;    /* filesystem's parsed option state */
    struct dentry    *root;          /* set by get_tree(); the new superblock root */
    struct user_namespace  *user_ns;
    struct net       *net_ns;
    const struct cred *cred;         /* mounter's credentials */
    char             *source;        /* block device path or NFS server string */
    char             *subtype;       /* FUSE subtype shown in /proc/mounts */
    unsigned int      sb_flags;      /* MS_RDONLY etc., translated from mount(2) flags */
    enum fs_context_purpose purpose; /* FS_CONTEXT_FOR_MOUNT / _RECONFIGURE / _SUBMOUNT */
};
```

`struct fs_context_operations` is the per-filesystem vtable:

```c
struct fs_context_operations {
    void   (*free)(struct fs_context *);         /* called by put_fs_context() */
    int    (*dup)(struct fs_context *, struct fs_context *);
    int    (*parse_param)(struct fs_context *, struct fs_parameter *); /* one option */
    int    (*parse_monolithic)(struct fs_context *, void *);           /* legacy blob */
    int    (*get_tree)(struct fs_context *);     /* build the superblock */
    int    (*reconfigure)(struct fs_context *);  /* remount */
};
```

`parse_param()` is called once per option — the VFS has already split the option string into typed `struct fs_parameter` values using `fs_parse()` and the `parameters` descriptor array. This means the filesystem receives a typed `u32`, `bool`, or string rather than an unparsed substring, and can return a meaningful error early if the value is invalid.

`get_tree()` replaces the old `fill_super` role. Filesystems typically delegate to one of four helpers:

| Helper | For |
|--------|-----|
| `get_tree_bdev(fc, fill_super)` | block-device filesystems |
| `get_tree_nodev(fc, fill_super)` | virtual filesystems with per-mount instances |
| `get_tree_single(fc, fill_super)` | single-instance (e.g. sysfs, procfs) |
| `get_tree_keyed(fc, fill_super)` | multiple superblocks keyed on `fc->s_fs_info` |

Each helper calls `sget_fc(fc, ...)` to either find an existing matching superblock in `file_system_type.fs_supers` or allocate a new one, then calls `fill_super` if it's new.

### New userspace mount API: fsopen/fsconfig/fsmount (5.2+)

The `fs_context` internals also enabled a new set of syscalls that expose the staged mount process to userspace:

```
fd = fsopen("ext4", 0);                      /* create an fs_context */
fsconfig(fd, FSCONFIG_SET_STRING, "source", "/dev/sda1", 0);
fsconfig(fd, FSCONFIG_SET_FLAG, "ro", NULL, 0);
fsconfig(fd, FSCONFIG_CMD_CREATE, NULL, NULL, 0); /* triggers get_tree() */
mfd = fsmount(fd, 0, MS_NODEV | MS_NOSUID);  /* create a mount object */
move_mount(mfd, "", AT_FDCWD, "/mnt", MOVE_MOUNT_F_EMPTY_PATH);
close(mfd); close(fd);
```

This replaces the single monolithic `mount(2)` call with discrete steps, enabling rich error reporting (each `fsconfig` call returns a specific error), namespace-passing (a namespace fd can be passed via `FSCONFIG_SET_FD`), and atomic two-phase mount (build the superblock, then atomically attach it).

For filesystems that still use the old `mount()` callback, the kernel wraps them with a `legacy_fs_context_ops` shim that calls `parse_monolithic()` (which in turn calls the old `mount()` data parsing) and `get_tree()` which calls the old `mount()` function.

### Superblock lifetime and kill_sb

The `struct super_block` created by `get_tree` / `fill_super` lives as long as at least one mount references it. The VFS tracks all superblocks of a given type in the `file_system_type.fs_supers` hlist; each entry also appears in the global `super_blocks` list.

When the last mount on a superblock is removed, the VFS calls `generic_shutdown_super()` (for most filesystems) which:

1. Calls `evict_inodes(sb)` to flush all cached inodes.
2. Calls `sb->s_op->put_super(sb)` to let the filesystem release private state.
3. Removes the superblock from `fs_supers` and `super_blocks`.
4. Calls `kill_sb()` on the `file_system_type` — e.g. `kill_block_super()` releases the block device, `kill_anon_super()` just frees the superblock struct.

## Key Data Structures

**`struct file_system_type`** (`include/linux/fs.h`) — the registration descriptor; one per filesystem driver; linked into the global `file_systems` list via `next`.

**`struct fs_context`** (`include/linux/fs_context.h`) — ephemeral context for one mount/remount operation; accumulates options before committing the superblock; freed by `put_fs_context()`.

**`struct fs_context_operations`** (`include/linux/fs_context.h`) — filesystem vtable for the staged mount; hooks: `parse_param`, `get_tree`, `reconfigure`, `free`.

**`struct fs_parameter_spec`** (`include/linux/fs_parser.h`) — describes one accepted mount option: name, type (`fs_param_is_string`, `fs_param_is_u32`, `fs_param_is_flag`, …), and an opcode the filesystem uses to switch in `parse_param()`.

**`struct super_block`** (`include/linux/fs.h`) — one live filesystem instance; created in `get_tree()`/`fill_super()`; lives in `file_system_type.fs_supers` hlist.

## Key Functions / Entry Points

**`register_filesystem(fs)`** (`fs/filesystems.c`) — appends `file_system_type` to global list; called at module init.

**`unregister_filesystem(fs)`** (`fs/filesystems.c`) — splices it out; called at module exit.

**`init_fs_context(fc)`** — filesystem callback; populates `fc->ops` and allocates `fc->fs_private`; entry point for all modern mounts.

**`get_tree_bdev(fc, fill_super)`** (`fs/super.c`) — standard helper for block-device filesystems; calls `sget_fc()` to find/create superblock, then `fill_super`.

**`get_tree_nodev(fc, fill_super)`** (`fs/super.c`) — standard helper for virtual per-mount filesystems.

**`get_tree_single(fc, fill_super)`** (`fs/super.c`) — helper for single-instance filesystems like procfs.

**`sget_fc(fc, test, set)`** (`fs/super.c`) — finds existing superblock in `fs_supers` via optional `test()` callback, or allocates new one and calls `set()`.

**`fs_parse(fc, spec, param, result)`** (`fs/fs_parser.c`) — typed option parser; called from filesystem's `parse_param()` implementation.

**`vfs_get_tree(fc)`** (`fs/super.c`) — calls `fc->ops->get_tree(fc)`; validates result; sets `fc->root`.

**`generic_shutdown_super(sb)`** (`fs/super.c`) — standard unmount: evict inodes, call `put_super`, remove from lists.

## Important Flags & Config Options

| Flag / Config | Meaning |
|---------------|---------|
| `FS_REQUIRES_DEV` | VFS enforces that `source` is a block device |
| `FS_USERNS_MOUNT` | allows unprivileged (user namespace) mounts |
| `FS_NO_DCACHE` | dentries not kept after unmount (pseudo-fses) |
| `FS_ALLOW_IDMAP` | filesystem supports idmapped mounts |
| `/proc/filesystems` | lists all registered filesystem types; `nodev` prefix = no block device needed |
| `CONFIG_TMPFS`, `CONFIG_EXT4_FS`, … | each filesystem has its own Kconfig symbol; all call `register_filesystem()` at boot/module init |

## Interactions with Other Subsystems

- **↑ Userspace**: `mount(2)`, `fsopen(2)`/`fsconfig(2)`/`fsmount(2)` syscalls trigger filesystem instantiation; `/proc/filesystems` exposes the registration list.
- **→ [[Superblock]]**: registration creates the template; each mount allocates a `struct super_block` instance tracked in `fs_supers`.
- **→ [[VFS]]**: registered filesystem names are looked up by `get_fs_type()` during mount; the VFS drives the `fs_context` lifecycle.
- **→ [[Mount Namespace]]**: `vfs_create_mount()` wraps the superblock root in a `struct mount` that is attached to the caller's mount namespace.
- **← [[Modules]]**: filesystem drivers are loadable modules; `owner = THIS_MODULE` prevents unload while any superblock is live; `request_module("fs-%s", fstype)` auto-loads unknown filesystem names.
- **→ [[Security (LSM)]]**: `security_sb_alloc()` and `security_fs_use()` are called during superblock creation; LSMs can deny mount based on filesystem type or label.

## Design Decisions & Tradeoffs

**Single linked list for registered filesystems**: The global `file_systems` list is protected by a read-write lock and is walked linearly on every mount. With O(n) lookup — acceptable since the list has ~100 entries on a typical system — the simplicity outweighs the performance cost. A hash table would complicate registration and add memory overhead for a one-time-per-mount-type operation.

**Legacy mount() wrapper preserved**: When the `fs_context` API was introduced, all ~50 in-tree filesystems could not be converted simultaneously. The legacy wrapper (`legacy_fs_context_ops`) translates old `mount()` calls into `fs_context` flows, letting the VFS internally use the new API uniformly while unconverted drivers still work. This was deliberately a long-term migration path rather than a hard cutover — NFS was one of the last holdouts (converted in 5.11).

**fill_super is still the real work**: Even with the modern API, `get_tree_*` helpers still call `fill_super` as the final step. This preserves the intuition that "fill_super initialises the superblock" while the surrounding `fs_context` machinery handles option parsing and superblock deduplication. The split is clean: `fs_context` does the "prepare and validate" work; `fill_super` does the "commit and build" work.

**Staged mount for rollback**: The `fs_context` design allows `parse_param()` to validate options and return errors before any superblock is allocated. Under the old API, a filesystem might allocate a superblock, partially apply options, then return an error — leaving the superblock in an inconsistent state that required careful cleanup. The staged approach makes invalid-option errors cheap and clean.

## How It Has Evolved

- **2.4**: `file_system_type.read_super` callback; `register_filesystem`; global linked list.
- **2.6.x**: `mount()` callback replaced `read_super()`; `mount_bdev/nodev/single/pseudo` helpers introduced.
- **3.0+**: `kill_sb` standardised; `kill_block_super/kill_anon_super/kill_litter_super` helpers.
- **5.1** (2019): `fs_context` and `init_fs_context` introduced (David Howells); legacy `mount()` wrapped transparently; typed parameter parsing via `fs_parse()`.
- **5.2** (2019): `fsopen(2)`, `fsconfig(2)`, `fsmount(2)`, `fspick(2)`, `move_mount(2)` syscalls exposing `fs_context` to userspace.
- **5.11** (2021): NFS converted to `fs_context` (one of the most complex conversions, requiring significant rework of NFS mount option parsing).
- **6.x**: `FS_ALLOW_IDMAP` added; idmapped mount support negotiated at registration time.

## Further Reading

1. [Filesystem Mount API — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/mount_api.html)
2. [VFS: Introduce filesystem context — LWN.net](https://lwn.net/Articles/780267/)
3. [A new API for mounting filesystems — LWN.net](https://lwn.net/Articles/753473/)
4. [Creating Linux virtual filesystems — LWN.net](https://lwn.net/Articles/57369/)
5. [Overview of the Linux VFS — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/vfs.html)

## LKML Highlights

- **fs_context introduction** — David Howells (2019): The 14-version, multi-year effort to introduce `struct fs_context`. The core design debate was whether to expose the new API to userspace immediately (via `fsopen`/`fsconfig`) or keep it purely kernel-internal first. The final approach did both: kernel API in 5.1, userspace syscalls in 5.2.
- **NFS fs_context conversion** — Trond Myklebust (2021): NFS mount option parsing is extraordinarily complex (50+ options, per-server state, negotiation with server). The thread (`[PATCH v11 00/14] NFS: Convert to the new mount API`) showed the cost of legacy: NFS had accumulated three parallel option-parsing code paths that the conversion collapsed into one.
