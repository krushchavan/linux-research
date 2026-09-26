---
title: "RDMA Subsystem — Explained"
category: explained
original: "[[rdma]]"
subsystem: rdma
tags: [explained, rdma, infiniband, roce, kernel-bypass]
converted: 2026-09-26
---

# The RDMA subsystem, explained

> Plain-language companion to [[rdma|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

With ordinary sockets, the kernel carries every byte: data is copied into a kernel buffer, protocol headers are built in software, and the CPU handles interrupts for each batch. For storage fabrics, HPC and AI clusters moving huge volumes at microsecond latencies, that per-byte and per-packet CPU work is the bottleneck. **Remote Direct Memory Access (RDMA)** network cards run the transport protocol in hardware and move data directly between registered memory on two hosts, with no kernel work per operation and no copies. They can even write into a remote machine's memory without that machine's CPU noticing.

That raises hard questions for the kernel: if it isn't in the data path, how does it keep processes from reading each other's memory, keep memory from moving while the card uses it, set up connections, and clean up when a process dies or a card is unplugged?

## The big picture

**The kernel is a notary, not a courier.** It never carries the data; it only certifies agreements up front: "this region of process memory is pinned at these addresses and may be accessed with key 0x1234", "this queue pair belongs to this process and may talk to that remote queue pair". After that, the application and the card talk directly. The application writes a **work request** into a queue in its own memory and rings a **doorbell**, a page of card registers mapped into its address space. The card reads the request, moves the data, and writes a **completion** into another queue that the application polls.

So there are two halves. The **control path** (discover devices, protect memory, set up connections, clean up) goes through the kernel and may sleep, allocate and validate heavily. The **data path** (post work, poll completions) never enters the kernel. io_uring also uses shared submission and completion rings, but there the kernel still carries out every operation; with RDMA it carries out none.

One API covers three wire transports: native **InfiniBand**, **RoCE** (RDMA over Converged Ethernet) and **iWARP** (RDMA over TCP), plus two software providers that run RDMA over any Ethernet card.

```text
 user space:  application ─ libibverbs + vendor lib        librdmacm
                   │ control (ioctl)          ╲ data path: write work request,
                   ▼                            ╲ ring doorbell, poll completions
 kernel:      uverbs ─ core (device/client registry) ─ memory pinning / paging
              connection manager ─ IB CM / iWARP CM ─ management datagrams
              RoCE address table, rw helper, netlink/resource tracking, cgroup
              kernel users: NVMe-oF, NFS/RDMA, IPoIB, SMC-R, iSER, SRP
                   │
 hardware:    RDMA NICs (mlx5, bnxt_re, irdma, efa, ionic…) or software rxe/siw
```

## The pieces

### Devices and clients
Hardware drivers ("providers") and consumers ("clients": user-space access, IPoIB, the connection managers, NVMe-oF) come and go independently. The core is a registry: a provider allocates its device with the core structure embedded, fills in a table of roughly 200 optional operations (the core checks which exist to learn capabilities), and registers. The core names it (e.g. `mlx5_0`), sets up sysfs and per-port caches, then tells every client about it. Unregistering reverses this, waits for users to let go, and for user processes **disassociates** them: their file descriptors stay valid, but their hardware objects are gone and every further call fails. Devices can also be network-namespace aware. See [[ib-device-and-client-model-explained|device and client model]].

### Verbs and user-space access
"Verbs" is the InfiniBand specification's abstract API: create a protection domain, register memory, post a send. The user-access module exposes it through `/dev/infiniband/uverbsN`, validating every request, translating user handles to kernel objects and cleaning up when a process dies. The original interface passed fixed-layout command structs via `write()`, which allowed credential confusion (a privileged process could be tricked into writing a command) and was hard to extend. The **ioctl interface** (4.14–4.20, Matan Barak and Jason Gunthorpe) sends typed attribute lists, and each method declares its attributes so a generic parser validates everything before the handler runs. Drivers can add their own methods (mlx5's DevX exposes nearly the raw device command interface). All user objects are torn down in a declared dependency order, including on process death or device removal. See [[verbs-api-and-uverbs-explained|verbs and uverbs]].

### Queue pairs and completion queues
The data-path objects. A **queue pair** is one endpoint of a hardware connection, with a send queue and a receive queue; a **completion queue** is where the card reports finished work. A **protection domain** scopes which queues may use which memory keys. Queue pairs come in service types: reliable connected (ordered, acknowledged, supports one-sided reads, writes and atomics), unreliable connected, unreliable datagram (like UDP), extended reliable connected, and vendor types. A new queue pair steps through states: reset, init, ready to receive (needs the peer's queue number and path), ready to send. Each work request lists memory pieces as address, length and local key, plus, for one-sided operations, the remote address and remote key. Kernel users get completions through callbacks on a chosen context (softirq, workqueue, or direct polling), with adaptive interrupt moderation; a **shared completion-queue pool** (5.9) spreads many kernel queues over per-CPU completion queues, and shared receive queues let many queue pairs draw from one buffer pool. See [[queue-pairs-and-completion-queues-explained|queue pairs and completion queues]].

### Memory registration
The card must translate application addresses to DMA addresses by itself, at line rate, possibly on behalf of a remote peer. **Registration** builds that translation and returns a **local key** and a **remote key** to hand to peers. The kernel checks the locked-memory limit, **pins** the pages long-term (first moving them out of movable memory zones), DMA-maps them, and lets the driver pick the largest page size its translation table supports (huge pages mean far fewer entries). Pinning is the root of RDMA's longest-running conflicts with memory management: pinned pages defeat reclaim, migration, compaction and DAX truncation, which is what drove the creation of the kernel's long-term pinning API. The alternatives are on-demand paging and **dma-buf** registration (5.12), which registers GPU or accelerator memory that has no ordinary page structures. Kernel users skip this and register memory with fast-registration work requests from pools. See [[memory-registration-and-ib-umem-explained|memory registration]].

### On-demand paging
**ODP** registers memory *without pinning it*. The kernel watches the range with an mmu notifier. When the card hits a page it has no translation for, it raises a **network page fault**; the driver faults the page in, maps it and updates the card, while the remote side's packet is stalled or retried. When memory management wants to move or reclaim a page, the notifier makes the driver remove the card's mapping first. **Implicit ODP** registers the whole address space and builds pieces lazily. The same machinery handles dma-buf exporters that move memory. See [[on-demand-paging-odp-explained|on-demand paging]].

### The connection manager
Bringing up a reliable connection needs the peer's queue number, path details and starting sequence numbers, which is error-prone to do by hand. The **RDMA connection manager** offers a sockets-like API keyed by **IP address and port**: resolve address, resolve route, connect, listen, accept. It maps the IP address to a local device through the routing table (plus neighbour lookup on Ethernet, or the subnet administrator on InfiniBand), then hands off to a transport-specific handshake: request/reply/ready messages for InfiniBand and RoCE, or iWARP's handshake over a real TCP connection. It moves the queue pair through its states for you and reports events. Nearly every kernel user relies on it. See [[rdma-cm-connection-manager-explained|connection manager]].

### Management datagrams
An InfiniBand fabric is managed in-band by **management datagrams** on two special queue pairs (one for subnet management, one for general services). The kernel multiplexes them among many agents (the connection manager, subnet-administration queries for paths and multicast, user-space subnet managers such as OpenSM, diagnostics), with timeouts, retries and segmentation for large payloads. On RoCE there's no subnet manager, but connection messages still travel this way, encapsulated in UDP or Ethernet. See [[mad-and-subnet-administration-explained|management datagrams]].

### RoCE address table
On Ethernet, an RDMA address (a **GID**) is derived from the interface's IP and MAC addresses and VLAN. The table must follow every IP change, bond failover and VLAN creation, or connections go out from stale addresses. Network notifiers add entries for each RoCE version (v1 raw Ethernet, v2 UDP/IP), each tied to its network device, so the connection manager picks the right VLAN, namespace and bond member. Hardware bonding can present two ports as one RDMA device. See [[roce-gid-table-and-netdev-binding-explained|RoCE GID table]].

### The rw helper
Storage targets (NVMe-oF, iSER, SRP, the NFS server) all do the same thing: take a host's remote address, key and length, map or register local pages, and issue RDMA reads or writes within the device's limits, remembering that iWARP needs registered memory for read targets. The **rw helper** does this once: it picks a strategy (one piece, several chained pieces, a contiguous IO-virtual mapping, or memory registration), posts the chain with one completion at the end, and cleans up. See [[rdma-rw-api-explained|rw API]].

### Visibility and limits
RDMA resources are scarce hardware objects that normal tools can't see. **Resource tracking** (4.17) records every domain, queue, memory region and connection with its owning task; a netlink family exposes them, plus statistics and link creation, to the `rdma` tool from iproute2. Per-queue and per-port hardware counters can bind automatically by type or process. The **rdma cgroup** controller (4.11, Parav Pandit) limits user contexts and verbs objects per device per cgroup. See [[rdma-netlink-restrack-and-cgroup-explained|netlink, restrack and cgroup]].

### Software RDMA
**rxe** (Soft-RoCE, 4.8) and **siw** (soft-iWARP, 5.3) implement a device in software over any Ethernet card: rxe wraps InfiniBand transport in UDP port 4791 with software checksums; siw runs iWARP's layers over a kernel TCP socket. The data path still uses shared memory, but ringing the doorbell becomes a system call. They're for development, CI and interoperability, not speed. See [[soft-rdma-rxe-and-siw-explained|rxe and siw]].

## A request's journey

A user application sets up a reliable connection with librdmacm and does one RDMA write:

1. **Resolve.** It creates a connection ID and resolves the peer's IP address; the kernel picks the local device and source GID via routing and the address table.
2. **Allocate.** It creates a protection domain and a completion queue.
3. **Register.** It registers a buffer: the kernel charges the locked-memory limit, pins the pages long-term, DMA-maps them, and the driver programs the card's translation table and returns local and remote keys.
4. **Connect.** It creates a queue pair and connects; the connection manager exchanges handshake messages and moves the queue pair to ready-to-send.
5. **Write, with no kernel.** This is the key moment: the application writes a work request (RDMA write, local key, remote address and remote key) into its queue and rings the doorbell by writing to a mapped register. The card reads from local memory and transmits; the remote card writes straight into the remote registered buffer.
6. **Complete.** The card writes a completion entry, which the application polls.

The kernel handled addressing, pinning, the handshake and state changes, and none of the write itself. The remote host's CPU and kernel never saw the write either; only the remote application, if it checks the buffer, knows data arrived.

## Tradeoffs

- **What it gives you:** no system calls, copies or (optionally) interrupts on the data path; one-sided access to remote memory; one API over InfiniBand, RoCE and iWARP; clean handling of process death and hot-unplug.
- **What it costs / requires:** after setup the kernel can't see, schedule, account or filter traffic: no netfilter, no queueing disciplines, no per-packet cgroup control. Security rests entirely on memory keys and protection domains enforced by hardware. Pinning conflicts with reclaim, migration, CMA and DAX; ODP avoids it but needs card support for page faults.
- **Where it bites:** transport differences leak through the common API (iWARP needs registered read targets and a TCP-based handshake; RoCE has no subnet manager). Hot-unplug by disassociation keeps servers safe but forces every user-access path to handle "device gone" at any moment.

## How it got here

- **2.6.11 (2005):** InfiniBand core, the first hardware driver, IPoIB and the write-based user interface (OpenIB/OFA stack).
- **2.6.x:** RDMA connection manager (2006) and iWARP support; the stack became "RDMA" in concept while keeping `infiniband` paths.
- **3.19 (2014):** on-demand paging for mlx5.
- **4.5–4.9:** RoCE v2 address types, the rw helper (4.7), rxe (4.8). **4.11:** rdma cgroup.
- **4.14–4.20:** the ioctl interface, with all write-based commands routed through it; DevX. **4.16–4.17:** netlink and resource tracking; the `rdma` tool.
- **5.3:** siw. **5.9:** shared completion-queue pool. **5.12:** dma-buf registration (Jianxin Xiong), dynamic first, pinned later for cards without ODP.
- **6.x:** ODP for rxe; new providers (mana, ionic, erdma); the DMA IOVA API in the rw helper.
- **2026:** RDMA devices can **export** dma-bufs (Edward Srouji), revocable pinned imports, one buffer descriptor that accepts either a virtual address or a dma-buf, and completion counters as an alternative to completion entries.

## Related

- Technical version: [[rdma]]
- [[ib-device-and-client-model-explained|Device and client model]], [[verbs-api-and-uverbs-explained|Verbs and uverbs]], [[queue-pairs-and-completion-queues-explained|Queue pairs and CQs]], [[memory-registration-and-ib-umem-explained|Memory registration]], [[on-demand-paging-odp-explained|On-demand paging]], [[rdma-cm-connection-manager-explained|Connection manager]], [[mad-and-subnet-administration-explained|Management datagrams]], [[roce-gid-table-and-netdev-binding-explained|RoCE GID table]], [[rdma-rw-api-explained|rw API]], [[rdma-netlink-restrack-and-cgroup-explained|Netlink, restrack and cgroup]], [[soft-rdma-rxe-and-siw-explained|rxe and siw]]
- [[io_uring-explained|io_uring]], [[get-user-pages-and-pinning-explained|Page pinning]], [[devmem-tcp-explained|devmem TCP]], [[af-xdp-explained|AF_XDP]]
