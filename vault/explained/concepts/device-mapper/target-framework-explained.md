---
title: "Device Mapper Target Framework — Explained"
category: explained
original: "[[target-framework]]"
subsystem: device-mapper
tags: [explained, device-mapper, plugins, block]
converted: 2026-09-25
---

# The device-mapper target framework, explained

> Plain-language companion to [[target-framework|the technical note]]. Same facts, fewer identifiers.

## The problem

Device mapper wants to support an open-ended list of storage tricks: simple concatenation, encryption, thin provisioning, mirroring, multipath, caching and more. If each one were wired into the core, every new feature would mean changing the core, and the core would grow without bound.

What the core really needs is a contract: "if you are a storage transformation, implement these few functions, and I'll handle configuration, the live-update lifecycle and routing I/O to you."

## The idea in one paragraph

The target framework is device mapper's **plugin interface**. A module describes a *target type* (a name plus a set of callbacks) and registers it. When a table row names that type, the core calls its constructor with the row's arguments. From then on, every I/O request in that row's sector range is handed to the target's **map** function, which decides what to do with it. Suspend and resume callbacks let targets pause cleanly so tables can be swapped under live I/O.

## Step by step

### Step 1: Register a target type
A module registers its target type when it loads: a name (such as "linear", "crypt", "thin" or "mirror"), a version, and callbacks. The main ones are construct, destroy, map, completion, suspend/resume hooks, status reporting, and runtime messages. Others let a target list the devices beneath it and advertise constraints like sector size and alignment. It unregisters when the module unloads.

### Step 2: A table row names the type
User space loads a table where each row reads "start sector, number of sectors, target name, arguments". For each row the core looks up the target type in a global list (guarded by a lock). If the name is unknown, the load fails.

### Step 3: Construct an instance
The core creates a target instance for the row, recording its start and length, and calls the type's constructor with the argument string. The constructor parses the arguments and builds its private state (for "linear", the device and offset; for "crypt", the cipher and key). If it fails, the error goes back to user space and the whole partial table is thrown away.

### Step 4: Route each I/O request to the right target
Once the table is active, every I/O request arriving at the virtual device goes through one dispatch function. It finds the target covering the request's starting sector with a binary search over the table's sorted ranges, then calls that target's map function. Targets can also set a maximum I/O size, and larger requests are split first.

### Step 5: The map function decides
This is the key step, the hot path of every target. The map function can:
- **Remap it:** point the request at a real device and sector, and let the core resubmit it. That is all "linear" does, with simple sector arithmetic.
- **Take ownership:** clone it, queue it internally, or send it to several devices (as "mirror" does), and tell the core "it's handled".
- **Ask for a retry:** push it back, for example when every path of a multipath device is down.
- **Fail it** with an error.

### Step 6: Post-process on completion
When a remapped request finishes, the target's completion callback runs before the result travels back up. It can inspect errors, update statistics, or do extra work.

### Step 7: Pause and resume around table changes
Before a table swap, a "pre-suspend" callback lets the target drain in-flight work (a mirror flushes pending resync jobs), and a "post-suspend" callback confirms it's fully quiet. On resume, matching callbacks restore operation. This is how LVM resizes a volume, adds a mirror leg or moves data between disks without stopping I/O.

### Step 8: Teardown
When a table is replaced or a device removed, each target's destructor frees its private state.

## The picture

```text
 table:  0     1000  linear  /dev/sda 2048
         1000  5000  crypt   aes-xts ... /dev/sdb 0
                │
                │ load: look up type by name → constructor(args) → instance
                ▼
 I/O for sector 1200 ──▶ dispatch: binary search → row 2 (crypt)
                                        │
                                        ▼  map()
             ┌──────────────┬───────────┴────────┬──────────────┐
          remap          take ownership       retry later      error
      (core resubmits)  (clone, queue, fan out)
             │
             ▼
      real device ──▶ completion callback ──▶ result back up
```

## Tradeoffs

- **What it gives you:** new storage features as self-contained modules, with the core handling configuration, lifecycle and dispatch.
- **What it costs / requires:** a lookup and a function call per I/O, and every target must implement suspend and resume correctly for live changes to be safe.
- **Where it bites:** a target that doesn't drain its in-flight work properly in its suspend hook can break the "no downtime" promise of table swaps. Some targets also restrict themselves to one instance per table via a feature flag.

## How it got here

The source note doesn't give a separate history. The plugin model has been device mapper's core design since its 2003 merge, chosen so features like encryption, snapshots and RAID could be added without touching the core.

## Related

- Technical version: [[target-framework]]
- [[device-mapper-explained|Device mapper]]: the framework as a whole
- [[ioctl-control-interface-explained|The control interface]]: table loads and suspend/resume
- [[dm-io-explained|dm-io]], [[kcopyd-explained|kcopyd]]: services targets use
- [[block-explained|Block layer]]: where remapped requests go next
