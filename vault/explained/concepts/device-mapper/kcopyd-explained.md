---
title: "kcopyd — Explained"
category: explained
original: "[[kcopyd]]"
subsystem: device-mapper
tags: [explained, device-mapper, copy-engine, mirror]
converted: 2026-09-25
---

# kcopyd, explained

> Plain-language companion to [[kcopyd|the technical note]]. Same facts, fewer identifiers.

## The problem

Several device-mapper targets have to move large amounts of data around in the background:
- a mirror resyncing a leg after a failure, to restore redundancy
- a snapshot pre-filling its copy-on-write area
- thin provisioning zeroing newly allocated blocks before handing them out

These copies can be gigabytes. They must not stall the normal I/O flowing through the device, and they must keep working even when the system is badly short of memory. A mirror resync, in particular, is exactly what you need to finish when things are going wrong.

## The idea in one paragraph

kcopyd is a shared background copy service. A target says "copy this source region to these destinations (up to eight) and call me when done", and kcopyd does the rest on a kernel workqueue. Each client has its own reserved pages, big copies are cut into pieces that flow through a small pipeline, and the result reports exactly which destinations failed.

## Step by step

### Step 1: Create a client with its own pages
A target creates a kcopyd client in its constructor. The client reserves a pool of pages just for its copies, independent of the general allocator. This guarantees copy jobs can make progress under severe memory pressure, which is critical for mirror resync.

### Step 2: Submit a job
The target names one source region (one device, one sector range), up to eight destination regions, a completion callback, and optionally a flag saying "keep going if one destination fails".

### Step 3: Split big copies
Anything larger than a sub-job size (128 sectors by default) is cut into sub-jobs. Each carries its own slice of pages and runs through the pipeline independently. This is the key design choice: several pieces are in flight at once, so the disks stay busy, and kcopyd never needs memory for the whole transfer at once.

### Step 4: Wait for pages
A job (or sub-job) first waits on a "needs pages" list until the client's pool has enough free pages. If the pool is temporarily empty, it stays there until other jobs return theirs.

### Step 5: Read once, write everywhere
Once it has pages, the job reads the source asynchronously. When the read completes, it immediately writes those same pages to all destinations at once.

### Step 6: Complete
When every write has finished, the job moves to a "complete" list. The workqueue handles completions in order: it calls the caller's callback and returns the pages to the pool. For split copies, a counter tracks how many pieces remain, and the caller's callback fires only when the last one finishes, with all the pieces' errors combined.

### Step 7: Report errors per destination
The result is a read error plus a bitmask of write errors, one bit per destination. With the "keep going" flag, a failed destination doesn't abort the others. The failure is still reported, so a mirror can mark that leg bad and carry on degraded.

### Step 8: Zero fill, a copy with no source
A variant writes zeros to destinations without reading anything. Thin provisioning uses it so newly allocated blocks read back as zeros, as POSIX requires for new space.

### Step 9: Teardown
Destroying a client waits for in-flight jobs and releases its pages.

## The picture

```text
 target: "copy SRC → D1, D2 (callback when done)"
                 │
                 ▼  split into sub-jobs of ~128 sectors
   ┌───────────────────────────────────────────────────────┐
   │ needs pages ──▶ I/O: read SRC ──▶ write D1 + D2 ──▶ complete │
   │   (wait for         (async)        (at once)        (callback,
   │    client pool)                                      pages back)
   └───────────────────────────────────────────────────────┘
      several sub-jobs in flight at once → disks stay busy
                 │
                 ▼
   last piece done → callback: read error + write-error bitmask per destination
```

## Tradeoffs

- **What it gives you:** background copies that don't block user I/O, are safe under memory pressure, and report failures per destination.
- **What it costs / requires:** each client keeps a reserved page pool for its lifetime, and copy traffic still competes with user I/O for disk bandwidth.
- **Where it bites:** with the "ignore errors" flag, a copy "finishes" even though some destinations failed. Callers must check the per-destination bitmask, or a mirror could believe a failed leg is in sync.

## How it got here

The source note doesn't give a version history for kcopyd. Its users span device mapper's history: mirror and snapshot (in the original 2003 merge), thin provisioning (3.2) and cache (3.9).

## Related

- Technical version: [[kcopyd]]
- [[device-mapper-explained|Device mapper]]: the framework
- [[dm-io-explained|dm-io]]: does kcopyd's actual reads and writes
- [[target-framework-explained|target-framework]]: mirror, snapshot, thin and cache create kcopyd clients
