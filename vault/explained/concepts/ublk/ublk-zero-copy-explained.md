---
title: "ublk Zero-Copy — Explained"
category: explained
original: "[[ublk-zero-copy]]"
subsystem: ublk
tags: [explained, ublk, zero-copy, io_uring, registered-buffers]
converted: 2026-09-25
---

# ublk zero-copy, explained

> Plain-language companion to [[ublk-zero-copy|the technical note]]. Same facts, fewer identifiers.

## The problem

In ublk's default mode, every byte crosses the user/kernel boundary twice. For a write, the data is copied from the client's request pages into the server's buffer, and then the server writes it again to its backend (a file, a socket). Reads do the reverse.

For large I/O, that copy is the main thing that makes ublk slower than an in-kernel driver. The fix is to let the server's backend I/O work *directly on the client's pages*. But handing a user-space process direct access to another program's pages raises safety questions, and finding a clean way to do it took three years.

## The idea in one paragraph

In copy mode, the server gets a photocopy of the parcel. **Registered-buffer zero-copy** gives the server **a claim ticket for the original parcel**: the kernel puts the client request's pages into the server's io_uring buffer table, and the server hands that ticket to a fixed-buffer read, write or send, without ever opening the parcel. **Shared-memory zero-copy** is different: client and server agreed beforehand to **use the same warehouse shelf** (shared memory), so the kernel only has to say which shelf position the data is on.

## Step by step

### Step 1: Where it started: copy mode
The driver walks the request's pages and copies each to or from the server's buffer address. Simple and safe, at the cost of one memory copy per byte.

### Step 2: Copy on demand (~6.5)
Instead of giving a buffer up front, the server reads or writes its device channel at an offset that encodes (queue, tag, byte offset). The kernel copies only the requested range. It's still a copy, but the server decides when, how much and into what. That helps servers that transform data (compression, encryption) or split one request into several backend operations. It was the stopgap while real zero-copy was debated, and it's also the path used for integrity metadata (7.0).

### Step 3: The detour (2023–2025)
Three designs competed:
- a BPF program type that would issue backend I/O from inside the kernel (Xiaoguang Wang, Alibaba)
- "fused" io_uring commands, where one command lent its request buffer to a linked second one (Ming Lei). Merged for 6.4, then pulled because io_uring's maintainers found it too intrusive and special-purpose.
- splicing into a registered buffer (Pavel Begunkov), never completed

Keith Busch's 2025 series won by making kernel-owned pages look exactly like ordinary registered buffers.

### Step 4: Registered-buffer zero-copy (6.15)
This is the key step. When the server gets a request, it picks a free slot in a *sparse* registered-buffer table of one of its io_uring rings (not necessarily the ring carrying ublk commands) and asks ublk to register the request's buffer there. ublk takes a reference on the request and installs its pages into that slot, with a callback for when the last user lets go.

Now the server can use that slot in any fixed-buffer operation: a fixed write to its backing file, a zero-copy network send, a passthrough command. Data moves straight between the client's pages and the backend. When done, the server unregisters it. The request can't complete until every registration is gone.

Because a server could otherwise expose uninitialised client memory, or read pages it shouldn't, this mode needs admin rights, and the server must report accurate result lengths.

### Step 5: Automatic registration (6.16)
Registering and unregistering cost two extra commands per I/O, and they have to be ordered correctly. With automatic registration, the server puts a slot index in its fetch or commit command. During dispatch, the kernel registers the request buffer at that index on the *same* ring before telling the server about the request, and commit unregisters it.

If registration fails (slot busy, or the table is full at 16K entries), the server can ask to be told instead of having the I/O fail, and fall back. Auto-registered buffers are counted with a cheap per-thread counter rather than atomic operations.

### Step 6: Registering from any thread (6.17)
Registration was originally allowed only from the slot's owning thread. An option now lets any thread do it, using an atomic reference count; at completion the per-thread count is folded in, so both kinds drain correctly.

### Step 7: Shared-memory zero-copy (2026)
Some deployments control both ends, for example a database talking to a ublk device served by a sidecar. Both map the same shared memory file (a memfd or hugetlbfs file). The server registers that memory; the kernel pins it and indexes its physical pages in a lookup tree.

When a client's direct I/O arrives, the kernel checks whether all its pages sit contiguously inside one registered buffer. If so, it marks the request and puts (buffer index, offset) in the descriptor. The server reads the data through its own mapping: no copy and no per-I/O registration. Anything that doesn't match silently falls back to copying. It requires client cooperation, direct I/O, and pages contiguous within one buffer.

## The picture

```text
 COPY MODE                      REGISTERED-BUFFER ZERO-COPY
 client pages                   client pages ◀── "claim ticket" in slot 5
    │ copy                            │           of server's buffer table
    ▼                                 │
 server buffer                  server: fixed write using slot 5
    │ write                           │   (no copy)
    ▼                                 ▼
 backend file                   backend file / socket

 SHARED-MEMORY ZERO-COPY
 client and server both map the same memory file
 client direct I/O ─▶ kernel: pages inside registered buffer 2?
                      yes → descriptor says "buffer 2, offset X" → server reads in place
                      no  → fall back to copy
```

## Tradeoffs

- **What it gives you:** backend I/O straight from or into the client's pages, removing ublk's main overhead. Because kernel buffers behave like user-registered ones, every fixed-buffer operation (file, socket, passthrough) worked immediately, with no new io_uring semantics.
- **What it costs / requires:** admin rights for registered-buffer mode; a sparse buffer table and fixed-buffer operations in the server. Automatic registration saves two commands per I/O but ties the buffer to the command ring and a chosen index.
- **Where it bites:** a buggy server with direct page access can leak stale memory in read replies, which is why the kernel restricts it and makes result lengths the server's responsibility. Shared-memory mode helps only cooperating clients using direct I/O, though it's transparent to everyone else.

## How it got here

- **6.0 (2022):** a zero-copy feature bit reserved in the interface, not implemented.
- **2023:** BPF, fused-command and splice proposals; fused commands merged for 6.4, then reverted.
- **~6.5:** copy on demand, as the interim answer.
- **6.15:** registered-buffer zero-copy via kernel buffers in io_uring (Keith Busch, Meta), shaped by review asking kernel buffers to behave like user-registered ones.
- **6.16–6.17:** automatic registration, then registration from any thread.
- **2026:** shared-memory zero-copy (Ming Lei), with review debating whether descriptors should carry index plus offset or a virtual address.

## Related

- Technical version: [[ublk-zero-copy]]
- [[ublk-explained|ublk]]: the subsystem overview
- [[ublk-io-command-protocol-explained|I/O command protocol]]: where the copies happen in the default mode
- [[registered-resources-explained|Registered resources]]: io_uring's buffer table, now holding kernel pages
- [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]]: zero-copy sends for network-backed devices
- [[uring-cmd-passthrough-explained|Passthrough commands]], [[get-user-pages-and-pinning-explained|Page pinning]], [[maple-tree|Maple tree]], [[huge-pages-hugetlbfs|hugetlbfs]]
