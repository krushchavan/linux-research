---
title: "Btrfs Quota Groups (Qgroups) — Explained"
category: explained
original: "[[qgroups]]"
subsystem: btrfs
tags: [explained, btrfs, quotas, snapshots, accounting]
converted: 2026-09-25
---

# Btrfs quota groups (qgroups), explained

> Plain-language companion to [[qgroups|the technical note]]. Same facts, fewer identifiers.

## The problem

In most filesystems, "how much space does this directory use?" is a simple sum. In btrfs it isn't. Snapshots and reflinks let one block of data be shared by dozens of subvolumes at once. If each of them is charged for the full block, space is counted many times over. If none are, nothing adds up.

What people actually want to know is two different things: **how much can this subvolume reach**, and **how much space would I get back if I deleted it?** And they want to set limits on either.

## The idea in one paragraph

Keep an **accounting ledger on top of the extent tree**. Every extent has a set of "owners": the subvolumes that reference it. For each quota group, track two numbers: **referenced** (all bytes it can reach, shared extents counted in full) and **exclusive** (bytes only it references, which is what deleting it would free). Level-0 groups correspond one-to-one to subvolumes; higher-level groups combine several, so you can put one limit on a set of related subvolumes. A fresh snapshot shares nearly everything with its source, so its exclusive count starts near zero and grows as the two diverge.

## Step by step

### Step 1: Turn quotas on
Quotas are off by default. Enabling them creates a **quota tree** holding a status record, one record per group with its current referenced and exclusive totals (plus compressed variants), one record per group with its limits, and one record per parent-child link in the hierarchy. On a filesystem that already has data, a **rescan** starts automatically: it walks every extent, works out which subvolumes reference it, and rebuilds all the numbers. Until it finishes, the numbers aren't reliable.

### Step 2: Reserve before writing
Before a write allocates anything, the kernel reserves space against the group's limits. If the limit would be exceeded, the write fails right there with "quota exceeded", so the user sees the error at `write()` or `fallocate()`, not later. Metadata needs are hard to predict, so metadata is over-reserved (per transaction, or in advance) and the excess released at commit. Since 3.19, reservations for overlapping ranges of the same file are de-duplicated; before that, rewriting the same range kept re-reserving it, causing false "quota exceeded" errors.

### Step 3: Trace which extents changed
As the transaction runs and extents are allocated, freed or gain and lose references, each affected extent is recorded as "dirty", along with the set of subvolumes that referenced it *before* this transaction. Capturing that "before" set at this moment avoids a second expensive lookup later and closes a race with concurrent operations.

### Step 4: Account at commit time
This is the key step. When the transaction commits, after all reference changes have been applied, the kernel goes through the dirty extents. For each, it finds the *new* set of subvolumes referencing it by walking the extent's back-references, compares it with the "before" set, and adjusts totals: a subvolume that gained a reference gains referenced bytes; an extent now owned by fewer subvolumes shifts exclusive bytes. Changes are then propagated up the group hierarchy.

Why wait until commit? The back-reference walk needs read locks on tree nodes, and doing it during the write, while write locks are held on the same tree, would deadlock. At commit time the tree is stable. The cost: numbers are only exact after each commit.

### Step 5: Parents aren't simple sums
A parent group's referenced total isn't child A plus child B: an extent shared by both would be counted twice. The kernel computes it over the combined set, counting shared extents once. So adding or removing a child from a parent normally needs a rescan, unless the child's data is entirely exclusive, in which case simple arithmetic is enough.

### Step 6: Simple quotas (6.7)
Traditional qgroups are expensive: every commit walks back-references for every dirty extent. In snapshot-heavy workloads (containers creating and deleting many snapshots), commit time grows faster than linearly, with measured throughput drops of 25–76%.

**Simple quotas** remove the walk entirely with a **permanent-ownership** rule: every extent is charged forever to the subvolume that first allocated it, recorded in a new kind of reference stamped into the extent at allocation. That needs an incompatible on-disk feature flag. The price: no more shared-versus-exclusive distinction (referenced always equals exclusive), and odd but predictable results: a snapshot's blocks stay charged to the original, even after the original is deleted, until they're rewritten. Meta's measurements showed 3–22% variance from baseline with simple quotas, versus 25–76% regression with traditional qgroups in those workloads.

## The picture

```text
 extents:     E1 (subvol 256 only)   E2 (256 + snapshot 257)   E3 (257 only)

 group 0/256: referenced = E1+E2   exclusive = E1
 group 0/257: referenced = E2+E3   exclusive = E3
 group 1/100 (parent of both): referenced = E1+E2+E3 (E2 once)  exclusive = all three

 write ──▶ reserve against limits (fail early: "quota exceeded")
 transaction ──▶ record dirty extents + "before" owners
 commit ──▶ walk back-references for "after" owners ──▶ adjust totals ──▶ propagate up
 simple quotas: owner = first allocator, stamped in the extent → no walk at commit
```

## Tradeoffs

- **What it gives you:** meaningful space accounting and limits on a snapshot-heavy, deduplicating filesystem, including "how much would deleting this free?".
- **What it costs / requires:** back-reference walks at every commit, rescans after enabling or reshaping the hierarchy, and accuracy only as of the last commit.
- **Where it bites:** snapshot-heavy workloads can see commit time and throughput collapse, which is what simple quotas fix at the cost of losing the shared/exclusive picture. Hierarchies beyond level 0 add cost and have been a source of bugs; most users never use them. Deleting big subtrees of snapshots is slow with exact accounting, so a tunable (6.1) lets the kernel skip it above a threshold, mark the numbers inconsistent, and rescan later.

## How it got here

- **3.8:** qgroups merged with per-subvolume tracking and hierarchy, but no rescan, so enabling them on a non-empty filesystem was unreliable.
- **3.10:** rescan, run automatically on enable.
- **3.19:** the reservation rework, fixing false "quota exceeded" errors.
- **4.x:** balance no longer triggers qgroup work unless there are concurrent writes.
- **6.1:** the threshold for skipping exact accounting on bulk snapshot deletion.
- **6.7:** simple quotas. 2024 work continued on removing stale groups for deleted subvolumes.

## Related

- Technical version: [[qgroups]]
- [[btrfs-explained|Btrfs]]: the subsystem overview
- [[subvolumes-and-snapshots-explained|subvolumes-and-snapshots]]: what creates shared extents
- [[multiple-b-trees-explained|Btrfs B-trees]]: the extent tree and its back-references, and the quota tree itself
- [[transaction-model-explained|transaction-model]]: why accounting happens at commit
- [[space-accounting-and-block-groups-explained|space-accounting-and-block-groups]]: physical space accounting, the complementary layer
