---
title: "Device Mapper Target Framework"
category: concept
tags: [device-mapper, block, target-type, plugin, bio]
subsystem: device-mapper
kernel_version: "2.6.0"
researched: 2026-04-18
status: complete
explained: "[[target-framework-explained]]"
sources:
  - https://github.com/torvalds/linux/blob/master/include/linux/device-mapper.h
  - https://en.wikipedia.org/wiki/Device_mapper
  - https://lwn.net/Articles/35077/
---

# Device Mapper Target Framework

> 📘 Plain-language version: [[target-framework-explained]]

## Overview

The target framework is device-mapper's plugin interface. It defines the contract between the DM core and storage transformation modules such as `linear`, `crypt`, `thin`, and `mirror`. Any kernel module that wants to expose a new type of virtual block device implements `target_type`, registers it, and the DM core takes care of everything else: table loading, suspend/resume lifecycle, bio dispatch.

## How It Works

When a DM device is configured, userspace supplies a **table**: a list of rows, each of the form `<start_sector> <num_sectors> <target_name> <args>`. The kernel processes this during `DM_TABLE_LOAD` by walking each row and calling `dm_table_add_target()`.

For each row, `dm_table_add_target()` looks up the named `target_type` in a global registered-target list (protected by a mutex). If found, it allocates a `dm_target` structure and calls the type's `ctr` (constructor) function, passing the arg string. The constructor parses its arguments, allocates private state, and stores it in `dm_target->private`. If construction fails, the error bubbles back to userspace via the ioctl return value and the partial table is discarded.

Once the table is active (after `DM_DEV_RESUME` promotes the inactive slot), every `bio` that arrives at the virtual device is dispatched through `dm_map_bio()`. This function finds the correct `dm_target` for the bio's starting sector using a binary search over the table's sorted sector ranges, then calls `target->type->map(target, bio)`.

The `map` function is the heart of a target. It may:
- **Remap and return `DM_MAPIO_REMAPPED`**: adjust `bio->bi_bdev` and `bio->bi_iter.bi_sector` to point at a physical device, and signal the DM core to re-submit. This is what `linear` does — trivial sector arithmetic.
- **Submit and return `DM_MAPIO_SUBMITTED`**: take full ownership of the bio, potentially cloning it, queuing it internally, or submitting it to multiple devices (as `mirror` does). The DM core considers the bio handled.
- **Requeue with `DM_MAPIO_REQUEUE`**: push the bio back for retry, used when a target is temporarily unavailable (e.g. all paths down in multipath).
- **Return `< 0`**: error; the DM core ends the bio with the error code.

Completion handling is the reverse: `end_io` is called when a remapped bio completes, giving the target a chance to inspect the error, update statistics, or perform post-processing before the bio is ended toward the originator.

The **suspend/resume lifecycle** matters for online reconfiguration. Before a table swap, `presuspend()` is called to let the target drain in-flight work (e.g. mirror flushes pending resync jobs). `postsuspend()` signals that the device is fully quiesced. On resume, `preresume()` / `resume()` restore operation. This is how LVM can resize an LV, add a mirror leg, or start a pvmove without ever stopping I/O to the device.

## Key Data Structures

**`target_type`** (`include/linux/device-mapper.h`):
```c
struct target_type {
    uint64_t     features;       /* DM_TARGET_SINGLETON, DM_TARGET_INTEGRITY, etc. */
    const char  *name;           /* "linear", "crypt", "thin", ... */
    struct module *module;
    unsigned int version[3];

    dm_ctr_fn    ctr;            /* constructor: parse args, alloc private state */
    dm_dtr_fn    dtr;            /* destructor: free private state */
    dm_map_fn    map;            /* primary I/O dispatch */
    dm_endio_fn  end_io;         /* I/O completion post-processing */
    dm_presuspend_fn  presuspend;
    dm_postsuspend_fn postsuspend;
    dm_preresume_fn   preresume;
    dm_resume_fn      resume;
    dm_status_fn  status;        /* "dmsetup status" output */
    dm_message_fn message;       /* runtime control messages */
    dm_iterate_devices_fn iterate_devices; /* enumerate backing devices */
    dm_io_hints_fn    io_hints;  /* advertise sector size, alignment */
    /* + DAX, request-based, and zone-management hooks */
};
```

**`dm_target`** (`include/linux/device-mapper.h`):
```c
struct dm_target {
    struct dm_table *table;   /* the table this target belongs to */
    struct target_type *type;
    sector_t begin;           /* first logical sector */
    sector_t len;             /* number of sectors */
    uint32_t max_io_len;      /* split bios larger than this */
    void    *private;         /* target-specific state */
    char    *error;           /* set by ctr on failure */
};
```

## Key Functions

- `dm_register_target(tt)` — add a `target_type` to the global list; called from a module's `__init`
- `dm_unregister_target(tt)` — remove on module exit
- `dm_table_add_target(table, type, start, len, params)` — called during `DM_TABLE_LOAD` for each row; invokes the constructor
- `dm_map_bio(md, bio)` — fast-path dispatch; binary searches the table and calls `map()`
- `dm_table_run_md_queue_async(table)` — kick request-based queues after a table load

## Config & Flags

- `CONFIG_BLK_DEV_DM` — enables device-mapper core
- `CONFIG_DM_DEBUG` — enables dm debug logging (`pr_debug` calls in hot paths)
- `DM_TARGET_SINGLETON` in `target_type.features` — prevents multiple instances of this target in a single table (used by some hardware-offload targets)
- `DM_TARGET_INTEGRITY` — signals that this target preserves data integrity metadata for layers above

## Interactions

- **[[ioctl-control-interface]]**: table loading drives target construction; suspend/resume drives the lifecycle hooks
- **[[dm-io]]**: targets use dm-io for their own metadata reads/writes
- **[[kcopyd]]**: mirror and snapshot targets use kcopyd for background data copying
- **[[block]]**: after `map()` remaps a bio, it re-enters the block layer via `submit_bio()` targeting the physical device
