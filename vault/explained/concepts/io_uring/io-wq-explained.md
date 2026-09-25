---
title: "io-wq — Explained"
category: explained
original: "[[io-wq]]"
subsystem: io_uring
tags: [explained, io_uring, thread-pool, async-io]
converted: 2026-09-25
---

# io-wq, explained

> Plain-language companion to [[io-wq|the technical note]]. Same facts, fewer identifiers.

## The problem

io_uring promises that submitting a request never blocks the application. But many kernel operations can only be done by a thread that is allowed to sleep: buffered writes that wait on a file's lock, fsync, most metadata operations, and any file type that ignores "don't block" requests.

Without some help, io_uring would have two bad choices: block the submitting thread (defeating the whole point) or refuse those operations. io-wq is the answer: a thread pool, specific to io_uring, that performs those blocking retries on the submitter's behalf.

## The idea in one paragraph

io-wq is **a back office staffed by clones of the customer**. When a request can't be finished at the counter, it goes to a worker who is literally a thread of the submitting process: same memory, same open files, same credentials. The office keeps two queues, one for jobs that will certainly finish soon (disk I/O) and one for jobs that might wait forever (sockets, pipes), so a crowd of indefinite waits can't use up all the clerks needed for the quick jobs.

## Step by step

### Step 1: Getting sent to the back office
Every request is first tried inline without blocking. If that fails with "would block" and the file can't be polled (or the application asked for "go async right away"), the request is prepared to leave the submitter. Any state it needs, such as its list of buffers, is copied into the request itself so it survives outside the submitter's stack. Then it is handed to the pool.

The pool is created lazily per thread, the first time that thread needs one. All rings used by that thread share it, and a ring can explicitly reuse another ring's pool.

### Step 2: Pick a queue: bound or unbound
Work on regular files and block devices goes to the **bound** class. It will finish in bounded time, so its worker limit is modest (based on ring size and CPU count). Work on anything that may wait forever (sockets, pipes, terminals) goes to the **unbound** class, limited only by the process's thread limit.

Early versions had one pool. A thousand receives waiting on idle connections could occupy every worker and starve the disk writes queued behind them. The split fixes that.

### Step 3: Serialize writes to the same file
Buffered writes to one file all compete for that file's lock. Running ten in parallel only puts ten workers to sleep on one lock. So each such write is tagged with a hash of the file, and only one item per hash runs at a time; the rest of that chain waits. Writes to different files still run in parallel.

Standard kernel workqueues had no way to say "don't run these at the same time". That was one of the original reasons for building io-wq.

### Step 4: Wake a worker, or make one
The work is appended to its class's list. If an idle worker exists, it is woken. If none is free and the class is under its limit, a new worker is needed.

This is the key design choice. Since 5.12, workers are **real threads of the submitting process**, created from that process. So creation can't happen from just anywhere: io-wq leaves a note (task work) for the submitting thread, which creates the worker the next time it passes through the kernel. The earlier design used kernel threads that temporarily borrowed the submitter's memory, files and credentials. Every resource they forgot to borrow (for example how "my own process" paths resolve, audit context, cgroup) was a potential bug or CVE. Real threads inherit everything automatically.

### Step 5: The worker does the job, allowed to block
A worker takes the next item and runs the operation again, this time *without* the "don't block" flag. It may sleep on page locks, the file's lock or disk completion, exactly like an ordinary system call. If the request carries a registered set of credentials, the worker adopts them for the duration. If a pollable file still says "not ready", the worker may arm a poll instead of spinning.

When done, the result is posted directly or handed back to the owner via task work, and the worker looks for more.

### Step 6: Keep the queue draining
Because workers are real threads, the scheduler tells io-wq when one goes to sleep and when it runs again. If a worker blocks while work is still queued, io-wq can start another so the queue keeps moving. Idle workers exit after a timeout, though one per class may stay around.

### Step 7: Cancellation and teardown
Cancelling removes matching items still in the queue, and signals running workers so interruptible sleeps return. When the process exits or the ring closes, everything is cancelled and the pool is torn down once no ring uses it.

### Step 8: When workers can't be created
If a worker can't be created (the thread limit is hit, or the process is exiting), queued work is cancelled with an error rather than left dangling. "Worker explosion", thousands of unbound workers blocked on sockets, was a real production problem. It was fixed operationally by letting applications cap bound and unbound worker counts (5.15).

## The picture

```text
 request tried inline ── "would block", not pollable ──┐
                                                       ▼
                              ┌──────────── per-process pool ────────────┐
                              │  BOUND queue (files, block devices)      │
                              │   modest cap; same-file writes run       │
                              │   one at a time                          │
                              │  UNBOUND queue (sockets, pipes, ttys)    │
                              │   capped by process thread limit         │
                              └───────────────┬──────────────────────────┘
                                              ▼
            workers = real threads of the process (same memory, files, creds)
            run the operation again, allowed to sleep
                                              │
                                              ▼
                              post result (directly or via task work)
```

## Tradeoffs

- **What it gives you:** blocking operations never block the application, and each worker behaves exactly like the process itself, so permissions and resources are right by construction.
- **What it costs / requires:** every trip to the pool costs a context switch and cross-CPU cache traffic. Workers are visible to users (named `iou-wrk-<tid>`), count against the thread limit, and need careful handling by debuggers, core dumps and signals (they ignore most signals).
- **Where it bites:** unbound work can still spawn very many threads unless you set the worker cap. Because punting is expensive, io_uring invests heavily in avoiding it: asynchronous buffered reads, async poll, and filesystems that honour "don't block".

## How it got here

- **5.1:** blocking work went to a generic kernel workqueue.
- **5.3 (2019):** io-wq introduced by Jens Axboe, with bound/unbound classes and per-file serialization, because workqueues couldn't bind to a process's memory or serialize per file.
- **5.12 (2021):** workers (and the polling thread) become real threads of the process, deleting the resource-borrowing code that had caused repeated bugs.
- **5.14–5.15:** CPU affinity and worker-count caps for applications.
- **2026 (RFC):** a *thread-identity handoff*: when an inline attempt is about to block, swap identities between the submitter and a worker so the worker carries on in user space. Reviewers are wary of the many states (debugging, real-time scheduling, futex ownership, shadow stacks) where a swap is unsafe.

## Related

- Technical version: [[io-wq]]
- [[io_uring-explained|io_uring]]: the subsystem overview
- [[io-uring-internals-explained|io_uring internals]]: where the fallback decision is made
- [[io-uring-async-poll-and-multishot-explained|Async poll and multishot]]: the preferred path for pollable files
- [[io-uring-task-work-explained|Task work]]: how workers get created in the owner's context
- [[credentials-explained|Credentials]], [[vfs-explained|VFS]]
