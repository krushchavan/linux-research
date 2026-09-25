---
title: "io_uring Task Work and Completion Batching — Explained"
category: explained
original: "[[io-uring-task-work]]"
subsystem: io_uring
tags: [explained, io_uring, task-work, completion]
converted: 2026-09-25
---

# io_uring task work and completion batching, explained

> Plain-language companion to [[io-uring-task-work|the technical note]]. Same facts, fewer identifiers.

## The problem

Most io_uring completions are *noticed* in an awkward place: a disk interrupt handler, the network stack's softirq processing, or a wait-queue callback running on some other CPU.

Finishing the request right there would be a bad idea. It would mean touching the submitting process's memory from a context that isn't that process, taking the completion ring's lock from interrupt context, and bouncing the ring's cache lines between CPUs.

So io_uring pushes the rest of the work back to the thread that submitted the request, where it can be done cheaply and in batches. *How* and *when* that work runs turns out to be one of the biggest performance levers io_uring has.

## The idea in one paragraph

Task work is **a note left on the thread's desk**. Whoever discovers a completion leaves a note ("finish request X") instead of doing the job. The only question is how loudly to announce it: tap the thread on the shoulder right now, wait until it next walks past its desk, or leave the pile alone until it sits down to go through its mail. Quieter announcements disturb the thread less and let it process a bigger pile at once.

## Step by step

### Step 1: Leave the note
Whatever path needs the submitting thread's context (a finished read, a socket that became ready, a retry) attaches a "what to do next" function to the request and adds it to a lock-free list. Adding from interrupt context is a single atomic operation.

### Step 2 (default mode): Tap on the shoulder
The request goes onto a per-thread list. If the list was empty, the thread is flagged, and if it is currently running user code on another CPU, it gets a cross-CPU interrupt so the work runs as soon as it next leaves the kernel. That is prompt, which helps latency. But a thread busy computing gets interrupted for every burst of completions, and each such interrupt costs microseconds.

### Step 3: Running the notes
When the thread returns to user space, or enters io_uring, it drains the list. The list comes out newest-first, so it is reversed back into order. Items for the same ring are handled with that ring's lock taken once, and their completions are collected rather than posted one by one (see step 7).

### Step 4 (cooperative mode, 5.19): Wait until it walks past
Many applications enter the kernel frequently anyway. Cooperative mode sets the flag but sends no interrupt, so the work runs at the next natural kernel entry. An optional companion flag in shared memory tells an application loop that only peeks at the completion ring: "there is pending work, call into the kernel to get it flushed."

### Step 5 (deferred mode, 6.1): Leave the pile until asked
The strongest option, introduced by Dylan Yudaken. The note goes on the *ring's own* list and the thread is not notified at all. Nothing runs until the thread asks for completions. Then the whole list is processed at once.

If the thread is already asleep waiting for, say, 16 completions, the kernel wakes it only once enough work has piled up to satisfy that, not once per completion.

The motivating example from the patch: a large receive copy landing in the middle of latency-critical send processing. The cost is that the application has to actually call in to make progress. A ring nobody waits on sees no completions.

### Step 6: Why deferred mode needs a single submitter
Deferred work must run in the thread that owns the ring's resources, and only that thread drains the ring's list. A "single issuer" promise (6.0) tells the kernel exactly one thread will ever submit; any other thread trying gets an error. That makes the owner well defined.

The same promise later enabled skipping the ring's main lock on the submit and task-work paths entirely (late 2025). Before that, the single-issuer flag on its own had given no speedup.

### Step 7: Post completions in batches
This is the key step for throughput. Instead of taking the completion lock for each result, finished requests are collected on a list and then posted together:
1. take the completion-ring lock once (for single-issuer rings, where only the owner writes the ring, this is a no-op)
2. write every result entry
3. publish the new tail once
4. wake any waiters once
5. free all the request objects in bulk

Multishot requests batch their extra completions the same way.

### Step 8: When things go wrong
If the completion ring is full at flush time, the extra results go on an overflow list and a flag tells the application. The next time it asks for completions, they are delivered in order. If the thread is exiting when its task work runs, the notes are handled in a fallback mode that cancels the requests rather than issuing them, so nothing is lost.

## The picture

```text
 interrupt / softirq / wait-queue callback
          │ "request X is done"
          ▼
   add note to lock-free list ────────────────────────────────┐
          │                                                   │
   ┌──────┼──────────────────────┬────────────────────────┐   │
 default                 cooperative                deferred  │
 flag + cross-CPU        flag only, no              ring's own list,
 interrupt now           interrupt                  no notification
   │                         │                          │
 runs on next           runs on next natural       runs only when the app
 kernel exit            kernel entry               asks for completions
   └──────────────┬──────────┴──────────────────────────┘
                  ▼
      batch: lock once → write all results → publish tail once
             → wake once → free requests in bulk
```

## Tradeoffs

- **What it gives you:** completion-ring updates that are effectively single-writer and cache-hot, continuations that can touch user memory, and posting costs spread across many completions.
- **What it costs / requires:** dependence on the owning thread getting to run. A thread stuck in a long computation delays its own completions. Three modes make the API more complex, but no single policy suits both latency-sensitive and throughput-oriented applications.
- **Where it bites:** deferred mode breaks the "fire and forget" illusion: results only show up when you ask. Batching can add microseconds to individual completions. "Minimum wait" timeouts (6.12) let applications bound that. Waiting also used to count as I/O wait, which misled CPU-frequency governors and monitoring; that became optional in 6.15.

## How it got here

- **5.7:** io_uring adopts task work for poll-driven retries and completions.
- **5.11–5.13:** a dedicated notification flag so io_uring's task work no longer masquerades as a signal; batching by ring.
- **5.19–6.1:** cooperative mode and the "task work pending" flag, then single issuer (6.0) and deferred mode (6.1).
- **6.12–6.15:** minimum-wait and absolute timeouts, clock selection, and optional I/O-wait accounting.
- **2025–2026:** skipping the ring lock for single-issuer rings.

## Related

- Technical version: [[io-uring-task-work]]
- [[io_uring-explained|io_uring]]: the subsystem overview
- [[io-uring-internals-explained|io_uring internals]]: where completions are posted
- [[io-uring-async-poll-and-multishot-explained|Async poll and multishot]]: poll wake-ups queue task work
- [[io-wq]]: helper-thread creation is itself scheduled with task work
- [[uring-cmd-passthrough]]: drivers finish commands in task context
- [[block-explained|Block layer]]: disk completions that start the chain
