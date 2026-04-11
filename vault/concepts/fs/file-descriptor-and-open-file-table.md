---
title: "File Descriptor and Open File Table"
category: concept
tags: [fs, vfs, file-descriptor, fdtable, files-struct, rcu, process]
subsystem: fs
kernel_version: "2.6.12+"
researched: 2026-04-11
status: complete
sources:
  - https://docs.kernel.org/filesystems/files.html
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://kernel-internals.org/vfs/vfs-objects/
  - https://kernel-internals.org/vfs/file-ops/
  - https://lwn.net/Articles/983957/
  - https://lwn.net/Articles/985853/
  - https://lwn.net/Articles/933924/
  - https://lwn.net/Articles/236843/
---

# File Descriptor and Open File Table

## Purpose

A file descriptor is a small non-negative integer that a process uses to name an open file, socket, pipe, or device. The kernel maintains two tables that give it meaning: the **per-process file descriptor table** (indexed by the integer) and the **open file table** (the collection of `struct file` objects referenced by those entries). Together they enforce POSIX sharing semantics — `dup2` produces two descriptors that share position, `fork` produces two processes with independent descriptor tables but shared file descriptions, and `close` on one descriptor does not affect another.

## Mental Model

There are three conceptual levels between a process and the on-disk file:

```
Process A               Process B
  fd 3 ──┐               fd 5 ──┐
         └──► struct file ◄─────┘  ← open file description (one per open/dup)
                │
                └──► inode ← per-file identity (one per pathname)
```

- **fd (int)**: a process-local index. Meaningless on its own; only valid within the process that holds it.
- **`struct file`**: the POSIX *open file description* — tracks position, flags, credentials, and the `file_operations` vtable. One is created per `open(2)` call; shared by `dup*` and inherited by `fork`.
- **inode**: the permanent per-file identity on the filesystem — permissions, size, data blocks. Multiple `struct file` objects may point to the same inode simultaneously.

The fd table is the per-process map from integers to `struct file*` pointers. The open file table is the universe of live `struct file` objects.

## How It Works

### The three-layer structure in the task

Every `task_struct` carries a pointer `->files` to a `struct files_struct` which owns the file descriptor table for that task (or a group of tasks if `CLONE_FILES` was used).

```c
/* task_struct (include/linux/sched.h) */
struct task_struct {
    ...
    struct files_struct *files;   /* fd table; shared with CLONE_FILES threads */
    ...
};
```

`struct files_struct` (defined in `include/linux/fdtable.h`) wraps the actual table:

```c
struct files_struct {
    atomic_t        count;          /* reference count; >1 if CLONE_FILES sharing */
    bool            resize_in_progress;
    wait_queue_head_t resize_wait;

    struct fdtable __rcu *fdt;      /* points to fdtab for small tables, else to heap */
    struct fdtable  fdtab;          /* embedded table for ≤ NR_OPEN_DEFAULT (64) fds */

    spinlock_t      file_lock;      /* protects all writes to fdt and fd slots */
    unsigned int    next_fd;        /* hint: lowest candidate for next allocation */
    unsigned long   close_on_exec_init[1];  /* close-on-exec bitmap, embedded */
    unsigned long   open_fds_init[1];       /* open fd bitmap, embedded */
    unsigned long   full_fds_bits_init[1];  /* level-2 "all slots full" bitmap */

    struct file __rcu *fd_array[NR_OPEN_DEFAULT]; /* inline fd → file* map */
};
```

The embedded `fdtab` and `fd_array` satisfy the common case (≤ 64 open files) without any heap allocation. When the process opens its 65th file, `expand_fdtable()` allocates a new `fdtable` on the heap and updates `fdt` under `file_lock`, allowing existing RCU readers to finish against the old table.

`struct fdtable` holds:

```c
struct fdtable {
    unsigned int    max_fds;        /* capacity of this table */
    struct file __rcu **fd;         /* the actual fd → struct file* array */
    unsigned long  *close_on_exec;  /* FD_CLOEXEC bitmap, one bit per slot */
    unsigned long  *open_fds;       /* open slots bitmap */
    unsigned long  *full_fds_bits;  /* level-2 bitmap: set if an open_fds word is full */
    struct rcu_head rcu;            /* for deferred free */
};
```

The level-2 `full_fds_bits` bitmap exists solely for allocation speed: instead of scanning `open_fds` word-by-word on every `open()`, the allocator first checks the level-2 word to skip whole 64-slot blocks that are fully occupied. On a process with thousands of open files this cuts the allocation scan from O(max_fds/64) to O(max_fds/4096).

### Allocating a file descriptor: the lowest-available-fd rule

When `open(2)`, `socket(2)`, `pipe2(2)`, or any fd-creating syscall needs a number, the VFS calls `__alloc_fd()`:

1. Take `files->file_lock`.
2. Start from `files->next_fd` (the hint from the last allocation).
3. Scan `open_fds` using `find_next_zero_bit()`, consulting `full_fds_bits` to skip full blocks, until a free slot is found.
4. Set the bit in `open_fds`; conditionally set `FD_CLOEXEC` in `close_on_exec` if `O_CLOEXEC` was requested.
5. Advance `next_fd` past the allocated slot.
6. Return the fd number; release the lock.

The table is expanded (doubling capacity up to `sysctl_nr_open`) if no free slot is found within the current capacity.

**The lowest-available rule** (POSIX-mandated) means the kernel always returns the smallest free fd. This has a well-known security implication: if a privileged program is exec'd with fd 0, 1, or 2 closed, the next `open()` it performs will land on one of those special descriptors, potentially directing error output to a privileged file. OpenBSD and glibc address this by pre-filling 0–2 with `/dev/null` before exec-ing setuid programs. The rule also creates serialisation pressure under high-parallelism workloads: all threads share the same `file_lock`, so concurrent `accept(2)` calls on a busy server must queue to find the lowest fd — this is a known scalability bottleneck (opens-per-second drops as core count rises).

### Installing, looking up, and closing a file descriptor

**Install** — after `struct file` creation, `fd_install(fd, file)` publishes the pointer into the fd table atomically:

```c
void fd_install(unsigned int fd, struct file *file)
{
    struct fdtable *fdt;
    rcu_read_lock_sched();
    fdt = rcu_dereference_sched(current->files->fdt);
    BUG_ON(fdt->fd[fd] != NULL);
    rcu_assign_pointer(fdt->fd[fd], file);
    rcu_read_unlock_sched();
}
```

`rcu_assign_pointer` emits a write memory barrier so concurrent `rcu_read_lock()` readers see a fully initialised `struct file` (not a half-written one).

**Lookup** — the hot path in every fd-consuming syscall. Two variants exist:

- `fget(fd)`: safe external lookup — increments `f_count` unconditionally; valid across process boundaries; must be paired with `fput()`.
- `fdget(fd)` / the `fdget()` family: optimised syscall-internal lookup. If `files->count == 1` (this task is the only thread sharing this fd table), no other thread can close the fd during the syscall, so `f_count` is *not* incremented — the reference is "borrowed". If the table is shared, falls back to `fget`. The `struct fd` return value packs the `struct file*` and a flag bit indicating which path was taken; `fdput()` calls `fput()` only if the flag is set.

Both paths must operate under `rcu_read_lock()` to prevent the `fdtable` from being freed mid-lookup during concurrent expansion:

```c
struct file *fget(unsigned int fd)
{
    struct file *file;
    rcu_read_lock();
    file = lookup_fdget_rcu(fd);   /* reads fdt->fd[fd], checks f_count > 0 */
    rcu_read_unlock();
    return file;
}
```

The check `atomic_long_inc_not_zero(&file->f_count)` inside `lookup_fdget_rcu` protects against the case where a concurrent thread just decremented the last reference — if `f_count` is already zero, the increment fails and the lookup returns NULL, preventing a use-after-free.

**Close** — `close(fd)` calls `__close_fd(files, fd)`, which under `file_lock`:

1. Clears the bit in `open_fds`.
2. Extracts the `struct file*` from `fdt->fd[fd]` and sets the slot to NULL using `rcu_assign_pointer`.
3. Updates `next_fd` to `fd` if `fd < next_fd` (so the freed slot will be reused first).
4. Releases the lock.

Then calls `filp_close()` → `f_op->flush()` (once per fd, used by NFS to flush dirty data before the fd is gone) → `fput()`. When `f_count` reaches zero, `fput()` schedules `____fput()` via `task_work_add()`, which eventually calls `f_op->release()` and frees the `struct file` back to the slab.

`flush()` is called per-fd; `release()` is called only when the *last reference* drops. This distinction matters for NFS: `flush()` writes back dirty buffers when the client closes an fd, even if the file is still open via `dup` or in another process.

### Fork, dup, and CLONE_FILES: sharing semantics

**`fork()` (without `CLONE_FILES`)**: `dup_fd()` allocates a fresh `files_struct` and `fdtable`, copies all fd slots, and calls `get_file()` (increments `f_count`) on each `struct file`. Parent and child have *independent fd tables* but share the same open file descriptions — the same `struct file` objects, including their `f_pos`. Closing an fd in the child only removes the child's table entry and decrements `f_count`; it does not affect the parent.

**`clone(CLONE_FILES)` / `pthread_create`**: no new `files_struct` is allocated. Instead `atomic_inc(&files->count)`. All threads in the thread group point to the *same* `files_struct`. An `fd_install()` in one thread is immediately visible to all. A `close()` in one thread removes the fd for all. This is why the `fdget` optimisation can only skip the refcount increment when `files->count == 1` — with CLONE_FILES, another thread can close the fd between the table lookup and the I/O operation.

**`dup(fd)` / `dup2(oldfd, newfd)` / `dup3`**: installs the same `struct file*` at a new fd slot (incrementing `f_count`). Both fds now point at the same open file description — they share `f_pos`. `dup2` first closes `newfd` if it was open, then atomically replaces it.

**`fork` + position**: because both parent and child share the same `struct file*` for any fd inherited across fork, they share `f_pos`. Writes from either process advance the shared position, which is why pipelines work — `ls | grep foo` relies on the pipe being a shared `struct file`.

### Close-on-exec: O_CLOEXEC and FD_CLOEXEC

The `close_on_exec` bitmap in `fdtable` is a one-bit-per-fd mask. When `execve(2)` is about to replace the process image, `do_close_on_exec()` iterates the bitmap and calls `__close_fd()` for every fd with the bit set, before the new image begins running. This prevents file descriptors opened by the parent (e.g. sensitive sockets, log files) from leaking into exec'd child programs.

Two ways to set the bit:

1. **`O_CLOEXEC`** passed to `open(2)`, `socket(2)`, `pipe2(2)`, `accept4(2)`, etc. — sets the bit atomically at fd allocation time, under `file_lock`. This is the preferred approach in multi-threaded programs.
2. **`fcntl(fd, F_SETFD, FD_CLOEXEC)`** — sets the bit after the fd is already live. In a multi-threaded program there is a window between fd creation and `fcntl` where another thread could `fork()` + `exec()` and inherit the unwanted fd. `O_CLOEXEC` closes this race by making the set atomic with allocation.

The `close_on_exec_init` embedded array in `files_struct` serves the same role as `open_fds_init`: it holds the first 64 entries inline without heap allocation.

### RCU-based lock-free reads

The fd table uses two synchronisation mechanisms:

| Operation | Mechanism |
|-----------|-----------|
| Read `fdt` pointer | `rcu_dereference()` via `files_fdtable()` macro |
| Read `fdt->fd[n]` | `rcu_dereference()` under `rcu_read_lock()` |
| Write `fdt` pointer (expansion) | `rcu_assign_pointer()` under `file_lock` |
| Write `fdt->fd[n]` (install/close) | `rcu_assign_pointer()` under `file_lock` |
| Free old `fdtable` after expansion | `call_rcu()` — deferred until all RCU readers finish |

The key invariant: **readers never take `file_lock`**. A thread performing `read(fd, buf, len)` takes an `rcu_read_lock()`, loads `fdt` and then `fdt->fd[fd]`, tries to increment `f_count`, and releases `rcu_read_lock()`. Meanwhile another thread can expand the table (installing a new `fdtable` and freeing the old one via RCU) without blocking any reader. Writers need `file_lock` only to serialise against other writers, not against readers.

This design was introduced in Linux 2.6.3 (2004) and gave measurable performance improvements (13–21% on `tiobench`) by removing the per-fd-lookup spinlock acquisition on every I/O syscall.

A subtle correctness requirement: after `files->file_lock` is dropped and re-taken (e.g. during table expansion), the caller must reload `fdt` from `files_fdtable()` — the expansion might have replaced the pointer. Any code that caches the `fdtable*` across a lock drop is incorrect.

## Key Data Structures

**`struct files_struct`** (`include/linux/fdtable.h`) — per-process fd table owner. Contains an embedded small `fdtable` for ≤ 64 fds and a pointer to an expanded heap `fdtable` for larger sets. Protected by `file_lock` (writes) and RCU (reads).

- `count` — reference count; > 1 when shared via `CLONE_FILES`.
- `fdt` — RCU pointer to the current `fdtable` (often points to the embedded `fdtab`).
- `file_lock` — spinlock; all fd table mutations must hold it.
- `next_fd` — allocation hint: the lowest fd to check first.
- `close_on_exec_init` / `open_fds_init` — embedded bitmaps for the first 64 fds.

**`struct fdtable`** (`include/linux/fdtable.h`) — the actual fd → file* mapping with associated bitmaps.

- `max_fds` — current capacity.
- `fd` — `struct file __rcu **`; the array indexed by fd number.
- `open_fds` — bitmap of in-use slots.
- `close_on_exec` — bitmap of fds marked for close-on-exec.
- `full_fds_bits` — level-2 bitmap for fast allocation skipping.

**`struct fd`** (`include/linux/file.h`) — a safe reference to a `struct file` obtained from `fdget()`. Internally a single `unsigned long` with the `struct file*` in the high bits and flag bits (FDPUT_FPUT, FDPUT_POS_UNLOCK) in the low bits. `fd_file(f)` extracts the pointer; `fd_empty(f)` tests for an invalid fd.

## Key Functions / Entry Points

**`__alloc_fd(files, start, end, flags)`** (`fs/file.c`) — allocates the lowest free fd in [start, end) under `file_lock`; expands the table if needed.

**`fd_install(fd, file)`** (`fs/file.c`) — RCU-publishes `file` into slot `fd`; after this call the fd is live and visible to all threads sharing the table.

**`__close_fd(files, fd)`** (`fs/file.c`) — atomically clears the fd slot and calls `filp_close()` → `fput()`.

**`fget(fd)`** (`fs/file.c`) — safe reference acquire; bumps `f_count`; valid across process and thread boundaries.

**`fdget(fd)`** / **`fdget_pos(fd)`** / **`fdget_raw(fd)`** (`fs/file.c`) — optimised syscall-internal lookup; borrows the reference without `f_count` increment when the fd table is unshared; returns `struct fd`.

**`fdput(f)`** (`include/linux/file.h`) — releases the reference from `fdget()`; calls `fput()` only if the FDPUT_FPUT flag is set.

**`dup_fd(oldf, max_fds, errp)`** (`fs/file.c`) — copies an entire `files_struct` for `fork()`.

**`do_close_on_exec(files)`** (`fs/file.c`) — iterates `close_on_exec` bitmap and closes every marked fd; called from `exec` path before the new image is loaded.

**`expand_fdtable(files, nr)`** (`fs/file.c`) — allocates a larger `fdtable`, copies entries, installs via `rcu_assign_pointer`, and frees the old table via `call_rcu`.

## Important Flags & Config Options

| Flag / Knob | Meaning |
|-------------|---------|
| `O_CLOEXEC` | Set FD_CLOEXEC atomically at open time; preferred over `fcntl(F_SETFD)` in multi-threaded code |
| `FD_CLOEXEC` | The close-on-exec bit; readable/writable via `fcntl(F_GETFD/F_SETFD)` |
| `/proc/sys/fs/file-max` | System-wide maximum number of simultaneously open `struct file` objects |
| `/proc/sys/fs/nr_open` | Per-process maximum fd number; hard ceiling on fd table expansion |
| `NR_OPEN_DEFAULT` | Compile-time constant (64); size of the inline embedded fd table in `files_struct` |
| `RLIMIT_NOFILE` | Per-process soft/hard limit on the number of open fds; enforced by `__alloc_fd` |

## Interactions with Other Subsystems

- **↑ Userspace**: every fd-consuming syscall (`read`, `write`, `close`, `ioctl`, `poll`, `mmap`, `fcntl`, `dup2`, …) begins with an fd-to-`struct file` lookup through this layer.
- **→ [[File Object (struct file)]]**: fd table slots store `struct file*` pointers; the descriptor table is the index into the open file table.
- **→ [[Dentry]]** / **[[Inode]]**: accessed indirectly via `struct file`; the descriptor table does not hold direct dentry or inode references.
- **→ [[Path Lookup]]**: `open(2)` calls `do_filp_open()` which does path resolution before allocating an fd.
- **← io_uring**: `io_uring_register(IORING_REGISTER_FILES)` imports a fixed set of `struct file*` references directly, bypassing per-syscall `fdget()`; uses `fget()` for each imported fd.
- **← [[VFS Locking Model]]**: `file_lock` in `files_struct` is a leaf spinlock in the locking hierarchy; no inode or dentry locks are taken while it is held.
- **← Process management (fork/exec/exit)**: `dup_fd()` (on fork), `do_close_on_exec()` (on exec), `exit_files()` (on exit) each operate on the descriptor table.

## Design Decisions & Tradeoffs

**Three-level separation (fd, struct file, inode)**: POSIX semantics require that `dup2` share position but `fork` not share position by default. These requirements are contradictory at the fd level, but consistent at the `struct file` level: `dup2` makes two fds point at the same `struct file` (same position), while `fork` gives the child its own fd table pointing at the same `struct file` objects (so position *is* shared, which is what POSIX pipes require). The inode level stays separate because the same file can be opened multiple times with independent positions.

**Lowest-available-fd rule**: POSIX mandates returning the lowest unused fd number. This ensures predictable behaviour (a program that closes fd 3 and then opens a file knows it will get fd 3 back) and enables the traditional UNIX trick of redirecting stdin/stdout via `close(0); open(...)`. The cost is serialisation: all threads share `file_lock` for allocation, creating a bottleneck under parallel `accept(2)` workloads. Alternatives (returning any free fd; caller-specified fd numbers) have been proposed but POSIX compliance prevents adoption in the general API; `O_CLOEXEC` on `openat2(2)` with specific fd numbers is a step in this direction.

**Inline embedded table (NR_OPEN_DEFAULT = 64)**: most processes never exceed 64 open files. Embedding the small table in `files_struct` avoids a heap allocation on every `fork()` and eliminates a pointer dereference on every fd lookup for the common case. The cost is 64 extra words in every `files_struct`, even for single-fd processes. The number 64 was chosen empirically; it covers the standard 3 stdio + library sockets + a few more comfortably.

**RCU for lock-free reads**: taking a spinlock on every `read(2)` or `write(2)` to look up the `struct file` was measured as significant overhead on multi-core systems. The RCU approach allows readers to proceed without any lock acquisition or cache-line contention; the only shared state is the `f_count` atomic, and the `fdget` optimisation eliminates even that for single-threaded processes.

**fdget borrowed-reference optimisation**: for a syscall in a single-threaded process, `f_count` cannot drop to zero during the syscall (no other thread can call `close(fd)`), so the increment is wasteful. `fdget` skips it. The complication is that the code must correctly track whether the increment was skipped — the `struct fd` flag bit carries this information. The original implementation used an obscure convention (returning a pointer with the low bit set); the 6.9 redesign made this explicit and added `__cleanup`-based automatic release to prevent the class of fd-leak bugs this optimisation historically caused.

## How It Has Evolved

- **Pre-2.6**: fd table protected by a single `files->file_lock` spinlock on every access; concurrent syscalls in a multi-threaded process serialised on every fd lookup.
- **2.6.3 (2004)**: Nick Piggin's RCU fd-table patch. Lock-free reads via `rcu_read_lock()`; writes still take `file_lock`. Benchmark improvement: 13–21% on 4-way `tiobench`.
- **2.6.12 (2005)**: `fdget`/`fdput` optimisation for unshared tables; `struct fd` returns both the pointer and whether refcount was taken.
- **3.x**: `full_fds_bits` level-2 bitmap added to accelerate fd allocation in processes with thousands of open fds.
- **5.x**: `next_fd` hint refined to restart from the freed fd on `close`, not just from 0.
- **6.9 (2024)**: Al Viro's `struct fd` redesign — packed `unsigned long` representation enabling `fd_file()` / `fd_empty()` inline helpers and `CLASS(fd, f)(n)` `__cleanup` syntax. Two real fd leaks and multiple use-after-free patterns fixed as part of the audit.

## Further Reading

1. [File management in the Linux kernel — kernel.org](https://docs.kernel.org/filesystems/files.html)
2. [A review of file descriptor memory safety — LWN.net](https://lwn.net/Articles/985853/)
3. [struct fd and memory safety — LWN.net](https://lwn.net/Articles/983957/)
4. [The problem is the lowest-unused-fd rule — LWN.net](https://lwn.net/Articles/933924/)
5. [Overview of the Linux VFS — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/vfs.html)
6. [VFS objects (kernel-internals.org)](https://kernel-internals.org/vfs/vfs-objects/)

## LKML Highlights

- **Lock-free fd table (2004)** — Nick Piggin, RCU-based fd lookup removing the per-lookup spinlock; the cover letter showed 13–21% improvement on multi-core tiobench and argued that fd lookup was measurably in the hot path for any fd-heavy workload.
- **struct fd __cleanup redesign (2023–2024)** — Al Viro's audit of ~160 `fdget`/`fdput` call sites; found two real leaks (ppc KVM, lirc) and several UAF patterns; the primary proposal was packed-integer `struct fd` + `CLASS()` macro to make scope-based cleanup compiler-enforced. Linus suggested the packed-ulong approach.
- **O_CLOEXEC introduction (2006)** — Ulrich Drepper's patch adding atomic close-on-exec to `open()`, `socket()`, and `accept()`; the motivation was a multi-threaded race window between fd creation and `fcntl(F_SETFD)` that could leak fds into exec'd children.
