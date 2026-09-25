---
title: "tracefs and the Ring Buffer — Explained"
category: explained
original: "[[tracefs-and-ring-buffer]]"
subsystem: tracing
tags: [explained, tracing, tracefs, ring-buffer, lockless]
converted: 2026-09-25
---

# tracefs and the ring buffer, explained

> Plain-language companion to [[tracefs-and-ring-buffer|the technical note]]. Same facts, fewer identifiers.

## The problem

Tracing produces events at enormous rates, including from interrupt handlers and NMIs. Those events need somewhere to land, but taking a lock to record them would slow and distort the very behaviour being observed, and an NMI can't wait for a lock at all. Separately, people need a simple way to control tracing (which tracer, which functions, which events) from a shell, without a special daemon.

## The idea in one paragraph

Split the job in two. **tracefs** is the **switchboard**: a pseudo-filesystem whose files are levers and readouts, so `echo` and `cat` control everything. The **ring buffer** is a **ticker-tape machine per CPU**: each CPU stamps events onto its own roll without waiting for anyone, using atomic compare-and-swap instead of locks, and readers tear off finished sections without stopping the machine.

## Step by step

### Step 1: The control panel
tracefs is mounted at /sys/kernel/tracing (and also appears under the old debugfs path for compatibility). Its files include:
- the **current tracer** (none, function, function graph, irqs-off, …)
- an **on/off switch** that stops recording without removing any instrumentation, handy for arming probes and firing later
- a **function filter** by name pattern, and a text interface to dozens of tracer options
- an **events** tree with one directory per tracepoint, each with enable, filter and trigger files
- **instances**, each an independent tracing session (see Step 6)

### Step 2: One ring per CPU
Each CPU has its own ring: a linked loop of page-sized chunks. Writers never coordinate across CPUs. Each chunk carries timestamps so events from different CPUs can be put into global order afterwards.

### Step 3: Reserve, write, commit
A writer first **reserves** space for its event at the write end. It computes the new end position and tries to install it with one atomic compare-and-swap; if something else got there first, it retries. It then writes the event directly into the page and **commits** it.

### Step 4: Nested writers
This is the key step. An interrupt can arrive in the middle of a write on the same CPU, and an NMI can arrive in the middle of *that*. Each nested writer gets its own region, in stack order, and an outer write can't commit until every inner one has finished. The committed position therefore only moves over complete events, so readers never see half an event, and NMIs can record events without any lock. That's what made NMI-based tracers such as the hardware-latency detector possible.

### Step 5: Lock-free reading
A reader holds a private spare page and **swaps** it with the oldest full page using one compare-and-swap. That swap is the only point where reader and writers coordinate. Afterwards the reader owns the page and can parse it at leisure. Reading can be streaming (events consumed as read) or a non-consuming snapshot.

### Step 6: When it fills up, and instances
By default, a full buffer **overwrites** the oldest chunk, keeping the newest events without ever blocking a writer. Alternatively it can **drop** new events, which is better when the first events matter most, such as the root cause of a bug before the buffer fills with consequences. The per-CPU size is adjustable (default 7 KB, often raised to megabytes). **Instances** give fully independent buffers and tracer settings, so trace-cmd can run a system-wide trace while someone else traces events separately, with neither seeing or disturbing the other.

### Step 7: Compact events
Each event has a tiny header: a few bits for type and length (small events need no separate length field) and a time **delta** since the previous event; a full timestamp is written only when the delta overflows.

## The picture

```text
 tracefs (switchboard):  current_tracer  tracing_on  set_ftrace_filter  events/…  instances/…

 CPU 0 ring:  [page][page][page][page]  ← writers: reserve (CAS) → write → commit
                 ▲                           nested: task ⟶ IRQ ⟶ NMI, commit in stack order
   reader: swap spare page ⇄ oldest full page (one CAS) → parse privately
 CPU 1 ring:  [page][page][page][page]   (independent; order merged by timestamps)
 full? overwrite oldest (default) | drop newest
```

## Tradeoffs

- **What it gives you:** recording from any context, including NMIs, with no locks; complete control from a shell; isolated concurrent tracing sessions.
- **What it costs / requires:** events from different CPUs come out of order and have to be sorted by timestamp if interleaving matters. Page-sized chunks line up with memory pages, which keeps mapping the buffer to user space simple.
- **Where it bites:** the lock-free algorithm is intricate, with complexity reviewers compared to RCU, and it was merged without a formal proof, accepted on the strength of heavy testing and its author's track record.

## How it got here

- **2.6.27 (2008):** the first per-CPU ring buffer, still with a spinlock on writes (an earlier design also disabled interrupts while writing).
- **2.6.32 (2009):** Steven Rostedt's lock-free rewrite, making NMI-safe writes possible.
- **3.x:** instances with independent buffers.
- **5.x:** work begins on mapping the buffer directly into user space for zero-copy readers.
- **6.x:** user-space programs can write their own events into the kernel ring buffer.

## Related

- Technical version: [[tracefs-and-ring-buffer]]
- [[tracing-explained|Tracing subsystem]], [[ftrace-explained|ftrace]], [[tracepoints-and-trace-event-explained|Tracepoints]], [[kprobes-and-kretprobes-explained|kprobes]], [[perf-events-explained|perf events]]
- [[bpf-ring-buffer-explained|BPF ring buffer]], [[rcu-read-copy-update-explained|RCU]]
