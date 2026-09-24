---
title: "SQPOLL (Submission Queue Polling)"
category: concept
tags: [io_uring, sqpoll, polling, kernel-thread, low-latency]
subsystem: io_uring
kernel_version: "5.1"
researched: 2026-09-24
status: complete
sources:
  - https://kernel-internals.org/io-uring/io-uring-arch/
  - https://kernel-internals.org/io-uring/life-of-request/
  - https://kernel-internals.org/io-uring/security/
  - https://lwn.net/Articles/776703/
  - https://lwn.net/Articles/846807/
  - https://lwn.net/Articles/1050662/
---

# SQPOLL (Submission Queue Polling)

## Purpose

io_uring's shared rings remove the per-operation syscall, but something still has to notice that new SQEs exist. Normally that is `io_uring_enter()`, one syscall per batch. SQPOLL dedicates a kernel thread to polling the SQ ring so that, in steady state, submission costs only a memory store by userspace. It matters for workloads where the remaining syscall and its mitigation overhead (Spectre/Meltdown entry costs) are a measurable share of per-I/O CPU.

## Mental Model

SQPOLL is a **courier waiting outside your door**. Instead of phoning the post office for every batch of letters (`io_uring_enter`), you drop letters in the outbox and the courier grabs them. If you stop sending letters for a while, the courier goes home and leaves a note on the door ("ring me when you need me"—`IORING_SQ_NEED_WAKEUP`), and your next send has to include one phone call to bring the courier back.

## How It Works

**Creation.** When `io_uring_setup()` sees `IORING_SETUP_SQPOLL`, `io_sq_offload_create()` either allocates a new `struct io_sq_data` or, with `IORING_SETUP_ATTACH_WQ` and a `wq_fd` that also uses SQPOLL, attaches this ring to the existing one. It then starts the thread with `create_io_thread(io_sq_thread, ...)`. Because it is an *io thread* (5.12+) of the creating process, it naturally runs with that process's `mm`, files and credentials—so it can only do what the creator could have done, which is why SQPOLL stopped needing `CAP_SYS_ADMIN` in 5.11. The LSM hook `security_uring_sqpoll()` lets policies still forbid it. If `IORING_SETUP_SQ_AFF` is set, the thread is pinned to `sq_thread_cpu`.

**The polling loop.** `io_sq_thread()` runs a loop over every ring on `sqd->ctx_list`. For each ring, `__io_sq_thread()` computes how many SQEs are pending (`io_sqring_entries()`), takes `ctx->uring_lock`, and calls `io_submit_sqes()`—the same function `io_uring_enter()` uses—capped per round so one busy ring can't starve others sharing the thread. If the ring uses `IORING_SETUP_IOPOLL`, the thread also calls `io_do_iopoll()` to reap polled completions, which makes SQPOLL+IOPOLL the fully interrupt-free, syscall-free configuration used for top-end NVMe benchmarks. Between rings the thread runs its own pending task_work and checks `need_resched()`/signals; it will yield the CPU rather than monopolise it.

**Going idle.** Every time the loop does useful work it refreshes a timeout. Once `sq_thread_idle` milliseconds (default 1 s) pass with no SQEs and no IOPOLL work, the thread prepares to sleep: it sets `IORING_SQ_NEED_WAKEUP` in each ring's shared `sq_flags`, issues a full memory barrier, re-checks the SQ ring (to close the race where userspace added work between the check and the flag), and then sleeps on `sqd->wait`. Userspace, after bumping the SQ tail, must read `sq_flags` (liburing does this in `io_uring_submit()`) and, if `NEED_WAKEUP` is set, call `io_uring_enter()` with `IORING_ENTER_SQ_WAKEUP`, which wakes the thread. If userspace instead wants to wait until SQ space frees up, `IORING_ENTER_SQ_WAIT` blocks until the thread has consumed entries.

**Overflow and task_work signalling.** Because userspace may never enter the kernel under SQPOLL, the thread communicates state via flags: `IORING_SQ_CQ_OVERFLOW` tells userspace CQEs are waiting in the kernel overflow list and an `io_uring_enter(GETEVENTS)` is needed to flush them; `IORING_SQ_TASKRUN` (with `IORING_SETUP_TASKRUN_FLAG`) indicates pending task_work.

**Parking.** Some operations—registering files or buffers, resizing rings, adding or removing a ring from a shared `io_sq_data`—must not race with submission. `io_sq_thread_park()` sets a park bit and waits for the thread to reach a safe point; `io_sq_thread_unpark()` releases it. This is why register calls on SQPOLL rings are comparatively expensive.

**Teardown and failure.** When the last ring detaches, `io_sq_thread_finish()` stops the thread. If the owning process exits, its io threads exit with it; any SQEs left unsubmitted are discarded. A subtle failure mode is **submitter/consumer confusion**: with SQPOLL, SQEs are consumed asynchronously, so userspace must not reuse an SQE slot until the kernel's SQ head has passed it—liburing's `io_uring_get_sqe()` handles this, hand-rolled ring code often doesn't.

## Key Data Structures

**`struct io_sq_data`** (`io_uring/sqpoll.h`) — the shared polling thread state.
- `refs` — number of rings using it
- `ctx_list` — rings to poll
- `thread`, `task_pid`, `sq_cpu` — the io thread and its CPU
- `sq_thread_idle` — idle timeout (the max across attached rings)
- `wait` — where the idle thread sleeps
- `state` — park/stop bits

**Shared SQ flags** (`struct io_rings.sq_flags`) — `IORING_SQ_NEED_WAKEUP`, `IORING_SQ_CQ_OVERFLOW`, `IORING_SQ_TASKRUN`.

## Key Functions / Entry Points

**`io_sq_offload_create()`** (`io_uring/sqpoll.c`) — create/attach the SQPOLL thread during setup.

**`io_sq_thread()`** — thread main loop; polls rings, runs task_work, manages idle.

**`__io_sq_thread()`** — per-ring step: submit pending SQEs, IOPOLL reap.

**`io_sq_thread_park()` / `io_sq_thread_unpark()`** — quiesce the thread for registration changes.

**`io_uring_enter()`** — with `IORING_ENTER_SQ_WAKEUP`, wakes a sleeping SQPOLL thread; with `IORING_ENTER_SQ_WAIT`, waits for SQ space.

## Important Flags & Config Options

- **`IORING_SETUP_SQPOLL`** — enable the polling thread.
- **`IORING_SETUP_SQ_AFF` + `sq_thread_cpu`** — pin to a CPU. Pinning to an isolated core avoids the thread competing with the application; pinning to a busy core can cause missed wakeups and latency spikes.
- **`sq_thread_idle`** (ms) — how long to spin before sleeping. Higher values burn more CPU but avoid wakeup syscalls for bursty loads.
- **`IORING_SETUP_ATTACH_WQ`** — share one SQPOLL thread among multiple rings (e.g. per-thread rings in one process).
- **`IORING_SETUP_IOPOLL`** — combine with SQPOLL for completely interrupt- and syscall-free NVMe I/O.
- **`IORING_SETUP_SINGLE_ISSUER`** — with SQPOLL, the SQPOLL thread counts as the single issuer; lock-elision optimisations for SINGLE_ISSUER explicitly exclude SQPOLL.

## Interactions with Other Subsystems

- **↑ Userspace**: sees a thread named `iou-sqp-<pid>`; must honour `NEED_WAKEUP` and SQ head semantics.
- **→ Scheduler**: the thread is a normal task that busy-polls; it calls `cond_resched()`/checks `need_resched()` and consumes a full CPU while active, visible in `top`.
- **→ [[block]]**: with IOPOLL, calls the driver's `->iopoll` hook to reap completions from polled hardware queues.
- **→ [[io-uring-task-work]]**: runs task_work queued for its own context between polling rounds.
- **← [[security]]**: `security_uring_sqpoll()` LSM hook; SELinux can deny `io_uring { sqpoll }`.

## Design Decisions & Tradeoffs

**Burning a CPU to save syscalls.** SQPOLL trades a (partly) dedicated core for zero-syscall submission. On a machine where cores are scarce, or with a low request rate, the idle/wakeup dance can cost more than it saves; benchmarks consistently show SQPOLL helping only at high, sustained IOPS.

**Privilege model.** Originally SQPOLL required `CAP_SYS_ADMIN` because a kthread running with borrowed identity was risky and because it can burn CPU. 5.11 dropped the requirement once the thread was guaranteed to run with the creator's own credentials, and 5.12 made that structural by turning it into an io thread; it is now accounted to the user like any other thread.

**Sharing threads.** One thread per ring wastes CPUs for applications with ring-per-thread designs; `ATTACH_WQ` sharing fixes that but introduces fairness concerns and the need to park the thread across all rings for any registration change.

**Asynchronous consumption changes the contract.** Without SQPOLL, the SQ is fully consumed by the time `io_uring_enter()` returns; with it, consumption is concurrent. This subtly changes error handling (submission errors arrive as CQEs, not return values) and SQE reuse rules.

## How It Has Evolved

- **5.1** — SQPOLL present from the start, as a kthread; requires `CAP_SYS_ADMIN`.
- **5.9–5.10** — shared SQPOLL threads via `IORING_SETUP_ATTACH_WQ`; `IORING_ENTER_SQ_WAIT`.
- **5.11** — unprivileged SQPOLL.
- **5.12** — converted to an io thread (`create_io_thread()`), inheriting the creator's context.
- **5.19** — `IORING_SQ_TASKRUN` signalling for COOP_TASKRUN.
- **6.x** — SQPOLL busy/idle time reported in the ring's `fdinfo`, which makes it possible to measure whether the dedicated thread is paying for itself.

## Further Reading

1. [Ringing in a new asynchronous I/O API — LWN (2019)](https://lwn.net/Articles/776703/) — introduces polled submission.
2. [Remove kthread usage from io_uring — patch posting (2021)](https://lwn.net/Articles/846807/)
3. [kernel-internals.org — io_uring architecture](https://kernel-internals.org/io-uring/io-uring-arch/)
4. [kernel-internals.org — io_uring security](https://kernel-internals.org/io-uring/security/)
5. `io_uring_setup(2)` man page — SQPOLL semantics and flags.

## LKML Highlights

> lore.kernel.org was unreachable from this run; entries are from LWN-mirrored postings.

- **"Remove kthread usage from io_uring" (Axboe, 2021)** — the conversion of SQPOLL to an io thread, which is what made unprivileged SQPOLL safe.
- **`<20251215200909.3505001-1-csander@purestorage.com>`** — Caleb Sander Mateos' SINGLE_ISSUER `uring_lock` elision (Dec 2025) explicitly excludes SQPOLL, because the polling thread would need extra synchronisation with the registering task—an example of SQPOLL's cross-thread nature constraining optimisations elsewhere.
