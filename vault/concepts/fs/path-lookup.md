---
title: "Path Lookup (namei)"
category: concept
tags: [fs, vfs, namei, rcu-walk, dcache, path-resolution]
subsystem: fs
kernel_version: "2.4+"
researched: 2026-04-05
status: complete
explained: "[[path-lookup-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/path-lookup.html
  - https://lwn.net/Articles/649729/
  - https://lwn.net/Articles/649115/
  - https://lwn.net/Articles/650786/
  - https://lwn.net/Articles/419811/
  - https://lwn.net/Articles/355839/
---

# Path Lookup (namei)

> 📘 Plain-language version: [[path-lookup-explained]]

## Purpose

Path lookup converts a null-terminated string like `/usr/lib/libc.so.6` into a kernel `struct dentry` (and the inode it points to). Every syscall that takes a filename — `open`, `stat`, `execve`, `mkdir`, `rename`, `unlink`, `mount` — passes through this machinery. Without a fast, scalable path-lookup implementation, all filesystem operations would serialize on locks protecting the dentry cache hierarchy.

## Mental Model

Path lookup is a controlled walk down a tree. The walker begins at a root (either `"/"` or the current working directory) and consumes one slash-separated component at a time, resolving each to a dentry before moving to the next. At every step, the walker may encounter a mount point (redirect to another filesystem root), a symlink (push the remainder and restart from the link target), or a permission denial (stop immediately).

There are two modes of walking. **RCU-walk** is the fast path: no locks are acquired, no reference counts are modified, and the walker verifies consistency via seqlock sequence numbers. If anything goes wrong — cache miss, concurrent rename, sleeping lock needed — the walker abandons RCU mode and restarts as **REF-walk**, which takes spinlocks and increments reference counts in the conventional way. The guiding philosophy is: *try quickly and check; if that fails, try slowly*.

## How It Works

### Entry points and nameidata

Every path lookup ultimately enters `filename_lookup()` or `path_openat()` in `fs/namei.c`. The caller specifies a filename, a starting directory file descriptor (`dfd`), and a set of `LOOKUP_*` flags. These functions allocate a `struct nameidata` on the stack and pass it to `path_lookupat()` (for non-open lookups) or `path_openat()` (for `open(2)`).

`struct nameidata` is the cursor that tracks the walk's current state:

```c
struct nameidata {
    struct path   path;       /* current position: (vfsmount*, dentry*) */
    struct qstr   last;       /* the next component to look up (name + hash + len) */
    struct path   root;       /* effective root for this walk (set by LOOKUP_IN_ROOT etc.) */
    struct inode  *inode;     /* inode of path.dentry, cached for convenience */
    unsigned int  flags;      /* LOOKUP_* flags */
    unsigned int  state;      /* ND_* internal state bits */
    unsigned      seq;        /* d_seq of current dentry (RCU-walk only) */
    unsigned      m_seq;      /* mount_lock sequence number (RCU-walk only) */
    int           last_type;  /* LAST_NORM, LAST_DOT, LAST_DOTDOT, LAST_ROOT */
    unsigned      depth;      /* symlink nesting depth */
    int           total_link_count; /* total symlinks followed */
    struct saved  stack[MAXSYMLINKS]; /* symlink remnant stack */
    /* … */
};
```

Absolute paths (`/foo/bar`) start at the process's filesystem root (`current->fs->root`); relative paths start at the AT_FDCWD current directory or the directory indicated by the `dfd` argument. The initial `path` and `inode` are installed before entering the main walk loop.

### RCU-walk: the lockless fast path

`link_path_walk()` is called holding `rcu_read_lock()` and with `nd->flags & LOOKUP_RCU` set. It loops over each slash-separated component of the path:

1. **Permission check**: verifies execute permission on the current directory inode. In RCU-walk this is done without taking `i_rwsem` — the permission check may call `inode_permission()` which either succeeds without locks or returns `-ECHILD` to force a fallback.

2. **Component extraction**: scans the path string to find the next `/`, computing the name's hash. Special names (`.`, `..`, and empty components) are classified in `nd->last_type`.

3. **`walk_component(nd, flags)`**: processes one component:
   - For `.` (LAST_DOT): no movement, just return.
   - For `..` (LAST_DOTDOT): `handle_dots()` walks up to the parent. In RCU-walk, this reads `dentry->d_parent` under `rcu_read_lock()` and validates it with `read_seqcount_retry(d_seq)`. At a mount root, it must also cross back to the covering mount; this is done via `follow_dotdot_rcu()` which reads `mnt->mnt_parent` and checks `mount_lock` has not changed.
   - For a normal name: `lookup_fast()` is tried first.

### lookup_fast: dcache lookup under RCU

`lookup_fast()` calls `__d_lookup_rcu(parent, name, &seq)` which looks up the dentry in the global hash table (`dentry_hashtable`) using a `hlist_bl_head` bit-locked bucket, but under RCU-walk it uses only `rcu_read_lock()` — not the bucket's spinlock. It finds a candidate dentry, samples `d_seq`, reads `d_inode`, and returns. The caller (`walk_component`) then calls `d_revalidate()` if the dentry has `d_op->d_revalidate` set (e.g. network filesystems), and confirms the dentry is still valid.

Validity is confirmed by calling `read_seqcount_retry(&dentry->d_seq, seq)` — if the sequence number changed between the sample and this check, a concurrent rename or unlink happened and the result is stale. The walker then returns `-ECHILD` to trigger REF-walk fallback.

The key insight: throughout all of this, the walker has made **no writes to shared memory**. No reference count was incremented, no spinlock was taken. On a 32-core system with 32 threads all looking up files in the same directory, RCU-walk allows all 32 to proceed in parallel without any cacheline bouncing.

### Mount crossing in RCU-walk

After resolving a component dentry, `step_into()` checks whether it is a mount point by calling `follow_managed()`. In RCU-walk, mount traversal uses `__follow_mount_rcu()`: it reads `dentry->d_flags` to check `DCACHE_MOUNTED`, then iterates through the mount table via `lookup_mnt_rcu()` which looks up the `(mnt, dentry)` pair in the mount hash table under `rcu_read_lock()`. The result is validated against `nd->m_seq` — a single sequence number sampled from `mount_lock` at walk start. If `mount_lock` has changed (a mount/umount occurred), `nd->m_seq` validation fails and the walk falls back.

### Fallback: completing the transition to REF-walk

Any time RCU-walk cannot proceed — cache miss, revalidation needed, `d_seq` changed, sleeping lock required — the walk calls `unlazy_walk()` (or `unlazy_child()` if a child dentry was already found). These functions:

1. Pin the current and root vfsmounts with `mntget()`.
2. Pin the current dentry with `dget()`.
3. Clear `LOOKUP_RCU` from `nd->flags`.
4. Call `rcu_read_unlock()`.

After `unlazy_walk()`, the walk continues in REF-walk mode: `lookup_fast()` falls back to `__d_lookup()` which takes the bucket's bit-spinlock, and `step_into()` calls `mntget()` on each crossed mount.

### Cache miss: lookup_slow

If `lookup_fast()` returns NULL (the component is not in the dcache), `lookup_slow()` is called. It acquires the parent directory's `i_rwsem` in shared mode (read lock), calls `__d_lookup()` again under the lock (to eliminate a race where another thread just inserted the dentry), and if still absent, calls `d_alloc_parallel()` followed by `inode->i_op->lookup(dir_inode, dentry, flags)` — the filesystem's own lookup, which reads the directory from disk or fetches it from the server. On return, the new dentry is inserted into the dcache and the `i_rwsem` is released.

`d_alloc_parallel()` handles the case where two threads miss the cache for the same name simultaneously: it inserts the new dentry into a secondary hash table with `DCACHE_PAR_LOOKUP` set, so the second thread finds it, waits on a waitqueue, and retries rather than issuing two disk reads for the same component.

### Symlinks

When `step_into()` finds that the resolved dentry is a symlink and `LOOKUP_FOLLOW` is set, it calls `pick_link()`. Rather than recursing, `pick_link()` saves the current path remnant and position onto the symlink stack (`nd->stack[nd->depth]`), then restarts `link_path_walk()` from the symlink target. This is the **non-recursive** approach introduced in 4.2 — the symlink stack is a fixed-depth explicit array rather than a call stack, eliminating kernel stack overflow risk.

The symlink target string is obtained via `inode->i_op->get_link(dentry, inode, &delay)`. Filesystems that store short symlinks in the inode itself (ext4 fast symlinks, tmpfs) return a pointer to the inline string directly — these work in RCU-walk because the string is stable as long as the inode exists. Filesystems that store symlink content in the page cache must call `page_get_link()`, which may need to wait for I/O — this returns `-ECHILD` in RCU-walk mode, forcing a fallback before retrying.

The total symlink count (`nd->total_link_count`) is capped at 40 (`MAXSYMLINKS`). This limit exists not primarily to prevent loops (which could be detected otherwise) but to prevent CPU exhaustion: a crafted directory tree with many symlinks could otherwise force unbounded work per lookup.

**Magic links** (e.g. `/proc/$PID/fd/N`) are a special symlink variant that calls `nd_jump_link()` to relocate the walk cursor to an arbitrary path — they can cross filesystems and namespaces. They are controlled by `LOOKUP_NO_MAGICLINKS`.

### Final component handling

`link_path_walk()` processes only the *non-final* components, returning with `nd->last` set to the final component name. The caller then handles it differently depending on the syscall:

- **`path_lookupat()`**: calls `lookup_last(nd)` which resolves the final component via `walk_component()`, following trailing slashes (which indicate a directory is expected) and symlinks if `LOOKUP_FOLLOW` is set. Used by `stat`, `access`, `chdir`, etc.
- **`path_parentat()`**: returns the parent directory and the final component name *without* looking up the final name. Used by `mkdir`, `unlink`, `rename`, `link` — syscalls that need to operate on the parent directory.
- **`path_openat()`**: handles `O_CREAT` atomicity via `do_last()` which uses `atomic_open()` if the filesystem provides it (NFS, local filesystems with `create` support) to test-and-create in one round trip.

### openat2 restriction flags

`openat2(2)` (5.6) exposes additional lookup restriction flags to userspace, enabling sandboxed file access:

| Flag | Effect |
|------|--------|
| `RESOLVE_NO_SYMLINKS` | refuse all symlinks |
| `RESOLVE_NO_MAGICLINKS` | refuse magic-link traversal |
| `RESOLVE_NO_XDEV` | refuse mount-point crossings |
| `RESOLVE_BENEATH` | refuse `..` that exits the starting directory |
| `RESOLVE_IN_ROOT` | treat starting directory as root (no `..` escape) |

These map internally to `LOOKUP_NO_SYMLINKS`, `LOOKUP_NO_MAGICLINKS`, `LOOKUP_NO_XDEV`, `LOOKUP_BENEATH`, `LOOKUP_IN_ROOT`. The kernel uses `rename_lock` and `mount_lock` to detect attacks where a raced rename moves a directory outside the protected boundary mid-walk.

## Key Data Structures

**`struct nameidata`** (`fs/namei.c`, internal) — per-walk cursor; holds current `path`, `inode`, seqlock samples, symlink stack, and `LOOKUP_*` flags. Stack-allocated by each lookup entry point.

**`struct path`** (`include/linux/path.h`) — `(vfsmount*, dentry*)` pair; represents a specific filesystem location including which mount instance it is on.

**`struct qstr`** (`include/linux/dcache.h`) — hashed, length-prefixed component name: `{hash_len, name}`. Used to avoid re-hashing the same component in repeated lookups.

**`struct saved`** (internal to `struct nameidata`) — one symlink stack frame: path remnant string, previous `struct path`, previous inode, sequence number, and `struct delayed_call` for cleanup.

## Key Functions / Entry Points

**`filename_lookup(dfd, name, flags, path, root)`** (`fs/namei.c`) — top-level entry for non-open lookups; allocates `nameidata`, calls `path_lookupat()`, handles audit.

**`path_openat(dfd, op, flags)`** (`fs/namei.c`) — top-level entry for `open(2)`; manages O_CREAT, O_EXCL, atomic_open.

**`link_path_walk(name, nd)`** (`fs/namei.c`) — main loop; processes non-final components one at a time in either RCU or REF walk mode.

**`walk_component(nd, flags)`** (`fs/namei.c`) — resolves one component: dots, cache lookup, slow lookup, mount crossing, symlink handling.

**`lookup_fast(nd, inode, seqp)`** (`fs/namei.c`) — RCU-mode dcache lookup using `__d_lookup_rcu()`; returns NULL on miss.

**`lookup_slow(nd, path)`** (`fs/namei.c`) — takes `i_rwsem`, calls filesystem's `i_op->lookup()`, inserts into dcache.

**`unlazy_walk(nd)`** (`fs/namei.c`) — converts RCU-walk to REF-walk by taking references on current path.

**`step_into(nd, flags, dentry)`** (`fs/namei.c`) — after resolving a component dentry, checks for mounts and symlinks and advances `nd->path`.

**`d_alloc_parallel(parent, name)`** (`fs/dcache.c`) — allocates a new dentry and handles parallel lookups of the same name via secondary hash + waitqueue.

## Important Flags & Config Options

| Flag | Meaning |
|------|---------|
| `LOOKUP_RCU` | internal: currently in RCU-walk mode |
| `LOOKUP_FOLLOW` | follow symlinks in the final component |
| `LOOKUP_DIRECTORY` | require the result to be a directory |
| `LOOKUP_AUTOMOUNT` | trigger automounts on final component |
| `LOOKUP_OPEN` | lookup is part of an open operation |
| `LOOKUP_CREATE` | O_CREAT; final component may be created |
| `LOOKUP_EXCL` | O_EXCL; fail if final component exists |
| `LOOKUP_REVAL` | force `d_revalidate` even for valid dentries (NFS, CIFS) |
| `LOOKUP_NO_SYMLINKS` | `openat2` restriction: no symlinks |
| `LOOKUP_BENEATH` | `openat2` restriction: no escaping starting dir |
| `LOOKUP_IN_ROOT` | `openat2` restriction: starting dir acts as root |

## Interactions with Other Subsystems

- **↑ Userspace**: every filename-taking syscall (`open`, `stat`, `execve`, `mkdir`, …) invokes path lookup; `openat2(2)` directly controls restriction flags.
- **→ [[Dentry Cache]]**: every component resolution hits the dcache hash table first; misses go to the filesystem and populate the cache.
- **→ [[Inode]]**: the resolved dentry yields the inode; permission checks use `inode->i_op->permission()`.
- **→ [[Mount Namespace]]**: mount-point crossings read the mount hash table; `nd->m_seq` tracks the global `mount_lock` for RCU validation.
- **← RCU**: `rcu_read_lock()` protects all pointer reads in RCU-walk; `call_rcu()` deferred freeing ensures dentry structs are not reused while RCU readers hold pointers.
- **→ [[Filesystem Registration]]**: each component miss calls `inode->i_op->lookup()`, dispatching to the registered filesystem's own lookup implementation.
- **→ [[File Object]]**: `path_openat()` terminates by calling `do_open()` which allocates the `struct file` and calls `f_op->open()`.

## Design Decisions & Tradeoffs

**No writes in RCU-walk**: The original observation (Nick Piggin, 2010) was that on multi-core systems, reference count increments and decrements on the hot dcache path caused severe cacheline bouncing. The fix was to make the common case (cache hit, no mount crossing, no symlink) write-free: the walk samples seqlocks and trusts that the data is consistent, validating only at key checkpoints. The cost is implementation complexity — every RCU-walk operation must be written to be safe under concurrent modification.

**Seqlock per-dentry rather than per-bucket**: Using `d_seq` (a per-dentry seqcount) rather than a per-hash-bucket seqlock allows writers to affect only the single entry they are modifying, preventing false-positive fallbacks in adjacent entries. The per-dentry granularity means that a rename of `/a/b` does not invalidate in-progress lookups of `/x/y/z`.

**Single mount_lock for all mounts**: While per-dentry seqlocks give fine-grained validation for the dentry tree, a single `mount_lock` seqlock covers all mount point crossings. This is coarser but simplifies the mount table code; mount operations are rare enough that the occasional false fallback is acceptable.

**Non-recursive symlink stack**: Before 4.2, symlink following was recursive — each symlink caused a new call to `link_path_walk()`, consuming kernel stack. With 40 symlinks each potentially triggering recursive calls, stack overflow was possible. The explicit stack approach (4.2) bounds stack consumption regardless of symlink depth.

**`-ECHILD` as RCU fallback signal**: Rather than maintaining two entirely separate code paths, the RCU-walk and REF-walk code is deeply interleaved. Any RCU-walk function that cannot proceed safely returns `-ECHILD` (chosen because it is not a real filesystem error code in this context), which propagates upward to the loop in `path_lookupat()` that detects it and calls `unlazy_walk()` before retrying. This keeps the common path and fallback path maximally shared.

## How It Has Evolved

- **2.4**: Single global `dcache_lock` for all dentry operations; path lookup fully serialized on this lock.
- **2.6.28** (2008): "store-free path walking" (Nick Piggin): partial prototype for lockless lookup; not yet merged.
- **2.6.38** (2011): RCU-walk merged (Nick Piggin's 46-patch series); eliminates refcount writes on the hot path; `d_seq` seqcount per dentry; `mount_lock` for mount traversal.
- **3.1** (2011): `lockref` atomic lock+refcount for `d_lockref`, enabling atomic "lock; decrement; unlock" in `dput()`.
- **4.2** (2015): Non-recursive symlink following (Neil Brown); symlink stack replaces call-stack recursion.
- **4.2** (2015): `get_link()` replaces `follow_link()`/`put_link()` vtable callbacks; RCU symlink following for inode-stored symlinks.
- **5.6** (2020): `openat2(2)` syscall exposing restriction flags (`RESOLVE_BENEATH`, `RESOLVE_IN_ROOT`, etc.) to userspace.
- **5.8** (2020): `LOOKUP_CACHED` flag for lookup that must not block (for io_uring and other async paths).

## Further Reading

1. [Pathname lookup in Linux — LWN.net](https://lwn.net/Articles/649115/)
2. [RCU-walk: faster pathname lookup in Linux — LWN.net](https://lwn.net/Articles/649729/)
3. [A walk among the symlinks — LWN.net](https://lwn.net/Articles/650786/)
4. [Dcache scalability and RCU-walk — LWN.net](https://lwn.net/Articles/419811/)
5. [Path lookup documentation — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/path-lookup.html)

## LKML Highlights

- **RCU-walk introduction** — Nick Piggin (2010): 46-patch series (`[PATCH 33/46] fs: rcu-walk for path lookup`); the core design debate was how to handle the case where two concurrent RCU-walk lookups need to insert a new dentry (resolved via `d_alloc_parallel()` and the secondary hash table with `DCACHE_PAR_LOOKUP`).
- **Non-recursive symlinks** — Neil Brown (2015): replacing recursive `link_path_walk()` calls with an explicit stack; the key review question was whether the stack depth of 40 was sufficient and whether the `delayed_call` mechanism for cleanup was safe in all filesystem implementations.
- **openat2 restrictions** — Aleksa Sarai (2019–2020): the `RESOLVE_BENEATH`/`RESOLVE_IN_ROOT` flags were motivated by container runtimes (runc) needing safe file access inside container roots without TOCTOU races; the debate centered on whether `rename_lock` + `mount_lock` was sufficient to detect "escape" attacks or whether additional per-component checks were needed.
