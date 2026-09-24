---
title: "io_uring Async Poll and Multishot Requests"
category: concept
tags: [io_uring, poll, multishot, networking, wait-queue]
subsystem: io_uring
kernel_version: "5.7"
researched: 2026-09-24
status: complete
sources:
  - https://kernel-internals.org/io-uring/multishot-ops/
  - https://kernel-internals.org/io-uring/networking/
  - https://kernel-internals.org/io-uring/io-uring-vs-epoll/
  - https://kernel-internals.org/io-uring/war-stories/
  - https://lwn.net/Articles/810414/
  - https://lwn.net/Articles/915635/
  - https://kernelnewbies.org/Linux_6.15
---

# io_uring Async Poll and Multishot Requests

## Purpose

For pollable files (sockets, pipes, eventfds, ttys), "would block" usually means "not ready yet", not "must sleep in the kernel". Sending such requests to an [[io-wq]] thread that then sleeps in `recv()` would recreate thread-per-connection. Async poll instead parks the request on the file's own wait queue and retries it when the file signals readiness, all without a thread. Multishot builds on that so one SQE can keep producing completions (every new connection, every chunk of data) without being resubmitted. Together they make io_uring a complete replacement for an epoll event loop.

## Mental Model

Async poll is **leaving your number with the shop**. Instead of standing in line (a blocked worker thread), you give the shop a callback (a wait-queue entry). When your order is ready the shop calls you, and you come back and pick it up (a task_work retry). Multishot is a **standing order**: after each pickup, the shop keeps your number and calls again when the next batch is ready. That continues until you cancel, something goes wrong, or you run out of bags to carry things home in (`-ENOBUFS`).

## How It Works

**From -EAGAIN to armed poll.** Every request is first issued with `IO_URING_F_NONBLOCK`. Say an `IORING_OP_RECV` on a TCP socket gets `-EAGAIN` because the receive queue is empty. `io_queue_async()` then checks whether the file supports polling (`file_can_poll()`) and whether the opcode is marked `pollin` or `pollout` in its `io_issue_def`. If so it calls `io_arm_poll_handler()` rather than punting to io-wq. That function allocates a `struct async_poll` (from a per-ring cache when possible), sets the desired mask (`EPOLLIN` for recv, `EPOLLOUT` for send), and calls `vfs_poll()` with a custom `poll_table` whose queue proc, `io_async_queue_proc()`, adds io_uring's own `wait_queue_entry` to the socket's wait queue. `vfs_poll()` also returns the current readiness. If the socket became ready between the failed attempt and arming, the race is caught right there and the request is retried immediately.

**Ownership: `poll_refs`.** Once armed, several parties may touch the request concurrently: the socket's wakeup (`io_poll_wake()` on any CPU, often in softirq), a cancellation, and the task processing a previous wakeup. io_uring arbitrates with `req->poll_refs`, an atomic counter where the low bits count pending "events" and high bits are flags (`IO_POLL_CANCEL_FLAG`, `IO_POLL_RETRY_FLAG`). Whoever increments it from zero owns the request and must process it. Anyone else just bumps the count so the owner knows to loop again. This scheme (Pavel Begunkov, 5.17-era) replaced a lock-heavy design and fixed a long series of poll races.

**Wakeup.** When data arrives, `sk_data_ready()` wakes the socket wait queue and `io_poll_wake()` runs. It checks the mask, and if the request is a one-shot it removes the wait entry. Then, if it gains ownership through `io_poll_get_ownership()`, it queues task_work via `__io_poll_execute()`. Nothing else is done in the waker's context: no copying and no CQE. That keeps softirq time short.

**Retry in task context.** `io_poll_task_func()` runs in the submitter via [[io-uring-task-work]]. It calls `io_poll_check_events()`, which re-reads readiness with `vfs_poll()`, handles any cancellation flag, and then, for internal async poll, re-issues the original operation with `io_req_task_submit()`. The recv now finds data, selects a buffer if `IOSQE_BUFFER_SELECT` is set, copies, and completes.

**Multishot.** A multishot request is flagged `REQ_F_APOLL_MULTISHOT`. On a successful transfer the handler does *not* complete the request. It posts an auxiliary CQE through `io_req_post_cqe()` with `IORING_CQE_F_MORE` set, keeps the poll armed, and loops: it tries the operation again right away while the socket still has data (bounded, so one busy socket can't monopolise the task), and goes back to waiting on poll when it hits `-EAGAIN`. Handlers signal what should happen next with internal return codes. `IOU_ISSUE_SKIP_COMPLETE` means "I posted my own CQE, keep me armed". A final result ends the chain. The terminating CQE lacks `IORING_CQE_F_MORE`, which is how userspace knows the SQE is dead. Termination happens on:
- an error, including `-ENOBUFS` when the provided buffer ring is empty
- EOF (`res == 0` on recv)
- explicit cancellation (`IORING_OP_ASYNC_CANCEL`)
- CQ overflow, since the kernel stops multishots rather than overflow indefinitely

**Poll as an operation.** The same engine backs the explicit `IORING_OP_POLL_ADD`, io_uring's epoll-equivalent readiness notification. With `IORING_POLL_ADD_MULTI` (5.13) it posts a CQE carrying the ready mask each time the file becomes ready. `IORING_OP_POLL_REMOVE` can cancel it or update its mask and `user_data` in place.

**Double poll.** Some files register on *two* wait queues in `->poll` (for example a tty with separate read and write queues, or signalfd). io_uring then needs two wait entries, handled via `apoll->double_poll`, and wakeup ownership must cover both. This is a classic source of bugs.

**Cancellation.** Armed requests go into hash tables (`ctx->cancel_table`, keyed by `user_data`) so that `IORING_OP_ASYNC_CANCEL` can find them without scanning. Cancel-by-fd and cancel-all (`IORING_ASYNC_CANCEL_FD`, `_ALL`, `_ANY`, 5.19) walk the tables. The canceller sets `IO_POLL_CANCEL_FLAG` in `poll_refs`. If it gains ownership it tears the request down directly. Otherwise the current owner sees the flag and does it.

**Which operations are multishot.** Accept (`IORING_ACCEPT_MULTISHOT`, 5.19; each CQE is a new fd or direct-descriptor index), recv/recvmsg (`IORING_RECV_MULTISHOT`, 6.0; buffers required), poll (5.13), timeouts (`IORING_TIMEOUT_MULTISHOT`, 6.4; periodic ticks), read on pollable files (`IORING_OP_READ_MULTISHOT`, 6.7), zero-copy receive (`IORING_OP_RECV_ZC`, 6.15), and `IORING_OP_EPOLL_WAIT` (6.15) for bridging existing epoll sets into a ring.

**Failure paths.** If the file can't be polled, or poll arming fails with `-ENOMEM`, the request falls back to io-wq. If the file is released while a poll is armed, the wait-queue entry is removed through the file's `->release` → `wake_up_pollfree()` path (`POLLFREE` handling), and the request completes with `-ECANCELED`. That path was added after use-after-free bugs with signalfd and binder.

## Key Data Structures

**`struct io_poll`** (`io_uring/poll.h`) — one wait-queue registration.
- `file` — the polled file
- `head` — the wait-queue head it is on (NULL once removed)
- `events` — requested mask, plus `EPOLLONESHOT` for single-shot
- `wait` — the embedded `wait_queue_entry` whose `func` is `io_poll_wake`

**`struct async_poll`** — internal poll for a non-poll opcode.
- `poll` — primary registration
- `double_poll` — optional second registration

**`io_kiocb` fields** — `poll_refs` (ownership atomic), `apoll`, `hash_node` (cancel table), flags `REQ_F_POLLED`, `REQ_F_APOLL_MULTISHOT`, `REQ_F_DOUBLE_POLL`.

## Key Functions / Entry Points

**`io_arm_poll_handler()`** (`io_uring/poll.c`) — arm internal poll after a non-blocking attempt returns `-EAGAIN`.

**`__io_arm_poll_handler()`** — common arming: `vfs_poll()` with io_uring's queue proc, race check, insert into cancel hash.

**`io_poll_wake()`** — wait-queue callback; claims ownership and queues task_work.

**`io_poll_task_func()`** / **`io_poll_check_events()`** — task-context processing, retry, multishot loop.

**`io_req_post_cqe()`** — post an extra CQE for a multishot request.

**`io_poll_cancel()` / `io_async_cancel()`** (`io_uring/cancel.c`) — cancellation.

## Important Flags & Config Options

- **`IORING_POLL_ADD_MULTI`**, **`IORING_POLL_UPDATE_EVENTS`**, **`IORING_POLL_UPDATE_USER_DATA`** — poll opcode flags.
- **`IORING_ACCEPT_MULTISHOT`**, **`IORING_RECV_MULTISHOT`**, **`IORING_TIMEOUT_MULTISHOT`**.
- **`IORING_CQE_F_MORE`** — more CQEs will follow for this SQE.
- **`IORING_CQE_F_SOCK_NONEMPTY`** — socket still had data when this recv completed.
- **`IORING_ASYNC_CANCEL_ALL` / `_FD` / `_ANY` / `_FD_FIXED` / `_USERDATA` / `_OP`** — cancellation matching.
- **`IOSQE_ASYNC`** — skip the inline attempt. For pollable files this arms poll straight away (rather than io-wq) on modern kernels.

## Interactions with Other Subsystems

- **↑ Userspace**: liburing `io_uring_prep_poll_multishot()`, `io_uring_prep_multishot_accept_direct()`, `io_uring_prep_recv_multishot()`. Loops check `IORING_CQE_F_MORE`.
- **→ [[vfs]]**: uses `vfs_poll()` and each file's `->poll` method, the same entry point as `poll(2)`/epoll.
- **→ [[net]]**: socket wakeups (`sk_data_ready`, `sk_write_space`) drive `io_poll_wake()`. Multishot accept can install into direct descriptors ([[registered-resources]]).
- **→ [[provided-buffer-rings]]**: multishot recv needs a buffer per completion.
- **→ [[io-uring-task-work]]**: every wakeup continues in task context.
- **← Scheduler / wait queues**: io_uring's entry is an ordinary `wait_queue_entry` with a custom wake function, the same trick epoll uses.

## Design Decisions & Tradeoffs

**Poll-then-retry instead of blocking threads (5.7).** Before async poll, networking via io_uring could be slower than epoll because every blocking op cost a worker thread. Arming poll made socket I/O thread-free. The price is a second attempt at the operation after wakeup, and a lot of concurrency machinery.

**Do almost nothing in the wakeup.** `io_poll_wake()` only claims ownership and queues task_work. Keeping softirq time minimal and doing the copy in the owner's context improves cache locality and fairness. It adds a hop of latency, which DEFER_TASKRUN batching then amortises.

**Refcount-style ownership (`poll_refs`).** Earlier versions used locks and state flags and had repeated races between wakeup, cancellation and completion (several CVEs). The atomic-ownership scheme is harder to read but provably serialises processing.

**Multishot termination by absent `F_MORE`.** Userspace needs a clear signal that an SQE is finished so it can free its state. Tying that to a CQE flag keeps the ABI simple, but every multishot consumer must remember to re-arm on a final CQE, including after `-ENOBUFS`.

**Backpressure via buffers and CQ space.** Multishot could flood the CQ. Stopping on buffer exhaustion or overflow keeps memory bounded, at the cost of occasional re-arm round-trips.

## How It Has Evolved

- **5.1** — `IORING_OP_POLL_ADD` (one-shot) only. Blocking socket ops go to workers.
- **5.7** — internal async poll ("fast poll") for pollable files. Big networking gains.
- **5.13** — multishot poll; poll update.
- **5.17–5.18** — `poll_refs` ownership rework; `POLLFREE` handling.
- **5.19** — multishot accept; extended cancellation (`_ALL`, `_FD`, `_ANY`).
- **6.0** — multishot recv/recvmsg with buffer rings.
- **6.2** — batched multishot CQE posting.
- **6.4** — multishot timeouts.
- **6.7** — multishot read.
- **6.15** — `IORING_OP_EPOLL_WAIT`; multishot `RECV_ZC`.

## Further Reading

1. [kernel-internals.org — Multishot operations](https://kernel-internals.org/io-uring/multishot-ops/)
2. [kernel-internals.org — io_uring vs. epoll](https://kernel-internals.org/io-uring/io-uring-vs-epoll/)
3. [kernel-internals.org — Networking with io_uring](https://kernel-internals.org/io-uring/networking/)
4. [The rapid growth of io_uring — LWN (2020)](https://lwn.net/Articles/810414/) — context for the 5.7 async-poll change.
5. [io_uring: batch multishot completions — patch posting](https://lwn.net/Articles/915635/)
6. [kernel-internals.org — war stories](https://kernel-internals.org/io-uring/war-stories/) — poll/cancellation bugs in production.

## LKML Highlights

> lore.kernel.org was unreachable from this run.

- **"io_uring: add support for async poll" (Jens Axboe, 5.7 cycle)** — introduced arming the file's wait queue on `-EAGAIN` instead of punting to workers, which made io_uring networking competitive with epoll.
- **Poll refcounting rework (Pavel Begunkov, ~5.17)** — replaced lock-based wakeup/cancel coordination with the `poll_refs` ownership counter, after a string of race-condition bugs in double-poll and cancellation.
- **"io_uring: batch multishot completions" (Dylan Yudaken, 6.2 cycle)** — defers multishot auxiliary CQEs into the completion batch rather than taking the CQ lock for each one, a significant win for multishot recv under load.
