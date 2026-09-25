---
title: "Preemption Model"
category: concept
tags: [scheduler, preemption, real-time, latency, context-switch]
subsystem: scheduler
kernel_version: "2.6"
researched: 2026-04-16
status: complete
explained: "[[preemption-model-explained]]"
sources:
  - https://kernel-internals.org/sched/preemption/
  - https://lwn.net/Articles/944686/
  - https://lwn.net/Articles/945422/
  - https://lwn.net/Articles/994322/
  - https://lwn.net/Articles/989212/
  - https://lwn.net/Articles/563088/
  - https://lwn.net/Articles/146861/
---

# Preemption Model

> 📘 Plain-language version: [[preemption-model-explained]]

## Purpose

The kernel's preemption model determines when the scheduler is allowed to force a currently running task off the CPU in favour of a higher-priority one. Without preemption, a task executing kernel code could hold the CPU for an unbounded amount of time — fine for batch servers, catastrophic for audio playback or safety-critical control loops. The preemption model is the primary knob that governs the worst-case latency / throughput tradeoff of the entire system.

## Mental Model

Think of a bank teller (the CPU) and a service rule (the preemption model). Under "no preemption", every customer must finish their transaction completely before the next one starts — great throughput, terrible for the person with a two-second question stuck behind a mortgage refinancing. Under "full preemption", a manager can tap the teller on the shoulder mid-transaction and say "deal with this urgent wire transfer first" — lower throughput, but nobody waits more than a few hundred microseconds. PREEMPT_RT is the teller bank that has remodelled so that even locking the safe doesn't block the teller from being interrupted.

## How It Works

### The Trigger Side — Setting TIF_NEED_RESCHED

Preemption starts with a signal, not an action. When the scheduler decides the current task should give up the CPU, it calls `resched_curr()` (`kernel/sched/core.c`), which sets the `TIF_NEED_RESCHED` flag in the task's `thread_info.flags`. This is a *request*, not a transfer of control. The flag is set by two main callers:

- `scheduler_tick()` — the timer interrupt handler. On each tick, it calls the active scheduler class's `task_tick()` method. For CFS this translates to `task_tick_fair()`, which calls `entity_tick()` → `check_preempt_tick()`. If the running task has consumed its ideal runtime (`ideal_runtime` computed from `sched_slice()`), `resched_curr()` is called.

- `try_to_wake_up()` — the wake path for blocked tasks. After placing the newly runnable task on its run queue, it calls the active class's `wakeup_preempt()` (e.g., `check_preempt_wakeup()` for CFS), which checks if the woken task's `vruntime` is sufficiently smaller than the current task's. If so, `resched_curr()` is again invoked.

In PREEMPT_LAZY mode (≥ 6.13), most wakeup paths instead set a second, lower-priority flag `TIF_NEED_RESCHED_LAZY`. This lazy flag is only acted upon at voluntary preemption points and timer ticks, not on every interrupt return, allowing the running task to exhaust more of its time slice before yielding.

### The Gate — preempt_count

The flag being set is necessary but not sufficient. The *gate* that must be open for preemption to actually occur is `preempt_count`, stored in `task_struct->thread_info.preempt_count` (or a per-CPU variable on some architectures). This is a packed 32-bit field encoding nested disablement contexts:

```
Bits  0– 7  PREEMPT_MASK    explicit preempt_disable() depth
Bits  8–15  SOFTIRQ_MASK    softirq nesting level
Bits 16–19  HARDIRQ_MASK    hardware IRQ nesting level
Bit  20     NMI_MASK        non-maskable interrupt active
```

The kernel is preemptible if and only if `preempt_count == 0` **and** interrupts are enabled. Every call to `preempt_disable()` increments the low byte; `preempt_enable()` decrements it. Taking a spinlock implicitly calls `preempt_disable()` (in non-RT kernels), so a task holding any spinlock cannot be involuntarily preempted. This is the bedrock guarantee that makes per-CPU data access safe: `get_cpu_var()` disables preemption, ensuring the task cannot migrate to another CPU mid-operation.

Context detection macros read from `preempt_count`:
- `in_interrupt()` — true if SOFTIRQ_MASK or HARDIRQ_MASK bits are non-zero
- `in_atomic()` — true if any bit is non-zero (preemption is unsafe)
- `might_sleep()` — a debug assertion that `in_atomic()` is false

### The Action Side — Checking and Acting

The `TIF_NEED_RESCHED` flag is checked and acted upon at *preemption check points*:

1. **Return from hardware interrupt to kernel space** (CONFIG_PREEMPT only): The architecture's interrupt return path (e.g., `ret_from_intr` on x86) tests `TIF_NEED_RESCHED` and, if `preempt_count == 0`, calls `preempt_schedule_irq()` which invokes `__schedule()` to pick the next task.

2. **preempt_enable()**: When the last `preempt_disable()` is undone, `preempt_enable()` calls `preempt_check_resched()`. If `TIF_NEED_RESCHED` is set it jumps into `preempt_schedule()` → `__schedule()`.

3. **Voluntary preemption points**: `cond_resched()` and `might_sleep()` check `TIF_NEED_RESCHED` and call `schedule()` if set. Under PREEMPT_NONE and PREEMPT_VOLUNTARY, these are the *only* in-kernel preemption points.

4. **Return to user space**: Universally checked across all models in the syscall return path. This is the minimum guarantee: no matter which model is active, a task cannot run in user space forever — it must return through the kernel at some point.

### The Five Preemption Models

**CONFIG_PREEMPT_NONE** — The traditional Unix server model. The kernel only yields at explicit `schedule()` calls, `cond_resched()` sites, or on return to user space. Latency can be tens of milliseconds or more if a kernel path is long. Selected by most server distributions (RHEL, Debian server) where throughput matters and latency is secondary.

**CONFIG_PREEMPT_VOLUNTARY** — Adds a large number of `might_sleep()` and `cond_resched()` calls throughout long kernel loops (memory allocation paths, filesystem journaling, etc.). These become voluntary yield points without full preemptibility. Latency drops to tens of milliseconds typical; still no interrupt-return preemption in kernel space. The traditional desktop kernel choice through the mid-2010s.

**CONFIG_PREEMPT** (Full Preemption) — Enables the interrupt-return and preempt_enable checks described above. Any time `preempt_count == 0` and `TIF_NEED_RESCHED` is set, the scheduler fires. Achieves hundreds-of-microseconds latency. Used for embedded systems, desktop systems with audio/video requirements. Ubuntu desktop and Fedora Workstation have historically shipped this.

**CONFIG_PREEMPT_RT** (Realtime) — The most invasive model, merged mainline circa Linux 6.12 for x86/arm64/riscv. Regular `spinlock_t` becomes a sleeping mutex (`rt_mutex`-backed), so holding a lock no longer disables preemption. Softirqs run in dedicated preemptible kernel threads rather than in interrupt context. Interrupt handlers run in preemptible threads except where `raw_spinlock_t` is used. Priority inheritance (`rt_mutex` PI chains) prevents priority inversion: when a high-priority RT task blocks on a lock held by a low-priority task, the holder's priority is temporarily boosted. Worst-case latency: 10–100 µs with proper tuning. Required for audio/professional/medical/industrial real-time work.

**CONFIG_PREEMPT_LAZY** (≥ 6.13) — A new intermediate mode emerging from PREEMPT_RT performance work. Introduces `TIF_NEED_RESCHED_LAZY` alongside `TIF_NEED_RESCHED`. Most wakeups set the lazy flag; only wakeups of high-priority or RT tasks set the urgent flag. The lazy flag is checked only at voluntary preemption points and tick boundaries, not on every interrupt return. This recovers much of PREEMPT_VOLUNTARY throughput while retaining PREEMPT's preemption infrastructure (no scattered `cond_resched()` dependency). The long-term vision is to collapse the model space down to just PREEMPT_LAZY and PREEMPT_RT.

**CONFIG_PREEMPT_DYNAMIC** (≥ 5.12) — Not a model itself, but a kernel build-time option that enables *runtime* selection among PREEMPT_NONE, PREEMPT_VOLUNTARY, and PREEMPT (not RT) via the `preempt=` kernel command-line parameter. The kernel maintains all the preempt-count metadata even in "none" mode, adding a tiny constant overhead (negligible on modern hardware) in exchange for the ability to ship one kernel binary that serves both server and desktop workloads. Major distributions (Fedora, Ubuntu) have moved to PREEMPT_DYNAMIC.

### PREEMPT_RT: Spinlock Transformation

The key mechanism enabling PREEMPT_RT is the split between `spinlock_t` and `raw_spinlock_t`:

- `raw_spinlock_t` — genuine busy-wait spin lock; still disables preemption; used for scheduler internals, interrupt controllers, and a handful of other paths that genuinely cannot sleep.
- `spinlock_t` under PREEMPT_RT — backed by `rt_mutex`; can sleep; holder remains preemptible; PI protocol prevents priority inversion.

The `rt_mutex` PI chain works as follows: thread A (low priority) holds lock L. Thread B (high RT priority) attempts to acquire L and blocks. The kernel follows L's `owner` pointer back to A and temporarily boosts A's scheduler priority to match B's. If A itself is blocked on another lock held by C, the boost propagates transitively up the chain. When A releases L, B is woken and runs at its real priority; A reverts to its original priority.

## Key Data Structures

**`thread_info.preempt_count`** (`include/linux/thread_info.h`) — the preemption gate; packed 32-bit counter encoding PREEMPT, SOFTIRQ, HARDIRQ, and NMI nesting. Zero means preemptible.
- Accessed via `preempt_count()`, modified via `preempt_disable()` / `preempt_enable()` and the `{get,put}_cpu_var()` family.

**`thread_info.flags`** (`include/linux/thread_info.h`) — per-task flags checked at preemption points.
- `TIF_NEED_RESCHED` — urgent: preempt at next check point
- `TIF_NEED_RESCHED_LAZY` (≥ 6.13) — deferred: preempt at next voluntary or tick point

**`struct rt_mutex`** (`include/linux/rtmutex.h`) — the sleeping mutex used by `spinlock_t` under PREEMPT_RT; contains owner pointer and waiter tree for PI chain traversal.

## Key Functions / Entry Points

**`resched_curr()`** (`kernel/sched/core.c`) — sets `TIF_NEED_RESCHED` on the current CPU's running task; the sole place this flag is raised by scheduler logic.

**`scheduler_tick()`** (`kernel/sched/core.c`) — called from the timer interrupt; drives running preemption by invoking `task_tick()` on the active class, potentially calling `resched_curr()`.

**`check_preempt_wakeup()`** (`kernel/sched/fair.c`) — CFS wakeup preemption check; compares woken task's `vruntime` against current task's to decide if immediate preemption is warranted.

**`preempt_disable()` / `preempt_enable()`** (`include/linux/preempt.h`) — increment/decrement `preempt_count`; `preempt_enable()` checks and executes `preempt_schedule()` if the flag is set.

**`preempt_schedule()`** / **`preempt_schedule_irq()`** (`kernel/sched/core.c`) — the actual preemption entry points that invoke `__schedule(preempt)`, informing `__schedule()` this is a forced preemption (not a voluntary `schedule()` call), so the task remains `TASK_RUNNING` and goes back to the run queue.

**`cond_resched()`** (`include/linux/sched.h`) — voluntary preemption point; checks `TIF_NEED_RESCHED` and calls `schedule()` if set. The backbone of PREEMPT_VOLUNTARY.

**`might_sleep()`** (`include/linux/kernel.h`) — debug assertion + voluntary preemption; calls `cond_resched()` in non-debug builds when PREEMPT_VOLUNTARY is active.

## Important Flags & Config Options

| Kconfig | Effect |
|---|---|
| `CONFIG_PREEMPT_NONE` | No in-kernel preemption; lowest latency overhead, highest throughput |
| `CONFIG_PREEMPT_VOLUNTARY` | Adds `cond_resched()` / `might_sleep()` as yield points |
| `CONFIG_PREEMPT` | Full in-kernel preemption at interrupt returns and preempt_enable |
| `CONFIG_PREEMPT_RT` | Sleeping spinlocks, PI, threaded IRQs; deterministic RT latency |
| `CONFIG_PREEMPT_LAZY` | Two-tier NEED_RESCHED; throughput + preemptible infrastructure |
| `CONFIG_PREEMPT_DYNAMIC` | Runtime model selection via `preempt=` cmdline; enables shipping one kernel for server + desktop |

**Boot parameter** `preempt=none|voluntary|full` — runtime selection under `CONFIG_PREEMPT_DYNAMIC`.

**`/proc/sys/kernel/sched_preempt`** (≥ 6.x) — sysctl to inspect/change the active model at runtime when PREEMPT_DYNAMIC is compiled in.

**`CONFIG_DEBUG_PREEMPT`** — enables preempt_count checking and warns when code sleeps in atomic context. High overhead; development/debug use only.

**`CONFIG_PREEMPTIRQ_TRACEPOINTS`** — enables ftrace events `preempt_disable`, `preempt_enable`, `irq_disable`, `irq_enable` for profiling preemption latency.

## Interactions with Other Subsystems

- **↑ Userspace**: latency-sensitive applications (audio daemons, industrial PLCs) choose their kernel via the Kconfig/cmdline model. PREEMPT_RT was historically a separate patchset that users had to build manually.
- **→ [[locking]]**: spinlock_t semantics change entirely under PREEMPT_RT (sleeping vs. spinning). All code that uses `spinlock_t` gets different behaviour without source changes. `raw_spinlock_t` provides the escape hatch.
- **→ [[interrupt-handling]]**: Under PREEMPT_RT, hard IRQs run as preemptible threaded handlers except where `IRQF_NO_THREAD` is set. Softirqs run in `ksoftirqd` threads, making them preemptible.
- **→ [[context-switch]]**: `__schedule()` is called by all preemption entry points; the actual context switch occurs there via `context_switch()`.
- **← [[cpu-cgroups]]**: cgroup scheduling imposes per-cgroup bandwidth limits which can cause tasks to be throttled; preemption is what makes the CFS bandwidth enforcement timely.
- **← [[rt-scheduler]]**: the RT scheduler's `pick_next_task_rt()` will immediately preempt a lower-priority task; the preemption model must support this fast response.

## Design Decisions & Tradeoffs

**Why four (now five) models instead of one?** Preemption is not free. Each additional check point adds a branch and a potential cache miss. Tracking `preempt_count` even in "no preemption" mode has a cost. For a database server that processes million-row scans in kernel context (e.g., io_uring), the overhead of full preemption degrades throughput measurably. A real-time audio system cannot afford a 50 ms stall. A single model would satisfy neither.

**Why not always use PREEMPT_RT?** Converting spinlocks to sleeping mutexes adds overhead on every lock acquisition (pi-chain bookkeeping, thread scheduling overhead) and fundamentally changes the memory ordering model. Throughput for workloads with high lock contention degrades. The printk subsystem alone required years of work to make RT-safe because log flushing from interrupt context was deeply embedded.

**The cond_resched() problem**: PREEMPT_VOLUNTARY's reliance on `cond_resched()` sprinkled throughout kernel paths is fragile — a new code path that forgets to call it creates a latency regression. PREEMPT_LAZY is designed to eliminate this: the infrastructure is always present, so developers do not need to add yield points manually.

**PREEMPT_DYNAMIC trade-off**: Maintaining preempt-count metadata in PREEMPT_NONE mode costs a few nanoseconds per lock operation. Early benchmarks on Arm showed 1–2% throughput impact on some microbenchmarks. The kernel community decided this was acceptable given the distribution benefit of single-binary shipping.

## How It Has Evolved

- **Pre-2.6**: The kernel was non-preemptible. Only user-space preemption existed.
- **2.6.0 (2003)**: CONFIG_PREEMPT (full preemption) introduced by Robert Love et al., enabling the kernel to be preempted at interrupt returns. A major milestone for Linux desktop and embedded use.
- **~2.6.12 (2005)**: PREEMPT_VOLUNTARY added as an intermediate option.
- **2004–2024**: The PREEMPT_RT patchset, maintained by Ingo Molnár, Thomas Gleixner, and Steven Rostedt, exists as an out-of-tree patchset for 20 years. Piece by piece (high-resolution timers, threaded IRQs, printk rework, etc.) it merges into mainline.
- **5.12 (2021)**: CONFIG_PREEMPT_DYNAMIC introduced by Michal Hocko; distributions start shipping dynamic kernels.
- **6.12 (2024)**: PREEMPT_RT finally fully merged for x86, arm64, and RISC-V in mainline. A two-decade project concludes.
- **6.13 (2025)**: PREEMPT_LAZY added by Thomas Gleixner as the foundation for collapsing the preemption model space toward just LAZY + RT.

## Further Reading

1. [Revisiting the kernel's preemption models (part 1) — LWN 2023](https://lwn.net/Articles/944686/)
2. [Revisiting the kernel's preemption model, part 2 — LWN 2023](https://lwn.net/Articles/945422/)
3. [The long road to lazy preemption — LWN 2024](https://lwn.net/Articles/994322/)
4. [The realtime preemption end game — LWN 2024](https://lwn.net/Articles/989212/)
5. [A realtime preemption overview — LWN 2005](https://lwn.net/Articles/146861/)
6. [kernel-internals.org: Preemption](https://kernel-internals.org/sched/preemption/)
7. [per-cpu preempt_count — LWN 2013](https://lwn.net/Articles/563088/)

## LKML Highlights

- **Voluntary Kernel Preemption Patch (2004)**: Ingo Molnár's original post introducing `might_sleep()`-based voluntary preemption, arguing that explicit yield points give 80% of PREEMPT's latency improvement with 20% of the risk. Sparked debate about whether scatter-gun `cond_resched()` is sustainable long-term — a debate that PREEMPT_LAZY ultimately answers 20 years later.
- **PREEMPT_RT printk series (2021–2024)**: The final blocker for RT mainline merge; Thomas Gleixner's printk rework to make the logging subsystem RT-safe without losing data under panic. Illustrated how a single subsystem's non-RT assumptions could block an entire feature for years.
