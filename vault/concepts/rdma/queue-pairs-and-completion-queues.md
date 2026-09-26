---
title: "Queue Pairs and Completion Queues"
category: concept
tags: [rdma, verbs, queue-pair, completion-queue, polling, kernel-bypass]
subsystem: rdma
kernel_version: "2.6.11 (CQ polling API: 4.5; shared CQ pool: 5.9; RDMA DIM: 5.4)"
researched: 2026-09-26
status: complete
sources:
  - https://github.com/torvalds/linux/blob/master/include/rdma/ib_verbs.h
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/cq.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/verbs.c
  - https://www.kernel.org/doc/html/latest/infiniband/core_locking.html
  - https://github.com/linux-rdma/rdma-core
---

# Queue Pairs and Completion Queues

## Purpose

A **Queue Pair (QP)** is the RDMA equivalent of a socket: one endpoint of a transport, owned by the NIC, made of a **Send Queue (SQ)** and a **Receive Queue (RQ)**. A **Completion Queue (CQ)** is where the NIC reports that queued work has finished. Together they form an asynchronous, ring-based command interface between software and the adapter. Software never waits on an individual operation. It queues descriptors and later harvests completions, which lets one core drive millions of operations per second with no syscalls and, when polling, no interrupts.

## Mental Model

Picture a **restaurant kitchen with order tickets**. The SQ is the ticket rail: you clip *work requests* (WRs) onto it and ring the bell (the *doorbell*), and the kitchen (the NIC) takes tickets in order. The RQ is a stack of empty plates you leave out for deliveries you expect. An incoming SEND needs an empty plate, and if none is there the sender is told "not ready" (RNR). The CQ is the pass: whenever the kitchen finishes a ticket you asked to be told about, it puts a slip there. You either stand at the pass watching (polling) or ask for a buzzer the next time a slip appears (arming for an interrupt). The PD is the restaurant's membership card: a QP can only use memory keys issued under the same card.

It is the same shape as [[io_uring]]: submission ring, completion ring, user-owned tags to correlate the two. The difference is who reads the submission ring. In io_uring the kernel does (or SQPOLL does). In RDMA the NIC's firmware does, so the kernel isn't in the loop at all.

## How It Works

**Creating the objects.** A consumer first allocates a **Protection Domain** (`ib_alloc_pd()`), then one or more CQs, then the QP. `ib_create_qp()` (for userspace, the uverbs `QP_CREATE` method) takes a `struct ib_qp_init_attr` naming the `send_cq`, `recv_cq`, optional `srq`, queue depths (`max_send_wr`, `max_recv_wr`), scatter/gather limits (`max_send_sge`, `max_recv_sge`), `max_inline_data`, the `qp_type`, and `sq_sig_type` (whether every send generates a CQE or only flagged ones). Send and receive CQs may be the same object. The driver allocates the rings, in host memory for most NICs, and for userspace QPs returns their location so the provider library can mmap them.

**QP types (services).** The type fixes what the transport guarantees:
- **RC** — Reliable Connected. One QP talks to exactly one remote QP. Delivery is acknowledged, retransmitted, in order and exactly once. It supports every opcode: SEND, SEND-with-immediate, RDMA WRITE (with or without immediate), RDMA READ and atomics (compare-and-swap, fetch-and-add). It is the workhorse for storage and MPI.
- **UC** — Unreliable Connected: WRITE and SEND without acks, so lost packets drop the whole message.
- **UD** — Unreliable Datagram. One QP can reach many peers (each WR carries an Address Handle plus the remote QPN and Q_Key). SEND only, one MTU per message. Used for MADs, IPoIB, and scalable service discovery.
- **XRC** (eXtended RC) — shares receive resources across processes on a node, which cuts the N×M QP explosion of RC.
- **RAW_PACKET** — Ethernet frames straight to and from the NIC. This is what DPDK's mlx5 PMD uses underneath.
- **Driver types** (`IB_QPT_DRIVER`) — mlx5 DC (Dynamically Connected: RC semantics with on-demand connections), EFA SRD (Scalable Reliable Datagram: reliable, *unordered*, multipath).

**The state machine.** A new QP is in **RESET** and can do nothing. `ib_modify_qp(qp, attr, mask)` walks it forward. `ib_modify_qp_is_ok()` checks every transition against `qp_state_table[cur][next]`, which lists the required and optional attribute masks for each QP type.
1. **RESET → INIT** — set port, P_Key index and access flags (whether remote READ/WRITE/atomic is allowed into this QP). Receive buffers may be posted from here on.
2. **INIT → RTR** (Ready To Receive) — set the *remote* identity: `dest_qp_num`, path (`ah_attr`: remote LID or GID, SL/traffic class, source GID index), `path_mtu`, starting receive PSN, and responder resources (`max_dest_rd_atomic`). For RC, this is the step that needs out-of-band information from the peer, which the [[rdma-cm-connection-manager]] exchanges.
3. **RTR → RTS** (Ready To Send) — set send PSN, retry counts (`retry_cnt`, `rnr_retry`), ACK `timeout`, and outstanding READ/atomic depth (`max_rd_atomic`).
4. **→ ERR** — entered on a fatal transport error or on request. All outstanding WRs complete with `IB_WC_WR_FLUSH_ERR`. **SQD/SQE** are drain and error sub-states for the send queue.

**Posting work.** `ib_post_send(qp, wr, &bad_wr)` takes a linked list of `struct ib_send_wr`. Each carries an `opcode`, a scatter/gather list of `struct ib_sge {addr, length, lkey}` naming local registered memory, `send_flags` (`IB_SEND_SIGNALED` to request a CQE; `IB_SEND_INLINE` to copy small payloads into the WQE itself so the NIC needn't DMA them; `IB_SEND_FENCE`), and a correlation tag, either `wr_id` or a `struct ib_cqe *`. One-sided ops wrap it: `struct ib_rdma_wr` adds `remote_addr` and `rkey`, and `struct ib_atomic_wr` adds compare/swap operands. The driver converts each WR into a hardware **WQE** in the SQ ring, then writes the new producer index to the **doorbell**, a register in an MMIO page. Optimizations include doorbell batching (one doorbell per WR list), "BlueFlame" or write-combining pushes of the whole WQE through MMIO to skip a DMA read, and doorbell records in host memory. On the receive side, `ib_post_recv()` posts `struct ib_recv_wr`s describing empty buffers, and each incoming SEND consumes exactly one, in order. A **Shared Receive Queue** (`ib_create_srq`) lets many QPs draw from one buffer pool, trading per-connection memory for a shared, low-watermark-driven refill (`IB_EVENT_SRQ_LIMIT_REACHED`).

**Selective signalling.** Generating a CQE for every send costs PCIe bandwidth and CPU. Applications typically signal only every Nth send. Completion of a signalled WR implies all earlier WRs on that SQ are done, so their slots can be reused. Unsignalled errors still generate CQEs.

**Completions.** The NIC writes a CQE for each finished signalled send, and for every receive, into the CQ ring. The CQE's ownership bit or phase toggles each lap, so software can tell new entries from stale ones without reading a register. Software reads them with `ib_poll_cq(cq, n, wc[])` (userspace: `ibv_poll_cq`, pure memory reads). Each becomes a `struct ib_wc` with `wr_id`/`wr_cqe`, `status` (`IB_WC_SUCCESS`, `IB_WC_RETRY_EXC_ERR`, `IB_WC_RNR_RETRY_EXC_ERR`, `IB_WC_REM_ACCESS_ERR`, `IB_WC_WR_FLUSH_ERR` ...), `opcode`, `byte_len`, `ex.imm_data`, `src_qp` and `slid` (UD). A non-success status moves the QP to ERR, and the rest of the queue flushes.

**Waiting instead of spinning.** `ib_req_notify_cq(cq, IB_CQ_NEXT_COMP | IB_CQ_REPORT_MISSED_EVENTS)` arms the CQ to raise an interrupt on its next CQE. `REPORT_MISSED_EVENTS` closes the classic race: it returns >0 if CQEs arrived between the last poll and arming, so the caller must poll again instead of sleeping forever. The pattern is: poll to empty → arm → poll again → sleep. Each CQ is bound to a **completion vector** (an MSI-X interrupt), and choosing `comp_vector` per CPU is how ULPs spread load.

**Kernel consumers: the CQ API (`cq.c`).** Rather than hand-rolling that pattern, kernel ULPs call `ib_alloc_cq(dev, private, nr_cqe, comp_vector, poll_ctx)` and put a `struct ib_cqe` (just a `done` callback, usually embedded in the request struct) in each WR. The core's `__ib_process_cq()` polls in batches of `IB_POLL_BATCH` (16) and calls `wc->wr_cqe->done(cq, wc)` for each CQE, stopping at the budget. `poll_ctx` selects where this runs:
- `IB_POLL_SOFTIRQ` — the interrupt schedules an **irq_poll** instance (NAPI-like, budget `IB_POLL_BUDGET_IRQ` = 256) that runs in softirq and re-arms when it drains. Lowest latency.
- `IB_POLL_WORKQUEUE` / `IB_POLL_UNBOUND_WORKQUEUE` — a work item on `ib_comp_wq` with budget 65536. The done callbacks may sleep-adjacent (take mutexes via deferral).
- `IB_POLL_DIRECT` — no interrupts. The caller calls `ib_process_cq_direct()` itself, e.g. while polling for a synchronous result.

With `ib_device.use_cq_dim`, **RDMA DIM** (Dynamic Interrupt Moderation, 5.4, from the netdev DIM library) adjusts CQ event coalescing from observed completion rates. The **shared CQ pool** (`ib_cq_pool_get(dev, nr_cqe, comp_vector_hint, poll_ctx)`, 5.9) gives ULPs such as NVMe-oF and iSER the least-used CQ on a vector, instead of one CQ per queue, which cuts interrupt vectors and memory.

**Teardown.** `ib_drain_qp()` moves the QP to ERR, posts a special marker WR on each queue with its own `ib_cqe`, and waits for the marker's flush completion. After that no more callbacks can arrive for the QP's WRs, so their buffers may be freed. This removed a whole class of use-after-free bugs in ULPs. Only then is `ib_destroy_qp()` safe.

**Userspace data path.** In userspace, none of the posting or polling above touches the kernel. The provider library (`libmlx5`'s `mlx5_post_send`, `mlx5_poll_cq`) writes WQEs into the mmapped SQ, fences, and stores to the doorbell. It polls by reading CQE ownership bits in the mmapped CQ. Completion channels (see [[verbs-api-and-uverbs]]) are the only kernel involvement, and only when the app chooses to sleep.

## Key Data Structures

**`struct ib_qp`** (`include/rdma/ib_verbs.h`)
- `pd`, `send_cq`, `recv_cq`, `srq` — wiring
- `qp_num`, `qp_type` — wire identity and service
- `rdma_mrs`, `sig_mrs`, `mrs_used` — MR pool used by `rdma_rw` for registration-based transfers
- `event_handler`, `qp_context` — async events (path migration, fatal error, last WQE reached)
- `av_sgid_attr` — source GID and netdev for RoCE paths

**`struct ib_cq`** (`include/rdma/ib_verbs.h`)
- `comp_handler`, `cq_context` — interrupt callback (the core supplies it for `ib_alloc_cq` users)
- `poll_ctx`, `iop`/`work`, `comp_wq` — the polling engine
- `wc` — batch buffer for `__ib_process_cq`
- `dim` — adaptive moderation
- `cqe`, `cqe_used`, `shared`, `pool_entry` — pool bookkeeping

**`struct ib_wc`** — one completion: `wr_id`/`wr_cqe`, `status`, `opcode`, `byte_len`, `qp`, `ex.imm_data`/`invalidate_rkey`, `src_qp`, `wc_flags`.

**`struct ib_cqe`** — `{ void (*done)(struct ib_cq *, struct ib_wc *); }` embedded in ULP request structures and recovered with `container_of`.

## Key Functions / Entry Points

- **`ib_create_qp()` / `ib_modify_qp()` / `ib_destroy_qp()`** (`verbs.c`) — lifecycle; transitions checked by `ib_modify_qp_is_ok()`
- **`ib_post_send()` / `ib_post_recv()` / `ib_post_srq_recv()`** — inline wrappers to `device->ops`; must not sleep
- **`ib_poll_cq()` / `ib_req_notify_cq()`** — raw CQ access
- **`ib_alloc_cq()` / `ib_free_cq()` / `ib_process_cq_direct()`** (`cq.c`) — managed polling for kernel ULPs
- **`ib_cq_pool_get()` / `ib_cq_pool_put()`** (`cq.c`) — shared CQs
- **`ib_drain_qp()` / `ib_drain_sq()` / `ib_drain_rq()`** (`verbs.c`) — safe quiesce before teardown

## Important Flags & Config Options

- WR opcodes: `IB_WR_SEND`, `IB_WR_SEND_WITH_IMM`, `IB_WR_SEND_WITH_INV`, `IB_WR_RDMA_WRITE`, `IB_WR_RDMA_WRITE_WITH_IMM`, `IB_WR_RDMA_READ`, `IB_WR_ATOMIC_CMP_AND_SWP`, `IB_WR_ATOMIC_FETCH_AND_ADD`, `IB_WR_REG_MR`, `IB_WR_LOCAL_INV`
- Send flags: `IB_SEND_SIGNALED`, `IB_SEND_INLINE`, `IB_SEND_FENCE`, `IB_SEND_SOLICITED`
- QP attributes that matter for tuning: `timeout` (4.096 µs × 2^timeout), `retry_cnt`, `rnr_retry` (7 = infinite), `min_rnr_timer`, `max_rd_atomic`, `path_mtu`
- `ib_device.use_cq_dim` / netlink `rdma dev set <dev> adaptive-moderation on`
- Userspace extended CQs (`ibv_create_cq_ex`) with hardware timestamps

## Interactions with Other Subsystems

- **↑ Userspace**: `ibv_create_qp`, `ibv_modify_qp`, `ibv_post_send`, `ibv_poll_cq`, `ibv_req_notify_cq`; higher-level libraries (UCX, libfabric) hide QPs behind endpoints
- **→ Memory registration**: every SGE names an `lkey` from [[memory-registration-and-ib-umem]]; every one-sided op names a remote `rkey`
- **→ IRQ / softirq**: `irq_poll` (the block layer's NAPI-style library) for `IB_POLL_SOFTIRQ` CQs
- **← Connection manager**: [[rdma-cm-connection-manager]] performs the INIT→RTR→RTS transitions and exchanges QPNs and PSNs
- **← ULPs**: NVMe-oF, NFS/RDMA, iSER, SMC-R, RTRS all build on `ib_alloc_cq`/`ib_cqe`/`ib_drain_qp`

## Design Decisions & Tradeoffs

- **Hardware-owned transport state.** RC keeps sequence numbers, retransmission and acks in the NIC. This is excellent for CPU efficiency, but QP state is a scarce on-NIC cache resource. Tens of thousands of RC QPs thrash the NIC's context cache, which motivated XRC, DC, SRD and SRQ.
- **Receiver-posted buffers for two-sided ops.** SEND/RECV requires the receiver to pre-post buffers, and if it runs dry you get RNR NAKs and retry delays. One-sided WRITE/READ avoid that but require rkey exchange and some separate signal that data has landed (WRITE-with-immediate, or polling a flag).
- **Callback-per-WR (`ib_cqe`) over `wr_id` switch statements.** The 4.5 CQ API (Christoph Hellwig) standardized kernel polling and moved interrupt/polling policy out of each ULP, at the cost of an indirect call per completion.
- **Drain via marker WRs.** This gives a deterministic "no more completions" point without driver-specific quiesce hooks.
- **Compared with io_uring**: io_uring completions are generated by kernel code and can carry rich results (bytes transferred, buffer IDs, multishot flags), and ordering is per-request unless linked. RDMA RC completions are strictly ordered per QP, generated by hardware, with fixed CQE semantics. io_uring can cover *any* syscall. RDMA covers only memory-to-memory transfers, but costs zero CPU on the remote side.

## How It Has Evolved

- **2.6.11** — `ib_create_qp`, `ib_post_send`, `ib_poll_cq` from the InfiniBand spec
- **4.5 (2016)** — new CQ API (`ib_alloc_cq`, `ib_cqe`, softirq/workqueue/direct polling) and `ib_drain_qp`
- **5.4** — RDMA DIM adaptive interrupt moderation
- **5.9** — shared CQ pool
- **userspace** — extended verbs (`ibv_wr_*` builder API, `ibv_cq_ex`) cut per-WR overhead; vendor DC/SRD types
- **6.x (2026)** — completion counters (`comp_cntrs` on `ib_qp`) that count completions without writing CQEs, for very high-rate one-sided traffic

## Further Reading

- kernel.org — [InfiniBand Midlayer Locking](https://www.kernel.org/doc/html/latest/infiniband/core_locking.html) (which verbs may sleep; CQ handler context)
- rdma-core man pages — `ibv_create_qp(3)`, `ibv_modify_qp(3)`, `ibv_post_send(3)`, `ibv_poll_cq(3)`, `ibv_req_notify_cq(3)`
- Source — `drivers/infiniband/core/cq.c` (polling engine), `verbs.c` (`qp_state_table`)
- Related: [[rdma]], [[verbs-api-and-uverbs]], [[io_uring]], [[network-device-and-napi]]

## LKML Highlights

- **"IB: add a proper completion queue abstraction" (Christoph Hellwig, 2015–16, 4.5)** — replaced per-ULP poll loops with `ib_alloc_cq` plus `ib_cqe` callbacks and three polling contexts. It is the basis of every modern kernel RDMA ULP. (Lore was unreachable this session; see `git log drivers/infiniband/core/cq.c`.)
- **"RDMA/core: Introduce shared CQ pool API" (Yamin Friedman, 2020, 5.9)** — motivated by NVMe-oF and iSER creating one CQ per queue per controller. Pooling per completion vector cut interrupt and CQ counts.
- **RDMA DIM (Yamin Friedman / Tal Gilboa, 2019, 5.4)** — brought netdev's DIM library to CQs; enabled per device with `use_cq_dim`.
