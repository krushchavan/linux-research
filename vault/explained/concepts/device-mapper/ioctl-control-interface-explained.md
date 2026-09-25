---
title: "Device Mapper ioctl Control Interface — Explained"
category: explained
original: "[[ioctl-control-interface]]"
subsystem: device-mapper
tags: [explained, device-mapper, ioctl, lvm]
converted: 2026-09-25
---

# The device-mapper control interface, explained

> Plain-language companion to [[ioctl-control-interface|the technical note]]. Same facts, fewer identifiers.

## The problem

Device mapper builds virtual block devices from tables of rules. Someone has to create those devices, load their tables, change them, and ask how they're doing. And storage in production can't simply stop while that happens: LVM needs to grow a volume, add a snapshot or move data to a new disk while a database keeps writing.

So the configuration interface has two jobs. It has to keep all *policy* (what to build) in user space, where tools like LVM live. And it has to make changes to a live device atomic: either the old layout or the new one, never a broken half-state, and never a gap in service.

## The idea in one paragraph

Everything goes through one control device and a small set of ioctl commands (14 of them). There are no sysfs or procfs knobs for creating devices. The central trick is that **every device has two table slots, active and inactive**. You build the new layout in the inactive slot while the active one keeps serving I/O, and then a resume swaps them in one atomic step. If anything goes wrong before that, the old table is still in charge.

## Step by step

### Step 1: Talk through one control device
The kernel registers a single control device at startup. LVM uses it through the device-mapper library, and the `dmsetup` tool wraps it for people. Every command starts with the same header: interface version, the device's name or number, a stable UUID, flags, an event counter, and where the payload starts.

Versions are checked on every call. A different major version fails; a newer minor version is tolerated, so extensions stay backward-compatible.

### Step 2: Create a device
A create command allocates the virtual device and registers it as an ordinary disk. It has a **name**, which can be changed later, and a **UUID** fixed at creation. LVM uses the UUID as the device's real identity, so tools can find it even after a rename.

### Step 3: Load a new table into the inactive slot
A load command carries a list of rows, each saying "starting at sector S, for L sectors, use target type T with these parameters" (for example "linear, /dev/sda starting at 2048"). The kernel builds each target. The active table keeps serving I/O the whole time. If any target fails to build, the partial table is thrown away and the caller can retry or give up. A separate clear command throws away the inactive table on purpose: that is the abort path.

### Step 4: Suspend
A suspend command stops new I/O from entering, waits for in-flight I/O to drain, and calls each target's suspend hooks so they can flush their own work. Flags can skip the flush to the disks below, or skip freezing the filesystem on top.

### Step 5: Resume, which performs the swap
This is the key step. If an inactive table is waiting, resume promotes it to active and destroys the old one, calls the targets' resume hooks, and lets I/O flow again. If no inactive table is waiting, it resumes the existing one.

Because load, suspend and resume are separate calls, a crash in the middle is harmless. If the tool dies between loading and suspending, the old table is still active and the device works normally.

### Step 6: Ask for status, or wait for events
A status command asks every target for its own report and combines them. A wait command blocks until the device's event counter changes. Targets bump that counter on significant changes, such as a mirror finishing its resync or a multipath path going down. LVM uses this to watch background work without polling.

### Step 7: Protect secrets
A "secure data" flag tells the kernel to wipe its copy of the command buffer when the call is done. dm-crypt uses it so encryption keys passed in a table don't linger in kernel memory.

## The picture

```text
               ┌──────────────── one DM device ────────────────┐
  LVM / dmsetup│                                               │
      │ load   │   inactive slot:  [new table]                 │
      ├───────▶│                       │                       │
      │ suspend│   (drain I/O)         │ resume = atomic swap  │
      ├───────▶│                       ▼                       │
      │ resume │   active slot:    [old table] ──▶ discarded   │
      ├───────▶│                   [new table] ◀── serving I/O │
      │        └───────────────────────────────────────────────┘
      │ clear  → drop inactive table, active never interrupted
      │ wait   → sleep until the event counter changes (resync done, path down)
```

## Tradeoffs

- **What it gives you:** configuration changes to live storage with no downtime and a safe rollback, with all policy in user space.
- **What it costs / requires:** two full tables in kernel memory during a change (negligible for typical device counts), and a multi-step protocol user-space tools must follow correctly.
- **Where it bites:** the ioctl interface is effectively frozen. When device mapper merged in 2003, ioctls were the norm for configuring block devices. A 2008 proposal to switch to netlink was rejected because the ioctl interface was stable, deeply used by LVM2, and already extensible through its versioning.

## How it got here

- **2003:** merged with device mapper itself, using ioctls as was standard for block-device configuration.
- **2008:** a netlink replacement was proposed and rejected; the ioctl interface stayed.

## Related

- Technical version: [[ioctl-control-interface]]
- [[device-mapper-explained|Device mapper]]: the framework
- [[target-framework]]: what a table load constructs, and the suspend/resume hooks
- [[dm-crypt]]: the main user of the secure-data flag
- [[block-explained|Block layer]]: where the virtual device is registered
