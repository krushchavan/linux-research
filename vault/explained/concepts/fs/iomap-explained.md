---
title: "iomap — Explained"
category: explained
original: "[[iomap]]"
subsystem: fs
tags: [explained, fs, iomap, page-cache, direct-io]
converted: 2026-09-25
---

# iomap, explained

> Plain-language companion to [[iomap|the technical note]]. Same facts, fewer identifiers.

## The problem

Every filesystem keeps answering one question: "for this byte range of this file, where does the data live, and is it allocated, reserved, not yet written, or a hole?" Traditionally each filesystem answered it **one block at a time**, through structures called buffer heads, and then each built its own buffered I/O, direct I/O, extent reporting, hole seeking and swapfile support on top. That meant lots of duplicated code, per-block overhead, and a design stuck on small fixed blocks just as the page cache moved to large folios.

## The idea in one paragraph

iomap is a shared library for filesystems that works like a **tour guide with a map-reading assistant**. The guide (iomap's generic code) knows how to run any tour: read into the page cache, write through it, do direct I/O, report extents. It doesn't know the terrain, so for each leg it asks the assistant (the filesystem), "from here, how far does this stretch go, and what's it like?" The filesystem answers with **one contiguous stretch**, perhaps "the next 8 MB are on disk at address X" or "the next 64 KB are a hole", and the guide handles that whole stretch at once before asking about the next. With buffer heads, the guide had to ask about every step.

## Step by step

### Step 1: The loop
Every iomap operation is the same loop. The generic code tracks the file, the current position, what's left and what kind of operation this is (write, zero, direct, DAX, fault, don't-wait…). Each round it calls the filesystem's **begin** callback, which returns one mapping starting at the current position, possibly shorter than asked. iomap does the work for that range, then calls the filesystem's **end** callback with how many bytes were actually handled, so the filesystem can release reservations it didn't need (after a short write, for example). Then it moves on. Since 5.15 this is written as an iterator; before, it was a callback-driven "apply" function.

### Step 2: What a mapping says
A mapping gives a file range, where the data lives (a disk address, device memory, or an in-memory buffer) and its **type**:
- **hole:** nothing allocated; reads return zeros, and it's never valid for writes
- **delayed allocation:** space reserved but not yet placed on disk
- **mapped:** real space on the device
- **unwritten:** allocated but never written; reads return zeros, and a write must convert it later
- **inline:** the data lives in memory, for example inside the inode

Flags add detail: freshly allocated (partial blocks need zeroing), metadata not yet committed (matters for data-sync), shared (needs copy-on-write), or stale (look it up again). A **validity cookie** lets the filesystem tell later whether the mapping has changed.

### Step 3: Copy-on-write
For writes to extents shared with another file (reflinks), the filesystem returns **two** mappings: where the new data goes (a fresh private allocation) and where the old data must be read from (the shared extent). A partial-block write can read the old contents, merge, and write the result to the new place. That's how XFS reflinks work through the shared code.

### Step 4: Locking in layers
The caller holds the usual VFS locks (the inode lock, folio locks for faults) for the whole operation. The filesystem takes its **own** mapping lock only inside the begin callback, long enough to read the mapping, then drops it. iomap has its own locks for folio state. Because the mapping lock is dropped before the page cache is touched, the mapping can change underneath, which is why Step 6 exists.

### Step 5: Reading
Reads fill the page cache directly from mappings: zero-fill holes and unwritten ranges, copy inline data, or build block I/O straight into the folios, covering as much of a large folio as one mapping allows. Extra per-folio state is kept **only** when a folio holds several filesystem blocks: then iomap tracks up-to-date and dirty bits per block, so partly read or partly written large folios work correctly.

### Step 6: Writing, and noticing stale maps
This is the key step. A buffered write asks for a mapping covering as much of the write as possible (often reserving delayed allocation for the whole range in one go), then, folio by folio, locks the folio, reads in any partial blocks that must be kept, copies the user data in and marks blocks dirty. But between getting the mapping and locking the folio, writeback or truncation may have changed the file's extents, say by turning a reservation into real blocks. Trusting the old mapping could corrupt data. So after locking each folio, iomap asks the filesystem whether the mapping is still valid, comparing the cookie with the filesystem's current change counter (XFS keeps one per inode; ext4's conversion added one). If not, iomap drops the stale mapping and asks for a fresh one. Page-fault writes follow the same path.

### Step 7: Cleaning up failed writes
If a write copies less than expected (a fault on the user buffer, say), delayed-allocation space may be reserved for bytes that never got dirty. iomap walks the unused range and asks the filesystem to **punch out** those reservations, so no reserved-but-empty space is later written as garbage.

### Step 8: Writeback
When dirty folios are written back, the filesystem maps each dirty range, turning delayed allocations into real extents at this point, and iomap reuses a mapping across contiguous dirty blocks. Delayed or inline mappings are rejected here, since everything must have real space by now. Ranges go into block I/O wrapped in completion records; adjacent records are merged and sorted, so after-I/O work like converting unwritten extents or finishing copy-on-write happens once for a big range instead of once per I/O.

### Step 9: Direct I/O and the rest
Direct I/O bypasses the page cache: flush and drop any cached pages in the range, then build I/O straight from the user's pinned buffer, mapping by mapping. Writes into unwritten or copy-on-write extents are flagged so the filesystem converts or remaps them **after** the data is safely on disk. Options cover waiting even for async requests, allowing only pure overwrites (else "try again", enabling a lighter-locking first attempt), returning partial progress when a page fault interrupts, falling back to buffered I/O, and atomic (untearable) writes. The same loop also drives DAX for persistent memory, extent reports, hole and data seeking, partial-block zeroing on truncate, unsharing reflinked extents and swapfile activation, each a short function on top of the loop.

## The picture

```text
 iomap operation (write 1 MB at offset 0)
   loop:
     begin(pos 0, len 1 MB) ─▶ filesystem: "0–256 KB MAPPED at disk X" (+ cookie)
         for each folio: lock → still valid? (cookie) ─ no → ask again
                         copy data, mark blocks dirty
     end(pos 0, written 256 KB) ─▶ filesystem releases unused reservations
     begin(pos 256 KB, …) ─▶ "256 KB–1 MB DELALLOC" …
 later, writeback: map dirty ranges → real extents → merged completions
```

## Tradeoffs

- **What it gives you:** a large amount of shared code instead of per-filesystem copies; per-call overhead proportional to extents, not blocks; the whole operation size known up front for better allocation; large-folio and larger-than-page block support.
- **What it costs / requires:** filesystems with naturally per-block mapping (indirect-block designs) must work harder to produce extent answers; the stale-mapping check and retry is the price of not holding the mapping lock during page-cache work.
- **Where it bites:** iomap is for **file data only**; as Dave Chinner put it, "Iomap was never intended for metadata use." Directories, indirect blocks and journals still need something else, which keeps buffer heads alive in older filesystems like ext2 and minix. The code also assumes I/O "should work the way it does on XFS": fscrypt, compression and (until recently) fs-verity weren't supported, and Btrfs uses iomap only for direct I/O.

## How it got here

- **Origins:** Dave Chinner's internal XFS mapping code, also used to hand extents to pNFS clients.
- **4.8 (2016):** Christoph Hellwig made it a generic VFS library.
- **4.x–5.x:** direct I/O, hole seeking and swapfile support moved in; XFS dropped buffer heads for data; ext4 (5.5) and Btrfs (5.8) adopted it for direct I/O.
- **5.15:** the iterator form. **5.18:** large folios, first used by XFS.
- **6.5–6.6:** per-block dirty tracking (Ritesh Harjani), so a small write to a large folio no longer writes back the whole folio; ext2 direct I/O.
- **6.11:** full documentation (Darrick Wong); larger-than-page block sizes for XFS.
- **Recent:** atomic writes, drop-behind I/O, fs-verity and integrity metadata, ext4 buffered I/O conversion with large folios, and support for FUSE servers.

## Related

- Technical version: [[iomap]]
- [[page-cache-explained|Page cache]], [[folio-explained|Folio]], [[bio-layer-explained|bio layer]], [[writeback-infrastructure-explained|Writeback]], [[get-user-pages-and-pinning-explained|Page pinning]], [[io-uring-internals-explained|io_uring internals]]
- [[vfs-explained|VFS]], [[fs-explained|Filesystems]]
