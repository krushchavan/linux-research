---
title: "Seqlocks and Memory Barriers"
category: concept
tags: [locking, synchronization, memory-ordering, seqlock, barriers]
subsystem: locking
kernel_version: "2.6.12"
researched: 2026-04-11
status: complete
sources:
  - https://kernel-internals.org/locking/seqlock/
  - https://www.kernel.org/doc/html/latest/locking/seqlock.html
  - https://lwn.net/Articles/846700/
  - https://lwn.net/Articles/847481/
  - https://lwn.net/Articles/22818/
  - https://www.kernel.org/doc/Documentation/memory-barriers.txt
  - https://github.com/torvalds/linux/blob/master/include/linux/seqlock.h
---

# Seqlocks and Memory Barriers

## Purpose

These two mechanisms are inseparable in practice: seqlocks provide a pattern for lock-free reads of frequently-updated small data, while memory barriers are the CPU-level primitives that make those lock-free reads correct across architectures. Without memory barriers, neither seqlocks nor any other lock-free concurrent code can be trusted — the CPU and compiler are free to reorder memory accesses in ways that break the assumptions of concurrent code. Without seqlocks, protecting fast-path read-heavy data like `jiffies_64` or `xtime` would require either expensive spinlocks that block readers or RCU which is overkill for simple scalar values.

## Mental Model

Think of memory barriers as "fences you plant between instructions" that say "nothing on my side of this fence may be reordered to the other side." Seqlocks then use a pair of such fences — one written by the writer before modifying data, one after — creating a bracketing pattern that lets any reader detect whether it raced with a write. If the reader sees the same sequence number before and after reading the protected data, no write interfered and the data is consistent. The odd/even parity of the sequence number is the signal: odd means a write is in progress, even means quiescent.

## How It Works

### Memory Barriers: The Foundation

Modern CPUs are not sequentially consistent. They contain **store buffers** that delay the visibility of stores to other CPUs — a CPU writes to its store buffer first, and only later propagates to the L1 cache and beyond. Similarly, **invalidation queues** allow a CPU to accept invalidations of cache lines without immediately processing them, meaning a load may return a stale value even after the invalidating store has theoretically been issued. Both effects mean that without explicit barriers, two CPUs observing each other's memory operations may disagree on the order in which they occurred.

The kernel provides several barrier types, each with a different cost and guarantee:

**Full barriers — `smp_mb()`** order all loads and stores on either side. After `smp_mb()`, no load or store issued before the barrier can be seen by another CPU as occurring after any load or store issued after it. The implementation flushes the store buffer and waits for invalidations to drain. On x86 this is `MFENCE`; on ARM this is `DMB ISH`. It is expensive (tens of cycles) and should be used only when needed.

**Write barriers — `smp_wmb()`** order only stores. All stores issued before the barrier are guaranteed to be visible before any store issued after it. On x86, this is typically a no-op because x86's TSO (Total Store Order) model already prevents store reordering, but on ARM it maps to `DMB ISHST`. Write barriers are cheaper but insufficient on their own — they must be paired with a matching read barrier on the consuming side.

**Read barriers — `smp_rmb()`** order only loads. They ensure that loads issued before the barrier see values at least as new as those seen by loads before any preceding write that was followed by a write barrier. On x86 again a no-op for the CPU, but acts as a compiler barrier; on ARM this is `DMB ISHLD`.

**ACQUIRE/RELEASE — `smp_load_acquire()` / `smp_store_release()`** are one-way (asymmetric) barriers. An ACQUIRE operation guarantees that all memory operations *after* it in program order appear to happen after it — no subsequent access can be reordered to before the acquire. A RELEASE operation guarantees that all memory operations *before* it in program order appear to happen before it — no prior access can be reordered past the release. When a writer uses `smp_store_release()` to publish a pointer or sequence counter, and a reader uses `smp_load_acquire()` to consume it, the kernel's LKML-conformant memory model guarantees the reader sees all stores the writer made before the release. These are cheaper than full barriers because they only constrain one direction.

**Compiler barriers — `barrier()`** prevent the compiler from reordering around the barrier, but generate no CPU instructions. They are sufficient when the CPU's own ordering is not a concern (single-CPU or architecture-guaranteed cases).

**`READ_ONCE()` / `WRITE_ONCE()`** prevent the compiler from tearing, coalescing, or eliminating accesses to shared variables. They do not generate memory-ordering CPU instructions but do act as compiler barriers. Since 4.15 they also encode address-dependency barriers implicitly. They are the minimal safe way to read or write any variable shared between kernel threads without a lock.

### Seqlocks: Putting Barriers to Work

#### The Sequence Counter (`seqcount_t`)

`seqcount_t` is the heart of seqlocks. It lives in `include/linux/seqlock.h` and contains a single `unsigned sequence` integer. The convention is:

- **Even** value → no write in progress; data is consistent.
- **Odd** value → a write is in progress; any reader that sees an odd value must discard its reads and retry.

A writer increments the counter twice: once before modifying the protected data (making it odd), and once after completing the modification (making it even again). The full write sequence with proper barriers is:

```c
raw_write_seqcount_begin(s):        /* s->sequence++ (now odd) */
    WRITE_ONCE(s->sequence, s->sequence + 1);
    smp_wmb();                      /* all prior stores complete before... */

/* ... writer modifies protected data ... */

raw_write_seqcount_end(s):          /* s->sequence++ (now even) */
    smp_wmb();                      /* ...data stores visible before... */
    WRITE_ONCE(s->sequence, s->sequence + 1);
```

The `smp_wmb()` before the data modifications ensures that the odd sequence number becomes visible before any data update. The `smp_wmb()` after ensures all data updates are visible before the even sequence number. Without these barriers, a reader could observe the even (clean) sequence number while the CPU had already reordered some data stores ahead of the counter decrement.

A reader captures the sequence, reads the data, then checks the sequence again:

```c
do {
    seq = read_seqcount_begin(s);    /* load seq; odd → spin until even; smp_rmb() */
    /* ... read protected data ... */
} while (read_seqcount_retry(s, seq)); /* read seq again; mismatch → retry */
```

`read_seqcount_begin()` issues an `smp_rmb()` after loading the sequence number. This prevents the CPU from reordering any of the protected data loads to before the sequence load — which would be a bug because the reader would then see data from *before* the sequence number it captured. `read_seqcount_retry()` checks whether the sequence number has changed (or was odd), causing a retry if so. The retry loop ensures eventual consistency: if a write began and ended between the two sequence reads, the reader detects this via a changed even number and retries from scratch.

The reader never acquires any lock and never blocks a writer. This is the key performance advantage: on read-heavy workloads, the common path (no concurrent write) is just two integer loads and a comparison.

#### The Full Seqlock (`seqlock_t`)

`seqlock_t` wraps `seqcount_t` with an embedded `spinlock_t`:

```c
typedef struct {
    struct seqcount seqcount;
    spinlock_t      lock;
} seqlock_t;
```

The spinlock serializes concurrent writers — `seqcount_t` on its own does nothing to prevent two writers from interleaving. `write_seqlock()` acquires the spinlock, disables preemption, and calls `raw_write_seqcount_begin()`. `write_sequnlock()` calls `raw_write_seqcount_end()` then releases the spinlock. Variants `_bh`, `_irq`, and `_irqsave` additionally disable softirqs or hardirqs, necessary when the seqlock-protected data is accessed from interrupt context.

For readers, `seqlock_t` adds a "locking read" path: `read_seqlock_excl()` acquires the spinlock, providing guaranteed-consistent reads at the cost of blocking writers. This is the fallback when a reader can't tolerate retries (e.g., it has expensive or non-idempotent side effects). The adaptive `read_seqbegin_or_lock()` first tries the lockless path; if the data keeps changing it falls back to the locking path.

#### Seqcount Latch (`seqcount_latch_t`)

`seqcount_latch_t` solves a specific problem: NMI (non-maskable interrupt) handlers that need to read data being updated. Because NMIs can interrupt the writer's critical section at any point, disabling interrupts is not an option. The latch variant maintains *two copies* of the protected data, indexed by `seq & 1`:

```c
/* Writer: */
write_seqcount_latch_begin(&latch);   /* seq++ → odd */
update(data[seq & 1]);                /* write "new" copy */
write_seqcount_latch(&latch);         /* seq++ → even */
update(data[seq & 1]);                /* write other copy too */
write_seqcount_latch_end(&latch);

/* Reader: */
do {
    seq = read_seqcount_latch(&latch);
    ptr = &data[seq & 1];             /* pick one copy */
    /* read from ptr */
} while (read_seqcount_latch_retry(&latch, seq));
```

Because the writer updates both copies, a reader that picks either copy based on the sequence parity will eventually read a fully-consistent snapshot, even if interrupted at the worst possible moment. The vDSO time-of-day fast path uses exactly this pattern.

### Where Seqlocks Are Used

The canonical use case is `jiffies_64` and `xtime` (wall clock time): the timer interrupt updates these values every tick, while almost every timer-related syscall reads them. The read-to-write ratio is enormous, so avoiding any lock overhead on the read path is critical. The vDSO uses `seqlock_t` so that `clock_gettime()` can be served from userspace without any syscall, reading the time variables exposed in the vDSO mapping using the seqlock protocol.

The scheduler also uses seqlocks to protect `task_rq_lock` on remote CPUs — a reader can optimistically read the run-queue without taking the run-queue lock, retrying only on a concurrent migration. Block layer bio completion paths, network socket timestamps, and various per-CPU time accounting structures all use seqlocks for the same reason: extremely frequent reads, infrequent writes, small fixed-size data.

## Key Data Structures

**`seqcount_t`** (`include/linux/seqlock.h`) — the raw sequence counter with no locking.
- `unsigned sequence` — the generation counter; odd during writes, even otherwise.
- Debug builds add `lockdep_map_p lock_dep_map` for validator integration.

**`seqlock_t`** (`include/linux/seqlock.h`) — combines seqcount with a spinlock.
- `struct seqcount seqcount` — the embedded sequence counter.
- `spinlock_t lock` — serializes writers; also provides the locking read path.

**`seqcount_latch_t`** (`include/linux/seqlock.h`) — dual-copy latch for NMI safety.
- `seqcount_t seqcount` — counts transitions; the low bit selects which copy is "current."

## Key Functions / Entry Points

**`read_seqcount_begin(s)`** (`include/linux/seqlock.h`) — starts a lockless read; spins if seq is odd, then issues `smp_rmb()`.

**`read_seqcount_retry(s, seq)`** — checks if the sequence has changed since `read_seqcount_begin()`; returns true if the read must be retried.

**`write_seqlock(lock)` / `write_sequnlock(lock)`** — writer entry/exit; acquires spinlock and brackets the data modification with sequence increments and write barriers.

**`raw_write_seqcount_begin(s)` / `raw_write_seqcount_end(s)`** — the inner sequence-counter manipulation used by all write paths; issues `smp_wmb()` around the counter increments.

**`read_seqbegin(lock)` / `read_seqretry(lock, seq)`** — the `seqlock_t` equivalents of `read_seqcount_begin()` / `read_seqcount_retry()`.

**`smp_mb()` / `smp_rmb()` / `smp_wmb()`** (`include/asm-generic/barrier.h`) — full, read, and write memory barriers; architecture-specific implementations in `arch/<arch>/include/asm/barrier.h`.

**`smp_load_acquire(p)` / `smp_store_release(p, v)`** — acquire-load and release-store; the preferred pairing for lock-free publish/subscribe patterns; cheaper than full barriers.

**`READ_ONCE(x)` / `WRITE_ONCE(x, v)`** (`include/linux/compiler.h`) — prevent compiler tearing or elimination of shared variable accesses; mandatory for any variable shared between concurrent contexts without a lock.

## Important Flags & Config Options

**`CONFIG_DEBUG_SEQLOCK`** — enables lockdep-style tracking for seqlocks, detecting misuse (e.g., calling `read_seqcount_begin()` inside a write section). Added in 5.10 alongside the seqcount refactor.

**`CONFIG_KCSAN`** — KCSAN (Kernel Concurrency Sanitizer) has special handling for seqlock regions: it marks all accesses within `read_seqcount_begin()` / `read_seqcount_retry()` loops as intentionally racy up to `KCSAN_SEQLOCK_REGION_MAX` (1000) iterations, suppressing false positives from the expected retry loop.

**`CONFIG_SMP`** — controls whether `smp_*` barriers emit real CPU instructions. On `!CONFIG_SMP` (uniprocessor), `smp_mb()`, `smp_rmb()`, and `smp_wmb()` reduce to compiler barriers (`barrier()`), avoiding overhead when CPU reordering is not a concern. Device driver code must use `mb()` / `rmb()` / `wmb()` (without the `smp_` prefix) for I/O ordering, which always emit real barriers regardless of `CONFIG_SMP`.

## Interactions with Other Subsystems

- **↑ Userspace**: the vDSO time-of-day fast path exports a `seqlock_t` into user mappings so that `clock_gettime()` can execute entirely in userspace, reading `xtime` and `jiffies_64` without a syscall while still detecting concurrent kernel updates.
- **→ [[locking → RCU read-copy-update|RCU]]**: seqlocks and RCU are complementary — RCU protects pointer-based data structures that may be traversed; seqlocks protect small scalar/struct data where pointer dereferencing is not needed. Combining them (e.g., seqlock for version detection + RCU for deferred freeing) is common in the VFS.
- **→ [[locking → per-cpu-variables|Per-CPU variables]]**: seqlocks are sometimes used alongside per-CPU data to provide a cross-CPU consistent snapshot — a reader aggregates per-CPU counters inside a seqlock read loop, so it can detect if a migration race corrupted the sum.
- **→ [[mm → xarray|XArray]] / [[mm → page-table-management|page tables]]**: mm uses seqlocks in `mmap_lock`-free speculative page-table walks — the walker takes a sequence snapshot, speculatively walks the page table, and only takes the full `mmap_lock` if the sequence changed.
- **← [[locking → interrupt-handling|Interrupt handling]]**: `write_seqlock_irq()` and `write_seqlock_irqsave()` are used when the writer runs in process context but the reader may run in interrupt context; the variants disable the appropriate interrupt level to prevent priority-inversion deadlocks.

## Design Decisions & Tradeoffs

**No pointer traversal in the read section**: Because a writer can modify data at any time relative to a reader, dereferencing a pointer read inside the seqlock loop is unsafe — the pointed-to object may have been freed by the time the dereference executes. This constraint fundamentally limits seqlocks to fixed-size, pointer-free data.

**Writer preference over reader progress**: Seqlocks guarantee writers are never blocked by readers. A slow or stalled reader simply retries more often. This makes seqlocks unsuitable for data accessed under conditions where retry is not safe (non-idempotent reads with side effects, or reads that hold other resources).

**`smp_rmb()` vs `smp_load_acquire()` in the read begin**: Early implementations used `smp_rmb()` after the sequence load. A 2024 optimization on ARM64 replaced this with `smp_load_acquire()` on the sequence load itself, reducing cycle count from 13 to 8 on Neoverse. The acquire semantic provides the same ordering guarantee but with lower hardware cost because the CPU can begin loading protected data in parallel with the acquire barrier processing.

**seqcount_t vs seqlock_t choice**: Using `seqcount_t` directly (without an embedded spinlock) is appropriate when an external lock already serializes writers — e.g., if the data is always written under a mutex, adding another spinlock inside a seqlock_t would be redundant and would create misleading lockdep annotations. `seqcount_t` variants (`seqcount_spinlock_t`, `seqcount_mutex_t`, etc.) accept the external lock as a parameter so lockdep can verify the associated lock is held during writes.

**ACQUIRE/RELEASE vs full barriers**: Full barriers (`smp_mb()`) are symmetric — they order everything before against everything after, in all directions. ACQUIRE/RELEASE are asymmetric and cheaper because they only constrain one half of a load or store. The kernel style guide (and LKML consensus) strongly prefers ACQUIRE/RELEASE for most patterns, reserving `smp_mb()` for the rare store-load ordering case (where a store on one CPU must be visible before a load on the same CPU that synchronizes with another CPU).

## How It Has Evolved

**2.6.12 (initial)**: Seqlocks introduced as `frlock` by Ingo Molnár, then renamed to `seqlock`. Initial use for `jiffies_64` and `xtime`. Memory model was implicit — barriers existed but were not formally documented.

**4.15**: `READ_ONCE()` / `WRITE_ONCE()` semantics were tightened; address-dependency barriers were folded into `READ_ONCE()`, removing the need for explicit `smp_read_barrier_depends()` which was notoriously misunderstood and misused.

**5.1**: The LKML memory model (`tools/memory-model/`) was merged, providing a formal specification of what `smp_load_acquire()`, `smp_store_release()`, `smp_mb()` etc. actually guarantee. This allowed automated verification of lock-free algorithms including seqlock patterns with the `herd7` tool.

**5.10**: Major seqlock refactor by Ahmed S. Darwish: introduced typed `seqcount_LOCKTYPE_t` variants (e.g., `seqcount_spinlock_t`, `seqcount_mutex_t`) that embed the associated lock type for lockdep validation. Also introduced `seqcount_latch_t` as a first-class type, formalizing the dual-copy pattern used in the vDSO.

**5.18+**: Ongoing micro-optimization replacing `smp_rmb()` in reader begin paths with `smp_load_acquire()`, measurably improving latency on acquire-efficient architectures like ARM64 without changing the memory model semantics.

## Further Reading

1. [Lockless patterns: relaxed access and partial memory barriers (LWN, 2021)](https://lwn.net/Articles/846700/) — explains how seqcounts sit within the broader landscape of lockless programming, with correct implementation patterns.
2. [Lockless patterns: full memory barriers (LWN, 2021)](https://lwn.net/Articles/847481/) — the complementary article explaining when full `smp_mb()` is unavoidable.
3. [Sequence counters and sequential locks — kernel.org](https://www.kernel.org/doc/html/latest/locking/seqlock.html) — canonical API reference.
4. [Driver porting: mutual exclusion with seqlocks (LWN, 2003)](https://lwn.net/Articles/22818/) — original introduction, explains design intent.
5. [memory-barriers.txt](https://www.kernel.org/doc/Documentation/memory-barriers.txt) — the definitive (very long) reference for all kernel barrier types.
6. [seqlock: Introduce seqcount_latch_t (LWN, 2020)](https://lwn.net/Articles/829724/) — the patch series formalizing seqcount_latch_t.

## LKML Highlights

- **`seqlock: serialize against writers`** — thread discussing corner cases where readers holding seqlocks need to be serialized against writers to prevent live-lock on non-preemptible kernels; introduced `read_seqlock_excl()`. Message-ID referenced via [lwn.net/Articles/296209/](https://lwn.net/Articles/296209/).
- **`New version of frlock (now called seqlock)`** — Ingo's original proposal thread, explaining why a new primitive was needed instead of using `rwlock` and the design decisions around writer preference and no-pointer constraints. Message-ID referenced via [lwn.net/Articles/21812/](https://lwn.net/Articles/21812/).
