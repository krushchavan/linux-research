---
title: "Device Mapper ioctl Control Interface"
category: concept
tags: [device-mapper, ioctl, lvm, control-plane, block]
subsystem: device-mapper
kernel_version: "2.6.0"
researched: 2026-04-18
status: complete
explained: "[[ioctl-control-interface-explained]]"
sources:
  - https://lwn.net/Articles/35077/
  - https://en.wikipedia.org/wiki/Device_mapper
  - https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/index.html
---

# Device Mapper ioctl Control Interface

> 📘 Plain-language version: [[ioctl-control-interface-explained]]

## Overview

Device-mapper's entire control plane flows through a single character device (`/dev/mapper/control`) and 14 ioctl commands. There are no sysfs knobs or procfs entries for device creation; all device lifecycle management, table loading, and status queries happen via this interface. LVM2 talks to it through `libdevmapper.so`; the `dmsetup(8)` tool wraps it for human use.

## How It Works

The kernel registers `/dev/mapper/control` as a misc device during `dm_init()`. All ioctls share a common `dm_ioctl` header that carries the device identity (by name or major:minor), plus versioning and event fields. The payload for table operations follows immediately after the header.

### Dual-Table Architecture

The most important design feature is that every DM device maintains **two table slots**: *active* and *inactive*. This enables atomic, zero-downtime reconfiguration:

1. **`DM_TABLE_LOAD`** — write a new table into the inactive slot. The active table continues serving I/O uninterrupted. If construction of any target fails, the partial inactive table is discarded; userspace can retry or abort.
2. **`DM_TABLE_CLEAR`** — discard the inactive slot without touching the active table. This is the abort path.
3. **`DM_DEV_SUSPEND`** — quiesce the device: block new I/O, drain in-flight I/O, call each target's `presuspend()` / `postsuspend()` hooks.
4. **`DM_DEV_RESUME`** — if an inactive table is present, promote it to active (destroying the old active table), then call `preresume()` / `resume()` and allow I/O to resume. If there is no inactive table, simply resume the existing active table.

The suspend and resume are separate ioctls, but the resume ioctl performs the atomic swap. This means userspace can do steps 1–4 as a sequence, and if it crashes between `DM_TABLE_LOAD` and `DM_DEV_SUSPEND`, the old table is still active and the device is fully operational.

### The dm_ioctl Header

```c
struct dm_ioctl {
    uint32_t version[3];    /* interface version (major.minor.patch) */
    uint32_t data_size;     /* total size of ioctl data block */
    uint32_t data_start;    /* byte offset to payload after this header */
    uint32_t target_count;  /* number of dm_target_spec entries (for table ops) */
    int32_t  open_count;    /* read-only: current openers */
    uint32_t flags;         /* DM_READONLY_FLAG, DM_SUSPEND_FLAG, DM_EXISTS_FLAG, ... */
    uint32_t event_nr;      /* for DM_DEV_WAIT: wait until event_nr changes */
    uint32_t padding;
    uint64_t dev;           /* device major:minor encoded */
    char     name[DM_NAME_LEN];  /* /dev/mapper/<name> */
    char     uuid[DM_UUID_LEN];  /* stable UUID set at creation */
    char     data[7];       /* alignment padding */
};
```

Version negotiation happens on every ioctl: userspace sends the version it expects; if the kernel's major version is different, the ioctl fails. Minor version differences are tolerated.

### Table Row Format

Each row in a table load is a `dm_target_spec` followed by a null-terminated parameter string:

```c
struct dm_target_spec {
    uint64_t sector_start;  /* logical start sector */
    uint64_t length;        /* number of sectors */
    int32_t  status;        /* set by kernel on status queries */
    uint32_t next;          /* byte offset to next dm_target_spec */
    char     target_type[DM_MAX_TYPE_NAME]; /* e.g. "linear" */
    /* immediately followed by null-terminated params, e.g. "/dev/sda 2048" */
};
```

### Notable Flags

| Flag | Meaning |
|---|---|
| `DM_READONLY_FLAG` | Load table read-only; writes to the device will error |
| `DM_SUSPEND_FLAG` | When set in `DM_DEV_SUSPEND`, suspends (not resumes) the device |
| `DM_SECURE_DATA_FLAG` | Zero the ioctl buffer after completion (prevents key leakage from dm-crypt) |
| `DM_NOFLUSH_FLAG` | During suspend, do not issue a flush to backing devices |
| `DM_SKIP_LOCKFS_FLAG` | Skip freezing filesystems during suspend |
| `DM_EXISTS_FLAG` | Set by kernel in responses when the device was found |

### Event Notification

`DM_DEV_WAIT` blocks the calling process until the device's `event_nr` increments. Targets increment the event counter when significant state changes occur (e.g. a mirror finishes resyncing, a multipath path goes down). LVM2 uses this to monitor background operations without polling.

## Key Functions (kernel-side)

- `dm_ioctl()` — main dispatch, in `drivers/md/dm-ioctl.c`
- `dev_create()` — `DM_DEV_CREATE`: allocates a `mapped_device`, creates the gendisk
- `table_load()` — `DM_TABLE_LOAD`: parses target specs, calls `dm_table_add_target()` per row
- `dev_suspend()` — `DM_DEV_SUSPEND`: quiesces or resumes, optionally swaps tables
- `dev_status()` — `DM_DEV_STATUS`: calls `target->status()` for each target, aggregates

## Design Decisions

**ioctl over netlink** — When DM was merged in 2003, ioctl was the established interface for block device configuration. A 2008 RFC proposed a netlink replacement but was rejected because the ioctl interface was already stable, widely deployed in LVM2, and the versioning mechanism meant extensions were backward-compatible. This is a frozen design decision.

**Separate UUID field** — The `name` field is mutable (devices can be renamed with `DM_DEV_RENAME`), but `uuid` is set at creation and never changes. LVM2 uses the UUID as the stable device identity, allowing tools to find a device even after it's been renamed.

## Interactions

- **[[target-framework]]**: table loading drives target construction and lifecycle hooks
- **[[block]]**: the `mapped_device` is registered as a `gendisk`; I/O arrives via `submit_bio()`
- **Userspace**: `libdevmapper.so` / `dmsetup(8)` / LVM2 are the primary consumers
