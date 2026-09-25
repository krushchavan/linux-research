---
title: "ublk Batch I/O — Explained"
category: explained
original: "[[ublk-batch-io]]"
subsystem: ublk
tags: [explained, ublk, io_uring, multishot, batching]
converted: 2026-09-25
---

# ublk batch I/O, explained

> Plain-language companion to [[ublk-batch-io|the technical note]]. Same facts, fewer identifiers.

## The problem

In ublk's classic protocol, every block request costs one command submission and one completion between the kernel and the user-space server. And each request slot is permanently tied to the server thread that first fetched it.

At tens of millions of operations per second, that per-request overhead adds up. And the fixed tie means a busy thread can't hand work to an idle one; load imbalance just stays put.

## The idea in one paragraph

Replace per-slot commands with per-queue commands that move **many requests at once**, and let *any* server thread take *any* request. The classic protocol is like a pager per restaurant table. Batch I/O is a **kitchen ticket printer**: any number of cooks can stand at the pass, and whoever's turn it is tears off the next strip of tickets, however many have piled up. Cooks then hand back a whole tray of finished dishes together.

## Step by step

### Step 1: Prime many slots at once
Instead of one "fetch" per slot, the server sends a single "prepare" command per queue containing a list of elements. Each element names a tag and a buffer index, optionally plus a buffer address or a zone position. This readies many slots in one go so the device can start.

### Step 2: Post a multishot fetch per thread
Each server thread that wants work posts one **multishot** fetch command for the queue. It stays armed indefinitely, producing a completion each time there's a batch. It's tied to a provided-buffer ring, from which the kernel takes a buffer to write each batch's list of tags. The kernel keeps all posted fetches on a list, but only one is **active** at a time.

### Step 3: Requests arrive and queue up
When the block layer hands ublk requests, the driver pushes their tags into a per-queue queue of pending events. Many requests can arrive concurrently, so writers take a small lock. At the end of the block layer's batch, the driver grabs the next fetch command and schedules task work on its thread.

### Step 4: Drain a batch into one completion
This is the key step. In the fetching thread's context, the kernel:
1. picks a buffer from the provided-buffer ring
2. takes as many tags from the pending queue as fit. There's only one reader, so reading needs no lock; careful memory barriers keep it correct against the writers.
3. fills each tag's descriptor, copies write data in copy mode, and auto-registers buffers for zero-copy if that's enabled
4. posts one completion whose buffer holds the whole list of tags

The fetch stays armed, so one submission delivers an unending stream of batches. Buffer size caps a batch's size.

### Step 5: Work flows to whoever is ready
If more events are pending when the active fetch runs out of buffers, the next posted fetch becomes active. Work therefore goes to whichever threads keep fetches posted. That's how load balances, with no scheduler in the kernel.

### Step 6: Commit many results at once
The server handles the tags in any order, on any thread, then sends a single "commit" with a list of (tag, buffer index, result). The kernel walks the list and completes each block request. Committing isn't tied to the thread that fetched, which is the main point of the feature.

### Step 7: Cancellation and teardown
On cancellation, all posted fetches are completed with an abort, and any tags still queued are failed or requeued according to the device's recovery settings. A fix in 2026 made the kernel snapshot the commit list before walking it, so a server can't change it mid-processing.

## The picture

```text
 block layer ──tags──▶ [ pending events queue ]  (many writers, lock)
                                 │ single reader, no lock
                                 ▼
 posted fetches:  T1 (active) ·  T2  ·  T3
                   │
                   ▼ one completion: buffer = [17, 4, 22, 9, 31 ...]
            server thread T1 handles them (or passes them around)
                   │
                   ▼
 one commit: [(17, ok), (4, ok), (22, ok), ...] ──▶ requests complete

 T1 out of buffers? → T2 becomes active → work spreads across threads
```

## Tradeoffs

- **What it gives you:** far fewer commands per request and automatic load balancing across server threads. About +12% IOPS at 16 jobs in copy mode (37.8M → 42.4M), +3.7% with zero-copy, where data movement no longer dominates.
- **What it costs / requires:** a more complex server (multishot fetches, a buffer ring per fetching thread) and a device must choose batch mode or classic mode when it's created; mixing them would complicate ownership and cancellation.
- **Where it bites:** the memory-ordering between the queue's writers and its lock-free reader is subtle. The series grew to 24–27 patches over six revisions, and fixes followed the merge.

## How it got here

- **Nov 2025:** version 4 posted by Ming Lei (27 patches), arguing that per-slot threads still bound work to threads and per-request commands cost too much at scale.
- **Jan 2026:** version 6 (24 patches), reshaped by Caleb Sander Mateos's review; merged for **7.0**.
- **2026:** follow-up fixes for cancellation, ordering, and snapshotting commit lists.

## Related

- Technical version: [[ublk-batch-io]]
- [[ublk-explained|ublk]]: the subsystem overview
- [[ublk-io-command-protocol]]: the classic per-request protocol this replaces
- [[ublk-zero-copy]], [[ublk-user-recovery]]
- [[io-uring-async-poll-and-multishot-explained|Multishot requests]], [[provided-buffer-rings-explained|Provided buffer rings]]
- [[blk-mq-explained|blk-mq]]
