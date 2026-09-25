---
title: "SQPOLL (Submission Queue Polling) — Explained"
category: explained
original: "[[sqpoll]]"
subsystem: io_uring
tags: [explained, io_uring, polling, performance]
converted: 2026-09-25
---

# SQPOLL (submission queue polling), explained

> Plain-language companion to [[sqpoll|the technical note]]. Same facts, fewer identifiers.

## The problem

io_uring's shared rings remove the system call per operation, but something still has to *notice* that new requests are waiting. Normally that is one system call per batch.

For most programs that is cheap enough. But at very high, sustained request rates, even one system call per batch, plus the extra entry costs added by Spectre and Meltdown mitigations, becomes a measurable share of the CPU spent per I/O.

## The idea in one paragraph

Dedicate a kernel thread to watching the submission ring, so that in steady state submitting costs only a memory write. SQPOLL is **a courier waiting outside your door**. Instead of phoning the post office for every batch of letters, you drop them in the outbox and the courier grabs them. If you stop sending for a while, the courier goes home and leaves a note on the door ("ring me when you need me"), and your next send has to include one phone call to bring them back.

## Step by step

### Step 1: Create the thread
When a ring is set up with polling enabled, the kernel starts a polling thread, or attaches this ring to an existing polling thread if asked to share. The thread is a real thread of the creating process (since 5.12), so it runs with that process's memory, files and credentials. It can do only what the creator could have done, which is why it stopped needing admin privileges in 5.11. A security-module hook still lets policies forbid it. Optionally, the thread is pinned to one CPU.

### Step 2: Poll the rings
The thread loops over every ring attached to it. For each, it checks how many new requests are waiting and submits them through exactly the same code a system call would use. Each ring gets a capped amount per round, so one busy ring can't starve the others sharing the thread.

If the ring also uses completion polling for fast storage, the thread reaps those completions too. That combination (submission polling plus completion polling) is the fully interrupt-free, system-call-free setup used for top-end NVMe benchmarks.

Between rings the thread runs its own pending task work and yields the CPU when the scheduler wants it back, rather than monopolising it.

### Step 3: Go idle, carefully
Every round with useful work resets an idle timer. When a configured idle time (1 second by default) passes with nothing to do, the thread prepares to sleep:
1. set a **"needs wakeup"** flag in each ring's shared memory
2. issue a full memory barrier
3. check the ring *once more*
4. only then sleep

This is the key step. Without the re-check, the application could add a request right between the thread's last look and it setting the flag, and that request would sit there with nobody coming for it.

### Step 4: Wake it when needed
After moving the submission tail forward, the application reads the shared flags (liburing does this for you). If "needs wakeup" is set, it makes one system call to wake the thread. There is also a call that waits until the thread has consumed entries, for when the submission ring is full.

### Step 5: Signal through flags
Under SQPOLL the application may never enter the kernel, so the thread talks through flags in shared memory. One says results are waiting in the kernel's overflow list and a call is needed to flush them. Another says task work is pending.

### Step 6: Park the thread for changes
Some changes must not race with submission: registering files or buffers, resizing rings, adding or removing a ring from a shared thread. For those the kernel "parks" the thread at a safe point and releases it afterwards. That is why registration calls are comparatively expensive on SQPOLL rings.

### Step 7: Teardown and a common mistake
When the last ring detaches, the thread stops. If the process exits, the thread exits with it and any unsubmitted requests are discarded.

A subtle failure mode: with SQPOLL, requests are consumed *concurrently*, not by the time a system call returns. The application must not reuse a submission slot until the kernel's head has moved past it. liburing handles that; hand-rolled ring code often doesn't. Submission errors also arrive as completions rather than as return values.

## The picture

```text
 application                          polling thread (one CPU, maybe pinned)
 ───────────                          ─────────────────────────────────────
 write request, move tail ──────────▶ loop over attached rings:
 (no system call)                        submit new requests (capped per ring)
                                         reap polled completions (fast NVMe)
                                         run own task work, yield if asked
                                                │ idle for N ms?
                                                ▼
                                      set "needs wakeup" → barrier →
                                      re-check ring → sleep
 see "needs wakeup"?  ──one call──▶   wake up, carry on
```

## Tradeoffs

- **What it gives you:** submission with no system calls at all in steady state; with completion polling, no interrupts either.
- **What it costs / requires:** a CPU that busy-polls while active (visible in `top`). On machines where cores are scarce, or at low request rates, the idle and wake-up dance can cost more than it saves. Benchmarks consistently show SQPOLL helping only at high, sustained rates.
- **Where it bites:** pinning the thread to an isolated core avoids competing with the application, but pinning it to a busy core can cause missed wake-ups and latency spikes. Sharing one thread across many rings saves CPUs but raises fairness issues, and every registration change must park it for all of them. Its cross-thread nature also rules it out of some optimisations elsewhere, such as skipping the ring lock for single-issuer rings.

## How it got here

- **5.1:** present from the start, as a kernel thread requiring admin privileges (a borrowed-identity kernel thread that can burn CPU was considered risky).
- **5.9–5.10:** sharing one polling thread among rings, and waiting for submission space.
- **5.11:** unprivileged SQPOLL, once the thread was guaranteed to run with the creator's own credentials.
- **5.12:** converted to a real thread of the process, making that guarantee structural; it is now accounted to the user like any other thread.
- **5.19 and later:** a "task work pending" flag, and busy/idle time reporting so you can measure whether the dedicated thread is paying for itself.

## Related

- Technical version: [[sqpoll]]
- [[io_uring-explained|io_uring]]: the subsystem overview
- [[io-uring-internals-explained|io_uring internals]]: the normal submission path SQPOLL replaces
- [[io-uring-task-work-explained|Task work]]
- [[io-wq-explained|io-wq]]: the other io_uring thread type, which also became a real thread in 5.12
- [[block-explained|Block layer]]: polled completions for fast storage
- [[security|Security]]
