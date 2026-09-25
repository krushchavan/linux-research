---
title: "netfs Operations Table — Explained"
category: explained
original: "[[netfs-operations-table]]"
subsystem: netfs
tags: [explained, netfs, callbacks, network-filesystems]
converted: 2026-09-25
---

# The netfs operations table, explained

> Plain-language companion to [[netfs-operations-table|the technical note]]. Same facts, fewer identifiers.

## The problem

[[netfs-explained|netfs]] does the heavy I/O work for network filesystems, but it can't talk to any server itself. It needs a precise way to ask each filesystem the few things only that filesystem knows: how to send a read, how big a call may be, what to do when a call fails. The interface has to be small enough that a filesystem can adopt netfs gradually (read support first, write support later) without rewriting everything at each step.

## The idea in one paragraph

A single table of callbacks is the whole contract, like a **hotel concierge desk**. netfs is the hotel: it handles check-in, room allocation, cleaning and billing (page lifecycle, splitting, result collection, retries). The filesystem is the guest and only has to answer a few questions: "how big a room do you need?" (prepare), "ready to check in?" (issue), "anything after checkout?" (done, free). Only "issue a read" and "issue a write" are required; everything else has a safe default or is skipped.

## Step by step

### Step 1: The order of calls for a read
1. **set up the request:** right after netfs creates it; the filesystem can stash an authentication token or connection reference
2. **widen readahead** (optional): round the window to a convenient boundary
3. **prepare each piece:** cap it at the filesystem's maximum call size
4. **issue each piece:** start the network call asynchronously and return at once
5. **done:** after all pages are unlocked and data is visible, for cleanup
6. **free:** release the filesystem's private data on the request and its pieces

If a piece fails, netfs calls the **retry** hook, then prepares (possibly with new limits) and issues the failed pieces again.

### Step 2: The order of calls for writeback
1. set up the request, as for reads
2. **begin writeback:** the filesystem switches on the server stream and takes whatever it needs, such as dirty-byte accounting or space reservations
3. **prepare each piece:** negotiate the write size
4. **issue each piece:** send the write to the server (or cache)
5. **invalidate the cache** if a cache write failed
6. **update the size** if the write extended the file
7. **after modification:** update the modification time or a version counter
8. **retry** on failure, as for reads

### Step 3: The rules for issuing a read
This is the key step, because it's the one callback every filesystem must get right:
1. The filesystem receives a piece with its offset, length and a buffer description pointing straight at the page cache pages to fill.
2. It starts its network call, which may be asynchronous, or synchronous run on a worker thread.
3. When the call finishes, in any context (interrupt, worker or directly), it calls netfs's **termination** function with the bytes transferred on success, or an error code on failure (netfs handles retries).
4. After that call it must not touch the piece again; netfs may free it immediately.

If data arrives in chunks, the filesystem can report **progress** first, so netfs can release pages early.

Completion is signalled by the filesystem calling into netfs, not by netfs polling or registering with the filesystem. That keeps netfs independent of each filesystem's network event loop.

### Step 4: The rules for preparing a write
netfs says how much it would like to write. The filesystem lowers that to its limit (for SMB, the maximum write size agreed when the session was set up). If splitting is allowed, netfs makes more pieces for the rest; if not, the filesystem must take it all or fail. netfs also says whether this piece covers everything left, so the filesystem can pad to its preferred size and avoid a final partial call.

### Step 5: How retries work
The retry hook receives the whole stream that had failures, not individual pieces. The filesystem looks at the failed pieces and decides: refresh credentials and let netfs retry as is, declare permanent failure, or change strategy (say, from a cached path to a direct one). netfs then re-prepares each failed piece, so the filesystem can apply new limits, for example after renegotiating with the server.

### Step 6: What's required and what's not
Everything except the two issue callbacks is optional, and which callbacks exist decides which features are on:
- no **begin writeback:** no server stream, so the filesystem is read-only
- no **retry:** failures are final within one writeback pass
- no **invalidate cache:** cache write failures are ignored, so cached data may go stale
- no **prepare:** no size cap; no **update size:** the default size update is used

A read-only filesystem can start with only "issue read" and add the rest later.

## The picture

```text
 read:   set up → [widen] → prepare piece → issue piece ─┐
                                                          │ network call…
         netfs ◀── termination(bytes | error) ◀───────────┘
         failure? → retry(stream) → prepare → issue again
         → done → free

 write:  set up → begin writeback → prepare → issue → [invalidate cache]
         → [update size] → [after modification] → [retry]

 required: issue read (to read), issue write (to write)   everything else: optional
```

## Tradeoffs

- **What it gives you:** a small interface a filesystem can adopt step by step; full buffered I/O, readahead, direct I/O, writeback and caching for implementing a handful of callbacks.
- **What it costs / requires:** strict rules on completion (call termination exactly once, then hands off). Cache reads never reach the filesystem, so it can't count cache hits itself.
- **Where it bites:** leaving out optional callbacks quietly changes behaviour. Omitting cache invalidation, for instance, means a failed cache write can leave stale data behind.

## How it got here

- **5.13:** the first table: issue and prepare reads, widen readahead, done, and request set-up and freeing.
- **6.3:** write callbacks: begin writeback, prepare and issue writes, and freeing pieces.
- **6.5:** retry and cache invalidation; the retry loop formalised.
- **6.7:** size-update and after-modification hooks.
- **6.13:** write preparation told whether the piece is the last and whether it may be split.

## Related

- Technical version: [[netfs-operations-table]]
- [[netfs-explained|netfs subsystem]], [[netfs-io-request-model-explained|Request model]], [[netfs-inode-context-explained|Inode context]], [[netfs-read-path-explained|Read path]], [[netfs-write-path-explained|Write path]]
- [[fscache-explained|fscache]], [[network-filesystems-overview-explained|Network filesystems overview]]
