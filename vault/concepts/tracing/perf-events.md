---
title: "perf Events"
category: concept
tags: [tracing, perf, pmu, sampling, hardware-counters, profiling]
subsystem: tracing
kernel_version: "2.6.31"
researched: 2026-04-17
status: complete
explained: "[[perf-events-explained]]"
sources:
  - https://kernel-internals.org/tracing/perf-events/
  - https://lwn.net/Articles/357481/
  - https://lwn.net/Articles/793749/
  - https://lwn.net/Articles/803347/
---

# perf Events

> 📘 Plain-language version: [[perf-events-explained]]

## Purpose

ftrace records *discrete events* (function calls, tracepoints); perf events measure *statistics* by sampling the system at high frequency and reading hardware performance counters. Profiling which functions account for CPU time, measuring cache miss rates, or detecting branch misprediction patterns all require the statistical model that perf events provide, not the per-event recording model of ftrace.

## Mental Model

Think of perf events as a **stroboscope attached to a tachometer**. The tachometer is the hardware performance monitoring unit (PMU): it counts physical events (CPU cycles, cache misses, branch mispredictions) in dedicated counter registers. The stroboscope is the sampling mechanism: every N events (or every ~N milliseconds), the PMU fires an NMI, the kernel freezes the instruction pointer and optionally the call stack, and records where the program was. Over many samples, statistical patterns emerge — functions that appear in many snapshots are the hot paths. Neither the tachometer nor the stroboscope tells you about individual events; together they show you the shape of the whole workload.

## How It Works

Everything in perf events starts with `perf_event_open()`. The caller constructs a `perf_event_attr` struct specifying: the event type (`PERF_TYPE_HARDWARE` for PMU counters, `PERF_TYPE_SOFTWARE` for kernel software counters, `PERF_TYPE_TRACEPOINT` for tracepoints, `PERF_TYPE_BREAKPOINT` for hardware watchpoints); the specific event config (e.g. `PERF_COUNT_HW_CPU_CYCLES`, `PERF_COUNT_HW_CACHE_MISSES`); the sample period or frequency; and a `sample_type` bitmask controlling what is captured per sample (instruction pointer, TID, timestamp, full call chain, register state, raw PMU data). The syscall returns a file descriptor representing the event; `ioctl` commands enable, disable, reset, and control the event; `mmap` maps the sample ring buffer.

For hardware PMU events, `perf_event_open()` calls into the PMU driver for the current CPU (Intel: `intel_pmu_init`, ARM: `armpmu_init`). The driver programs the hardware counter registers: on Intel, `IA32_PERFEVTSELx` configures which architectural event to count, and `IA32_PMCx` holds the counter value. The kernel sets the counter to a negative value equal to the sample period (e.g. `-10000`); when it overflows to zero, the PMU fires an NMI.

The NMI handler (`perf_event_nmi_handler()`) captures the saved instruction pointer from the NMI's `pt_regs`, then optionally unwinds the call stack. Three unwinding modes are supported: frame-pointer-based (fast, inaccurate if the binary was compiled without `-fno-omit-frame-pointer`), DWARF-based (accurate, copies up to 65535 bytes of raw stack into the sample for offline unwinding), and LBR (Last Branch Record, an Intel hardware feature that records the last 16–32 taken branches with near-zero overhead and no stack copying). After capturing the sample, the handler writes it to the `perf_buffer` ring buffer as a variable-length `perf_event_header` + fields record. It then reprograms the counter to `-sample_period` to schedule the next NMI.

The `perf_buffer` (mmap ring buffer) has a different layout from the ftrace ring buffer: it uses a shared memory page with `data_head` (written by kernel, ordering via `smp_wmb`) and `data_tail` (written by userspace after consumption). Userspace reads by polling `data_head` for advancement, then reading records between its current `data_tail` and `data_head`. The `perf` tool reads this buffer in a tight loop in `perf record` mode, writing records to a `perf.data` file for offline analysis.

**PMU multiplexing** handles the reality that hardware counter registers are finite. Intel Skylake has 4 general-purpose programmable counters plus 3 fixed-function counters (instructions retired, CPU cycles unhalted, reference cycles). If the user requests 10 events simultaneously, the kernel time-slices them: on each context switch, `perf_pmu_sched_task()` saves the current counter values, selects the next batch of events to schedule, and programs the PMU registers. Each event records `time_running` (how long it was scheduled) and `time_enabled` (total elapsed time), allowing the perf tool to extrapolate raw counts to estimated totals: `estimated = raw_count * (time_enabled / time_running)`. This gives approximate values for metrics that don't fit simultaneously in hardware, clearly marked as estimates in `perf report` output.

Software counters (`PERF_TYPE_SOFTWARE`) bypass the PMU entirely. `PERF_COUNT_SW_PAGE_FAULTS` is incremented by `perf_sw_event(PERF_COUNT_SW_PAGE_FAULTS, ...)` inside `handle_mm_fault()`; `PERF_COUNT_SW_CONTEXT_SWITCHES` is fired from the scheduler. These counters can be used for sampling (generating a sample on every N page faults, for example) using the same ring-buffer and mmap infrastructure as hardware events.

Tracepoint events (`PERF_TYPE_TRACEPOINT`) attach perf's sample collection to any ftrace tracepoint. When a tracepoint fires, if a matching perf event is active, `perf_trace_buf_submit()` writes the tracepoint's field data plus any requested `sample_type` fields (stack, TID, etc.) into the `perf_buffer`. This gives perf's statistical correlation capabilities (grouping samples by time, PID, CPU) to tracepoint data.

## Key Data Structures

**`struct perf_event`** (`include/linux/perf_event.h`) — the central kernel object representing one active counter.
- `attr` — `perf_event_attr` with full user configuration
- `hw` — `hw_perf_event` with hardware-specific state: counter register index, previous counter value, sample period tracking
- `ctx` — pointer to `perf_event_context` (task context or per-CPU context)
- `rb` — pointer to the `perf_buffer` (mmap ring buffer) for sample delivery
- `overflow_handler` — called in NMI/interrupt context when the counter overflows; default writes a sample to `rb`

**`struct perf_event_attr`** (`include/uapi/linux/perf_event.h`) — user-facing configuration.
- `type` — `PERF_TYPE_HARDWARE`, `PERF_TYPE_SOFTWARE`, `PERF_TYPE_TRACEPOINT`, etc.
- `config` — event-specific identifier (e.g. `PERF_COUNT_HW_CPU_CYCLES`)
- `sample_period` / `sample_freq` — how often to generate samples; freq mode adapts period dynamically to maintain target rate
- `sample_type` — bitmask: `PERF_SAMPLE_IP`, `PERF_SAMPLE_TID`, `PERF_SAMPLE_CALLCHAIN`, `PERF_SAMPLE_REGS_USER`, `PERF_SAMPLE_STACK_USER`

**`struct perf_buffer`** (`kernel/events/ring_buffer.c`) — the mmap-shared sample ring buffer.
- `data_head` — kernel write pointer (updated atomically after each sample write)
- `data_tail` — userspace read pointer (updated by consumer after reading)
- `data_pages[]` — the actual ring buffer pages, mmap-mapped into userspace

## Key Functions / Entry Points

**`perf_event_open()`** (`kernel/events/core.c`) — syscall entry; validates `perf_event_attr`, allocates `perf_event`, finds the PMU driver, and programs hardware.

**`perf_event_overflow()`** (`kernel/events/core.c`) — called from NMI/interrupt context on counter overflow; captures IP and optional call chain; calls `overflow_handler`; reprograms counter.

**`perf_output_sample()`** (`kernel/events/core.c`) — formats a sample record according to `sample_type` and writes it to the `perf_buffer`.

**`perf_pmu_sched_task()`** (`kernel/events/core.c`) — called on context switch; saves/restores counter values for per-task events; rotates multiplexed events across limited hardware counters.

**`arch_perf_update_userpage()`** — updates the `perf_event_mmap_page` (the first page of the mmap) with the current `time_enabled` and `time_running`, enabling accurate extrapolation.

## Important Flags & Config Options

- `CONFIG_PERF_EVENTS` — master Kconfig; enables `perf_event_open()` and the software counter framework
- `CONFIG_HW_PERF_EVENTS` — hardware PMU support; selected by platform-specific configs
- `CONFIG_PERF_EVENTS_INTEL_UNCORE` — Intel uncore (memory controller, PCIe) PMU support
- `perf_event_paranoid` (sysctl) — controls access:
  - `-1` = all users can profile, including kernel addresses
  - `0` = all users can do system-wide profiling
  - `1` (default on many distros) = unprivileged users limited to their own processes
  - `2` = only root can use perf events (or `CAP_PERFMON` since Linux 5.8)
- `kptr_restrict` (sysctl) — controls whether kernel addresses appear symbolised in samples for unprivileged users

## Interactions with Other Subsystems

- **↑ Userspace**: `perf_event_open()` syscall; `mmap()` ring buffer for sample delivery; `ioctl(PERF_EVENT_IOC_ENABLE/DISABLE/RESET/REFRESH)` for lifecycle management; `libperf` wraps this for library consumers
- **→ Scheduler**: context switches call `perf_pmu_sched_task()` to save/restore per-task counter state; `PERF_COUNT_SW_CONTEXT_SWITCHES` is fired from `__schedule()`
- **→ Memory Management**: `PERF_COUNT_SW_PAGE_FAULTS` fires from `handle_mm_fault()`; `perf_event_mmap()` is called on every `mmap()` to update ASLR-aware symbolisation data
- **→ Tracepoints**: tracepoint events attach perf's sample collector to any ftrace event, adding timing and stack context to tracepoint data
- **← BPF**: BPF programs can attach to perf events via `BPF_PROG_TYPE_PERF_EVENT`; they access counter values and sample data via BPF helpers

## Design Decisions & Tradeoffs

**Statistical sampling over complete recording** — Recording every instruction executed would produce terabytes of data per second. Sampling at 99–999 Hz produces a statistically accurate picture of which functions account for CPU time with kilobytes per second of overhead. The tradeoff is that infrequent or bursty code (a function called once per second that takes 1 ms) may be statistically invisible — tools like `trace-cmd` with ftrace are better for those cases.

**NMI-based sampling** — Timer-based profiling (firing at regular wall-clock intervals) is biased: it misses functions that only execute during interrupt context. NMI-based sampling (counter overflow fires an NMI regardless of the current kernel state) captures everything, including NMI-safe sections. The tradeoff is that NMI handlers must be extremely careful about re-entrance and stack usage.

**`perf_event_paranoid` layering** — Access control is tiered by the sensitivity of what is revealed: a count of CPU cycles is benign, but a call chain with kernel addresses reveals the kernel's internal structure. The `perf_event_paranoid` sysctl allows per-system policy tuning between "allow broad profiling for developer productivity" and "restrict to root for security".

**Single syscall, many event types** — `perf_event_open()` handles hardware PMU, software counters, tracepoints, kprobes, uprobes, and breakpoints through a single interface. This creates an extremely complex `perf_event_attr` struct (nearly 100 fields) but ensures all sample types are delivered through the same `perf_buffer` ring buffer, enabling correlation across event types by timestamp.

## How It Has Evolved

- **2.6.31 (2009)** — `perf_event_open()` merged; replaces the earlier per-architecture `perfctr` interface; initial PMU counters + software counters
- **2.6.33** — Tracepoint events attached to perf; `PERF_TYPE_TRACEPOINT`
- **3.x** — DWARF-based stack unwinding; LBR (Last Branch Record) support for Intel
- **4.1 (2015)** — `perf_event_attr` extended with `clockid` field for choosing the clock source
- **4.4** — Intel PT (Processor Trace) integrated via a new PMU; full instruction-level recording
- **5.8 (2020)** — `CAP_PERFMON` capability added; allows granting perf access without full root
- **6.x** — Continued work on AMD IBS (Instruction-Based Sampling) integration; ring buffer mmap improvements for low-overhead consumers

## Further Reading

1. [KS2009: The future of perf events (LWN, 2009)](https://lwn.net/Articles/357481/) — Ingo Molnár and Peter Zijlstra introduce perf as the unified interface for all hardware performance analysis
2. [Unifying kernel tracing (LWN, 2019)](https://lwn.net/Articles/803347/) — context for `libperf` as a shared library wrapping perf_event_open()
3. [kernel-internals.org: perf Events](https://kernel-internals.org/tracing/perf-events/) — practical architecture overview with key structs

## LKML Highlights

- **perf events introduction (2009)** — Peter Zijlstra's original patches proposed a unified `perf_event_open()` to replace the many per-architecture performance counter interfaces; Ingo Molnár championed its inclusion as the de-facto profiling interface going forward.
