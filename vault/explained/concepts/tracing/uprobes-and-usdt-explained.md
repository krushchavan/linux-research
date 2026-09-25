---
title: "uprobes and USDT — Explained"
category: explained
original: "[[uprobes-and-usdt]]"
subsystem: tracing
tags: [explained, tracing, uprobes, usdt, user-space]
converted: 2026-09-25
---

# uprobes and USDT, explained

> Plain-language companion to [[uprobes-and-usdt|the technical note]]. Same facts, fewer identifiers.

## The problem

Sometimes the interesting behaviour is in a **user-space program**: a web server's request handler, a database query path. Traditional debuggers attach with ptrace, which means a separate process, round trips for every event, and heavy overhead. Restarting or recompiling the application isn't always an option. And probes placed by raw file offset break as soon as the binary is rebuilt.

## The idea in one paragraph

uprobes apply kprobes' breakpoint trick to **user programs**. A probe is identified by **(file, offset)** rather than an address, so one registration covers *every* process running that binary, now and later. The breakpoint goes into a **copy-on-write** copy of the page, leaving the file itself untouched. **USDT** adds a table of contents: developers compile named, no-op probe markers into their programs, and tools attach by name ("connection established in nginx") instead of by offset.

## Step by step

### Step 1: Identify the probe by file and offset
Because of address randomisation, the same binary sits at different addresses in different processes, and its pages may be shared. So a probe is keyed by the file's inode and a byte offset, independent of any one process, and it applies to processes started after it was registered too.

### Step 2: Patch through copy-on-write
This is the key step. Registration walks every existing mapping of that file. Where the page is in memory, the kernel makes a **copy-on-write copy** and writes a breakpoint at the offset in the copy; the on-disk file and page cache original are never modified. Later mappings of the same binary get the patched page transparently.

### Step 3: Trap and dispatch
When a process hits the breakpoint, the CPU traps into the kernel. The handler checks its table of probes, saves the thread's registers, and calls each attached consumer in turn: a BPF program, a trace event, and so on. A consumer can filter by process.

### Step 4: Run the original instruction out of line
The kernel maps a small **execute-out-of-line** area into the process. It copies the displaced original instruction there, sets the single-step flag and resumes there. After that one instruction, a debug trap fires and execution continues after the probe site. An optional **return handler** can also run when the probed function returns, like a kretprobe.

### Step 5: What it costs
Every hit is a trip from user mode into the kernel and back, with registers saved: more expensive than a kprobe hit, which never leaves the kernel, but far cheaper than ptrace, which needs a separate debugger process and inter-process round trips.

### Step 6: USDT markers
Developers place markers with DTrace- or SystemTap-style macros. Each compiles to a **single no-op instruction** plus an entry in an ELF note section recording the probe's provider, name, and where its arguments live. An untraced program pays nothing, not even a branch. To attach, a tool reads the ELF notes, turns the name into a file offset, and registers a uprobe there. The one-byte no-op is exactly the size of the one-byte breakpoint on x86, so enabling it touches a single byte, atomic without the multi-byte patching dance ftrace needs.

### Step 7: BPF on top
Since 4.7, BPF programs can attach to uprobes and USDT probes, with all the usual maps and helpers, and read user memory for arguments. libbpf later added helpers that read USDT arguments directly, without manual offset work.

## The picture

```text
 register(nginx, offset 0x4f2a0)
   every mapping of nginx: page → copy-on-write copy → [INT3] at offset
   (file on disk untouched; new processes get the patched page too)

 process runs … INT3 → kernel: save regs → consumers (BPF, trace event)
             → out-of-line area: original instruction, single-step → continue

 USDT: binary ships  [nop] + ELF note "nginx:connection_established, args…"
       tool: read note → offset → register uprobe → nop becomes INT3 (1 byte)
```

## Tradeoffs

- **What it gives you:** dynamic tracing of any user program without source changes, restarts or ptrace; one registration for all processes; stable named probes through USDT, free when unused.
- **What it costs / requires:** a user-to-kernel round trip per hit, noticeably more than a kprobe. Programs need USDT markers compiled in to get stable names; otherwise you're back to offsets that change with every rebuild.
- **Where it bites:** copy-on-write patching means probed pages become separate copies. The merge debate (2012) weighed this against patching each process individually, and settled on one probe covering all processes, since most users trace system-wide workloads.

## How it got here

- **3.5 (2012):** uprobes merged, breakpoint-based with copy-on-write on x86.
- **3.10:** uprobes as tracefs trace events.
- **4.7 (2016):** BPF programs on uprobes and USDT.
- **4.8+:** return handlers for user-space functions.
- **5.17+ / 6.x:** libbpf USDT support, including argument-reading helpers.

## Related

- Technical version: [[uprobes-and-usdt]]
- [[tracing-explained|Tracing subsystem]], [[kprobes-and-kretprobes-explained|kprobes]], [[tracepoints-and-trace-event-explained|Tracepoints]], [[tracefs-and-ring-buffer-explained|tracefs and ring buffer]], [[perf-events-explained|perf events]], [[ftrace-explained|ftrace]]
- [[bpf-explained|BPF]], [[libbpf-and-toolchain-explained|libbpf]], [[mm-explained|Memory management]]
