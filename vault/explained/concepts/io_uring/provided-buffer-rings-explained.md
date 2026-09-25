---
title: "io_uring Provided Buffer Rings — Explained"
category: explained
original: "[[provided-buffer-rings]]"
subsystem: io_uring
tags: [explained, io_uring, buffers, networking]
converted: 2026-09-25
---

# io_uring provided buffer rings, explained

> Plain-language companion to [[provided-buffer-rings|the technical note]]. Same facts, fewer identifiers.

## The problem

An epoll-style server waits until a socket is readable and only then picks a buffer to read into. A completion-style interface like io_uring normally needs the buffer *when you submit the request*, because you are asking "receive into this memory whenever data arrives".

For a server with 100,000 mostly idle connections, that means 100,000 buffers sitting in pending receives, doing nothing. Memory ends up scaling with the number of connections rather than with the traffic actually flowing.

## The idea in one paragraph

Hand the kernel a shared pool of empty buffers up front, and let it pick one only when data actually arrives. Picture **a shared tray of empty cups**. The application keeps refilling the tray at one end. When a request finally needs a cup, the kernel takes the next one from the other end and says in the completion which cup it filled. Cups are grouped into trays by size or purpose, and each request says which tray to draw from. This late choice is also what makes multishot receive possible.

## Step by step

### Step 1: Register a tray
The application allocates a ring of buffer descriptions (address, length, buffer ID), with a power-of-two number of slots, and registers it under a **group ID**. The ring's only header field, its tail counter, is tucked into a reserved field of the first entry, so the ring needs no separate header and entries stay aligned. The kernel records the group so requests can find it by ID.

Since 6.4 the kernel can allocate the ring memory itself and the application maps it. That avoids pinning user memory.

### Step 2: Fill the tray
To add buffers, the application writes entries at the tail and then publishes them by moving the tail forward with a memory-ordering "release" store. No system call. The kernel keeps its own private head counter, so the tail is the only shared value that changes. There is exactly one producer (the application) and one consumer (the kernel).

### Step 3: Submit a request with no buffer
A receive request says "pick a buffer from group G" instead of naming one. At submission it has no memory attached at all.

### Step 4: Pick a buffer when data arrives
This is the key step. Only when the handler is actually about to move data (for example after the socket became readable) does it look at the group, check that the tail is ahead of its head, and take the next entry. The completion is marked "used a buffer" and carries that buffer's ID. The application processes the data and later puts that buffer back in the tray.

### Step 5: Give the buffer back if it wasn't needed
Sometimes a buffer is selected but not used: the receive finds no data after all and goes back to waiting on poll. Holding the buffer while waiting would defeat the whole point. Because the kernel only moves its head forward when a request *completes*, "giving it back" means not moving the head. The next selection picks the same entry again.

### Step 6: Running dry is deliberate backpressure
If the tray is empty when the kernel needs a buffer, the request completes with "no buffers". For a multishot receive, that ends the request. The application must refill the tray and re-arm. The kernel refuses to queue unlimited data on the application's behalf. Since 6.8 the application can ask how far the kernel's head has advanced.

### Step 7: Bundles, for buffers that are too small (6.10)
With small buffers, a busy socket might need several for one receive. A "bundle" receive takes a run of consecutive buffers, fills them in order, and posts one completion with the first buffer ID and the total bytes. The application walks forward from that ID. Sends can use bundles too, transmitting a sequence of buffers from one request.

### Step 8: Incremental use, for buffers that are too big (6.12)
The opposite problem: buffers of, say, 64 KiB, but small messages. In incremental mode a buffer isn't retired after one use. The kernel remembers how far into it it has written and hands out the remainder next time. Several completions can then refer to the same buffer ID, with a flag saying "the kernel still owns the rest of this buffer". Memory use improves a lot, and applications can register fewer, larger buffers.

### Step 9: The older scheme
The first design (5.7) supplied buffers with a special request, storing them on a linked list. Refilling meant submitting more requests, and every selection took list locks. It still works but is discouraged.

## The picture

```text
          application refills here                kernel takes from here
                   │ (tail)                               │ (head, private)
                   ▼                                      ▼
   ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
   │ buf │ buf │ buf │     │     │ buf │ buf │ buf │   one group (tray)
   └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
                                                  │
 receive request: "use group G" (no buffer yet)   │ data arrives → take next
                                                  ▼
               completion: "N bytes, in buffer ID 7"
                                                  │
     app processes data ──▶ puts buffer 7 back at the tail
     tray empty?  → "no buffers" → multishot stops; refill and re-arm
```

## Tradeoffs

- **What it gives you:** memory proportional to active traffic, not to connection count; refilling with no system call and no lock; and the foundation for multishot receive.
- **What it costs / requires:** the application must keep the tray stocked, and the shared layout (tail tucked into the first entry) is a tricky interface.
- **Where it bites:** if the tray runs dry, multishot receives stop and must be re-armed, and forgetting to handle that silently stalls connections. Committing buffers only at completion keeps the rules simple: a buffer is consumed only when a completion says so.

## How it got here

- **5.7:** the list-based scheme, supplied through requests.
- **5.19:** the shared-ring design, in time for multishot accept and receive (multishot receive followed in 6.0).
- **6.4–6.8:** kernel-allocated ring memory, multishot read, and a way to query the kernel's position.
- **6.10–6.12:** bundles for too-small buffers, incremental use for too-big ones. Both are opt-in, so existing users see no change.
- **2026 (posted, not confirmed merged):** kernel-managed buffer rings for FUSE over io_uring, enabling zero-copy between the FUSE server and the page cache, with a reported 20–25% gain in buffered-read throughput.

## Related

- Technical version: [[provided-buffer-rings]]
- [[io_uring-explained|io_uring]]: the subsystem overview
- [[io-uring-async-poll-and-multishot-explained|Async poll and multishot]]: multishot receive requires provided buffers
- [[registered-resources-explained|registered-resources]]: the other way to prepare buffers in advance
- [[fuse|FUSE]]: driving kernel-managed buffer rings
- [[net|Networking]], [[vfs|VFS]]
