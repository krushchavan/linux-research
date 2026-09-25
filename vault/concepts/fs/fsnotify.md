---
title: "fsnotify"
category: concept
tags: [fs, vfs, fsnotify, inotify, fanotify, notifications]
subsystem: fs
kernel_version: "2.6.36"
researched: 2026-04-05
status: complete
explained: "[[fsnotify-explained]]"
sources:
  - https://lwn.net/Articles/318618/
  - https://lwn.net/Articles/604686/
  - https://lwn.net/Articles/339399/
  - https://lwn.net/Articles/718802/
  - https://lwn.net/Articles/311350/
  - https://github.com/torvalds/linux/blob/master/include/linux/fsnotify_backend.h
---

# fsnotify

> 📘 Plain-language version: [[fsnotify-explained]]

## Purpose

fsnotify is the kernel-internal backbone that powers all Linux filesystem event notification APIs: dnotify, inotify, and fanotify. Before fsnotify, each of these was an independent implementation with its own VFS hooks, its own locking, and its own event queuing code. fsnotify extracts the common infrastructure — mark attachment to filesystem objects, event generation at VFS hook points, and delivery to registered listeners — into one framework that each user-facing API plugs into as a backend.

## Mental Model

The framework works on three concepts: **marks**, **groups**, and **events**.

A *mark* is a sticky note attached to a filesystem object (inode, vfsmount, or superblock) that says "notify group G when events matching mask M happen to this object." A *group* is a subscriber — an open inotify fd, an open fanotify fd, etc. — with its own event queue and its own vtable for handling events. When the VFS performs a filesystem operation, it fires the appropriate hook; fsnotify walks the marks on the affected objects and, for each mark whose mask matches the event, delivers a notification to the mark's owning group.

## How It Works

### VFS hook points

fsnotify intercepts filesystem operations through a set of inline helper functions in `include/linux/fsnotify.h` that are called directly in the VFS path. Key hooks include:

| Hook | Called from | Events |
|------|-------------|--------|
| `fsnotify_open(file)` | `do_open()` | `FS_OPEN` |
| `fsnotify_access(file)` | `read_iter` path | `FS_ACCESS` |
| `fsnotify_modify(file)` | `write_iter` path | `FS_MODIFY` |
| `fsnotify_close(file, mode)` | `filp_close()` | `FS_CLOSE_WRITE`, `FS_CLOSE_NOWRITE` |
| `fsnotify_attrib(inode)` | `notify_change()`, `setattr` | `FS_ATTRIB` |
| `fsnotify_create(dir, entry)` | `vfs_create()` | `FS_CREATE` |
| `fsnotify_mkdir(dir, entry)` | `vfs_mkdir()` | `FS_CREATE | FS_ISDIR` |
| `fsnotify_move(old_dir, new_dir, old_name, new_name, ...)` | `vfs_rename()` | `FS_MOVED_FROM`, `FS_MOVED_TO` |
| `fsnotify_delete(dir, inode, entry)` | `vfs_unlink()`, `vfs_rmdir()` | `FS_DELETE` |
| `fsnotify_link(old_dentry, new_dir, new_dentry)` | `vfs_link()` | `FS_CREATE` |

Each helper constructs an event descriptor and calls the core `fsnotify(inode, mask, ...)` function. On the fast path — no marks at all on the object — the hook is a single test of a bit in `inode->i_fsnotify_mask` (a cached union of all marks on that inode) that allows immediate return with no further work.

### fsnotify_group: the subscriber

Every user-facing notification fd (one `inotify_init()` call, one `fanotify_init()` call) corresponds to one `struct fsnotify_group`:

```c
struct fsnotify_group {
    const struct fsnotify_ops *ops;    /* backend vtable: handle_event, free_group, etc. */
    struct srcu_struct         notif_lock;  /* protect mark list operations */
    struct list_head           marks_list; /* all marks owned by this group */
    struct fsnotify_event      *overflow_event; /* event sent when queue overflows */

    /* Event queue */
    struct mutex               notification_mutex;
    struct list_head           notification_list; /* queued events */
    wait_queue_head_t          notification_waitq;
    unsigned int               q_len;    /* current queue depth */
    unsigned int               max_events; /* limit; overflow triggers overflow_event */

    unsigned int               priority;  /* groups iterated in priority order */
    bool                       shutdown;

    refcount_t                 refcnt;
};
```

The `ops` vtable (`struct fsnotify_ops`) is the key extension point:

| Callback | Called when |
|----------|-------------|
| `handle_event(group, inode, mask, data, ...)` | An event matches a mark in this group |
| `free_group_priv(group)` | Group reference count reaches zero |
| `freeing_mark(mark, group)` | A mark is being removed |
| `free_event(group, event)` | Event is consumed and should be freed |

### fsnotify_mark: the inode/mount/sb attachment

A `struct fsnotify_mark` connects a group to a specific object:

```c
struct fsnotify_mark {
    __u32                mask;          /* events of interest (FS_MODIFY, FS_OPEN, …) */
    struct fsnotify_group *group;       /* owning group */
    struct list_head      g_list;       /* entry in group->marks_list */
    spinlock_t            lock;
    struct hlist_node     obj_list;     /* entry in fsnotify_mark_connector->list */
    struct fsnotify_mark_connector *connector; /* the object this mark is on */
    __u32                 ignored_mask; /* events explicitly ignored */
    unsigned int          flags;        /* FSNOTIFY_MARK_FLAG_INODE, _VFSMOUNT, _SB */
    refcount_t            refcnt;
};
```

Adding a watch (`inotify_add_watch()`, `fanotify_mark()`) allocates a `struct fsnotify_mark`, initialises its `mask`, and calls `fsnotify_add_mark()` which attaches it to the target object's `fsnotify_mark_connector`.

### fsnotify_mark_connector: per-object mark list

Every inode that has at least one mark has a `struct fsnotify_mark_connector *` stored in `inode->i_fsnotify_marks` (for inode marks), `vfsmount->mnt_fsnotify_marks` (for mount marks), or `super_block->s_fsnotify_marks` (for superblock marks). The connector holds:

- `hlist_head list` — all marks attached to this object.
- `type` — FSNOTIFY_OBJ_TYPE_INODE, _VFSMOUNT, or _SB.
- A back-reference to the object.

The connector exists as long as any mark is attached; when the last mark is removed, the connector is freed. The inode (or mount/sb) stores only a pointer, not the connector inline, so objects that are never watched pay zero cost.

`inode->i_fsnotify_mask` is a cached bitwise OR of all `mark->mask` values for inode-level marks on this inode. The VFS hook checks this field first; if the event bit is not set, the hook returns immediately without any list traversal.

### Event generation and delivery

When an event fires, `fsnotify(inode, mask, data, data_type, file_name, cookie)` is called:

1. **Object determination**: builds an `fsnotify_iter_info` covering three mark lists: inode marks on the affected inode, vfsmount marks on the current vfsmount, and superblock marks on the superblock.

2. **SRCU read lock**: acquires `srcu_read_lock(&fsnotify_mark_srcu)`. This is a Sleepable RCU — writers (mark add/remove) can sleep; readers (event delivery) hold a sleepable read lock rather than a spinlock. This matters because `handle_event()` may sleep (fanotify permission events block until userspace responds).

3. **Group iteration**: for each unique group that has a mark on any of the three objects, with a combined mask matching the event, calls `group->ops->handle_event()`.

4. **SRCU unlock**: drops the read lock.

The choice of SRCU (rather than plain RCU or a spinlock) is central to fanotify's correctness: permission events require the kernel to wait for a userspace response, which may take seconds. A spinlock read-side or non-sleepable RCU would make this impossible.

### inotify: fd-based per-file watching

inotify is implemented in `fs/notify/inotify/` entirely on top of fsnotify. `inotify_init1()` allocates an `fsnotify_group` with `inotify_fsnotify_ops` as the vtable. `inotify_add_watch(fd, pathname, mask)` allocates a mark on the target inode. When an event fires, `inotify_handle_inode_event()` (the `handle_event` callback) allocates an `inotify_event_info` and appends it to the group's notification list. Userspace reads events with `read(fd, buf, len)`.

The watch descriptor (wd) returned by `inotify_add_watch` is an integer allocated from the group's IDR that maps to the `fsnotify_mark`. On `IN_IGNORED` (watch removal), the mark is removed and an `IN_IGNORED` event is queued.

### fanotify: permission events and global listeners

fanotify (`fs/notify/fanotify/`) uses the same fsnotify backbone but extends it with two capabilities inotify lacks:

**Permission events** (`FAN_OPEN_PERM`, `FAN_ACCESS_PERM`, `FAN_OPEN_EXEC_PERM`): when one of these events fires, `fanotify_handle_event()` creates a `fanotify_perm_event` that contains a kernel hold: the kernel blocks the triggering process (sets it to `TASK_KILLABLE` sleep) until the fanotify listener reads the event and writes back an `allow` or `deny` response via `write(fd, &response, sizeof(response))`. This enables userspace malware scanners and DLP tools.

**Mount and superblock marks**: `fanotify_mark(fd, FAN_MARK_ADD, mask, AT_FDCWD, NULL)` with `FAN_MARK_FILESYSTEM` attaches a mark to the superblock rather than to individual inodes, matching all events anywhere on that filesystem. This avoids the O(n) per-file watch registration that inotify requires for large trees.

### dnotify: legacy directory watching

dnotify (`fs/notify/dnotify/`) is the oldest API (2.4.0). It attaches marks to inodes of open directories and delivers notifications via `SIGIO` or a specified real-time signal. It remains in the kernel for compatibility but is rarely used in new code.

## Key Data Structures

**`struct fsnotify_group`** (`include/linux/fsnotify_backend.h`) — one notification subscriber; owns a mark list and an event queue; event queue is drained by `read(fd)`.

**`struct fsnotify_mark`** (`include/linux/fsnotify_backend.h`) — one watch: `mask` of events, pointer to group, pointer to connector; protected by SRCU.

**`struct fsnotify_mark_connector`** (`include/linux/fsnotify_backend.h`) — per-object list of marks; stored in `inode->i_fsnotify_marks`, `mnt->mnt_fsnotify_marks`, or `sb->s_fsnotify_marks`.

**`struct fsnotify_event`** (`include/linux/fsnotify_backend.h`) — base class for queued events; subclassed by inotify and fanotify for their private event data.

**`inode->i_fsnotify_mask`** — cached OR of all mask values on inode marks; checked in every VFS hook for fast no-op return.

## Key Functions / Entry Points

**`fsnotify(inode, mask, data, data_type, file_name, cookie)`** (`fs/notify/fsnotify.c`) — core dispatch; iterates marks on inode+mount+sb, calls `handle_event` for each matching group.

**`fsnotify_add_mark(mark, connp, type, allow_dups, fsn_mutex)`** (`fs/notify/mark.c`) — attaches a mark to a connector; updates the object's cached mask.

**`fsnotify_remove_mark(mark)`** (`fs/notify/mark.c`) — detaches a mark; decrements the object's cached mask; frees mark when refcount reaches zero.

**`inotify_add_watch(fd, pathname, mask)`** — userspace; internally calls `fsnotify_add_mark()` on the target inode.

**`fanotify_mark(fd, flags, mask, dfd, pathname)`** — userspace; attaches inode/mount/sb mark depending on `FAN_MARK_INODE/MOUNT/FILESYSTEM`.

**`__fsnotify_inode_delete(inode)`** (`fs/notify/fsnotify.c`) — called when an inode is freed; removes all marks and frees the connector.

## Important Flags & Config Options

| Flag | Meaning |
|------|---------|
| `FS_ACCESS` | File was read |
| `FS_MODIFY` | File was written |
| `FS_ATTRIB` | Metadata changed (chmod, chown, utimes) |
| `FS_CREATE` | File/dir created in watched dir |
| `FS_DELETE` | File/dir deleted in watched dir |
| `FS_MOVED_FROM / FS_MOVED_TO` | File moved out/into watched dir |
| `FS_OPEN` | File opened |
| `FS_CLOSE_WRITE / FS_CLOSE_NOWRITE` | Writable/read-only fd closed |
| `FS_OPEN_PERM / FS_ACCESS_PERM` | fanotify permission event |
| `FAN_MARK_INODE / _MOUNT / _FILESYSTEM` | fanotify mark scope |
| `CONFIG_FSNOTIFY` | Kconfig: enable fsnotify framework |
| `CONFIG_INOTIFY_USER` | Kconfig: enable inotify userspace API |
| `CONFIG_FANOTIFY` | Kconfig: enable fanotify |
| `CONFIG_FANOTIFY_ACCESS_PERMISSIONS` | Kconfig: enable permission events |
| `/proc/sys/fs/inotify/max_user_watches` | max inotify watches per user (default 8192) |
| `/proc/sys/fs/inotify/max_queued_events` | max queued events per group (default 16384) |

## Interactions with Other Subsystems

- **↑ Userspace**: `inotify_init1(2)`, `inotify_add_watch(2)`, `fanotify_init(2)`, `fanotify_mark(2)` — all create/manipulate fsnotify groups and marks; events are read with `read(2)` and `poll(2)`/`epoll`.
- **→ [[VFS]]**: every vfs_create/vfs_unlink/vfs_rename/notify_change call fires an fsnotify hook; the cost on the fast path (no marks) is one `&` test on `inode->i_fsnotify_mask`.
- **→ [[Inode]]**: marks are stored in `inode->i_fsnotify_marks`; `inode->i_fsnotify_mask` is the hot-path cache; `__fsnotify_inode_delete()` cleans up marks when the inode is freed.
- **→ [[Mount Namespace]]**: vfsmount marks are stored in `vfsmount->mnt_fsnotify_marks`; this means a fanotify mount watch is namespace-specific — two namespaces with the same underlying superblock can have independent mount-level watches.
- **← Security (LSM)**: `security_inode_notify()` hook allows LSMs to filter or deny notification delivery; used by SELinux and AppArmor to prevent leaking file access info across security domains.

## Design Decisions & Tradeoffs

**SRCU for mark iteration**: Using Sleepable RCU (rather than a mutex or plain RCU) for the mark list allows `handle_event()` to block — which fanotify permission events require — while still allowing multiple concurrent readers (event deliveries on different CPUs). Plain RCU would disallow sleeping; a mutex would serialize all event delivery system-wide.

**Cached `i_fsnotify_mask`**: Every VFS write path must check whether any listener wants to know about the operation. The cached bitmask trades a small amount of mark-add/remove complexity (updating the cache) for a near-zero cost on the common (unmonitored) path. Without the cache, every `write()` on an unwatched file would still walk a list.

**Superblock marks vs. recursive inode marks**: For malware scanning and backup tools, watching every inode individually requires O(n) registration. Superblock-level marks provide O(1) registration for "watch everything" use cases. The tradeoff is coarser event filtering — superblock marks cannot exclude subtrees without per-inode ignored masks.

**fanotify permission events as a blocking primitive**: Permission events require the kernel thread performing the file open to block until a userspace decision arrives. This is powerful (enables real-time access control) but dangerous: a fanotify listener that crashes or becomes unresponsive can hang all openers of watched files. A 5-second timeout (in early versions; later removed from the mainline) was debated extensively — the final consensus was to provide `FAN_UNLIMITED_QUEUE` and `FAN_NONBLOCK` flags and let the privileged listener be responsible for responsiveness.

## How It Has Evolved

- **2.4.0** (2001): dnotify introduced — directory-only, signal-based.
- **2.6.13** (2005): inotify introduced — fd-based, file and dir watching, richer events.
- **2.6.36** (2010): fsnotify unified backend introduced; dnotify and inotify reimplemented as backends.
- **2.6.37** (2011): fanotify merged; permission events; mount-level marks.
- **4.20** (2018): fanotify filesystem (superblock) marks added.
- **5.1** (2019): fanotify gained `FAN_REPORT_FID` — event includes a file handle (fsid + fhandle) rather than an open fd, allowing use without opening the file.
- **5.9** (2020): fanotify directory entry events (`FAN_CREATE`, `FAN_DELETE`, `FAN_MOVE`) with `FAN_REPORT_DFID_NAME` providing parent dir + filename in events.
- **5.13** (2021): fanotify filesystem-error events (`FAN_FS_ERROR`) for file system corruption monitoring.

## Further Reading

1. [fsnotify, dnotify, and inotify — LWN.net](https://lwn.net/Articles/311350/)
2. [fsnotify: unified filesystem notification backend — LWN.net](https://lwn.net/Articles/318618/)
3. [Filesystem notification, part 1: overview — LWN.net](https://lwn.net/Articles/604686/)
4. [The fanotify API — LWN.net](https://lwn.net/Articles/339399/)
5. [Superblock watch for fsnotify — LWN.net](https://lwn.net/Articles/718802/)

## LKML Highlights

- **fsnotify unification** — Eric Paris (2009–2010): The key challenge was that dnotify and inotify had subtly different semantics at the VFS hook level — some hooks fired before the operation, some after. The unification required auditing all 40+ hook call sites and ensuring the unified framework preserved each API's observable behaviour.
- **fanotify merge** — Eric Paris (2010): The most contested point was permission events. Al Viro and others argued that blocking userspace processes in kernel paths on an unresponsive daemon was unsafe without a timeout. The compromise was making permission-event support a separate `CONFIG_FANOTIFY_ACCESS_PERMISSIONS` Kconfig option, requiring `CAP_SYS_ADMIN` to use.
- **fanotify FAN_REPORT_FID** — Amir Goldstein (2018–2019): Addressed the long-standing problem that fanotify events delivered open file descriptors, which was costly (open fd allocation per event) and created race conditions with unprivileged processes. File handles (fsid + fhandle) are stable identifiers that don't require the file to remain open.
