---
title: "BPF Ring Buffer — Explained"
category: explained
original: "[[bpf-ring-buffer]]"
subsystem: bpf
tags: [explained, bpf, ring-buffer, tracing, zero-copy]
converted: 2026-09-25
---

# The BPF ring buffer, explained

> Plain-language companion to [[bpf-ring-buffer|the technical note]]. Same facts, fewer identifiers.

## The problem

Tracing tools built on BPF generate a flood of events: every file opened, every packet sent, every process started. Each event has to get from a BPF program inside the kernel to a tool in userspace, fast.

The older mechanism, the *perf buffer*, gave every CPU its own buffer. On a 64-CPU machine that meant 64 buffers (most of them mostly empty, wasting memory), 64 things to wait on, and 64 read loops. Events from different CPUs arrived in separate streams, so the tool had to sort out the order itself. And reading meant going through the kernel, with a copy.

## The idea in one paragraph

Use **one** circular buffer for the whole machine, and map its memory directly into the reading program. A BPF program on any CPU *reserves* a slot, writes its event straight into it, and *commits* it. The reader sees the committed record appear in its own memory with no copy and no system call. Two shared counters, "how far the writers have got" and "how far the reader has got", are all either side needs to coordinate.

## Step by step

### Step 1: One region, two views
The buffer is one power-of-two-sized block of memory. The kernel sees it through its own mapping, where BPF programs write. The reader maps the same physical pages into its own address space, read-only. Two position counters (producer and consumer) sit on a separate shared page.

### Step 2: Reserve a slot
A BPF program asks for a slot of N bytes. The kernel takes a short lock, checks there's room (the writer mustn't lap the reader), writes a small 8-byte header marked *busy*, advances the producer position, and drops the lock. The program gets a pointer to its slot.

The lock is only held for that tiny reservation step. That's what makes one shared buffer workable across many CPUs.

### Step 3: Write the event in place
The program fills in its event directly in the slot. There's no intermediate copy. The verifier knows the slot is exactly N bytes and rejects any write past the end.

### Step 4: Commit or discard
When done, the program *commits*, which clears the busy mark and makes the record visible. Or it *discards*, which marks the record "skip me" (useful when it turns out the event wasn't interesting after all).

This is the key safety rule. The verifier checks that **every** path through the program commits or discards every slot it reserved. A slot left busy forever would block the reader at that point permanently, jamming the whole buffer.

### Step 5: Wake the reader, or don't
By default, committing wakes a reader that's sleeping. For very frequent events, waking on every commit is wasteful, so a program can commit *without* waking, and trigger the wakeup later after a batch. It can also force a wakeup regardless.

For small events there's also a one-shot "output" call that reserves, copies and commits in one go, like the old perf-buffer call. The reserve-and-commit approach is only worth it when avoiding the copy matters.

### Step 6: The reader walks records in its own memory
The reader looks at the producer position, walks records from its own position up to that point, skips discarded ones, hands each real one to a callback, and advances its consumer position. All of this happens in the reader's own memory, with **zero system calls** on the hot path.

Only when it catches up (nothing left to read) does it sleep, using epoll on the buffer's file descriptor, until a commit wakes it.

### Step 7: The reverse direction
Since 5.20 there's also a user ring buffer where the roles flip: one userspace program writes records and BPF programs drain them. It's used for feeding configuration, such as firewall rule updates, into a running BPF program without a system call per update.

## The picture

```text
 CPU 0 prog ─┐                                   reader (userspace)
 CPU 1 prog ─┼─▶ reserve (short lock) ─┐          reads its own mapping
 CPU 7 prog ─┘                         ▼          of the same pages
      ┌──────────────────────────────────────────────────────────┐
      │ [hdr|event] [hdr|event] [hdr|BUSY...] [free space ...]   │
      └──────────────────────────────────────────────────────────┘
        ▲ consumer position            ▲ producer position
        │ (advanced by reader)         │ (advanced on reserve)

  write in place ─▶ commit (clear busy) ─▶ wake reader (optional/batched)
                  └ or discard (reader skips it)
```

## Tradeoffs

- **What it gives you:** one buffer instead of one per CPU (so `size` of memory instead of CPUs × `size`), one file descriptor to wait on, events in a single global order, and no copy on the read side.
- **What it costs / requires:** all writers share one reservation lock. On machines with many CPUs writing very frequent events, that lock can contend, and per-CPU perf buffers may still be the better choice. The reserve/commit protocol also adds work for the verifier.
- **Where it bites:** a slow reader. The buffer is finite, so if the reader falls behind, reservations fail and events are lost. Most modern tools (bpftrace, bcc on recent kernels) use the ring buffer by default anyway.

## How it got here

- **5.8 (2020):** ring buffer introduced with reserve, commit, discard, one-shot output and query.
- **5.20 (2022):** the user ring buffer for the userspace-to-BPF direction.
- **7.1 (2026):** documentation clarified what "don't wake" means when discarding.

## Related

- Technical version: [[bpf-ring-buffer]]
- [[bpf-explained|BPF overview]]
- [[bpf-maps-explained|BPF maps]]: the ring buffer is one kind of map
- [[bpf-verifier-explained|The verifier]]: enforces commit-or-discard on every path
- [[tracing-explained|Tracing]]: the main producer of ring-buffer events
