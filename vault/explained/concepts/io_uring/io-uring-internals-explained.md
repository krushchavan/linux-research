---
title: "io_uring Internals — Explained"
category: explained
original: "[[io-uring-internals]]"
subsystem: io_uring
tags: [explained, io_uring, async-io, ring-buffer]
converted: 2026-09-25
---

# io_uring internals, explained

> Plain-language companion to [[io-uring-internals|the technical note]]. Same facts, fewer identifiers.

## The problem

Before io_uring, "asynchronous I/O" on Linux was a broken promise. The POSIX interface either worked only for direct disk I/O that bypasses the page cache, or was quietly implemented as a thread pool in user space. And the older kernel AIO interface still needed one system call to submit and another to collect results.

System-call overhead sounds small, but above roughly 500,000 operations per second it becomes measurable on its own. What was needed was a truly kernel-backed asynchronous interface that works the same way for files, sockets and pipes, and that doesn't need a system call per operation.

## The idea in one paragraph

Decouple submission from completion completely, and do both through shared memory. Picture a **two-lane highway** between the application and the kernel. The application drops job tickets into one lane and drives off without waiting. The kernel picks them up, does the work, and drops result slips into the other lane. No tollbooth (system call) is needed unless a lane is congested or one side has to wait for the other.

## Step by step

### Step 1: Set up the rings
One setup call creates the ring and returns a file descriptor that stands for the whole thing. The kernel allocates three memory regions:
- a **submission ring** with head and tail counters, flags, and a list of indexes into the request array
- the **request array** itself, holding the actual job descriptions
- a **completion ring** with head and tail counters and the result entries inline

The application maps all three into its own memory. After that, setup is never needed again. The kernel keeps one central object per ring that anchors everything: the ring memory, the helper-thread pool, registered files and buffers, the polling thread and the locks. It lives as long as the file descriptor does.

### Step 2: Fill in a request
Each request is a 64-byte entry, exactly one cache line. The important parts are:
- which **operation** (read, send, accept...)
- some **flags** (use a registered file, link to the next request, let the kernel pick a buffer)
- the **file descriptor**, or a slot number in a registered-file table
- the buffer address, length and file offset
- a 64-bit **tag** chosen by the application, copied unchanged into the matching result so the two can be paired up

### Step 3: Publish it
The application moves the submission ring's tail forward with a memory-ordering barrier (a "release" store). That barrier is the whole act of submission. The kernel learns about it one of two ways:
- **Normally**, the application makes one system call saying "I've added N entries". The kernel walks from where it last stopped to the new tail.
- **With a polling thread**, a dedicated kernel thread watches the ring in a loop and picks entries up with no system call at all. After a configurable idle period it sleeps and sets a "wake me" flag, and the application makes one call to wake it.

The request array is kept separate from the index list the kernel reads. That lets the application fill several entries at its own pace, then publish them all by moving the tail once.

### Step 4: Turn each entry into an in-kernel request
For each new entry the kernel allocates an in-flight request object from a fast allocator, copies the operation and flags, resolves the file, and **snapshots the submitter's credentials**. That snapshot matters later: if the work ends up on a helper thread, permission checks must still be made as the submitter, not as the thread.

### Step 5: Try it right away, without blocking
The kernel calls the operation's handler with a "do not block" flag. If the operation can finish immediately (the data is in the page cache, the socket already has data, the filesystem honours non-blocking requests), it does, and the result is posted straight away. Still no extra system call.

This is the key step. Most requests in a well-tuned system finish here, costing little more than a function call.

### Step 6: The slow path: hand it to a helper thread
If the handler says "this would block" (a cache miss, direct disk I/O latency, a contended filesystem lock), the request goes to **io-wq**, a pool of helper threads for this ring that grows with demand. A worker runs the handler again, this time *allowed* to sleep on page faults, disk completions or locks. Around the call it temporarily adopts the submitter's credentials, so the filesystem and block layer see the right permissions.

(Pollable files like sockets usually take a different route, parking on the file's wait queue instead of using a thread. See [[io-uring-async-poll-and-multishot-explained|async poll and multishot]].)

### Step 7: Post the result
Whichever path finishes the request writes a 16-byte result entry: the application's tag, the result (bytes transferred or an error code), and flags such as "more results coming". Then it moves the completion ring's tail forward with a release barrier.

### Step 8: The application collects results
The application reads the completion ring's tail with a matching "acquire" read, processes any new entries, and moves the head forward to free the slots. No system call and no lock. If it has nothing to do until results arrive, it makes one call that sleeps until at least N completions are ready.

### Step 9: When the completion ring fills up
If the application falls behind and the completion ring is full, newer kernels hold the extra results in an internal overflow list and deliver them later. Older kernels dropped them and bumped a counter. The practical defence is to make the completion ring larger than the submission ring and keep up with collecting.

### Step 10: Teardown
When the last reference to the ring's file descriptor goes away (close or process exit), the kernel tears down the whole context: rings, threads and registered resources.

## The picture

```text
  APPLICATION                                    KERNEL
  ───────────                                    ──────
  fill 64-byte entry ─┐
  fill 64-byte entry ─┤
  move SQ tail (release) ──▶ submission ring ──▶ (system call or polling thread)
                                                     │ build request, snapshot creds
                                                     ▼
                                          try now, "do not block"
                                           │ done          │ would block
                                           │               ▼
                                           │        helper thread (io-wq),
                                           │        may sleep, uses submitter's creds
                                           ▼               │
  read CQ tail (acquire) ◀── completion ring ◀── post 16-byte result, move tail
  process, move head      (tag, result, flags)
```

## Tradeoffs

- **What it gives you:** steady-state I/O with no system call per operation, results in any order, and one interface for files, sockets and pipes.
- **What it costs / requires:** a one-time memory mapping, careful memory ordering on both sides, and a kernel-side thread pool that can pile up under load (a cap on worker count was added for that). Snapshotting credentials costs a little on every submission.
- **Where it bites:** seccomp filters cannot see the individual operations, only the ring. Android 12+ and ChromeOS block io_uring setup in their sandboxes. Per-ring restrictions and the deferred task-work mode are the kernel's mitigations. Also, the operation field is 8 bits, so there can be at most 256 operations. With 50+ in use there is headroom, but the choice kept entries at exactly one cache line.

## How it got here

- **Jan 2019:** Jens Axboe's first RFC. A key debate was one ring versus two. Two won because results finish in a different order than they are submitted.
- **5.1 (May 2019):** merged with no-op, read/write, fixed-buffer I/O, fsync and poll.
- **5.3:** a dedicated per-ring helper-thread pool (io-wq) replaced generic kernel workqueues; the worker-count limit came out of that debate.
- **5.4–5.6:** timeouts, cancellation, linked requests, accept and connect, then a burst of file operations (open, close, stat, rename, splice).
- **5.13–6.0:** multishot poll, accept and receive; provided buffer rings; zero-copy send.
- **6.1–6.2:** deferred task work, where completions run in the submitting thread; and a single-submitter mode that removes the last locks on the submission fast path.

## Related

- Technical version: [[io-uring-internals]]
- [[io_uring-explained|io_uring]]: the subsystem overview
- [[io-uring-async-poll-and-multishot-explained|Async poll and multishot]]
- [[io-wq-explained|io-wq]], [[sqpoll]], [[io-uring-task-work-explained|io-uring-task-work]], [[registered-resources]], [[provided-buffer-rings-explained|provided-buffer-rings]]
- [[seqlocks-and-memory-barriers|Memory barriers]]: the acquire/release ordering the rings rely on
- [[vfs|VFS]], [[block-explained|Block layer]], [[security|Security]]
