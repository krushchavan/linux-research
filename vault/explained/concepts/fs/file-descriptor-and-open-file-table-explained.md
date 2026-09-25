---
title: "File Descriptor and Open File Table — Explained"
category: explained
original: "[[file-descriptor-and-open-file-table]]"
subsystem: fs
tags: [explained, fs, file-descriptors, rcu, posix]
converted: 2026-09-25
---

# File descriptors and the open file table, explained

> Plain-language companion to [[file-descriptor-and-open-file-table|the technical note]]. Same facts, fewer identifiers.

## The problem

A program refers to an open file, socket or pipe by a small integer: 0, 1, 2, 3... POSIX attaches precise sharing rules to those numbers. After `dup`, two numbers share one file position. After `fork`, parent and child have separate number tables but still share positions (which is what makes pipelines like `ls | grep foo` work). Closing one number mustn't affect another. And every `read`, `write` or `close` has to turn a number into the kernel's open-file object, on every call, from possibly many threads at once, without becoming a bottleneck.

## The idea in one paragraph

Use three levels. The **descriptor** is just an index into a per-process table. The table slot points to an **open file description**, the kernel's per-`open` object holding the position, flags and operations. That in turn points to the **inode**, the file's permanent identity. `dup` makes two slots point at one open file; `fork` copies the table so both processes' slots point at the same open files; opening the same path twice makes two open files for one inode. Reading the table takes no lock at all; only changes to it do.

```text
 process A  fd 3 ──┐              process B  fd 5 ──┐
                   └──▶ [ open file: position, flags ] ◀──┘
                                    │
                                    ▼
                               [ inode ]  ◀── another open of the same path
```

## Step by step

### Step 1: The per-process table
Each process points at a descriptor table object. Threads created with shared files point at the *same* one (a reference count says how many share it). The first 64 slots, and their bitmaps, are built into the object itself, so most processes never need an extra allocation. When a process opens its 65th file, a bigger table is allocated and swapped in, while anyone still reading the old one finishes safely.

The table holds the slot array plus bitmaps: which slots are open, which are marked **close-on-exec**, and a second-level bitmap marking which 64-slot blocks are completely full, so allocation can skip whole blocks. That turns a scan over thousands of descriptors into a much shorter one.

### Step 2: Hand out the lowest free number
POSIX requires the **lowest unused** descriptor. The kernel takes the table's lock, starts from a remembered hint, skips full blocks, finds the first free slot, marks it (and marks close-on-exec if requested), and returns it. If the table is full, it grows, up to a system limit.

This rule is predictable (close fd 3, and the next open gets 3; the classic trick of closing stdin and reopening relies on it), but it has costs:
- **Security:** if a privileged program is started with 0, 1 or 2 closed, its next `open` lands on one of them, and error output might go into a sensitive file. glibc and OpenBSD fill those slots with `/dev/null` before running setuid programs.
- **Scalability:** every thread allocating descriptors takes the same lock, so parallel `accept` on a busy server serialises.

### Step 3: Publish the open file
Once the open file object is ready, it's placed into its slot with a memory barrier, so other threads can never see a half-initialised object.

### Step 4: Look it up, on every system call
This is the key step. Every descriptor-using system call starts by turning the number into the open file. The lookup runs under RCU and **takes no lock**: read the table pointer, read the slot, and bump the object's reference count, but only if it isn't already zero. That last check prevents using an object another thread has just released.

A further shortcut: if the process's table isn't shared with other threads, nobody else can close the descriptor during this system call, so even the reference-count bump is skipped and the reference is simply "borrowed". A small flag remembers which way it was done so the release matches. With a shared table, it falls back to taking a real reference.

### Step 5: Close
Under the lock, the slot's bit is cleared, the pointer removed, and the hint moved back so this number is reused first. Then the file's **flush** hook runs (once per descriptor; NFS uses it to write back dirty data when any descriptor closes) and the reference is dropped. Only when the *last* reference goes does the **release** hook run and the object get freed.

### Step 6: fork, threads, dup
- **fork:** the child gets a new table, a copy of the parent's, with each open file's reference count bumped. Separate tables, shared open files, so shared positions. Closing in the child doesn't affect the parent.
- **threads with shared files:** no copy at all; everyone uses the same table, so an open or close in one thread is instantly visible to all.
- **dup / dup2:** another slot pointing at the same open file. `dup2` first closes the target number if needed, then atomically replaces it.

### Step 7: Close-on-exec
Descriptors marked close-on-exec are closed automatically just before `exec` loads a new program, so sensitive sockets and log files don't leak into it. Setting the mark *at open time* is atomic; setting it afterwards with `fcntl` leaves a window in which another thread could `fork` and `exec` and inherit the descriptor. That race is why atomic close-on-exec flags were added (Ulrich Drepper, 2006).

### Step 8: Readers never lock
Writers (install, close, grow) take the table's lock and publish changes RCU-style; an old table is freed only after all readers are done with it. Readers never take the lock. One subtlety: code that drops and retakes the lock must reload the table pointer, since it may have been replaced.

## The picture

```text
 descriptor table (per process, shared by threads)
   bitmaps: open ▣▣▣▢▣▢...   close-on-exec ▢▣▢▢...   full-blocks ▣▢...
   slots:   0 → stdin  1 → stdout  2 → stderr  3 → [open file] ...

 open():  lock → lowest free slot → mark → publish pointer → unlock
 read(3): RCU: slot 3 → open file → ref++ (skipped if table unshared) → I/O
 close(3): lock → clear slot → unlock → flush → drop ref → last ref? release
```

## Tradeoffs

- **What it gives you:** exact POSIX sharing semantics, lock-free lookups on the hottest path, and no allocation for small processes.
- **What it costs / requires:** 64 slots' worth of space in every table even for tiny processes; a single lock for allocation and closing.
- **Where it bites:** the lowest-free-number rule serialises descriptor allocation under heavy parallelism and has security pitfalls. The "borrowed reference" shortcut historically caused descriptor leaks and use-after-free bugs, which prompted the 2024 redesign.

## How it got here

- **Before 2.6:** one lock taken on every descriptor lookup; multi-threaded programs serialised on it.
- **2.6.3 (2004):** lock-free lookups using RCU (Nick Piggin), 13–21% faster on a multi-core benchmark.
- **2.6.12 (2005):** skipping the reference count for unshared tables.
- **3.x:** the second-level "full blocks" bitmap.
- **5.x:** reuse the most recently freed number first.
- **6.9 (2024):** Al Viro's redesign of the borrowed-reference handle with automatic, compiler-enforced cleanup, after auditing about 160 call sites and finding two real leaks and several use-after-free patterns.

## Related

- Technical version: [[file-descriptor-and-open-file-table]]
- [[file-object-explained|file-object]]: the open file description itself
- [[core-in-memory-structures-explained|Core VFS objects]], [[fs-explained|Filesystem subsystem (VFS)]]
- [[path-lookup]], [[vfs-locking-model]]
- [[registered-resources-explained|io_uring registered files]]: skipping this lookup entirely
- [[rcu-read-copy-update|RCU]]
