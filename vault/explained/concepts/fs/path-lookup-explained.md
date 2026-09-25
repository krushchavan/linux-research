---
title: "Path Lookup (namei) — Explained"
category: explained
original: "[[path-lookup]]"
subsystem: fs
tags: [explained, fs, path-lookup, rcu-walk, symlinks]
converted: 2026-09-25
---

# Path lookup (namei), explained

> Plain-language companion to [[path-lookup|the technical note]]. Same facts, fewer identifiers.

## The problem

Every system call that takes a file name (`open`, `stat`, `execve`, `mkdir`, `rename`, `unlink`, `mount`) must turn a string like `/usr/lib/libc.so.6` into the kernel's directory entry and inode. Along the way it has to check permissions on every directory, cross into mounted filesystems, follow symlinks, handle `.` and `..`, and cope with other processes renaming things at the same moment.

This happens constantly, on every core. If each step took locks and bumped reference counts on shared directory entries, many threads looking up files in the same directory would fight over the same cache lines, and filesystem performance would stop scaling.

## The idea in one paragraph

Walk the tree **one component at a time**, starting from `/` or the current directory. And walk it in two modes: **try quickly and check; if that fails, try slowly**. The fast mode, **RCU-walk**, takes no locks and writes nothing to shared memory; it just reads, and checks sequence counters afterwards to confirm nothing changed. If anything goes wrong (a cache miss, a concurrent rename, something that needs to sleep), it switches to **ref-walk**, which takes locks and references the conventional way.

## Step by step

### Step 1: Set up a walk cursor
Each lookup keeps a small cursor on the stack: the current position (mount + directory entry), the next component, the effective root, sequence counter samples for the fast mode, a count of symlinks followed, and a stack of saved positions for symlinks. Absolute paths start at the process's root; relative ones at its current directory or at a directory given by descriptor.

### Step 2: For each component, in RCU-walk
Holding only an RCU read lock:
1. **check permission** to search the current directory. If that would need a lock or to sleep, give up on the fast mode.
2. **cut out the next name** and compute its hash; spot `.`, `..` and empty components.
3. **handle it**: `.` means stay; `..` means go to the parent (read the parent pointer, then check the sequence counter; at the top of a mount, step back into the covering mount, checking the global mount sequence counter); a normal name goes to the fast cache lookup.

### Step 3: Fast cache lookup
Look the name up in the dentry cache's hash table using only RCU, take a snapshot of the entry's sequence counter, and read its inode. Network filesystems may need to revalidate the entry. Then confirm the sequence counter hasn't changed; if it has, a rename or removal raced with us and the fast walk bails out.

This is the key point: throughout, the walk has **written nothing shared**, no reference counts and no locks. On a 32-core machine, 32 threads looking up files in the same directory proceed in parallel with no cache-line bouncing. The check is per entry, so renaming `/a/b` doesn't disturb a lookup of `/x/y/z`.

### Step 4: Crossing mount points
If the entry has something mounted on it, the walk looks up the mount in the mount hash table under RCU and validates against the global mount sequence counter sampled at the start. Mounts change rarely, so one coarse counter is good enough; a change just forces the slow mode.

### Step 5: Falling back to ref-walk
When the fast mode can't continue, it signals a special internal error ("try again slowly"). The walk then takes real references on its current position and mounts, leaves RCU mode, and carries on with locks and reference counts. Both modes share most of their code; the fallback signal just bubbles up to the loop that retries.

### Step 6: Cache miss: ask the filesystem
If the name isn't cached, the walk takes the directory's lock in shared mode, checks the cache again (someone may have just added it), and if still missing asks the filesystem to look it up, from disk or the server, and caches the result. If two threads miss on the same name at once, the second finds the first's in-progress entry and waits, so the lookup is done only once.

### Step 7: Symlinks, without recursion
When a component is a symlink to be followed, the walk saves the rest of the path on an explicit **symlink stack** and restarts from the link's target, instead of calling itself recursively. Since 4.2 (Neil Brown) this bounds kernel stack use however deep the links go. Short symlinks stored inside the inode can be followed in fast mode; ones stored in the page cache may need I/O, so they force the slow mode. The total is capped at **40** symlinks per lookup, less to catch loops than to stop crafted trees from burning unbounded CPU. Special "magic links" such as `/proc/<pid>/fd/N` can jump to anywhere, across filesystems and namespaces.

### Step 8: The last component is special
The main loop handles every component *except the last*. What happens to the last depends on the call:
- `stat`, `access`, `chdir`: look it up (respecting trailing slashes and whether to follow a final symlink)
- `mkdir`, `unlink`, `rename`, `link`: return the parent directory and the final name, without looking it up
- `open`: handle "create if missing" atomically, in one round trip where the filesystem supports it (useful for NFS)

### Step 9: Restricted lookups for sandboxes
`openat2` (5.6) lets programs restrict a lookup: no symlinks, no magic links, no crossing mounts, never escape the starting directory with `..`, or treat the starting directory as the root. Container runtimes use these to open files inside a container safely. The kernel watches the rename and mount sequence counters to detect a racing rename that tries to move a directory outside the boundary mid-walk.

## The picture

```text
 "/usr/lib/libc.so.6"
  start at /  ──▶ "usr" ──▶ "lib" ──▶ (last) "libc.so.6"
                RCU: hash lookup, read, check seq counter (no writes)
                  │ mount here? → follow mount (check mount seq)
                  │ symlink?   → push rest on stack, walk target
                  │ miss / changed / must sleep?
                  ▼
             ref-walk: take refs + locks, ask filesystem, cache result, continue
 last component: lookup │ parent + name │ open/create atomically
```

## Tradeoffs

- **What it gives you:** path lookup that scales across many cores, safe symlink handling, and sandbox-friendly restrictions.
- **What it costs / requires:** considerable complexity: every fast-mode step has to be safe against concurrent changes, and fallbacks must hand over cleanly.
- **Where it bites:** changes to the mount table force fallbacks for everyone mid-walk, and filesystems that need revalidation (NFS, CIFS) or store symlinks in the page cache fall out of the fast path more often.

## How it got here

- **2.4:** one global dentry lock serialised all lookups.
- **2.6.28 (2008):** an early "store-free path walking" prototype (Nick Piggin), not merged.
- **2.6.38 (2011):** RCU-walk merged (Nick Piggin's 46-patch series), with per-entry sequence counters and the mount sequence lock.
- **3.1 (2011):** a combined lock-and-count for dentries.
- **4.2 (2015):** non-recursive symlink following and a new symlink-reading interface that works in fast mode for inode-stored links (Neil Brown).
- **5.6 (2020):** `openat2` restriction flags (Aleksa Sarai), motivated by container runtimes. **5.8:** a "must not block" lookup mode for io_uring and other asynchronous users.

## Related

- Technical version: [[path-lookup]]
- [[dentry-explained|Dentries]], [[dentry-cache-explained|Dentry cache]]
- [[mount-namespace-explained|Mount namespaces]]: crossing mount points
- [[file-object-explained|File object]]: what `open` produces at the end
- [[filesystem-registration-explained|Filesystem registration]], [[inode]]
- [[fs-explained|Filesystem subsystem (VFS)]], [[rcu-read-copy-update-explained|RCU]], [[seqlocks-and-memory-barriers-explained|Sequence locks]]
