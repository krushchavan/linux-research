---
title: "Lockdep: Runtime Locking Correctness Validator"
category: concept
tags: [locking, lockdep, debugging, deadlock, dependency-graph, concurrency]
subsystem: locking
kernel_version: "2.6.18"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/locking/
  - https://www.kernel.org/doc/html/latest/locking/lockdep-design.html
  - https://www.kernel.org/doc/html/latest/locking/locktypes.html
---

# Lockdep: Runtime Locking Correctness Validator

## Overview

Lockdep is a kernel runtime validator that detects potential deadlocks and lock ordering violations at the first occurrence, long before an actual deadlock manifests in production. It was introduced by Ingo Molnar in Linux 2.6.18 (2006) and remains the primary tool for catching lock bugs during development and testing. Lockdep operates on **lock classes** — types of locks rather than individual instances — and tracks how classes depend on each other.

## How It Works

### Lock Classes

The key insight enabling Lockdep to scale is that it does not track individual lock instances. A production kernel might have millions of live `inode` objects each with their own `i_rwsem`, but all of those semaphores belong to one lock class: "inode i_rwsem". Lockdep maintains a global hash table of `lock_class` structures, one per unique `(lock_type, subclass)` pair, rather than one per lock instance.

Classes are identified by a static `lock_class_key` — a zero-initialized global variable placed by the compiler in a dedicated ELF section. When `mutex_init()` or `spin_lock_init()` is called, the lock registers itself against the class key. Lockdep maps the address of the class key to a `lock_class` entry.

### Dependency Graph

When task T acquires lock B while already holding lock A, Lockdep records the directed edge `A → B` (meaning "B was acquired while A was held"). If a path `B → … → A` already exists in the graph, a cycle is detected — this would be a potential deadlock if two CPUs ran the acquisition sequence in reverse order. Lockdep reports the cycle immediately via a kernel warning or BUG, including the full stack trace and the sequence of locks held.

Edges are typed based on whether the acquirer is a reader or exclusive locker, producing four edge types:

- `-(ER)->` Exclusive → Recursive-reader
- `-(EN)->` Exclusive → Non-recursive locker
- `-(SR)->` Shared-reader → Recursive-reader
- `-(SN)->` Shared-reader → Non-recursive locker

**Strong paths** — chains that do not contain two consecutive `-(xR)->-(Sx)->` transitions — correspond to real deadlock risks when they form cycles. Lockdep only checks strong paths when validating new edges.

### IRQ-Safety Rules

Beyond cycle detection, Lockdep enforces IRQ-context consistency. Each lock class accumulates a **usage bitmask** recording the contexts in which it has been acquired:

- `hardirq-safe`: acquired inside a hard IRQ handler (IRQs were disabled at entry)
- `hardirq-unsafe`: acquired with hard IRQs enabled
- `softirq-safe` / `softirq-unsafe`: same for softirq context

A lock class cannot be both `hardirq-safe` and `hardirq-unsafe` — that would mean it is sometimes acquired in IRQ context and sometimes with IRQs enabled, creating the classic "interrupt preempts lock holder" deadlock. Lockdep flags this the first time it observes the inconsistency, even if no such deadlock has ever occurred.

The printed splat encodes these states with single characters after the lock name. For example, `[mutex_name]{+.+.}` means the mutex has been acquired with IRQs enabled (`+`) in two different state dimensions.

### Lock Chains and Caching

A **lock chain** is the full ordered set of locks held simultaneously at the moment of an acquisition. Lockdep hashes the chain to a 64-bit value and caches whether it has been validated. On subsequent acquisitions of the same chain (same set of locks in the same order), the cached result is used — no graph traversal. This reduces the worst-case overhead from O(N²) to O(1) for repeated patterns.

The default maximum number of lock classes is 8,191. Exceeding this typically indicates a module loading/unloading bug where new classes are created but old ones are never freed (modules re-register their locks on each load). The count can be monitored via `/proc/lockdep_stats`.

### Developer Annotations

- `lockdep_assert_held(lock)` — triggers a warning if the current task does *not* hold `lock`; used to document and enforce "caller must hold X" preconditions.
- `lockdep_assert_held_read(rwsem)` — asserts at least a read lock is held.
- `lockdep_pin_lock(lock)` / `lockdep_unpin_lock(lock)` — marks a lock as "pinned"; Lockdep warns if the lock is released between pin and unpin, catching accidental unlock-inside-callback bugs.
- `lockdep_set_subclass(lock, subclass)` — splits a single lock type into multiple classes (e.g., to teach Lockdep that inode locks acquired at different directory-tree depths are distinct classes and their nesting is intentional).

## Key Data Structures

`struct lock_class` (`include/linux/lockdep_types.h`):
```c
struct lock_class {
    struct hlist_node   hash_entry;    // in global class hash table
    struct list_head    lock_entry;    // in all_lock_classes list
    struct list_head    locks_after;   // outgoing dependency edges (B after A)
    struct list_head    locks_before;  // incoming dependency edges
    const struct lockdep_subclass_key *key;
    unsigned int        subclass;
    unsigned long       usage_mask;    // IRQ context usage bitmask
    const char          *name;         // human-readable (e.g., "&inode->i_rwsem")
};
```

`struct held_lock` (per-task stack entry, in `task_struct.held_locks[]`):
```c
struct held_lock {
    u64         prev_chain_key;   // hash of the chain before this lock
    unsigned long acquire_ip;     // instruction pointer at lock_acquire()
    struct lockdep_map *instance; // points back to the lock's dep_map
    unsigned int irq_context;     // IRQ context at acquisition time
    unsigned int trylock:1;       // acquired via trylock?
    unsigned int read:2;          // 0=write, 1=read, 2=recursive read
    unsigned int check:1;         // whether to validate this acquisition
    unsigned int hardirqs_off:1;  // were hardirqs disabled at acquisition?
};
```

## Key Functions

- `lockdep_init_map(map, name, key, subclass)` — registers a lock with its class; called by `mutex_init()`, `spin_lock_init()`, etc.
- `lock_acquire(map, subclass, trylock, read, check, nest_lock, ip)` — hook called on every lock acquisition; updates held_locks, validates chain
- `lock_release(map, ip)` — hook called on every unlock; pops from held_locks
- `check_noncircular()` — traverses the dependency graph looking for a path back to the current lock
- `mark_lock()` — updates `usage_mask` and validates IRQ-safety rules
- `print_circular_bug()` — formats and prints the deadlock splat

## Output Interpretation

A Lockdep splat looks like:
```
WARNING: possible circular locking dependency detected
task/pid is trying to acquire lock:
  (lockA){+.+.}, at: some_function+0x40/0x80

but task is already holding:
  (lockB){....}, at: other_function+0x20/0x60

which lock already depends on the new lock.
...
Chain exists of: lockA --> lockC --> lockB
```

The `{+.+.}` notation encodes usage in 4 contexts (hardirq read, hardirq write, softirq read, softirq write). `+` = acquired with that context enabled, `-` = acquired with it disabled, `.` = never used in that context.

## Overhead and Production Use

Lockdep is not intended for production: it adds ~10–30% overhead due to graph traversal and the per-lock-acquisition hook. It is enabled for kernel CI (0-day, syzbot), developer builds, and distro debug kernels. Detected violations are typically caught during automated fuzzing long before they could cause a production deadlock.

## Config & Flags

- `CONFIG_PROVE_LOCKING` — enables Lockdep (selects `CONFIG_DEBUG_LOCK_ALLOC`, `CONFIG_LOCK_STAT`)
- `CONFIG_DEBUG_LOCK_ALLOC` — validates lock lifecycle (no use-after-free, no init-while-held)
- `CONFIG_LOCK_STAT` — per-class contention counters visible in `/proc/lock_stat`
- `/proc/lockdep` — list of all known lock classes and their dependency edges
- `/proc/lockdep_stats` — counters: lock_classes used, chains validated, etc.

## Further Reading

- [kernel.org: Lockdep design](https://www.kernel.org/doc/html/latest/locking/lockdep-design.html)
- [LWN: Runtime locking correctness validator](https://lwn.net/Articles/185666/) — original announcement article
