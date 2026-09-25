---
title: "pNFS (Parallel NFS)"
category: concept
tags: [nfs, pnfs, parallel-io, layout, storage, nfsv4.1]
subsystem: nfs
kernel_version: "2.6.38"
researched: 2026-04-05
status: complete
explained: "[[pnfs-explained]]"
sources:
  - https://lwn.net/Articles/313437/
  - https://lwn.net/Articles/628682/
  - https://lwn.net/Articles/898262/
  - https://docs.kernel.org/5.15/filesystems/nfs/pnfs.html
  - https://linux-nfs.org/wiki/index.php/Proposed_Device_Management_Design
---

# pNFS (Parallel NFS)

> 📘 Plain-language version: [[pnfs-explained]]

## Purpose

Traditional NFS routes all file data through a single metadata server (MDS), creating an I/O bottleneck for high-throughput workloads (HPC, video streaming, large-scale object stores). pNFS (part of NFSv4.1, RFC 5661) breaks this bottleneck by separating **metadata** (handled by the MDS) from **data** (fetched directly from storage devices). The MDS hands the client a **layout** — a map of which storage nodes hold which byte ranges — and the client then performs direct I/O to those nodes in parallel, bypassing the MDS data path entirely.

## Mental Model

pNFS is a **split-brain storage architecture**: one server handles metadata and coordination; many storage devices serve data in parallel. Analogous to a library system where a librarian (MDS) tells you which shelf and row number (layout) a book is on, and you walk directly to the stacks (storage devices) yourself rather than waiting for the librarian to fetch it. If you are writing a new section, you tell the librarian where you put it (`LAYOUTCOMMIT`) when you're done.

## How It Works

### The three-party interaction

1. **Client → MDS: LAYOUTGET** — before performing data I/O, the client sends a `LAYOUTGET` compound to the MDS requesting a layout for a file range. The MDS returns a **layout** (an opaque blob interpreted by the layout driver) and a list of **device addresses** (physical storage endpoints).

2. **Client → DS: direct I/O** — using the layout, the client sends READ/WRITE RPCs (or SCSI commands for block layouts) directly to the **data servers (DS)**. The MDS is not involved in these data-path operations.

3. **Client → MDS: LAYOUTCOMMIT / LAYOUTRETURN** — after writing, `LAYOUTCOMMIT` tells the MDS what byte ranges were written and the new file size. When the client no longer needs the layout (file close, callback recall), `LAYOUTRETURN` releases it.

### Layout types

pNFS is designed for multiple storage protocols, each with a layout driver:

| Layout type | Protocol | Use case |
|---|---|---|
| `LAYOUT4_NFSV4_1_FILES` | NFSv4.1 | NAS head with multiple NFS data servers (scale-out NFS) |
| `LAYOUT4_OSD2_OBJECTS` | OSD2 (SCSI) | Object-based storage arrays |
| `LAYOUT4_BLOCK_VOLUME` | SCSI block | SAN (iSCSI, FC) block devices |
| `LAYOUT4_FLEX_FILES` | NFSv3/v4 | Flexible files; each DS speaks NFS, client picks version |

Linux supports files, block, SCSI, and flexfiles layout drivers (`fs/nfs/nfs4filelayout.c`, `fs/nfs/blocklayout/`, `fs/nfs/flexfilelayout/`). In the absence of a layout driver for a server's advertised type, the client falls back to ordinary through-server NFS I/O.

### In-kernel layout cache — `pnfs_layout_hdr` and `lseg`

Each NFS inode that has an active layout holds a `pnfs_layout_hdr` (stored in `nfs_inode.layout`). This header manages a list of **layout segments** (`pnfs_layout_segment`, usually called `lseg`), each covering a byte range of the file:

```c
struct pnfs_layout_hdr {
    refcount_t        plh_refcount;
    atomic_t          plh_outstanding;  /* outstanding LAYOUTGET/RETURN */
    spinlock_t        plh_lock;
    struct list_head  plh_segs;         /* list of lsegs */
    nfs4_stateid      plh_stateid;      /* layout stateid from server */
    struct inode     *plh_inode;
    unsigned long     plh_flags;        /* NFS_LAYOUT_DESTROYED etc. */
};

struct pnfs_layout_segment {
    struct list_head       pls_list;    /* in pnfs_layout_hdr.plh_segs */
    struct pnfs_layout_range pls_range; /* {iomode, offset, length} */
    refcount_t             pls_refcount;
    unsigned long          pls_flags;  /* NFS_LSEG_VALID etc. */
    struct pnfs_layout_hdr *pls_layout;
    /* layout-driver-specific data follows */
};
```

On a read or write, the pNFS core calls `pnfs_find_or_recover_layout()` to check the cache. If no valid lseg covers the requested range, it sends `LAYOUTGET` to the MDS, parses the response via the layout driver's `alloc_lseg()`, and adds the new lseg to the header's list.

### Layout driver interface

Each layout type implements `pnfs_layoutdriver_type`:

```c
struct pnfs_layoutdriver_type {
    u32 id;                         /* LAYOUT4_* constant */
    struct pnfs_layout_segment *(*alloc_lseg)(struct pnfs_layout_hdr *,
                                              struct nfs4_layoutget_res *,
                                              gfp_t);
    void (*free_lseg)(struct pnfs_layout_segment *);
    int  (*read_pagelist)(struct nfs_pgio_header *);
    int  (*write_pagelist)(struct nfs_pgio_header *);
    void (*encode_layoutreturn)(struct pnfs_layout_hdr *,
                                struct xdr_stream *,
                                struct nfs4_layoutreturn_args *);
    ...
};
```

The core pNFS layer calls `read_pagelist()` / `write_pagelist()` instead of the normal NFS I/O functions when a valid lseg exists. The layout driver translates the request into the appropriate protocol (NFSv4 to a data server, SCSI command to a block device, etc.).

### Device ID cache

Layouts reference storage devices by **device ID** — an opaque 128-bit identifier. The MDS maps device IDs to network addresses via `GETDEVICEINFO`. Device information is cached in a per-`nfs_client` RCU hash table (`nfs4_deviceid_cache`) keyed by `(device_id, layout_type)`. Entries expire on layout return or explicit invalidation.

### Layout recall — `CB_LAYOUTRECALL`

The MDS can recall a layout at any time via `CB_LAYOUTRECALL` callback on the NFSv4.1 back channel. The client must:
1. Flush any pending writes for the recalled range.
2. Send `LAYOUTRETURN` to release the layout.
3. Resume through-server I/O for the duration.

Layout recalls happen when the MDS needs to rebalance the storage, when a DS fails, or when another client needs a conflicting layout (e.g. a file is being truncated).

### LAYOUTCOMMIT

For write layouts, the client calls `LAYOUTCOMMIT` before returning the layout or at `fsync`/`close`. This operation tells the MDS:
- The range that was written (`offset`/`length`).
- The new file end-of-file (if the file grew).
- Any layout-type-specific commit data (e.g. the data server's write verifier for NFSv3 file layout).

The MDS then updates the authoritative metadata and, for file layouts, may send `COMMIT` to the data servers if they used unstable writes.

## Key Data Structures

**`pnfs_layout_hdr`** (`include/linux/nfs_fs.h`) — per-inode layout cache; list of lsegs + layout stateid.

**`pnfs_layout_segment` (`lseg`)** (`include/linux/pnfs.h`) — one byte-range layout grant; driver-specific data appended.

**`pnfs_layoutdriver_type`** (`include/linux/pnfs.h`) — layout driver vtable; registered at module init.

**`nfs4_deviceid_cache`** (`fs/nfs/pnfs.h`) — RCU hash table of device ID → address mappings per client.

## Key Functions / Entry Points

**`pnfs_update_layout()`** (`fs/nfs/pnfs.c`) — checks layout cache; sends `LAYOUTGET` if needed; called on every read/write.

**`pnfs_find_and_lock_lseg()`** (`fs/nfs/pnfs.c`) — searches `pnfs_layout_hdr.plh_segs` for a valid lseg covering the request range.

**`nfs4_proc_layoutget()`** (`fs/nfs/nfs4proc.c`) — sends `LAYOUTGET` compound to MDS; parses response via layout driver.

**`pnfs_layoutreturn_free_lsegs()`** (`fs/nfs/pnfs.c`) — releases lsegs and sends `LAYOUTRETURN` to MDS.

**`nfs4_callback_layoutrecall()`** (`fs/nfs/nfs4callback.c`) — handles `CB_LAYOUTRECALL` from server; triggers layout flush and return.

## Important Flags & Config Options

| Flag / Option | Effect |
|---|---|
| `pnfs` / `nopnfs` | Mount options; `nopnfs` disables pNFS even if server advertises it |
| `NFS_LAYOUT_DESTROYED` | `plh_flags` bit set when layout is being freed; prevents new lseg additions |
| `NFS_LSEG_VALID` | `lseg.pls_flags` bit; cleared when layout is recalled; I/O reverts to MDS |
| `LAYOUT4_NFSV4_1_FILES` / `LAYOUT4_FLEX_FILES` | Layout type IDs; determines which driver handles the layout |

## Interactions with Other Subsystems

- **↑ Userspace**: transparent; applications use normal read/write syscalls. `nfsstat` can show pNFS I/O statistics.
- **→ [[nfsv4.1-sessions]]**: `LAYOUTGET`, `LAYOUTRETURN`, `LAYOUTCOMMIT` use fore channel slots; `CB_LAYOUTRECALL` uses back channel.
- **→ [[sunrpc]]**: data server I/O goes through the RPC transport; block/SCSI layouts bypass RPC entirely.
- **→ [[nfs-client]]**: pNFS is a data path optimisation within the NFS client; metadata still goes through the normal client-MDS path.
- **← Block layer**: block layout driver uses `submit_bio()` to send SCSI commands directly to DS block devices.

## Design Decisions & Tradeoffs

**Separation of metadata and data**: By keeping metadata at the MDS and only distributing the data path, pNFS avoids the distributed locking complexity of a full distributed filesystem (like Lustre or GPFS). The MDS remains the authority for namespace and layout grants; clients coordinate only through the MDS, not peer-to-peer.

**Layout driver modularity**: The layout driver interface lets pNFS support NFS, SCSI, object, and flexfiles protocols with a common control plane. This avoids a proliferation of parallel filesystem protocols while still accommodating heterogeneous storage back-ends.

**Fallback to server-side I/O**: If no layout driver is available, or if `CB_LAYOUTRECALL` fires and the client can't immediately recover a new layout, I/O falls back to the ordinary NFS data path. This graceful degradation means a misconfigured or partially-failed pNFS deployment still works, just slower.

**LAYOUTCOMMIT required for write consistency**: Because data is written directly to DSes without the MDS seeing it, the MDS doesn't know the new file size until `LAYOUTCOMMIT`. This means the MDS can return stale size information (`GETATTR`) until commit. Implementations must be careful about when `LAYOUTCOMMIT` is sent.

## How It Has Evolved

- **2.6.38 (2011)**: pNFS client framework + file layout driver merged.
- **3.5 (2012)**: pNFS block layout driver merged.
- **3.14 (2014)**: pNFS SCSI layout driver merged.
- **4.0 (2015)**: pNFS flexfiles layout driver merged (enables per-DS NFSv3/v4 I/O).
- **4.17 (2018)**: pNFS block layout server in nfsd merged.

## Further Reading

1. **LWN — "New NFS to bring parallel storage to the masses"** (2008): https://lwn.net/Articles/313437/
2. **LWN — "A simple and scalable pNFS block layout server"** (2014): https://lwn.net/Articles/628682/
3. **Kernel docs — Reference counting in pnfs**: https://docs.kernel.org/5.15/filesystems/nfs/pnfs.html
