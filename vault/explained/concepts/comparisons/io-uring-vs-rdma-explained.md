---
title: "io_uring vs RDMA: Completion Models, Memory Registration and Zero-Copy — Explained"
category: explained
original: "[[io-uring-vs-rdma]]"
subsystem: comparisons
tags: [explained, comparison, io_uring, rdma, zero-copy]
converted: 2026-09-26
---

# io_uring vs RDMA, explained

> Plain-language companion to [[io-uring-vs-rdma|the technical note]]. Same facts, fewer identifiers.

## The problem

From user space, io_uring and RDMA verbs look strikingly alike. Both give the application a **submission queue** and a **completion queue** in shared memory, both let it **pre-register memory** to avoid pinning pages on every operation, and both promise **zero-copy** and **system-call-free** fast paths. Yet they solve different problems and put the work in different places. **io_uring is an asynchronous interface to the kernel**: the kernel still carries out every operation (TCP, filesystems, block I/O), and only the *interface overhead* disappears. **RDMA is an interface to a network card that runs a transport in hardware**: after setup, neither host's kernel is involved per operation, and neither is the remote CPU. Comparing them mechanism by mechanism makes the tradeoffs explicit.

## The idea in one paragraph

Both are **order windows**. io_uring's window opens into the **kernel's kitchen**: the chef (kernel code, sometimes a helper thread) cooks every order under all the house rules (permissions, page cache, TCP congestion control, firewalling), and the window only saves you queueing at the counter. RDMA's window opens into a **delivery robot's loading bay** (the card). The robot takes the order, drives across town and puts the goods straight into the recipient's pantry, without the recipient's staff (remote CPU) or either kitchen (kernels) touching it. But the robot only moves bytes between registered pantries: no cooking, no house rules after setup, and a menu of read, write, send and atomics.

## Step by step

### Step 1: Who reads the submission queue
An io_uring entry can describe *any* supported operation (read, write, send, receive, accept, open, device commands…). The **kernel** consumes it, either when the application makes one system call per batch or, with no system call at all, when a kernel polling thread watches the queue at the cost of burning that thread ([[sqpoll-explained|SQPOLL]]). The kernel runs the operation inline, through its async poll machinery, or on worker threads ([[io-wq-explained|io-wq]], [[io-uring-async-poll-and-multishot-explained|async poll and multishot]]). An RDMA entry, formatted for the card's driver, describes only send, receive, remote read or write, atomics or a memory registration. The **card** consumes it after user space writes to a doorbell register, with no system call on hardware (the software RDMA drivers do need one) ([[queue-pairs-and-completion-queues-explained|queue pairs and CQs]]). io_uring can express anything the kernel can do; RDMA can only move memory. That asymmetry drives everything that follows.

### Step 2: How completions work
- **Who writes them:** io_uring completions are posted by kernel code; RDMA completions are DMA'd by the card into the ring, with an ownership bit so software can spot new ones without reading registers.
- **What they say:** io_uring results are rich (bytes, a file descriptor, an error), with flags for "more coming", "which provided buffer was used", "zero-copy pages now free", and larger entries for zcrx offsets. RDMA completions have fixed, transport-defined fields.
- **One request, many results:** io_uring **multishot** requests (accept, receive, poll, zero-copy receive) stream completions from one submission. RDMA is at most one completion per request, so continuous receiving means posting many receive requests or a shared receive queue.
- **Skipping completions:** RDMA can leave sends unsignalled (a later signalled one implies the earlier ones finished); io_uring has a similar "skip on success" flag.
- **Order:** RDMA completions on one reliable connection are strictly ordered; io_uring's aren't unless requests are linked or drained.
- **Zero-copy sends:** io_uring gives a result, then a separate notification when the pages are free. RDMA gives one completion meaning "the remote side acknowledged", after which the buffer is free, and for a remote write, the data is already in place.
- **Waiting:** io_uring waits in its system call, via an eventfd, or by spinning on device queues. RDMA busy-polls the ring (pure memory reads) or arms it and sleeps on a file descriptor, the one point where the kernel re-enters the RDMA data path. Both support spin-then-sleep ([[polling-vs-interrupts-io-uring-napi-rdma-cq-explained|polling vs interrupts]]).
- **Overflow:** io_uring stashes completions internally if the ring is full, so none are lost. An RDMA completion-queue overflow is a fatal error, so the application must size queues for the worst case.

### Step 3: Registering memory
Both pin pages long-term with the same kernel primitive and charge them against the locked-memory limit. From there they diverge:
- **io_uring** builds a kernel-side table of pages identified by an **index that only means something inside that one ring**. No other machine can use it. Its purpose is to skip per-I/O pinning ([[registered-resources-explained|registered resources]]).
- **RDMA** DMA-maps the pages and programs them into the **card's own translation table**, producing a local key and a **remote key a peer can use**, so the peer's card reads and writes that memory with no local CPU. Its purpose is to give the card an independent, access-controlled address space ([[memory-registration-and-ib-umem-explained|memory registration]]). It also has an unpinned option, **on-demand paging**, where the card takes page faults and is told when mappings change ([[on-demand-paging-odp-explained|ODP]]).

For device memory, io_uring has zcrx areas (with transmit from dma-bufs planned) and RDMA has dma-buf-backed regions (5.12+). Both hit the same conflicts with page migration and contiguous-memory allocation. RDMA also has to pick huge-page-sized chunks carefully because card translation caches are small.

### Step 4: Zero-copy send
With io_uring's zero-copy send, kernel TCP attaches the user's pages to packets, the card DMAs from them, and a notification says when TCP no longer needs them (after acknowledgement). The **receiver** still runs a full TCP stack and, without zcrx, copies. With RDMA, the card DMAs straight from the registered region, segments and retransmits in hardware, and the remote card places the data. **A remote write needs no receiver CPU at all**; a send consumes a receive buffer the receiver posted earlier.

### Step 5: Zero-copy receive, the big difference
This is the key step. For io_uring zcrx, the card must split headers from payload and the application's flows must be **steered** to a dedicated receive queue whose buffers come from io_uring. Payloads land in the user's area, headers go through kernel TCP, and completions point at area and offset; wrong steering means a copy ([[header-split-and-flow-steering-for-zero-copy-rx-explained|header split and steering]], [[zero-copy-rx-zcrx-explained|zcrx]]). For RDMA, placement is **defined by the protocol**: a remote write carries its destination address and key, so the card knows where every byte goes, and a send lands in the next posted buffer. No header split, steering or dedicated queue, and no per-packet header work on the receiving CPU. TCP-based schemes must *infer* placement from which queue a flow hashes to; RDMA's wire protocol *states* it. That's why RDMA remains unmatched for remote-memory access.

### Step 6: Connecting, security and visibility
io_uring uses ordinary sockets and the kernel's TCP handshake. RDMA needs queue-pair creation, a state machine, an out-of-band exchange of queue numbers, sequence numbers and keys, and a connection manager ([[rdma-cm-connection-manager-explained|RDMA CM]]). Setup is far heavier (milliseconds, management messages, maybe directory lookups), so RDMA favours long-lived, pooled connections. Every io_uring operation passes the normal permission, security module, firewall, cgroup and accounting checks, although its own attack surface has led some distributions to restrict it. RDMA data movement bypasses all of those after setup: isolation rests on **hardware-checked protection domains and keys**, per-cgroup object limits and fabric partitioning. No firewall sees an RDMA write, and traffic accounting comes from card counters ([[rdma-netlink-restrack-and-cgroup-explained|RDMA netlink, restrack and cgroup]]).

### Step 7: Performance, roughly
- **Latency:** one-sided RDMA operations take about 1–3 µs end to end with no remote CPU; io_uring over kernel TCP is typically about 10–30 µs for a small-message round trip (less with busy polling), dominated by two kernel stacks.
- **CPU per byte:** about zero on both sides for RDMA. io_uring zero-copy receive and send remove copies but keep per-packet TCP/IP work (reported around 116 Gbit/s on one core for zcrx at 200G).
- **Generality:** io_uring speeds up storage, files, sockets and device passthrough. RDMA needs RDMA cards (or software emulation at a large CPU cost) and, for RoCE, a tuned fabric.
- **Skill matters:** a 2025–26 database study found that swapping in io_uring naively doesn't necessarily help; registered buffers, passthrough and architecture choices produced its 14% PostgreSQL gain. Naive verbs code (no batching, small regions, poor signalling) likewise loses much of RDMA's advantage.

### Step 8: Where they meet
An NVMe-oF RDMA namespace is an ordinary block device, so io_uring (including polled I/O and NVMe passthrough) drives it while RDMA does the network leg ([[nvme-over-fabrics-rdma-and-tcp-explained|NVMe over Fabrics]], [[uring-cmd-passthrough-explained|passthrough]]); a liburing issue documents polling-tuning problems at high queue depth there. Both share long-term pinning, dma-buf and P2PDMA. SMC-R gives unmodified socket applications, and therefore io_uring ones, an RDMA data path ([[smc-r-shared-memory-communications-explained|SMC-R]]). There's no mainline io_uring interface to verbs itself: verbs' data path is already system-call-free, so io_uring would have nothing to batch.

## The picture

```text
 io_uring:  app ─SQ─▶ KERNEL (TCP, VFS, block, checks) ─▶ device ─▶ ... remote KERNEL TCP ─▶ app
            completions written by kernel code; registration = private index in one ring
 RDMA:      app ─SQ + doorbell─▶ CARD ═══ fabric ═══▶ remote CARD ─▶ remote memory (by key)
            completions DMA'd by card; registration = keys a remote card can use
            no kernel, no remote CPU per operation
```

## Tradeoffs

- **What it gives you:** io_uring keeps the kernel's semantics, security and portability and strips interface overhead, with rich results and multishot streams. RDMA takes both kernels and the remote CPU out of the data path, with protocol-defined placement that makes zero-copy receive natural.
- **What it costs / requires:** RDMA needs special hardware, offers a narrow set of operations, and trusts card-enforced keys. Because it exports memory to a fabric, it needs keys, invalidation and ODP; io_uring's registration is private to one ring and needs none. io_uring's zero-copy receive needs header split, steering and a dedicated queue.
- **Where it bites:** choosing by the similar-looking rings is a mistake. io_uring suits general servers, storage engines, proxies and databases on commodity cards and lossy networks. RDMA suits tightly coupled clusters (HPC, AI collectives, disaggregated storage, key-value caches) where microsecond latency and zero remote CPU justify the fabric. Increasingly the two appear together: io_uring for local and TCP I/O, RDMA for the cluster fabric.

## How it got here

- **2005:** RDMA verbs arrive in Linux (2.6.11) with queue pairs, completion queues and memory regions, a decade before io_uring.
- **2019:** io_uring (5.1) brings the shared-ring model to general kernel I/O, with registered buffers from day one.
- **2019–2022:** io_uring gains unprivileged polling threads, polled I/O, multishot, provided buffers and zero-copy send (6.0), shrinking interface overhead toward RDMA-like levels.
- **2020–2021:** RDMA dma-buf regions (5.12); on-demand paging moved onto HMM.
- **2025:** io_uring zcrx (6.15) and dma-buf areas (6.16): zero-copy receive into user or GPU memory *through* kernel TCP, the closest io_uring has come to RDMA semantics.
- **2026:** RDMA dma-buf export and revocation; zcrx events, multiple areas and export; queue leasing brings zcrx into containers.

## Related

- Technical version: [[io-uring-vs-rdma]]
- [[io-uring-internals-explained|io_uring internals]], [[registered-resources-explained|Registered resources]], [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]], [[zero-copy-rx-zcrx-explained|zcrx]]
- [[rdma-explained|RDMA]], [[queue-pairs-and-completion-queues-explained|Queue pairs and CQs]], [[memory-registration-and-ib-umem-explained|Memory registration]], [[get-user-pages-and-pinning-explained|Page pinning]], [[dma-buf-sharing-explained|dma-buf]]
- [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk-explained|Kernel-bypass comparison]], [[devmem-tcp-vs-rdma-gpudirect-vs-io-uring-zcrx-explained|Devmem vs GPUDirect vs zcrx]]
