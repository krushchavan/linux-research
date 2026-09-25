---
title: "dm-io — Explained"
category: explained
original: "[[dm-io]]"
subsystem: device-mapper
tags: [explained, device-mapper, block-io, metadata]
converted: 2026-09-25
---

# dm-io, explained

> Plain-language companion to [[dm-io|the technical note]]. Same facts, fewer identifiers.

## The problem

Most of what a device-mapper target does is pass the I/O it receives down to another device. But many targets also need to do I/O *of their own*: read and write their metadata, write a block to several mirror legs, load a snapshot's table of copied blocks.

If every target (mirror, snapshot, RAID) wrote its own code for that, each would duplicate the same plumbing: building block requests, handling errors, managing memory, and calling back on completion. And they would all face the same trap: under memory pressure, a target that can't allocate memory to read its metadata may deadlock the very device the system needs in order to free memory.

## The idea in one paragraph

dm-io is a small shared I/O helper for device-mapper targets. You describe *where* (one or more regions of a device) and *what memory* (in one of three forms), say read or write, and either wait or get a callback. Each client has its own reserved pages, so it can always make progress. Results come back as a bitmask, one bit per region, so a single call to several destinations can report exactly which ones failed.

## Step by step

### Step 1: Create a client with reserved memory
A target creates a dm-io client in its constructor, saying how many pages it expects to use at once. The client reserves that many pages up front. This is the key step: metadata I/O must succeed even when the system is short of memory, and reserving pages in advance makes it independent of the general page allocator.

### Step 2: Describe where the I/O goes
Each **region** names a device, a starting sector and a number of sectors. A request can cover several regions.

### Step 3: Describe the memory
The data side can be given in three forms, picked to fit the situation:
- **A list of pages**, with an offset into the first. The most flexible, used when the target takes pages from its own pool.
- **An existing list of page segments** taken from an I/O request the target already received. Useful for redirecting parts of that request to different devices, such as mirroring a write to two disks.
- **One contiguous block of virtual memory.** Good for big metadata reads, like loading a snapshot's exception table, without allocating and chaining many separate pages.

### Step 4: Wait, or get called back
With no callback, the call blocks until all regions finish and returns the result. With a callback, it returns immediately and the callback fires when everything is done.

### Step 5: Read the error bitmask
The result is not a single error code but a **bitmask**: bit *i* set means region *i* failed. That matters for writes to several places at once.

### Step 6: Write the same data to many places
One call can write the same data to many destinations. The mirror target uses this instead of submitting a separate request per mirror leg. The bitmask tells it which legs succeeded, so it can keep running in a degraded state rather than failing outright.

### Step 7: Teardown
Destroying the client releases its reserved pages.

## The picture

```text
 target (mirror, snapshot, raid, kcopyd...)
    │
    │  request: read/write · memory (page list | existing segments | one buffer)
    │           · regions [dev A 100..199] [dev B 100..199] · callback or wait
    ▼
 ┌──────────── dm-io client ────────────┐
 │  reserved pages → always makes progress
 │  builds block requests per region     │
 └───────────────┬───────────────────────┘
                 ▼
     block devices A, B ...
                 │
                 ▼
   result bitmask: 0b10 → "region 1 (dev B) failed, region 0 ok"
```

## Tradeoffs

- **What it gives you:** one shared, memory-safe way for targets to do their own I/O, with per-region error reporting and fan-out writes.
- **What it costs / requires:** each client ties up its reserved pages for its whole lifetime, whether or not they're in use.
- **Where it bites:** callers must treat the result as a bitmask, not a plain error. Treating any non-zero result as total failure throws away the information a mirror needs to degrade gracefully.

## How it got here

The source note doesn't give a version history for dm-io itself. The mirror target, one of its main users, was part of device mapper's first merge (2.6.0, 2003).

## Related

- Technical version: [[dm-io]]
- [[device-mapper-explained|Device mapper]]: the framework
- [[kcopyd-explained|kcopyd]]: uses dm-io for the read and write halves of each copy
- [[target-framework-explained|target-framework]]: targets create their dm-io clients in their constructors
- [[dm-bufio-explained|dm-bufio]]: the metadata cache that sits beside it
- [[block-explained|Block layer]]: where the requests end up
