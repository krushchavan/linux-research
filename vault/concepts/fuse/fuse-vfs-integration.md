---
title: "FUSE VFS Integration"
category: concept
tags: [fuse, vfs, filesystems, inode, dentry]
subsystem: fuse
kernel_version: "2.6.14"
researched: 2026-04-10
status: complete
sources:
  - https://www.kernel.org/doc/html/next/filesystems/fuse.html
  - https://github.com/torvalds/linux/blob/master/fs/fuse/fuse_i.h
  - https://github.com/torvalds/linux/blob/master/fs/fuse/inode.c
  - https://github.com/torvalds/linux/blob/master/fs/fuse/dir.c
  - https://lwn.net/Articles/68104/
  - https://lwn.net/Articles/832430/
  - https://lwn.net/Articles/874000/
  - https://static.lwn.net/kerneldoc/filesystems/vfs.html
  - https://docs.kernel.org/filesystems/vfs.html
---

# FUSE VFS Integration

## Purpose

FUSE VFS integration is the glue layer that makes the Linux VFS believe it is talking to a normal kernel filesystem while actually routing every operation to a userspace daemon. Without it, implementing a filesystem would require kernel code; with it, any process that can open `/dev/fuse` can provide a fully POSIX-capable filesystem. The integration layer must translate between the VFS's in-kernel object model (inodes, dentries, superblocks, file objects) and the FUSE wire protocol that moves messages between kernel and daemon.

## Mental Model

Think of FUSE's VFS integration as a translation booth in an embassy. The VFS speaks one language (C function pointers, inode structs, dcache entries), and the userspace daemon speaks another (FUSE protocol messages over `/dev/fuse`). The integration layer sits in between: it registers itself as a legitimate VFS filesystem, accepts VFS calls through the standard operation tables, translates each call into a FUSE protocol message, forwards it to the daemon, and converts the reply back into whatever the VFS expected. From the VFS's perspective it is just another filesystem; from the daemon's perspective it is just reading and writing structured messages on a file descriptor.

## How It Works

### Filesystem Registration

When the `fuse.ko` module loads, `fuse_init()` calls `register_filesystem()` three times to register three distinct filesystem types with the VFS:

- **`fuse`** — the standard type for in-memory, network, or overlay filesystems backed by a userspace daemon. The first argument to `mount(2)` is an arbitrary string that the kernel does not interpret.
- **`fuseblk`** — for block-device–backed userspace filesystems where the first argument names the device file (e.g. `ntfs-3g`).
- **`fusectl`** — the control filesystem that gets mounted at `/sys/fs/fuse/connections` and exposes one directory per active connection with `waiting` and `abort` files.

Each `file_system_type` carries an `init_fs_context` callback instead of the old `mount` callback. For `fuse`, this is `fuse_init_fs_context()`, which allocates a `fuse_fs_context` and populates a `fs_context_operations` table — telling the VFS how to parse mount options (`fuse_parse_param`), validate them (`fuse_validate`), and finally create the superblock (`fuse_get_tree`).

### Mount Process: `fuse_get_tree()` and Superblock Initialisation

When userspace calls `mount(2)` with type `fuse`, the VFS context machinery eventually reaches `fuse_get_tree()`. Here the kernel allocates both the core connection object (`struct fuse_conn` via `fuse_conn_init()`) and the per-mount wrapper (`struct fuse_mount`) that links a superblock to that connection. Multiple bind-mounts can share one `fuse_conn`, so the two objects have separate lifetimes.

`fuse_get_tree()` then calls `fuse_fill_super()`, which performs the final security checks: it verifies that the `fd=N` mount option really refers to a FUSE device file (`fuse_dev_operations`), and that the opening process belongs to the same user namespace as the superblock being constructed. Only then does it hand off to `fuse_fill_super_common()`.

Inside `fuse_fill_super_common()`, the superblock is wired up for VFS duty:

1. **Block size and limits** — `sb->s_blocksize` is set to `PAGE_SIZE`; `sb->s_maxbytes` to `MAX_LFS_FILESIZE`.
2. **Operations tables** — `sb->s_op = &fuse_super_operations` installs the superblock operations table; `sb->s_xattr = fuse_xattr_handlers` installs the extended-attribute dispatch table.
3. **Backing device info (BDI)** — a `bdi_alloc()` and `bdi_register()` call registers a `struct backing_dev_info` with the writeback subsystem. This gives FUSE a well-defined slot in the page-writeback scheduler and lets the kernel report congestion back to writers when the daemon is slow.
4. **Root inode** — `fuse_get_root_inode()` calls `fuse_iget()` with the fixed well-known `FUSE_ROOT_ID = 1` and the `rootmode` attribute supplied at mount time. This creates the first `fuse_inode` and installs the appropriate inode-operations table (`fuse_dir_inode_operations` for the root directory). A VFS root dentry is then created with `d_make_root()` and stored in `sb->s_root`.
5. **FUSE_INIT handshake** — `fuse_send_init()` is called, which enqueues the capability negotiation request (see [[fuse-connection]]). Until the daemon replies, the superblock is live but the capability flags are unknown.

The pointer `sb->s_fs_info = fuse_mount` ties the generic VFS superblock to the FUSE world. Any VFS path that has only a `struct super_block *` can reach the connection via `get_fuse_mount_super(sb)->fc`.

### The `fuse_inode`: Embedding the VFS Inode

FUSE allocates inodes from a dedicated slab cache (`fuse_inode_cachep`) using the `alloc_inode` super-operation hook, `fuse_alloc_inode()`. The allocated object is a `struct fuse_inode` whose first member is an embedded `struct inode`:

```c
struct fuse_inode {
    struct inode inode;       /* must be first — VFS uses container_of */
    u64           nodeid;     /* FUSE protocol ID for this inode */
    u64           nlookup;    /* lookup reference count */
    u64           i_time;     /* expiry timestamp for cached attrs */
    u32           inval_mask; /* which attr fields are already invalid */
    unsigned long state;      /* FUSE_I_BAD, FUSE_I_EXCLUSIVE, … */
    /* write/readdir cache fields, forget list, ... */
};
```

`get_fuse_inode(inode)` is the trivial `container_of` macro that converts a VFS `struct inode *` back to the enclosing `fuse_inode`. Every kernel path that holds only a VFS inode pointer uses this to reach FUSE-private state.

The `nodeid` is the cornerstone of the VFS↔daemon mapping. When the daemon replies to a `LOOKUP` or `CREATE` request it supplies a `nodeid` (plus a `generation` number to detect recycled node IDs). The kernel stores this in `fi->nodeid` and thereafter includes it in the header of every FUSE request targeting this inode. The daemon uses the nodeid to look up its own in-memory state. There is no direct relationship between a `nodeid` and a Unix inode number; both are chosen by the daemon and need not match.

`fuse_iget()` is the factory that either creates a new inode or finds an existing one in the inode cache. The VFS `iget_locked()` call hashes on the inode number — but FUSE sets `inode->i_ino` to the `nodeid` (truncated to `unsigned long` on 32-bit; a hash on 64-bit) so that the inode cache can find existing inodes for the same node without a round-trip to the daemon. After `iget_locked()` returns a fresh (locked) inode, `fuse_init_inode()` selects the right operations tables based on the file mode, sets `fi->nodeid`, and calls `fuse_change_attributes()` to populate `i_size`, `i_mtime`, `i_uid`, etc. from the attributes the daemon returned.

### Inode Operations Tables

FUSE installs different `inode_operations` depending on the file mode:

| Mode | Operations table | Notable callbacks |
|---|---|---|
| Directory | `fuse_dir_inode_operations` | `lookup`, `create`, `mkdir`, `unlink`, `rmdir`, `rename`, `symlink`, `link`, `permission`, `setattr`, `getattr` |
| Regular file | `fuse_file_inode_operations` | `setattr`, `getattr`, `permission`, `fallocate`, `copy_file_range` |
| Symlink | `fuse_symlink_inode_operations` | `get_link`, `getattr` |

Every operation in these tables follows the same pattern: marshal the arguments into a FUSE request message, submit it via `fuse_simple_request()` (which sleeps until the daemon replies), then extract the results and update kernel state. For example, `fuse_lookup()` sends a `FUSE_LOOKUP` message carrying the parent nodeid and the filename; the daemon replies with a `fuse_entry_out` struct containing the child's nodeid, its inode attributes, and two timeout values — `entry_valid` (how long the name→nodeid mapping can be trusted) and `attr_valid` (how long the inode attributes can be trusted).

### The Attribute and Entry Cache

FUSE maintains two distinct caches within every inode that directly affect how the VFS behaves:

**Attribute cache** — `fi->i_time` stores the jiffies timestamp when the cached attributes expire. `fuse_change_attributes()` reads the `attr_valid` value from the daemon's reply and writes `jiffies + attr_valid * HZ` into `fi->i_time`. When any operation calls `fuse_update_attributes()` and finds that `time_before64(fi->i_time, get_jiffies_64())` is true, it issues a fresh `FUSE_GETATTR` before proceeding.

**Entry (dentry) cache** — the timeout for name→nodeid mappings lives in the dentry's private data. `fuse_dentry_init()` (called via `fuse_dentry_operations.d_init`) allocates a `struct fuse_dentry` and sets `fd->time = 0` (immediately expired). When a `LOOKUP` reply arrives, `fuse_change_entry_timeout()` stores `jiffies + entry_valid * HZ` in `fd->time`.

The interplay of these two caches determines the freshness guarantees FUSE offers. A dentry is considered valid — and the kernel can skip issuing a `FUSE_LOOKUP` — only while its entry timeout has not expired.

### Dentry Operations and Revalidation

FUSE installs `fuse_dentry_operations` on every dentry it owns:

```c
const struct dentry_operations fuse_dentry_operations = {
    .d_revalidate  = fuse_dentry_revalidate,
    .d_delete      = fuse_dentry_delete,
    .d_init        = fuse_dentry_init,
    .d_release     = fuse_dentry_release,
    .d_automount   = fuse_dentry_automount,
};
```

`fuse_dentry_revalidate()` is the most important. It is called by the VFS on every path lookup that traverses a cached dentry. Its logic:

1. If the dentry's `fd->time` has not expired, return 1 (valid) immediately — this is the fast path and costs nothing beyond a jiffies comparison.
2. If the connection is dead (`fc->connected == 0`), return 0 (invalid) so the VFS drops the dentry and returns an error to the caller.
3. Otherwise send a `FUSE_LOOKUP` to the daemon. If the reply carries the same `nodeid` and `generation` as the cached inode, the dentry is still valid; `fuse_change_entry_timeout()` refreshes the expiry timestamp. If the nodeid changed or the lookup fails, return 0 so the VFS calls `fuse_lookup()` anew.

`fuse_dentry_delete()` returns true when the entry timeout is already zero, signalling to the VFS that the dentry should not be kept in the dcache at all — this prevents accumulation of stale negative entries from short-lived files.

`fuse_dentry_automount()` handles the case where the dentry is a cross-mount point: FUSE submounts (kernel 5.10+) can nest, and VFS calls `d_automount` to trigger the child mount when the path resolver steps over such a dentry.

### File Operations

When a process calls `open(2)` on a FUSE file, `fuse_open()` sends a `FUSE_OPEN` (or `FUSE_OPENDIR` for directories) request. The daemon replies with a `fuse_open_out` containing a `fh` (file handle) opaque integer and `open_flags` (e.g. `FOPEN_DIRECT_IO`, `FOPEN_KEEP_CACHE`, `FOPEN_STREAM`). The kernel stores these in a `struct fuse_file`:

```c
struct fuse_file {
    struct fuse_mount *fm;      /* owning mount */
    u64                kh;      /* kernel-side handle (unique ID) */
    u64                fh;      /* daemon-assigned file handle */
    u64                nodeid;  /* associated inode */
    refcount_t         count;
    u32                open_flags; /* FOPEN_* flags from daemon */
    enum { IOM_NONE, IOM_CACHED, IOM_UNCACHED } iomode;
};
```

The `fh` is returned to the daemon in the `fuse_in_header` of every subsequent `READ`, `WRITE`, `FSYNC`, and `FLUSH` request, allowing stateful server-side file handles (analogous to NFS file handles). `kh` is the kernel's own unique ID used to look up the `fuse_file` in `fc->polled_files` for `poll(2)` support.

The `FOPEN_DIRECT_IO` flag tells the kernel to bypass the page cache for this file entirely; `FOPEN_KEEP_CACHE` (the default if neither direct nor invalidate is set) allows the VFS page cache to hold data across open/close cycles. `FOPEN_STREAM` marks the file as a stream (like a pipe) that does not support `lseek`.

For `read(2)` and `write(2)`, the registered `file_operations` (either `fuse_file_operations` for regular files or `fuse_dir_operations` for directories) call into `fuse_read_iter()` / `fuse_write_iter()`. These build one or more `FUSE_READ` / `FUSE_WRITE` protocol messages, each bounded by `fc->max_pages * PAGE_SIZE`, and submit them via the [[fuse-request-queue]]. The daemon returns data in-band in its reply for reads, or a byte count for writes.

### Superblock Operations

The `fuse_super_operations` table wires the superblock lifecycle into FUSE:

| Callback | FUSE implementation | What it does |
|---|---|---|
| `alloc_inode` | `fuse_alloc_inode` | Allocates `fuse_inode` from slab cache |
| `free_inode` | `fuse_free_inode` | Returns slab memory |
| `evict_inode` | `fuse_evict_inode` | Sends `FUSE_FORGET` to daemon, releases passthrough/DAX resources |
| `write_inode` | `fuse_write_inode` | Flushes dirty inode attrs (a no-op for most FUSE types) |
| `drop_inode` | `generic_delete_inode` | Never puts inode on LRU; always evicts immediately |
| `statfs` | `fuse_statfs` | Sends `FUSE_STATFS`, translates reply to `kstatfs` |
| `umount_begin` | `fuse_umount_begin` | Called on lazy unmount; initiates graceful connection shutdown |
| `show_options` | `fuse_show_options` | Prints `fd=`, `rootmode=`, `user_id=`, `group_id=` to `/proc/mounts` |

`fuse_evict_inode()` is particularly important: it calls `fuse_forget_nolock()` to enqueue a `FUSE_FORGET` message with the accumulated `nlookup` count. The daemon uses this to know when it can free its own per-inode state. `nlookup` is incremented on every successful `LOOKUP` (including the initial `fuse_iget`), and the `FORGET` message carries the total count so that a single forget can undo multiple lookups.

## Key Data Structures

**`struct fuse_inode`** (`fs/fuse/fuse_i.h`) — extends the VFS inode with FUSE-private state.
- `inode` — embedded VFS inode; must be first for `container_of` to work
- `nodeid` — the daemon-assigned identifier sent in every request header
- `nlookup` — accumulated lookup reference count; sent to daemon on eviction via `FORGET`
- `i_time` — jiffies expiry for cached attributes; 0 means already expired
- `inval_mask` — bitmask of attribute fields that are known stale
- `state` — bit-flags: `FUSE_I_BAD` (inode has been invalidated), `FUSE_I_EXCLUSIVE` (exclusive create in progress)

**`struct fuse_dentry`** (`fs/fuse/dir.c`) — dentry-private FUSE state, allocated by `fuse_dentry_init`.
- `time` — jiffies expiry for the name→nodeid mapping (entry cache timeout)
- `node_id` — nodeid at the time the entry was last validated; used to detect renames by the daemon

**`struct fuse_file`** (`fs/fuse/fuse_i.h`) — open file handle state.
- `fm` — the owning `fuse_mount`
- `kh` / `fh` — kernel and daemon file handle identifiers
- `open_flags` — `FOPEN_DIRECT_IO`, `FOPEN_KEEP_CACHE`, `FOPEN_STREAM`, etc.
- `iomode` — `IOM_NONE`, `IOM_CACHED` (writeback mode), or `IOM_UNCACHED` (passthrough/direct)

**`struct fuse_mount`** (`fs/fuse/fuse_i.h`) — binds a VFS superblock to a FUSE connection.
- `fc` — the shared `fuse_conn`
- `sb` — the VFS superblock
- `fc_entry` — links into `fc->mounts` (one connection, potentially multiple mounts)

## Key Functions / Entry Points

**`fuse_init()`** (`fs/fuse/inode.c`) — module init; registers `fuse`, `fuseblk`, and `fusectl` with VFS and allocates `fuse_inode_cachep`.

**`fuse_get_tree()`** (`fs/fuse/inode.c`) — VFS context operation; allocates `fuse_conn` + `fuse_mount`, then calls into superblock creation.

**`fuse_fill_super_common()`** (`fs/fuse/inode.c`) — installs operation tables, registers BDI, creates root inode via `fuse_get_root_inode()`, and triggers `FUSE_INIT`.

**`fuse_alloc_inode()`** (`fs/fuse/inode.c`) — `alloc_inode` hook; allocates `fuse_inode` from slab, initialising all locks and list heads.

**`fuse_iget()`** (`fs/fuse/inode.c`) — finds or creates a VFS inode for a given `nodeid`; calls `fuse_init_inode()` and `fuse_change_attributes()` on a newly allocated inode.

**`fuse_change_attributes()`** (`fs/fuse/inode.c`) — copies daemon-supplied attribute values into the VFS inode fields and resets `fi->i_time` to the new expiry.

**`fuse_evict_inode()`** (`fs/fuse/inode.c`) — `evict_inode` hook; sends `FUSE_FORGET` with the accumulated `nlookup`, aborts any pending writes, releases file resources.

**`fuse_lookup()`** (`fs/fuse/dir.c`) — `inode_operations.lookup`; sends `FUSE_LOOKUP`, calls `fuse_iget()` to install the returned inode, sets entry timeout on the dentry.

**`fuse_dentry_revalidate()`** (`fs/fuse/dir.c`) — `dentry_operations.d_revalidate`; fast-path jiffies check or slow-path `FUSE_LOOKUP` to verify dentry freshness.

**`fuse_open()`** (`fs/fuse/file.c`) — `file_operations.open`; sends `FUSE_OPEN`, allocates a `fuse_file`, stores daemon `fh` and `open_flags`.

## Important Flags & Config Options

| Symbol | Where | Effect |
|---|---|---|
| `FOPEN_DIRECT_IO` | `fuse_open_out.open_flags` | Per-file: bypass the page cache for reads and writes |
| `FOPEN_KEEP_CACHE` | `fuse_open_out.open_flags` | Per-file: allow page cache to persist across open/close cycles |
| `FOPEN_STREAM` | `fuse_open_out.open_flags` | Per-file: mark as a stream; `lseek` is not meaningful |
| `FUSE_WRITEBACK_CACHE` | `fuse_conn.writeback_cache` | Connection-wide: enable page-cache write-back buffering (negotiated at `FUSE_INIT`) |
| `FUSE_AUTO_INVAL_DATA` | `fuse_conn.auto_inval_data` | Connection-wide: kernel invalidates page cache when size or mtime changes |
| `FUSE_EXPLICIT_INVAL_DATA` | `fuse_conn.explicit_inval_data` | Connection-wide: kernel only invalidates page cache when daemon sends `FUSE_NOTIFY_INVAL_INODE` |
| `FUSE_POSIX_ACL` | `fuse_conn.posix_acl` | Connection-wide: kernel enforces POSIX ACLs using `xattr` round-trips |
| `default_permissions` | mount option | VFS performs standard Unix permission checks before calling FUSE `permission()` |
| `allow_other` | mount option | Allows users other than the mount owner to access the filesystem |
| `CONFIG_FUSE_FS` | Kconfig | Compiles the FUSE kernel module |
| `CONFIG_VIRTIO_FS` | Kconfig | Compiles virtiofs (reuses all FUSE VFS integration; replaces `/dev/fuse` with virtio transport) |

## Interactions with Other Subsystems

- **↑ Userspace**: userspace daemons read VFS-triggered requests from `/dev/fuse` and write replies; `fusermount` translates the `mount(2)` call into the correct `fuse` filesystem type with the required options.
- **→ VFS / dcache**: FUSE registers three `file_system_type` structs and installs operation tables on every superblock, inode, dentry, and file object it creates; the VFS owns these objects' lifetimes but dispatches all method calls through FUSE's tables.
- **→ Page cache**: for files without `FOPEN_DIRECT_IO`, the kernel's page cache buffers data; `FUSE_WRITEBACK_CACHE` mode fully integrates with the write-back path, while `FUSE_AUTO_INVAL_DATA` and `FUSE_EXPLICIT_INVAL_DATA` control when stale cache pages are evicted.
- **→ Writeback / BDI**: the registered BDI lets `wbc` (write-back control) schedule dirty-page flushes to the daemon; congestion signals from [[fuse-connection]] flow back through BDI to throttle writers.
- **→ [[fuse-connection]]**: every VFS operation that cannot be served from cache becomes a FUSE request posted to the connection's queue and dispatched over `/dev/fuse`.
- **→ [[fuse-request-queue]]**: `fuse_simple_request()` and `fuse_simple_background()` are the handoff points from the VFS integration layer to the request queue.
- **← Security / namespaces**: `fuse_permission()` checks are gated by the `default_permissions` mount flag; uid/gid translation uses `fc->user_ns` to remap IDs between the daemon's user namespace and the mounting namespace.
- **← fsnotify**: inotify watches installed on FUSE inodes generate notifications when the kernel receives `FUSE_NOTIFY_INVAL_INODE` or `FUSE_NOTIFY_DELETE` events from the daemon; full bidirectional inotify for virtiofs was proposed in 2022 but not yet merged.

## Design Decisions & Tradeoffs

**Embed `struct inode` rather than pointer.** All FUSE private state (nodeid, nlookup, attribute-cache timers) lives in a `fuse_inode` that starts with an embedded `struct inode`. This allows the VFS to own the inode's lifecycle (slab allocation, reference counting, eviction) without FUSE needing to manage a shadow object separately. The tradeoff is that `fuse_alloc_inode` must allocate memory for the full `fuse_inode` even for inodes that will never be used, and the struct is noticeably larger than plain `struct inode`.

**Timeout-based rather than callback-based invalidation.** FUSE chose a pull model: each dentry and inode carries an expiry time; when it passes, the kernel re-queries the daemon. The alternative — pushing invalidation events from daemon to kernel eagerly — would require a separate notification channel and more complex protocol. The timeout approach is simpler and works well for local FUSE filesystems, but it means remote changes (e.g. on a network-backed FUSE filesystem) are invisible to the kernel until the next expiry. The `FUSE_NOTIFY_INVAL_INODE` and `FUSE_NOTIFY_INVAL_ENTRY` messages were added later to allow daemons to push invalidations when they need stronger consistency.

**`nlookup` as the inode-forget reference count.** The kernel tracks how many VFS lookups have returned a given nodeid and sends the cumulative count in a single `FUSE_FORGET`. This batching avoids a round-trip on every dentry drop. The downside is that the daemon must maintain its own reference-count invariant and must not free per-inode state until it has received a `FORGET` with a matching total.

**No VFS writeback for most FUSE filesystems (pre-3.15).** Originally FUSE used synchronous `FUSE_WRITE` for every write: the page cache was not involved and each `write(2)` call generated a FUSE round-trip. This gave strong consistency but poor throughput for local filesystems like SSHFS. `FUSE_WRITEBACK_CACHE` (3.15) opted into the VFS page-writeback path, allowing writes to be batched and coalesced — but at the cost of potential stale reads if external writers modify the file concurrently.

## How It Has Evolved

- **2.6.14 (2005)**: initial merge. Synchronous write model; `fuse_dir_inode_operations` and `fuse_file_operations` tables; `/dev/fuse` character device; `fuse`, `fuseblk`, and `fusectl` filesystem types.
- **2.6.26**: `FUSE_ATOMIC_O_TRUNC` added — allows `open` with `O_TRUNC` to be forwarded to the daemon atomically rather than as a separate `FUSE_SETATTR` call, reducing round-trips.
- **3.15**: `FUSE_WRITEBACK_CACHE` capability added; FUSE integrated fully with the VFS page-writeback infrastructure, enabling buffered write batching for the first time.
- **4.6**: `FUSE_AUTO_INVAL_DATA` generalised into `FUSE_EXPLICIT_INVAL_DATA` — allowing daemons to opt in to explicit push-based page-cache invalidation instead of size/mtime heuristics.
- **4.20**: `FUSE_NOTIFY_INVAL_INODE` and `FUSE_NOTIFY_DELETE` notifications allowed daemons to push cache-invalidation events to the kernel, enabling stronger consistency for network-backed filesystems.
- **5.10**: FUSE submounts (`fuse_dentry_automount`) added, allowing nested FUSE filesystems to appear as kernel submounts at cross-directory-entry boundaries rather than as plain directories.
- **5.15**: passthrough read/write merged — daemons can opt in to `FOPEN_PASSTHROUGH` on a per-file basis, causing the kernel to forward I/O directly to a lower `struct file` via `call_read_iter` / `call_write_iter`, bypassing the daemon for data-path operations.
- **6.6**: iomap support added for FUSE, allowing large sequential I/O to use the kernel's iomap infrastructure (used by XFS and ext4) rather than per-page scatter-gather, improving throughput for large files.

## Further Reading

1. [FUSE — The Linux Kernel documentation](https://www.kernel.org/doc/html/next/filesystems/fuse.html) — canonical reference; covers mount options, security model, and the request/response cycle
2. [Introducing FUSE (LWN, 2004)](https://lwn.net/Articles/68104/) — original architecture overview including the three-component design
3. [Overview of the Linux Virtual File System](https://docs.kernel.org/filesystems/vfs.html) — explains the VFS interfaces (`file_system_type`, `super_operations`, `inode_operations`, `file_operations`, `dentry_operations`) that FUSE implements
4. [FUSE passthrough read/write (LWN)](https://lwn.net/Articles/832430/) — design rationale for the passthrough I/O path that bypasses daemon round-trips for vetted files
5. [Inotify support in FUSE and virtiofs (LWN)](https://lwn.net/Articles/874000/) — discusses how fsnotify integrates with FUSE's notification mechanism
6. [`fs/fuse/fuse_i.h`](https://github.com/torvalds/linux/blob/master/fs/fuse/fuse_i.h) — authoritative struct definitions for `fuse_inode`, `fuse_file`, `fuse_mount`, `fuse_conn`
7. [`fs/fuse/dir.c`](https://github.com/torvalds/linux/blob/master/fs/fuse/dir.c) — `fuse_dentry_operations`, directory inode ops, `fuse_lookup`, `fuse_dentry_revalidate`
8. [`fs/fuse/inode.c`](https://github.com/torvalds/linux/blob/master/fs/fuse/inode.c) — `fuse_get_tree`, `fuse_fill_super_common`, `fuse_alloc_inode`, `fuse_iget`, `fuse_evict_inode`

## LKML Highlights

- **fuse: add writeback cache support** (around 3.15, series by Brian Foster) — proposed integrating FUSE with the VFS page-writeback path. Key debate was about read-after-write consistency: with writeback enabled the kernel might serve a read from dirty page-cache data before the daemon has acknowledged the write, which is acceptable for local filesystems (SSHFS) but dangerous for shared network filesystems. The resolution was to make `FUSE_WRITEBACK_CACHE` an opt-in capability rather than the default.
- **fuse: allow parallel lookups and readdir** (`FUSE_PARALLEL_DIROPS`, merged 4.8) — previously a global mutex serialised all directory operations. The patch relaxed this to allow concurrent `LOOKUP` and `READDIR` on the same directory, with debate about whether daemons that assumed serialisation would break. The capability flag was added so existing daemons would not be affected.
- **fuse: passthrough read/write** (series targeting ~5.15) — proposed allowing `FOPEN_PASSTHROUGH` to let the kernel bypass the daemon for I/O on files the daemon pre-authorised. The main debate was about credential switching: since the kernel issues I/O on behalf of the calling process rather than the daemon, it temporarily adopts the daemon's credentials for the lower filesystem call. Reviewers challenged whether this was safe; the final design restricts passthrough to files where the daemon holds an open `struct file` on the lower filesystem.
