---
title: "OOM Killer — Explained"
category: explained
original: "[[oom-killer]]"
subsystem: mm
tags: [explained, mm, oom, reclaim, cgroups]
converted: 2026-09-25
---

# The OOM killer, explained

> Plain-language companion to [[oom-killer|the technical note]]. Same facts, fewer identifiers.

## The problem

Sometimes memory really runs out. RAM and swap are full, and reclaim can't free anything: nothing left to drop, write back, swap or compact. An allocation is still waiting.

The kernel then has three options: wait forever (the machine hangs), panic (the machine reboots), or **sacrifice one process** so its memory can be reused. The out-of-memory (OOM) killer takes the third option. The hard parts are choosing the victim fairly, and making sure its memory is actually freed, even if the victim is stuck and can't run to exit.

## The idea in one paragraph

Think of a **triage surgeon** in a disaster: supplies are gone and the only way to save the ward is to give one bed to someone else. The kernel scores every process by roughly what share of memory it holds, adjusted by a per-process knob operators can set, and kills the highest scorer. Then a separate helper, the **OOM reaper**, doesn't wait for the victim to leave politely: it strips the victim's memory immediately so others can use it.

## Step by step

### Step 1: Reached only as a last resort
The allocator's slow path first wakes background reclaim, tries direct reclaim harder and harder, and tries compaction. Only when all of that fails repeatedly does it call the OOM killer. A page fault that can't be satisfied can also end up here, and memory cgroups have their own path for OOM within a container.

### Step 2: Sanity checks before killing
A global lock ensures only one OOM decision happens at a time. Then:
1. If the system is set to **panic on OOM**, it panics.
2. Registered notifiers get a chance to free memory themselves; if one succeeds, the killer backs off.
3. If a previously chosen victim is **still dying**, wait instead of killing again: memory is already on its way.
4. If the allocating task is itself already being killed, let its exit free memory.

If an option says "kill whoever triggered this", that task is chosen directly. Otherwise, scoring begins.

### Step 3: Score every process
The kernel walks every process. Some are skipped outright: PID 1, kernel threads, processes mid-`vfork`. A task already dying stops the scan. The task that triggered the OOM may be picked immediately.

For the rest, the **badness score** is essentially: how much memory does this process hold?
- pages in RAM (anonymous and file-backed)
- plus pages it has in swap
- plus the memory its page tables use

That's turned into a score from 0 to 1000, meaning roughly "per mille of available memory". Then:
- privileged (admin) processes get a 3% discount
- a per-process adjustment from **−1000 to +1000** is added, scaled so +1000 counts as a whole extra RAM's worth. **−1000 makes a process immune**: its score becomes zero and it can never be chosen.

Everyone else scores at least 1, to avoid ties at zero. Threads of one process are judged together.

### Step 4: Choose, and maybe pick a child instead
The highest scorer is the candidate. Before killing it, the kernel checks its children that have their own memory: if one of them scores higher, the child is killed instead, since that frees about as much and the parent may be more valuable.

### Step 5: Kill
The kernel logs an OOM report (memory state, the victim, a per-process summary), sends **SIGKILL**, marks every thread sharing the victim's memory as an OOM victim (which also lets them allocate a little so they can finish exiting), and wakes the reaper.

### Step 6: The OOM reaper frees memory without waiting
This is the key step. A killed process might never actually run: it could be blocked on a lock held by another process that is itself stuck waiting for memory. Then nothing is freed and the system deadlocks.

The reaper is a dedicated kernel thread. For each victim it:
1. checks whether the process already exited
2. tries to take the victim's memory lock *without blocking*, retrying up to 10 times about 10 ms apart. Blocking here could deadlock too.
3. unmaps the victim's memory regions, **except** huge-page regions, memory locked in RAM by the user, and shared file mappings (tearing those down could affect other processes)
4. hands the freed pages straight back to the allocator
5. marks the victim so it can't be chosen again, and clears its victim status

Memory is freed whether or not the victim ever runs. The reaper (Michal Hocko, 4.6) turned the OOM killer from an occasional deadlock source into a reliable recovery mechanism.

### Step 7: OOM inside a container
With memory cgroups, hitting a group's limit triggers OOM **within that group**, choosing only among its processes. A group option (5.4, Roman Gushchin) kills the whole group together, so a containerised application isn't left half-dead. His work also made selection two-level: first pick the biggest group, then the worst process inside it.

## The picture

```text
 allocation fails ── reclaim, compaction fail repeatedly ──▶ OOM killer (one at a time)
        │ panic mode? notifier freed memory? victim already dying? → stop
        ▼
 score each process:  RAM + swap + page tables  → 0..1000
                      admin: −3%     adjustment: −1000 (immune) .. +1000
        ▼
 highest scorer (or a heavier child) ──▶ SIGKILL, mark victim
        ▼
 OOM reaper: try-lock victim memory → unmap anonymous/private regions
             (skip huge pages, locked pages, shared file mappings)
             → pages back to the allocator, even if the victim is stuck
```

## Tradeoffs

- **What it gives you:** a machine that recovers from memory exhaustion instead of hanging or rebooting, with a predictable, auditable choice of victim.
- **What it costs / requires:** operators must manage priorities with the adjustment knob; systemd, for example, makes critical services immune with −1000. The kernel doesn't try to guess importance.
- **Where it bites:** a long-running, important daemon that happens to use lots of memory looks exactly like a runaway leak. The killer kills one process, then waits to see whether that was enough, which can be slow if the victim's exit path itself needs memory. That's why user-space daemons (earlyoom, systemd-oomd) watch memory pressure and kill whole groups early, trading collateral damage for faster recovery. On 32-bit systems, exhausting only the low-memory zone fails the allocation rather than killing, since killing wouldn't help.

## How it got here

- **Early kernels:** a heuristic mix of CPU time, uptime, nice value, capabilities and cpuset membership, which gave unpredictable results.
- **2.6.36:** the adjustment knob changed from a −17..+15 scale to the linear −1000..+1000 scale, with old values mapped over.
- **3.x:** David Rientjes rewrote scoring as a pure share-of-memory figure: "process A scores 500 because it uses 50% of RAM".
- **4.6:** the OOM reaper.
- **5.4:** killing whole cgroups together.
- **5.x onward:** notifiers and memory-pressure information enable user-space OOM daemons that act before the kernel's last resort.

## Related

- Technical version: [[oom-killer]]
- [[mm-explained|Memory management]]: the subsystem overview
- [[page-reclaim]]: what must fail first
- [[memory-cgroup-explained|Memory cgroups]]: OOM scoped to a container
- [[buddy-allocator-explained|Buddy allocator]]: where reaped pages go
- [[virtual-memory-areas]], [[page-fault-handler]], [[psi-pressure-stall-information]]
