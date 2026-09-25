---
title: "io_uring Registered Resources — Explained"
category: explained
original: "[[registered-resources]]"
subsystem: io_uring
tags: [explained, io_uring, fixed-files, fixed-buffers]
converted: 2026-09-25
---

# io_uring registered resources (fixed files and buffers), explained

> Plain-language companion to [[registered-resources|the technical note]]. Same facts, fewer identifiers.

## The problem

Every ordinary I/O pays two setup taxes before any data moves:

- **The file descriptor** has to be turned into the kernel's open-file object and released again afterwards. That is atomic reference-count traffic on a shared cache line whenever threads share a descriptor table.
- **A user buffer** for direct I/O has to have its pages found and pinned in memory, then unpinned afterwards.

At a million operations per second these taxes are a visible share of CPU time, even though they do the same thing over and over for the same files and buffers.

## The idea in one paragraph

Pay the taxes once, up front. Registration is **checking your bags at the start of a trip**. Instead of producing your luggage and passport at every connection, you hand them over once and get claim tickets (small integer indexes). Every later request shows a ticket. The airline (the kernel) holds the bags, but it can't hand one back while any flight (an in-flight request) still has it on board, so every slot keeps its own count of users. The same tables later became the home for files that never get a normal descriptor, and for buffers supplied by the kernel itself.

## Step by step

### Step 1: Register files
The application hands the kernel a list of file descriptors. The kernel takes a reference on each file and stores it in a per-ring table. (It refuses io_uring's own descriptors, to avoid reference cycles.) A table can also be created empty at a fixed size and filled in later (5.19).

### Step 2: Use a fixed file
A request flagged "fixed file" puts a slot number where the descriptor would go. At issue time the kernel looks up the slot and bumps a counter on the *slot*, a cheap increment under the ring's lock with no atomic traffic on the file itself. The request holds the slot until it completes, so the file can't vanish under it even if the application replaces that slot meanwhile.

### Step 3: Files that never get a descriptor
Since 5.15, operations that create files (open, accept, socket, and later pipe) can put the new file straight into a table slot, or into any free slot with the kernel reporting which one. The file never enters the process's normal descriptor table, so there is no lookup cost and no contention on that table. That matters a lot for accept-heavy servers with many threads. These are called **direct descriptors**. If ordinary code needs a normal descriptor later, one can be installed from a slot (6.8). The ring's own descriptor can be registered too, so entering the ring skips its lookup as well.

### Step 4: Register buffers
For each buffer, the kernel pins the user pages **long-term** and charges them against the user's locked-memory limit. "Long-term" matters: the pages may stay pinned indefinitely, so they must first be moved out of memory zones meant for movable pages. The pinned pages are recorded as a ready-made list of physical page segments. If they come from huge pages, since 6.12 one segment covers a whole huge page, which makes the list much smaller and faster to walk.

Memory backed by a file is refused for most filesystems, because long-term pins on page-cache pages break writeback.

### Step 5: Use a fixed buffer
A request names a buffer index plus an address and length that must fall inside that registered range. The kernel checks the range and builds its I/O description directly from the pinned pages. No per-I/O pinning, and the block layer receives a ready-made list of pages. Since 6.15 vectored reads and writes can use several pieces of one registered buffer.

### Step 6: Replace or remove a slot safely
The application can replace or clear individual slots. The old slot's contents are not freed immediately; they are freed when the last in-flight request using them finishes.

This is where the 6.13 rework mattered. Older kernels grouped slots into "generations" and, on update, sometimes had to wait for every in-flight request of the old generation to finish. That caused latency spikes and deadlock-prone waits. Per-slot counting makes updates constant-time and non-blocking, and removed a lot of code.

### Step 7: Share buffers between rings (6.12)
Registering gigabytes of buffers is slow, dominated by pinning and accounting. That hurt designs where short-lived threads each create their own ring. Cloning copies another ring's buffer table by taking references on the already-pinned buffers. The liburing wiki cites about 17 µs instead of about 1 second for a large table.

### Step 8: Kernel-supplied buffers (6.15)
This is the key step for ublk zero-copy. A driver can put *its own* pages into a ring's buffer table. ublk, the user-space block driver, installs the pages of a block request at an index chosen by its user-space server. The server then issues ordinary fixed-buffer reads and writes against its backing file using that index, so data moves between the block request's pages and the backing storage without ever being copied to user space. A callback tells the driver when the last user is gone. Keith Busch's series settled on this after several earlier designs.

### Step 9: Failure and teardown
Registration fails if the locked-memory limit would be exceeded, the address is bad, or the memory can't be pinned long-term. At issue time a bad index is an error. Indexes are bounds-checked in a way that also blocks speculative out-of-bounds reads (Spectre). When the ring or process goes away, every slot is dropped, and each file is released or its pages unpinned once its last in-flight user finishes.

## The picture

```text
 REGISTRATION (once)                       PER REQUEST (cheap)
 ─────────────────────                     ──────────────────
 fds ──take refs──▶ ┌ file table ┐         "fixed file, slot 3"
                    │ 0 1 2 3 ...│ ◀────── bump slot 3's count (no file atomics)
 open/accept ──────▶│ direct fds │         
                    └────────────┘
 buffers ──pin long-term──▶ ┌ buffer table ─────────┐   "buffer 1, offset, len"
         (charged to        │ 0: page list          │ ◀── check range, build
          memlock limit)    │ 1: page list (huge)   │     I/O from pinned pages
 driver (ublk) ────────────▶│ 2: kernel pages       │
                            └───────────────────────┘
 replace a slot → old contents freed when its last in-flight user finishes
```

## Tradeoffs

- **What it gives you:** no per-request descriptor lookups or page pinning, no descriptor-table contention for direct descriptors, and a path to true zero-copy for drivers like ublk.
- **What it costs / requires:** long-term pinned pages interfere with memory compaction, contiguous-memory allocation, memory hot-unplug and page-cache writeback. That is why pins are counted against the locked-memory limit and most file-backed memory is refused.
- **Where it bites:** direct descriptors are invisible to ordinary system calls and to debugging tools that list a process's open files. Anything outside io_uring needs a normal descriptor installed first.

## How it got here

- **5.1:** buffer and file registration from day one, with fixed-buffer reads and writes.
- **5.13–5.15:** tags that post a completion when a slot is finally freed, updates, and direct descriptors for open and accept.
- **5.18–5.19:** registered ring descriptors, empty pre-sized tables, and kernel-chosen free slots.
- **6.12:** huge-page coalescing and cloning buffer tables across rings.
- **6.13:** per-slot reference counting replaces generation-based quiescing.
- **6.15:** vectored fixed buffers, and kernel-registered pages for ublk zero-copy.

## Related

- Technical version: [[registered-resources]]
- [[io_uring-explained|io_uring]]: the subsystem overview
- [[provided-buffer-rings-explained|Provided buffer rings]]: the other buffer mechanism, chosen late instead of up front
- [[get-user-pages-and-pinning|Page pinning]]: how long-term pins work
- [[ublk|ublk]]: the main user of kernel-registered buffers
- [[uring-cmd-passthrough]]: passthrough commands can use registered buffers
- [[vfs|VFS]], [[block-explained|Block layer]]
