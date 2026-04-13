---
title: "local_lock: Per-CPU Critical Sections"
category: concept
tags: [locking, per-cpu, local-lock, preempt-rt, synchronization, concurrency]
subsystem: locking
kernel_version: "5.8"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/locking/
  - https://www.kernel.org/doc/html/latest/locking/locktypes.html
  - https://lwn.net/Articles/828477/
---

# local_lock: Per-CPU Critical Sections

## Overview

`local_lock_t` provides named, Lockdep-visible critical sections for protecting **per-CPU data**. On non-RT kernels it compiles down to preemption or interrupt disabling, adding zero overhead over what the code would do anyway. On `PREEMPT_RT` kernels it becomes a genuine per-CPU `spinlock_t`, allowing the holder to be preempted by higher-priority tasks while still excluding concurrent access from other contexts on the same CPU.

## The Problem it Solves

Before `local_lock`, per-CPU data was protected with bare `preempt_disable()` / `local_irq_disable()` calls. These work correctly but have two drawbacks:

1. **No Lockdep visibility**: Lockdep cannot see what is being protected, so it cannot catch bugs like holding a sleeping lock while inside a disabled-preemption region.
2. **RT incompatibility**: On `PREEMPT_RT`, disabling preemption prevents the kernel from scheduling a higher-priority RT task, destroying latency guarantees. RT must be able to preempt even inside "critical sections".

`local_lock` was developed in the RT tree and merged into mainline in Linux 5.8, simultaneously solving both problems.

## How It Works

### Non-RT Kernel

`local_lock()` expands to `preempt_disable()`.
`local_lock_irq()` expands to `local_irq_disable()`.
`local_lock_irqsave(lock, flags)` expands to `local_irq_save(flags)`.

If `CONFIG_DEBUG_LOCK_ALLOC` is enabled, a `lockdep_map` embedded in `local_lock_t` is exercised, so Lockdep sees the acquisition even though no actual spinning or sleeping occurs.

### PREEMPT_RT Kernel

`local_lock_t` contains a per-CPU `spinlock_t`. Each per-CPU slot is a separate lock object. `local_lock()` acquires the per-CPU slot's spinlock (which on RT is an `rt_mutex`-backed sleeping lock). This means:

- The holder **can** be preempted by a higher-priority task.
- Other tasks cannot concurrently run on the same CPU and access the per-CPU variable (the lock is per-CPU, so tasks on other CPUs need their own copy anyway).
- Interrupt handlers still cannot preempt a `local_lock_irq()` holder because those variants disable interrupts even on RT.

### Declaration Pattern

```c
// In the .c file that owns the per-CPU data:
DEFINE_PER_CPU(struct foo, my_data);
static DEFINE_PER_CPU(local_lock_t, my_data_lock);

// At module_init or boot:
local_lock_init(&my_data_lock);

// Usage:
local_lock(&my_data_lock);
ptr = this_cpu_ptr(&my_data);
// ... modify *ptr ...
local_unlock(&my_data_lock);
```

The lock is scoped to the data it protects; each protected per-CPU variable should have its own `local_lock_t`. This naming makes the intent explicit and allows Lockdep to build separate dependency chains for separate per-CPU domains.

## Key Data Structures

`local_lock_t` (`include/linux/local_lock_internal.h`):

Non-RT (with lockdep):
```c
typedef struct {
    struct lockdep_map dep_map;
    struct task_struct *owner;  // for lockdep owner tracking
} local_lock_t;
```

PREEMPT_RT:
```c
typedef spinlock_t local_lock_t;  // per-CPU spinlock
```

## Key Functions

- `local_lock(lock)` / `local_unlock(lock)` — disable preemption (RT: acquire per-CPU spinlock)
- `local_lock_irq(lock)` / `local_unlock_irq(lock)` — disable IRQs + preemption
- `local_lock_irqsave(lock, flags)` / `local_unlock_irqrestore(lock, flags)` — IRQ flags save/restore
- `local_lock_init(lock)` — initialize (sets lockdep metadata)
- `local_trylock(lock)` — non-blocking; undefined on non-RT (always succeeds with preempt_disable)

## Relationship to spin_lock and preempt_disable

| Construct | Non-RT | PREEMPT_RT | Lockdep-visible |
|-----------|--------|-----------|-----------------|
| `preempt_disable()` | Disables preemption | Disables preemption | No |
| `spin_lock(l)` | qspinlock | rt_mutex | Yes |
| `local_lock(l)` | preempt_disable | per-CPU spinlock | Yes |
| `local_lock_irq(l)` | irq_disable | irq_disable | Yes |

`local_lock` is not a substitute for `spin_lock`: it only protects against concurrent access *on the same CPU*, not from other CPUs. Per-CPU data by definition has no other-CPU contention, so the per-CPU scope is correct and sufficient.

## Config & Flags

- `CONFIG_PREEMPT_RT` — enables per-CPU spinlock implementation
- `CONFIG_DEBUG_LOCK_ALLOC` — activates Lockdep instrumentation
- `CONFIG_LOCKDEP` — required for lock dependency tracking to work

## Further Reading

- [LWN: Local locks in the kernel](https://lwn.net/Articles/828477/) — motivation, design, PREEMPT_RT semantics
- [kernel.org: Lock types and rules](https://www.kernel.org/doc/html/latest/locking/locktypes.html) — comparison table including local_lock
