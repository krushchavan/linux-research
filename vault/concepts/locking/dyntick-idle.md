---
title: "Dyntick-Idle (NO_HZ)"
category: concept
tags: [locking, rcu, timers, nohz, power-management, scheduling]
subsystem: locking
kernel_version: "2.6.21"
researched: 2026-04-13
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/timers/no_hz.html
  - https://docs.kernel.org/timers/no_hz.html
  - https://lwn.net/Articles/549580/
  - https://lwn.net/Articles/223185/
  - https://lwn.net/Articles/549593/
  - https://www.suse.com/c/cpu-isolation-full-dynticks-part2/
  - https://www.suse.com/c/cpu-isolation-nohz_full-part-3/
  - https://lore.kernel.org/all/20220307233034.34550-1-frederic@kernel.org/
---

# Dyntick-Idle (NO_HZ)

## Purpose

Before dyntick-idle, every CPU received a periodic scheduling-clock interrupt at a fixed rate (HZ times per second — 250 or 1000 on most configurations) regardless of whether anything needed doing. An idle CPU would be woken up hundreds of times a second only to find no work. Dyntick-idle replaces the fixed-rate tick with a one-shot timer programmed to fire only when the next real event is due: the CPU sleeps undisturbed until then, reducing power consumption by 2–3× on battery devices, eliminating unnecessary VMEXIT cycles in virtualised environments, and reducing OS jitter for real-time and HPC workloads.

## Mental Model

Think of dyntick-idle as "smart alarm clock" mode versus "snooze every five minutes" mode. The old periodic tick was the snooze alarm that woke the CPU on every interval even if nothing needed doing. Dyntick-idle looks at the queue of pending timers, finds the earliest deadline, sets a single alarm for exactly that moment, and lets the CPU sleep uninterrupted until it fires — just like setting a single alarm for the exact time you need to wake up.

## How It Works

### Idle Entry: Suppressing the Tick

The sequence begins when a CPU's runqueue empties and the scheduler calls `cpu_idle_loop()`. Before entering the low-power idle state, the CPU calls `tick_nohz_idle_enter()` in `kernel/time/tick-sched.c`. This function does three things in order:

First, it queries the timer infrastructure for the next pending event (via `get_next_timer_interrupt()`). This scans all hrtimers and the timer wheel to find the earliest expiry. Second, it programs the CPU's local clock event device to deliver a single interrupt at that time using `tick_program_event()`, which calls the underlying `clockevents` driver to set a one-shot alarm. Third, it marks the per-CPU `struct tick_sched` — specifically the `ts->tick_stopped` flag — to record that the periodic tick has been suppressed.

Once the alarm is set, the CPU drops into its hardware idle state (via `arch_cpu_idle()`). During this time it receives no scheduling-clock interrupts unless a timer fires or an external interrupt arrives.

### Idle Exit: Restoring the Tick

When the CPU wakes — whether because the one-shot timer fired, an external IRQ arrived, or an IPI was sent — it calls `tick_nohz_idle_exit()`. This function reads the current time, accounts for the elapsed time in the per-CPU `struct tick_sched` (`ts->idle_sleeptime`, `ts->idle_exittime`), restores the periodic tick if other CPUs require time services from this CPU, and re-enables load accounting. The elapsed-time accounting is critical: because no ticks fired, the kernel must reconstruct jiffies and load statistics from the hardware clocksource rather than tick counts.

### RCU's Extended Quiescent State (EQS)

The deepest interaction of dyntick-idle is with [[RCU read-copy-update]]. RCU grace periods require every CPU to pass through at least one *quiescent state* — a point where no RCU read-side critical section is active. Under a periodic tick, each tick interrupt that lands outside an `rcu_read_lock()` region constitutes a quiescent state. But a tick-less idle CPU never receives these interrupts, so it would appear to RCU as permanently stuck, stalling grace periods forever.

The solution is the **RCU Extended Quiescent State (EQS)**: when a CPU enters dyntick-idle, it passively declares itself to be in a continuous quiescent state for the entire duration. The mechanism uses an atomic counter (historically `rcu_dynticks.dynticks`, now `context_tracking.state`) per CPU. The invariant is simple: an **even** value means the CPU is in an extended quiescent state (idle, no RCU readers possible); an **odd** value means the CPU is active. On idle entry, the CPU atomically increments this counter (odd→even) with a full memory barrier. On idle exit, it increments again (even→odd). RCU's grace-period machinery, when scanning for CPUs that have not reported a quiescent state, checks this counter: if it reads an even value, that CPU is passively quiescent for the entire current grace period, and RCU can count it as complete without requiring the CPU to be woken.

Interrupts and NMIs that arrive during idle complicate this picture. An IRQ handler could execute an RCU read-side critical section, so the CPU cannot remain in EQS while handling it. The architecture's IRQ entry path calls `rcu_irq_enter()`, which increments `context_tracking.state` to an odd value (exiting EQS), runs the handler, then calls `rcu_irq_exit()` to decrement back to even — or, if the CPU is no longer idle, leaves it odd. The nested `dynticks_nmi_nesting` field handles NMI nesting on top of IRQ nesting.

### NO_HZ_FULL: Adaptive Ticks for Active CPUs

`CONFIG_NO_HZ_FULL` extends ticklessness beyond idle CPUs to active CPUs running a single task. A CPU designated via `nohz_full=` at boot will suppress its scheduling-clock interrupt whenever only one task is runnable on it. This eliminates the ~1% CPU overhead of periodic interrupts on compute-intensive workloads and eliminates scheduler jitter — crucial for HPC jobs where a single delayed CPU stalls all others at barriers.

For this to work correctly, several services that the tick normally drives must be replaced:

**Context tracking**: The kernel enables `CONFIG_CONTEXT_TRACKING`, which instruments every user↔kernel boundary. Each `ct_user_enter()` / `ct_user_exit()` call updates `context_tracking.state` and notifies RCU that a quiescent state has occurred. Since a CPU in userspace with a single task is by definition not in an RCU read-side critical section, every return-to-user is a quiescent state. The tick can be silent.

**RCU callback offloading**: An nohz_full CPU that enqueues an RCU callback would need to wake periodically to drain it — defeating the purpose. `CONFIG_RCU_NOCB_CPU` offloads callbacks to dedicated `rcuog`/`rcuop` kthreads that run on housekeeping CPUs. With `nohz_full=`, this offloading is applied automatically.

**Scheduler housekeeping**: A residual 1 Hz tick persists even on nohz_full CPUs to drive load-average updates and other scheduler bookkeeping. Unbound workqueues and timers are migrated to non-isolated CPUs at boot.

The CPU exits adaptive-tick mode if: more than one task becomes runnable, a POSIX CPU timer is active, a perf event requires periodic sampling, or the CPU enqueues an RCU callback while NOCB is not configured.

### The Clockevents Abstraction

The entire dyntick-idle mechanism depends on `clockevents`, introduced in 2.6.21 alongside dyntick-idle. Clockevents provides a uniform driver API for hardware timers that can deliver a one-shot interrupt at a specified future time. Before clockevents, timer drivers were per-architecture and could only run in periodic mode. The `struct clock_event_device` abstraction exposes `set_next_event()` to arm the one-shot timer, and the dyntick code uses this to program the next wakeup. The broadcast timer mechanism handles CPUs whose local timers stop in deep C-states: a global broadcast timer fires on behalf of all affected CPUs.

## Key Data Structures

**`struct tick_sched`** (`kernel/time/tick-sched.h`) — per-CPU state for the dyntick-idle and nohz_full machinery.
- `inidle` — set when the CPU is in the idle path
- `tick_stopped` — tick has been suppressed
- `idle_tick` — jiffies value when tick was last stopped
- `idle_sleeptime` / `idle_exittime` — accumulated idle time for accounting
- `next_timer` — expiry of the next pending timer when tick was stopped

**`struct context_tracking`** (`include/linux/context_tracking_state.h`) — per-CPU state used by both NO_HZ_FULL and RCU EQS tracking.
- `state` — atomic_t; even = in EQS (idle or userspace), odd = active kernel context
- `dynticks_nmi_nesting` — nesting depth of NMIs that interrupted an already-interrupted idle CPU
- `nesting` — nesting depth for user↔kernel transitions on nohz_full CPUs

**`struct clock_event_device`** (`include/linux/clockchips.h`) — represents a hardware timer capable of one-shot delivery.
- `set_next_event()` — arms the timer for a specific future ktime
- `features` — `CLOCK_EVT_FEAT_ONESHOT` indicates one-shot capability

## Key Functions / Entry Points

**`tick_nohz_idle_enter()`** (`kernel/time/tick-sched.c`) — called by idle loop on idle entry; stops the tick and programs the next wakeup event.

**`tick_nohz_idle_exit()`** (`kernel/time/tick-sched.c`) — called on idle exit; restores jiffies accounting and re-enables the tick.

**`rcu_idle_enter()`** / **`rcu_idle_exit()`** (`kernel/rcu/tree.c`) — increment/decrement `context_tracking.state` to enter/exit the RCU extended quiescent state.

**`rcu_irq_enter()`** / **`rcu_irq_exit()`** (`kernel/rcu/tree.c`) — temporarily exit EQS during interrupt handling; handle nesting correctly.

**`tick_program_event()`** (`kernel/time/tick-sched.c`) — programs the clockevent device for the next wakeup; calls `clockevents_program_event()`.

**`context_tracking_user_enter()`** / **`context_tracking_user_exit()`** (`kernel/context_tracking.c`) — NO_HZ_FULL path; called at every user/kernel boundary to notify RCU of quiescent states.

**`hrtimer_get_next_event()`** — queries the hrtimer subsystem for the nearest pending timer, used to compute the idle sleep duration.

## Important Flags & Config Options

| Option | Meaning |
|--------|---------|
| `CONFIG_HZ_PERIODIC` | Traditional always-on periodic tick; never omits ticks |
| `CONFIG_NO_HZ_IDLE` | Omit tick on idle CPUs; the default and recommended option |
| `CONFIG_NO_HZ_FULL` | Adaptive ticks: also omit tick on CPUs with one runnable task |
| `CONFIG_NO_HZ_COMMON` | Shared infrastructure selected by both NO_HZ_IDLE and NO_HZ_FULL |
| `CONFIG_CONTEXT_TRACKING` | Instruments user↔kernel transitions; required for NO_HZ_FULL |
| `CONFIG_RCU_NOCB_CPU` | Offloads RCU callbacks to kthreads; required for NO_HZ_FULL |
| `nohz=off` | Boot param: disable dyntick-idle even if compiled in |
| `nohz_full=1,6-8` | Boot param: designate specific CPUs as adaptive-ticks CPUs |
| `rcu_nocbs=1,3-5` | Boot param: offload RCU callbacks from listed CPUs |

**Constraints for NO_HZ_FULL**:
- Boot CPU cannot be adaptive-tick
- At least one non-adaptive-tick CPU must remain online for timekeeping
- A reboot is required to change `nohz_full=` and `rcu_nocbs=` assignments
- POSIX CPU timers may miss deadlines on nohz_full CPUs; tasks using them should be pinned to housekeeping CPUs

## Interactions with Other Subsystems

- **↑ Userspace**: processes and tools like `taskset`/`cpusets` influence which CPUs become isolated; `nohz_full=` is a boot parameter; `/proc/irq/$N/smp_affinity` must be configured to steer hardware IRQs away from isolated CPUs.
- **→ [[RCU read-copy-update]]**: dyntick-idle is the primary mechanism by which idle CPUs report quiescent states to RCU without active participation; the entire EQS protocol is a direct consequence of dyntick's tick suppression.
- **→ [[scheduler]]**: the periodic tick is the scheduler's heartbeat for preemption and load balancing; NO_HZ_FULL breaks this assumption for isolated CPUs, requiring the scheduler to account for "stale" load figures.
- **→ [[interrupt-handling]]**: IRQ entry/exit paths must call `rcu_irq_enter()`/`rcu_irq_exit()` to temporarily exit EQS; NMI paths call separate nesting-aware variants.
- **← clockevents / hrtimers**: dyntick-idle consumes the clockevents one-shot capability; the hrtimer subsystem's next-event query is what determines how long the CPU can sleep.
- **← [[per-cpu-variables]]**: all dyntick and context-tracking state is per-CPU to avoid cache contention and inter-CPU lock overhead.
- **← power management / cpuidle**: dyntick-idle is a prerequisite for entering deep hardware C-states; without a suppressed tick, the CPU would be woken too frequently to stay in C2+.

## Design Decisions & Tradeoffs

**Why even/odd atomic counter rather than a flag?** A boolean flag for "in EQS" would need to be read-modify-written atomically, requiring an expensive locked operation on every idle entry and exit. The even/odd counter requires only an atomic increment (which is cheaper on most architectures) and has the convenient property that the counter value itself encodes nesting depth for IRQs and NMIs — no separate lock is needed to check whether an IRQ interrupted an already-interrupted idle.

**Why a residual 1 Hz tick in NO_HZ_FULL?** Completely eliminating the tick for active CPUs would require every kernel subsystem that relies on periodic callbacks (load averaging, scheduler statistics, watchdog) to be rewritten to operate event-driven. The 1 Hz residual was a pragmatic compromise: it costs almost nothing in terms of jitter (1 interrupt per second vs. 250-1000) while preserving compatibility with subsystems that haven't been converted. Linus Torvalds noted that removing the single-task restriction for NO_HZ_FULL would require this residual tick to be eliminated too, which is a harder problem.

**Why must the boot CPU stay periodic?** The boot CPU is the default timekeeper CPU, responsible for advancing jiffies and driving global timer infrastructure. Making it adaptive-tick would require designating another CPU as the timekeeping guardian, adding complexity for a CPU that typically runs system daemons anyway.

**Dyntick-idle vs. tickless for latency**: Dyntick-idle is beneficial for power and jitter reduction but introduces overhead at idle entry/exit: the CPU must scan timers, reprogram the clockevent device, and perform extra accounting — operations that add microseconds to the idle path. This makes it unsuitable for systems that need sub-microsecond idle transitions and instead want `CONFIG_HZ_PERIODIC`.

## How It Has Evolved

**2.6.21 (2007)**: First dyntick-idle for x86_64, introduced alongside the `clockevents` abstraction that made one-shot timer programming architecture-independent. Only idle CPUs benefited; the tick was still mandatory when any task ran.

**2.6.27 (2008)**: Extended to ARM, MIPS, and PowerPC as those architectures gained clockevents drivers.

**3.10 (2013)**: `CONFIG_NO_HZ_FULL` (then called "full dynticks") added by Frederic Weisbecker and Paul McKenney, extending tickless operation to CPUs with a single runnable task. Required substantial RCU rework to handle quiescent states through context tracking rather than tick interrupts.

**~4.x (2014–2016)**: Scheduler CPU load accounting rewritten to correctly handle nohz periods (no ticks = no samples → stale load values). `nohz_full=` began auto-configuring `rcu_nocbs=` to remove a manual configuration step.

**5.x (2019–2021)**: `CONFIG_RCU_FAST_NO_HZ` removed after the context-tracking approach made it obsolete. `struct rcu_dynticks` fields folded into `struct context_tracking`, unifying the two tracking mechanisms.

**Recent (5.x–6.x)**: Continued cleanup: `rcu_dynticks_curr_cpu_in_eqs()` renamed to `rcu_watching_curr_cpu()`; `dynticks_nmi_nesting` renamed to `nmi_nesting`; softirq-in-idle warnings improved. The goal of a truly tickless kernel (zero ticks, even the 1 Hz residual) remains open.

## Further Reading

1. [NO_HZ: Reducing Scheduling-Clock Ticks — kernel.org](https://docs.kernel.org/timers/no_hz.html) — the authoritative documentation; explains all three modes and their constraints.
2. [(Nearly) full tickless operation in 3.10 — LWN, 2013](https://lwn.net/Articles/549580/) — covers the NO_HZ_FULL introduction and design debate.
3. [Clockevents and dyntick — LWN, 2007](https://lwn.net/Articles/223185/) — historical context of the 2.6.21 introduction and the clockevents abstraction.
4. [CPU Isolation – Full dynticks internals — SUSE Labs](https://www.suse.com/c/cpu-isolation-full-dynticks-part2/) — explains the four service-replacement strategies used by NO_HZ_FULL.
5. [CPU Isolation – nohz_full — SUSE Labs](https://www.suse.com/c/cpu-isolation-nohz_full-part-3/) — practical guide to configuring and using nohz_full for CPU isolation.
6. [task isolation discussion at Linux Plumbers — LWN, 2016](https://lwn.net/Articles/705853/) — debate on extending dyntick-idle ideas toward full task isolation.

## LKML Highlights

- **`20220307233034.34550-4-frederic@kernel.org`** (Frederic Weisbecker, 2022): Cleanup series removing `CONFIG_RCU_FAST_NO_HZ` and fixing `RCU_SOFTIRQ`-in-idle edge cases — illustrates how the nohz layout simplified significantly over a decade of evolution, eliminating workarounds that were added when context tracking didn't exist yet.
- **`169861501181.181063.11456638002426777407.tglx@xen13`** (Thomas Gleixner, 2023): timers/core pull for 6.7-rc1 — shows the ongoing maintenance work in tick-sched.c as timer internals continue to be refined.
