---
title: "io_uring task_work and Completion Batching"
category: concept
tags: [io_uring, task-work, defer-taskrun, completion, single-issuer]
subsystem: io_uring
kernel_version: "5.7"
researched: 2026-09-24
status: complete
explained: "[[io-uring-task-work-explained]]"
sources:
  - https://lwn.net/Articles/906470/
  - https://lwn.net/Articles/910608/
  - https://lwn.net/Articles/909485/
  - https://lwn.net/Articles/915635/
  - https://lwn.net/Articles/1050662/
  - https://kernel-internals.org/io-uring/life-of-request/
  - https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html
---

# io_uring task_work and Completion Batching

> 📘 Plain-language version: [[io-uring-task-work-explained]]

## Purpose

Most io_uring completions are *detected* somewhere inconvenient: in a block-layer IRQ handler, in network softirq, or in a wait-queue callback running on another CPU. Finishing the request there would mean touching the submitter's user memory from the wrong `mm`, taking the CQ lock from interrupt context, and bouncing ring cache lines between CPUs. io_uring instead uses the kernel's `task_work` mechanism to push the rest of the work back to the submitting task, where it can be done cheaply and in batches. How and *when* that task_work runs is one of the biggest performance levers io_uring offers.

## Mental Model

task_work is a **note left on the task's desk**. Whoever discovers a completion leaves a note ("finish request X") instead of doing the job themselves. The question is how loudly they announce it: tap the task on the shoulder right now (`TWA_SIGNAL`, possibly an IPI), wait until the task next walks past its desk (`COOP_TASKRUN`), or leave the pile untouched until the task explicitly sits down to process mail (`DEFER_TASKRUN`). Quieter announcements disturb the task less and let it process a larger pile at once.

## How It Works

**Queueing.** Any path that needs task context calls `io_req_task_work_add(req)` after setting `req->io_task_work.func` to the continuation—`io_req_task_complete` for a finished request, `io_poll_task_func` for a poll wakeup, `io_req_task_submit` to retry an issue, `io_req_rw_complete` for a finished read/write. The list is a lock-free `llist`, so adding from IRQ context is a single cmpxchg.

**Normal mode.** The request is added to the per-task `struct io_uring_task`'s `task_list`, and if the list was previously empty, the task is notified via `task_work_add(..., TWA_SIGNAL)` with the callback `tctx_task_work()`. `TWA_SIGNAL` sets `TIF_NOTIFY_SIGNAL` and, if the task is running in userspace on another CPU, kicks it with an IPI so the work runs promptly on its next kernel exit. That promptness is good for latency but bad for throughput: an application busy computing gets interrupted for every burst of completions, and each IPI costs microseconds.

**Running normal task_work.** On return to userspace (or in `io_uring_enter()`), `tctx_task_work()` reverses the llist (it's LIFO), and runs each item's `func`. Items belonging to the same ring are processed with that ring's `uring_lock` taken once, and completions are collected rather than posted one by one—see batching below.

**COOP_TASKRUN (5.19).** Many applications enter the kernel frequently anyway. `IORING_SETUP_COOP_TASKRUN` changes notification to `TWA_SIGNAL_NO_IPI`: the flag is set but no IPI is sent, so work runs at the next natural transition. Paired with `IORING_SETUP_TASKRUN_FLAG`, the kernel sets `IORING_SQ_TASKRUN` in the shared SQ flags so a userspace loop that only peeks the CQ knows it must call `io_uring_enter()` to get completions flushed.

**DEFER_TASKRUN (6.1).** The strongest form, introduced by Dylan Yudaken. With `IORING_SETUP_DEFER_TASKRUN` (which requires `IORING_SETUP_SINGLE_ISSUER`), `io_req_task_work_add()` routes to `io_req_local_work_add()`, which appends to the *ring's* `ctx->work_llist` and does **not** call `task_work_add()` at all. Nothing runs until the submitting task calls `io_uring_enter()` with `IORING_ENTER_GETEVENTS` (or otherwise waits on the ring); then `__io_run_local_work()` processes the whole list. If the task is sleeping in the wait, the adder wakes it only once enough items have accumulated to satisfy `min_complete`—the `nr_wait` accounting in `io_req_local_work_add()` avoids waking a waiter for each individual completion. The motivating example from the patch: a large async `recv` memcpy landing in the middle of latency-critical `send` processing. The cost is that the application must actually enter the kernel to make progress; a ring that nobody waits on sees no completions.

**Why SINGLE_ISSUER?** Deferred work must run in the context of the task that owns the ring's resources, and the ring's local work list is only drained by that task. `IORING_SETUP_SINGLE_ISSUER` (6.0) promises the kernel that exactly one task submits (enforced: other tasks get `-EEXIST`), which makes that well defined. It also enables lock elision: patches from Caleb Sander Mateos (late 2025) skip `uring_lock` on the issue and task_work paths entirely when the single-issuer guarantee holds.

**Completion batching.** Whether it runs inline at submit time or in task_work, completion usually doesn't call `io_req_complete_post()` (which takes `completion_lock` per CQE). Instead requests are appended to `ctx->submit_state.compl_reqs`, and `io_submit_flush_completions()` posts them all at once: it takes the CQ lock once (`__io_cq_lock()`, which is a no-op for single-issuer/DEFER rings where only the owner writes the CQ), fills every CQE with `io_fill_cqe_req()`, commits the tail once with a release store, wakes waiters once (`io_cqring_ev_posted()`), and frees the requests in bulk to the per-ring request cache. Multishot requests similarly batch their auxiliary CQEs.

**Failure paths.** If the CQ ring is full when CQEs are flushed, they go to `ctx->cq_overflow_list` as `struct io_overflow_cqe` and `IORING_SQ_CQ_OVERFLOW` is set; the next `io_uring_enter(GETEVENTS)` flushes them in order. If the task is exiting when task_work runs (`PF_EXITING`), continuations are run in a "fallback" mode (`io_fallback_req_func` via a workqueue) that cancels rather than issues, so requests are never lost.

## Key Data Structures

**`struct io_uring_task`** (`include/linux/io_uring_types.h`) — per-task io_uring context.
- `task_list` — llist of pending task_work (normal mode)
- `task_work` — the `callback_head` registered with `task_work_add()`
- `io_wq` — the task's [[io-wq]] pool
- `registered_rings[]` — ring fds registered with `IORING_REGISTER_RING_FDS`
- `inflight` — outstanding request count, used during cancellation

**`struct io_ring_ctx` (task_work-related fields)**
- `work_llist` — DEFER_TASKRUN local work
- `cq_wait_nr` — how many completions the current waiter needs before waking
- `submit_state.compl_reqs` — batch of requests awaiting CQE posting
- `cq_overflow_list` — overflowed CQEs

**`struct io_task_work`** (in `io_kiocb`) — `node` (llist entry) and `func` (continuation).

## Key Functions / Entry Points

**`io_req_task_work_add()`** (`io_uring/io_uring.c`) — queue a request continuation; dispatches to local or normal mode.

**`io_req_local_work_add()`** — DEFER_TASKRUN path; append to `ctx->work_llist`, maybe wake waiter.

**`tctx_task_work()`** — normal task_work callback; runs the task's list.

**`__io_run_local_work()`** — drain DEFER_TASKRUN work from `io_uring_enter()` / wait.

**`io_submit_flush_completions()`** — batch-post CQEs and free requests.

**`io_cqring_wait()`** — the wait loop in `io_uring_enter(GETEVENTS)`; runs local work and sleeps until `min_complete` CQEs are available or a timeout expires.

## Important Flags & Config Options

- **`IORING_SETUP_COOP_TASKRUN`** (5.19) — no IPI for task_work; good default for event-loop applications.
- **`IORING_SETUP_TASKRUN_FLAG`** (5.19) — expose pending task_work as `IORING_SQ_TASKRUN`.
- **`IORING_SETUP_SINGLE_ISSUER`** (6.0) — one submitting task; enables lock elision and is required for DEFER.
- **`IORING_SETUP_DEFER_TASKRUN`** (6.1) — run completions only when the task waits for them. Recommended for single-threaded servers; required by zero-copy receive.
- **`IORING_ENTER_GETEVENTS`** + `min_complete` — the call that drives DEFER_TASKRUN work.
- **Min-wait timeouts (6.12)** — `io_uring_enter` can wait with both a short "min wait" and an overall timeout, letting apps trade latency for batching explicitly.
- **iowait toggle (6.15)** — `IORING_ENTER_NO_IOWAIT` stops waits from counting as iowait, which had misled CPU-frequency governors and monitoring.

## Interactions with Other Subsystems

- **↑ Userspace**: behaviour is chosen at setup time; userspace chooses when to call `io_uring_enter(GETEVENTS)`.
- **→ Core kernel task_work**: normal mode relies on `task_work_add()` / `TIF_NOTIFY_SIGNAL` in `kernel/task_work.c` and the exit-to-user path.
- **→ Scheduler**: IPIs from `TWA_SIGNAL` and wakeups from waits; iowait accounting affects cpufreq/cpuidle decisions.
- **← [[block]]**: bio completion in IRQ context queues task_work for read/write requests.
- **← [[io-uring-async-poll-and-multishot]]**: poll wakeups queue task_work to retry the operation.
- **← [[uring-cmd-passthrough]]**: drivers call `io_uring_cmd_complete_in_task()` to finish commands in task context.
- **← [[io-wq]]**: worker creation is itself scheduled with task_work in the owner.

## Design Decisions & Tradeoffs

**Complete in the owner's context.** Doing completions in the submitter keeps CQ updates effectively single-writer and cache-hot, and lets continuations touch user memory. The price is dependency on the task getting scheduled: a task stuck in a long userspace computation delays its own completions.

**Three notification modes rather than one.** No single policy is right for both latency-sensitive and throughput-oriented applications. io_uring exposes the tradeoff as setup flags, adding complexity to the API but avoiding a global compromise.

**DEFER_TASKRUN shifts responsibility to userspace.** It gives the best throughput and the fewest surprises (no work runs behind the application's back) but breaks the "fire and forget" illusion: completions only materialise when you ask. It also closed a practical gap for sandboxes, because deferred completions don't spawn io-wq workers for the completion side.

**Batching over latency.** Posting CQEs in bulk dramatically cuts lock and cache traffic but can add microseconds to individual completions; min-wait timeouts let applications bound that.

## How It Has Evolved

- **5.7** — io_uring adopts task_work for poll-driven retries and completions.
- **5.11–5.13** — `TIF_NOTIFY_SIGNAL` introduced so io_uring task_work doesn't masquerade as a signal; task_work batching by ring.
- **5.19** — `COOP_TASKRUN`, `TASKRUN_FLAG`.
- **6.0** — `SINGLE_ISSUER`.
- **6.1** — `DEFER_TASKRUN` (Dylan Yudaken).
- **Later 6.x** — local-work wake accounting reworked so that a waiter is woken only once enough work is queued.
- **6.12–6.15** — min-wait timeouts, absolute timeouts and clock selection, optional iowait.
- **2025–2026** — `uring_lock` elision for SINGLE_ISSUER rings.

## Further Reading

1. [io_uring: defer task work to when it is needed — patch posting (2022)](https://lwn.net/Articles/906470/)
2. [The rest of the 6.1 merge window — LWN](https://lwn.net/Articles/910608/)
3. [io_uring: register single issuer task at creation — patch posting](https://lwn.net/Articles/909485/)
4. [io_uring: batch multishot completions — patch posting](https://lwn.net/Articles/915635/)
5. [io_uring: avoid uring_lock for IORING_SETUP_SINGLE_ISSUER — patch posting (2025)](https://lwn.net/Articles/1050662/)
6. [The trouble with iowait — LWN](https://lwn.net/Articles/989272/)

## LKML Highlights

> lore.kernel.org was unreachable from this run; message-ids come from LWN's mirrors.

- **`<20220830125013.570060-1-dylany@fb.com>`** — Dylan Yudaken's DEFER_TASKRUN series (v4). It frames task_work interruption as a latency problem for network servers, and it ties the feature to SINGLE_ISSUER so the submitter and waiter are guaranteed to be the same task.
- **`<20251215200909.3505001-1-csander@purestorage.com>`** — Caleb Sander Mateos (v5, Dec 2025) points out that SINGLE_ISSUER had offered no speedup on its own. He uses its guarantee to skip `uring_lock`, suspending the submitter via task_work when another thread must register resources.
