---
title: "Queue Pairs and Completion Queues — Explained"
category: explained
original: "[[queue-pairs-and-completion-queues]]"
subsystem: rdma
tags: [explained, rdma, queue-pair, completion-queue, verbs]
converted: 2026-09-26
---

# Queue pairs and completion queues, explained

> Plain-language companion to [[queue-pairs-and-completion-queues|the technical note]]. Same facts, fewer identifiers.

## The problem

Software needs a way to tell an RDMA card "do this transfer" millions of times per second, from one core, without system calls and ideally without interrupts, and to find out later which transfers finished and whether they succeeded. Waiting on each operation individually would waste the hardware's speed.

## The idea in one paragraph

A **queue pair** is RDMA's version of a socket: one endpoint of a transport, owned by the card, made of a **send queue** and a **receive queue**. A **completion queue** is where the card reports finished work. Picture a **restaurant kitchen**: the send queue is the ticket rail where you clip orders and ring the bell (the **doorbell**); the receive queue is a stack of empty plates left out for deliveries you expect; the completion queue is the pass, where the kitchen leaves a slip for each ticket you asked about. You either stand at the pass watching (polling) or ask for a buzzer next time (an interrupt). A **protection domain** is the membership card: a queue can only use memory keys issued under the same card. It's the same shape as io_uring, except the card, not the kernel, reads the submission ring.

## Step by step

### Step 1: Create the objects
A consumer allocates a protection domain, one or more completion queues, then the queue pair, naming its send and receive completion queues (possibly the same one), an optional shared receive queue, queue depths, scatter-gather limits, how much data can be carried inline, its service type, and whether every send produces a completion or only flagged ones. The driver allocates the rings, usually in host memory, and for user processes returns their location so the library can map them.

### Step 2: Choose a service
- **Reliable connected:** one queue pair talks to exactly one remote queue pair; delivery is acknowledged, retransmitted, in order and exactly once; supports sends, one-sided writes and reads, and atomics. The workhorse for storage and MPI.
- **Unreliable connected:** writes and sends without acknowledgements; a lost packet drops the whole message.
- **Unreliable datagram:** one queue pair reaches many peers, each request naming its destination; sends only, one MTU each. Used for management traffic, IPoIB and discovery.
- **Extended reliable connected:** shares receive resources across processes, cutting the connection explosion of plain reliable connected.
- **Raw packet:** Ethernet frames straight to and from the card (what DPDK's mlx5 driver uses).
- **Vendor types:** mlx5's Dynamically Connected (reliable, connections on demand) and AWS EFA's Scalable Reliable Datagram (reliable, unordered, multipath).

### Step 3: Walk the state machine
A new queue pair can do nothing. Each step is checked against a table of required and optional settings:
1. **init:** port, partition and which remote operations are allowed into it; receive buffers can now be posted.
2. **ready to receive:** the *remote* identity: peer queue number, path, MTU, starting sequence number, how many incoming reads/atomics to allow. This is the step needing out-of-band information from the peer, which the connection manager exchanges.
3. **ready to send:** send sequence number, retry counts, acknowledgement timeout, how many reads/atomics may be outstanding.
4. **error:** after a fatal transport error or on request; everything outstanding completes with a "flushed" status.

### Step 4: Post work and ring the doorbell
This is the key step. A work request has an operation, a list of memory pieces (address, length, local key), flags (produce a completion; carry small data *inline* in the request so the card needn't fetch it; fence) and a tag to match its completion. One-sided operations add the remote address and remote key; atomics add their operands. The driver turns each request into a hardware entry in the ring and writes the new position to the **doorbell** register. Tricks cut costs further: one doorbell per batch, pushing a whole entry straight through the register to save the card a DMA read, and doorbell records in memory. Receive buffers are posted similarly, and each incoming send consumes exactly one, in order; a **shared receive queue** lets many queue pairs draw from one pool, refilled when a low-water mark is hit.

### Step 5: Signal selectively
A completion for every send costs PCIe bandwidth and CPU, so applications usually ask for one every N sends. A finished signalled request implies all earlier ones on that send queue are done too, so their slots can be reused. Errors still always produce completions.

### Step 6: Harvest completions
The card writes a completion entry for each signalled send and every receive. An ownership bit that flips each lap lets software spot new entries without reading a register. Each entry reports the tag, status (success, retries exceeded, "receiver not ready" retries exceeded, remote access error, flushed…), operation, byte count, immediate data and, for datagrams, the sender. A failure moves the queue pair to error and flushes the rest.

### Step 7: Wait instead of spin
Software can arm the completion queue for an interrupt on the next entry. Arming can report that entries arrived between the last poll and arming, closing a classic race: poll until empty, arm, poll again, then sleep. Each completion queue is tied to one interrupt vector, and choosing vectors per CPU spreads load.

### Step 8: How kernel users do it
Instead of hand-rolling that loop, kernel users attach a small **completion callback** to each request and let the core poll in batches of 16 and call the callbacks. They choose where: **softirq** (NAPI-like, lowest latency), **workqueue**, or **direct** (the caller polls, no interrupts). Adaptive interrupt moderation (5.4) tunes coalescing from observed rates, and a **shared completion-queue pool** (5.9) gives users such as NVMe-oF and iSER the least-used queue on a vector, cutting interrupt vectors and memory.

### Step 9: Drain before teardown
Before freeing buffers, a kernel user **drains** the queue pair: move it to error, post a special marker request on each queue and wait for the marker's flush. After that no more callbacks can arrive, so buffers can be freed. This removed a whole class of use-after-free bugs.

### Step 10: In user space, no kernel at all
User-space posting and polling never touch the kernel: the library writes entries into the mapped ring, fences, stores to the doorbell, and polls by reading ownership bits. The kernel is only involved if the application chooses to sleep.

## The picture

```text
 app ─▶ send queue ring: [WRITE {lkey buf, rkey remote}] [SEND] … ─▶ doorbell register
                                            │ card fetches, transmits, retries, acks
 card ─▶ completion queue ring: {tag, SUCCESS, bytes}  (ownership bit flips each lap)
 app: poll → empty → arm interrupt → poll again → sleep
 receive queue: [empty buf][empty buf]… incoming SEND consumes one (none left → "not ready")
 states: reset → init → ready-to-receive (peer info) → ready-to-send;  error → flush all
```

## Tradeoffs

- **What it gives you:** millions of operations per second per core, no system calls, optional zero interrupts, and zero CPU on the remote side for one-sided operations.
- **What it costs / requires:** reliable-connection state lives in the card as a scarce cache; tens of thousands of connections thrash it, which motivated extended, dynamic and datagram-based alternatives and shared receive queues. Two-sided sends need pre-posted receive buffers, or senders get "not ready" delays; one-sided writes avoid that but need key exchange and a separate "data landed" signal (write-with-immediate, or polling a flag).
- **Where it bites:** compared with io_uring, completions here are fixed-format and strictly ordered per queue pair, generated by hardware, and cover only memory-to-memory transfers, whereas io_uring can cover any system call with richer results. The per-request callback API adds an indirect call per completion.

## How it got here

- **2.6.11:** create, post and poll from the InfiniBand specification.
- **4.5 (2016):** the completion callback API with three polling contexts, and draining (Christoph Hellwig).
- **5.4:** adaptive interrupt moderation. **5.9:** shared completion-queue pool (Yamin Friedman).
- **User space:** extended verbs and builder APIs cut per-request overhead; vendor connection types.
- **2026:** completion counters that count finished work without writing completion entries, for very high-rate one-sided traffic.

## Related

- Technical version: [[queue-pairs-and-completion-queues]]
- [[rdma-explained|RDMA subsystem]], [[verbs-api-and-uverbs-explained|Verbs and uverbs]], [[memory-registration-and-ib-umem-explained|Memory registration]], [[rdma-cm-connection-manager-explained|Connection manager]]
- [[io_uring-explained|io_uring]], [[network-device-and-napi-explained|NAPI]]
