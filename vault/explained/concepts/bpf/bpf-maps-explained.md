---
title: "BPF Maps — Explained"
category: explained
original: "[[bpf-maps]]"
subsystem: bpf
tags: [explained, bpf, maps, data-structures]
converted: 2026-09-25
---

# BPF maps, explained

> Plain-language companion to [[bpf-maps|the technical note]]. Same facts, fewer identifiers.

## The problem

A BPF program runs inside the kernel, often while handling an interrupt or a network packet. It can't block, can't make system calls, and is gone the moment it returns. Yet almost every useful program needs memory that lasts: a packet counter, a table of blocked addresses, a list of open connections, a queue of events for a monitoring tool.

That state also has to be shared across a boundary. Userspace needs to configure the program (add an address to the block list) and read its results (how many packets were dropped). Other BPF programs may need to see it too. And whatever the mechanism, the verifier must still be able to prove the program never reads outside the memory it was given.

## The idea in one paragraph

A **map** is a typed data store that the kernel owns and both sides can reach. You declare its kind (array, hash table, ring buffer…), its key size, value size and maximum number of entries, and the kernel allocates it. A BPF program looks things up through a kernel helper and gets a pointer *straight into* the stored value, so there's no copy. Userspace reaches the same map through the bpf() system call, which copies data in and out. The verifier knows exactly how big each value is and checks every access against that size.

## Step by step

### Step 1: Create the map
Userspace asks the kernel for a map of a given kind and shape. For arrays and (by default) hash tables, the kernel allocates all the memory up front. It returns a file descriptor as a handle.

### Step 2: Keep it alive while anyone needs it
A map is reference-counted. It stays alive while there's an open handle to it, a loaded program that uses it, or a *pin*: a name in a special BPF filesystem that lets it outlive the process that created it. When the last reference goes, the map is freed.

### Step 3: A program looks something up
When the program is loaded, its reference to the map is turned into a direct pointer to the map object. At run time, a lookup goes through the map kind's own lookup routine and returns a pointer into the value memory, or "not found".

This is the key step. The verifier treats that result as "pointer to a map value of exactly N bytes, *or nothing*". The program must check for nothing before using it, and every read or write through it is checked against N. That's how a shared data structure stays safe without any runtime bounds checks.

### Step 4: Userspace reads and writes through system calls
From userspace, a lookup copies the key into the kernel, runs the same lookup routine, and copies the value back out. This copying is the price of the control path. The fast path, inside the BPF program, is copy-free.

### Step 5: Handle concurrency
Many CPUs may run the same program at once, touching the same map.
- Hash tables lock individual buckets for updates and use RCU (a lock-free read scheme) for lookups.
- Arrays can update 64-bit values atomically. For wider values that must change together, you embed a small spinlock in the value; the verifier refuses programs that touch a lock-protected value without holding its lock.
- **Per-CPU** variants give each CPU its own copy of every value, so no locking is needed at all. Userspace then adds up the per-CPU copies itself.

### Step 6: When memory runs out
If a hash table was created without preallocating memory, entries are allocated on insert. Inside interrupt context the kernel can't wait for memory, so an insert can fail. Programs must handle a failed update, as well as a "not found" lookup.

## The main kinds of map

- **Array:** a fixed block of slots indexed by number. Fastest, preallocated, zero-filled, never shrinks. Good for counters, histograms and configuration.
- **Hash table:** arbitrary keys. The **LRU** variant automatically evicts the least-recently-used entries so it never fills up, which is ideal for connection tracking.
- **Longest-prefix-match trie:** finds the most specific network prefix that matches an address. Used for routing tables and firewall allow-lists.
- **Program array:** holds other BPF programs. A *tail call* jumps into one of them, replacing the current program. This lets you chain stages together, such as a multi-step protocol parser too large to verify as one program (the limit is about a million instructions).
- **Ring buffer:** one shared circular buffer that userspace maps into its own memory, for streaming events out with no copy. See [[bpf-ring-buffer|the ring buffer]].
- **Socket maps:** hold sockets, so a program can forward data straight from one socket to another inside the kernel, for proxies and load balancers.
- **Maps of maps:** the outer map holds inner maps, so you can swap an entire table atomically by replacing one entry.
- **Queues and stacks** with push and pop.

## The picture

```text
          userspace                         kernel
   ┌──────────────────┐             ┌──────────────────────────┐
   │ control program  │  bpf() call │          MAP             │
   │  add/remove keys │ ── copy ──▶ │  kind, key size,         │
   │  read counters   │ ◀── copy ── │  value size, max entries │
   └──────────────────┘             │  ┌─────┬─────┬─────┐     │
   ┌──────────────────┐   mmap      │  │ val │ val │ val │     │
   │ event reader     │ ◀─shared──  │  └──▲──┴─────┴─────┘     │
   └──────────────────┘   pages     └─────┼────────────────────┘
      (ring buffer,                       │ pointer, no copy
       mmapable arrays)             ┌─────┴──────────────┐
                                    │  BPF program       │
                                    │  lookup → ptr|none │
                                    │  verifier checks   │
                                    │  every access      │
                                    └────────────────────┘
```

## Tradeoffs

- **What it gives you:** one uniform, verifier-checked way to keep state and talk to userspace, with copy-free access from the program side.
- **What it costs / requires:** you declare sizes up front. Per-CPU maps multiply memory by the number of CPUs and push aggregation onto userspace, though most production monitoring tools use them for high-frequency counters anyway. Lock-protected values serialize updates.
- **Where it bites:** forgetting that lookups can fail and inserts can run out of memory. The verifier forces the "not found" check, but an insert failure under memory pressure is a real runtime event programs must tolerate.

## How it got here

- **3.18 (2014):** the first maps: hash, array and program array.
- **4.6–4.8 (2016):** per-CPU maps, stack-trace maps, and LRU hash tables for connection tracking.
- **4.11–4.15 (2017–2018):** maps of maps, device maps, socket maps and per-cgroup storage.
- **5.1 (2019):** queues and stacks.
- **5.8 (2020):** the ring buffer, replacing one-buffer-per-CPU perf buffers with one shared buffer; later a userspace-to-BPF direction too.
- **6.x:** values can hold pointers to kernel objects, with the verifier tracking ownership.

## Related

- Technical version: [[bpf-maps]]
- [[bpf-explained|BPF overview]]
- [[bpf-ring-buffer|BPF ring buffer]]: the streaming map in detail
- [[bpf-verifier|The verifier]]: checks every map access
- [[bpf-helpers-and-kfuncs-explained|Helpers and kfuncs]]: how programs call lookup and update
- [[btf-and-co-re|BTF]]: type info that lets tools pretty-print map contents
