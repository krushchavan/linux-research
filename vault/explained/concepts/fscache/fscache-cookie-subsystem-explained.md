---
title: "fscache Cookie Subsystem — Explained"
category: explained
original: "[[fscache-cookie-subsystem]]"
subsystem: fscache
tags: [explained, fscache, cookies, cache-coherency]
converted: 2026-09-25
---

# fscache cookies, explained

> Plain-language companion to [[fscache-cookie-subsystem|the technical note]]. Same facts, fewer identifiers.

## The problem

A network filesystem that wants a local disk cache needs some way to say "this file, from this server, in this version" to the caching layer, without knowing or caring how and where the cache stores it. The caching layer, in turn, needs to know when a cached copy is still valid, when a file is in use, and when its storage can be thrown away.

The tricky part is lifetimes. If the cache keeps pointers back into the filesystem's own data structures, the filesystem can't shut down or unmount safely while the cache still holds them, and teardown turns into a delicate dance of waiting for callbacks.

## The idea in one paragraph

Hand out **cookies**, like luggage tickets. The filesystem describes an object (a key plus validity data) and gets back an opaque ticket. Later it presents the ticket to read or write cached data; the storage system ([[fscache-explained|fscache]] plus [[cachefiles-backend-explained|CacheFiles]]) decides where the luggage actually lives. Since 5.17, the ticket carries **copies** of everything fscache needs, so fscache never has to call back into the filesystem.

## Step by step

### Step 1: Three levels of cookie
- **Cache cookie:** one per registered backend. CacheFiles obtains one and brings it online with its table of operations; the cookie mainly anchors that table.
- **Volume cookie:** one per mount, grouping that mount's files. It's named by a printable string key (for NFS, something like server address plus export path; no slashes, at most 254 bytes). fscache hashes it and asks the backend to find or create the matching on-disk container. It also carries validity data checked when the cache binds to it.
- **File cookie:** one per cached file, created when the filesystem sets up the inode. It holds a binary key unique within the volume (typically the inode number), validity data (such as modification time and generation number) and the file's size.

Per-file granularity matches how NFS- and AFS-style filesystems judge validity: per file. Per page would mean far more cookies; per mount would make invalidating a single file impossible.

### Step 2: Idle until used
A freshly acquired file cookie is **quiescent**: no backend resources are held. The key and validity data wait in the cookie until the file is opened.

### Step 3: Use at open
Opening the file marks the cookie **in use**: the backend finds or creates the on-disk object, and an active-user count goes up. Opening the same file several times bumps the same count rather than creating more backend objects.

### Step 4: Unuse at close
Closing drops the count. The filesystem passes in the final size and updated validity data, so the backend can record them for next time. At zero, the backend may flush or keep the object. The filesystem can also update validity data and size while the cookie stays in use.

### Step 5: Invalidate without waiting
This is the key step. When a file changes on the server, its cached copy must go, but in-flight cache reads could take seconds to drain.

Instead of waiting, fscache bumps an **invalidation counter** in the cookie. Every in-flight operation checks the counter before committing its result; if it has changed, the result is dropped. At the same time the backend creates a new empty backing file (as a temporary file) for future writes, and retires the old one in the background. From the filesystem's point of view, invalidation is instant. The price is a brief window in which an in-flight read produces stale-but-consistent data, which it then discards.

### Step 6: Relinquish
When the inode goes away, the cookie is relinquished and destroyed. If the filesystem asks for it to be retired, the backend queues its on-disk object for deletion.

### Step 7: No back-pointers
Before 5.17, fscache called back into the filesystem to produce keys, check validity and complete I/O, so it held live references into filesystem structures and teardown order was complicated. Now keys, validity data and size are copied into the cookie at acquisition. That costs a small allocation per cookie, but fscache can run a cookie entirely on its own, even after the filesystem has begun shutting down.

## The picture

```text
 filesystem:  mount ─▶ volume cookie ("nfs,server:/export")
              inode ─▶ file cookie (key, validity data, size)

 file cookie:  quiescent ──open──▶ in use (count++) ──close──▶ quiescent
                                      │ server changed
                                      ▼
                            invalidate: counter++  → in-flight I/O drops results
                                        new temp backing file, old one retired
               inode gone ──▶ relinquish (optionally delete on-disk copy)
```

## Tradeoffs

- **What it gives you:** a clean separation between network filesystems and cache storage, safe teardown with no callbacks, and instant invalidation.
- **What it costs / requires:** copies of keys and validity data held per cookie; a brief window where in-flight reads do wasted work.
- **Where it bites:** validity is only as good as the data the filesystem supplies. The cache can't tell a file has changed unless the key or validity data says so.

## How it got here

- **Before 5.17:** a four-level index hierarchy (cache, primary index, secondary index, data file), a callback table for key generation, validity checks and I/O completion, and an object state machine with more than 20 states.
- **5.17 (2022):** collapsed to two levels (volume and file), callbacks removed, data copied into the cookie at acquisition, counter-based invalidation instead of drain-and-retire, and the state machine removed entirely.

## Related

- Technical version: [[fscache-cookie-subsystem]]
- [[fscache-explained|fscache subsystem]], [[cachefiles-backend-explained|CacheFiles backend]], [[netfs-helper-library-explained|netfs helper library]]
- [[network-filesystems-overview-explained|Network filesystems overview]], [[vfs|VFS]]
