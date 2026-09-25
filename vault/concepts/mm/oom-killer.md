---
title: "OOM Killer"
category: concept
tags: [mm, oom, memory-pressure, process-management, cgroups]
subsystem: mm
kernel_version: "2.4"
researched: 2026-04-10
status: complete
explained: "[[oom-killer-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/mm/concepts.html
  - https://www.kernel.org/doc/gorman/html/understand/understand016.html
  - https://github.com/ljskernel/linux-vm-notes/blob/master/sections/oom.md
  - https://lwn.net/Articles/317814/
  - https://lwn.net/Articles/391222/
  - https://lwn.net/Articles/684945/
  - https://lwn.net/Articles/761118/
  - https://lwn.net/Articles/666024/
  - https://howtech.substack.com/p/linux-oom-killer-how-the-kernel-decides
  - https://blog.wesleyac.com/posts/linux-kernel-oom-killer
---

# OOM Killer

> 📘 Plain-language version: [[oom-killer-explained]]

## Purpose

When physical memory and swap are exhausted and the [[page-reclaim]] subsystem cannot free enough pages to satisfy an allocation, the kernel faces a choice: stall indefinitely, panic, or sacrifice one process to reclaim its memory. The OOM killer implements the third option — it selects and kills a single process whose death is expected to free enough memory for the system to continue operating. Without it, a fully loaded machine would either deadlock or require an operator-initiated reboot.

## Mental Model

Think of the OOM killer as a triage surgeon in a disaster scenario. Resources are gone, every route to new supply is blocked, and the only way to save the ward is to make the hardest possible decision about which patient's bed to reallocate. The surgeon (the kernel) scores every patient (process) by how much memory they hold versus how important they seem, then makes a cut. The OOM reaper is the orderly who doesn't wait for the patient to formally vacate — it strips the bed immediately so others can use the space.

## How It Works

### Triggering the OOM Killer

The OOM killer is a last resort, reached only after the allocator has exhausted every reclaim path. When a caller invokes `__alloc_pages()` and normal allocation fails, the slow path `__alloc_pages_slowpath()` kicks in: it wakes `kswapd`, tries direct reclaim at progressively higher scan priorities, and attempts memory compaction. Only after all of this fails repeatedly — when nothing can be reclaimed from any LRU list or compacted to form a free block — does the allocator call `out_of_memory()`.

Two other entry points exist: `mm_fault_error()` reaches `out_of_memory()` when a page fault cannot be satisfied after all reclaim is exhausted, and `mem_cgroup_oom_synchronize()` intercepts OOM conditions scoped to a [[memory-cgroup]], allowing container-level policy without invoking the global killer.

### `out_of_memory()` — the decision point

`out_of_memory()` in `mm/oom_kill.c` is protected by `oom_lock`, a global mutex that serialises concurrent OOM events on SMP systems. The function performs a sequence of sanity checks before committing to a kill:

1. **Is the OOM killer disabled?** `vm.oom_kill_allocating_task` and `vm.panic_on_oom` are checked. If panic mode is set, the kernel calls `panic()` directly.
2. **Has a notifier handled it?** `oom_notifier_call_chain()` fires a blocking notifier so that userspace daemons (e.g. `earlyoom`) registered via `register_oom_notifier()` can free memory themselves. If a notifier claims success the killer backs off.
3. **Is there already a dying victim?** If any task carries the `TIF_MEMDIE` thread flag (meaning it was already selected and is exiting), the killer waits rather than killing again — no point piling on while memory is already being freed.
4. **Fatal signal pending?** If the allocating task is already dying, the kernel returns and lets that exit free memory naturally.

If all checks pass and `vm.oom_kill_allocating_task` is set, the currently running task becomes the immediate candidate. Otherwise, `select_bad_process()` walks every process on the system and scores each one.

### Scoring: `oom_badness()`

`select_bad_process()` iterates all tasks via `for_each_process_thread()`. For each candidate it calls `oom_scan_process_thread()` first to classify the task:

- **`OOM_SCAN_ABORT`**: the task holds `TIF_MEMDIE` (already dying) — abort the entire scan and wait.
- **`OOM_SCAN_SELECT`**: the task is the origin of the OOM (flagged via `signal->oom_flags & OOM_FLAG_ORIGIN`) — select it immediately.
- **`OOM_SCAN_CONTINUE`**: the task is unkillable (PID 1, a kernel thread, or in a vfork) — skip.
- **`OOM_SCAN_OK`**: proceed to `oom_badness()`.

`oom_badness()` computes a single integer score on a 0–1000 scale representing "what fraction of available memory does this process consume?":

```c
points = get_mm_rss(mm)       // anonymous + file-backed pages in RAM
       + get_mm_counter(mm, MM_SWAPENTS)  // pages pushed to swap
       + mm_pgtables_bytes(mm) / PAGE_SIZE // page table overhead
```

The raw point total is then adjusted:

- **`CAP_SYS_ADMIN`**: 3% discount (the privileged process is assumed more important).
- **`oom_score_adj`** (`/proc/<pid>/oom_score_adj`, range −1000 to +1000): `adj = oom_score_adj * total_memory_pages / 1000`. This is added directly to `points`, meaning a score of −1000 zeroes out the process entirely (immune) and +1000 adds one full RAM worth of virtual penalty.

The function returns 0 for immune processes (making them impossible to select), and a minimum of 1 for all others to avoid ties at zero.

`select_bad_process()` tracks the highest scorer across the walk. Thread groups are evaluated as units: if any thread in a process group scores highest, the whole process is the victim.

### Killing: `oom_kill_process()`

Once a victim is chosen, `oom_kill_process()` handles the kill with a refinement: rather than killing the selected process directly, it first scans the process's children for any that do not share the parent's `mm_struct`. If a first-generation child has a higher `oom_badness()` score than the parent, that child becomes the actual victim — freeing the child's memory may be just as effective and the parent might be more valuable.

The actual kill sequence is:

1. **Log an OOM report** to the kernel ring buffer: a dump of meminfo, the victim's details, and a `sysrq-m`-style summary.
2. **Send `SIGKILL`** to the victim via `do_send_sig_info()`.
3. **Call `mark_oom_victim()`**: sets `TIF_MEMDIE` on every thread sharing the victim's `mm_struct`, raises `MMF_OOM_SKIP` on the mm so the page allocator knows reclaim is in progress, and wakes the OOM reaper via `wake_oom_reaper()`.
4. **Broadcast `SIGKILL`** to all processes sharing the same `mm_struct` (e.g., threads in the same process).

### OOM Reaper

The fundamental problem with just sending `SIGKILL` is that the victim may be blocked waiting for a lock held by another process that is also stuck in `__alloc_pages()`. In that case the victim never runs, its memory is never freed, and the system is deadlocked.

The OOM reaper solves this. It is a dedicated kernel thread (started at boot as `oom_reaper`) waiting on `oom_reaper_wait`. When `wake_oom_reaper()` is called, it places the victim's `mm_struct` on a single-item queue using an atomic compare-and-swap (`cmpxchg`), preventing races when multiple victims accumulate.

`oom_reap_task()` / `__oom_reap_task_mm()` performs the actual work:

1. Check if `mm->mm_users` is already 0 (the process has exited) — if so, done.
2. Take `down_read_trylock(&mm->mmap_lock)` (the mmap reader-writer semaphore). If it fails, retry up to 10 times with ~10 ms delays to avoid spinning. This non-blocking approach is critical: a blocking `down_read()` could deadlock if the lock holder is also waiting for memory.
3. Walk every VMA in the process and call `unmap_page_range()` on those that are **not**: hugetlb (architecture-sensitive), `mlock`-pinned (locked in RAM by user), or file-backed shared (unmapping could cause data loss for other processes).
4. After unmapping, the freed page frames are returned to the buddy allocator, immediately visible as `MemFree` in `/proc/meminfo`.
5. Set `oom_score_adj` to `OOM_SCORE_ADJ_MIN` on the victim to prevent it from being selected again if it hasn't exited yet.
6. Call `exit_oom_victim()` to clear `TIF_MEMDIE` and decrement `mm->mm_users` via `mmput()`.

The reaper runs independently of whether the victim's signal handler runs, so memory is freed even if the victim is completely blocked. This turned the OOM killer from an occasional deadlock source into a reliable recovery mechanism.

### memcg-scoped OOM

When memory cgroups ([[memory-cgroup]]) are in use, OOM events can be scoped to a single cgroup rather than the whole system. `mem_cgroup_oom_synchronize()` intercepts the OOM before `out_of_memory()` is reached; it consults the cgroup's `oom_control` file to decide whether to kill or wait, and runs `select_bad_process()` restricted to tasks within the cgroup's hierarchy.

The `memory.oom_group` knob (added in 5.4) changes behavior: if set, the entire cgroup is killed rather than one process. Roman Gushchin's work also added two-phase cgroup targeting: the algorithm first selects the cgroup consuming the most memory (within the hierarchy), then selects the worst process inside that cgroup.

## Key Data Structures

**`struct task_struct`** (`include/linux/sched.h`) — process descriptor; the OOM killer reads several fields:
- `signal->oom_score_adj` — per-process tunable (−1000 to +1000)
- `signal->oom_flags` — includes `OOM_FLAG_ORIGIN` to mark the task that triggered the OOM
- `mm` — pointer to the process's memory descriptor

**`struct mm_struct`** (`include/linux/mm_types.h`) — memory descriptor for a process:
- `mm_users` — reference count; reaper decrements this when done
- `flags` — includes `MMF_OOM_SKIP` to signal that this mm is being reaped
- `mmap_lock` — reader-writer semaphore protecting the VMA list; reaper uses trylock

**Thread flags** (per-thread bits in `task_struct->flags`):
- `TIF_MEMDIE` — set by `mark_oom_victim()`; tells the memory allocator to give this task a last-chance allocation so it can exit, and tells `select_bad_process()` to abort further scanning (a victim is already dying)

**`struct oom_control`** (`include/linux/oom.h`) — groups the context passed through the OOM path:
- `zonelist` / `nodemask` — the NUMA allocation context; restricts victim search to the right memory domain
- `memcg` — if non-NULL, restricts kill to this cgroup hierarchy
- `order` — allocation order that triggered OOM
- `chosen` — the winning `task_struct *` after `select_bad_process()` returns

## Key Functions / Entry Points

**`out_of_memory()`** (`mm/oom_kill.c`) — top-level entry point; called by the page allocator and page fault handler after reclaim fails; serialised by `oom_lock`.

**`select_bad_process()`** (`mm/oom_kill.c`) — walks all tasks, calling `oom_scan_process_thread()` then `oom_badness()` for each; returns the highest scorer in `oom_control->chosen`.

**`oom_badness()`** (`mm/oom_kill.c`) — computes the 0–1000 score for one process; called by `select_bad_process()` and directly when `vm.oom_kill_allocating_task` is set.

**`oom_kill_process()`** (`mm/oom_kill.c`) — logs the kill, sends SIGKILL, calls `mark_oom_victim()`, wakes the reaper.

**`mark_oom_victim()`** (`mm/oom_kill.c`) — sets `TIF_MEMDIE`, sets `MMF_OOM_SKIP`, wakes the reaper.

**`oom_reap_task()`** / **`__oom_reap_task_mm()`** (`mm/oom_kill.c`) — reaper thread body; unmaps anonymous VMAs from the victim's address space using `unmap_page_range()`.

**`mem_cgroup_oom_synchronize()`** (`mm/memcontrol.c`) — cgroup-scoped OOM handler; called instead of `out_of_memory()` when the failing allocation is under a cgroup limit.

## Important Flags & Config Options

| Knob | Location | Effect |
|------|----------|--------|
| `/proc/<pid>/oom_score_adj` | per-process | −1000 = immune; +1000 = always killed first |
| `/proc/<pid>/oom_score` | per-process (read-only) | current computed badness score |
| `vm.panic_on_oom` | sysctl | 0 = invoke killer; 1 = panic on OOM; 2 = panic even with cpuset constraints |
| `vm.oom_kill_allocating_task` | sysctl | 1 = kill the task that triggered OOM instead of scoring all processes |
| `vm.oom_dump_tasks` | sysctl | 1 = dump per-process memory stats to dmesg on OOM (default on) |
| `memory.oom_group` | cgroup v2 | 1 = kill the entire cgroup on OOM, not just one process |
| `memory.oom_control` | cgroup v1 | can disable OOM killer inside a cgroup and deliver notifications instead |
| `CONFIG_MEMCG` | Kconfig | enables cgroup memory accounting; required for per-cgroup OOM |

## Interactions with Other Subsystems

- **↑ Userspace**: Processes can tune `oom_score_adj` via `/proc`; daemons can register OOM notifiers (`register_oom_notifier()`) to act before the kernel kills anything. `earlyoom` and `systemd-oomd` use this to implement proactive killing.
- **→ [[page-reclaim]]**: The OOM killer is only invoked after page reclaim reports complete failure. `out_of_memory()` is called from `__alloc_pages_slowpath()` and from the direct-reclaim path when `should_reclaim_retry()` returns false.
- **→ [[buddy-allocator]]**: Freed pages from the reaper flow directly back to the buddy allocator's free lists; `TIF_MEMDIE` grants the dying task an unconditional allocation bypass so it can run its exit path.
- **→ [[memory-cgroup]]**: cgroup memory limits can trigger their own OOM path before the system-wide killer fires; `memory.oom_group` and `oom_control` give operators per-container kill policy.
- **→ [[virtual-memory-areas]]**: The reaper iterates VMAs to unmap anonymous memory; it deliberately skips shared file-backed mappings to avoid corrupting other processes' views.
- **← [[page-fault-handler]]**: `mm_fault_error()` calls `out_of_memory()` when a fault cannot be satisfied after all reclaim is exhausted.
- **← NUMA**: `oom_control->nodemask` restricts victim selection to tasks allocated on the exhausted NUMA node, avoiding unfair kills of processes using a different node's memory.

## Design Decisions & Tradeoffs

**Score simplicity over precision.** The 0–1000 percentage-of-memory formula deliberately abandoned the original heuristic soup (CPU time, uptime, nice values, capability bitmask discounts) in favour of a single question: "how much of our scarce resource does this process hold?" This makes the outcome predictable and auditable but means a long-running important daemon that happens to consume a lot of memory looks the same as a runaway leak.

**`oom_score_adj` as the operator escape hatch.** Rather than trying to make the kernel smart about process importance, the kernel exposes a simple bias knob and leaves the policy to operators and daemons. A value of −1000 grants absolute immunity; systemd sets it on critical system services. This accepts that operators must actively manage OOM priorities rather than trusting heuristics.

**The reaper as a separate thread.** An earlier design killed the victim inline and waited for it to exit. The reaper decouples "memory freed" from "process exited", which is essential when the victim is blocked on a lock. The tradeoff is complexity: the reaper cannot safely unmap everything (shared mappings, hugetlb), so some memory may only be freed when the process finally exits. On very low-memory systems the reaper may leave the system still tight until the victim's full exit path completes.

**No kill ordering guarantees.** The OOM killer kills one process and then backs off, waiting for `TIF_MEMDIE` to clear before deciding whether another kill is needed. This can be slow if the first victim's exit path allocates memory to clean up. `systemd-oomd`'s approach — kill entire cgroups immediately and aggressively — trades collateral damage for speed of recovery.

**Avoiding 32-bit low-memory zone OOM.** When only the low-memory zone (ZONE_DMA/ZONE_DMA32) is exhausted on a 32-bit system, the allocator fails the request outright rather than invoking the OOM killer. Killing processes to free high-memory pages would not help a low-memory zone allocation.

## How It Has Evolved

**Pre-2.6 (original heuristic killer)**: `badness()` accumulated adjustments for CPU time, wall-clock runtime, nice values, capabilities, and cpuset membership. The result was unpredictable — processes that happened to have been running a long time scored artificially low regardless of memory consumption.

**2.6.36 (oom_adj → oom_score_adj)**: The `oom_adj` interface (range −17 to +15, exposed as `/proc/<pid>/oom_adj`) was deprecated in favour of `oom_score_adj` (range −1000 to +1000). The new interface maps linearly, making values portable and predictable. Backwards compatibility was maintained by mapping old values to new ones.

**3.x — rewritten `oom_badness()`**: David Rientjes rewrote the scoring function to use a pure memory-percentage formula (0–1000). The capability discounts, nice-value penalties, and uptime terms were removed. The goal was a scorer that could be reasoned about: "process A scores 500 because it uses 50% of RAM."

**4.6 — OOM reaper** (Michal Hocko): Introduced `oom_reaper` as a separate kernel thread. This fixed a class of OOM deadlocks where the victim could not exit because it needed memory to run its cleanup code, but no memory could be freed because it wasn't exiting. Merged in v4.6.

**5.4 — `memory.oom_group`** (Roman Gushchin): Allowed operators to designate an entire cgroup as a single kill unit — either all processes in the cgroup survive OOM or all are killed together. This matches the semantics of containerised workloads where a partial kill leaves the application in an inconsistent state.

**5.x onwards — `earlyoom` / `systemd-oomd`**: Not kernel changes, but the kernel's `register_oom_notifier()` and `/proc/pressure/memory` interfaces enabled reliable userspace OOM daemons. These can react to memory pressure before the kernel's last-resort threshold, proactively killing low-priority cgroups, which avoids the thrashing and latency spikes that precede kernel OOM.

## Further Reading

1. [Taming the OOM killer — LWN.net](https://lwn.net/Articles/317814/) — thorough explanation of the original heuristics and the case for replacing them
2. [Another OOM killer rewrite — LWN.net](https://lwn.net/Articles/391222/) — covers the 0–1000 scoring redesign and `oom_score_adj`
3. [Improving the OOM killer — LWN.net](https://lwn.net/Articles/684945/) — OOM reaper design and the deadlock problem it solves
4. [Teaching the OOM killer about control groups — LWN.net](https://lwn.net/Articles/761118/) — cgroup-aware OOM and `memory.oom_group`
5. [mm, oom: introduce oom reaper — LWN.net](https://lwn.net/Articles/666024/) — original reaper patch thread
6. [Chapter 13: Out Of Memory Management — Gorman](https://www.kernel.org/doc/gorman/html/understand/understand016.html) — classic deep-dive into the early OOM implementation
7. [linux-vm-notes: oom.md](https://github.com/ljskernel/linux-vm-notes/blob/master/sections/oom.md) — annotated walkthrough of the modern source code

## LKML Highlights

> No specific LKML message IDs were needed for this note — the LWN articles above directly reference the key patch discussions and review threads for each major evolution.
