---
title: "fsnotify — Explained"
category: explained
original: "[[fsnotify]]"
subsystem: fs
tags: [explained, fs, fsnotify, inotify, fanotify]
converted: 2026-09-25
---

# fsnotify, explained

> Plain-language companion to [[fsnotify|the technical note]]. Same facts, fewer identifiers.

## The problem

Many programs want to know when files change: editors reloading a file, build tools, desktop file browsers, backup agents, anti-virus scanners. Linux grew three separate ways to ask: dnotify, then inotify, then fanotify. Each originally had its own hooks into the filesystem code, its own locking and its own event queues.

Whatever the mechanism, it sits in the hottest paths there are (every open, read, write and create), so it must cost essentially nothing for files nobody is watching. And anti-virus scanners want something even harder: to *pause* a program opening a file until the scanner says yes or no.

## The idea in one paragraph

fsnotify is the shared backbone under all three APIs, built on three ideas. A **mark** is a sticky note on a filesystem object (a file, a mount, or a whole filesystem) saying "tell group G about events matching these types". A **group** is a subscriber, one open inotify or fanotify descriptor, with its own queue and its own handling functions. An **event** is generated at fixed hook points in VFS; fsnotify finds the matching marks and hands the event to each interested group. Each user-facing API is just a group implementation on top.

## Step by step

### Step 1: Hooks in the filesystem code
VFS calls small notification helpers at fixed points: open, read, write, close (split into "was open for writing" and "wasn't"), attribute change, create, mkdir, rename (as a "moved from" and "moved to" pair), delete and hard link. Each one builds an event description and calls the core dispatcher.

### Step 2: Near-zero cost when nobody's watching
This is the key performance trick. Each inode keeps a cached summary: the combined set of event types that *any* mark on it cares about. The hook checks one bit there first; if it's not set, it returns immediately with no list walking. Objects never watched store only an empty pointer, no mark structures.

### Step 3: Marks are attached through a connector
The first mark on an object allocates a small connector holding the list of marks on that object (inode, mount or superblock). Adding a mark (an inotify watch, a fanotify mark) attaches it to the connector and updates the cached summary; removing the last one frees the connector.

### Step 4: Dispatch
When an event fires, fsnotify gathers the marks on three levels (the inode, the mount it was accessed through, and the whole filesystem) and, for each group whose marks match, calls that group's event handler. This walk is done under **sleepable RCU**: many CPUs can deliver events concurrently, and a handler is allowed to sleep. That's essential for fanotify permission events, which may wait seconds for an answer; ordinary RCU wouldn't allow sleeping, and a mutex would serialise all event delivery system-wide.

### Step 5: inotify on top
An inotify instance is a group. Adding a watch puts a mark on one inode and returns a small watch number. Events are queued, and the program reads them from its descriptor. Removing a watch queues an "ignored" event. Limits cap watches per user (8192 by default) and queued events (16384 by default); overflowing the queue produces a special overflow event.

### Step 6: fanotify's extras
fanotify is also a group, but adds two powerful features:
- **Permission events:** on an open or access being watched this way, the kernel **pauses** the process doing it (in a killable sleep) until the listener reads the event and writes back allow or deny. This powers on-access malware scanners and data-loss-prevention tools. It requires admin rights and a separate build option.
- **Mount- and filesystem-wide marks:** one mark covers everything on a mount or filesystem, instead of registering a watch on every file as inotify needs for big trees. The cost is coarser filtering: excluding subtrees needs per-inode "ignore" marks.

Later versions report events with a stable **file handle** (filesystem ID plus handle) instead of an open descriptor per event, which is cheaper and avoids races; add directory-entry events with parent and name; and add filesystem-error events for monitoring corruption.

### Step 7: dnotify, the legacy one
The oldest API watches directories and signals the process. It's kept for compatibility.

### Step 8: Security and namespaces
Security modules can filter notifications so watching doesn't leak information across security domains. Mount-level marks belong to a particular mount, so two namespaces mounting the same filesystem can have independent mount watches.

## The picture

```text
 VFS op (write to /data/a.txt)
     │ hook: inode's cached event summary includes "modify"? ── no → return
     │ yes
     ▼
 marks on: inode a.txt │ mount /data │ whole filesystem
     │ (sleepable RCU)
     ▼
 group: inotify fd 5 → queue event → program reads it
 group: fanotify fd 7 → permission event? → pause writer → daemon: allow/deny → resume
```

## Tradeoffs

- **What it gives you:** one framework for every notification API, almost no cost on unwatched files, filesystem-wide watching, and real-time access control.
- **What it costs / requires:** marks, connectors and queues for watched objects; per-user limits to prevent abuse.
- **Where it bites:** a permission-event listener that crashes or stalls can hang every program that opens watched files. A timeout was debated at length and not kept in mainline; instead privileged listeners are responsible for staying responsive, with options for unlimited queues and non-blocking use. inotify's per-file watches scale poorly to huge trees.

## How it got here

- **2.4.0 (2001):** dnotify, directories only, via signals.
- **2.6.13 (2005):** inotify, descriptor-based, files and directories.
- **2.6.36 (2010):** fsnotify unified backend (Eric Paris); the work required auditing 40+ hook sites to keep each API's behaviour.
- **2.6.37:** fanotify with permission events and mount marks, after arguments (notably from Al Viro) about blocking processes on an unresponsive daemon; permission events were put behind a separate option and admin rights.
- **4.20 (2018):** filesystem-wide marks.
- **5.1–5.13:** events carrying file handles (Amir Goldstein), directory-entry events with names, and filesystem-error events.

## Related

- Technical version: [[fsnotify]]
- [[inotify-and-fanotify-explained|inotify-and-fanotify]]: the user-facing APIs in more detail
- [[fs-explained|Filesystem subsystem (VFS)]]
- [[inode-explained|inode]], [[mount-namespace-explained|mount-namespace]], [[lsm-framework-explained|LSM framework]]
- [[rcu-read-copy-update-explained|RCU]]
