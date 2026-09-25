---
title: "Scheduler Classes — Explained"
category: explained
original: "[[scheduler-classes]]"
subsystem: scheduler
tags: [explained, scheduler, sched-class, extensibility]
converted: 2026-09-25
---

# Scheduling classes, explained

> Plain-language companion to [[scheduler-classes|the technical note]]. Same facts, fewer identifiers.

## The problem

Linux runs several scheduling policies side by side: proportional fairness for desktop tasks, fixed-priority pre-emption for audio servers, guaranteed bandwidth for real-time control loops. Each needs different data structures and a different rule for picking the next task. Writing all of them as branches inside one scheduler core would make it unmaintainable, and every new policy would mean surgery on that core.

## The idea in one paragraph

Put each policy behind the **same small interface**, like dispatch algorithms plugged into a building's elevator controller. The controller doesn't know whether it's running a FIFO algorithm or a deadline-based one; it calls the same few operations. The policies are stacked in a **fixed order** of importance, and the core always asks the most important one first. Whoever offers a task first wins.

## Step by step

### Step 1: A common set of operations
Each policy, called a **scheduling class**, provides the same set of hooks:
- add a task that has become runnable, or remove one that blocked or left
- pick the best runnable task (or say "none")
- settle accounts for the outgoing task, and set up the incoming one
- react to a timer tick, a priority change, or a task arriving from another class
- refresh runtime accounting (virtual runtime for fair tasks, budget for deadline tasks)

### Step 2: A fixed chain of five
From most to least important:
1. **stop:** CPU hotplug, migration helpers and "stop the machine" work; must pre-empt everything
2. **deadline:** tasks with declared runtime and deadline contracts
3. **real-time:** FIFO and round-robin tasks
4. **fair:** normal, batch and idle-priority tasks, the vast majority of processes
5. **idle:** each CPU's idle task, always runnable and never chosen over anything else

### Step 3: Ask each in turn
After locking the run queue and updating its clock, the scheduler walks the chain from the top, asking each class for a task. The first to return one wins; lower classes only get a turn when everything above has nothing to run.

### Step 4: Position replaces special cases
This is the key step. The stop class must be able to pre-empt even a priority-99 real-time task during CPU migration. Instead of a "is this the stop task?" check in the core, it's put first in the chain; its position *is* the special case. The same holds for every class: precedence comes from order alone.

### Step 5: The fast path
Nearly all tasks are usually fair-scheduled. So if every runnable task on the CPU belongs to the fair class, the scheduler skips the walk and asks the fair class directly, recovering most of the overhead of going through the interface.

### Step 6: Switching class
Each task records which class manages it. When a task changes policy, the kernel removes it through the old class, points it at the new one, and adds it through the new class, which can then set up its own state.

## The picture

```text
 schedule():   ask ──▶ stop ──▶ deadline ──▶ real-time ──▶ fair ──▶ idle
                        │ none     │ none        │ none       │ task B ✓
                                                               ▼
                                                            run B
 fast path: all runnable tasks are fair?  ──────────────────▶ ask fair directly

 3.14: deadline slotted in above real-time with zero changes to the core
 6.6:  fair class's insides replaced by EEVDF with the interface unchanged
```

## Tradeoffs

- **What it gives you:** policies isolated from each other and from the core; a new policy is added by implementing the interface, as deadline scheduling proved.
- **What it costs / requires:** calling through an interface stops the compiler from inlining each policy's code the way a hard-coded if-else chain could. The fair-class shortcut is the main concession to performance.
- **Where it bites:** the chain is deliberately fixed rather than dynamically registered, because ordering classes at runtime would bring back the complexity the static chain avoids. So new variants that don't need a slot between existing classes are added as policies *inside* the fair class instead.

## How it got here

- **2.6.23 (2007):** classes arrived with CFS. Ingo Molnár's cover letter presented the abstraction as what would let deadline scheduling be added later without touching the core. Four classes at launch: stop, real-time, fair, idle.
- **3.14 (2014):** deadline scheduling (Juri Lelli's series) slotted in between stop and real-time with no changes to the core scheduling function, as promised.
- **4.x:** a hook for set-up after the next task has been chosen.
- **6.6 (2023):** the fair class's internals were replaced by EEVDF with the interface untouched, showing the isolation working.

## Related

- Technical version: [[scheduler-classes]]
- [[scheduler-explained|Scheduler]], [[runqueue-explained|Run queue]], [[cfs-eevdf-explained|CFS/EEVDF]], [[rt-scheduler-explained|Real-time scheduler]], [[sched-deadline-explained|SCHED_DEADLINE]], [[context-switch-explained|Context switch]]
- [[interrupt-handling-explained|Interrupt handling]], [[locking-explained|Locking]]
