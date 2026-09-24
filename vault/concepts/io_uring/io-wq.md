---
title: "io-wq"
category: concept
tags: [io_uring, io-wq, worker-threads, async-io, io-threads]
subsystem: io_uring
kernel_version: "5.3"
researched: 2026-09-24
status: complete
sources:
  - https://lwn.net/Articles/803070/
  - https://lwn.net/Articles/803036/
  - https://lwn.net/Articles/846807/
  - https://lwn.net/SubscriberLink/1094303/50affb2e7bd3e698/
  - https://kernel-internals.org/io-uring/life-of-request/
  - https://kernel-internals.org/io-uring/war-stories/
---

# io-wq

## Purpose

io_uring promises that submission never blocks, but many kernel operations can only be performed by a thread that is allowed to sleep: buffered writes that take `i_rwsem`, `fsync`, most metadata operations, and any file whose `->read_iter` ignores `IOCB_NOWAIT`. io-wq is the io_uring-specific thread pool that performs those blocking retries on the submitter's behalf. Without it, io_uring would either have to block the submitting thread (defeating the point) or refuse those operations.

## Mental Model

io-wq is a **back office staffed by clones of the customer**. When a request can't be finished at the counter, it is handed to a worker who is literally a thread of the submitting process: same memory, same open files, same credentials. The office has two queues—one for jobs that will certainly finish soon (disk I/O) and one for jobs that might wait forever (sockets, pipes)—so that a crowd of indefinite waits can't use up all the clerks needed for the quick jobs.

## How It Works

**Getting there.** Every request is first issued inline with `IO_URING_F_NONBLOCK`. If the handler returns `-EAGAIN` and the file cannot be polled (or the opcode has no poll support, or `IOSQE_ASYNC` was set), the core calls `io_queue_iowq()`. That prepares the request for a context switch—any iovec or msghdr state the handler needs is copied into `req->async_data` so it survives outside the submitter's stack—and passes the request's embedded `struct io_wq_work` to `io_wq_enqueue()`. The pool itself is created lazily per task: the first time a task needs it, `io_init_wq_offload()` builds a `struct io_wq` and hangs it off the task's `struct io_uring_task` (`tctx->io_wq`). All rings used by that task share the pool, and `IORING_SETUP_ATTACH_WQ` lets a ring explicitly reuse another ring's pool.

**Choosing a queue: bound vs. unbound.** `struct io_wq` holds two `struct io_wq_acct` accounting classes. Work on regular files and block devices goes to **bound** (`IO_WQ_ACCT_BOUND`): it will finish in bounded time, so its worker limit is modest (derived from ring size and CPU count). Work on anything that may wait indefinitely—sockets, pipes, ttys; the opdef flag `unbound_nonreg_file` identifies these—goes to **unbound** (`IO_WQ_ACCT_UNBOUND`), limited only by the task's `RLIMIT_NPROC`. The split exists because early versions used a single pool: a thousand `recv`s waiting on idle connections could occupy every worker and starve disk writes behind them.

**Hashed work.** Buffered writes to the same regular file would all contend on the inode's `i_rwsem`; running them in parallel just makes N workers sleep on one lock. So `io_wq_hash_work()` tags such work with a hash derived from the inode. Within an acct, `io_get_next_work()` will run only one work item per hash bucket at a time; the rest of that chain is stalled until the running item finishes. Work for different inodes still runs in parallel. This was one of the original motivations for replacing generic workqueues (LWN, 2019): standard workqueues offer no way to express "don't run these concurrently".

**Waking or creating a worker.** `io_wq_enqueue()` appends the work to the acct's list, then tries `io_wq_activate_free_worker()` to wake an idle worker. If none is free and the acct is below `max_workers`, a new worker is created—but not directly. Since 5.12 workers are *io threads*: created with `create_io_thread()` as real threads of the submitting process, carrying `PF_IO_WORKER`. Creation must happen from that task, so io-wq queues a task_work (`create_worker_cb`) which runs `create_io_worker()` when the task next enters/leaves the kernel. This design replaced kthreads that temporarily borrowed the submitter's `mm`, `files` and creds (LWN "Remove kthread usage from io_uring", 2021); every resource they forgot to borrow had been a potential security bug.

**The worker loop.** Each worker (`struct io_worker`) runs `io_wq_worker()`: it pulls work from its acct under `acct->lock`, and for each item calls the ring's work handler `io_wq_submit_work()`. That function applies the snapshot credentials if the request carries a personality, then calls `io_issue_sqe(req, 0)`—*without* `IO_URING_F_NONBLOCK`—so the opcode handler can sleep on page locks, `i_rwsem`, or bio completion like an ordinary syscall. For pollable files that still return `-EAGAIN` (e.g. `IOSQE_ASYNC` on a socket), the worker may arm poll rather than spin. When the handler finishes, the completion is posted (`io_req_complete_post()` or via task_work to the owner) and the worker looks for more work. A worker that finds nothing sleeps; after an idle timeout (`WORKER_IDLE_TIMEOUT`) it exits, except that one worker per acct may stay around.

**Scheduling hooks.** Because the workers are real threads, the scheduler calls `io_wq_worker_sleeping()` / `io_wq_worker_running()` around their blocking. When a worker blocks with work still queued, io-wq can spin up another worker so the queue keeps draining—similar to the concurrency management of CMWQ, but under io_uring's control.

**Cancellation and teardown.** `io_wq_cancel_cb()` walks queued work (removing matches) and running workers (sending them a signal via `__set_notify_signal()` so interruptible sleeps return). On task exit or ring close, `io_uring_cancel_generic()` cancels everything, and `io_wq_exit_start()` / `io_wq_put_and_exit()` tear the pool down once no rings reference it.

**Failure path.** If a worker cannot be created (hit `RLIMIT_NPROC`, or the task is exiting), queued work is cancelled with `-ECANCELED`/`-EAGAIN` rather than left dangling. Worker explosion—thousands of unbound workers blocked on sockets—was a real production problem, fixed operationally by `IORING_REGISTER_IOWQ_MAX_WORKERS` (5.15).

## Key Data Structures

**`struct io_wq`** (`io_uring/io-wq.c`) — one per task (optionally shared).
- `acct[IO_WQ_ACCT_NR]` — bound and unbound classes
- `hash` — shared `struct io_wq_hash` bitmap/waitqueue for hashed work
- `task` — owning task; `cpu_mask` — worker affinity

**`struct io_wq_acct`** — `max_workers`, `nr_workers`, `nr_running`, `work_list`, `free_list`, `lock`.

**`struct io_worker`** — `task` (the io thread), `acct`, `cur_work`, `flags` (`IO_WORKER_F_FREE`, `_RUNNING`, `_BOUND`).

**`struct io_wq_work`** (embedded in `io_kiocb`) — `node` for the list, `flags` (`IO_WQ_WORK_CANCEL`, `IO_WQ_WORK_HASHED`, `IO_WQ_WORK_UNBOUND`, hash key in the high bits), `cancel_seq`.

## Key Functions / Entry Points

**`io_queue_iowq()`** (`io_uring/io_uring.c`) — core entry after an inline `-EAGAIN`; prepares async state and enqueues.

**`io_wq_enqueue()`** (`io_uring/io-wq.c`) — insert work, wake or schedule creation of a worker.

**`io_wq_hash_work()`** — tag work with an inode hash for serialisation.

**`io_wq_worker()`** — worker thread main loop.

**`io_wq_submit_work()`** (`io_uring/io_uring.c`) — per-request handler run by workers; issues without NONBLOCK.

**`io_wq_cancel_cb()`** — cancellation of queued/running work.

## Important Flags & Config Options

- **`IOSQE_ASYNC`** — skip the inline attempt and go straight to io-wq. Useful when you know the op will block (e.g. big buffered writes) and want to avoid the wasted non-blocking try.
- **`IORING_REGISTER_IOWQ_MAX_WORKERS`** (5.15) — set/get `[bound, unbound]` worker caps per task. The most important knob for servers with many blocked socket ops.
- **`IORING_REGISTER_IOWQ_AFF` / `IORING_UNREGISTER_IOWQ_AFF`** (5.14) — restrict workers to a CPU set.
- **`IORING_SETUP_ATTACH_WQ`** — share the io-wq of another ring (identified by fd).
- **`RLIMIT_NPROC`** — the effective cap on unbound workers.

## Interactions with Other Subsystems

- **↑ Userspace**: invisible except as extra threads named `iou-wrk-<tid>` in `/proc/<pid>/task`, and through the worker-limit/affinity registration ops.
- **→ Scheduler**: workers are ordinary `SCHED_NORMAL` threads; the scheduler's sleep/wake hooks drive dynamic worker creation.
- **→ [[vfs]] / filesystems**: workers perform the blocking `->read_iter`/`->write_iter`, `->fsync`, `do_filp_open()` calls.
- **→ [[credentials]]**: requests with a registered personality run under `override_creds()`; otherwise the worker already has the task's creds.
- **← [[io-uring-task-work]]**: worker creation is itself deferred via task_work to the owning task.
- **← [[io-uring-async-poll-and-multishot]]**: poll is preferred over io-wq for pollable files; io-wq is the fallback.

## Design Decisions & Tradeoffs

**A custom pool instead of workqueues.** Generic workqueues decide where and when work runs, have no notion of a user `mm`, and can't express per-inode serialisation. io-wq (5.3) took that control back at the cost of maintaining a bespoke thread pool.

**io threads instead of kthreads (5.12).** The kthread design required each worker to "assume" the submitter's `mm`, `files`, `fs`, creds, and more; missing one (e.g. `/proc/self` resolution, audit context, cgroup) produced bugs and CVEs. Real threads inherit everything by construction. The tradeoff: workers are visible to userspace, count against `RLIMIT_NPROC`, and must be handled carefully by `ptrace`, core dumps, and signal delivery (they ignore most signals).

**Bound/unbound split.** Guarantees forward progress for disk I/O while allowing large numbers of indefinite waits. The downside is that unbound work can still create very many threads; the explicit cap came later.

**Blocking is expensive by design.** Every io-wq punt costs a context switch and cross-CPU cache traffic. That's why the subsystem invests heavily in avoiding io-wq (async buffered reads, async poll, `FMODE_NOWAIT` support in filesystems) and why the 2026 *thread-identity handoff* RFC proposes paying worker cost only when the inline attempt actually blocks.

## How It Has Evolved

- **5.1** — async work punted to a generic kernel workqueue.
- **5.3** — io-wq introduced (Jens Axboe): per-node pools, bound/unbound, hashed work.
- **5.12** — workers and SQPOLL become io threads (`create_io_thread()`, `PF_IO_WORKER`); pool becomes per-task.
- **5.14–5.15** — worker affinity and max-worker registration.
- **6.x** — per-NUMA `io_wqe` structures collapsed into a single `io_wq` with two accts; continued cancellation fixes.
- **2026 (RFC)** — thread-identity handoff: when an inline issue is about to block, the scheduler hook `io_uring_task_sleeping()` swaps identities between the submitter and a worker so the worker continues userspace while the original thread blocks.

## Further Reading

1. [Redesigned workqueues for io_uring — LWN (2019)](https://lwn.net/Articles/803070/)
2. [Replace io_uring workqueues with io-wq — patch posting](https://lwn.net/Articles/803036/)
3. [Remove kthread usage from io_uring — patch posting (2021)](https://lwn.net/Articles/846807/)
4. [Thread-identity switcheroo for io_uring — LWN (2026)](https://lwn.net/SubscriberLink/1094303/50affb2e7bd3e698/)
5. [kernel-internals.org — Life of an io_uring request](https://kernel-internals.org/io-uring/life-of-request/)

## LKML Highlights

> lore.kernel.org was unreachable from this run; see the LWN-mirrored postings above.

- **"Replace io_uring workqueues with io-wq" (Axboe, Oct 2019)** — argues workqueues can't bind to a user `mm` or serialise per-file work; introduces hashed enqueue and the bound/unbound split.
- **"Remove kthread usage from io_uring" (Axboe, Feb 2021)** — converts workers and SQPOLL to io threads, deleting the resource-borrowing code that had caused repeated bugs.
- **Thread-identity handoff RFC (Axboe, Sep 2026)** — proposes swapping thread identities at block time instead of pre-emptively punting; reviewers focus on the long list of states (ptrace, RT, futex owner, vfork, shadow stacks) where a swap is unsafe.
