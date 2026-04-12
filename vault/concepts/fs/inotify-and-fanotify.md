---
title: "inotify and fanotify"
category: concept
tags: [fs, vfs, inotify, fanotify, fsnotify, notifications]
subsystem: fs
kernel_version: "2.6.13"
researched: 2026-04-12
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/inotify.html
  - https://www.man7.org/linux/man-pages/man7/inotify.7.html
  - https://www.man7.org/linux/man-pages/man7/fanotify.7.html
  - https://lwn.net/Articles/604686/
  - https://lwn.net/Articles/605128/
  - https://lwn.net/Articles/339399/
  - https://lwn.net/Articles/311350/
  - https://lwn.net/Articles/185464/
---

# inotify and fanotify

## Purpose

inotify and fanotify are the two primary Linux APIs for watching filesystem events from userspace. inotify (2.6.13, 2005) replaced the older dnotify, offering a clean fd-based model that watches individual files and directories without keeping them open. fanotify (2.6.37, 2011) goes further: it can watch entire mounts or filesystems with a single mark, and it supports *permission events* that block the originating syscall until userspace issues an allow/deny verdict — the primitive that makes userspace malware scanners and DLP agents possible. Both are built on top of the [[fsnotify]] unified backend; the kernel mechanism is the same, the surface APIs differ in scope and capability.

## Mental Model

Think of inotify as a targeted surveillance camera: you explicitly point it at named paths and it reports what happens to them. fanotify is a city-wide CCTV system: a single mark covers an entire filesystem, and the control room can halt any event in progress until an operator clears it. The underlying switch-board routing events to cameras is fsnotify — inotify and fanotify are just different front-end consoles wired to the same switch.

## How It Works

### inotify: fd-based per-inode watching

The journey starts with `inotify_init1(flags)`. A single call allocates an `fsnotify_group` in the kernel and returns a file descriptor to the caller. All subsequent watches are funnelled through this one fd. The `flags` argument accepts `IN_CLOEXEC` and `IN_NONBLOCK` — the 1-suffixed variant was added in 2.6.27 specifically to support these flags without a separate `fcntl` call.

Adding a watch with `inotify_add_watch(inotifyfd, pathname, mask)` is where the inode-level bookkeeping begins. The kernel resolves `pathname` to an inode and looks for an existing `inotify_inode_mark` on that inode owned by this group. If one already exists, `inotify_add_watch()` returns the same watch descriptor (wd) and updates the mask — this idempotency is intentional and lets callers safely re-add watches during directory rescans without worrying about duplicates. If no mark exists, a new `struct inotify_inode_mark` is allocated, embedded in an `fsnotify_mark`, and attached to the inode's `i_fsnotify_marks` connector via `fsnotify_add_mark()`. A watch descriptor — a positive integer — is allocated from the group's IDR (`idr_alloc`) and stored in the mark. The kernel's cached `inode->i_fsnotify_mask` is updated to include the new event bits, making future VFS hooks free on the fast path for unaffected inodes.

When, say, another process writes to the watched file, the VFS write path calls `fsnotify_modify(file)`. fsnotify tests `inode->i_fsnotify_mask` — if `FS_MODIFY` is not set, it returns immediately. Otherwise it iterates marks on the inode (and the active vfsmount and superblock, for fanotify) via an SRCU read lock. For the inotify group, `inotify_handle_inode_event()` is invoked. It allocates a `struct inotify_event_info` (which embeds an `fsnotify_event`) and appends it to the group's `notification_list`. It also wakes the wait queue so any blocked `read()` or `poll()` on the inotify fd returns. The event is laid out in userspace as `struct inotify_event`:

```c
struct inotify_event {
    int    wd;     /* Watch descriptor — which path triggered this */
    __u32  mask;   /* Event type (IN_MODIFY, IN_CREATE, etc.)       */
    __u32  cookie; /* Links paired IN_MOVED_FROM / IN_MOVED_TO      */
    __u32  len;    /* Bytes of name[] field (0 if no name)          */
    char   name[]; /* NUL-terminated filename (if present)          */
};
```

The `cookie` field deserves special attention: renames produce two separate events (IN_MOVED_FROM on the source directory, IN_MOVED_TO on the destination directory), and the kernel assigns both the same cookie value so userspace can pair them. If the read buffer only catches one of the pair, userspace has to use a short timeout (typically 2 ms) to decide whether to wait for the matching event or treat it as a half-rename.

**Queue overflow** is signalled by a synthetic `IN_Q_OVERFLOW` event (wd = -1) when the group's queue depth exceeds `/proc/sys/fs/inotify/max_queued_events` (default 16 384). Subsequent events are silently dropped until the application drains the queue. The recommended recovery is to close the fd, rebuild the watch set, and re-scan the directory tree — there is no way to recover the dropped events.

Removing a watch via `inotify_rm_watch(inotifyfd, wd)` marks the fsnotify_mark for removal (which is deferred until the SRCU grace period expires), queues an `IN_IGNORED` event to the group's list, and removes the wd from the IDR. The watch is also auto-removed when the watched inode is deleted (yielding `IN_DELETE_SELF` then `IN_IGNORED`) or unmounted (`IN_UNMOUNT`).

### inotify kernel-side data structures

**`struct inotify_inode_mark`** (`fs/notify/inotify/inotify.h`) — the inotify-specific mark:

```c
struct inotify_inode_mark {
    struct fsnotify_mark    fsn_mark;  /* embedded; links to inode & group */
    int                     wd;        /* watch descriptor (from IDR)       */
};
```

**`struct inotify_event_info`** (`fs/notify/inotify/inotify.h`) — the queued event:

```c
struct inotify_event_info {
    struct fsnotify_event   fse;       /* embedded base event               */
    u32                     mask;      /* FS_* flags translated to IN_* for uapi */
    int                     wd;        /* which watch triggered this        */
    u32                     sync_cookie;
    const char             *name;      /* filename (if inside watched dir)  */
    size_t                  name_len;
};
```

### fanotify: mount-wide watching with permission control

fanotify is initialised with `fanotify_init(flags, event_f_flags)`. The `flags` argument controls the notification class and additional capabilities requested:

- **`FAN_CLASS_NOTIF`** — basic notification group (no permission events)
- **`FAN_CLASS_CONTENT`** — permission events for file content (FAN_ACCESS_PERM, FAN_OPEN_EXEC_PERM)
- **`FAN_CLASS_PRE_CONTENT`** — permission events before content is accessible (FAN_OPEN_PERM)
- **`FAN_REPORT_FID`** (5.1+) — events carry a file handle instead of an open fd; allows watching without opening files
- **`FAN_REPORT_DFID_NAME`** (5.9+) — events additionally carry parent dir handle + filename, enabling CREATE/DELETE/MOVE tracking

`event_f_flags` is passed to `O_RDONLY`/`O_RDWR` when the kernel opens a file descriptor for each event (only meaningful for fd-based modes; ignored for FAN_REPORT_FID).

Marks are added with `fanotify_mark(fanotifyfd, flags, mask, dirfd, pathname)`. The `flags` argument controls the mark type:

- **`FAN_MARK_ADD | FAN_MARK_INODE`** — same granularity as inotify; mark one inode
- **`FAN_MARK_ADD | FAN_MARK_MOUNT`** — mark a vfsmount: all files under this mount point
- **`FAN_MARK_ADD | FAN_MARK_FILESYSTEM`** — mark the superblock: all files on the filesystem, regardless of mount

The superblock mark is the key scalability feature for tools like antivirus scanners. Where inotify would need to call `inotify_add_watch()` for every file in a 10-million-file tree, fanotify needs exactly one `fanotify_mark()` call to cover all of them.

Each mark also has an **ignore mask** (set via `FAN_MARK_ADD | FAN_MARK_IGNORED_MASK`). This allows a global listen with selective suppression: a backup tool might watch an entire filesystem for FAN_MODIFY but add ignore masks on temp directories to avoid noise.

**Reading events** works the same way as inotify — `read(fanotifyfd, buf, len)` returns one or more `struct fanotify_event_metadata` records. In fd-based mode:

```c
struct fanotify_event_metadata {
    __u32  event_len;    /* total size including optional info records */
    __u8   vers;         /* FANOTIFY_METADATA_VERSION */
    __u8   reserved;
    __u16  metadata_len; /* sizeof this struct */
    __u64  mask;         /* event type flags (FAN_OPEN, FAN_MODIFY, ...) */
    __s32  fd;           /* open fd to the file (O_RDONLY or O_RDWR) */
    __s32  pid;          /* PID of the process that caused the event */
};
```

For FAN_REPORT_FID mode, the event is followed by one or more `fanotify_event_info_*` records (using a tagged union identified by `fanotify_event_info_header.info_type`) that provide file handles, error details, mount IDs, or range information.

**Permission events** are the feature that separates fanotify from all other Linux notification APIs. When a permission event fires — `FAN_OPEN_PERM`, `FAN_ACCESS_PERM`, or `FAN_OPEN_EXEC_PERM` — the kernel creates a `struct fanotify_perm_event` with `state = FAN_EVENT_INIT` and puts the triggering task to sleep (`TASK_KILLABLE`) on a wait queue embedded in the event. The event is queued to the fanotify group. The fanotify listener reads it, inspects the file (using the fd provided in the event), and writes back a `struct fanotify_response`:

```c
struct fanotify_response {
    __s32  fd;        /* fd from the event */
    __u32  response;  /* FAN_ALLOW or FAN_DENY */
};
```

When the kernel processes the write, it sets `event->state = FAN_EVENT_ANSWERED`, stores `event->response`, and wakes the sleeping task. If the listener wrote `FAN_DENY`, the task's syscall returns `EACCES`. Since Linux 6.13, `FAN_DENY_ERRNO(errno)` allows specifying a custom errno (EPERM, EIO, EBUSY, etc.).

The blocking sleep uses `TASK_KILLABLE` rather than `TASK_UNINTERRUPTIBLE` — a fatal signal can wake the task and fail the permission check — but a non-fatal signal leaves the task blocked. This was a deliberate design choice: an antivirus daemon that dies while events are in-flight should not silently allow all pending operations; it should cause the blocked processes to fail visibly (EINTR is a survivable error that the application can handle).

**fanotify kernel-side data structures:**

**`struct fanotify_event`** (`fs/notify/fanotify/fanotify.h`) — base event, embedded in all fanotify event types:

```c
struct fanotify_event {
    struct fsnotify_event   fse;
    struct path             path;     /* the affected file/dir path */
    __kernel_pid_t          pid;
    /* ... type-specific data follows in subclasses ... */
};
```

**`struct fanotify_perm_event`** — extends fanotify_event for permission events:

```c
struct fanotify_perm_event {
    struct fanotify_event   fae;
    __u32                   response;  /* FAN_ALLOW / FAN_DENY (filled by listener) */
    __u8                    hdr_type;
    __u8                    state;     /* FAN_EVENT_INIT / FAN_EVENT_REPORTED / FAN_EVENT_ANSWERED */
    wait_queue_head_t       *wq;       /* points to group's perm_wait_q */
};
```

## Key Data Structures

**`struct inotify_inode_mark`** (`fs/notify/inotify/inotify.h`) — inotify's per-watch state; contains the wd integer alongside the embedded `fsnotify_mark`.

**`struct inotify_event_info`** (`fs/notify/inotify/inotify.h`) — queued notification; carries wd, mask, cookie, and optional filename.

**`struct inotify_event`** (`include/uapi/linux/inotify.h`) — the structure exposed to userspace via `read()`.

**`struct fanotify_event_metadata`** (`include/uapi/linux/fanotify.h`) — base event delivered to fanotify listeners; contains mask, open fd (in fd-based mode), and PID.

**`struct fanotify_perm_event`** (`fs/notify/fanotify/fanotify.h`) — permission event; includes a wait queue head and state machine for blocking the originator.

**`struct fanotify_response`** (`include/uapi/linux/fanotify.h`) — written back to the fd by the listener to allow/deny a permission event.

## Key Functions / Entry Points

**`inotify_init1(flags)`** (`fs/notify/inotify/inotify_user.c`) — allocates an fsnotify_group with `inotify_fsnotify_ops`; returns the group fd.

**`inotify_add_watch(fd, pathname, mask)`** (`fs/notify/inotify/inotify_user.c`) — resolves pathname to inode; creates or updates an `inotify_inode_mark`; allocates wd from IDR.

**`inotify_handle_inode_event()`** (`fs/notify/inotify/inotify_user.c`) — the fsnotify `handle_event` callback for inotify; allocates `inotify_event_info` and appends to group queue.

**`fanotify_init(flags, event_f_flags)`** (`fs/notify/fanotify/fanotify_user.c`) — allocates an fsnotify_group with `fanotify_fsnotify_ops`; requires `CAP_SYS_ADMIN` if permission events are used.

**`fanotify_mark(fd, flags, mask, dirfd, pathname)`** (`fs/notify/fanotify/fanotify_user.c`) — attaches an inode/mount/sb mark; updates combined masks.

**`fanotify_handle_event()`** (`fs/notify/fanotify/fanotify.c`) — the fsnotify `handle_event` callback; for permission events allocates a `fanotify_perm_event` and sleeps the originator.

**`fanotify_release()`** (`fs/notify/fanotify/fanotify_user.c`) — called when the fanotify fd is closed; automatically wakes all blocked permission events with `FAN_ALLOW` (to avoid permanently hanging processes when the daemon exits).

## Important Flags & Config Options

| Symbol | Meaning |
|--------|---------|
| `CONFIG_INOTIFY_USER` | Kconfig: compile inotify userspace API |
| `CONFIG_FANOTIFY` | Kconfig: compile fanotify |
| `CONFIG_FANOTIFY_ACCESS_PERMISSIONS` | Kconfig: permission event support (requires `CAP_SYS_ADMIN`) |
| `/proc/sys/fs/inotify/max_user_watches` | Max watches per UID (default 8192) |
| `/proc/sys/fs/inotify/max_user_instances` | Max inotify fds per UID (default 128) |
| `/proc/sys/fs/inotify/max_queued_events` | Max queued events per instance (default 16384) |
| `FAN_CLASS_NOTIF` | fanotify notification-only group |
| `FAN_CLASS_CONTENT / FAN_CLASS_PRE_CONTENT` | fanotify permission event groups (requires `CAP_SYS_ADMIN`) |
| `FAN_REPORT_FID` | Events carry file handles, not open fds (5.1+) |
| `FAN_REPORT_DFID_NAME` | Events carry parent dir handle + name (5.9+) |
| `FAN_MARK_MOUNT / FAN_MARK_FILESYSTEM` | Mark scope for fanotify |
| `FAN_UNLIMITED_QUEUE` | Disable per-group event queue limit (requires `CAP_SYS_ADMIN`) |
| `FAN_UNLIMITED_MARKS` | Disable per-user mark limit (requires `CAP_SYS_ADMIN`) |
| `IN_CLOEXEC / IN_NONBLOCK` | inotify_init1() flags |

## Interactions with Other Subsystems

- **↑ Userspace**: inotify — `inotify_init1(2)`, `inotify_add_watch(2)`, `inotify_rm_watch(2)`, `read(2)`; fanotify — `fanotify_init(2)`, `fanotify_mark(2)`, `read(2)`, `write(2)`.
- **→ [[fsnotify]]**: both APIs are implemented entirely as fsnotify backends; all VFS hook interception, mark management, SRCU locking, and event queuing is provided by fsnotify.
- **→ [[VFS]]**: inotify and fanotify events are triggered in VFS operations (`vfs_read`, `vfs_write`, `vfs_open`, `vfs_create`, `vfs_rename`, `vfs_unlink`, `notify_change`) via fsnotify inline hooks.
- **→ [[Mount Namespace]]**: fanotify mount marks are namespace-specific — adding a mark with `FAN_MARK_MOUNT` covers only the vfsmount visible in the calling process's namespace; a different namespace with the same superblock has independent mount-level marks.
- **← Security (LSM)**: `security_inode_notify()` allows SELinux and AppArmor to block notification delivery across security domains, preventing information leakage.
- **← [[file-descriptor-and-open-file-table]]**: fanotify in fd-based mode opens a new file descriptor for each event; this means a slow or backlogged fanotify listener can exhaust the global open-file limit.

## Design Decisions & Tradeoffs

**inotify's wd-IDR instead of a file descriptor per watch**: The original dnotify model required an open fd per watched directory, quickly exhausting limits on large trees. inotify uses integer watch descriptors from an IDR — they consume far less memory than open files and don't count against `RLIMIT_NOFILE`. The tradeoff is that wd integers are local to a group, not globally meaningful.

**No process information in inotify**: inotify delivers no information about *which process* triggered the event. This was a deliberate minimalism choice to keep the kernel path fast (no process context lookup at event time). fanotify added PID delivery to address this, and FAN_REPORT_PIDFD (5.15+) added a pidfd to survive PID reuse races.

**fanotify FAN_REPORT_FID vs. open fd**: Early fanotify opened a file descriptor per event, which was costly (fd allocation, open-file table entry, reference counting) and created races — the file could be renamed or deleted between event delivery and the listener's `stat()`. FAN_REPORT_FID (5.1, Amir Goldstein) replaced this with a stable (fsid, file handle) pair that uniquely identifies the inode without keeping it open. The downside: reading file content now requires the listener to call `open_by_handle_at(2)` separately.

**Permission event blocking with TASK_KILLABLE**: Using `TASK_KILLABLE` rather than `TASK_UNINTERRUPTIBLE` was contentious. The alternative — making permission events non-blocking and returning a default allow — would be silently unsafe when the daemon fails. `TASK_KILLABLE` means a fatal signal can unblock the originator (preventing permanent hangs in crash scenarios) while non-fatal signals leave the task blocked, making the blocking predictable.

**fanotify_release() auto-allow on close**: If a fanotify group's fd is closed while permission events are outstanding, the kernel automatically allows all pending events. This prevents a daemon crash from permanently hanging every process waiting on a permission check. The policy choice (allow rather than deny on crash) was debated; allow was chosen because deny would cause unexplained `EACCES` errors that are harder to diagnose than a brief window of unscanned access.

**Superblock marks vs. O(n) inode marks**: For tools that need filesystem-wide coverage (backup, AV), superblock marks are an O(1) solution. The tradeoff is granularity: a superblock mark can't exclude a specific subtree without layering per-inode ignore masks on top, which partially defeats the scalability win. The recommended pattern is: one superblock mark for the global listen, per-directory ignore marks for exclusions.

## How It Has Evolved

- **2.4.0** (2001): dnotify — directory-only, signal-based, one fd per watched dir.
- **2.6.13** (2005): inotify — three syscalls, fd-based event queue, file and dir watching, rename cookies.
- **2.6.27** (2008): `inotify_init1()` added to support `IN_CLOEXEC` and `IN_NONBLOCK`.
- **2.6.36** (2010): fsnotify unified backend; inotify reimplemented on top.
- **2.6.37** (2011): fanotify merged — mount marks, permission events, CAP_SYS_ADMIN requirement.
- **4.20** (2018): `FAN_MARK_FILESYSTEM` (superblock marks) added, enabling O(1) global watches.
- **5.1** (2019): `FAN_REPORT_FID` — file handle in events instead of open fd; fanotify gains `FAN_CREATE`, `FAN_DELETE`, `FAN_MOVE` event types.
- **5.9** (2020): `FAN_REPORT_DFID_NAME` — parent directory handle + filename in events for directory entry tracking.
- **5.13** (2021): `FAN_FS_ERROR` — filesystem error events for ext4 corruption monitoring.
- **5.15** (2021): `FAN_REPORT_PIDFD` — pidfd instead of raw PID to avoid PID reuse races.
- **6.6** (2023): `FAN_PRE_ACCESS` — events for pre-access range information.
- **6.13** (2024): `FAN_DENY_ERRNO` — permission denials can specify a custom errno.

## Further Reading

1. [Filesystem notification, part 1: dnotify and inotify overview — LWN.net](https://lwn.net/Articles/604686/)
2. [Filesystem notification, part 2: deeper inotify investigation — LWN.net](https://lwn.net/Articles/605128/)
3. [fsnotify, dnotify, and inotify unification — LWN.net](https://lwn.net/Articles/311350/)
4. [The fanotify API — LWN.net](https://lwn.net/Articles/339399/)
5. [inotify kernel API — LWN.net](https://lwn.net/Articles/185464/)
6. [inotify(7) man page](https://www.man7.org/linux/man-pages/man7/inotify.7.html)
7. [fanotify(7) man page](https://www.man7.org/linux/man-pages/man7/fanotify.7.html)
8. [Kernel documentation: filesystems/inotify.html](https://www.kernel.org/doc/html/latest/filesystems/inotify.html)

## LKML Highlights

- **inotify introduction** — John McCutchan & Robert Love (2005): The original debate centred on whether to extend `fcntl()` (as dnotify did) or introduce dedicated syscalls. The kernel community strongly preferred dedicated syscalls — cleaner ABI, no overloading — and the three-syscall design (`inotify_init`, `inotify_add_watch`, `inotify_rm_watch`) prevailed, setting the template for subsequent notification APIs.
- **fanotify merge** — Eric Paris (2010–2011): The most contested area was permission events without a kernel-enforced timeout. Al Viro and others warned that a hung fanotify listener could deadlock all openers of watched files. The resolution was to make permission events a separately gated `CONFIG_FANOTIFY_ACCESS_PERMISSIONS` option, require `CAP_SYS_ADMIN` to create such groups, and rely on `TASK_KILLABLE` to handle daemon crashes — explicit timeout was rejected as adding complexity for a privileged API that should be handled responsibly.
- **FAN_REPORT_FID** — Amir Goldstein (2018–2019): Addressed the long-standing complaint that fanotify events forced the kernel to open a file descriptor per event, creating overhead and race conditions. The thread established that stable file handles (fsid + fhandle) from `name_to_handle_at(2)` were the right primitive, and the series added FID-mode events, paving the way for fanotify's adoption in backup and anti-malware tools that previously relied on inotify or kernel modules.
