---
title: "FUSE Connection — Explained"
category: explained
original: "[[fuse-connection]]"
subsystem: fuse
tags: [explained, fuse, connection, flow-control]
converted: 2026-09-25
---

# The FUSE connection, explained

> Plain-language companion to [[fuse-connection|the technical note]]. Same facts, fewer identifiers.

## The problem

[[fuse-explained|FUSE]] lets a user-space program act as a filesystem. For that, the kernel needs one durable object per mounted FUSE filesystem to route every file operation to the right daemon and match replies back to the right caller. It also has to remember what features both sides agreed on, and to cope when the daemon is slow, stuck or gone.

Without such an object there'd be nowhere to hold the queues, no way to keep one mount's requests separate from another's, and no single place to pull the plug when things go wrong.

## The idea in one paragraph

The connection is the kernel's end of a **telephone switchboard**. Every operation on the mount becomes a message posted to a shared inbox (the `/dev/fuse` device); the daemon picks messages up, works on them and posts replies. The switchboard holds the queues, tracks outstanding calls, limits how many can pile up, and remembers which features were agreed when the line was first opened. A single "connected" switch lets the whole thing be shut down at once.

## Step by step

### Step 1: Birth at mount time
The daemon opens `/dev/fuse` and passes the file descriptor to `mount`. The kernel checks that the descriptor really is a FUSE device, that the caller is in the same user namespace that opened it, and that the required mount options are present. Then it creates the connection:
- locks for general state and for background requests
- a reference count and a count of open device descriptors, both starting at 1
- an input queue with pending and interrupt lists, and a wait queue where the daemon's reads sleep
- background limits (default at most 12 requests, with a lower congestion threshold)
- the caller's process-ID and user namespaces, so later IDs can be translated correctly even if the daemon moves
- the "connected" flag, switched on

### Step 2: The init handshake
The connection exists but isn't usable yet. The kernel queues an **init** request, which is the first thing the daemon reads. It carries the kernel's protocol version (7.x) and a 64-bit mask of every feature the kernel supports: write-back caching, parallel directory operations, asynchronous direct I/O, POSIX ACLs, passthrough, io_uring transport and so on.

The daemon replies with its own version, the largest write it accepts, how far ahead the kernel may read, its preferred background limits, and its own feature mask. The kernel keeps only the features both offered and records the limits. Only then is the root directory exposed to applications.

Growing a feature mask under a fixed major version means old daemons ignore bits they don't know and keep working. The cost is a large mask and some subtle interactions between features.

### Step 3: Queuing and dispatch
Each file operation creates a request and puts it on a queue:
- **foreground** requests, whose caller waits for the answer
- **interrupts**, telling the daemon a request was killed by a signal
- **background** requests, asynchronous and allowed to run concurrently up to the limit

When the daemon reads the device, the kernel hands it the highest-priority request (interrupts, then foreground, then background) as a header plus body, and moves it to the per-descriptor **processing** list. The caller sleeps. When the daemon writes a reply, the kernel finds the request in the processing list by its unique ID, copies the answer in, and wakes the caller.

### Step 4: Back-pressure
This is the key step for robustness. When outstanding background requests reach the congestion threshold, the connection marks its backing device congested, so writeback eases off; the mark clears when the queue drains. At the hard maximum, new background requests block until space frees up. A slow or stuck daemon therefore can't make the kernel's request pool grow without bound.

For foreground requests, the kernel refuses with a permission error rather than sleeping forever in one deadlock-prone case involving processes owned by the mount's owner.

### Step 5: Abort
A connection can end abruptly in four ways: the daemon exits (its last device descriptor closes), an admin writes to the connection's abort control file, a forced unmount, or the superblock being torn down. Aborting switches "connected" off, walks every pending and processing list, wakes each waiter with an error, and rejects any new request immediately. Unmount and control-file aborts can report different errors, if the daemon negotiated that feature.

Aborting is all-or-nothing. Finer control, cancelling a single request, comes from the interrupt path.

### Step 6: Final teardown
Each mount of the connection (bind mounts share one) and each open device descriptor holds a reference. When the last one goes, the kernel releases DAX resources, cancels the request-timeout watchdog, runs the queue's cleanup hook, frees write-synchronisation state, and then frees the connection after an **RCU grace period**, so any reader walking the connection list at that moment finishes safely first.

### Step 7: The io_uring path (6.14)
Instead of a loop of reads and writes on the device, the daemon can register per-CPU slots in an io_uring. The kernel places requests directly into those slots and signals completion events. The daemon answers with one command that both commits its reply and fetches the next request, avoiding a context switch per request. Notifications and interrupts still use the traditional path, so the result is a hybrid.

### Other transports
The same connection machinery serves CUSE (character devices implemented in user space) and virtiofs. Their queues have pluggable hooks, so virtiofs, for instance, sends requests over a virtual-machine queue instead of `/dev/fuse`.

## The picture

```text
 mount(fd of /dev/fuse) ─▶ create connection ─▶ queue INIT ─▶ daemon replies: features ∩, limits
                                    │
   file ops ─▶ [interrupts] [foreground] [background ≤ max, congested ≥ threshold]
                                    │ daemon read()
                          processing list (by unique ID)
                                    │ daemon write(reply)
                          match ID → copy → wake caller
   abort: connected = 0 → fail all waiters, reject new requests
   last reference: cleanup → free after RCU grace period
```

## Tradeoffs

- **What it gives you:** one place that owns queues, limits, negotiated features and shutdown; protection from runaway queues; support for several transports.
- **What it costs / requires:** a single device descriptor per connection means the daemon is a bottleneck unless it manages its own concurrency; sharing across bind mounts makes teardown order complicated.
- **Where it bites:** aborting is coarse, failing everything at once. Enabling write-back caching improves writes but can serve stale data when something outside the mount changes files.

## How it got here

- **2.6.14 (2005):** initial merge with pending and processing queues on `/dev/fuse`.
- **2.6.29:** daemons can set the background limits during init (protocol 7.13).
- **3.15:** write-back caching; **4.8:** parallel directory operations, ending the serialisation of all directory work.
- **4.20:** distinct errors for control-file abort versus unmount. **5.4:** virtiofs, with pluggable queue hooks.
- **6.1:** a proposed recovery mechanism so a crashed daemon can reattach to an existing connection without unmounting.
- **6.14:** the io_uring transport.

## Related

- Technical version: [[fuse-connection]]
- [[fuse-explained|FUSE subsystem]], [[fuse-request-queue-explained|Request queue]], [[fuse-wire-protocol|Wire protocol]], [[fuse-vfs-integration|VFS integration]]
- [[io_uring-explained|io_uring]], [[uring-cmd-passthrough-explained|io_uring command passthrough]]
- [[writeback-infrastructure-explained|Writeback]], [[rcu-read-copy-update|RCU]]
