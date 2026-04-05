---
title: "File Object (struct file)"
category: concept
tags: [fs, vfs, file-object, file-descriptor, file-operations, rcu]
subsystem: fs
kernel_version: "2.4+"
researched: 2026-04-05
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://docs.kernel.org/filesystems/files.html
  - https://lwn.net/Articles/983957/
  - https://lwn.net/Articles/972081/
  - https://lwn.net/Articles/93566/
---

# File Object (struct file)

## Purpose

`struct file` is the kernel's representation of a POSIX *open file description* — the per-`open(2)` call state that tracks current file position, access flags, credentials, and a pointer to the operations table for the underlying object. It is distinct from both the file descriptor (a small per-process integer) and the inode (per-file metadata). Multiple file descriptors can point to the same `struct file` (via `dup2`), and multiple processes can share one (via `fork`), but each `open()` call creates a new, independent `struct file`.

## Mental Model

Three levels connect userspace to disk:

```
fd (int) → struct file (open file description) → dentry → inode → disk
```

The fd is a process-local name for the file description. The `struct file` holds the *open state* (position, flags, capabilities). The inode holds the *file state* (size, permissions, data). This separation allows ten processes to have ten different positions in the same file simultaneously — each has its own `struct file`, all pointing at the same inode.

## How It Works

### struct file layout

Defined in `include/linux/fs.h`, the key fields are:

```c
struct file {
    union { struct llist_node f_llist; struct rcu_head f_rcuhead; };
    const struct path        f_path;          /* vfsmount + dentry */
    struct inode             *f_inode;        /* cached from f_path.dentry->d_inode */
    const struct file_operations *f_op;       /* vtable from inode at open time */

    spinlock_t               f_lock;          /* protects f_ep_links, f_flags in rare cases */
    atomic_long_t            f_count;         /* reference count */
    unsigned int             f_flags;         /* O_RDONLY, O_NONBLOCK, O_APPEND, … */
    fmode_t                  f_mode;          /* FMODE_READ, FMODE_WRITE, FMODE_EXEC, … */
    struct mutex             f_pos_lock;      /* serialises positional I/O by multiple threads */
    loff_t                   f_pos;           /* current file offset */
    struct fown_struct       f_owner;         /* async notification (SIGIO) target */
    const struct cred        *f_cred;         /* credentials at open time */
    struct file_ra_state     f_ra;            /* read-ahead state */
    u64                      f_version;       /* incremented by positional write; checked by mmap/write races */
    void                     *private_data;   /* filesystem/driver private state */
    struct address_space     *f_mapping;      /* == f_inode->i_mapping (shortcut) */
    errseq_t                 f_wb_err;        /* per-fd write error cursor */
    errseq_t                 f_sb_err;        /* per-fd superblock error cursor */
};
```

`f_inode` is a shortcut — it caches `f_path.dentry->d_inode` to avoid one pointer dereference on hot paths. `f_op` is set at open time from the inode's `i_fop` and does not change for the lifetime of the file object.

`f_cred` captures the opener's credentials. This matters for operations like `execve` that check permissions at *open* time (setting `FMODE_EXEC`) rather than at each read, and for UNIX sockets and FIFOs where the opener's uid/gid affects signalling.

### Creating and installing a file object

`open(2)` calls `do_sys_openat2()` → `do_filp_open()` → `path_openat()` which:

1. Resolves the path to a `struct path` (via the [[Path Lookup]] machinery).
2. Calls `alloc_file()` to allocate a `struct file` from the `filp` slab cache (`kmem_cache_alloc(filp_cachep, GFP_KERNEL)`).
3. Initialises all fields, sets `f_op = inode->i_fop`, and calls `f_op->open(inode, file)` to give the filesystem/driver a chance to initialise `private_data` and validate the open.
4. Calls `get_unused_fd_flags()` to find a free slot in the process's fd table.
5. Calls `fd_install(fd, file)` which stores the `struct file*` into `current->files->fdt->fd[fd]` under RCU.

The fd number is now live. Any concurrent thread in the same process with a shared fd table sees it immediately after `fd_install()`.

### Reference counting: f_count, fget/fput, fdget/fdput

`f_count` is an `atomic_long_t` reference count. While `f_count > 0`, the `struct file` is alive and cannot be freed. References are held by:
- Each fd slot in any process's fd table (`fd_install` takes one; `__close_fd` drops it).
- Active syscalls that called `fget(fd)` or `fdget(fd)`.
- Splice pipes, io_uring, and other long-lived kernel consumers.

**`fget(fd)`** is the "safe" borrow: it finds the file and increments `f_count`, returning a pointer the caller may use after `rcu_read_unlock()`. The caller must call `fput(file)` when done. `fget` works across process boundaries (e.g. `pidfd` operations).

**`fdget(fd)`** is the optimised syscall-internal borrow. If the calling thread is the only thread sharing the fd table (the common single-threaded case), it returns the file without bumping `f_count` — a "borrowed" reference that is valid for the duration of the syscall because the caller cannot close the fd from under itself. If the fd table *is* shared, `fdget` falls back to an `fget`. The returned `struct fd` encodes which path was taken in a flag bit (`FDPUT_FPUT`); `fdput(f)` checks the bit and calls `fput` only if needed.

Since Linux 6.9, `struct fd` is a struct wrapping an `unsigned long` that packs the file pointer and the flags (FDPUT_FPUT, FDPUT_POS_UNLOCK) into a single word. This enables `CLASS(fd, f)(fd)` syntax with `__cleanup` for automatic `fdput` on scope exit, eliminating a large class of fd-related use-after-free bugs and leaks.

**`fdget_pos(fd)`** additionally takes `f_pos_lock` if `f_count > 1`, serialising file-position updates for the cases where multiple threads share the same open file description and issue positional I/O.

### The fd table: files_struct and fdtable

Every process has a `struct files_struct` (pointed to by `task_struct->files`). It embeds a small inline `fdtable` for the common case (≤ `NR_OPEN_DEFAULT`, typically 64 fds) and a pointer to a dynamically allocated `fdtable` for larger tables. Both are protected by:
- `files->file_lock` spinlock for writes.
- RCU (`rcu_read_lock()` + `rcu_dereference()`) for reads.

`fork()` with `CLONE_FILES` creates a new reference to the *same* `files_struct` (incrementing its refcount `->count`). Without `CLONE_FILES` (normal `fork`), `dup_fd()` allocates a new `files_struct`, copies all fd slots, and increments `f_count` on each copied file. The new process starts with the same open file descriptions but independent fd tables — closing one fd in the child does not affect the parent.

`dup2(oldfd, newfd)` installs the same `struct file*` at two fd slots, incrementing `f_count`. Both fds share `f_pos`.

`close(fd)` calls `__close_fd()` → `filp_close()` → `f_op->flush(file)` (if set) → `fput(file)`. `fput` decrements `f_count`; when it hits zero, it schedules `____fput()` via `task_work_add()` or `schedule_delayed_work()`, which eventually calls `f_op->release(inode, file)`, releases the dentry reference, and frees the `struct file` back to the slab.

### file_operations: the vtable

`struct file_operations` is the operations table for file objects. Key callbacks (as of 6.9):

| Callback | Trigger | Notes |
|----------|---------|-------|
| `open(inode, file)` | first open | initialise `private_data`; check capabilities |
| `release(inode, file)` | last `fput` | free `private_data`; flush pending state |
| `read_iter(kiocb, iov_iter)` | `read(2)`, `pread(2)`, `readv(2)` | async-capable; superceded `read()` |
| `write_iter(kiocb, iov_iter)` | `write(2)`, `pwrite(2)`, `writev(2)` | async-capable; superseded `write()` |
| `llseek(file, offset, whence)` | `lseek(2)`, `llseek(2)` |  |
| `mmap(file, vma)` | `mmap(2)` | set up `vma->vm_ops` |
| `poll(file, poll_table)` | `select(2)`, `poll(2)`, `epoll` | return readiness mask |
| `fsync(file, start, end, datasync)` | `fsync(2)`, `fdatasync(2)` | flush to storage |
| `unlocked_ioctl(file, cmd, arg)` | `ioctl(2)` | no BKL held |
| `compat_ioctl(file, cmd, arg)` | `ioctl(2)` from 32-bit process on 64-bit kernel | |
| `iterate_shared(file, ctx)` | `getdents(2)` | reads directory entries |
| `splice_read(in, ppos, pipe, len, flags)` | `splice(2)` | zero-copy between fd and pipe |
| `splice_write(pipe, out, ppos, len, flags)` | `splice(2)` | |
| `fallocate(file, mode, offset, len)` | `fallocate(2)` | preallocate or punch holes |
| `fadvise(file, offset, len, advice)` | `fadvise(2)` | readahead hints |
| `flush(file, id)` | `close(2)` (once per fd; not per refcount zero) | NFS uses for writeback-before-close |
| `lock(file, cmd, lock)` | `fcntl(2)` POSIX locks | |
| `get_unmapped_area(file, addr, len, pgoff, flags)` | `mmap(2)` on some archs | choose VMA placement |
| `check_flags(flags)` | `fcntl(F_SETFL)` | validate flag changes |

**`read()` and `write()` were removed in Linux 6.8** (Jens Axboe's 437-patch series). All drivers were migrated to `read_iter`/`write_iter`, which take a `struct kiocb` (carrying async context, `ki_pos`, hint flags) and a `struct iov_iter` (scatter-gather buffer description). This unifies sync, async, vectored, and kernel-initiated I/O into a single callback.

### Read-ahead state: f_ra

`struct file_ra_state` is embedded in every `struct file`. It tracks:
- `start`: page index of the current readahead window start
- `size`: number of pages in the current window
- `async_size`: number of pages in the async lookahead portion
- `ra_pages`: maximum window size (from backing device's `read_ahead_kb`)

`ondemand_readahead()` in `mm/readahead.c` reads `f_ra` on every cache miss and updates it. Sequential access grows the window; random access shrinks it. Because `f_ra` is per `struct file`, two processes reading the same file independently maintain independent readahead windows.

## Key Data Structures

**`struct file`** (`include/linux/fs.h`) — the open file description; fields above.

**`struct file_operations`** (`include/linux/fs.h`) — vtable; 30+ function pointers; `NULL` means use a generic default or return `EINVAL`.

**`struct fd`** (`include/linux/file.h`) — unsigned-long-wrapped (file*, flags) pair; `fd_file(f)` extracts the pointer; `fd_empty(f)` tests for invalid fd.

**`struct files_struct`** (`include/linux/fdtable.h`) — per-process fd table owner; contains a small inline `fdtable` and a pointer to an overflow `fdtable`.

**`struct fdtable`** (`include/linux/fdtable.h`) — `struct file **fd` array + `open_fds` bitmap + `close_on_exec` bitmap; grows in power-of-two steps.

**`struct file_ra_state`** (`include/linux/fs.h`) — per-file readahead window; fields `start`, `size`, `async_size`, `ra_pages`.

## Key Functions / Entry Points

**`alloc_file(path, fmode, fops)`** (`fs/file_table.c`) — allocates and initialises a `struct file`; used by `do_filp_open()` and kernel-internal opens.

**`fget(fd)`** (`fs/file.c`) — safe external reference acquire; bumps `f_count`; works across process boundaries.

**`fdget(fd)`** / **`fdget_pos(fd)`** (`fs/file.c`) — optimised syscall-internal borrow; may skip `f_count` bump for unshared fd tables.

**`fput(file)`** (`fs/file_table.c`) — release reference; when `f_count` hits zero, schedules `____fput()` to call `release()` and free.

**`fd_install(fd, file)`** (`fs/file.c`) — RCU-publishes the `struct file*` into the fd table slot; after this call the fd is visible to other threads.

**`__close_fd(files, fd)`** (`fs/file.c`) — atomically clears fd slot and triggers `fput`.

**`do_filp_open(dfd, filename, op)`** (`fs/namei.c`) — full open path: resolve → alloc_file → f_op->open → return.

## Important Flags & Config Options

| Flag / Field | Meaning |
|--------------|---------|
| `O_RDONLY/WRONLY/RDWR` | access mode; reflected in `f_mode` as `FMODE_READ`/`FMODE_WRITE` |
| `O_NONBLOCK` | non-blocking I/O; stored in `f_flags` |
| `O_APPEND` | all writes go to EOF; `f_pos` ignored for writes |
| `O_DIRECT` | bypass page cache; requires `f_op->direct_IO` or DIO path |
| `O_CLOEXEC` / `FD_CLOEXEC` | close-on-exec; set in `fdtable->close_on_exec` bitmap |
| `O_PATH` | open without access; produces a path-only fd; `f_mode = FMODE_PATH` |
| `FMODE_EXEC` | fd opened for execution; checked by `mmap(PROT_EXEC)` |
| `f_wb_err` / `f_sb_err` | per-fd error cursors for `errseq_t`; delivers write errors exactly once per open fd |
| `/proc/sys/fs/file-max` | maximum number of open file objects system-wide |
| `/proc/sys/fs/nr_open` | per-process fd limit |

## Interactions with Other Subsystems

- **↑ Userspace**: every fd-using syscall (`read`, `write`, `ioctl`, `mmap`, `poll`, `close`, …) enters the kernel through the fd → `struct file` lookup path.
- **→ [[Dentry]]**: `f_path.dentry` holds a reference that keeps the dentry (and through it, the inode) alive for the lifetime of the open file object.
- **→ [[Inode]]**: `f_inode` shortcut; inode methods are invoked through `f_op` (which was set from `inode->i_fop` at open time).
- **→ [[Address Space]]**: `f_mapping` shortcut to `f_inode->i_mapping`; read/write paths and readahead go through the address space.
- **→ io_uring / AIO**: `struct kiocb` carries a pointer to the `struct file`; long-lived async operations hold their own `fget` reference.
- **→ epoll / poll**: `f_op->poll()` adds the file to epoll wait queues; the file holds a pointer back to all epoll instances watching it via `f_ep_links`.
- **← [[Path Lookup]]**: path resolution produces the `struct path` that is stored in `f_path` at open time.

## Design Decisions & Tradeoffs

**Separation of fd, struct file, and inode**: POSIX requires that `dup2` produces two fds sharing the same position, while `fork` produces two processes with separate positions. This maps naturally to three levels: fd (per-process slot), `struct file` (per-open-description), inode (per-file). Any design that collapses two of these levels would either break POSIX semantics or require more complex workarounds.

**Borrowed references (fdget) vs. full fget**: Bumping `f_count` on every syscall entry is safe but expensive — it's a shared atomic write that bounces the cacheline containing `f_count` on multi-core systems. For single-threaded processes the fd table is unshared, so the reference is inherently valid for the syscall duration. The `fdget` optimisation exploits this, avoiding the atomic at the cost of requiring callers to understand the lifecycle rule ("do not return to userland while holding a borrowed reference"). The `struct fd` + `__cleanup` approach makes this rule compiler-enforceable.

**read()/write() removal**: For 32 years, most filesystems and drivers implemented both `read()`/`write()` (simple buffer+length callbacks) and `read_iter()`/`write_iter()` (iov_iter-based). The duplication created maintenance burden and subtle inconsistencies (e.g. `splice` could only use `read_iter` paths). Removing the old callbacks forced all users to the unified interface and eliminated ~1000 lines of bridge code that emulated one in terms of the other.

**`f_pos_lock` for shared file descriptions**: When multiple threads share an open file description (via `pthread_create` without `CLONE_FILES`... wait, actually with `CLONE_FILES`), concurrent `read()`/`write()` calls race on `f_pos`. `f_pos_lock` (a mutex) serialises these. The lock is only taken when `f_count > 1`, so single-threaded programs pay no cost. Using a mutex rather than a spinlock allows the position update to sleep during slow I/O.

## How It Has Evolved

- **2.4**: `struct file` present; global `files_lock` for fd table; `read()`/`write()` were the primary I/O callbacks.
- **2.6.3** (2004): Lock-free RCU fd lookup; spinlock replaced by `rcu_read_lock()` for readers.
- **2.6.22** (2007): `read_iter()`/`write_iter()` added; async I/O and vectored I/O unified.
- **3.4** (2012): `unlocked_ioctl` replaced `ioctl` (BKL removal complete).
- **5.0** (2019): `errseq_t wb_err` per-file error cursor for precise fsync error reporting.
- **5.9** (2020): `f_sb_err` added for superblock-level error tracking.
- **6.8** (2024): `read()` and `write()` callbacks removed from `file_operations`; all callers migrated to `read_iter`/`write_iter`.
- **6.9** (2024): `struct fd` redesigned as packed unsigned long; `CLASS(fd, f)(fd)` `__cleanup` syntax for automatic `fdput`.

## Further Reading

1. [Overview of the Linux VFS — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/vfs.html)
2. [File management in the Linux kernel — kernel.org](https://docs.kernel.org/filesystems/files.html)
3. [struct fd and memory safety — LWN.net](https://lwn.net/Articles/983957/)
4. [The file_operations structure gets smaller — LWN.net](https://lwn.net/Articles/972081/)
5. [Lock-free fd lookup — LWN.net](https://lwn.net/Articles/93566/)

## LKML Highlights

- **Lock-free fd table** — Nick Piggin (2004): RCU-based fd lookup removing the per-process spinlock from the read path; showed 13–21% tiobench improvements on 4-way systems.
- **read()/write() removal** — Jens Axboe (2024): 437-patch series touching 859 files; the review debate was whether the compat shim that wrapped old drivers was correct in all corner cases, particularly for `O_NONBLOCK` semantics.
- **struct fd __cleanup redesign** — Al Viro (2023–2024): The memory safety audit that found two real fd leaks and multiple UAF patterns; the core argument was that compiler-enforced scope cleanup was the only reliable way to prevent this entire class of bugs at scale.
