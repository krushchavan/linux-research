---
title: "Context Switch"
category: concept
tags: [scheduler, context-switch, task-switch, switch-to, preemption]
subsystem: scheduler
kernel_version: "2.6.0"
researched: 2026-04-13
status: complete
sources:
  - https://kernel-internals.org/sched/context-switch/
  - https://kernel-internals.org/sched/preemption/
  - https://kernel-internals.org/sched/wakeup/
---

# Context Switch

## Purpose

The illusion of concurrent execution on a single CPU requires rapidly transferring control from one task to another — saving the outgoing task's register state, switching address spaces, and restoring the incoming task's registers. This must happen correctly under all conditions (NMI, IRQ, lazy TLB, kernel threads, virtualization) while spending as few cycles as possible on overhead that produces no user-visible work.

## Mental Model

Think of context switching as **suspending and resuming a phone call**. When you put one call on hold and take another, you save your conversational context (where you were, what you were saying), switch who you're talking to, and pick up where you left off with the new caller. The CPU does the same: it saves one task's register state onto that task's private stack, switches page tables to the new task's address space, and restores the new task's registers from its stack. Critically, each task's stack holds its own "saved state", so the old task resumes exactly where it left off when the CPU comes back to it.

## How It Works

### Triggering: TIF_NEED_RESCHED

A context switch doesn't happen at a random moment — it happens at a *scheduling point*. The mechanism is the `TIF_NEED_RESCHED` flag in `task_struct->thread_info.flags`. When the scheduler wants to switch away from the current task (because a higher-priority task woke up, or the current task's timeslice expired, or the task explicitly called `schedule()`), it calls `resched_curr()`, which sets `TIF_NEED_RESCHED`.

The flag is checked at every safe preemption point:
- On return from an interrupt or exception (always)
- On return from a syscall (always)
- At explicit `preempt_enable()` calls when `preempt_count == 0` (under `CONFIG_PREEMPT`)
- At `cond_resched()` calls in long kernel loops (under `CONFIG_PREEMPT_VOLUNTARY`)

Under `CONFIG_PREEMPT_NONE`, the flag is only checked at explicit `schedule()` calls and syscall/interrupt returns. Under `CONFIG_PREEMPT`, it is checked at every `preempt_enable()`, enabling kernel preemption — a higher-priority task can interrupt even deep kernel code.

### `__schedule()`: Orchestrating the Switch

`__schedule()` in `kernel/sched/core.c` is the central function. It is called from `schedule()` (explicit yield), from preemption points, and from the return path of interrupts when `TIF_NEED_RESCHED` is set.

First, it disables local IRQs (to prevent interrupts from modifying the runqueue mid-switch) and acquires `rq->__lock`. Then it calls `update_rq_clock()` to advance the nanosecond clock — all accounting during this critical section uses a fixed timestamp to avoid inconsistencies.

Next, `__schedule()` examines the outgoing task (`prev`). If it has a non-runnable state (`TASK_INTERRUPTIBLE`, `TASK_UNINTERRUPTIBLE`, etc.) and the switch is a voluntary block (not a preemption), `dequeue_task()` removes it from the runqueue. If a signal is pending for an `TASK_INTERRUPTIBLE` task, it is woken back to `TASK_RUNNING` before the dequeue — the I/O it was waiting for hasn't arrived, but the signal takes priority.

`pick_next_task()` then selects the next task using the scheduler class chain. If `prev` is still runnable (preemption case), `put_prev_task()` updates its accounting and potentially re-inserts it into the queue at the appropriate position.

If `next != prev` (a switch is actually needed), `context_switch(rq, prev, next, &rf)` runs.

### `context_switch()`: Address Space and Register State

`context_switch()` handles two separable concerns: *memory* and *CPU state*.

**Memory**: `switch_mm_irqs_off(prev->active_mm, next->mm, next)` switches address spaces. For user tasks, this means writing the new page table root into the CPU's page table register (CR3 on x86-64, TTBR0 on ARM64), which flushes the TLB unless PCID (Process Context Identifiers) allows tag-based TLB invalidation. For *kernel threads*, there is no user address space — they borrow `prev->active_mm` via the lazy TLB mechanism (`enter_lazy_tlb()`), avoiding the CR3 write and TLB flush entirely. The reference count on `prev->mm` or `prev->active_mm` is managed here.

**CPU state**: `switch_to(prev, next, prev)` is the architecture-specific assembly macro that performs the actual register swap. On x86-64, it:
1. Saves callee-saved registers (rbx, rbp, r12–r15) of `prev` onto `prev`'s kernel stack
2. Swaps stack pointers: RSP now points to `next`'s kernel stack
3. Restores callee-saved registers of `next` from its kernel stack
4. Returns — but the return address on `next`'s stack is wherever `next` was when it was last switched out

After `switch_to()`, code executes in `next`'s context. `prev` is still referenced (via the `prev` variable on the new stack) but it is no longer running.

### `finish_task_switch()`: Post-Switch Cleanup

`finish_task_switch()` runs in the *new task's* context. Its most important operation is clearing `prev->on_cpu` with release semantics via `smp_store_release`. This matters for task migration: `try_to_wake_up()` uses `smp_cond_load_acquire(&p->on_cpu, !VAL)` to spin until the task is fully off the CPU before migrating it. If `finish_task_switch()` didn't use release semantics, a concurrent waker on another CPU could see `on_cpu == 0` before the stack is fully unwound.

After clearing `on_cpu`, the runqueue lock (held since before `pick_next_task()`) is released. Memory management cleanup (lazy TLB, active_mm reference counts) is handled here. If `prev` is in `TASK_DEAD` state (the task exited), its `task_struct` is freed here.

### Voluntary vs. Involuntary Switches

The kernel tracks both kinds:
- **Voluntary** (`nvcsw`): Task called `schedule()` because it blocked (waiting for I/O, sleeping, acquiring a lock)
- **Involuntary** (`nivcsw`): Scheduler preempted the task — timeslice expired or higher-priority work arrived

High `nivcsw` relative to `nvcsw` for a task indicates it is being frequently preempted despite wanting to run — a sign of CPU contention. Both counters are visible in `/proc/$PID/status`.

## Key Data Structures

**`struct task_struct`** (selected fields, `include/linux/sched.h`)
- `__state` — current task state: `TASK_RUNNING`, `TASK_INTERRUPTIBLE`, `TASK_UNINTERRUPTIBLE`, `TASK_DEAD`
- `on_cpu` — 1 while the task is executing on a CPU; cleared by `finish_task_switch()` with release semantics
- `thread` — `struct thread_struct`; arch-specific register state (FPU, debug registers, etc.)
- `active_mm` — the `mm_struct` the task is using (for kernel threads, borrowed from prev)
- `nvcsw` / `nivcsw` — voluntary / involuntary context switch counters

**`struct thread_info`** (arch-specific, `arch/x86/include/asm/thread_info.h`)
- `flags` — bitmap including `TIF_NEED_RESCHED`, `TIF_SIGPENDING`, `TIF_NOTIFY_RESUME`
- `preempt_count` — nesting level; preemption occurs only when this is zero

## Key Functions / Entry Points

**`__schedule()`** (`kernel/sched/core.c`) — central orchestrator: lock runqueue, dequeue if blocking, pick next, switch or return.

**`context_switch()`** (`kernel/sched/core.c`) — memory and CPU state transition; calls `switch_mm_irqs_off()` and `switch_to()`.

**`switch_to(prev, next, prev)`** (`arch/*/include/asm/switch_to.h`) — arch assembly: save callee registers, swap stack pointers, restore callee registers, return into new task.

**`finish_task_switch()`** (`kernel/sched/core.c`) — post-switch cleanup: clear `prev->on_cpu`, release runqueue lock, lazy TLB cleanup.

**`resched_curr()`** (`kernel/sched/core.c`) — set `TIF_NEED_RESCHED` on the current task of the target CPU; may generate an IPI if the CPU is remote.

## Important Flags & Config Options

- `CONFIG_PREEMPT_NONE` — preemption only at explicit `schedule()` and interrupt returns (server workloads)
- `CONFIG_PREEMPT_VOLUNTARY` — adds `cond_resched()` points in long kernel loops (desktop default)
- `CONFIG_PREEMPT` — full kernel preemption at any `preempt_enable()` point (embedded, gaming)
- `CONFIG_PREEMPT_RT` — converts spinlocks to sleeping mutexes; enables preemption in most critical sections (hard real-time)
- `TIF_NEED_RESCHED` — the flag that gates switching; visible in `/proc/$PID/wchan`

## Interactions with Other Subsystems

- **↑ Userspace**: Context switch count visible via `/proc/$PID/status` (`voluntary_ctxt_switches`, `nonvoluntary_ctxt_switches`)
- **→ [[runqueue]]**: `__schedule()` holds `rq->__lock` throughout; calls `update_rq_clock()` at entry
- **→ [[cfs-eevdf]]**: `put_prev_task_fair()` updates vruntime for the outgoing task; `set_next_task_fair()` sets the incoming task as current
- **← [[interrupt-handling]]**: Timer ticks set `TIF_NEED_RESCHED`; IRQ return path checks the flag and calls `__schedule()` if set
- **← [[locking]]**: Sleeping locks (mutex, semaphore, wait_event) call `schedule()` after setting the task state to `TASK_INTERRUPTIBLE`

## Design Decisions & Tradeoffs

**Release semantics on `on_cpu`**: The `smp_store_release` in `finish_task_switch()` is not just a nice-to-have — without it, a CPU waking a migrating task could see `on_cpu == 0` before the register save is complete and attempt to enqueue it on another CPU while it's still partially on the old one. The acquire in `try_to_wake_up()` pairs with this release to form the necessary barrier.

**Lazy TLB for kernel threads**: Switching page tables is expensive (TLB flush, possibly L1/L2 cache pollution). Kernel threads have no user address space, so they borrow the previous task's `mm`. This avoids the flush — at the cost of keeping the previous user task's page tables mapped while the kernel thread runs. For short kernel threads this is a clear win; for long-running kernel threads on NUMA systems it may keep remote page tables unnecessarily resident.

**`switch_to()` as a macro**: The function returns in the new task's context, which requires very careful stack discipline. A regular function call would return to the caller on the *old* task's stack; the macro form allows the compiler to understand the stack discontinuity.

## How It Has Evolved

- **SMP (2.6.0+)**: `finish_task_switch()` split from `context_switch()` to correctly handle the transition from old to new task on the new task's stack
- **Lazy TLB**: Introduced early to avoid TLB flushes for kernel-thread switches; refined with PCID (x86, ~4.14) for user-task switches
- **`CONFIG_PREEMPT_RT` (~5.15)**: `switch_to()` unchanged, but the paths leading to it (spinlock sleeps) changed fundamentally
- **FPU lazy save**: FPU state is not saved/restored on every context switch — only when the new task actually uses FPU, triggered by an `#XM` / device-not-available fault

## Further Reading

1. [kernel-internals.org/sched/context-switch/](https://kernel-internals.org/sched/context-switch/)
2. [Scheduler documentation — kernel.org](https://static.lwn.net/kerneldoc/scheduler/index.html)

## LKML Highlights

- **`finish_task_switch()` introduction**: The split from a monolithic `context_switch()` was necessitated by SMP — code that runs after the stack pointer swap executes in the new task's context, requiring careful attribution.
- **PCID and lazy TLB (4.14)**: Joerg Roedel's series using PCID to avoid full TLB flushes on context switch, significantly reducing switch cost for process-heavy workloads.
