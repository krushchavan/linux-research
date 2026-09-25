---
title: "FUSE Request Queue — Explained"
category: explained
original: "[[fuse-request-queue]]"
subsystem: fuse
tags: [explained, fuse, request-queue, interrupts, timeouts]
converted: 2026-09-25
---

# The FUSE request queue, explained

> Plain-language companion to [[fuse-request-queue|the technical note]]. Same facts, fewer identifiers.

## The problem

In [[fuse-explained|FUSE]], many kernel threads may need the user-space daemon at once: one process is listing a directory, another is reading a file, a third is being killed by a signal mid-request. The kernel can't switch directly into a particular daemon thread for each of them. It needs a buffer where requests wait, a way for several daemon threads to drain it, and a way to match each reply to the thread that's sleeping for it.

On top of that: urgent messages mustn't wait behind routine ones, floods of housekeeping messages mustn't starve real work, signals racing with delivery must be handled exactly right, and a daemon that stops answering mustn't hang the system forever.

## The idea in one paragraph

Picture a restaurant's **order window**. Kernel threads are waiters dropping tickets on a rail; the daemon is the kitchen, taking tickets off, cooking, and sliding plates back. The queue is the rail plus the shelf where in-progress orders wait for "order up". **Interrupts** are rush tickets that jump the line; **forget** slips (housekeeping) are bundled so they don't clog the rail. Each ticket has a unique number so every plate reaches the right table.

## Step by step

### Step 1: Create a ticket
Each operation allocates a request, marks it **pending** (not yet left the kernel), and gets a unique 64-bit ID from a counter on the connection. The ID goes into the header the daemon will read, and is how the reply finds its way back.

### Step 2: Queue it by priority
The input queue has three tiers, all sharing one wait queue where idle daemon threads sleep:
- **interrupts:** tiny messages saying "cancel request N", read before anything else
- **pending:** normal foreground requests such as lookup, getattr or mkdir, whose callers are blocked
- **forgets and background:** batched forget notices, and asynchronous I/O tracked separately

Adding a request wakes exactly one sleeping daemon thread.

### Step 3: Keep forgets from flooding
A forget tells the daemon the kernel has dropped its references to an inode. It needs no reply, and when the kernel evicts many inodes, huge bursts arrive. So they're batched and rationed: for every 8 ordinary requests the daemon reads, up to 16 forgets are released. The ratio was chosen empirically and isn't tunable.

### Step 4: Hand it to the daemon
When a daemon thread reads the device, it sleeps until there's work (or the connection dies), then takes the highest-priority request, copies its header and body into the daemon's buffer, marks it **sent**, and files it in the **processing** table.

Each open descriptor of the device has its own processing table, and daemons can clone descriptors so several worker threads drain the shared pending list in parallel without a global lock on replies. Each table is a 256-bucket hash keyed by unique ID, so matching a reply needs no long scan. A separate list holds requests mid-copy; abort must wait for those, to avoid freeing a request while it's being copied.

### Step 5: Match the reply
When the daemon writes a reply, the kernel reads its header (length, error, unique ID), looks the request up in the processing table, copies the reply payload where the caller wanted it, marks the request **finished**, and wakes the sleeping thread. For background requests there's no sleeper; a completion callback runs instead.

### Step 6: Signals racing with delivery
This is the key step. If a signal arrives while a thread waits, the kernel should send an interrupt, but only once the original request has actually reached the daemon, since otherwise there's nothing to cancel. The trouble is that "sent" and "interrupted" are set by two different threads, possibly on two CPUs at the same instant.

The fix is a lock-free double-check:
- the waiting thread sets **interrupted**, *then* checks **sent**
- the delivering thread sets **sent**, *then* checks **interrupted**

Because each sets its own flag before looking at the other's, at least one of them must see both, whatever the timing. Whoever sees both queues the interrupt, and queuing is idempotent, so doing it twice is harmless. The daemon answers the original request with "interrupted", or with "try again" to have the interrupt requeued. It's correct but famously confusing to reviewers.

### Step 7: Background limits
File reads and writes usually go as background requests. When they reach the congestion threshold (by default about 75% of the maximum), the connection signals congestion so writeback slows down; at the maximum (default 12, adjustable during init), new ones block. A slow daemon can't collect an unlimited pile of dirty pages.

### Step 8: Timeouts (6.14)
Each request records when it was created. Every 15 seconds a watchdog scans the processing tables; if any request is older than the agreed timeout, it **aborts the entire connection**. Timing out only the one request was considered and rejected: a daemon that failed to answer one request within budget can't be trusted with the next. System-wide settings provide a default and a cap on the timeout. Requests on the io_uring path live elsewhere and must be scanned separately, which on a 96-core machine meant 256 × 96 = 24,576 lists to walk, prompting work on per-queue timeouts.

### Step 9: Resending after a daemon restart
A recovery mechanism (proposed from 6.1, still evolving) lets a crashed daemon reattach to an existing connection. Requests the old daemon had taken are moved back to pending with a "resend" marker on their IDs, so the new daemon knows they're retries.

## The picture

```text
 kernel threads            input queue (one wait queue)            daemon threads
 ── ticket #41 ──▶  [interrupts] ▶ [forgets, 16 per 8] ▶ [pending] ▶ read()
                                                                       │ mark "sent"
                                         processing table (256 buckets, per descriptor)
                                                                       │
 ◀── wake #41 ◀── match by ID ◀─────────────────────────────── write(reply #41)

 signal race:  waiter: set INTERRUPTED → check SENT
               reader: set SENT → check INTERRUPTED   ⇒ someone queues the interrupt
 watchdog (15 s): any request too old? → abort whole connection
```

## Tradeoffs

- **What it gives you:** many callers and many daemon threads working concurrently, urgent messages first, forget storms tamed, signals handled without a lock, and hangs bounded by timeouts.
- **What it costs / requires:** every dequeue checks several lists; the interrupt protocol is subtle; the fixed-size hash has to be scanned in full on abort or timeout.
- **Where it bites:** a timeout kills the whole connection, not just the slow request, and every application using the mount gets errors.

## How it got here

- **2.6.14 (2005):** the pending, interrupt and processing lists (processing then a plain list) with a single daemon thread.
- **2.6.29:** daemons set their own background limits during init.
- **3.x:** processing became a 256-bucket hash, ending linear scans. **4.x:** cloning device descriptors for parallel worker threads.
- **5.4:** pluggable queue hooks, so virtiofs reuses everything over a virtual-machine queue.
- **6.1:** recovery with resend markers proposed.
- **6.14:** the io_uring path, the timeout watchdog and its system-wide settings.

## Related

- Technical version: [[fuse-request-queue]]
- [[fuse-explained|FUSE subsystem]], [[fuse-connection-explained|Connection]], [[fuse-wire-protocol-explained|Wire protocol]], [[fuse-vfs-integration-explained|VFS integration]]
- [[io_uring-explained|io_uring]], [[writeback-infrastructure-explained|Writeback]]
