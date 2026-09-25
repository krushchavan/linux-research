---
title: "io_uring — Explained"
category: explained
original: "[[io_uring]]"
subsystem: io_uring
tags: [explained, io_uring, async-io, ring-buffer, zero-copy]
converted: 2026-09-25
---

# io_uring, explained

> Plain-language companion to [[io_uring|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

A classic Unix program does I/O one system call at a time, and each call either finishes or puts the thread to sleep until it can. A server juggling thousands of files and sockets then has two bad options: one thread per connection (lots of memory and context switches), or a readiness loop like epoll that still pays one system call per read or write.

Linux had an older asynchronous I/O interface (AIO), but it only really worked for direct disk I/O and still cost a system call per batch. io_uring, merged in 5.1 (2019), was built as a faster replacement. It has since grown into a parallel system-call interface: well over 50 kinds of operation covering files, sockets, filesystem metadata, futexes, waiting for processes and driver-specific commands, plus zero-copy networking, kernel-managed buffer pools and, since 7.1, event loops driven by BPF programs.

The hard part is that the kernel was written around blocking calls. Most operations *might* sleep: on a disk read, a lock, or a socket with no data. io_uring has to run all of them asynchronously without rewriting the whole kernel.

## The big picture

Think of io_uring as **a dispatcher sitting in front of the whole kernel**. The application drops work orders into a mailbox in shared memory. The dispatcher first tries each job on the spot in a way that is not allowed to block. If the job would block, the dispatcher picks the cheapest way to wait:

- **Park it on the file's own wait queue** and retry when the file is ready (*async poll*), for sockets and pipes.
- **Hand it to a helper thread** that is allowed to sleep (*io-wq*), for things that must block.
- **Let the device finish it** and bounce the result back to the application's thread (*task work*).

Every other feature (pre-registered files and buffers, a kernel polling thread, multishot requests, zero-copy) exists to make one of those paths cheaper.

```text
   application
      │ writes requests                          reads results ▲
      ▼                                                        │
 ┌──────────────┐   system call or         ┌──────────────┐    │
 │ submission   │── polling thread ──▶ ... │ completion   │────┘
 │ ring (shared)│                          │ ring (shared)│
 └──────────────┘                          └──────▲───────┘
         │                                        │
         ▼                                        │
   try it now, non-blocking ── success ───────────┤
         │ would block                            │
   ┌─────┼────────────────┬───────────────┐       │
   ▼     ▼                ▼               ▼       │
 pollable file?     must sleep?     device does it│
 wait on its        helper thread   (disk, NVMe)  │
 wait queue         (io-wq)             │         │
   │ ready               │              │         │
   └──▶ task work: retry or finish in the app's thread ──┘
```

## The pieces

### The rings and the request lifecycle

The interface itself is two ring buffers in memory shared by the application and the kernel. See [[io-uring-internals]].

1. The application writes fixed-size (64-byte) request entries into the **submission queue** and moves its tail forward.
2. One system call (or the polling thread, below) tells the kernel to walk the new entries. Each becomes an in-kernel request object, with its file resolved and credentials recorded.
3. A per-operation table says how to validate and perform each kind of request and which fallback paths it supports. Chains of linked requests, "drain" barriers and timeouts are handled centrally, not per operation.
4. Results come back as entries on the **completion queue**, in whatever order they finish. The application reads them with no system call at all.

A system-wide switch (6.6) can allow io_uring for everyone, only for one group, or for nobody.

### Helper threads (io-wq)

Some operations have to block: buffered writes that wait on a file's lock, fsync, many file opens. See [[io-wq]].

1. When the non-blocking attempt fails and the file cannot be polled, the request goes to a pool of helper threads owned by the submitting process.
2. Work is split into two classes. **Bound** work (regular files, block devices) has finite latency and a modest worker cap. **Unbound** work (sockets, pipes, anything that may wait forever) is capped by the process's thread limit. That way a pile of stuck network requests can't starve disk I/O of workers.
3. Buffered writes to the same file are serialized onto one worker, so a crowd of workers don't all queue on the same lock.
4. Since 5.12 these workers are real threads of the submitting process, sharing its memory, open files and credentials. Before that they were kernel threads that had to borrow those by hand, and every missed resource was a potential privilege bug.

### The polling thread (SQPOLL)

Even one batched system call is a system call. See [[sqpoll]].

1. The application can ask for a dedicated kernel thread that watches the submission ring and picks up new requests itself. Steady-state submission then costs only a memory write.
2. If nothing arrives for a configured idle time, the thread sets a "wake me" flag in shared memory and sleeps. The application then makes one system call to wake it.
3. The thread runs with its creator's credentials, so it can't do anything the process couldn't. That is why it stopped requiring privileges in 5.11.

### Task work: finishing in the right place

Completions are often detected in the wrong place: an interrupt handler, or a callback run by whoever woke a wait queue. io_uring wants to finish them in the submitting thread, where it can touch that process's memory and the ring without heavy locking. See [[io-uring-task-work]].

1. The finished request is put on a lock-free list and the owning thread is notified.
2. By default the notification can interrupt the thread (even with a cross-CPU interrupt) and force it out of user space. That is expensive for busy servers.
3. A "cooperative" mode (5.19) waits until the thread enters the kernel naturally instead.
4. A "deferred" mode (6.1, requires that only one thread ever submits) runs the work *only* when the application asks for completions. The application decides when it gets interrupted, and hundreds of completions can be posted in one batch.

### Registered files and buffers

Every ordinary I/O pays to look up the file descriptor and, for user memory, to find and pin the pages. Registering them once up front removes that per-request cost. See [[registered-resources]].

1. The application registers a table of files. Requests then name a slot number instead of a descriptor. Since 5.15, opening a file or accepting a connection can put the result straight into a slot, without ever creating a normal descriptor.
2. Registered buffers have their pages pinned once and recorded as a ready-made list of physical pages. Reads, writes, sends and driver commands can use them directly.
3. Each slot has its own reference count, so it can be replaced while older requests still use the old contents.
4. Since 6.15 drivers such as ublk can put *kernel* memory into a slot, which is how ublk gets zero-copy. Pinned memory counts against the locked-memory limit.

### Provided buffer rings

A server with 10,000 idle sockets would waste a lot of memory if every pending receive had its own buffer. See [[provided-buffer-rings]].

1. The application registers a *buffer group*: a ring of buffer descriptions it fills and the kernel consumes (5.19).
2. A receive request says "pick a buffer from group G" instead of naming one. The kernel chooses a buffer only when data actually arrives, and the completion says which buffer it used.
3. If the ring is empty the request fails with "no buffers", which also ends a multishot request.
4. Later refinements: one completion covering several buffers ("bundles"), and a large buffer consumed a piece at a time across completions (6.12).

### Async poll and multishot

Sending a socket read to a helper thread that then sleeps would recreate thread-per-connection. See [[io-uring-async-poll-and-multishot]].

1. If a non-blocking attempt on a pollable file fails, io_uring hooks the request onto that file's wait queue, the same one epoll would use.
2. When the socket becomes readable, the wake-up callback claims the request and queues task work, which retries it in the submitting thread.
3. A **multishot** request does not disarm after succeeding. It posts a completion flagged "more coming" and re-arms, until an error, running out of buffers, end of file or cancellation posts a final completion without that flag.
4. The same machinery gives multishot accept (5.19), receive (6.0), read (6.7) and timeouts (6.4).

### Driver passthrough commands

Generic operations can't express every driver's native command set. See [[uring-cmd-passthrough]].

1. A file can accept its own commands through io_uring. The request carries a command code and a small inline payload (up to 80 bytes with double-size entries).
2. The driver completes it immediately or later, usually finishing in the submitter's thread via task work.
3. The first user (5.19) was raw NVMe commands. Since then: ublk, the user-space block driver (6.0); socket commands (6.7); FUSE over io_uring (6.14); btrfs encoded reads; block-device discard.
4. Because passthrough skips the permission checks of the generic paths, a dedicated security hook (6.0) lets security modules police it.

### Zero-copy networking

At 100–400 Gbit/s, copying between socket buffers and user memory dominates CPU cost. See [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]].

1. **Send (6.0):** your pages are attached to outgoing packets instead of copied. You get one completion when the data is queued and a second when the network stack releases your pages.
2. **Receive (6.15):** one hardware receive queue is dedicated to your flows, and the card writes payloads straight into memory you registered. Completions tell you where the data landed, and you hand chunks back through a refill ring.

## A request's journey

A buffered read that misses the page cache:

1. **The application submits.** It writes a read request into the submission ring and makes one system call to submit it.
2. **The kernel tries it without blocking.** The data isn't in memory. On filesystems that support asynchronous buffered reads (5.9+), the read starts readahead and, instead of sleeping until the page is unlocked, registers a callback and returns "queued".
3. **The disk finishes.** When the block I/O completes and the page is unlocked, the callback fires and queues task work for the submitting thread.
4. **Retry in the right thread.** Next time the thread enters the kernel (or right away if it is waiting for completions), the task work retries the read, which now finds the data in the cache.
5. **Completion posted.** The result goes onto the completion ring, often in a batch with others. No helper thread was involved. On a filesystem without asynchronous buffered reads, step 2 would have handed the read to an io-wq bound worker instead.

A TCP server follows a similar pattern: one multishot accept puts each new connection straight into a registered file slot, one multishot receive per connection picks buffers from a provided-buffer ring as data arrives, async poll avoids helper threads, and deferred task work batches the completions.

## Tradeoffs

- **What it gives you:** batching, no system call per operation, true asynchrony for almost anything, and one event loop that can handle files, sockets, timers, futexes and device commands together.
- **What it costs / requires:** every operation must cope with "would block" and be safe to retry, which has been a major source of subtle bugs. Waiting on wait queues brings hard ownership and cancellation races, a steady source of CVEs. It is one of the largest and most security-sensitive system-call surfaces in the kernel.
- **Where it bites:** seccomp filters only see "enter the ring", not the individual operations. io_uring offers its own controls instead (per-ring restrictions in 5.10, the system-wide switch in 6.6, security-module hooks, and a proposed per-task restriction in 2026). Many sandboxes (Android, ChromeOS, Docker's default profile, Google's production fleet) still turn io_uring off entirely because of its CVE history.

## How it got here

- **5.1 (2019):** merged with read, write, fsync and poll. Helper threads (io-wq) arrived in 5.3.
- **5.7:** async poll for pollable files. Before this, every blocking socket operation went to a worker thread and scaled no better than thread-per-connection.
- **5.12:** helper and polling threads become real threads of the submitting process, closing a class of privilege bugs.
- **5.19–6.1:** driver passthrough with NVMe, provided buffer rings, multishot accept and receive, zero-copy send, cooperative and deferred task work. The code moved into its own top-level directory.
- **6.6–6.16:** the system-wide disable switch, futex and wait operations, FUSE over io_uring, zero-copy receive, and kernel-buffer registration for ublk zero-copy.
- **7.1 (2026):** BPF programs can drive the event loop. Still in discussion (Sep 2026): per-task restrictions, and a proposal to swap thread identities with a worker only at the moment a request would actually block.

## Related

- Technical version: [[io_uring]]
- [[io-uring-internals]]: the rings and request lifecycle in detail
- [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]]
- [[block-explained|Block layer]] and [[blk-mq-explained|blk-mq]]: where direct and passthrough I/O goes
- [[bpf-explained|BPF]]: now able to drive io_uring event loops
- [[vfs|VFS]], [[net|Networking]], [[page-pool|Page pool]], [[get-user-pages-and-pinning|Page pinning]]
- [[ublk|ublk]], [[fuse|FUSE]], [[seccomp-bpf|seccomp]]
