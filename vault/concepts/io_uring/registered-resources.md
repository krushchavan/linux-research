---
title: "io_uring Registered Resources (Fixed Files and Buffers)"
category: concept
tags: [io_uring, fixed-buffers, fixed-files, direct-descriptors, pinning]
subsystem: io_uring
kernel_version: "5.1"
researched: 2026-09-24
status: complete
sources:
  - https://kernel-internals.org/io-uring/fixed-buffers/
  - https://kernelnewbies.org/Linux_6.15
  - https://github.com/axboe/liburing/wiki/What's-new-with-io_uring-in-6.11-and-6.12
  - https://lwn.net/Articles/1007721/
  - https://lwn.net/Articles/926118/
  - https://lwn.net/Articles/776703/
---

# io_uring Registered Resources (Fixed Files and Buffers)

## Purpose

Each ordinary I/O pays two setup taxes before any data moves. The file descriptor must be turned into a `struct file` with an `fdget()`/`fdput()` pair, which is atomic refcount traffic on a shared cache line whenever the file table is shared. A user buffer for direct I/O must be pinned with `get_user_pages()` and released afterwards. At a million IOPS these taxes are a visible share of CPU. Registered resources let an application pay them once, at registration time, and then refer to files and buffers by small integer indices. The same tables have grown into the mechanism for *direct descriptors* (files that never get a normal fd) and for kernel-supplied buffers (ublk zero-copy).

## Mental Model

Registration is **checking your bags once at the start of a trip**. Instead of producing your luggage and passport at every connection (fdget, page pinning), you hand them over once and get claim tickets (indices). Each later request just shows a ticket. The airline (kernel) holds the bags and cannot lose track of them, but it can't give them back while any flight (in-flight request) still has them on board. That's why every slot is refcounted separately.

## How It Works

**Registering files.** `io_uring_register(fd, IORING_REGISTER_FILES, fds[], n)` reaches `io_sqe_files_register()`. For each fd it takes a reference (`fget()`), refuses io_uring fds themselves (to avoid reference cycles), and stores the file in `ctx->file_table`. Each slot is an `io_rsrc_node` of type `IORING_RSRC_FILE` holding the `struct file *`. A companion bitmap tracks which slots are in use. `IORING_RSRC_REGISTER_SPARSE` (5.19) creates an empty table of a given size so slots can be filled later.

**Using a fixed file.** An SQE with `IOSQE_FIXED_FILE` treats `sqe->fd` as an index. At issue time `io_file_get_fixed()` calls `io_rsrc_node_lookup()` on the table, takes a reference on the *node* (a plain increment under `uring_lock`, no atomics on the file), and stores it in `req->file_node`. The request holds that node until it completes, so the file cannot disappear under it even if userspace replaces the slot.

**Direct descriptors (5.15).** Opcodes that create files (`IORING_OP_OPENAT`, `OPENAT2`, `ACCEPT`, `SOCKET`, and later pipe) can put the new file straight into a table slot by setting `sqe->file_index`, or into any free slot with `IORING_FILE_INDEX_ALLOC`, which returns the chosen index in the CQE. The file never enters the process fd table, so there's no `fdget` cost and no fd-table contention at all. That matters for accept-heavy servers with many threads. `IORING_OP_FIXED_FD_INSTALL` (6.8) converts a direct descriptor into a normal fd when one is needed. Ring fds themselves can be registered (`IORING_REGISTER_RING_FDS`, 5.18) so that `io_uring_enter()` with `IORING_ENTER_REGISTERED_RING` skips its own `fdget`.

**Registering buffers.** `IORING_REGISTER_BUFFERS` / `IORING_REGISTER_BUFFERS2` reach `io_sqe_buffers_register()`, which calls `io_sqe_buffer_register()` for each iovec. It pins the user pages with `pin_user_pages_fast(FOLL_WRITE | FOLL_PIN | FOLL_LONGTERM)` and charges the pinned memory against the user's `RLIMIT_MEMLOCK` via `io_account_mem()`. `FOLL_LONGTERM` matters: the pages may stay pinned indefinitely, so they must not sit in movable zones or CMA. The pinned pages become a `bio_vec` array inside a `struct io_mapped_ubuf`. If the pages come from huge pages, 6.12 coalesces them so one bvec covers the whole folio (`folio_shift`), which makes iteration faster and the structure much smaller. File-backed memory is rejected for most filesystems, because long-term pins on page-cache pages break writeback.

**Using a fixed buffer.** `IORING_OP_READ_FIXED` / `WRITE_FIXED`, and send/recv or uring_cmd with their fixed-buffer flags, carry `sqe->buf_index` plus an address and length that must lie inside the registered range. `io_import_reg_buf()` / `io_import_fixed()` validates the range (`-EFAULT` otherwise) and builds an `ITER_BVEC` `iov_iter` pointing at the pinned pages. It skips the per-I/O pinning and gives the block layer a ready-made bvec. Vectored variants `IORING_OP_READV_FIXED` / `WRITEV_FIXED` (6.15) accept an iovec whose entries all fall within one registered buffer.

**Updating and unregistering.** `IORING_REGISTER_FILES_UPDATE2` / `BUFFERS_UPDATE` replace individual slots (`-1` clears one). The old node is not freed immediately. It is freed when its refcount drops to zero, after the last in-flight request that used it completes. Older kernels achieved this with a ring-wide "rsrc node" generation and quiesce (`io_rsrc_ref_quiesce()`), which could stall. The 6.13 rework by Jens Axboe moved to simple per-slot refcounting, which removed the stalls and a lot of code.

**Sharing buffers across rings.** Registering gigabytes of buffers is slow (pinning and accounting dominate), which hurt designs where short-lived threads each create a ring. `IORING_REGISTER_CLONE_BUFFERS` (6.12) copies a source ring's buffer table into another ring by taking references on the existing `io_mapped_ubuf`s. The liburing wiki cites ~17 µs versus ~1 s for a large table.

**Kernel-registered buffers (6.15).** A driver can install *its own* pages into a ring's buffer table: `io_buffer_register_bvec()` takes a block `struct request`'s bvec and places it at an index chosen by the ublk server. `io_buffer_unregister_bvec()` removes it, and a release callback tells the driver when the last user is gone. The ublk server can then issue fixed-buffer reads/writes against its backing file using that index, moving data straight between the ublk request's pages and the backend with no copy to userspace. Keith Busch's series settled on this after several earlier designs (fused commands, splice-based, and BPF-based) for ublk zero-copy.

**Failure paths.** Registration fails with `-ENOMEM` if `RLIMIT_MEMLOCK` would be exceeded, `-EFAULT` for bad addresses, and `-EOPNOTSUPP` for file-backed memory that can't be long-term pinned. At issue time, an out-of-range index gives `-EBADF` (files) or `-EFAULT` (buffers). If the ring or task dies, `io_rsrc_data_free()` drops every node, and each node drops its file or unpins its pages once the last in-flight user is gone.

## Key Data Structures

**`struct io_rsrc_node`** (`io_uring/rsrc.h`) — one table slot.
- `type` — `IORING_RSRC_FILE` or `IORING_RSRC_BUFFER`
- `refs` — in-flight users plus the table's own reference
- `tag` — user-supplied 64-bit tag; when set, a CQE is posted when the node is finally freed
- union: `file_ptr` or `buf` (`struct io_mapped_ubuf *`)

**`struct io_rsrc_data`** — `nr` and `nodes[]`; embedded in `ctx->file_table.data` and `ctx->buf_table`.

**`struct io_mapped_ubuf`** — `ubuf`, `len`, `nr_bvecs`, `folio_shift`, `refs` (shared across cloned rings), `dir` (allowed data direction), `release`/`priv` (for kernel-registered bvecs), `bvec[]`.

**`struct io_file_table`** — `data` (the rsrc table), `bitmap` (slot occupancy), `alloc_hint`.

## Key Functions / Entry Points

**`io_sqe_files_register()` / `io_sqe_buffers_register()`** (`io_uring/rsrc.c`) — registration entry points from `io_uring_register()`.

**`io_rsrc_node_lookup()`** — index → node, bounds-checked with `array_index_nospec()` to block Spectre-v1 gadgets.

**`io_file_get_fixed()`** (`io_uring/io_uring.c`) — resolve a fixed file for a request.

**`io_import_reg_buf()`** — build an `iov_iter` from a registered buffer.

**`io_register_clone_buffers()`** — clone a buffer table from another ring.

**`io_buffer_register_bvec()` / `io_buffer_unregister_bvec()`** — driver API for kernel-owned buffers.

**`io_install_fixed_file()`** — place a new file into a direct-descriptor slot.

## Important Flags & Config Options

- **`IOSQE_FIXED_FILE`** — interpret `sqe->fd` as a table index.
- **`IORING_REGISTER_FILES` / `_FILES2` / `_FILES_UPDATE2`**, **`IORING_REGISTER_BUFFERS` / `_BUFFERS2` / `_BUFFERS_UPDATE`**, with tags.
- **`IORING_RSRC_REGISTER_SPARSE`** — pre-size an empty table.
- **`IORING_FILE_INDEX_ALLOC`** — let the kernel pick a free direct-descriptor slot.
- **`IORING_REGISTER_FILE_ALLOC_RANGE`** — restrict auto-allocation to a sub-range.
- **`IORING_REGISTER_RING_FDS` + `IORING_ENTER_REGISTERED_RING`** — avoid fdget on the ring fd itself.
- **`IORING_REGISTER_CLONE_BUFFERS`** — share buffer registrations across rings.
- **`RLIMIT_MEMLOCK`** — bounds pinned buffer memory (unless `CAP_IPC_LOCK`).

## Interactions with Other Subsystems

- **↑ Userspace**: liburing `io_uring_register_files()`, `io_uring_register_buffers()`, `io_uring_prep_*_fixed()`, `io_uring_prep_openat_direct()`.
- **→ mm**: long-term pinning via [[get-user-pages-and-pinning]]; `FOLL_LONGTERM` migrates pages out of `ZONE_MOVABLE`/CMA before pinning.
- **→ [[vfs]]**: file references (`fget`/`fput`); direct descriptors bypass the fd table (`files_struct`).
- **→ [[block]]**: fixed buffers arrive as ready-made `bio_vec` arrays; O_DIRECT can skip page pinning entirely.
- **← [[ublk]] and other drivers**: register kernel bvecs to enable zero-copy between a device request and backend I/O.
- **← [[uring-cmd-passthrough]]**: `io_uring_cmd_import_fixed()` lets passthrough commands (NVMe) use registered buffers.

## Design Decisions & Tradeoffs

**Long-term pinning.** Keeping pages pinned indefinitely is what makes fixed buffers fast. It also interferes with compaction, CMA, memory hot-unplug and page-cache writeback. The kernel therefore insists on `FOLL_LONGTERM` semantics, accounts pinned memory to `RLIMIT_MEMLOCK`, and refuses most file-backed mappings.

**Index-based, not pointer-based.** Userspace never sees kernel pointers. Indices are validated with `array_index_nospec()`, so a malicious index can't speculatively read out of bounds.

**Per-slot refcounting (6.13) vs. generation quiesce.** The old design grouped nodes into generations and, on update, sometimes had to wait for all in-flight requests of the older generation. It was simpler to reason about for bulk teardown but caused latency spikes and deadlock-prone waits. Per-slot refs make updates O(1) and non-blocking.

**Direct descriptors vs. POSIX fds.** Skipping the fd table gives big gains for multi-threaded accept loops, but a direct descriptor is invisible to ordinary syscalls. Any non-io_uring use needs `FIXED_FD_INSTALL`, and debugging tools can't see these files in `/proc/<pid>/fd`.

## How It Has Evolved

- **5.1** — `IORING_REGISTER_BUFFERS` / `FILES` from day one, with `READ_FIXED`/`WRITE_FIXED`.
- **5.5** — `IORING_REGISTER_FILES_UPDATE` for in-place updates.
- **5.13** — resource tags and `*_UPDATE2`, `BUFFERS2`/`FILES2`.
- **5.15** — direct descriptors for `openat`/`accept`.
- **5.18–5.19** — registered ring fds; sparse tables; `IORING_FILE_INDEX_ALLOC`.
- **6.8** — `IORING_OP_FIXED_FD_INSTALL`.
- **6.12** — huge-page coalescing; `IORING_REGISTER_CLONE_BUFFERS`.
- **6.13** — rsrc rework to per-node refcounting.
- **6.15** — vectored fixed buffers; kernel bvec registration used for ublk zero-copy.

## Further Reading

1. [kernel-internals.org — Fixed buffers and files](https://kernel-internals.org/io-uring/fixed-buffers/)
2. [ublk zero-copy support — patch posting (2025)](https://lwn.net/Articles/1007721/)
3. [Zero-copy I/O for ublk, three different ways — LWN (2023)](https://lwn.net/Articles/926118/) — the design history before the bvec-registration approach.
4. [liburing wiki — What's new in 6.11 and 6.12](https://github.com/axboe/liburing/wiki/What's-new-with-io_uring-in-6.11-and-6.12)
5. [Linux 6.15 — kernelnewbies](https://kernelnewbies.org/Linux_6.15)
6. `io_uring_register(2)` man page.

## LKML Highlights

> lore.kernel.org was unreachable from this run; see LWN-mirrored postings.

- **"ublk zero-copy support" (Keith Busch, 2025)** — adds a kernel-buffer resource node type so a ublk server can register a request's bvec at an index, use it in any fixed-buffer op, then unregister it. It replaced Ming Lei's earlier fused-command approach, which reviewers had considered too special-purpose.
- **Clone buffers (Jens Axboe, 6.12 cycle)** — motivated by applications that create short-lived rings per thread and could not afford to re-pin large buffer sets. Cloning shares the underlying `io_mapped_ubuf` refcounts instead of re-pinning.
