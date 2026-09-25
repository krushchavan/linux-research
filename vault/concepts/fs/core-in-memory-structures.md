---
title: "Core VFS In-Memory Structures"
category: concept
tags: [fs, vfs, superblock, inode, dentry, file-object, address-space]
subsystem: fs
kernel_version: "2.4+"
researched: 2026-04-05
status: complete
explained: "[[core-in-memory-structures-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://linux-kernel-labs.github.io/refs/heads/master/labs/filesystems_part1.html
  - https://lwn.net/Articles/57369/
  - https://lwn.net/Articles/649115/
---

# Core VFS In-Memory Structures

> 📘 Plain-language version: [[core-in-memory-structures-explained]]

## Purpose

The Linux VFS defines six core in-memory object types that together represent every state the kernel needs to manage an open file: where it lives on disk (superblock, inode), how to find it by name (dentry), where it is mounted (mount), how its data is cached (address_space), and which process has it open (file). These objects form a graph; understanding the graph is the prerequisite for tracing any filesystem code path.

## Mental Model

Each object answers one question:

| Object | Question answered |
|--------|------------------|
| `struct super_block` | Which filesystem instance am I on? |
| `struct inode` | What are this file's metadata and location? |
| `struct dentry` | What is this file's name in the directory tree? |
| `struct vfsmount` / `struct mount` | Where is this filesystem mounted? |
| `struct address_space` | What are this file's cached pages? |
| `struct file` | Who has this file open, and at what position? |

The graph from a process's perspective: `fd → struct file → (struct dentry, struct vfsmount) → struct inode → struct address_space → page cache folios`.

## How It Works

### struct super_block: the filesystem instance

`struct super_block` (`include/linux/fs.h`) represents one *mounted* filesystem. There is one superblock per mounted instance — bind mounts share the superblock but have distinct `struct mount` objects. Key fields:

```c
struct super_block {
    dev_t                  s_dev;        /* block device identifier */
    unsigned long          s_blocksize;  /* block size in bytes */
    unsigned long          s_magic;      /* filesystem magic number */
    const struct super_operations *s_op; /* vtable: alloc_inode, write_inode, … */
    const struct dquot_operations *dq_op;
    const struct quotactl_ops     *s_qcop;
    struct dentry          *s_root;      /* root dentry of this filesystem */
    struct list_head       s_inodes;     /* all live inodes of this sb */
    struct list_head       s_inode_lru;  /* per-sb LRU of unused inodes */
    struct hlist_node      s_instances;  /* entry in file_system_type->fs_supers */
    void                   *s_fs_info;   /* filesystem-private data (e.g. ext4_sb_info) */
    struct file_system_type *s_type;     /* back-pointer to the fs type */
    unsigned int           s_flags;      /* MS_RDONLY, MS_NOSUID, … */
    u64                    s_iflags;     /* SB_I_CGROUPWB, SB_I_NODEV, … */
    struct backing_dev_info *s_bdi;      /* writeback device */
    errseq_t               s_wb_err;     /* last writeback error on this sb */
};
```

The `s_op` vtable defines:
- `alloc_inode` / `destroy_inode` — slab allocation for filesystem-extended inodes
- `write_inode` — persist inode metadata
- `evict_inode` — writeback + page cache truncation before freeing
- `put_super` — release private state on unmount
- `sync_fs` — flush all dirty state
- `freeze_fs` / `unfreeze_fs` — quiesce for snapshots
- `statfs` — filesystem statistics

The superblock is created during mount by `fill_super()` (called from `get_tree_*` helpers). It is destroyed by `generic_shutdown_super()` when the last mount is removed.

### struct inode: the file-system object

`struct inode` (`include/linux/fs.h`) is the kernel's representation of one filesystem object — a file, directory, symlink, device node, socket, or pipe. It is identified within a filesystem by `(sb, i_ino)`. Multiple dentries (hard links) may point to the same inode. Key fields:

```c
struct inode {
    umode_t                i_mode;       /* file type + permissions */
    kuid_t                 i_uid;
    kgid_t                 i_gid;
    unsigned int           i_flags;      /* S_IMMUTABLE, S_APPEND, … */
    const struct inode_operations *i_op; /* vtable: lookup, create, link, … */
    const struct file_operations  *i_fop;/* default file operations (copied to struct file at open) */
    struct super_block     *i_sb;        /* back-pointer to superblock */
    struct address_space   *i_mapping;   /* page cache (usually points to i_data below) */
    struct address_space    i_data;      /* embedded address_space for regular files */
    unsigned long          i_ino;        /* inode number within this sb */
    union { unsigned int i_nlink; };     /* hard link count */
    loff_t                 i_size;       /* file size in bytes */
    struct timespec64      i_atime, i_mtime, i_ctime;
    atomic_t               i_count;      /* reference count (≥1 means not in LRU) */
    unsigned int           i_state;      /* I_NEW, I_DIRTY_*, I_FREEING, … */
    spinlock_t             i_lock;       /* protects i_state, i_count */
    struct hlist_head      i_dentry;     /* all dentries aliasing this inode */
    struct list_head       i_sb_list;    /* entry in sb->s_inodes */
    /* … fsnotify, xattr, acl fields … */
};
```

The `i_op` vtable defines metadata operations: `lookup`, `create`, `link`, `unlink`, `mkdir`, `rmdir`, `rename`, `readlink`, `get_link`, `permission`, `getattr`, `setattr`, `listxattr`.

Most filesystems embed `struct inode` in a larger, filesystem-private struct (e.g. `struct ext4_inode_info`) allocated from a per-filesystem slab cache. `container_of(inode, struct ext4_inode_info, vfs_inode)` recovers the private struct. See [[Inode Cache]] for the full lifecycle.

### struct dentry: the name-to-inode mapping

`struct dentry` (`include/linux/dcache.h`) caches the result of a single pathname component resolution. It connects a name string to an inode (positive dentry) or records that no file exists with that name (negative dentry). Key fields:

```c
struct dentry {
    unsigned int        d_flags;     /* DCACHE_MOUNTED, DCACHE_OP_HASH, … */
    seqcount_spinlock_t d_seq;       /* seqlock for RCU-walk validation */
    struct hlist_bl_node d_hash;     /* entry in global dentry_hashtable */
    struct dentry      *d_parent;    /* parent dentry */
    struct qstr         d_name;      /* name: {hash_len, name pointer} */
    struct inode       *d_inode;     /* NULL for negative dentries */
    unsigned char       d_iname[DNAME_INLINE_LEN]; /* inline name buffer */
    struct lockref      d_lockref;   /* spinlock + refcount (atomic cmpxchg) */
    const struct dentry_operations *d_op; /* vtable: d_revalidate, d_hash, d_compare, … */
    struct super_block *d_sb;        /* back-pointer to superblock */
    struct list_head    d_child;     /* entry in parent->d_subdirs */
    struct list_head    d_subdirs;   /* list of child dentries */
    union {
        struct list_head  d_alias;   /* entry in inode->i_dentry (positive dentries) */
        struct list_head  d_in_lookup_hash; /* for parallel lookup */
    };
    struct list_head    d_lru;       /* entry in sb->s_dentry_lru */
};
```

The dentry cache (dcache) is the central accelerator for [[Path Lookup]]. See [[Dentry Cache]] for eviction and memory management details.

### struct vfsmount / struct mount: the mount point

The public `struct vfsmount` (`include/linux/mount.h`) is the part of a mount that is exported to drivers:

```c
struct vfsmount {
    struct dentry     *mnt_root;   /* root dentry of this mount */
    struct super_block *mnt_sb;    /* superblock of this filesystem */
    int                mnt_flags;  /* MNT_NOSUID, MNT_READONLY, … */
    struct user_namespace *mnt_userns; /* idmapping */
};
```

The internal `struct mount` (`fs/mount.h`, unexported) embeds `struct vfsmount` and adds all the namespace/propagation machinery:
- `mnt_parent` / `mnt_mountpoint` — where this mount is attached in its parent.
- `mnt_ns` — the containing [[Mount Namespace]].
- `mnt_mounts` / `mnt_child` — tree of child mounts.
- `mnt_share`, `mnt_slave`, `mnt_master` — shared-subtree propagation links.
- `mnt_count` — reference count.

The global mount hash table maps `(parent vfsmount, mountpoint dentry)` → `struct mount`, enabling O(1) mount-point crossing during path lookup.

### struct address_space: the page cache anchor

`struct address_space` (`include/linux/fs.h`) manages the page cache for one file (or device). Every inode has one embedded in `i_data`; `i_mapping` points to it (or to an override like the block device's address space for O_DIRECT). Key fields:

```c
struct address_space {
    struct inode               *host;          /* owning inode */
    struct xarray               i_pages;       /* XArray of cached folios */
    struct rw_semaphore         invalidate_lock; /* protects invalidation vs read faults */
    gfp_t                       gfp_mask;
    atomic_t                    i_mmap_writable;
    struct rb_root_cached       i_mmap;        /* interval tree of VMAs (reverse mapping) */
    unsigned long               nrpages;       /* total cached page count */
    pgoff_t                     writeback_index; /* next page to write in range_cyclic mode */
    const struct address_space_operations *a_ops; /* vtable: readpage, writepage, … */
    unsigned long               flags;
    errseq_t                    wb_err;        /* writeback error (errseq_t) */
    spinlock_t                  private_lock;
    struct list_head            private_list;
    void                        *private_data;
};
```

See [[Address Space]] for the complete read/write path through `a_ops`.

### struct file: the open-file description

`struct file` (`include/linux/fs.h`) is the per-`open(2)` kernel object. It is the only structure that is truly per-process-per-open (though shared across `dup2` and `fork` with `CLONE_FILES`). Key fields:

```c
struct file {
    struct path              f_path;      /* (vfsmount*, dentry*) — the open location */
    struct inode             *f_inode;    /* shortcut: f_path.dentry->d_inode */
    const struct file_operations *f_op;  /* vtable snapshot from inode at open time */
    atomic_long_t            f_count;    /* reference count */
    unsigned int             f_flags;    /* O_RDONLY, O_NONBLOCK, … */
    fmode_t                  f_mode;     /* FMODE_READ, FMODE_WRITE, … */
    struct mutex             f_pos_lock; /* serialise multi-threaded positional I/O */
    loff_t                   f_pos;      /* current file offset */
    struct address_space     *f_mapping; /* shortcut: f_inode->i_mapping */
    errseq_t                 f_wb_err;   /* per-fd error cursor */
    void                     *private_data; /* filesystem/driver private state */
};
```

See [[File Object]] for the complete open/close lifecycle, `fdget`/`fput` reference counting, and the `struct fd` `__cleanup` redesign.

### The complete object graph

```
struct task_struct
  └─ files → struct files_struct
       └─ fdt→fd[n] → struct file
                         ├─ f_path.mnt → struct vfsmount (embedded in struct mount)
                         │                  ├─ mnt_sb → struct super_block
                         │                  └─ mnt_root → struct dentry (mount root)
                         ├─ f_path.dentry → struct dentry
                         │                    ├─ d_inode → struct inode
                         │                    │              ├─ i_sb → struct super_block
                         │                    │              ├─ i_mapping → struct address_space
                         │                    │              │                └─ i_pages (XArray of folios)
                         │                    │              └─ i_op → struct inode_operations
                         │                    └─ d_parent → parent struct dentry
                         ├─ f_inode → (same as f_path.dentry->d_inode, cached)
                         ├─ f_mapping → (same as f_inode->i_mapping, cached)
                         └─ f_op → struct file_operations
```

### Operations vtable chain

Each object has its own vtable:

| Object | Vtable | Who provides it |
|--------|--------|-----------------|
| `super_block` | `struct super_operations` (`s_op`) | Filesystem (ext4, xfs, btrfs …) |
| `inode` | `struct inode_operations` (`i_op`) | Filesystem, may differ for files vs dirs |
| `inode` | `struct file_operations` (`i_fop`) | Filesystem; copied to `file->f_op` at open |
| `dentry` | `struct dentry_operations` (`d_op`) | Filesystem (optional; NFS uses for revalidation) |
| `address_space` | `struct address_space_operations` (`a_ops`) | Filesystem |
| `file_system_type` | `fs_context_operations` (via `init_fs_context`) | Filesystem |

The VFS never calls filesystem code directly — it always dispatches through one of these vtables. This is the "plugin" architecture that allows hundreds of filesystem types to coexist.

### Object lifecycles and caching

Objects are created lazily and cached aggressively:

- **superblock**: created at mount; lives until last `umount`.
- **inode**: created on first lookup or `create`; cached in `inode_hashtable` keyed by `(sb, ino)`. Freed when `i_count` hits zero and memory pressure evicts it from the LRU. See [[Inode Cache]].
- **dentry**: created on each unique path component lookup; cached in the global `dentry_hashtable`. Freed under memory pressure by `dcache_shrinker`. See [[Dentry Cache]].
- **struct mount**: created by `do_mount`; torn down on `umount`. See [[Mount Namespace]].
- **struct file**: created by `do_filp_open()` for each `open(2)` call; freed by `____fput()` when `f_count` hits zero. See [[File Object]].
- **address_space folios**: created on page cache miss (read fault or buffered write); evicted by page reclaim. See [[Address Space]].

## Key Data Structures

All six structures are defined in `include/linux/fs.h` except:
- `struct dentry` → `include/linux/dcache.h`
- `struct mount` (internal) → `fs/mount.h`
- `struct vfsmount` (public) → `include/linux/mount.h`

See the individual concept notes for annotated field listings:
- [[Superblock]] — `vault/concepts/fs/superblock.md`
- [[Inode]] — `vault/concepts/fs/inode.md`
- [[Dentry]] — `vault/concepts/fs/dentry.md`
- [[Dentry Cache]] — `vault/concepts/fs/dentry-cache.md`
- [[Inode Cache]] — `vault/concepts/fs/inode-cache.md`
- [[File Object]] — `vault/concepts/fs/file-object.md`
- [[Address Space]] — `vault/concepts/mm/address-space.md`
- [[Mount Namespace]] — `vault/concepts/fs/mount-namespace.md`

## Key Functions / Entry Points

**Object creation**:
- `new_inode(sb)` — allocate inode via `sb->s_op->alloc_inode()`
- `d_alloc(parent, name)` — allocate dentry
- `d_make_root(inode)` — allocate and attach root dentry
- `alloc_file(path, fmode, fops)` — allocate struct file

**Object lookup**:
- `iget_locked(sb, ino)` — find or allocate inode by number
- `d_lookup(parent, name)` — find dentry in dcache
- `lookup_fast(nd, inode, seqp)` — RCU dcache lookup during path resolution

**Object release**:
- `iput(inode)` — drop inode reference; LRU or immediate eviction
- `dput(dentry)` — drop dentry reference; LRU or immediate eviction
- `fput(file)` — drop file reference; schedules `____fput` when zero
- `mntput(mnt)` — drop mount reference

## Important Flags & Config Options

| Flag | Object | Meaning |
|------|--------|---------|
| `MS_RDONLY` | `sb->s_flags` | Filesystem mounted read-only |
| `S_IMMUTABLE` | `inode->i_flags` | File cannot be modified or deleted |
| `DCACHE_MOUNTED` | `dentry->d_flags` | Another filesystem is mounted here |
| `DCACHE_NEGATIVE` | `dentry->d_flags` | Negative dentry (no file at this name) |
| `I_NEW` | `inode->i_state` | Being initialised; other threads must wait |
| `I_DIRTY_*` | `inode->i_state` | Dirty metadata pending writeback |
| `FMODE_READ/WRITE` | `file->f_mode` | Access mode granted at open |
| `MNT_READONLY` | `vfsmount->mnt_flags` | This mount is read-only (even if sb is rw) |

## Interactions with Other Subsystems

- **↑ Userspace**: every filesystem syscall (`open`, `read`, `write`, `stat`, `rename`, `mount`, …) enters through one of these objects.
- **→ [[Path Lookup]]**: traverses dentry→parent chains and crosses mount points to resolve a path string into a `(vfsmount, dentry)` pair.
- **→ [[Filesystem Registration]]**: `file_system_type` provides `init_fs_context` which leads to `fill_super` which creates the superblock and root objects.
- **→ [[Page Reclaim]]**: dentries (via `dcache_shrinker`) and inodes (via `icache_shrinker`) are reclaimed under memory pressure; `address_space` folios are reclaimed via the LRU.
- **→ [[Writeback Infrastructure]]**: dirty inodes (`I_DIRTY_*`) are tracked in `bdi_writeback`; dirty folios (`PG_dirty`) in the address space are flushed by flusher threads.
- **→ [[fsnotify]]**: inotify/fanotify marks are attached to inodes and vfsmounts; VFS hooks in the operations vtables fire `fsnotify()` at each operation.

## Design Decisions & Tradeoffs

**Object separation (inode ≠ dentry)**: UNIX filesystems allow hard links — multiple names (dentries) for the same data (inode). Separating dentry (name/position) from inode (data/metadata) makes this natural: both dentries simply point to the same inode. A design that fused them would require special-casing hard links throughout.

**Shortcut fields in struct file**: `f_inode` (`f_path.dentry->d_inode`) and `f_mapping` (`f_inode->i_mapping`) are redundant with data accessible by pointer chasing. They exist because the read/write hot path follows these pointers millions of times per second; eliminating two pointer dereferences per I/O operation measurably improves throughput on high-IOPS workloads.

**Embedded address_space in inode**: Every file's page cache is anchored via `i_data` embedded directly in the inode rather than as a separate allocation. This keeps the inode and its address_space on the same or adjacent cache lines, improving locality during reads and writes.

**Vtable dispatch (not function pointers in operations)**: Operations are grouped into vtable structs (`super_operations`, `inode_operations`, etc.) rather than individual function pointers in the objects themselves. This keeps the object structs small and allows filesystems to share vtable instances across all inodes of the same type (e.g. all directory inodes in ext4 share one `ext4_dir_inode_operations`).

## How It Has Evolved

- **2.0**: Original VFS with superblock, inode, file objects; no separate dentry — pathname resolution was always done by the filesystem.
- **2.1.78** (1997): dcache introduced — dentry objects and the dentry hash table, enabling purely VFS-level path caching independent of the filesystem.
- **2.4**: `struct address_space` separated from inode; XIP (execute-in-place) support.
- **2.6.x**: Continued refinement; `lockref` for `d_lockref`; per-inode `i_lock`; address_space operations reworked.
- **4.20** (2018): Page cache migrated from radix tree to XArray (`i_pages` in `address_space`).
- **5.1** (2019): `fs_context` replaces `mount()` in `file_system_type`; superblock creation becomes a staged operation.
- **5.16+** (2022): `struct folio` replaces `struct page` in page-cache operations; `a_ops->writepage` → `writepages`, `read_folio`, `write_begin`/`write_end` standardised on folios.
- **6.8** (2024): `file_operations.read`/`.write` removed; all I/O goes through `read_iter`/`write_iter`.
- **6.9** (2024): `struct fd` redesigned as packed pointer+flags; `CLASS(fd, f)` `__cleanup` for automatic `fdput`.

## Further Reading

1. [Overview of the Linux Virtual File System — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/vfs.html)
2. [Creating Linux virtual filesystems — LWN.net](https://lwn.net/Articles/57369/)
3. [Pathname lookup in Linux — LWN.net](https://lwn.net/Articles/649115/)
