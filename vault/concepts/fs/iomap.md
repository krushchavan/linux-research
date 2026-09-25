---
title: "iomap"
category: concept
tags: [fs, iomap, page-cache, direct-io, buffer-heads, xfs]
subsystem: fs
kernel_version: "4.8"
researched: 2026-09-25
status: complete
explained: "[[iomap-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/filesystems/iomap/design.html
  - https://www.kernel.org/doc/html/latest/filesystems/iomap/operations.html
  - https://lwn.net/Articles/1079415/
  - https://lwn.net/Articles/974958/
  - https://lwn.net/Articles/931809/
  - https://lwn.net/Articles/969359/
  - https://kernelnewbies.org/KernelProjects/iomap
  - https://blogs.oracle.com/linux/upcoming-xfs-work-in-linux-v48-v49-and-v410-by-darrick-wong
---

# iomap

> 📘 Plain-language version: [[iomap-explained]]

## Purpose

Every filesystem has to answer the same question over and over: "for this byte range of this file, where does the data live on storage, and is it allocated, reserved, unwritten or a hole?" Historically each filesystem answered it one block at a time through **buffer heads**, and then reimplemented buffered I/O, direct I/O, fiemap, seek and swapfile support around those answers. iomap is a shared filesystem library (`fs/iomap/`) that asks the filesystem for **whole extents** instead and implements the common file operations generically on top of them. Filesystems get to delete large amounts of boilerplate, the generic code works on byte ranges and large folios instead of 512-byte–4 KiB blocks, and filesystems learn the full size of an operation up front, which lets them make larger allocations and fight fragmentation.

## Mental Model

iomap is a **tour guide with a map-reading assistant**. The guide (iomap's generic code) knows how to lead any tour: read a file into the page cache, write through it, do direct I/O, answer fiemap. It doesn't know the terrain, so for each leg it asks the assistant (the filesystem's `->iomap_begin`), "from here, how far does this stretch go and what's it like?" The assistant answers with one contiguous stretch: "the next 8 MiB are mapped at disk address X", or "the next 64 KiB are a hole", or "unwritten". The guide handles the whole stretch in one go, then tells the assistant it's done (`->iomap_end`) and asks about the next one. Buffer heads, by contrast, made the guide ask about every single step.

## How It Works

**The iterator and the two callbacks.** Every iomap operation is built on the same loop. A caller such as `iomap_file_buffered_write()` sets up a `struct iomap_iter` describing the file (`inode`), the current position (`pos`), the remaining length (`len`) and the operation `flags`, then repeatedly calls `iomap_iter()`. Each turn of the loop calls the filesystem's `iomap_begin` from its `struct iomap_ops`, passing the position, length and flags describing the operation (`IOMAP_WRITE`, `IOMAP_ZERO`, `IOMAP_DIRECT`, `IOMAP_DAX`, `IOMAP_FAULT`, `IOMAP_NOWAIT`, `IOMAP_OVERWRITE_ONLY`, `IOMAP_ATOMIC`, `IOMAP_DONTCACHE`…). The filesystem fills in a `struct iomap` describing **one contiguous mapping starting at `pos`**, possibly shorter than requested. iomap then does the actual work for that range: copying data into folios, building bios, reporting an extent. Afterwards it calls `iomap_end` with the number of bytes actually processed, so the filesystem can release reservations it made for bytes that weren't used (for example after a short write) or finish metadata updates. The loop advances `pos` and repeats until the range is done or an error occurs. Before 5.15 the same pattern was expressed as `iomap_apply()` with an actor callback; the iterator form (Christoph Hellwig) made it easier to write and optimise.

**What a mapping says.** `struct iomap` carries the file range (`offset`, `length`), where it lives (`addr` on `bdev`, or on `dax_dev`, or `inline_data` in memory), and a `type`:
- `IOMAP_HOLE` — nothing allocated; reads return zeroes, and it's never valid for a write
- `IOMAP_DELALLOC` — space reserved but not yet allocated (delayed allocation)
- `IOMAP_MAPPED` — real space on the device at `addr`
- `IOMAP_UNWRITTEN` — allocated but not yet written; reads return zeroes and a write must later convert it
- `IOMAP_INLINE` — the data lives in a memory buffer (for example inline in the inode)

`flags` add properties: `IOMAP_F_NEW` (freshly allocated, so partial blocks must be zeroed), `IOMAP_F_DIRTY` (metadata not yet committed, which matters for `O_DSYNC`), `IOMAP_F_SHARED` (shared extent, so a write must copy-on-write), `IOMAP_F_STALE` (mapping went stale; look it up again) and a few device-constraint flags. A `validity_cookie` lets the filesystem detect later that the mapping has changed, and `private` carries filesystem data from `iomap_begin` to `iomap_end`.

**Copy-on-write with `srcmap`.** For writes to shared (reflinked) extents, `iomap_begin` returns **two** mappings: `iomap` for where the new data will be written (a fresh private allocation) and `srcmap` for where existing data must be read from (the shared extent). A partial-block write can then read the old contents from the source and write the merged result to the destination. This is how XFS reflink works through the generic code.

**Locking.** iomap documents three levels. The **upper** level is VFS locking held by the caller across the whole operation (`i_rwsem`, `invalidate_lock`, folio locks for faults). The **lower** level is the filesystem's own mapping lock (XFS `ILOCK`, ext4 `i_data_sem`), taken *inside* `iomap_begin` only long enough to sample the mapping. The **operation** level is iomap's own (folio locks, per-folio state locks). Upper locks are always taken before lower ones. Because the mapping lock is dropped before iomap touches the page cache, the mapping can change underneath it, which is why the validity check below exists.

**Buffered reads.** `iomap_read_folio()` and `iomap_readahead()` fill the page cache. For each mapping they either zero the folio range (holes, unwritten extents), copy inline data, or build bios straight into the folios, covering as much of a large folio as one mapping allows. Per-folio state (`struct iomap_folio_state`, known as `iomap_page` before 6.5) is only needed when a folio contains several filesystem blocks. It then tracks **uptodate and dirty bits per block**, so a partially read or partially written large folio can be handled correctly. When the block size equals the folio size, the folio's own flags are enough and no extra state is allocated.

**Buffered writes: the fast path.** `iomap_file_buffered_write()` asks the filesystem for a mapping covering as much of the write as possible (often reserving delayed allocation for the whole range at once), then, for each folio in that mapping, gets a locked folio (`get_folio`, by default `iomap_get_folio()`), reads in any partial blocks that must be preserved, copies the user data in, and marks the affected blocks dirty. Large folios mean one folio can take a large chunk of the copy.

**Buffered writes: the stale-mapping path.** Between `iomap_begin` returning a mapping and iomap locking a folio, writeback or a truncate can change the file's extents, for example converting delayed allocation into real blocks. A write that trusted the stale mapping could corrupt data. So after locking each folio, iomap calls the filesystem's `iomap_valid()` hook, which compares the mapping's `validity_cookie` against the filesystem's current sequence number (XFS bumps a per-inode sequence count on every extent change; ext4's iomap conversion added one for its extent status tree). If the mapping is stale, iomap marks it `IOMAP_F_STALE`, ends this iteration and asks for a fresh mapping. Page faults on mapped files take the same path via `iomap_page_mkwrite()` with `IOMAP_WRITE | IOMAP_FAULT`.

**Buffered writes: the failure path.** If a write copies fewer bytes than expected (a fault on the user buffer, say), the filesystem may have reserved delayed allocation for bytes that never became dirty. `iomap_write_delalloc_release()` walks the unused range and calls the filesystem's `punch` callback to release those reservations, so no reserved-but-unused space is left behind to be written as garbage later.

**Writeback.** `iomap_writepages()` walks dirty folios. For each dirty block range it calls the filesystem's `writeback_range()` to map it (converting delayed allocation into real extents at this point), reusing the mapping for contiguous dirty blocks, and appends the range to a bio wrapped in a `struct iomap_ioend`. Inline and delalloc mappings are rejected here, because by writeback time every dirty block must have real space. Ioends for adjacent ranges are merged (`iomap_ioend_try_merge()`) and sorted, so completion work such as converting unwritten extents or ending COW can be done for one large range in a single transaction instead of once per bio. The default completion clears writeback on the folios and records errors; filesystems that must update metadata install their own completion that runs in a workqueue and finally calls `iomap_finish_ioends()`.

**Direct I/O.** `iomap_dio_rw()` bypasses the page cache. It first flushes and invalidates any cached pages in the range, then iterates mappings with `IOMAP_DIRECT` and builds bios directly from the user's buffer, pinning its pages. Holes and unwritten extents read as zeroes. Writes into unwritten or COW extents are flagged (`IOMAP_DIO_UNWRITTEN`, `IOMAP_DIO_COW`) so the filesystem's `end_io` in `struct iomap_dio_ops` can convert or remap the extents after the data is safely on disk. Asynchronous requests return `-EIOCBQUEUED` and complete later. Useful flags: `IOMAP_DIO_FORCE_WAIT` (wait even for async kiocbs), `IOMAP_DIO_OVERWRITE_ONLY` (only pure overwrites, else `-EAGAIN`, which lets filesystems try a lock-light path first) and `IOMAP_DIO_PARTIAL` (return progress when a page fault interrupts the request; the caller retries with `done_before` set). Returning `-ENOTBLK` tells the caller to fall back to buffered I/O. `IOMAP_ATOMIC` asks for torn-write protection, using a single `REQ_ATOMIC` bio when the hardware supports it, or a filesystem software fallback.

**DAX and the rest.** For persistent-memory filesystems, the same iterator drives `dax_iomap_rw()` and `dax_iomap_fault()`, which copy to or map device memory directly instead of using the page cache. The iterator also provides FIEMAP (`iomap_fiemap()`), `SEEK_HOLE`/`SEEK_DATA` (`iomap_seek_hole/data()`), bmap, zeroing and truncation of partial blocks (`iomap_zero_range()`, `iomap_truncate_page()`), unsharing of reflinked extents, and swapfile activation (`iomap_swapfile_activate()`), each a few dozen lines on top of the same mapping loop.

## Key Data Structures

**`struct iomap`** (`include/linux/iomap.h`) — one contiguous mapping returned by the filesystem.
- `offset`, `length` — file byte range covered
- `type` — `IOMAP_HOLE` / `DELALLOC` / `MAPPED` / `UNWRITTEN` / `INLINE`
- `flags` — `IOMAP_F_NEW`, `_DIRTY`, `_SHARED`, `_STALE`, …
- `addr`, `bdev`, `dax_dev`, `inline_data` — where the data lives
- `validity_cookie` — sequence sample for revalidation
- `private` — filesystem context passed to `iomap_end`

**`struct iomap_iter`** — loop state: `inode`, `pos`, `len`, `flags`, the current `iomap` and `srcmap`, and `private`.

**`struct iomap_ops`** — `iomap_begin(inode, pos, length, flags, iomap, srcmap)` and `iomap_end(inode, pos, length, written, flags, iomap)`.

**`struct iomap_folio_state`** (`fs/iomap/buffered-io.c`) — per-folio bitmap of uptodate and dirty blocks, plus read/write byte counts pending, allocated only when block size < folio size.

**`struct iomap_ioend`** — writeback completion unit wrapping a bio; carries the file range, mapping type and flags so completions can be merged and processed per range.

**`struct iomap_dio_ops`** — `end_io`, optional `submit_io`, optional `bio_set` for direct I/O.

## Key Functions / Entry Points

**`iomap_iter()`** (`fs/iomap/iter.c`) — advances the loop: finishes the previous mapping (`iomap_end`), asks for the next (`iomap_begin`).

**`iomap_read_folio()` / `iomap_readahead()`** (`fs/iomap/buffered-io.c`) — page-cache reads; wired into `address_space_operations`.

**`iomap_file_buffered_write()`** — buffered write loop, called from a filesystem's `->write_iter`.

**`iomap_page_mkwrite()`** — write fault on a shared file mapping.

**`iomap_writepages()`** — writeback entry point from `->writepages`.

**`iomap_dio_rw()`** (`fs/iomap/direct-io.c`) — direct I/O for reads and writes.

**`iomap_zero_range()` / `iomap_truncate_page()` / `iomap_file_unshare()`** — partial-block zeroing and reflink unsharing.

**`iomap_fiemap()`, `iomap_seek_hole()`, `iomap_seek_data()`, `iomap_swapfile_activate()`, `iomap_bmap()`** — mapping-report helpers.

**`dax_iomap_rw()` / `dax_iomap_fault()`** (`fs/dax.c`) — fsdax paths on the same iterator.

## Important Flags & Config Options

- `CONFIG_FS_IOMAP` — selected by filesystems that use it; not user-visible.
- Operation flags to `iomap_begin`: `IOMAP_WRITE`, `IOMAP_ZERO`, `IOMAP_REPORT` (fiemap), `IOMAP_FAULT`, `IOMAP_DIRECT`, `IOMAP_NOWAIT` (return `-EAGAIN` instead of blocking; used by io_uring and `RWF_NOWAIT`), `IOMAP_OVERWRITE_ONLY`, `IOMAP_UNSHARE`, `IOMAP_DAX`, `IOMAP_ATOMIC`, `IOMAP_DONTCACHE` (drop page cache after I/O, for `RWF_DONTCACHE`).
- Direct I/O flags: `IOMAP_DIO_FORCE_WAIT`, `IOMAP_DIO_OVERWRITE_ONLY`, `IOMAP_DIO_PARTIAL`.
- `IOMAP_F_BUFFER_HEAD` — lets a filesystem use iomap's buffered write path while still attaching buffer heads, as a transitional aid; expected to stay until every filesystem has left buffer heads, which may be never.

## Interactions with Other Subsystems

- **↑ Userspace**: read/write, `O_DIRECT`, `mmap` write faults, `FIEMAP`, `lseek(SEEK_HOLE/SEEK_DATA)`, `swapon`, `RWF_NOWAIT`/`RWF_ATOMIC`/`RWF_DONTCACHE` all end up in iomap for converted filesystems.
- **→ [[page-cache]] / [[folio]]**: buffered I/O operates on (large) folios and keeps per-block state for them.
- **→ [[bio-layer]]**: iomap builds and submits bios for reads, writeback and direct I/O, and uses ioends to batch completions.
- **→ [[writeback-infrastructure]]**: `iomap_writepages()` is the filesystem's `->writepages` implementation.
- **→ [[get-user-pages-and-pinning]]**: direct I/O pins user pages for the bio lifetime.
- **← Filesystems**: XFS (iomap-only, no buffer heads for data), ext4 and Btrfs (direct I/O since 5.5 and 5.8; ext4 buffered-path conversion in progress), ext2 direct I/O (6.6), gfs2, zonefs, erofs, fuse and others to varying degrees.
- **← [[io-uring-internals]]**: relies on `IOMAP_NOWAIT` so non-blocking submissions don't sleep in the filesystem.

## Design Decisions & Tradeoffs

- **Extents, not blocks.** Asking for the largest contiguous mapping makes the per-call overhead proportional to the number of extents rather than the number of blocks, and gives the filesystem the whole operation size up front for better allocation. The cost is that filesystems whose block mapping is naturally per-block (indirect-block schemes) have to do more work to produce extent answers.
- **Byte ranges and folios, not buffer heads.** Buffer heads duplicate page-cache state per block and assume small, fixed blocks. iomap works on byte ranges and keeps a compact per-block bitmap only when needed, which made large folios and block sizes larger than the page size practical.
- **Data only.** iomap was designed for file data. Dave Chinner: "Iomap was never intended for metadata use." Directories, indirect blocks and journals still need something else, which is the main barrier for older filesystems such as ext2 and minix and part of why buffer heads persist (LSFMM 2024).
- **Revalidation instead of holding the mapping lock.** Dropping the filesystem's mapping lock before touching the page cache avoids lock inversions with folio locks, at the price of the stale-mapping check and retry.
- **XFS-shaped assumptions.** The documentation acknowledges "strong assumptions that IO should work the way it does on XFS". fscrypt, compression and (until recently) fs-verity weren't supported, and Btrfs's buffered path has behaviour that doesn't fit, so Btrfs uses iomap only for direct I/O.

## How It Has Evolved

- **XFS origins** — Dave Chinner's internal XFS mapping code, also used to hand extent data to pNFS clients.
- **4.8 (2016)** — Christoph Hellwig hoisted it into the VFS as generic iomap: buffered write helpers, fiemap, DAX.
- **4.x–5.x** — direct I/O moved into iomap (XFS first), then SEEK_HOLE/DATA, swapfile, bmap; XFS dropped buffer heads for data. ext4 (5.5) and Btrfs (5.8) switched direct I/O to iomap.
- **5.15** — `iomap_iter()` replaced the `iomap_apply()`/actor model.
- **5.18** — large folios in the page cache used first by XFS through iomap.
- **6.5–6.6** — `iomap_page` renamed `iomap_folio_state`; per-block dirty tracking (Ritesh Harjani) so a small write to a large folio no longer writes back the whole folio.
- **6.6** — ext2 direct I/O via iomap.
- **6.11** — comprehensive iomap documentation (Darrick Wong); block size > page size support work lands for XFS.
- **Recent** — atomic writes (`IOMAP_ATOMIC`), `RWF_DONTCACHE`, fs-verity and T10 PI support, reworked read and writeback operation tables, readahead improvements, ext4 buffered I/O conversion with large folios in progress, and iomap support for FUSE servers. Planned work includes further iterator-based API changes and direct I/O performance.

## Further Reading

1. [The kernel's iomap layer — LWN](https://lwn.net/Articles/1079415/)
2. [Filesystems and iomap — LWN (LSFMM 2024)](https://lwn.net/Articles/974958/)
3. [Sunsetting buffer heads — LWN (2023)](https://lwn.net/Articles/931809/)
4. [ext4: use iomap for regular file's buffered IO path and enable large folio — LWN](https://lwn.net/Articles/969359/)
5. [iomap design — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/iomap/design.html)
6. [iomap operations — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/iomap/operations.html)
7. [KernelProjects/iomap — kernelnewbies](https://kernelnewbies.org/KernelProjects/iomap)
8. [Upcoming XFS work in 4.8/4.9/4.10 — Darrick Wong, Oracle blog](https://blogs.oracle.com/linux/upcoming-xfs-work-in-linux-v48-v49-and-v410-by-darrick-wong)

## LKML Highlights

> lore.kernel.org was unreachable (TLS certificate error) during this session; these are summarised from LWN coverage.

- **LSFMM 2024 "Filesystems and iomap"** — Dave Chinner argued iomap should stay data-only and buffer heads be replaced separately; Matthew Wilcox called unifying the page cache and buffer cache "a mistake"; Ritesh Harjani agreed to explore iomap for ext2's metadata paths.
- **"ext4: use iomap for regular file's buffered IO path and enable large folio" (Zhang Yi, 2024)** — added an extent-status sequence counter for mapping revalidation and showed higher IOPS and bandwidth with iomap plus large folios than with buffer heads.
- **Sunsetting buffer heads (LSFMM 2023)** — consensus to convert buffer heads to use folios internally with minimal filesystem-visible change, while filesystems keep migrating data paths to iomap.
