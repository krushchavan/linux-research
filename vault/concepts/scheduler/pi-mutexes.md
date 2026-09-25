---
title: "PI Mutexes (Priority Inheritance)"
category: concept
tags: [scheduler, real-time, locking, priority-inversion, rt-mutex, futex]
subsystem: scheduler
kernel_version: "2.6.18"
researched: 2026-04-16
status: complete
explained: "[[pi-mutexes-explained]]"
sources:
  - https://kernel-internals.org/sched/pi-mutexes/
  - https://docs.kernel.org/locking/rt-mutex-design.html
  - https://docs.kernel.org/locking/rt-mutex.html
  - https://docs.kernel.org/locking/pi-futex.html
  - https://lwn.net/Articles/178253/
  - https://lwn.net/Articles/252716/
  - https://lwn.net/Articles/934114/
  - https://lwn.net/Articles/360699/
---

# PI Mutexes (Priority Inheritance)

> 📘 Plain-language version: [[pi-mutexes-explained]]

## Purpose

Under fixed-priority scheduling a high-priority task can be blocked indefinitely by a lower-priority lock holder that itself gets preempted by a medium-priority task — a scenario called **priority inversion**. PI mutexes prevent this by temporarily elevating the lock holder's priority to match the highest-priority waiter, ensuring the holder can preempt any interfering task and release the resource promptly. Without PI, real-time guarantees collapse the moment two tasks share even a single mutex.

## Mental Model

Imagine a highway with priority lanes: a VIP car (high-priority task H) is stuck behind a delivery truck (low-priority task L) that's parked in the VIP lane because L is waiting to pull into a loading bay (lock). A city bus (medium-priority task M) keeps cutting in front of L in normal traffic, so L never gets to the bay, and H stays stuck forever. Priority inheritance gives L a VIP pass until it finishes at the bay — M can no longer block it, L completes quickly, and H gets the lane back. The VIP pass (boosted priority) evaporates the instant L clears the bay.

## How It Works

### The Priority Inversion Problem

The canonical sequence: H blocks on a mutex held by L; M becomes runnable at a priority between H and L; M preempts L. Now L cannot run (M runs instead), so the mutex is never released, so H cannot run either. The kernel is technically correct — M outranks L — but the net effect is that H, with the highest priority of all three, cannot make progress. On a real-time system, this can mean a missed deadline or a watchdog reset (the Mars Pathfinder mission in 1997 suffered exactly this).

### rt_mutex: The Kernel Primitive

Linux implements PI through a dedicated structure `struct rt_mutex` (and the trimmed base `struct rt_mutex_base`), defined in `include/linux/rtmutex.h`. It differs from `struct mutex` in one critical way: it tracks its owner and maintains a priority-ordered waiters tree.

```c
struct rt_mutex_base {
    raw_spinlock_t   wait_lock;     /* protects all fields below */
    struct rb_root_cached waiters;  /* priority-sorted rbtree of blocked tasks */
    struct task_struct *owner;      /* current owner; LSB = HAS_WAITERS flag */
};
```

The `owner` field encodes two things at once: the high bits hold a pointer to the owning `task_struct` (guaranteed 4-byte aligned, so bits 0–1 are free), and bit 0 is the **HAS_WAITERS** flag. Setting this flag forces the unlock path through the slow path even if the release looks trivial, preventing a race where a concurrent chain-walk reads stale owner information.

### task_struct PI Fields

Every task carries four fields that form the PI state machine:

```c
/* in struct task_struct */
raw_spinlock_t          pi_lock;        /* protects all pi_* below */
struct rb_root_cached   pi_waiters;     /* top waiter of each mutex this task owns */
struct task_struct     *pi_top_task;    /* cached highest-priority pi_waiter */
struct rt_mutex_waiter *pi_blocked_on;  /* the waiter struct for lock this task waits on */
```

`pi_waiters` holds only the **top waiter** from each mutex the task owns, not every waiter of every mutex. This compression is important: computing the effective priority of a task only requires inspecting `pi_waiters.rb_leftmost` (the highest-priority entry), not iterating all downstream waiters. `pi_blocked_on` enables the chain walk — by following `pi_blocked_on` from one task to the next, the kernel can traverse the entire lock dependency graph.

### Lock Acquisition — Fast Path

`rt_mutex_lock()` in `kernel/locking/rtmutex.c` attempts a single `cmpxchg` on the owner field. If the mutex is free (owner == NULL), the caller atomically writes its own task pointer. No spinlocks, no waiter trees, no PI logic — the fast path is a single atomic instruction.

### Lock Acquisition — Slow Path

When the fast path fails (mutex is held or marked HAS_WAITERS), `rt_mutex_slowlock()` takes over:

1. **Allocate a waiter on stack**: `struct rt_mutex_waiter` is a stack-allocated object holding a pointer back to the task, the mutex, and two `rb_node` fields — one for the mutex's `waiters` tree, one for the owner's `pi_waiters` tree.

2. **Acquire `wait_lock`** on the mutex (a raw spinlock, so non-preemptible while held).

3. **Call `try_to_take_rt_mutex()`**: grants the lock if there is no owner *and* the calling task is the highest-priority waiter. The check for "highest-priority waiter" prevents a lower-priority task from stealing a lock from a higher-priority one that is also sleeping.

4. **If that fails, call `task_blocks_on_rt_mutex()`**:
   - Insert the new waiter into the mutex's `waiters` rbtree, ordered by priority (and FIFO within equal priorities).
   - If the new task becomes the new top waiter of this mutex, remove the old top waiter from the owner's `pi_waiters` tree and insert the new one.
   - Call `rt_mutex_adjust_prio()` on the owner to recompute its effective priority.
   - If the owner is itself blocked on another mutex (`pi_blocked_on != NULL`), call `rt_mutex_adjust_prio_chain()` to propagate the boost up the chain.
   - Set `current->pi_blocked_on` to the new waiter and call `schedule()` to sleep.

5. On wake-up, the task loops back and retries `try_to_take_rt_mutex()`. If a signal or timeout occurred and the lock was not acquired, the waiter is removed and `-EINTR`/`-ETIMEDOUT` is returned.

### The Heart of PI: rt_mutex_adjust_prio_chain()

This function in `kernel/locking/rtmutex.c` propagates a priority change up an arbitrary chain of blocked tasks and mutexes. Its signature captures the full state it needs:

```c
static int rt_mutex_adjust_prio_chain(
    struct task_struct     *task,      /* task whose priority just changed */
    enum rtmutex_chainwalk  chwalk,    /* detect deadlock? */
    struct rt_mutex_base   *orig_lock, /* lock task is blocked on */
    struct rt_mutex_base   *next_lock, /* lock at the tip of the chain */
    struct rt_mutex_waiter *orig_waiter,
    struct task_struct     *top_task); /* highest-priority task in the chain */
```

The algorithm walks upward one link at a time. At each step it holds **at most two locks** simultaneously (the current mutex's `wait_lock` and the next task's `pi_lock`), releases the lower one before acquiring the next, and checks whether priority actually changed before continuing — stopping early if the chain has already converged. This "at most two locks" discipline is not just an optimisation; it prevents the indefinite lock-order inversions that would occur if the walk held every lock it visited.

To guard against **deadlock** (cycles in the lock graph), the walk detects when it has reached `orig_lock` again. If so, it returns `-EDEADLK`, which the caller translates into a `EDEADLK` error for the blocked task. The check is optional (controlled by the `chwalk` flag) because in-kernel callers that cannot be in a cycle skip it for performance.

A secondary concern is **DoS protection**: a malicious task could construct a chain of depth 1000 to make every lock acquisition O(chain_length). The kernel limits chain walks to `MAX_LOCK_DEPTH` (48 as of 6.x) and returns `-EDEADLK` if exceeded — this prevents lock contention from becoming a CPU starvation attack.

### Lock Release

`rt_mutex_unlock()` fast-paths through a `cmpxchg` that clears the owner field only if HAS_WAITERS is clear. If HAS_WAITERS is set, `rt_mutex_slowunlock()`:

1. Acquires `wait_lock`.
2. Picks the highest-priority waiter from `waiters`.
3. Acquires that waiter's `pi_lock`, removes it from the owner's `pi_waiters` tree, and wakes the waiter.
4. Recomputes the owner's priority via `rt_mutex_adjust_prio()` — the owner's priority can now drop back toward `normal_prio` since its highest-priority waiter left.
5. The woken waiter races to claim the mutex in its retry loop.

### Userspace PI Mutexes: FUTEX_LOCK_PI

The rt_mutex infrastructure is exposed to userspace through two futex operations: `FUTEX_LOCK_PI` and `FUTEX_UNLOCK_PI`. A userspace PI mutex stores the owner's TID in 32 bits; bit 30 (`FUTEX_WAITERS`) signals kernel-managed contention.

The fast path is pure userspace: `cmpxchg(futex_addr, 0, tid)`. On failure, the kernel is called. The kernel locates (or creates) a `struct futex_pi_state` keyed to the futex address; this structure holds a `struct rt_mutex` that mirrors the userspace lock's contention state. The blocking task then calls `rt_mutex_lock()` on that embedded rt_mutex, triggering the same slow path described above — including full priority inheritance. This is how glibc implements `PTHREAD_MUTEX_PRIO_INHERIT` mutexes with zero overhead in the uncontended case.

`FUTEX_REQUEUE_PI` additionally allows a condition-variable wake (where waiters on a condvar must be moved to a PI mutex) to happen atomically in the kernel, avoiding a spurious priority drop between the requeue and the mutex acquisition.

### SCHED_DEADLINE Integration

When a `SCHED_DEADLINE` task H blocks on a mutex held by L, raw priority boosting is meaningless — deadline scheduling does not use priority numbers. Instead, the kernel installs a **deadline PI entity** on L: L temporarily gains a deadline-class scheduling entity that expires when H's deadline would expire. Until H's deadline, L can preempt every RT task. When the mutex is released, the borrowed entity is removed and L reverts to its own policy. This is called **DL_TASK_BOOSTED** — a flag in `task_struct.dl` that marks the entity as temporary.

### PREEMPT_RT Extension

The `PREEMPT_RT` patchset (increasingly merged in 6.x) replaces most kernel-internal spinlocks with `rt_mutex`-backed sleeping locks, called **rtspinlocks** or **rt_spinlocks**. This extends priority inheritance into the kernel itself, eliminating the last sources of unbounded latency from kernel code paths that CFS and RT tasks share. Under `PREEMPT_RT`, a task holding a kernel lock can be boosted by a high-priority task waiting on that same lock — just as in userspace PI. The infrastructure was already in `rt_mutex`; PREEMPT_RT simply widens its scope from PI-futex and kernel rt_mutex users to nearly all kernel locking.

## Key Data Structures

**`struct rt_mutex_base`** (`include/linux/rtmutex.h`) — the embedded core of every rt_mutex.
- `wait_lock` — raw spinlock protecting all mutable state; must be held to touch `waiters` or `owner`
- `waiters` — red-black tree of `rt_mutex_waiter` entries sorted by `(priority, FIFO sequence)`; leftmost node is the top waiter
- `owner` — task pointer with bit 0 as HAS_WAITERS; compare with `rt_mutex_owner()` which masks the flag bits

**`struct rt_mutex_waiter`** (`include/linux/rtmutex.h`) — stack-allocated per blocked task.
- `tree.entry` — node in the mutex's `waiters` rbtree
- `pi_tree.entry` — node in the owner's `pi_waiters` rbtree
- `task` — back-pointer to the blocked task
- `lock` — the rt_mutex this waiter is waiting on
- `wake_state` — the task state to restore on wake-up

**`struct futex_pi_state`** (`kernel/futex/pi.c`) — per-contended-futex kernel object.
- `rt_mutex` — the embedded rt_mutex that mirrors userspace lock contention
- `owner` — the current kernel-side owner (may differ from futex value during handoff)
- `list` — links multiple pi_state objects on the same task (one per PI futex owned)

## Key Functions / Entry Points

**`rt_mutex_lock()`** (`kernel/locking/rtmutex.c`) — public entry; tries fast path, falls back to `rt_mutex_slowlock()`.

**`rt_mutex_slowlock()`** (`kernel/locking/rtmutex.c`) — slow path: allocates waiter, calls `task_blocks_on_rt_mutex()`, sleeps in a retry loop.

**`task_blocks_on_rt_mutex()`** (`kernel/locking/rtmutex.c`) — links the waiter into both trees, boosts the owner, triggers chain walk if needed.

**`rt_mutex_adjust_prio_chain()`** (`kernel/locking/rtmutex.c`) — transitive priority propagation; walks upward at most `MAX_LOCK_DEPTH` hops with at most two locks held simultaneously.

**`rt_mutex_adjust_prio()`** (`kernel/locking/rtmutex.c`) — recomputes one task's effective priority from `normal_prio` and `pi_top_task`; calls `rt_mutex_setprio()` if a change is needed.

**`rt_mutex_setprio()`** (`kernel/locking/rtmutex.c`) — calls into the scheduler (`sched_setscheduler_nocheck()`) to apply the new effective priority; handles the SCHED_DEADLINE boosting case.

**`futex_lock_pi()`** (`kernel/futex/pi.c`) — kernel side of `FUTEX_LOCK_PI`; finds or creates `futex_pi_state`, calls `rt_mutex_lock()` on the embedded mutex.

## Important Flags & Config Options

**`CONFIG_RT_MUTEXES`** — Kconfig symbol that enables the rt_mutex subsystem; implicitly selected by `FUTEX`, `PREEMPT_RT`, and any driver using `rt_mutex_*` directly. Cannot be turned off in practice on any modern kernel.

**`CONFIG_DEBUG_RT_MUTEXES`** — Enables self-test locking correctness checks, deadlock detection in all contexts (not just when requested by caller), and `CONFIG_RT_MUTEX_TESTER` integration.

**`CONFIG_PREEMPT_RT`** — When set, replaces spinlocks in most kernel paths with rt_mutex-backed sleeping locks; extends PI to the full kernel lock graph.

**`/proc/sys/kernel/sched_rt_runtime_us`** / **`sched_rt_period_us`** — RT bandwidth throttle; a boosted task that runs under an inherited RT priority is subject to these limits just like a native RT task.

**`MAX_LOCK_DEPTH`** (48) — Compile-time cap on PI chain walk depth; `EDEADLK` is returned if exceeded.

## Interactions with Other Subsystems

- **↑ Userspace**: `FUTEX_LOCK_PI` / `FUTEX_UNLOCK_PI` syscalls; glibc uses these for `PTHREAD_MUTEX_PRIO_INHERIT`; the `FUTEX_REQUEUE_PI` operation supports PI-aware condition variables.
- **→ Scheduler**: `rt_mutex_setprio()` calls `sched_setscheduler_nocheck()` to change the task's scheduling class and priority in-flight; for SCHED_DEADLINE the borrowed deadline entity is managed via `dl_task_boosted`.
- **→ Locking**: `pi_lock` (a raw spinlock on `task_struct`) and `wait_lock` (a raw spinlock on each rt_mutex) are the primitives underpinning PI state changes; they must be taken in a strict order (innermost first: `wait_lock` before `pi_lock` of the **owner**, never the reverse).
- **← PREEMPT_RT**: The `PREEMPT_RT` patchset imports rt_mutex as the backing primitive for all kernel spinlocks, turning the entire kernel lock graph into a PI-eligible graph.
- **← Futex layer**: `struct futex_pi_state` embeds an `rt_mutex`; the futex subsystem is the dominant userspace consumer of PI.

## Design Decisions & Tradeoffs

**Why a separate rt_mutex instead of extending mutex?** Regular `struct mutex` is optimised for throughput: it has a simpler owner field, no priority trees, and no chain-walk logic. Merging PI into it would add overhead (extra pointer, two rbtree nodes) to every mutex in the kernel. The decision to keep rt_mutex separate means PI is opt-in and zero-cost for non-RT paths.

**Why store only the top waiter in pi_waiters?** A task can own many mutexes, each with many waiters. Storing all waiters of all mutexes in `pi_waiters` would make priority computation O(total waiters). Storing only the top waiter from each mutex keeps it O(number of mutexes owned), which is small in practice, and `pi_waiters.rb_leftmost` gives the effective priority in O(1).

**Why does Linus oppose PI in principle?** Torvalds argued that PI is "fundamentally broken in the general case" — it cannot handle all forms of priority inversion (e.g. those caused by CPU bandwidth, cache effects, or memory bus contention) and gives a false sense of correctness. The kernel's implementation is explicitly scoped to mutex-mediated inversions only, which is the tractable subset. For deadline scheduling, the proxy-execution approach (lending the full scheduling context, not just priority) is being developed as a more complete solution.

**The "at most two locks" invariant in the chain walk**: If the walk held every lock in the chain, acquiring them in order (bottom → top) would create a lock-order cycle with any other walk going top → bottom. The two-lock discipline eliminates this by releasing the lower lock before acquiring the next, at the cost of having to re-validate state after each step.

## How It Has Evolved

**2.6.18 (2006)**: First mainline appearance of rt_mutex and `FUTEX_LOCK_PI`, introduced by Ingo Molnar and Thomas Gleixner as part of the `-rt` realtime preemption patchset's incremental upstreaming. Linus initially opposed the approach but eventually accepted the limited, mutex-scoped implementation.

**2.6.19–2.6.28**: `FUTEX_REQUEUE_PI` added (Darren Hart, 2009), enabling PI-aware condition variables without a priority-drop window during the cond → mutex re-queue.

**4.x**: PI chain walk hardened against races introduced by `task_struct` recycling; the `orig_waiter` validation loop in `rt_mutex_adjust_prio_chain()` was tightened to detect mid-walk task-exit.

**5.x**: SCHED_DEADLINE boosting (DL_TASK_BOOSTED) integrated; a blocked DL task can now lend its deadline entity to a lower-priority lock holder.

**6.x onwards**: PREEMPT_RT patches progressively merged (CONFIG_PREEMPT_RT available since 6.1); rt_mutex now underlies `spinlock_t`, `rwlock_t`, and `semaphore` when RT is enabled, extending the PI graph kernel-wide. Proxy execution (full scheduling-context lending) is under active development as the long-term successor for the `SCHED_DEADLINE` cross-class inversion problem.

## Further Reading

1. [RT-mutex implementation design — kernel.org](https://docs.kernel.org/locking/rt-mutex-design.html) — the canonical reference; covers all data structures, chain-walk algorithm, and deadlock detection in detail
2. [Priority inheritance in the kernel — LWN.net (2006)](https://lwn.net/Articles/178253/) — the original introduction, including the political history of Linus's objections
3. [A futex overview and update — LWN.net](https://lwn.net/Articles/360699/) — covers FUTEX_LOCK_PI and FUTEX_REQUEUE_PI from a futex-layer perspective
4. [Addressing priority inversion with proxy execution — LWN.net (2023)](https://lwn.net/Articles/934114/) — next-generation approach; explains why PI alone is insufficient for SCHED_DEADLINE
5. [Lightweight PI-futexes — kernel.org](https://docs.kernel.org/locking/pi-futex.html) — userspace interface documentation
6. [What's in the realtime tree — LWN.net (2007)](https://lwn.net/Articles/252716/) — broader context of PREEMPT_RT and PI's role in it

## LKML Highlights

- **Introducing PI-futex** (`20060301131748.GD5587@laptop.programming.kicks-ass.net`): Ingo Molnar's cover letter for the original rt_mutex + FUTEX_LOCK_PI patch series; the thread captures Linus's pushback and the eventual agreement to accept the limited mutex-scope implementation.
- **Deadline PI crash fix** (`20170323150216.157682758@infradead.org`): Peter Zijlstra's patch series fixing a crash where a SCHED_DEADLINE task boosted through rt_mutex without the DL entity infrastructure in place; reveals the complexity of cross-class priority inheritance.
