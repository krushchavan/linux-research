---
title: "Btrfs Space Accounting and Block Groups — Explained"
category: explained
original: "[[space-accounting-and-block-groups]]"
subsystem: btrfs
tags: [explained, btrfs, enospc, block-groups, reservations]
converted: 2026-09-25
---

# Btrfs space accounting and block groups, explained

> Plain-language companion to [[space-accounting-and-block-groups|the technical note]]. Same facts, fewer identifiers.

## The problem

Btrfs must always know two things: where the free space is, and whether the operation it's about to start will fit. The second is harder than it sounds.

Copy-on-write means a change never overwrites the old block, so old and new versions both exist until the transaction commits. One small write can ripple into dozens of new tree nodes. And a transaction that runs out of space halfway through can't simply back out. Without careful accounting you get the infamous **phantom ENOSPC**: `df` shows free space, but the filesystem can't complete the next transaction.

## The idea in one paragraph

Organise the disk into big **block groups** (about 256 MiB for metadata, 1 GiB for data), each of one type (data, metadata or system) and one RAID profile. Track free space inside each group, and roll totals up per type. Then separate **reservation from allocation**: before any operation starts, it reserves its worst-case space against the totals. If that fails, it fails *early and cleanly*, before touching anything, and the kernel tries a ladder of increasingly drastic ways to free space, queuing waiters fairly, first come first served.

## Step by step

### Step 1: Create block groups from chunks
When more space is needed, btrfs carves a **chunk** out of the raw devices (recording which device ranges it uses), maps it into the logical address space, and creates a block group for it. In memory, each block group records its start, size, and how much is used, reserved and **pinned** (freed but still needed by an unfinished transaction). Block groups are kept in a tree ordered by address. A new one must load (or create) its free-space record before anything can be allocated from it.

When a block group becomes completely empty, it is deleted and its device space returned, the mirror image of creating it.

### Step 2: Profiles
Each block group has a profile (single, DUP, RAID0/1/1C3/1C4/5/6/10) that decides how its chunk is spread over devices. Single devices default to DUP metadata and single data; multi-device volumes default to RAID1 metadata. All block groups of one type must share a profile, and changing it means a balance.

### Step 3: Roll up totals per type
One summary object per type (data, metadata, system) adds up all its block groups:
- **total:** all space in groups of this type
- **used:** actually allocated
- **pinned:** freed by a transaction that hasn't committed yet
- **reserved:** held by the chunk allocator
- **may use:** promised to operations that haven't allocated yet
- **read-only**, and on zoned devices, space past a zone's write pointer that can't be reused

The rule is that total must always cover everything else added together. The live numbers are visible under sysfs.

### Step 4: Track free space inside each group
To allocate quickly, each group has a record of its free ranges. The old way (v1) stored it in a special hidden file per group, which had to be invalidated and rebuilt after an unclean shutdown. The **free space tree** (v2), default for new filesystems since about 5.15, keeps it in a proper B-tree updated in the same transaction as the allocations themselves, so it's always consistent after a crash, at the cost of extra writes.

### Step 5: Reserve before you allocate
This is the key idea. Almost every change first reserves space:
1. **estimate the worst case:** for metadata, the maximum number of tree nodes this operation could copy, including every ancestor up to the root; for a buffered write, the size being written
2. **try to reserve it** by raising the "may use" total. If there's room, done: a fast path with only a brief spinlock.

Later, when blocks are really allocated, "may use" goes down and the block group's "used" goes up. Buffered writes work this way throughout: pages are dirtied and space promised, but real extents are allocated only at writeback.

### Step 6: The flush ladder
If there isn't room, the kernel frees space, cheapest steps first:
1. flush pending small metadata updates (inode updates, directory index entries)
2. run pending reference-count changes
3. write out dirty data, which makes its reservations concrete
4. allocate a new chunk, which grows the total
5. finally, **commit the transaction**, which releases everything pinned by earlier frees

### Step 7: Tickets for fairness
If the ladder still hasn't found enough, the thread queues a **ticket** and sleeps. A background worker keeps running the ladder and, as space appears, satisfies tickets in order. If two full passes don't help, the remaining tickets get ENOSPC. Before tickets, racing threads could starve each other and see false ENOSPC.

A separate **priority** queue exists for operations that must never wait behind others, such as the transaction commit itself: otherwise the commit could need metadata space that is waiting for a commit, a deadlock.

### Step 8: The global reserve
A small amount of metadata space (from about 512 KiB to a few MiB) is kept permanently reserved and never given to ordinary operations. It guarantees a commit can finish even when everything else is exhausted. If even that isn't enough, the filesystem aborts into read-only mode rather than risk corruption.

### Step 9: Freed space isn't free immediately
Freeing a block creates a delayed reference change; until it's processed, the space counts as **pinned**, because the old transaction may still need the old blocks. Committing unpins it.

### Step 10: Size classes (6.1)
Btrfs allocates the first free range that fits. When big extents are freed and small writes then fill the gaps, groups fragment. Since 6.1, data block groups are sorted into small, medium and large size classes (worked out when loaded, with no on-disk change), and writes prefer groups whose free ranges match their size.

## The picture

```text
 operation ──▶ estimate worst case ──▶ reserve ("may use" += N)
                                          │ room? yes → proceed
                                          │ no
                                          ▼
     ladder: flush small metadata → refs → dirty data → new chunk → commit
                                          │ still no?
                                          ▼
     ticket queue (FIFO)  ← worker satisfies in order; 2 failed passes → ENOSPC
     priority queue       ← commit and friends, never stuck behind others

 per type:  total ≥ used + pinned + reserved + may use + read-only (+ zone-unusable)
 block groups: [meta 256 MiB][data 1 GiB][data 1 GiB]... each with its own free-space record
 global reserve: always kept back so a commit can finish
```

## Tradeoffs

- **What it gives you:** operations fail up front instead of mid-transaction, fair behaviour under pressure, and crash-consistent free-space records.
- **What it costs / requires:** worst-case estimates are pessimistic, so metadata can look heavily used even when little is really allocated. Late ladder steps, especially forcing a commit, cause latency spikes.
- **Where it bites:** small filesystems (under about 50 GiB) can run out of *metadata* space while data space is plentiful, especially with RAID1 metadata, where every group costs twice its size in raw space. Many snapshots delay freeing (lots of pending reference changes), making ENOSPC more surprising.

## How it got here

- **2.6.29 (2009):** block groups with the v1 free-space cache and coarse reservation.
- **2.6.32 (2009):** Josef Bacik's metadata ENOSPC overhaul introduced worst-case reservation and "may use", so ENOSPC is caught before a transaction starts.
- **3.4 (2012):** background flushing for metadata reservations.
- **4.2:** ticketed reservations with a priority queue for metadata.
- **~5.10 (2020):** tickets extended to data (Josef Bacik), fixing early ENOSPC in write-heavy workloads.
- **5.15 (2021):** the free space tree became the default for new filesystems (kernel support since 4.5).
- **6.1 (2022):** size classes for data block groups, and zoned-device accounting.

## Related

- Technical version: [[space-accounting-and-block-groups]]
- [[btrfs-explained|Btrfs]]: the subsystem overview
- [[transaction-model]]: commits release pinned space
- [[multiple-b-trees-explained|Btrfs B-trees]]: the extent tree and free space tree
- [[raid-and-multi-device-support-explained|RAID and multi-device support]]: how chunks map to devices
- [[balance-and-device-management-explained|Balance]], [[qgroups-explained|Qgroups]], [[subvolumes-and-snapshots]]
