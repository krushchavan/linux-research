---
title: "PSI — Pressure Stall Information"
category: concept
tags: [mm, psi, memory-pressure, cgroups, monitoring]
subsystem: mm
kernel_version: "4.20"
researched: 2026-04-16
status: complete
explained: "[[psi-pressure-stall-information-explained]]"
sources:
  - https://kernel-internals.org/mm/psi/
  - https://www.kernel.org/doc/html/latest/accounting/psi.html
  - https://lwn.net/Articles/759781/
  - https://lwn.net/Articles/759658/
  - https://facebookmicrosites.github.io/psi/docs/overview
  - https://github.com/torvalds/linux/blob/master/kernel/sched/psi.c
  - https://github.com/torvalds/linux/blob/master/include/linux/psi_types.h
  - https://unixism.net/2019/08/linux-pressure-stall-information-psi-by-example/
---

# PSI — Pressure Stall Information

> 📘 Plain-language version: [[psi-pressure-stall-information-explained]]

## Purpose

PSI measures how much time tasks spend *stalled* — waiting for CPU, memory, or I/O
resources rather than doing productive work. Traditional metrics like CPU utilisation
percentage and free memory bytes describe what the hardware is doing; PSI describes what
the *workload* is suffering. A machine running at 30% CPU utilisation can still have
severe memory pressure if its tasks are mostly blocked in page reclaim. PSI makes that
invisible suffering visible and quantifiable, enabling automated load-shedding, cgroup
resource tuning, and early OOM prevention.

## Mental Model

Think of PSI as a stopwatch that runs whenever tasks are stuck at a red light waiting for
a resource, and pauses the moment they are moving again. The stopwatch runs at two
different levels of severity: *some* (at least one task stuck) and *full* (every
non-idle task stuck, so even CPUs are wasted). The ratio of stopwatch-running time to
wall-clock time is the pressure percentage reported in `/proc/pressure/*`.

## How It Works

### Entry point: task state transitions

Every time a task enters or leaves a resource-waiting state, the scheduler (or memory
reclaim path) calls `psi_task_change()` in `kernel/sched/psi.c`. The function is
called with the task, the old flags, and the new flags. Four PSI-relevant task states
are tracked via `enum psi_task_count`:

```c
enum psi_task_count {
    NR_IOWAIT,           /* waiting for block I/O completion */
    NR_MEMSTALL,         /* waiting for memory (reclaim, swap-in, refault) */
    NR_RUNNING,          /* on a runqueue (eligible for CPU) */
    NR_MEMSTALL_RUNNING, /* running but inside synchronous reclaim */
    NR_PSI_TASK_COUNTS
};
```

There is also a virtual flag `TSK_ONCPU` that marks a task actually executing on a core.
`NR_MEMSTALL_RUNNING` matters because a task spinning in direct reclaim *is* consuming a
CPU but contributing nothing useful; it belongs in the "some" stall bucket even though
it is technically running.

`psi_task_change()` updates the per-task flags and propagates the change up the cgroup
hierarchy — each cgroup in the chain from the task's cgroup to the root gets its
per-CPU counters updated by `psi_group_change()`.

### Per-CPU accounting: psi_group_cpu

All hot-path accounting is per-CPU to avoid cross-CPU locking. Each `struct psi_group`
(one system-wide, one per cgroup) contains a per-CPU array of `struct psi_group_cpu`:

```c
struct psi_group_cpu {
    seqcount_t              seq;         /* protect readers from torn writes */
    unsigned int            tasks[NR_PSI_TASK_COUNTS];  /* task counts per state */
    u32                     state_mask;  /* bitmask of active pressure states */
    u32                     times[NR_PSI_STATES]; /* ns spent in each state since last agg */
    u64                     state_start; /* rq_clock when state_mask last changed */
    u32                     times_prev[2][NR_PSI_STATES]; /* delta detection ring buffer */
};
```

`psi_group_change()` is the hot-path function. After `psi_task_change()` adjusts task
counts, `psi_group_change()` calls the internal `test_states()` helper to derive a new
`state_mask` from the current task counters: does at least one task need a resource
(SOME), or do all non-idle tasks need it (FULL)? It then measures elapsed time since
`state_start` and adds it to the appropriate `times[]` bucket for the *old* state_mask.
The counters are 32-bit (keeping the struct small and cache-friendly); overflow is
handled during aggregation. The whole update is bracketed by `write_seqcount_begin/end`
so readers can detect concurrent modification.

### Periodic aggregation: psi_avgs_work

The times[] buckets accumulate raw nanosecond deltas per CPU. Turning those into the
exponentially-weighted moving averages (EWMAs) users see requires collecting all CPUs'
contributions. This is done by `psi_avgs_work()`, which runs as a delayed work item
every **2 seconds** while the system is active, or on-demand when a user reads
`/proc/pressure/*`.

The aggregator visits every online CPU, reads `times[]` under the seqcount, accumulates
total stall time and non-idle time, then feeds the result into the running EWMAs for the
10 s, 60 s, and 300 s windows. The EWMA update formula weights the most recent 2-second
sample against the existing average, scaled to produce a percentage:

```
avg = avg * e^(-dt/window) + sample * (1 - e^(-dt/window))
```

Because the aggregation period is fixed at 2 s, the coefficients are pre-computed
constants at compile time. The *total* microsecond counter is simply the sum of all
stall deltas since boot — it never decays and is useful for detecting brief spikes that
would be lost in the smoothed averages.

When there are no tasks and the system is idle, the work item backs off (does not
reschedule itself) to avoid burning CPU on a fully-idle machine.

### Trigger notifications (v5.2+)

The base PSI interface is polled: userspace reads `/proc/pressure/memory` and computes
trends itself. For tight real-time control (e.g. killing a cgroup before OOM), latency
must be under 100 ms — far too slow for a 2-second aggregation loop.

Triggers allow userspace to register an interrupt-style threshold. A process opens the
pressure file, writes a specification string, then calls `poll()` on the fd:

```c
/* Wake me if ≥100 ms of "some" memory stall accumulates in any 1-second window */
const char *spec = "some 100000 1000000";   /* us stall, us window */
write(fd, spec, strlen(spec) + 1);
struct pollfd pfd = { .fd = fd, .events = POLLPRI };
poll(&pfd, 1, -1);
```

Window constraints: 500 ms–10 s; unprivileged users must use multiples of 2 s. One file
descriptor per trigger; multiple triggers on the same resource are allowed.

When a trigger is registered, the kernel arms a high-frequency aggregation timer at the
trigger's window granularity (minimum 50 ms), much faster than the background 2 s loop.
When accumulated stall time within the window exceeds the threshold, `POLLPRI` is posted
on the fd. Systemd-oomd, Android LMKD, and Meta's oomd daemon all use this interface to
react to memory pressure before the OOM killer fires.

### Cgroup integration

Per-cgroup PSI was part of the original v4.20 patchset. Each cgroup2 group exposes:

```
/sys/fs/cgroup/<group>/cpu.pressure
/sys/fs/cgroup/<group>/memory.pressure
/sys/fs/cgroup/<group>/io.pressure
```

The `psi_group_change()` hot path walks the cgroup ancestry from the task's leaf cgroup
up to root, updating each group's per-CPU counters. This is slightly expensive for deep
hierarchies but is the only way to get accurate aggregated pressure per subtree. The walk
is bounded by the cgroup depth limit.

### Reading the numbers

`psi_show()` in `kernel/sched/psi.c` formats the output for `/proc/pressure/*`:

```
some avg10=4.67 avg60=2.13 avg300=0.85 total=2345678
full avg10=0.00 avg60=0.00 avg300=0.00 total=123456
```

CPU pressure only reports `some`, not `full`: if every task is waiting for CPU, the CPU
is by definition idle — not stalled — so `full` is logically meaningless for CPU. Memory
and I/O have both lines.

## Key Data Structures

**`struct psi_group_cpu`** (`include/linux/psi_types.h`) — per-CPU accounting for one
pressure group (system or cgroup). The first cache line holds hot scheduler state.
- `tasks[]` — live count of tasks in each `psi_task_count` state on this CPU
- `state_mask` — bitmask of currently active SOME/FULL states, derived from `tasks[]`
- `times[]` — nanoseconds spent in each state since last aggregation snapshot
- `state_start` — `rq_clock` timestamp when `state_mask` last changed
- `times_prev[]` — two-slot ring buffer for delta detection across aggregation cycles

**`struct psi_group`** (`include/linux/psi_types.h`) — per-group state shared across
CPUs; one instance at `init_task.signal->psi` for the global group, and one embedded in
each cgroup.
- `pcpu` — pointer to the per-CPU `psi_group_cpu` array
- `avg[]` — current EWMAs for each resource × each pressure level
- `total[]` — cumulative stall time in microseconds per state
- `avg_work` — delayed_work handle for the 2-second background aggregator
- `rtpoll_work` — work handle for the high-frequency trigger aggregator
- `poll_nb` — notifier list of registered trigger waitqueues

**`enum psi_res`** — `PSI_IO=0`, `PSI_MEM=1`, `PSI_CPU=2`, optionally `PSI_IRQ` with
`CONFIG_IRQ_TIME_ACCOUNTING`.

## Key Functions / Entry Points

**`psi_task_change()`** (`kernel/sched/psi.c`) — called by `activate_task()`,
`deactivate_task()`, and memory reclaim paths; propagates a task's flag change to all
ancestor psi_groups.

**`psi_group_change()`** (`kernel/sched/psi.c`) — updates one `psi_group_cpu`: adjusts
task counters, derives new `state_mask`, records elapsed time in old state.

**`psi_avgs_work()`** (`kernel/sched/psi.c`) — delayed-work handler; collects per-CPU
deltas and updates EWMAs; runs every 2 s or on-demand at read time.

**`psi_show()`** (`kernel/sched/psi.c`) — seq_file show callback for
`/proc/pressure/{cpu,memory,io}`; triggers an on-demand aggregation pass then formats
the numbers.

**`psi_trigger_create()`** / **`psi_poll_worker()`** (`kernel/sched/psi.c`) — register
a userspace trigger and run the high-frequency poll aggregator respectively.

**`psi_memstall_enter()` / `psi_memstall_leave()`** (`include/linux/psi.h`) — called by
`mm/vmscan.c` and swap paths to bracket the time a task spends in memory reclaim.

## Important Flags & Config Options

| Symbol / knob | Effect |
|---|---|
| `CONFIG_PSI` | Enable PSI; off by default before 5.2, on by default from 5.13+ |
| `CONFIG_PSI_DEFAULT_DISABLED` | Build with PSI compiled in but disabled at boot |
| `psi=1` / `psi=0` | Kernel command-line override to force enable/disable at boot |
| `/proc/pressure/cpu` | System-wide CPU stall percentages |
| `/proc/pressure/memory` | System-wide memory stall percentages |
| `/proc/pressure/io` | System-wide I/O stall percentages |
| Trigger window (`500ms`–`10s`) | Minimum 500 ms, maximum 10 s; unprivileged: must be multiple of 2 s |

## Interactions with Other Subsystems

- **↑ Userspace**: reads `/proc/pressure/*` for metrics; writes triggers and calls
  `poll()` / `epoll()` for event-driven notifications; systemd-oomd, Android LMKD, and
  oomd consume PSI to kill cgroups proactively.
- **→ [[memory-cgroup]]**: per-cgroup PSI files live in cgroup2 hierarchy; hot path
  walks the cgroup ancestry to update every ancestor's pressure group.
- **← [[page-reclaim]]**: `mm/vmscan.c` calls `psi_memstall_enter/leave` to bracket
  time in direct reclaim; the refault tracking in page reclaim feeds memory stall flags.
- **← [[swap]]**: swap-in paths set `NR_MEMSTALL` on the waiting task.
- **← scheduler**: `activate_task()` and `deactivate_task()` call `psi_task_change()`
  to reflect runqueue transitions.
- **→ [[oom-killer]]**: PSI-based daemons (systemd-oomd) are intended to replace the
  in-kernel OOM killer for most workloads, reacting earlier and more selectively.

## Design Decisions & Tradeoffs

**Why "some" and "full" rather than a single metric?** A single stall count would be
ambiguous: one task blocked on swap-in while 31 others run productively is very
different from all 32 tasks blocked. "some" captures resource availability pressure;
"full" captures lost CPU capacity. Both are needed to distinguish degraded service from
total stall.

**Why EWMAs over fixed windows?** Fixed-window averages reset abruptly at window
boundaries, creating step artifacts in monitoring graphs. EWMAs are continuous but still
provide the semantic of "pressure over the last N seconds". The three window sizes
(10 s / 60 s / 300 s) mirror the traditional Unix load-average convention, making
adoption by existing monitoring systems easier.

**Why keep the `total` microsecond counter?** The EWMAs smooth away short spikes. A
10-second burst of full memory stall followed by 50 seconds of calm would show up as
~17% avg60, potentially below an alert threshold. The `total` counter grows monotonically
and can be differenced between two reads to detect any-sized spike.

**Per-CPU counters vs. global atomics**: Updating a global atomic on every task state
transition (which happens hundreds of thousands of times per second) would cause extreme
cache-line bouncing. Per-CPU counters eliminate this; the cost is that aggregation must
visit all CPUs, but aggregation runs only every 2 s or on-demand at read time, making
the trade-off extremely favourable.

**No `full` for CPU**: If every runnable task is waiting for CPU, the CPU is idle — the
pressure is captured by the task's absence from the runqueue, not by a stall state. The
"full" metric would always be 0% for CPU and is therefore omitted.

**Refault tracking for memory**: Plain page faults include first-access faults (normal
program startup) which are not pressure-indicating. PSI for memory counts only
*refaults* — pages that were previously evicted under pressure and must be re-read. This
avoids false positives when a workload is simply loading new data.

## How It Has Evolved

**v4.20 (Dec 2018)** — Initial PSI merged by Johannes Weiner (Meta), covering system-wide
and per-cgroup CPU, memory, and I/O pressure. Commit `eb414681d5a0` introduced the core
infrastructure. Meta had been running PSI internally for several kernel versions before
upstreaming.

**v5.2 (2019)** — PSI triggers added by Suren Baghdasaryan, enabling `poll()`/`epoll()`
notification when a threshold is crossed. This unlocked real-time, low-latency
applications like Android LMKD replacing the in-kernel lowmemorykiller.

**v5.13 (2021)** — `CONFIG_PSI` enabled by default on most distro configs; previously
opt-in at compile time. `CONFIG_PSI_DEFAULT_DISABLED` added to allow distros to build it
in but require `psi=1` at boot.

**v5.19 / v6.x** — IRQ pressure tracking added (`PSI_IRQ`) under
`CONFIG_IRQ_TIME_ACCOUNTING`; measures time the system loses to interrupt handling
rather than task work.

**v6.0+ (ongoing)** — Continued refinements to the high-frequency trigger aggregator to
reduce overhead on large-CPU-count machines; improvements to accuracy on NUMA systems.

## Further Reading

1. [Tracking pressure-stall information (LWN, 2018)](https://lwn.net/Articles/759781/) — the original article by Jonathan Corbet covering the v2 patchset and design rationale
2. [psi: pressure stall information for CPU, memory, and IO v2 — LKML cover letter](https://lwn.net/Articles/759658/) — Johannes Weiner's detailed design document
3. [PSI — Pressure Stall Information (kernel.org)](https://www.kernel.org/doc/html/latest/accounting/psi.html) — authoritative user-facing documentation
4. [kernel-internals.org — PSI](https://kernel-internals.org/mm/psi/) — design rationale and internals
5. [Facebook PSI microsite](https://facebookmicrosites.github.io/psi/docs/overview) — use-case documentation from Meta
6. [Linux PSI by Example (unixism.net)](https://unixism.net/2019/08/linux-pressure-stall-information-psi-by-example/) — worked examples of the trigger interface

## LKML Highlights

**v2 cover letter** (`LWN:759658`): Weiner explains the SOME vs FULL distinction in
detail and justifies using EWMAs rather than instantaneous measurements; reviewers pushed
back on per-cgroup overhead, leading to the seqcount-based per-CPU design.

**PSI triggers patchset** (`20181214171508.7791-1-surenb@google.com`): Baghdasaryan's
cover letter describes the Android LMKD use case and the 50 ms minimum poll interval
chosen to keep trigger overhead under 0.5% CPU on a busy system.
