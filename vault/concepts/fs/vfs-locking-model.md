---
title: "VFS Locking Model"
category: concept
tags: [vfs, locking, concurrency, filesystem, dcache]
subsystem: fs
kernel_version: "2.6.38"
researched: 2026-04-11
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/locking.html
  - https://www.kernel.org/doc/html/latest/filesystems/directory-locking.html
  - https://www.kernel.org/doc/html/latest/filesystems/vfs.html
  - https://lwn.net/Articles/685108/
  - https://lwn.net/Articles/649115/
  - https://lwn.net/Articles/545119/
  - https://lwn.net/Articles/419811/
  - https://lwn.net/Articles/1017477/
---

# VFS Locking Model

## Purpose

The VFS layer sits between syscalls and individual filesystems, coordinating concurrent access to inodes, dentries, and the directory tree from hundreds of threads simultaneously. Without an explicit locking discipline, concurrent `rename()`, `unlink()`, and `lookup()` calls would corrupt directory trees and leave dangling pointers. The VFS locking model defines which locks protect which objects, the ordering rules that prevent deadlocks, and the fast lockless path that makes pathname lookup scale on modern many-core hardware.

## Mental Model

Think of the VFS as a city of filing cabinets (inodes) connected by a labelled index (dentries). Most workers just need to *read* the index to find a cabinet; a few need to *move* or *delete* entries. The VFS gives readers a brief read-lock on each row they scan so no one relabels it mid-read. Writers (create, unlink, rename) must grab an exclusive lock on the row's cabinet. Moving a folder from one cabinet to another is the hard case: you must lock both cabinets in a fixed order — always the ancestor first — so two concurrent moves cannot deadlock each other. The filing room also has a single master binder that governs any move crossing cabinet boundaries (the per-superblock rename mutex).

## How It Works

### The Lock Inventory

The VFS maintains six distinct synchronisation primitives. Each guards a different scope:

**`inode->i_rwsem`** (`include/linux/fs.h`) is the primary serialiser for directory mutations. It replaced the old `i_mutex` (a plain mutex) in Linux 4.7, when Al Viro's parallel-lookups work allowed multiple readers to traverse a directory simultaneously without blocking each other. Exclusive mode is required for any operation that changes a directory's contents — `create`, `mkdir`, `unlink`, `rmdir`, `rename` — or for `write(2)` on a regular file when the filesystem opts in. Shared mode is sufficient for a lookup that will install a new dentry into the cache.

**`inode->i_lock`** is a plain spinlock protecting the in-memory fields of `struct inode` that can change while the inode lives in cache: `i_state`, `i_count`, `i_nlink`, and the dirty/writeback list anchors. It is never held while sleeping.

**`dentry->d_lock`** is a per-dentry spinlock embedded inside `d_lockref`, a combined lock-plus-refcount word introduced for atomic "lock; increment; unlock" sequences. It protects `d_flags`, `d_parent`, and `d_name` against rename while a lookup is reading them in ref-walk mode.

**`dentry->d_seq`** is a per-dentry seqlock. Whenever a dentry is renamed — its `d_parent`, `d_name`, or `d_inode` changes — the sequence counter is incremented. RCU-walk readers snapshot the counter before reading those fields and then validate it afterward; if the counter changed, the dentry was modified and the lookup must retry.

**`rename_lock`** (`fs/dcache.c`) is a global seqlock updated on every rename. It guards hash-table searches in `__d_lookup()`: if a search for a name fails, the code checks whether a rename happened concurrently and retries if so, preventing a missed dentry from being mistaken for a negative lookup result.

**`sb->s_vfs_rename_mutex`** is a per-superblock mutex taken exclusively before any cross-directory rename touches its parent-pointers. Because the topological ordering of directories must not change while it is being traversed to determine lock order, the rename mutex freezes all other cross-directory renames on the same filesystem until the current one completes.

---

### Pathname Lookup: The Two-Speed Path

Path resolution in `path_walk()` / `link_path_walk()` uses two distinct modes:

**RCU-walk (fast path)** begins with `rcu_read_lock()`. The kernel reads `dentry->d_parent` and `dentry->d_inode` without touching any reference counts or spinlocks. Before using a value read from a dentry, it snapshots `d_seq`, reads the field, and then validates the sequence number has not changed. As long as the entire path exists in the dcache and no rename or unlink occurs during traversal, the full lookup completes without any write to a shared cache line — hence no inter-CPU cacheline bouncing. The benefit is dramatic on workloads opening many files concurrently on multi-core machines.

RCU-walk falls back to **ref-walk (slow path)** when: (a) a dentry component is not in the cache, (b) a d_seq validation fails (a rename happened), (c) the dentry has `DCACHE_OP_REVALIDATE` set and the filesystem's `d_revalidate()` method might sleep, or (d) the caller's `dentry_operations` cannot run safely without locks. In ref-walk, the kernel increments `d_lockref` on each intermediate dentry (pinning it in memory), acquires `d_lock` briefly to check `d_parent` and `d_name`, uses `rename_lock` seqlock reads for hash searches, and takes `i_rwsem` in shared mode on the directory inode when handing off to the filesystem's `->lookup()` method.

The transition from RCU to ref-walk is a *retry from the beginning* — the kernel drops `rcu_read_lock()`, then re-walks the path using ref counts.

---

### Directory Mutation: Create, Unlink, Rmdir

All operations that modify a directory's contents share the same basic locking template implemented by the VFS wrappers (`vfs_create()`, `vfs_unlink()`, `vfs_mkdir()`, etc.):

1. Take `i_rwsem` exclusively on the **parent** directory inode.
2. Call the filesystem's `inode_operations->create()` / `->unlink()` / etc.
3. Release the parent's `i_rwsem`.

For `unlink` and `rmdir`, the victim's `i_rwsem` is also taken exclusively so that no concurrent operation can be modifying it while it is being detached. The kernel documentation's locking table (`Documentation/filesystems/locking.rst`) lists the exact lock context for every `inode_operations` method — most require `i_rwsem` on the directory in exclusive mode.

The filesystem's callback runs under these locks, so individual filesystems do not need to re-acquire them for directory-level serialisation; they only need to add their own internal locks for journal commits or extent trees.

---

### Rename: The Hard Case

`rename()` is the most complex VFS operation because it modifies two directories simultaneously and can move directory inodes, potentially creating cycles in the tree.

For a **same-directory rename** (source and destination share one parent), the kernel takes `i_rwsem` exclusively on that parent. If both source and destination are non-directory inodes that must be individually locked, they are taken in increasing address order to prevent a cycle between two concurrent same-directory renames involving the same pair.

For a **cross-directory rename**, the sequence is:

1. Lock `sb->s_vfs_rename_mutex` exclusively. This blocks all other cross-directory renames on the filesystem, preventing the directory tree topology from changing while lock order is computed.
2. Walk the tree to determine ancestor ordering between the two parent directories. Ancestors must always be locked before descendants; this is the topological ordering that makes the scheme deadlock-free. If neither parent is an ancestor of the other, they are locked in inode-pointer address order as a tiebreak.
3. Take `i_rwsem` on the ancestor parent first (exclusive), then on the other parent (exclusive).
4. If the source is a subdirectory, lock it exclusively (a subdirectory rename must also update its `..` entry).
5. If an existing destination entry must be overwritten, lock the victim.
6. Call the filesystem's `->rename()` method.
7. Release all locks in reverse order, then release `s_vfs_rename_mutex`.

**Why this is deadlock-free**: The scheme's invariant is that there exists a global rank for every lock — the filesystem mutex has the lowest rank, then directory `i_rwsem` in ancestor-first order, then non-directory `i_rwsem` in address order. Any deadlock cycle would require two threads each to hold a higher-ranked lock while waiting for a lower-ranked one, which the acquisition order forbids. The `s_vfs_rename_mutex` ensures the topology is stable while ranks are computed.

The 2013 deadlock discovered by Dave Jones's Trinity fuzzer ([LWN 545119](https://lwn.net/Articles/545119/)) arose because `/proc` presented multiple dentries over the same directory inode, violating the VFS invariant that a directory inode has exactly one parent dentry. The fix was to always allocate fresh inodes for `/proc` rather than sharing them — the locking model itself was correct.

---

### Page Cache Coordination: `invalidate_lock`

When a filesystem implements hole-punching (`fallocate(FALLOC_FL_PUNCH_HOLE)`) or truncation, it must coordinate with the page cache to prevent a race where pages are loaded from disk *after* the on-disk data has been discarded. The `mapping->invalidate_lock` (an `rw_semaphore` added in 5.15) provides this coordination:

- `write_begin()` and `read_folio()` take `invalidate_lock` in **shared** mode, indicating that a page load or write is in progress.
- Hole-punch and truncation take `invalidate_lock` in **exclusive** mode, blocking until all in-flight page operations complete, then invalidating the page range without risk of stale data being reloaded.

---

### Permission and Attribute Reads

`->permission()`, `->getattr()`, and `->listxattr()` require no VFS-level locks because they read from the inode without modifying directory structure. Individual filesystems may take internal locks (e.g., an extent tree read lock), but the VFS does not impose any.

## Key Data Structures

**`struct inode`** (`include/linux/fs.h`) — the in-memory representation of a filesystem object.
- `i_rwsem` — read-write semaphore serialising directory mutations and (optionally) file writes
- `i_lock` — spinlock for `i_state`, `i_count`, `i_nlink`, and writeback list membership
- `i_mapping` — pointer to the address space; its `invalidate_lock` is used for page cache coordination

**`struct dentry`** (`include/linux/dcache.h`) — a cached path component.
- `d_lockref` — combined spinlock + reference count; `d_lock` is the spinlock half
- `d_seq` — seqlock counter; incremented on rename so RCU-walk readers can detect concurrent modification
- `d_parent`, `d_name` — protected by `d_lock` in ref-walk; validated via `d_seq` in RCU-walk

**`struct super_block`** (`include/linux/fs.h`) — per-filesystem state.
- `s_vfs_rename_mutex` — serialises cross-directory rename on this filesystem

**`rename_lock`** (`fs/dcache.c`) — a global `seqlock_t` updated on every rename; used by `__d_lookup()` to detect rename during hash searches.

## Key Functions / Entry Points

**`path_lookupat()`** (`fs/namei.c`) — top-level entry for pathname resolution; chooses RCU-walk or ref-walk and drives the loop over path components.

**`lookup_fast()`** (`fs/namei.c`) — the RCU-walk fast path; reads dentries under `rcu_read_lock()` with `d_seq` validation, no refcount modifications.

**`lookup_slow()`** (`fs/namei.c`) — falls back to taking the directory's `i_rwsem` shared and calling the filesystem's `->lookup()` method.

**`lock_rename()`** / **`unlock_rename()`** (`fs/namei.c`) — implement the cross-directory rename locking protocol; compute ancestor order, acquire `s_vfs_rename_mutex` if needed, then lock parents in safe order.

**`vfs_rename()`** (`fs/namei.c`) — the main rename implementation; calls `lock_rename()`, validates the operation, hands off to `->rename()`, then calls `unlock_rename()`.

**`vfs_unlink()`** / **`vfs_create()`** (`fs/namei.c`) — simpler wrappers that acquire the parent `i_rwsem` exclusively and call the filesystem method.

**`d_lookup()`** / **`__d_lookup()`** (`fs/dcache.c`) — dentry hash lookup using `rename_lock` seqlock to detect concurrent renames.

## Important Flags & Config Options

There are no Kconfig symbols that change the core VFS locking model. Individual filesystems may opt in to parallel lookup support (shared-lock lookups) by not requiring exclusive i_rwsem in their `->lookup()` implementation — a convention rather than a flag.

Filesystem developers signal safe-to-parallelize lookups by ensuring their `->lookup()` does not take operations that would conflict with a shared lock, and by relying on the in-progress lookup hash in `d_alloc_parallel()` to serialize identical concurrent lookups.

## Interactions with Other Subsystems

- **↑ Userspace**: every `open()`, `stat()`, `unlink()`, `rename()`, and `readdir()` syscall drives the VFS locking machinery; processes block on `i_rwsem` if a conflicting directory operation is in progress.
- **→ [[page-cache]]**: `invalidate_lock` on `address_space` coordinates truncation/hole-punch with page fault and read-ahead paths that load pages from disk.
- **→ [[path-lookup]]**: the RCU-walk / ref-walk path resolution logic depends entirely on this locking model; `d_seq` and `rename_lock` exist specifically to make RCU-walk correct.
- **→ [[dentry-cache]]**: `d_lock` and `d_lockref` are owned by this model; eviction and hash operations on the dcache use `d_lock` to protect structural changes.
- **← [[locking]]**: `i_rwsem` is a standard kernel `rw_semaphore`; `rename_lock` and `d_seq` are `seqlock_t` instances; `s_vfs_rename_mutex` is a standard `mutex`.
- **← Network filesystems (NFS, Ceph)**: network filesystems must respect the same VFS locking contract; `nfs_lookup()` and similar methods run under `i_rwsem` shared and must not deadlock against their own RPC call-backs.

## Design Decisions & Tradeoffs

**i_mutex → i_rwsem (Linux 4.7)**: The original per-inode mutex fully serialised all directory operations — lookups included. This was correct but wasteful: lookups are read-only and can safely run in parallel. Al Viro replaced `i_mutex` with `i_rwsem` and changed all lookup paths to take it in shared mode, allowing N concurrent lookups into the same directory. The cost was a more complex locking table and the need for an in-progress lookup hash (`d_alloc_parallel`) to prevent races when two threads both find a name missing and try to create dentries for it simultaneously.

**Global rename_lock seqlock vs per-dentry**: Using a single global seqlock for rename detection in hash searches was chosen over per-dentry alternatives for simplicity. The seqlock is read-dominated (only writes on rename), so contention is negligible for most workloads.

**Topological lock ordering vs a single global mutex**: A single lock for all directory operations would be simple but would serialise the entire filesystem. Topological ordering with `s_vfs_rename_mutex` only for cross-directory renames allows same-directory operations on different directories to proceed in parallel. The complexity cost (computing ancestor order, handling edge cases) was judged worthwhile.

**RCU-walk as an optimisation, not a redesign**: Rather than building a fully lock-free dcache, Nick Piggin's RCU-walk (merged 2.6.38) layered RCU on top of the existing locking model. RCU-walk is an optimistic fast path with a fallback to ref-walk; the fallback ensures correctness without duplicating the full locking logic in a second implementation.

**Directory hard links are forbidden**: The 2013 Trinity deadlock revealed that the entire lock-ordering scheme assumes a directory has exactly one parent dentry. VFS explicitly rejects hard links to directories at the `link()` syscall level, and the `/proc` fix (`new_inode_pseudo()`) enforced this for pseudo-filesystems that had been cheating.

## How It Has Evolved

- **Pre-2.6.38**: ref-walk only; every path component lookup briefly held `d_lock` and bumped refcounts; high contention on popular directories on multi-core.
- **2.6.38 (Nick Piggin)**: RCU-walk introduced — `d_seq` seqlock added to each dentry, `rename_lock` global seqlock added; paths through hot directories now nearly contention-free.
- **4.7 (Al Viro)**: `i_mutex` replaced by `i_rwsem`; parallel lookups into the same directory become possible; `d_alloc_parallel()` added to serialise concurrent same-name lookups.
- **5.15**: `mapping->invalidate_lock` formalised as an `rw_semaphore` in `struct address_space`; previously filesystems each implemented their own ad-hoc coordination between truncation and page loading.
- **6.x (ongoing)**: Proposals for parallel directory creates (Neil Brown, Christian Brauner) would replace the exclusive `i_rwsem` on the parent with shared mode plus per-entry locks; NFS and distributed filesystems are the primary beneficiaries.

## Further Reading

1. [Pathname lookup in Linux — LWN.net](https://lwn.net/Articles/649115/) — excellent walkthrough of both RCU-walk and ref-walk with lock annotations
2. [VFS parallel lookups — LWN.net](https://lwn.net/Articles/685108/) — covers the i_mutex → i_rwsem change and d_alloc_parallel
3. [Dcache scalability and RCU-walk — LWN.net](https://lwn.net/Articles/419811/) — Nick Piggin's original design for RCU-walk
4. [A VFS deadlock post-mortem — LWN.net](https://lwn.net/Articles/545119/) — illustrates why the "one dentry per directory inode" invariant is non-negotiable
5. [Parallel directory operations — LWN.net](https://lwn.net/Articles/1017477/) — ongoing work to parallelize creates
6. [Locking — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/locking.html) — authoritative per-method lock tables for all VFS callbacks
7. [Directory Locking — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/directory-locking.html) — formal description of the rename locking protocol

## LKML Highlights

- **RCU-walk merge (2.6.38)**: Nick Piggin's patchset adding `d_seq` seqlock and RCU-walk mode; the cover letter explains the cacheline-bouncing problem motivating the work. Message-ID: `<20101117094904.GC3781@wotan.suse.de>` (approx).
- **i_mutex → i_rwsem (4.7)**: Al Viro's series replacing the per-inode mutex with a read-write semaphore. The review discussion focused on how to handle in-flight lookups that simultaneously discover a missing dentry, which led to `d_alloc_parallel()`.
- **/proc directory inode deadlock fix (3.11)**: Discussion triggered by Dave Jones's Trinity fuzzer revealing multiple dentries on the same directory inode; Linus's response (`new_inode_pseudo()`) is in `fs/inode.c` and the thread firmly settled the "no directory hard-links" principle.
