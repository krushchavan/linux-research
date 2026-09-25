---
title: "Context Switch — Explained"
category: explained
original: "[[context-switch]]"
subsystem: scheduler
tags: [explained, scheduler, context-switch, tlb, preemption]
converted: 2026-09-25
---

# The context switch, explained

> Plain-language companion to [[context-switch|the technical note]]. Same facts, fewer identifiers.

## The problem

One CPU gives the impression of running many tasks at once by rapidly handing control from one to another. Each hand-off must save the outgoing task's registers, switch to the incoming task's address space, and restore its registers, and it has to be correct under every condition: interrupts, NMIs, kernel threads, virtualisation. Every cycle spent here is overhead that does no useful work, so it also has to be fast.

## The idea in one paragraph

A context switch is like **putting one phone call on hold to take another**. You remember where you were in the conversation, switch callers, and later pick up exactly where you left off. The CPU saves one task's registers onto that task's **own kernel stack**, switches page tables, then restores the next task's registers from *its* stack. Because each task's saved state lives on its own stack, a task resumes exactly where it stopped when the CPU returns to it.

## Step by step

### Step 1: Ask for a switch
Switches don't happen at arbitrary moments. When the scheduler wants the current task off the CPU (a higher-priority task woke, the slice ran out, or the task blocked), it sets a **"needs rescheduling" flag** on it. The flag is checked at safe points:
- returning from an interrupt, exception or system call (always)
- when pre-emption is re-enabled in kernel code (in the fully pre-emptible kernel)
- at explicit "good place to reschedule" markers in long kernel loops (in the voluntary model)

Which of these apply depends on the kernel's [[preemption-model|pre-emption model]]. In the non-pre-emptible model, only explicit calls and returns to user space count.

### Step 2: Lock and stamp the time
The central scheduling function disables local interrupts, so nothing can change the run queue mid-switch, and takes the run queue's lock. It refreshes the queue's clock once, so all accounting during the switch uses the same timestamp.

### Step 3: Deal with the outgoing task
If the old task is going to sleep voluntarily, it's removed from the run queue. One exception: if it's in an interruptible sleep and a signal is pending, it's set back to runnable first, since the signal takes priority even though what it was waiting for hasn't arrived. If it's being pre-empted instead, it stays queued and its accounting is updated.

### Step 4: Pick the next task
The scheduling classes are asked in priority order. If the winner is the same task, nothing more happens.

### Step 5: Switch the address space
For a user task, the CPU is given the new task's top-level page table, which flushes the TLB unless the hardware can tag TLB entries by process (PCID on x86, used since about 4.14). **Kernel threads** have no user address space of their own, so they **borrow** the previous task's, skipping the page table switch and flush entirely. This is called lazy TLB.

### Step 6: Swap registers and stacks
A small piece of architecture-specific assembly:
1. pushes the old task's callee-saved registers onto its kernel stack
2. switches the stack pointer to the new task's kernel stack
3. pops the new task's saved registers
4. "returns", but into wherever the new task was when it last switched out

It's written as a macro rather than a normal function because it returns on a different stack from the one it was called on.

### Step 7: Clean up as the new task
This is the key step. Back in the new task, a clean-up routine marks the old task as **no longer on a CPU**, using a store with release ordering. Another CPU that wants to wake and migrate the old task waits for that mark with a matching acquire. Without the pairing, it could see "off the CPU" before the old task's registers were fully saved, and start running a task that's still half on the old CPU. Then the run queue lock is released, borrowed-address-space bookkeeping is settled, and if the old task had exited, it's freed here.

## The picture

```text
 CPU running A            "needs rescheduling" set on A
      │ safe point (e.g. interrupt return)
      ▼
 lock run queue → dequeue A if sleeping → pick B
      │
      ├─ address space: load B's page tables (kernel thread? borrow A's, no flush)
      ├─ registers: save A's onto A's stack │ stack pointer → B's stack │ restore B's
      ▼
 now running as B: mark A "off CPU" (release) → unlock run queue
                   ▲
       another CPU waking A waits for this (acquire)
```

## Tradeoffs

- **What it gives you:** tasks resume exactly where they stopped; kernel threads avoid TLB flushes; the kernel counts voluntary switches (the task blocked) and involuntary ones (it was pre-empted) for each process. Many involuntary switches mean the task is fighting for CPU.
- **What it costs / requires:** strict stack discipline and careful memory ordering around the "on a CPU" mark.
- **Where it bites:** lazy TLB keeps the previous user task's page tables in use while a kernel thread runs. That's a clear win for short kernel threads, but a long-running one on a NUMA machine may keep remote page tables resident for no reason.

## How it got here

- **2.6.0 (SMP):** the post-switch clean-up was split out, because code after the stack swap runs as the new task and has to be written with that in mind.
- **Lazy TLB:** added early for kernel threads; PCID (Joerg Roedel's series, ~4.14) later cut flush costs for user-task switches too.
- **Real-time kernel (~5.15):** the register swap itself was unchanged, but the paths leading to it changed fundamentally now that spinlocks can sleep.
- **Lazy FPU saving:** floating-point state is saved and restored only when the new task actually uses the FPU, triggered by a fault.

## Related

- Technical version: [[context-switch]]
- [[scheduler-explained|Scheduler]], [[runqueue|Run queue]], [[cfs-eevdf-explained|CFS/EEVDF]], [[preemption-model|Preemption model]], [[scheduler-classes|Scheduling classes]]
- [[interrupt-handling-explained|Interrupt handling]], [[locking-explained|Locking]]
