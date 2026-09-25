---
title: "ublk I/O Command Protocol — Explained"
category: explained
original: "[[ublk-io-command-protocol]]"
subsystem: ublk
tags: [explained, ublk, io_uring, protocol, block]
converted: 2026-09-25
---

# The ublk I/O command protocol, explained

> Plain-language companion to [[ublk-io-command-protocol|the technical note]]. Same facts, fewer identifiers.

## The problem

Once a ublk disk exists, every block request has to reach the user-space server, and every result has to come back. A system call per request in each direction would make ublk far slower than an in-kernel driver.

There's also a context problem. A request can be submitted by any process on any CPU, but completing the server's command and copying data into the server's memory can only safely happen in the server's own context.

## The idea in one paragraph

Put both directions on io_uring with **one long-lived command per request slot**. Think of **a restaurant pager per table**. The server hands the kernel a pager for every table ("fetch"). When an order arrives at table 17, the kernel writes it on table 17's ticket (a shared, read-only descriptor) and buzzes that pager (completes the command). The waiter serves the order, then hands back the pager while reporting the bill ("commit and fetch"), and the same pager is immediately ready for table 17's next order.

## Step by step

### Step 1: Slots and descriptors
A device has some number of queues, each with some number of slots. A slot is identified by (queue, tag), and the block layer's own request tag *is* the slot number, so no mapping table is needed. For each queue the kernel keeps an array of **descriptors** (operation and flags, start sector, length, buffer address). The server maps this array **read-only**: the kernel writes it, the server only reads it, so a buggy server can't corrupt kernel state through it.

### Step 2: Prime every slot
For each slot, the server submits a "fetch" command naming the slot and, in copy mode, its buffer address. The kernel records the command, marks the slot active, remembers the submitting thread as the slot's owner, marks the command cancelable, and leaves it **pending** in the ring indefinitely. Once every slot is primed, the device can start.

### Step 3: A request arrives
The block layer hands ublk a request. If the queue is being cancelled or is in fail mode, it's rejected. Otherwise ublk stores the request with the slot's pending command and asks io_uring to run a callback **in the owner thread's context** (task work). That runs when the thread next enters the kernel, or right away if it's waiting for completions.

### Step 4: Dispatch in the server's context
In the server thread, the kernel:
1. fills the slot's descriptor (operation, flags such as force-unit-access, sectors, buffer address)
2. copies write data into the server's buffer (unless a zero-copy or copy-on-demand mode is on)
3. marks the slot as owned by the server and completes the pending fetch

The server now sees a completion for that slot.

### Step 5: Serve and commit, in one command
This is the key step. The server reads the descriptor, does the work, and sends **"commit and fetch"** with the result (bytes done or an error). The kernel checks the slot really belongs to the server and that the sender is the slot's owner, copies read data back into the request's pages, ends the block request (batched when possible), and re-arms the slot using the *same* command.

One submission both completes the previous request and waits for the next. In steady state that is one submission and one completion per I/O, the same trick NVMe uses with its doorbells.

### Step 6: The two-phase write option
In plain copy mode, the server must give a write buffer *before* it knows how big the write is. With the "need get data" option, a write first arrives with no data. The server allocates a buffer, sends its address, and only then does the kernel copy the payload in. It costs an extra round trip but suits servers that manage memory per request.

### Step 7: Who owns a slot
Originally one server thread served a whole queue and had to issue every command for it. Since 6.16 (Uday Shankar), ownership is **per slot**: whichever thread fetched a slot owns it. Server thread count no longer has to match the number of hardware queues. Batch I/O later removed fixed ownership entirely.

### Step 8: Cancellation and timeouts
When the server's ring is torn down or it cancels commands, io_uring tells ublk. ublk marks the queue as cancelling and stops dispatching, then completes each still-pending fetch with an abort. Requests the server already owned are dealt with later, when its channel is released (see recovery). If a request times out on an **unprivileged** device, the kernel kills the server outright, so a malicious or stuck server can't hang the system forever.

## The picture

```text
 server                                    kernel
 ──────                                    ──────
 fetch (q2, tag17) ─────────────────────▶  pending, slot 17 active, owner = me
                                           ... block request with tag 17 arrives
                                           task work in owner thread:
                                             fill descriptor[17], copy write data,
 ◀────────────────────────── completion ── complete the fetch (slot → server)
 read descriptor[17], do the I/O
 commit-and-fetch (tag17, result) ──────▶  copy read data back, end request,
                                           re-arm slot 17 with the same command
```

## Tradeoffs

- **What it gives you:** one submission and one completion per I/O, no per-request system calls, and a read-only descriptor array that keeps the kernel safe from the server.
- **What it costs / requires:** every request bounces into the server thread's context, and (before per-slot owners) threads were hard-bound to queues. Because tags are slots, queue depth fixes the number of pending commands, at most 4096 per queue.
- **Where it bites:** copying data in and out of the server's buffers is the dominant cost of this simple design. That drove years of zero-copy work.

## How it got here

- **6.0 (2022):** one owner thread per queue, fetch and commit-and-fetch, and the two-phase write option. In the original posting, Ming Lei reported ublk's loop target beating the kernel's own loop driver.
- **6.2:** standard ioctl encoding for the commands.
- **6.6:** zoned operations, with zone-append positions returned in the commit.
- **6.15:** buffer register and unregister commands join the set, for zero-copy.
- **6.16:** per-slot owner threads.
- **7.0:** batch commands as an alternative protocol.

## Related

- Technical version: [[ublk-io-command-protocol]]
- [[ublk-explained|ublk]]: the subsystem overview
- [[ublk-control-plane-explained|Control plane]]: priming happens before "start"
- [[ublk-batch-io-explained|Batch I/O]]: the many-requests-per-command alternative
- [[ublk-zero-copy]], [[ublk-user-recovery-explained|ublk-user-recovery]]
- [[uring-cmd-passthrough-explained|Passthrough commands]], [[io-uring-task-work-explained|Task work]], [[blk-mq-explained|blk-mq]]
