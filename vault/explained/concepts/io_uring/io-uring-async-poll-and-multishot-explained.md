---
title: "io_uring Async Poll and Multishot — Explained"
category: explained
original: "[[io-uring-async-poll-and-multishot]]"
subsystem: io_uring
tags: [explained, io_uring, poll, multishot, networking]
converted: 2026-09-25
---

# io_uring async poll and multishot, explained

> Plain-language companion to [[io-uring-async-poll-and-multishot|the technical note]]. Same facts, fewer identifiers.

## The problem

io_uring first tries every request without blocking. For a disk file, "would block" often means real work has to sleep somewhere. For a socket, pipe or terminal, it usually only means *not ready yet*: no data has arrived.

If io_uring handled "not ready" by giving the request to a helper thread that then sleeps waiting for data, a server with 10,000 idle connections would need 10,000 sleeping threads. That is thread-per-connection all over again, the very thing asynchronous I/O is supposed to avoid.

There is a second cost too. A server receives on each connection over and over. Submitting a fresh request after every single receive or accept adds work that adds up at high rates.

## The idea in one paragraph

Async poll is **leaving your number with the shop**. Instead of standing in line (a blocked thread), io_uring leaves a callback on the file's own wait queue. When the socket becomes ready, the callback fires and the request is retried in the application's thread. Multishot is a **standing order**: after each pickup the shop keeps your number and calls again for the next batch, until you cancel, something fails, or you run out of bags to carry things home in (no free buffers).

## Step by step

### Step 1: The first attempt fails with "not ready"
Say a receive on a TCP socket finds the receive queue empty. io_uring checks two things: can this file be polled, and does this operation care about readability or writability? If both are yes, it arms a poll instead of calling for a helper thread.

### Step 2: Arm the poll, and check for a race
io_uring adds its own entry to the socket's wait queue, the same kind of hook epoll uses. The same call also reports the socket's current state. If data arrived in the tiny gap between the failed attempt and arming, that is caught right here and the request is retried immediately rather than waiting for a wake-up that already happened.

### Step 3: Decide who owns the request
Once armed, several parties may touch the request at once: the socket's wake-up on any CPU, a cancellation, and the application thread still handling a previous wake-up. io_uring settles this with a single atomic counter. Whoever bumps it up from zero owns the request and must process it. Anyone else only bumps the count, which tells the owner to loop again.

This is the key step. Earlier versions used locks and state flags and suffered a long run of races between wake-up, cancellation and completion, several of them CVEs. The counter scheme (around 5.17) is harder to read but reliably makes one party at a time do the processing.

### Step 4: The wake-up does almost nothing
When data arrives, the network stack wakes the socket's wait queue and io_uring's callback runs, often in interrupt-like context (softirq). It checks that this is an event it cares about, claims ownership if it can, and queues **task work** for the application's thread. It does no copying and posts no completion. That keeps softirq time short.

### Step 5: Retry in the application's thread
The task work runs in the submitting thread. It checks readiness again, handles any pending cancellation, and re-issues the original receive. This time data is there: a buffer is picked if the request asked for one, the data is copied, and the request completes. The cost is a second attempt at the operation and an extra hop of latency, which batching of completions later absorbs.

### Step 6: Multishot keeps the request alive
A multishot request does not finish after a successful receive. It posts a completion flagged **"more coming"**, stays armed, and tries again right away while the socket still has data. That loop is bounded so one busy socket can't hog the thread. When the socket runs dry, it goes back to waiting on poll.

### Step 7: How a multishot request ends
The final completion is the one *without* the "more coming" flag. That is how the application knows the request is dead and must be resubmitted if still wanted. It ends on:
- an error, including "no buffers" when the provided buffer ring is empty
- end of file (a receive returning zero bytes)
- explicit cancellation
- the completion ring overflowing, since the kernel stops multishots rather than overflow indefinitely

These stops are deliberate backpressure: they keep memory bounded. Every multishot user must remember to re-arm after a final completion, including after "no buffers".

### Step 8: Awkward files with two wait queues
Some files register on *two* wait queues when polled, for example a terminal with separate read and write queues. io_uring then needs two hook entries, and ownership has to cover both. This is a classic source of bugs.

### Step 9: Cancellation
Armed requests are kept in hash tables keyed by the application's tag, so a cancel request can find them without scanning. Since 5.19 you can also cancel by file, or cancel everything matching. The canceller sets a "cancel" flag in the ownership counter. If it becomes the owner it tears the request down itself. Otherwise the current owner sees the flag and does it.

### Step 10: Failure and teardown
If the file can't be polled at all, or arming runs out of memory, the request falls back to a helper thread. If the file is closed while a poll is armed, the file's teardown path removes the wait-queue entry and the request completes as "cancelled". That path was added after use-after-free bugs with signalfd and binder.

## Which operations use it

The same engine powers several features:
- **Explicit poll:** io_uring's epoll equivalent. With multishot (5.13) it posts a completion with the ready events every time the file becomes ready, and can be updated in place.
- **Multishot accept** (5.19): each completion is a new connection, optionally placed straight into a registered file slot.
- **Multishot receive** (6.0): needs provided buffers, one per completion.
- **Multishot timeouts** (6.4): periodic ticks. **Multishot read** on pollable files (6.7).
- **Zero-copy receive** and an **epoll-wait** operation for bridging existing epoll sets into a ring (both 6.15).

## The picture

```text
 receive on socket ── not ready ──▶ arm poll on socket's wait queue
                                         │   (race check: ready already? retry now)
                                         ▼
                      data arrives ──▶ wake-up callback (softirq)
                                         │ claim ownership, queue task work
                                         ▼
                      application thread: re-check, re-issue receive
                                         │
                   ┌─────────────────────┴───────────────────┐
              one-shot                                 multishot
          completion, done                  completion "more coming"
                                            try again while data remains
                                            ├─ runs dry → wait on poll again
                                            └─ error / EOF / no buffers /
                                               cancel → final completion
                                                        (no "more" flag)
```

## Tradeoffs

- **What it gives you:** socket I/O with no helper threads at all, and one request that keeps producing results. Together they make io_uring a complete replacement for an epoll event loop.
- **What it costs / requires:** a second attempt at each operation after wake-up, an extra hop into the application's thread, and a lot of concurrency machinery (ownership counting, double wait queues, cancellation).
- **Where it bites:** this code has been a steady source of races and CVEs. On the application side, forgetting to re-arm when a multishot request ends (especially after running out of buffers) silently stops a connection from being read.

## How it got here

- **5.1:** only a one-shot explicit poll. Blocking socket operations went to worker threads, so io_uring networking could be slower than epoll.
- **5.7:** internal async poll ("fast poll") for pollable files. Big networking gains.
- **5.13:** multishot poll, and updating a poll in place.
- **5.17–5.18:** the ownership-counter rework after repeated races, plus safe handling of files closed while polled.
- **5.19–6.7:** multishot accept, broader cancellation, multishot receive with buffer rings (6.0), batched multishot completions (6.2), multishot timeouts and read.
- **6.15:** epoll-wait operation and multishot zero-copy receive.

## Related

- Technical version: [[io-uring-async-poll-and-multishot]]
- [[io_uring-explained|io_uring]]: the subsystem overview
- [[io-uring-task-work-explained|io-uring-task-work]]: how wake-ups continue in the application's thread
- [[provided-buffer-rings-explained|provided-buffer-rings]]: where multishot receive gets its buffers
- [[io-wq-explained|io-wq]]: the helper-thread fallback this avoids
- [[registered-resources-explained|registered-resources]]: direct descriptors for multishot accept
- [[vfs-explained|VFS]], [[net-explained|Networking]]
