---
title: "inotify and fanotify — Explained"
category: explained
original: "[[inotify-and-fanotify]]"
subsystem: fs
tags: [explained, fs, inotify, fanotify, notifications]
converted: 2026-09-25
---

# inotify and fanotify, explained

> Plain-language companion to [[inotify-and-fanotify|the technical note]]. Same facts, fewer identifiers.

## The problem

Programs need to react when files change: an editor reloading, a build tool rebuilding, a sync client uploading, a virus scanner checking a file *before* it's opened. The original mechanism, dnotify, only watched directories, used signals, and needed an open file descriptor per watched directory, which ran out fast on big trees.

inotify fixed the basics. But some tools need to watch *everything* on a filesystem (backup, anti-virus), and some need to **block** an open until they've approved it. That needed a second, more powerful API: fanotify.

## The idea in one paragraph

Both APIs sit on the same kernel backbone, [[fsnotify-explained|fsnotify]], and differ in scope. **inotify** is like **a set of targeted cameras**: you point one at each file or directory you care about and read what happens to them from one descriptor. **fanotify** is **city-wide CCTV with a control room**: one mark can cover a whole mount or filesystem, and the control room can hold an event in progress (pausing the program doing it) until an operator says allow or deny.

## Step by step: inotify

### Step 1: Create an instance
One call creates an inotify instance (a notification group in the kernel) and returns a descriptor. All watches go through it. A newer variant of the call (2.6.27) takes close-on-exec and non-blocking flags directly.

### Step 2: Add watches
Adding a watch resolves a path to an inode and puts a mark on it for this instance, returning a small integer **watch descriptor**. If the inode is already watched by this instance, the same number is returned and the event mask updated, so re-adding during a rescan is harmless. Watch numbers are cheap integers, not open files, so they don't count against the open-file limit (the big improvement over dnotify). Limits: 8192 watches and 128 instances per user, 16384 queued events per instance, by default.

### Step 3: Receive events
When something happens to a watched file, the event is queued and any `read` or `poll` on the descriptor wakes up. Each event carries the watch number, the event type, an optional filename (for things inside a watched directory) and a **cookie**. A rename produces two events (moved-from in the old directory, moved-to in the new) with the same cookie so they can be paired. If only one half arrives in a read, programs typically wait a couple of milliseconds for the other before treating it as a half-rename.

### Step 4: Overflow and removal
If the queue fills, a special "overflow" event is delivered and later events are dropped. There's no way to get them back: the recommended recovery is to rebuild all watches and rescan. Removing a watch (or deleting or unmounting the watched file) produces an "ignored" event.

inotify doesn't say *which process* caused an event; that kept its kernel path minimal.

## Step by step: fanotify

### Step 5: Create a group with a class
When creating a fanotify group you choose its class: notification only, or permission events (before or at content access). Permission classes need admin rights. Options choose how files are identified in events (see step 8).

### Step 6: Mark at the right scope
A mark can cover one inode (like inotify), a **mount** (everything under that mount point), or a whole **filesystem** (everything on it, however it's mounted). A single filesystem mark replaces the millions of watches inotify would need for a 10-million-file tree. **Ignore masks** carve out exceptions, for example a backup tool watching a whole filesystem for changes but ignoring temp directories.

### Step 7: Permission events: pause, decide, resume
This is fanotify's defining feature. When a watched open or access happens, the kernel creates a permission event and puts the program doing it to sleep. The listener reads the event, inspects the file (through a descriptor in the event), and writes back **allow** or **deny**. The kernel wakes the program; on deny, its system call fails with "permission denied", or since 6.13, a custom error of the listener's choosing.

The sleep can be ended by a fatal signal but not by ordinary ones, so a crashing daemon can't hang processes forever, but normal signals don't sneak past the check. If the listener's descriptor is closed with events still pending, the kernel **allows** them all, so a daemon crash causes a brief unscanned window rather than baffling "permission denied" errors everywhere. That choice was debated.

### Step 8: How files are identified
Originally each event came with a freshly opened file descriptor for the file. That was expensive, a backlogged listener could exhaust the system's open-file limit, and the file could be renamed or deleted before the listener looked. Since 5.1, events can carry a **file handle** (filesystem ID plus handle), a stable identifier that doesn't hold the file open; the listener opens it by handle if it needs the contents. 5.9 added the parent directory's handle plus the name, enabling create/delete/move tracking. 5.15 added a process file descriptor instead of a raw PID, avoiding PID-reuse races.

## The picture

```text
 inotify                                   fanotify
 ───────                                   ────────
 instance fd                               group fd (class: notify / permission)
   watch 1 → /etc/hosts                      mark: whole filesystem /
   watch 2 → /home/me/project/                 ignore: /tmp
 read → {watch, type, cookie, name}        read → {type, pid, fd or file handle}
                                           permission event:
                                             program opens file → paused
                                             listener: allow / deny → program resumes / fails
```

## Tradeoffs

- **What it gives you:** inotify: cheap, precise watches on chosen paths. fanotify: whole-filesystem coverage with one call, process information, stable file handles, and real-time access control.
- **What it costs / requires:** inotify needs one watch per file or directory and drops events on overflow. fanotify's permission features need admin rights, and filesystem-wide marks give coarser filtering unless ignore masks are layered on.
- **Where it bites:** a slow permission listener slows every program touching watched files; one that stalls can block them until killed. An explicit kernel timeout was rejected; the privileged daemon is trusted to stay responsive.

## How it got here

- **2001 (2.4.0):** dnotify.
- **2005 (2.6.13):** inotify (John McCutchan and Robert Love), with dedicated system calls rather than overloading `fcntl` as dnotify did.
- **2.6.36–2.6.37 (2010–2011):** the shared fsnotify backbone, then fanotify (Eric Paris), whose permission events were put behind a separate build option and admin rights after concerns about hung listeners.
- **4.20 (2018):** filesystem-wide marks.
- **5.1–5.15 (2019–2021):** file handles in events (Amir Goldstein), directory-entry events, filesystem-error events, process file descriptors.
- **6.6–6.13 (2023–2024):** pre-access range events and custom error codes on deny.

## Related

- Technical version: [[inotify-and-fanotify]]
- [[fsnotify-explained|fsnotify]]: the shared backbone
- [[fs-explained|Filesystem subsystem (VFS)]], [[mount-namespace-explained|mount-namespace]]
- [[file-descriptor-and-open-file-table-explained|Descriptors and the open file table]]
- [[lsm-framework-explained|LSM framework]]
