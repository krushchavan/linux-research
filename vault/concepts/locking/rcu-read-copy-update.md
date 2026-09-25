---
title: "RCU: Read-Copy-Update"
category: concept
tags: [rcu, locking, synchronization, concurrency, memory-ordering]
subsystem: locking
kernel_version: "2.5.43"
researched: 2026-04-06
status: complete
explained: "[[rcu-read-copy-update-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/RCU/whatisRCU.html
  - https://www.kernel.org/doc/html/latest/RCU/Design/Requirements/Requirements.html
  - https://www.kernel.org/doc/html/latest/RCU/Design/Data-Structures/Data-Structures.html
  - https://www.kernel.org/doc/html/latest/RCU/rcubarrier.html
  - https://lwn.net/Articles/262464/
  - https://lwn.net/Articles/777036/
  - https://lwn.net/Articles/305782/
---

# RCU: Read-Copy-Update

> 📘 Plain-language version: [[rcu-read-copy-update-explained]]

## Purpose

RCU is a synchronization mechanism optimized for read-heavy data structures. Without it, protecting a linked list or pointer-based structure under concurrent modification requires either a rwlock (which serializes all writers and delays reads during updates) or reference counting (which writes to shared cache lines on every read, destroying cache locality). RCU eliminates reader overhead entirely by deferring the destruction of old data until all readers that could possibly hold a reference have finished — readers never block, never write shared state, and on non-preemptible kernels pay literally zero cost to enter a critical section.

## Mental Model

Think of a city directory printed on paper. When an address changes, the city doesn't snatch the directory from everyone's hands — instead it prints a new edition, distributes it, and shreds the old one only after enough time has passed that everyone has finished consulting the old copy. RCU works the same way: writers publish a new version atomically, then wait for a *grace period* (a window long enough that all readers of the old version are guaranteed to have finished) before freeing the old data. Readers never need to know an update happened.

## How It Works

### Readers: zero-cost critical sections

A reader enters an RCU critical section with `rcu_read_lock()` and exits with `rcu_read_unlock()`. On a non-preemptible kernel (`CONFIG_PREEMPT=n`) these compile to *nothing* — not even a memory barrier — because the absence of preemption itself is the guarantee: a task in a critical section cannot be switched away, so any context switch on a CPU proves that CPU is no longer in any prior reader critical section. On preemptible kernels (`CONFIG_PREEMPT_RCU`) the pair increments and decrements a per-task nesting counter instead, which is cheap but not zero.

Inside the critical section, the reader fetches the protected pointer with `rcu_dereference(ptr)`. This is not just a load — it emits a data-dependency barrier (a compiler barrier on most architectures, an actual `smp_read_barrier_depends()` on Alpha) that prevents the compiler or CPU from speculating the pointer's target before the pointer value is known. Without this, an out-of-order CPU could begin reading fields of the struct before the pointer itself arrives from memory, seeing garbage.

### Writers: copy, modify, publish, then defer free

A writer that needs to update an RCU-protected structure never modifies the live object in place. Instead it:

1. **Copies** — allocates a new version of the data structure and fills it with the desired new values.
2. **Publishes** — stores the new pointer atomically with `rcu_assign_pointer(ptr, new_val)`. This macro includes a `smp_wmb()` (store-release on modern architectures) so that any CPU that subsequently loads the pointer via `rcu_dereference()` will see all the fields initialized before the pointer went live. This is the *publish-subscribe* guarantee.
3. **Defers freeing** — calls either `synchronize_rcu()` (which blocks the calling thread) or `call_rcu(&old->rcu_head, my_callback)` (which queues a callback) to arrange for the old structure to be freed after the current grace period ends.

The old structure is now unreachable from new readers (who see the updated pointer) but may still be referenced by readers that loaded the old pointer before the publish. The writer must not touch the old structure again until the grace period has elapsed.

### Grace periods: quiescent states and the combining tree

A **grace period** is defined as: a time interval long enough that every CPU has passed through at least one **quiescent state** — a point where it cannot possibly be inside an RCU read-side critical section that started before the grace period began.

For classic RCU, quiescent states are:
- A context switch (only possible when not in a critical section on non-preemptible kernels)
- Entry to user space
- Entry to the idle loop
- An offline CPU (which can't be executing anything)

The RCU core, running as a per-CPU softirq and kthread (`rcu_gp_kthread`), tracks quiescent-state reports from every CPU using a **hierarchical combining tree** of `rcu_node` structures. This tree was introduced in Linux 2.6.29 to replace a flat global lock that caused catastrophic contention on large SMP systems (with 1024 CPUs all trying to clear a single bitmask).

The tree is rooted at `rcu_state.node[0]`. Each leaf `rcu_node` covers a small fanout of CPUs (16 by default); non-leaf nodes cover 64 children on 64-bit systems. When a CPU reaches a quiescent state it clears its bit in its leaf node's `qsmask`. When the last CPU clears a node's mask, the node itself clears its bit in its parent — propagation continues until the root is cleared, at which point the grace period is complete. A 4096-CPU system needs only ~64 CPUs to contend for any single `rcu_node` lock instead of all 4096 contending for one.

Each CPU has a `rcu_data` per-CPU structure (`kernel/rcu/tree.h`) that acts as the interface between the CPU and its leaf `rcu_node`. It tracks:
- `gp_seq` / `gp_seq_needed` — local copy of the grace-period sequence number, to detect when callbacks become eligible for invocation
- `rcu_segcblist cblist` — a segmented callback list with four queues:
  - `RCU_DONE_TAIL`: ready to invoke now
  - `RCU_WAIT_TAIL`: waiting for the grace period currently in progress
  - `RCU_NEXT_READY_TAIL`: waiting for the *next* grace period
  - `RCU_NEXT_TAIL`: not yet assigned to any grace period
- `cpu_no_qs` / `core_needs_qs` — flags indicating whether this CPU owes the grace-period machinery a quiescent-state report

When `synchronize_rcu()` is called, it posts a completion on the calling thread's stack, registers a callback via `call_rcu()` that will signal that completion, and then blocks. The callback fires after the grace period, waking the waiter. The implementation batches thousands of concurrent `synchronize_rcu()` calls into a single grace period, which is why it can take multiple milliseconds — this batching is intentional and good for throughput.

For latency-critical paths, `synchronize_rcu_expedited()` sends an IPI to every CPU to force immediate quiescent-state reporting, completing in microseconds at the cost of disrupting real-time workloads.

### Module unloading: rcu_barrier vs synchronize_rcu

`synchronize_rcu()` waits for a grace period to elapse but does *not* wait for outstanding `call_rcu()` callbacks to execute. Under memory pressure or real-time scheduling, callbacks may be deferred beyond the grace period. A module that posts `call_rcu()` callbacks and then unloads risks having those callbacks execute against already-freed module text.

`rcu_barrier()` solves this: it posts a barrier callback on every CPU and blocks until all of them have run, which proves that all prior `call_rcu()` callbacks have also run. The correct sequence before unloading a module with outstanding callbacks is: stop posting new callbacks → `rcu_barrier()` → unload.

## Key Data Structures

**`struct rcu_state`** (`kernel/rcu/tree.h`) — global RCU state machine.
- `node[]` — the combining tree (root is `node[0]`, leaves are at the end)
- `gp_seq` — grace-period sequence counter; even = not in GP, odd = GP in progress
- `gp_kthread` — the kthread driving grace-period state machine
- `gp_wq` — workqueue for expedited grace periods

**`struct rcu_node`** (`kernel/rcu/tree.h`) — one node in the combining tree.
- `lock` — protects this node's state
- `qsmask` — bitmask of CPUs (or child nodes) that still owe a quiescent state
- `gp_seq` / `gp_seq_needed` — local view of grace-period progress
- `blkd_tasks` — (PREEMPT_RCU only) list of tasks blocked inside a read-side critical section on a CPU covered by this node

**`struct rcu_data`** (`kernel/rcu/tree.h`) — per-CPU interface to the RCU machinery.
- `mynode` — pointer to the leaf `rcu_node` for this CPU
- `cblist` (`rcu_segcblist`) — the four-segment callback queue
- `gp_seq_needed` — the grace-period number this CPU is waiting for
- `dynticks` — atomic counter for dyntick-idle tracking (even = idle, odd = active)

**`struct rcu_head`** (`include/linux/rcupdate.h`) — callback handle embedded in RCU-protected objects.
- `next` — intrusive list linkage
- `func` — the callback to invoke once the grace period ends

## Key Functions / Entry Points

**`rcu_read_lock()`** / **`rcu_read_unlock()`** (`include/linux/rcupdate.h`) — marks read-side critical section boundaries; no-ops on non-preemptible kernels.

**`rcu_dereference(p)`** (`include/linux/rcupdate.h`) — safely loads an RCU-protected pointer with data-dependency ordering; the reader must hold `rcu_read_lock()`.

**`rcu_assign_pointer(p, v)`** (`include/linux/rcupdate.h`) — publishes a new pointer value with store-release semantics; called by updaters after initializing the new struct.

**`synchronize_rcu()`** (`kernel/rcu/tree.c`) — blocks until a full grace period elapses; the slow but simple update path.

**`call_rcu(head, func)`** (`kernel/rcu/tree.c`) — posts an asynchronous callback to fire after the next grace period; use when the updater cannot block.

**`kfree_rcu(ptr, field)`** (`include/linux/rcupdate.h`) — convenience macro combining `call_rcu()` + `kfree()`; field is the `rcu_head` member name.

**`rcu_barrier()`** (`kernel/rcu/tree.c`) — waits for all pending `call_rcu()` callbacks to complete; required before module unload.

**`synchronize_rcu_expedited()`** (`kernel/rcu/tree.c`) — forces a fast grace period via IPI; use only in driver/module init paths, never in steady-state hot paths.

## Important Flags & Config Options

**`CONFIG_PREEMPT_RCU`** — enables the preemptible RCU variant. Read-side critical sections can now be preempted, at the cost of per-task nesting counters and a more complex grace-period mechanism that must track blocked tasks in `rcu_node.blkd_tasks`.

**`CONFIG_PROVE_RCU`** / **`CONFIG_DEBUG_LOCK_ALLOC`** — enables lockdep-style checking for RCU usage violations: using `rcu_dereference()` without `rcu_read_lock()`, calling `synchronize_rcu()` from within a critical section, etc.

**`CONFIG_RCU_STALL_COMMON`** + `rcupdate.rcu_cpu_stall_timeout` — controls when the kernel prints an "RCU detected CPU stall" warning. Default is 21 seconds. Reduce to 3–5s in CI environments to catch hung tests quickly.

**`CONFIG_SRCU`** — enables Sleepable RCU, which allows blocking inside `srcu_read_lock()` / `srcu_read_unlock()` critical sections. Required for filesystems and other subsystems that need to hold an RCU-like protection across a blocking call. Each SRCU domain allocates its own `srcu_struct`.

**`CONFIG_TASKS_RCU`** — enables RCU-Tasks, used by Ftrace and kprobes. Quiescent states are voluntary context switches and user-space execution only; grace periods are measured in hundreds of milliseconds.

**`rcupdate.rcu_expedited=1`** (boot param) — forces all `synchronize_rcu()` calls to use the expedited path. Useful for live-patching or module loading in latency-sensitive contexts, but severely impacts real-time performance.

## Interactions with Other Subsystems

- **↑ Userspace**: no direct syscall interface; RCU is entirely an in-kernel mechanism. User-visible effects come indirectly through latency and throughput of network, file system, and device operations that use RCU internally.
- **→ Scheduler**: RCU observes context switches as quiescent states. The scheduler's `schedule()` function calls `rcu_note_context_switch()` to report the quiescent state.
- **→ [[interrupt-handling]]**: Hardware interrupts and softirqs force quiescent states (a CPU handling an interrupt is by definition not in a read-side critical section for non-preemptible kernels).
- **→ [[per-cpu-variables]]**: `rcu_data` is a per-CPU structure; the entire grace-period machinery is designed to minimize cross-CPU cache-line bouncing.
- **→ [[dyntick-idle]]**: The dyntick-idle subsystem (`kernel/rcu/dyntick.h`) tracks whether each CPU is in the idle loop so RCU can account for CPUs that are sleeping as already-past quiescent states. This is critical for power efficiency on battery-powered systems.
- **← mm/[[slab-allocator]]**: `kfree_rcu()` is used pervasively by network and VFS code to return objects to the slab allocator after the grace period, without blocking the updater.
- **← [[netfilter]]**, **[[xarray]]**, **[[dcache]]**: These subsystems use RCU-protected linked lists and hash tables as the primary data structure for their hot-path lookups.

## Design Decisions & Tradeoffs

**Readers pay zero; writers pay deferred cost.** The original 2002 design decision was to put all synchronization burden on writers and free readers entirely. This is the right trade when reads vastly outnumber writes — which is true for routing tables, process lists, file-system dentries, and module lists. The cost: writers must maintain two live versions of data simultaneously and cannot reclaim memory immediately.

**Grace periods are long by default, batched for throughput.** `synchronize_rcu()` can take 10–100ms because it batches thousands of concurrent waiters into one grace period. This is intentional — the alternative (one grace period per call) would flood CPUs with IPIs and destroy scalability. The tradeoff is that RCU is a poor fit for low-latency reclamation requirements.

**No recursion — `synchronize_rcu()` cannot be called from within `rcu_read_lock()`.** This is a hard rule. The grace period waits for readers to finish; if a reader called `synchronize_rcu()`, it would deadlock on itself (in non-preemptible kernels) or cause unbounded latency (in preemptible kernels). Use `call_rcu()` if deferred work is needed from reader context.

**Hierarchical tree was the only path to 1000+ CPU scalability.** The original flat-bitmask design hit a hard wall at ~32 CPUs due to a global spinlock. The 2.6.29 hierarchical tree eliminated this by distributing quiescent-state reporting across a logarithmic tree, trading implementation complexity for linear scalability.

**SRCU trades scalability for flexibility.** SRCU allows sleeping inside read-side critical sections by using per-CPU counters instead of quiescent-state inference. The price is that grace period detection requires polling all CPUs rather than passively observing context switches, making SRCU grace periods more expensive and less scalable than vanilla RCU. Use vanilla RCU whenever possible; reach for SRCU only when blocking in a read-side critical section is unavoidable.

## How It Has Evolved

**2.5.43 (2002)**: Paul McKenney submitted the initial RCU implementation, targeting the DCL (Directory Cache Lock) contention problem in the VFS dcache. The design was a flat bitmask — every CPU cleared its bit on context switch.

**2.6.29 (2009)**: Hierarchical RCU (Tree RCU) replaced Classic RCU. The combining tree of `rcu_node` structures enabled scaling to 1024+ CPUs by eliminating the global lock. This version also introduced `call_rcu()` and the four-segment callback queue.

**2.6.32 (2009)**: `synchronize_rcu()` learned to detect the already-in-a-grace-period case and return immediately, avoiding redundant waiting in high-throughput code paths.

**3.0 (2011)**: RCU-BH and RCU-Sched flavors unified into a single implementation sharing the tree infrastructure. SRCU moved to using per-CPU data to improve its grace-period detection.

**4.20 (2018)**: RCU-BH and RCU-Sched *update-side* APIs were deprecated and their functionality folded into vanilla `synchronize_rcu()` / `call_rcu()`. The read-side variants remain for specialised use but the separate updater families were eliminated as unnecessary complexity.

**5.5 (2020)**: `kfree_rcu()` gained a no-`rcu_head`-needed variant (`kfree_rcu(ptr)`) that batches frees and uses bulk-allocation to avoid per-object overhead, significantly improving performance of protocols that allocate and free many small objects on the network fast path.

**6.x (ongoing)**: Polled grace period APIs (`start_poll_synchronize_rcu()`, `poll_state_synchronize_rcu()`) were added to allow waiting for grace periods without blocking, enabling RCU integration into contexts that cannot sleep.

## Further Reading

1. [What is RCU, Fundamentally? — LWN](https://lwn.net/Articles/262464/) — Best conceptual introduction; McKenney's three-part series.
2. [The RCU API, 2019 Edition — LWN](https://lwn.net/Articles/777036/) — Comprehensive API reference with variant selection guidance.
3. [The RCU API, 2024 Edition — LWN](https://lwn.net/Articles/988638/) — Latest additions including Tasks Trace RCU and polled APIs.
4. [Hierarchical RCU — LWN](https://lwn.net/Articles/305782/) — The 2009 redesign that enabled thousand-CPU scalability.
5. [kernel.org: What is RCU?](https://www.kernel.org/doc/html/latest/RCU/whatisRCU.html) — Official documentation with usage examples for all RCU flavors.
6. [kernel.org: RCU Design Requirements](https://www.kernel.org/doc/html/latest/RCU/Design/Requirements/Requirements.html) — Formal treatment of RCU's guarantees, constraints, and tradeoffs.
7. [kernel.org: RCU Data Structures](https://www.kernel.org/doc/html/latest/RCU/Design/Data-Structures/Data-Structures.html) — Deep dive into `rcu_state`, `rcu_node`, and `rcu_data`.

## LKML Highlights

- **Original submission (2002)**: McKenney's initial patch introduced RCU to dcache. The cover letter explicitly described the "bitmask of CPUs" approach and motivated it as a solution to lock contention in the VFS layer.
- **Tree RCU RFC (2008)**: The Hierarchical RCU proposal generated significant discussion about the combining-tree approach versus alternatives. McKenney's benchmarks showed a 3–4× throughput improvement on 128-CPU systems. Thread: `<20081205171833.GA4893@linux.vnet.ibm.com>`.
- **kfree_rcu() batch optimization (2020)**: The thread debating whether batching frees was worth the implementation complexity, ultimately resolved by showing a 30% improvement in network benchmark throughput for protocols like QUIC that create many short-lived connection objects.
