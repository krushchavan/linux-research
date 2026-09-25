---
title: "pNFS (Parallel NFS) — Explained"
category: explained
original: "[[pnfs]]"
subsystem: nfs
tags: [explained, nfs, pnfs, layouts, parallel-io]
converted: 2026-09-25
---

# pNFS (parallel NFS), explained

> Plain-language companion to [[pnfs|the technical note]]. Same facts, fewer identifiers.

## The problem

In ordinary NFS, every byte of file data passes through one server. For high-throughput work (HPC clusters, video streaming, large object stores) that server becomes the bottleneck, however many disks sit behind it. Full distributed filesystems avoid this by letting clients talk to storage directly, but they bring heavy machinery for coordinating clients with each other.

pNFS, part of NFSv4.1, aims for the middle ground: keep one server in charge of names and coordination, and let data flow in parallel straight between clients and storage.

## The idea in one paragraph

Split the job in two. Think of a library: the librarian (the **metadata server**) tells you which shelf and row a book is on (the **layout**), and you walk to the stacks (the **data servers** or storage devices) and fetch it yourself instead of waiting for the librarian. If you add a new section, you tell the librarian where you put it when you're done. The metadata server stays the single authority; clients coordinate only through it, never with each other.

## Step by step

### Step 1: Ask for a layout
Before doing data I/O on a file, the client asks the metadata server for a layout covering a byte range. The reply is a layout (an opaque blob that only the matching layout driver understands) plus the identities of the storage devices involved.

### Step 2: Cache it
The client keeps layouts per inode as a list of **segments**, each covering a byte range and an access mode. On every read or write it looks for a valid segment covering the range; if none exists, it asks for a new layout and the layout driver turns the reply into a segment.

Devices are named by opaque 128-bit IDs. The client resolves them to network addresses with a device-info request and caches the answers per client, dropping them when layouts are returned or invalidated.

### Step 3: Go direct
This is the key step. With a valid segment, the normal NFS read and write functions are bypassed: the layout driver sends I/O straight to the storage. The type of storage decides how:
- **files:** NFSv4.1 data servers behind a NAS head (scale-out NFS)
- **flexfiles:** each data server speaks NFS, with the client choosing NFSv3 or v4
- **block / SCSI:** SAN devices over iSCSI or Fibre Channel, with the client issuing block I/O itself and no RPC involved
- **objects:** object-based storage arrays

The metadata server sees none of this data traffic. If the client has no driver for the server's layout type, it uses ordinary through-the-server I/O.

### Step 4: Report writes
Because data went straight to storage, the metadata server doesn't know what was written or how big the file now is. So before returning a write layout, and at fsync or close, the client sends a **layout commit**: which range was written, the new end of file, and any type-specific details (for NFSv3-based file layouts, the data server's write verifier). The metadata server updates its records and, for file layouts, may tell the data servers to commit writes they held in memory.

### Step 5: Give it back, or have it taken back
When the client is done (file closed, say) it returns the layout. The metadata server can also **recall** a layout at any time, over the NFSv4.1 back channel: to rebalance storage, after a data server fails, or when another client needs a conflicting layout (a truncate, for example). The client flushes pending writes for that range, returns the layout, and carries on through the server until it gets a new one.

## The picture

```text
                      ┌────────── metadata server ──────────┐
 client ──get layout─▶│ "bytes 0–1 GB: stripes on DS1, DS2"  │
        ◀── layout ───│  device IDs → addresses              │
                      └──────────────────────────────────────┘
 client ═══ READ/WRITE ═══▶ DS1      (in parallel, server not involved)
 client ═══ READ/WRITE ═══▶ DS2
 client ──layout commit (range, new size)──▶ metadata server
 metadata server ──recall (back channel)──▶ client: flush → return layout → fall back
```

## Tradeoffs

- **What it gives you:** data bandwidth that scales with the number of storage devices, without the peer-to-peer locking of a full distributed filesystem (such as Lustre or GPFS), plus one control protocol for several storage types.
- **What it costs / requires:** layouts, device lookups, layout commits and recalls, a whole second recovery path, and a driver per layout type.
- **Where it bites:** until the layout commit arrives, the metadata server can report a stale file size. When commits are sent matters, and most deployments skip pNFS because the complexity only pays off at large scale. On the plus side, a partly broken setup degrades gracefully: without a usable layout, I/O goes through the server, only slower.

## How it got here

- **2.6.38 (2011):** the pNFS client framework and file layout driver.
- **3.5 (2012):** the block layout driver. **3.14 (2014):** the SCSI layout driver.
- **4.0 (2015):** the flexfiles layout driver.
- **4.17 (2018):** a block layout server in the in-kernel NFS server.

## Related

- Technical version: [[pnfs]]
- [[nfs-explained|NFS subsystem]], [[nfs-client-explained|NFS client]], [[nfsv4.1-sessions-explained|NFSv4.1 sessions]], [[sunrpc-explained|SUNRPC]]
- [[block-explained|Block layer]], [[delegations-and-locking-explained|Delegations and locking]]
