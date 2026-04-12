---
title: "Extended Attributes and ACLs"
category: concept
tags: [xattr, acl, vfs, security, filesystem, posix]
subsystem: fs
kernel_version: "2.6.0"
researched: 2026-04-12
status: complete
sources:
  - https://kernel-internals.org/vfs/xattr/
  - https://kernel-internals.org/site-index/
  - https://docs.kernel.org/filesystems/ext4/attributes.html
  - https://lwn.net/Articles/6963/
  - https://lwn.net/Articles/868505/
  - https://lwn.net/Articles/897420/
  - https://github.com/torvalds/linux/blob/master/include/linux/xattr.h
  - https://github.com/torvalds/linux/blob/master/fs/posix_acl.c
  - https://man7.org/linux/man-pages/man7/xattr.7.html
  - https://www.usenix.org/legacyurl/posix-access-control-lists-linux
---

# Extended Attributes and ACLs

## Purpose

Traditional POSIX file metadata — owner UID/GID, permission bits, timestamps — is fixed in structure and cannot accommodate application-defined or security-module-defined metadata without abusing other fields. Extended attributes (xattrs) solve this by allowing arbitrary name-value pairs to be attached to any inode, enabling POSIX ACLs, SELinux labels, encryption policies, OverlayFS markers, and application-defined metadata all to coexist on the same file without any of them knowing about the others.

## Mental Model

Think of a file's inode as a manila folder. The front of the folder has the standard fields (owner, permissions, timestamps) — the traditional POSIX metadata. Extended attributes are sticky notes on the back of the folder: each note has a namespaced label (e.g. `user.comment`, `security.selinux`, `system.posix_acl_access`) and an arbitrary value blob. The VFS hands sticky notes to the right handler based on the namespace prefix, and the handler figures out what to do with the value — one handler might store it on-disk, another might enforce a permission check, another might feed it to an LSM hook.

## How It Works

### The Namespace Architecture and Handler Dispatch

When a process calls `setxattr("foo", "security.selinux", value, ...)`, the kernel must route this operation to the right piece of code. It does so through a *namespace architecture*: the attribute name's prefix determines which handler owns the operation.

Four namespaces are defined:

| Namespace   | Prefix       | Who can write                        | Primary use                              |
|-------------|--------------|--------------------------------------|------------------------------------------|
| `user`      | `user.`      | Any process with file write access   | Application metadata                     |
| `system`    | `system.`    | Kernel / privileged (CAP_SYS_ADMIN)  | POSIX ACLs (`system.posix_acl_*`)        |
| `security`  | `security.`  | LSM modules (implicitly CAP_SYS_ADMIN)| SELinux labels, AppArmor contexts        |
| `trusted`   | `trusted.`   | CAP_SYS_ADMIN                        | Container runtimes, OverlayFS markers    |

Each filesystem registers a NULL-terminated array of `struct xattr_handler *` pointers in `sb->s_xattr` at mount time. When the VFS receives an xattr syscall it iterates this table looking for a handler whose `prefix` matches the attribute name's leading bytes (or whose `name` matches exactly). The match then dispatches to the handler's `get`, `set`, or `list` callback.

```c
struct xattr_handler {
    const char *name;      /* match exactly this name, OR */
    const char *prefix;    /* match names starting with this prefix */
    int flags;             /* fs-private flags passed to callbacks */

    bool (*list)(struct dentry *dentry);
    int  (*get)(const struct xattr_handler *, struct dentry *dentry,
                struct inode *inode, const char *name,
                void *buffer, size_t size);
    int  (*set)(const struct xattr_handler *,
                struct mnt_idmap *idmap, struct dentry *dentry,
                struct inode *inode, const char *name,
                const void *buffer, size_t size, int flags);
};
```

The four VFS entry points — `vfs_getxattr()`, `vfs_setxattr()`, `vfs_listxattr()`, and `vfs_removexattr()` — all live in `fs/xattr.c` and follow the same pattern: resolve the handler via `xattr_resolve_name()`, check permissions (including LSM hooks via `security_inode_setxattr` / `security_inode_getxattr`), then call the handler callback which eventually calls the filesystem's inode operation (`inode->i_op->get_inode_acl`, `inode->i_op->set_acl`, or the lower-level `__vfs_setxattr`).

### System Call Path (setxattr fast path)

The journey from userspace to on-disk starts at the `setxattr(2)` syscall. The kernel resolves the pathname to a dentry (triggering path lookup's full machinery), performs a capability check appropriate to the namespace, then calls `vfs_setxattr()`. Inside `vfs_setxattr()`:

1. `xattr_resolve_name()` walks `sb->s_xattr` looking for a handler whose prefix matches the attribute name. If none is found and the filesystem provides `inode->i_op->set_xattr` directly, that fallback is used. If still no match, `-EOPNOTSUPP` is returned.
2. `security_inode_setxattr()` is called — this is the LSM hook that allows SELinux/AppArmor/smack to veto or transform the operation before it reaches the filesystem.
3. The resolved handler's `set()` callback is invoked. For `user.*` attributes on ext4 this calls `ext4_xattr_set()`. For `security.*` attributes it invokes the LSM's own storage logic. For `system.posix_acl_*` it calls `posix_acl_xattr_set()`.
4. `__vfs_setxattr_noperm()` → `__vfs_setxattr()` writes through to the filesystem, which handles the actual on-disk representation.

`getxattr(2)` reverses the path: resolve handler → LSM hook `security_inode_getxattr()` → handler `get()` → filesystem read.

`listxattr(2)` is slightly different: it calls `vfs_listxattr()` which invokes `inode->i_op->listxattr()`. Most filesystems implement `generic_listxattr()`, which iterates `sb->s_xattr` and calls each handler's `list()` callback to decide which attribute names to include (some, like internal fscrypt attrs, are intentionally hidden from userspace listing).

### Physical Storage: Inline and External Blocks

How xattrs end up on disk varies by filesystem, but ext4's approach is representative:

**Inline (in-inode) storage** — The inode structure on disk is larger than the fixed 128-byte legacy size. `i_extra_isize` records how many extra bytes exist at the end of the inode. After the fixed inode fields and the variable `i_extra_isize` region, any remaining bytes are claimed by an `ext4_xattr_ibody_header` (magic number only, 4 bytes) followed by packed `ext4_xattr_entry` records. Small attributes live here with zero extra I/O cost beyond reading the inode itself.

**External block storage** — When inline space fills up, `inode.i_file_acl` (a block number field) points to a dedicated 4 KiB xattr block. This block begins with a 32-byte `ext4_xattr_header` containing a reference count, hash, and checksum, followed by an array of `ext4_xattr_entry` records sorted by (name_index, name_len, name). Attribute values are packed from the *end* of the block backwards. When the two regions collide, the overflow spills into yet another block referenced via the EA_INODE feature (introduced to support values larger than 64 KiB).

The name_index compression is a space optimization: instead of storing `"user."` or `"security."` verbatim, each entry stores a small integer (1 = `user.`, 4 = `trusted.`, etc.) that the kernel decodes back to the prefix when listing.

```
  Block layout (external xattr block):
  ┌─────────────────────────────────────────┐
  │ ext4_xattr_header (32 bytes)            │
  ├─────────────────────────────────────────┤
  │ ext4_xattr_entry[0]  (name inline)      │
  │ ext4_xattr_entry[1]  ...                │
  │ ...                                     │  ← entries grow downward
  ├─────────────────────────────────────────┤
  │          (free space)                   │
  ├─────────────────────────────────────────┤
  │ ...attr value N                         │
  │ attr value 1       (values grow upward) │  ← values packed from end
  └─────────────────────────────────────────┘
```

Reference counting on the external block allows *sharing*: if two hard links to the same inode, or two files with identical xattr sets, the block is shared, and the reference count prevents premature freeing.

### POSIX ACLs

POSIX ACLs are the primary consumer of the `system.*` namespace. They extend the traditional `rwxrwxrwx` permission model to support per-user and per-group entries beyond just the file owner and owning group.

Two attributes govern a file's ACL:
- `system.posix_acl_access` — the access ACL applied on every open/permission check.
- `system.posix_acl_default` — the default ACL on a directory, inherited by new files created in it.

Each attribute stores a serialised `struct posix_acl`, which is an array of `struct posix_acl_entry` records:

```c
struct posix_acl_entry {
    short           e_tag;   /* ACL_USER_OBJ, ACL_USER, ACL_GROUP_OBJ,
                                ACL_GROUP, ACL_MASK, ACL_OTHER */
    unsigned short  e_perm;  /* bitfield: ACL_READ | ACL_WRITE | ACL_EXECUTE */
    kuid_t          e_uid;   /* valid for ACL_USER entries */
    kgid_t          e_gid;   /* valid for ACL_GROUP entries */
};

struct posix_acl {
    refcount_t      a_refcount;
    unsigned int    a_count;       /* number of entries */
    struct posix_acl_entry a_entries[]; /* flexible array */
};
```

**Permission checking** happens in `posix_acl_permission()` (`fs/posix_acl.c`), called from `inode_permission()` when `inode->i_opflags & IOP_POSIX_ACL` is set. The algorithm:

1. If only `ACL_USER_OBJ`, `ACL_GROUP_OBJ`, `ACL_OTHER` entries exist (minimal ACL), fall back to traditional `ugo` permission bits — no overhead.
2. Otherwise walk the entry array. If the current UID matches `ACL_USER_OBJ` (file owner), check permissions and apply the mask. If an `ACL_USER` entry matches the calling UID, that entry's `e_perm` is AND-ed with the `ACL_MASK` entry — a result of "granted" wins immediately. If no `ACL_USER` matched, check all `ACL_GROUP` and `ACL_GROUP_OBJ` entries; at least one must match the calling process's group set and after masking yield the required permission. Finally fall through to `ACL_OTHER`.
3. Return 0 (granted) or `-EACCES`.

The ACL is retrieved from the inode via `get_inode_acl()` (an inode operation), which reads the `system.posix_acl_access` xattr through the handler chain and then caches the parsed `struct posix_acl` in `inode->i_acl` to avoid repeated disk reads. On modification (`chmod`, `setfacl`), the cache is invalidated via `forget_cached_acl()`.

**ACL inheritance at creation** is handled in `posix_acl_create()`: when a new file or directory is created inside a directory with a default ACL, the VFS reads `system.posix_acl_default` from the parent, applies the creation mask (`umask` interaction), then writes the resulting ACL to the new inode via `set_posix_acl()`.

### LSM Integration via the `security.*` Namespace

Security modules hook into xattrs at two levels. First, the `security_inode_setxattr()` / `security_inode_getxattr()` LSM hooks fire for *every* xattr operation, giving LSMs veto power even over `user.*` attributes. Second, LSMs use `security.*` xattrs as their own persistent storage for labels (SELinux) or contexts (AppArmor). During file creation `selinux_inode_init_security()` is called, which writes `security.selinux` to the new inode based on the parent directory's context and the creating process's domain — this is how every file gets a label automatically without any userspace involvement.

LSMs can also use `security_inode_listsecurity()` to inject their own attribute names into `listxattr(2)` output without going through the normal `s_xattr` dispatch table.

## Key Data Structures

**`struct xattr_handler`** (`include/linux/xattr.h`) — The unit of dispatch. A filesystem registers an array of these in `sb->s_xattr`; each handler claims a namespace prefix or exact name, and provides `get`/`set`/`list` callbacks.

**`struct posix_acl`** (`include/linux/posix_acl.h`) — In-memory representation of a file's access or default ACL. Reference-counted; cached in `inode->i_acl` and `inode->i_default_acl`.
- `a_count` — number of ACL entries
- `a_entries[]` — the entries themselves

**`struct posix_acl_entry`** (`include/linux/posix_acl.h`) — One row of an ACL: tag type, permissions, and the UID or GID it applies to.

**`struct ext4_xattr_header`** (`fs/ext4/xattr.h`) — On-disk header for an external xattr block.
- `h_magic` — `0xEA020000`, validates the block is genuine
- `h_refcount` — allows multiple inodes to share one xattr block
- `h_hash` — enables fast block lookup in the xattr block cache

**`struct ext4_xattr_entry`** (`fs/ext4/xattr.h`) — On-disk descriptor for one attribute.
- `e_name_index` — compressed namespace prefix (1 = `user.`, 4 = `trusted.`, etc.)
- `e_name_len` / `e_name` — attribute name without prefix, without NUL
- `e_value_size` / `e_value_offs` — value location (offset from block end, growing upward)

## Key Functions / Entry Points

**`vfs_getxattr()`** (`fs/xattr.c`) — Primary VFS entry for getxattr; resolves handler, fires LSM hook, dispatches to handler `get()`.

**`vfs_setxattr()`** (`fs/xattr.c`) — Primary VFS entry for setxattr; checks namespace permissions, fires `security_inode_setxattr()`, dispatches to handler `set()`.

**`xattr_resolve_name()`** (`fs/xattr.c`) — Walks `sb->s_xattr` to find the handler whose prefix/name matches the attribute name; returns `-EOPNOTSUPP` if none found.

**`posix_acl_permission()`** (`fs/posix_acl.c`) — The ACL permission check algorithm. Called from `inode_permission()` when `IOP_POSIX_ACL` is set.

**`posix_acl_create()`** (`fs/posix_acl.c`) — Derives the ACL for a newly created inode from the parent directory's default ACL and the umask; called from filesystem `mkdir`/`create` paths.

**`posix_acl_xattr_set()`** (`fs/posix_acl.c`) — The `set()` callback for the `system.posix_acl_*` handler; parses the raw xattr blob into a `struct posix_acl` and calls `set_posix_acl()`.

**`get_inode_acl()`** / **`set_inode_acl()`** (`fs/posix_acl.c`) — VFS helpers that wrap `inode->i_op->get_inode_acl` / `inode->i_op->set_acl` with cache-aware logic.

**`forget_cached_acl()`** (`include/linux/posix_acl.h`) — Clears `inode->i_acl` / `inode->i_default_acl` on any operation that changes the ACL (chmod, setfacl, set_acl).

**`generic_listxattr()`** (`fs/xattr.c`) — Default `listxattr` implementation for filesystems that use the `s_xattr` table; iterates handlers and calls their `list()` callbacks.

## Important Flags & Config Options

**`CONFIG_FS_POSIX_ACL`** — Enables generic POSIX ACL support in the VFS. Filesystems that support ACLs select this.

**`CONFIG_EXT4_FS_POSIX_ACL`** / **`CONFIG_XFS_POSIX_ACL`** — Per-filesystem ACL support; enables the handler registration and ACL inode operations.

**`acl` / `noacl` mount options** — Most filesystems accept these; `acl` enables ACL enforcement, `noacl` disables it even if the filesystem has stored ACL data. Some filesystems (ext4 on kernels >= 3.8) enable ACL by default if the feature is present on disk.

**`i_extra_isize`** (ext4 inode field) — Controls how many bytes are available for inline xattr storage. Set at `mkfs` time via `-I <inode-size>`; larger inodes allow more attributes to be stored without an extra block I/O.

**`user_xattr` / `nouser_xattr` mount options** — On some filesystems, control whether the `user.*` namespace is enabled at all.

**`trusted.*` namespace** — Requires `CAP_SYS_ADMIN`; commonly used by OverlayFS for `trusted.overlay.opaque` (marks directories as opaque to the overlay) and `trusted.overlay.origin` (tracks inode lineage across layers).

## Interactions with Other Subsystems

- **↑ Userspace**: `getxattr(2)`, `setxattr(2)`, `listxattr(2)`, `removexattr(2)` syscalls (with `l` and `f` prefixed variants for symlinks and file descriptors). Tools: `getfattr`/`setfattr` for general xattrs, `getfacl`/`setfacl` for ACLs.
- **→ [[LSM / Security]]**: Every xattr operation passes through `security_inode_setxattr()` / `security_inode_getxattr()` hooks. LSMs also consume `security.*` xattrs for label persistence.
- **→ [[VFS]]**: xattrs are surfaced through inode operations (`i_op->listxattr`, `i_op->set_acl`, `i_op->get_inode_acl`). ACL permission checks integrate into `inode_permission()`.
- **→ [[fscrypt]]**: Encryption policies are stored as an internal xattr index not accessible to userspace; fscrypt uses `__vfs_setxattr()` to bypass the normal permission path.
- **→ [[OverlayFS]]**: Uses `trusted.*` xattrs extensively to mark opaque directories and track origin inodes across overlay layers.
- **← [[NFS]]**: The NFS client/server both implement xattr protocol extensions (NFSv3 XATTR RPC, NFSv4.1/4.2 extended attribute support) to propagate xattrs over the wire, including POSIX ACLs.
- **← [[Btrfs]]**: Stores xattrs as regular B-tree items under `BTRFS_XATTR_ITEM_KEY`, sharing the same copy-on-write semantics as all other data.

## Design Decisions & Tradeoffs

**Namespace prefix dispatch over a unified registry** — The handler table approach (`sb->s_xattr`) means the VFS never needs to understand xattr semantics: it just finds the handler and calls it. This is simple and extensible but creates a maintenance burden: every filesystem must register its own handler table, and handler lookup is a linear scan (acceptable because the table is tiny).

**User xattrs not allowed on symlinks and device files** — This is intentional. Any process that can write to `/dev/null` could attach unlimited xattr data to it, filling the disk. Only symlink/device owners would be allowed to set `user.*` attrs (a relaxation discussed in 2021, lwn.net/Articles/868505), and the debate is unresolved: some argue the semantic model of `user.*` mirroring file contents is important to preserve.

**POSIX ACL mask semantics** — The `ACL_MASK` entry is non-obvious: it bounds the effective permissions of all `ACL_USER` and `ACL_GROUP` entries, not `ACL_USER_OBJ`. This means the file owner's permissions are unaffected by the mask, but group entries are bounded. It is a designed compatibility mechanism so that tools that modify the group permission bits do not accidentally open up all group ACL entries.

**In-memory ACL caching on the inode** — Rather than parsing the xattr blob on every permission check, the kernel caches the `struct posix_acl` in `inode->i_acl`. This eliminates disk I/O for hot files. The tradeoff is cache invalidation complexity: any operation that might change ACL state (`chmod`, `setfacl`, truncation) must call `forget_cached_acl()`.

**Shared xattr blocks (ext4 reference counting)** — When many files share the same set of extended attributes (e.g. all files in a container share the same SELinux label), ext4's reference-counted xattr blocks allow them to point to one shared block rather than storing the identical data N times. This is a significant space saving in container workloads.

## How It Has Evolved

**Pre-2.6 (early 2000s)** — Individual filesystems (XFS, ReiserFS, ext2/3) implemented ACLs independently with no shared VFS infrastructure. Conversion was handled entirely by filesystem-specific code.

**2.6.0 (2003)** — Generic POSIX ACL infrastructure (`fs/posix_acl.c`) added, standardising the `struct posix_acl` representation and the permission-checking algorithm. Filesystems could now share code instead of each implementing their own.

**2.6.x — xattr namespaces formalised** — The four-namespace model (`user`, `system`, `security`, `trusted`) solidified. LSMs began using `security.*` for label persistence. SELinux and Smack rely on this for mandatory access control.

**~3.8 (2013)** — ext4 began mounting with ACL support enabled by default when the filesystem feature is present, removing the need for the `acl` mount option.

**4.5 (2016)** — The `name` field was added to `struct xattr_handler`, allowing handlers to match exact attribute names (not just prefixes). This was needed for POSIX ACL handlers.

**~5.9–5.15 (2020–2021)** — Christian Brauner's series moved filesystem POSIX ACL handling from per-filesystem generic xattr handlers to a unified VFS-level POSIX ACL API (`get_inode_acl` / `set_acl` inode operations), removing boilerplate from individual filesystems and centralising the cache-invalidation logic.

**5.15+ (2021)** — NFSv4.2 extended attribute support landed, allowing `listxattr`/`getxattr`/`setxattr`/`removexattr` over NFS with proper server-side enforcement.

**2022 summit discussions** — Proposals to use the xattr interface for retrieving kernel-internal object attributes (mounts, processes) using a separate namespace, to create a unified metadata extraction API without new syscalls.

## Further Reading

1. [POSIX ACL Kernel Infrastructure (LWN, 2002)](https://lwn.net/Articles/6963/) — the original patch description explaining the design rationale
2. [Extended Attributes for Special Files (LWN, 2021)](https://lwn.net/Articles/868505/) — debate on relaxing `user.*` namespace restrictions for symlinks/device files
3. [Retrieving Kernel Attributes via xattr (LWN, 2022)](https://lwn.net/Articles/897420/) — LS/FSMM summit discussion on using xattrs for kernel object introspection
4. [Ext4 Extended Attributes — kernel.org](https://docs.kernel.org/filesystems/ext4/attributes.html) — on-disk layout reference
5. [POSIX Access Control Lists on Linux (Usenix)](https://www.usenix.org/legacyurl/posix-access-control-lists-linux) — academic-style overview of the ACL model
6. [xattr(7) man page](https://man7.org/linux/man-pages/man7/xattr.7.html) — userspace API reference

## LKML Highlights

- **Brauner's POSIX ACL cleanup series (2022–2023)**: `20221018115700.166010-25-brauner@kernel.org` and `20230125-fs-acl-remove-generic-xattr-handlers-v1-0-6cf155b492b6@kernel.org` — migrated filesystems away from per-filesystem ACL xattr handlers to a centralised VFS API; the main debate was how to handle in-flight callers and whether the ACL cache should live in the VFS layer or remain in each filesystem.
- **NFSv3 XATTR protocol thread**: `lwn.net/Articles/392944` — discussion of adding xattr RPC operations to NFSv3, with debate about whether server-side enforcement or client-side pass-through was the right model.
