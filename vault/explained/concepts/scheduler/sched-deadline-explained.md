---
title: "SCHED_DEADLINE — Explained"
category: explained
original: "[[sched-deadline]]"
subsystem: scheduler
tags: [explained, scheduler, sched-deadline, edf, real-time]
converted: 2026-09-25
---

# Deadline scheduling, explained

> Plain-language companion to [[sched-deadline|the technical note]]. Same facts, fewer identifiers.

## The problem

Traditional real-time scheduling uses fixed priorities: an administrator picks a number, and higher numbers always win. That works, but it's fragile. A real-time task that uses more CPU than expected can starve everything below it, and nothing enforces what it *should* have used. Priorities say "who goes first", not "how much is needed, and by when".

## The idea in one paragraph

Deadline scheduling is a **contract**. A task says: "I need 5 ms of CPU every 20 ms, finished by the 20 ms mark." The kernel's admission desk checks whether it can honour that alongside every contract it has already accepted. If so, the task gets its 5 ms on time, every period. If not, the request is refused and the application must ask for less. There's no priority gaming, just bandwidth declarations with arithmetic behind them.

## Step by step

### Step 1: Declare three numbers
Through a system call (which needs a privilege), a task declares:
- **runtime:** how much CPU it needs per period
- **deadline:** how soon after each period starts the work must be done
- **period:** how often it repeats (the deadline, if left unset)

Runtime divided by period is the task's **utilisation**. Keeping deadline and period separate allows, for example, a 10 ms period with a 5 ms deadline: finish in the first half, common in control systems that need results before the next actuation.

### Step 2: Admission control
Before accepting, the kernel adds up the utilisation of every deadline task on every CPU. If the new one would push the total above 100%, the request fails with "busy". Everything admitted can be met, because the kernel never takes on more than it can deliver.

### Step 3: Spend a budget
This is the key step. Once admitted, the task is policed by the **Constant Bandwidth Server** (CBS). Each period it starts with a budget equal to its runtime, and every timer tick subtracts the time it used. When the budget hits zero, the task is **throttled at once**: taken off the run queue, with a high-resolution timer set for the next period. A task that overruns hurts only itself, never other deadline tasks.

### Step 4: Refill
At the period boundary, the timer fires, refills the budget, sets a new absolute deadline (now plus the relative deadline), and puts the task back in the queue.

### Step 5: Earliest deadline first
Deadline tasks wait in a tree ordered by absolute deadline, and the one whose deadline comes soonest runs. On one CPU, earliest-deadline-first is provably optimal: any task set some other algorithm can schedule, this one can too. With CBS isolating tasks from each other, the approach extends to multiple CPUs within the admission bounds. Because the deadline class sits above the real-time class, any deadline task pre-empts every real-time and normal task, a precedence that admission control justifies.

### Step 6: Reclaim what's unused (optional)
With strict isolation, a task that finishes early can't hand its leftover budget to anyone. **GRUB** (greedy reclamation of unused bandwidth) optionally lets others use that reclaimed time, while still pre-empting them the moment any deadline task needs its promised CPU.

### Step 7: Multiple CPUs
Deadline tasks can migrate between CPUs, with the per-CPU bandwidth accounting moved along so nothing is counted twice. The kernel tracks the earliest deadline on each CPU so it can place tasks where deadlines are least likely to be missed.

## The picture

```text
 contract: runtime 5 ms / period 20 ms  (utilisation 25%)
 admission: sum of all deadline utilisations + 25% ≤ 100%?  no → "busy"

 period:   |0 ─────────────────── 20|20 ─────────────────── 40|
 budget:    5 4 3 2 1 0 ✂ throttled   5 … (refilled by timer)
 queue:    tree by absolute deadline → earliest runs first,
           ahead of every real-time and normal task
```

## Tradeoffs

- **What it gives you:** real guarantees rather than hopeful priorities, isolation between deadline tasks, and refusal up front instead of silent overload.
- **What it costs / requires:** applications must know their needs. Ask too high and admission fails with "busy"; ask too low and deadlines get missed in practice.
- **Where it bites:** strict isolation wastes budget that tasks leave unused, unless GRUB is turned on. Deadlines don't map onto priority numbers, which complicates lock sharing; see [[pi-mutexes-explained|PI mutexes]] for how a lock holder borrows a waiter's deadline.

## How it got here

- **3.14 (2014):** merged with CBS, earliest-deadline-first and admission control (Juri Lelli, Claudio Scordino). Lelli's cover letter argued bandwidth-based scheduling is fundamentally safer than priority-based real-time for production systems.
- **3.14+:** GRUB reclamation, made opt-in within the existing CBS framework after debate over strict isolation versus utilisation.
- **4.x:** better multiprocessor migration and per-CPU earliest-deadline tracking.
- **5.x:** integration with energy-aware scheduling for mixed CPUs.

## Related

- Technical version: [[sched-deadline]]
- [[scheduler-explained|Scheduler]], [[rt-scheduler-explained|Real-time scheduler]], [[scheduler-classes-explained|Scheduling classes]], [[runqueue-explained|Run queue]], [[pi-mutexes-explained|PI mutexes]]
- [[locking-explained|Locking]]
