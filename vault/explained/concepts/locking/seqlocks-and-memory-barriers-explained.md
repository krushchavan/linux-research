---
title: "Seqlocks and Memory Barriers — Explained"
category: explained
original: "[[seqlocks-and-memory-barriers]]"
subsystem: locking
tags: [explained, locking, seqlocks, memory-barriers, lockless]
converted: 2026-09-25
---

# Seqlocks and memory barriers, explained

> Plain-language companion to [[seqlocks-and-memory-barriers|the technical note]]. Same facts, fewer identifiers.

## The problem

Some small pieces of data are read constantly and updated regularly. The classic example is the kernel's clock: the timer interrupt updates it every tick, and nearly every time-related call reads it. Making every reader take a spinlock would be a waste, since readers would block writers and each other. RCU is overkill for a few integers.

There's a deeper problem underneath any lock-free scheme. Modern CPUs don't make memory operations visible in program order. Stores sit in **store buffers** before other CPUs can see them, and CPUs can accept cache invalidations without processing them yet, so another CPU may observe your writes in a different order from the one you made them in. The compiler reorders too. Without explicit ordering, lock-free code can't be trusted at all.

## The idea in one paragraph

**Memory barriers** are fences planted between instructions: nothing on one side may be reordered to the other. **Seqlocks** use a pair of such fences around writes to let readers detect interference instead of preventing it. A counter goes **odd** while a write is in progress and back to **even** when it's done. A reader notes the counter, reads the data, and checks the counter again: same even value means no write interfered; otherwise it tries again. Readers never lock and never block writers.

## Step by step

### Step 1: Know your fences
- **Full barrier:** orders all loads and stores on either side; drains the store buffer. Expensive (tens of cycles); use only when needed.
- **Write barrier:** orders stores only. Free on x86, whose model already keeps stores in order; a real instruction on ARM. Must be paired with a read barrier on the reading side.
- **Read barrier:** orders loads only.
- **Acquire / release:** one-way fences. A release store makes everything before it visible first; an acquire load makes everything after it happen after. Pairing them gives "the reader sees everything the writer did before publishing". They're cheaper than full barriers and generally preferred.
- **Compiler barrier:** stops only the compiler reordering; emits no instruction.
- **Read-once / write-once:** stop the compiler splitting, merging or deleting accesses to shared variables. The minimum for any unlocked shared variable.

On single-CPU builds, the SMP barriers shrink to compiler barriers. Drivers ordering device I/O use separate barriers that always emit real instructions.

### Step 2: How a writer updates
1. increment the counter (now **odd**), then a write barrier, so "odd" is visible before any data changes
2. update the data
3. a write barrier, then increment the counter (now **even**), so every data change is visible before "even"

Without the barriers, a reader could see the clean even number while some data stores had actually been reordered after it.

### Step 3: How a reader reads
This is the key step:
1. load the counter; if it's odd, wait until it's even; then a read barrier, so no data load is moved before the counter load
2. read the data
3. load the counter again; if it changed, a write happened (or was happening), so start over

The common case, with no concurrent write, costs two integer loads and a comparison. Readers never block writers; a slow reader just retries more.

### Step 4: Serialising writers
The counter alone doesn't stop two *writers* from interleaving. The full **seqlock** pairs it with a spinlock that writers take, with variants that also disable soft or hard interrupts when readers may run in interrupt context. A reader that can't tolerate retrying (say its reads have side effects) can take the lock instead, blocking writers; an adaptive version tries lock-free first and falls back to locking if the data keeps changing. When writers are already serialised by some other lock, the bare counter is used with that lock recorded in its type, so lockdep can check it's held.

### Step 5: The latch, for NMIs
An NMI can interrupt the writer at any instant, so it can't wait for "even". The **latch** variant keeps **two copies** of the data. The writer updates one copy, flips the counter, then updates the other. A reader picks a copy by the counter's parity, and always finds one that's complete. The vDSO's time-of-day fast path uses this.

### Step 6: The one big restriction
Because a writer can change data at any moment, a reader must not follow a pointer it read inside the loop: the target might already be freed. Seqlocks are for **small, fixed-size data without pointers**. For pointer-based structures, RCU is the right tool, and the two are often combined.

## The picture

```text
 counter:  … 40 (even) │ writer: 41 (odd) ─ update data ─ 42 (even) │ …

 reader A:  sees 40 ─ reads data ─ sees 40  ✓ consistent
 reader B:  sees 40 ─ reads data ─ sees 42  ✗ retry
 reader C:  sees 41 (odd) → wait for even, then start

 writer:  ++count  │ write barrier │ data │ write barrier │ ++count
 reader:  count    │ read barrier  │ data │ count again, compare
```

## Tradeoffs

- **What it gives you:** reads with almost no cost that never block writers; the vDSO uses it to serve `clock_gettime` entirely in user space, with no system call.
- **What it costs / requires:** readers must be able to retry safely, and data must be small and pointer-free; barriers must be placed exactly right on every architecture.
- **Where it bites:** under constant writes, readers can retry many times. Following pointers inside the read loop is a use-after-free waiting to happen. The concurrency sanitizer treats seqlock read loops as intentionally racy, up to 1,000 iterations.

## How it got here

- **2.6 era:** introduced by Ingo Molnár as "frlock", then renamed seqlock, first for the kernel's tick counter and wall-clock time; barriers existed but the memory model was informal.
- **4.15:** read-once took over address-dependency ordering, retiring a notoriously misused special barrier.
- **5.1:** the formal kernel memory model merged, allowing tools to verify lock-free patterns, seqlocks included.
- **5.10:** Ahmed S. Darwish's rework: counter types that name their writer lock, for lockdep checking, and the latch as a first-class type.
- **5.18+:** reader entry switched from a read barrier to an acquire load where cheaper; on ARM64 Neoverse, from 13 cycles to 8.

## Related

- Technical version: [[seqlocks-and-memory-barriers]]
- [[locking-explained|Locking subsystem]], [[rcu-read-copy-update-explained|RCU]], [[per-cpu-variables-explained|Per-CPU variables]], [[interrupt-handling-explained|Interrupt handling]]
- [[path-lookup-explained|Path lookup (sequence counters in RCU-walk)]], [[page-table-management-explained|Page tables]]
