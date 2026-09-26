---
title: "io_uring vs RDMA: Completion Models, Memory Registration and Zero-Copy"
category: concept
tags: [io_uring, rdma, comparison, zero-copy, memory-registration, completion-queues]
subsystem: comparisons
kernel_version: "io_uring 5.1+; RDMA 2.6.11+; zcrx 6.15; dma-buf in both 5.12/6.16"
researched: 2026-09-26
status: complete
sources:
  - https://arxiv.org/abs/2512.04859
  - https://kernel-recipes.org/en/2024/schedule/efficient-zero-copy-networking-using-io_uring/
  - https://docs.kernel.org/networking/iou-zcrx.html
  - https://www.kernel.org/doc/html/latest/infiniband/user_verbs.html
  - https://www.kernel.org/doc/html/latest/infiniband/core_locking.html
  - https://blog.lbenicio.dev/blog/kernel-bypass-networking-dpdk-io_uring-and-the-rdma-revolution/
  - https://github.com/axboe/liburing/issues/1228
  - https://github.com/torvalds/linux/tree/master/io_uring
  - https://github.com/torvalds/linux/tree/master/drivers/infiniband/core
---

# io_uring vs RDMA: Completion Models, Memory Registration and Zero-Copy

> Comparison note. Filed under `comparisons/` (a new folder) because it spans the [[io_uring]] and [[rdma]] subsystems equally.

## Purpose

io_uring and RDMA verbs look strikingly similar from userspace. Both hand the application a **submission queue** and a **completion queue** in shared memory, both let you **pre-register memory** to skip per-operation pinning, and both advertise **zero-copy** and **syscall-free** fast paths. They solve different problems, though, and put the work in different places. **io_uring is an asynchronous interface to the kernel**: the kernel still executes every operation (TCP, filesystems, block I/O) and only the *interface overhead* is removed. **RDMA is an interface to a NIC that executes a transport in hardware**: after setup, the kernel isn't involved per operation at all, on either host, and the remote CPU isn't either. This note compares them mechanism by mechanism so the tradeoffs are explicit.

## Mental Model

Both are **order windows**. In io_uring, the window opens into the **kernel's kitchen**: the chef (kernel code, sometimes a helper thread) cooks every order with all the house rules applied (permissions, page cache, TCP congestion control, netfilter), and the window just saves you queueing at the counter. In RDMA, the window opens into a **delivery robot's loading bay** (the NIC). The robot takes the order, drives across town, and puts the goods straight into the recipient's pantry, without the recipient's staff (remote CPU) or either kitchen (kernels) touching it. The robot only knows how to move bytes between registered pantries, so there's no cooking, no house rules after setup, and no menu beyond read, write, send and atomics.

## How It Works

### 1. Who consumes the submission queue

| | io_uring | RDMA verbs |
|---|---|---|
| SQ entry | 64/128-byte SQE describing *any* supported operation (read, write, send, recv, accept, openat, uring_cmd …) | Driver-formatted WQE describing SEND, RECV, RDMA READ/WRITE, atomics, REG_MR |
| Consumer | Kernel: `io_uring_enter()` → `io_submit_sqes()`, or an SQPOLL kernel thread ([[sqpoll]]) | NIC firmware/hardware, after an MMIO **doorbell** write from userspace ([[queue-pairs-and-completion-queues]]) |
| Syscall on submit | One per batch, or none with SQPOLL (which burns a kernel thread) | None on hardware providers; software providers (rxe/siw) need one |
| Execution | Inline in the submitter's context, via async poll/task_work, or offloaded to io-wq threads ([[io-wq]], [[io-uring-async-poll-and-multishot]]) | Entirely in the NIC's transport engine |

io_uring can express anything the kernel can do, while RDMA can only move memory. That asymmetry drives most of what follows.

### 2. Completion models

- **Who writes the CQE.** io_uring CQEs are posted by kernel code (`io_req_complete_post`, task_work with `DEFER_TASKRUN`, IOPOLL reaping). RDMA CQEs are DMA'd by the NIC into the CQ ring, with an ownership/phase bit so software detects new entries without reading registers.
- **Contents.** io_uring CQE = `{user_data, res, flags}`, where `res` carries rich kernel results (bytes, fd, error), and flags carry `F_MORE` (multishot), `F_BUFFER` (selected provided buffer), `F_NOTIF` (zero-copy release), 32-byte extensions (zcrx offsets). RDMA `ib_wc` = `{wr_id, status, opcode, byte_len, imm_data, src_qp …}`, fixed semantics defined by the transport.
- **One-to-many.** io_uring **multishot** requests (accept, recv, poll, `RECV_ZC`) produce a stream of CQEs from one SQE ([[io-uring-async-poll-and-multishot]]). RDMA is one WR → at most one CQE. Receive "multishot" is emulated by posting many RECV WRs (or an SRQ).
- **Selective completion.** RDMA can suppress CQEs for unsignalled sends (a later signalled WR implies earlier ones finished). io_uring has `IOSQE_CQE_SKIP_SUCCESS`, which is similar in spirit.
- **Ordering.** RDMA RC completions on one QP are strictly ordered. io_uring completions are unordered unless requests are linked (`IOSQE_IO_LINK`) or drained.
- **Two-phase completions for zero-copy.** io_uring `SEND_ZC` posts a result CQE, then a separate `F_NOTIF` CQE when the pages are free. RDMA gives one CQE, meaning "the remote side has ACKed", after which the buffer is free. For RDMA WRITE that also means the data is placed remotely.
- **Waiting.** io_uring: `io_uring_enter(GETEVENTS, min_complete, timeout)`, registered eventfd, or IOPOLL spinning on device queues. RDMA: busy-poll `ibv_poll_cq` (pure memory reads), or arm with `ibv_req_notify_cq` and block on a completion-channel fd (the only point where the kernel re-enters the RDMA data path). Both support hybrid spin-then-sleep (see [[polling-vs-interrupts-io-uring-napi-rdma-cq]]).
- **Overflow.** io_uring buffers CQEs internally if the CQ is full (`IORING_SQ_CQ_OVERFLOW`), so no completion is lost. An RDMA CQ overflow is a fatal async error (`IB_EVENT_CQ_ERR`), and the application must size CQs for the worst case.

### 3. Memory registration

| | io_uring registered buffers | RDMA memory regions |
|---|---|---|
| API | `IORING_REGISTER_BUFFERS[2]` ([[registered-resources]]) | `ibv_reg_mr` / `ibv_reg_dmabuf_mr` ([[memory-registration-and-ib-umem]]) |
| Pinning | `pin_user_pages_fast(FOLL_LONGTERM)`, charged to `RLIMIT_MEMLOCK` | Same: `pin_user_pages_fast(FOLL_LONGTERM)`, charged to `pinned_vm` vs `RLIMIT_MEMLOCK` |
| What's built | Kernel-side `bio_vec` table (`io_mapped_ubuf`), CPU-physical | DMA-mapped scatterlist, programmed into the **NIC's own translation table (MTT)** |
| Handle | Index (`buf_index`) valid only inside this ring | `lkey` (local) and **`rkey`, usable by a remote peer** |
| Remote access | None, since only the kernel on this host uses it | Yes: the peer's NIC reads and writes it by rkey with no local CPU |
| Purpose | Skip per-I/O GUP and pinning cost | Give the NIC an independent, access-controlled address space |
| Unpinned alternative | Not for general buffers (zcrx areas are provider-managed) | **ODP**: NIC page faults + mmu-notifier invalidation ([[on-demand-paging-odp]]) |
| Device memory | zcrx areas and (planned) TX from dma-bufs ([[zero-copy-rx-zcrx]]) | dma-buf MRs (5.12+), dynamic or pinned-revocable ([[dma-buf-sharing]]) |

Both converge on the same mm primitives (`FOLL_LONGTERM` pins, `pinned_vm` accounting, dma-buf) and suffer the same conflicts with migration and CMA. RDMA additionally needs **huge-page-aware page-size selection** (`ib_umem_find_best_pgsz`) because NIC translation caches are small, while io_uring coalesces huge-page bvecs for iteration speed.

### 4. Zero-copy send

- **io_uring `SEND_ZC`**: the kernel TCP stack attaches the user's (possibly registered) pages to skbs as frags, the NIC DMAs from them, and a notification CQE says when TCP no longer needs them (after ACK). The **receiver** still runs a full TCP stack, and without zcrx it copies.
- **RDMA WRITE / SEND**: the NIC DMAs directly from the MR, segments and retransmits in hardware, and the remote NIC places the data. **RDMA WRITE requires no receiver CPU at all**, and SEND consumes a pre-posted receive buffer.

### 5. Zero-copy receive (the big difference)

- **io_uring zcrx**: the NIC must be configured with **header split**, and the application's flows **steered** to a dedicated RX queue whose page pool is an io_uring memory provider. Payloads land in the user area, headers go through kernel TCP, and CQEs point at `(area, offset)`. Buffers return through a refill ring. Wrong steering means a copy fallback ([[header-split-and-flow-steering-for-zero-copy-rx]], [[zero-copy-rx-zcrx]]).
- **RDMA**: placement is **protocol-defined**. A WRITE carries the target `{addr, rkey}`, so the NIC knows the final destination of every byte. A SEND lands in the next posted receive buffer. No header split, steering or queue dedication is needed, and the receiver's CPU doesn't process per-packet headers.

This is the core reason RDMA remains unmatched for remote-memory access: TCP-based schemes must *infer* placement from which queue a flow hashes to, while RDMA's wire protocol *states* it.

### 6. Connection setup and control plane

- io_uring uses ordinary sockets (`IORING_OP_CONNECT`, multishot `ACCEPT`) with the kernel's TCP handshake.
- RDMA needs QP creation, a state machine (INIT→RTR→RTS), out-of-band exchange of QPN/PSN/rkeys, and the RDMA CM ([[rdma-cm-connection-manager]]). Connection setup is far heavier (milliseconds, MADs, possibly SA queries), so RDMA favours long-lived connections and pooled QPs.

### 7. Security, isolation and observability

- io_uring operations go through the normal permission, LSM, netfilter, cgroup and accounting paths per operation (with an io_uring-specific attack surface that has led some distributions to restrict it).
- RDMA data movement bypasses all of that after setup: isolation rests on **hardware-enforced PD/lkey/rkey checks**, per-cgroup object limits (`rdma.max`) and fabric partitioning (P_Keys, VLANs). No firewall sees RDMA WRITEs. Traffic accounting comes from NIC counters ([[rdma-netlink-restrack-and-cgroup]]).

### 8. Performance envelope (rules of thumb)

- **Latency**: RDMA one-sided ops ≈ 1–3 µs end to end with no remote CPU. io_uring over kernel TCP ≈ 10–30 µs typical small-message RTT (less with busy-poll), dominated by two kernel stacks.
- **CPU per byte**: RDMA ≈ zero on both sides. io_uring zcrx plus SEND_ZC removes copies but keeps per-packet TCP/IP processing (reported ~116 Gbit/s on one core for zcrx at 200G).
- **Generality**: io_uring accelerates storage, files, sockets and device passthrough (NVMe uring_cmd with IOPOLL). RDMA needs RDMA NICs (or software rxe/siw at a large CPU cost) and, for RoCE, a tuned fabric ([[roce-congestion-control-pfc-ecn-dcqcn]]).
- **Using it well matters**: the 2025–26 DBMS study (Jasny, El-Hindi, Ziegler, Leis, Binnig) found that "naively replacing traditional I/O interfaces with io_uring does not necessarily yield performance benefits". Registered buffers, passthrough and architecture choices determined its 14% PostgreSQL gain. RDMA has the same property: naive verbs code (unsignalled sends, small MRs, no batching) loses much of its advantage.

### 9. Where they meet

- **io_uring on top of RDMA storage**: an NVMe-oF RDMA namespace is a normal block device, so io_uring (including IOPOLL on poll queues, and NVMe uring_cmd passthrough on `/dev/ng*`) drives it, with RDMA doing the network leg ([[nvme-over-fabrics-rdma-and-tcp]], [[uring-cmd-passthrough]]). liburing issue #1228 documents IOPOLL tuning problems at high queue depth over NVMe-oF RDMA.
- **Shared plumbing**: both use `FOLL_LONGTERM` pinning, dma-buf, P2PDMA ([[p2pdma-peer-to-peer-dma]]) and page-pool memory providers (RDMA via SMC-R's socket interface, not providers).
- **Sockets over RDMA**: SMC-R gives unmodified socket (and thus io_uring) applications an RDMA data path ([[smc-r-shared-memory-communications]]). There is no mainline io_uring interface to verbs itself: verbs' data path is already syscall-free, so there is nothing for io_uring to batch.

## Key Data Structures

**io_uring**: `struct io_uring_sqe`, `struct io_uring_cqe` (+ 32-byte extension), `struct io_ring_ctx`, `struct io_mapped_ubuf` (registered buffer), `struct io_zcrx_ifq` (zcrx).

**RDMA**: `struct ib_qp`, `struct ib_cq`, `struct ib_wc`, `struct ib_send_wr`/`ib_rdma_wr`, `struct ib_mr`, `struct ib_umem` (+ `_odp`, `_dmabuf`).

## Key Functions / Entry Points

- io_uring: `io_uring_enter()` → `io_submit_sqes()`; `io_sq_thread()`; `io_sqe_buffers_register()`; `io_send_zc()`; `io_recvzc()`
- RDMA: provider `post_send`/`poll_cq` (userspace, no syscall); `ib_umem_get_va()` / `ib_umem_odp_get()`; `ib_alloc_cq()` + `ib_cqe` for kernel users; `rdma_connect()`

## Important Flags & Config Options

- io_uring: `IORING_SETUP_SQPOLL`, `IORING_SETUP_IOPOLL`, `IORING_SETUP_DEFER_TASKRUN`, `IORING_SETUP_SINGLE_ISSUER`, `IORING_REGISTER_BUFFERS`, `IORING_OP_SEND_ZC`, `IORING_OP_RECV_ZC`, `IOSQE_CQE_SKIP_SUCCESS`
- RDMA: `IB_SEND_SIGNALED`, `IB_SEND_INLINE`, `IB_ACCESS_ON_DEMAND`, `IB_ACCESS_REMOTE_WRITE`, CQ `comp_vector`, `ibv_req_notify_cq`
- Shared: `RLIMIT_MEMLOCK`, `CAP_IPC_LOCK`, dma-buf fds

## Interactions with Other Subsystems

- **io_uring** leans on VFS, the block layer, the TCP/IP stack, the page pool (zcrx), and mm pinning
- **RDMA** leans on mm pinning, HMM/mmu-notifiers (ODP), the DMA/IOMMU layer, and the netdev layer for RoCE addressing; data movement bypasses the net stack
- Both: [[dma-buf-sharing]], [[get-user-pages-and-pinning]], [[dma-mapping-api]]

## Design Decisions & Tradeoffs

- **Kernel-executed vs hardware-executed.** io_uring keeps the kernel's semantics, security and portability and removes interface overhead. RDMA removes the kernel (and the remote CPU) from the data path at the cost of special hardware, a narrower operation set, and trust in NIC-enforced keys.
- **Registration scope.** An io_uring buffer registration is private to one ring on one host. An RDMA registration exports memory to a fabric. That is why RDMA needs keys, invalidation and ODP, while io_uring doesn't.
- **Placement knowledge.** RDMA protocols carry destination addresses, so zero-copy receive is inherent. TCP doesn't, so io_uring zcrx needs NIC header split plus steering and per-queue dedication.
- **Completion richness vs hardware simplicity.** io_uring can report arbitrary kernel results, multishot streams and buffer selections. RDMA CQEs are fixed-format but generated without software.
- **When to choose which.** io_uring suits general servers, storage engines, proxies and databases on commodity NICs and lossy networks. RDMA suits tightly coupled clusters (HPC, AI collectives, disaggregated storage, key-value caches) where microsecond latency and zero remote CPU justify the fabric. Increasingly both appear together: io_uring for local and TCP I/O, RDMA for the cluster fabric.

## How It Has Evolved

- **2005** — RDMA verbs in Linux (2.6.11) with queue pairs, CQs and MRs, a decade before io_uring
- **2019** — io_uring (5.1) brings the shared-ring model to general kernel I/O; registered buffers from day one
- **2019–2022** — io_uring gains SQPOLL for unprivileged users, IOPOLL, multishot, provided buffers and `SEND_ZC` (6.0), narrowing interface overhead toward RDMA-like levels
- **2020–2021** — RDMA dma-buf MRs (5.12); ODP converted to HMM
- **2025** — io_uring zcrx (6.15) with dma-buf areas (6.16): zero-copy receive into user or GPU memory *through* kernel TCP, the closest io_uring has come to RDMA semantics
- **2026** — RDMA dma-buf export and revocation; zcrx events, multi-area and export; netkit queue leasing brings zcrx into containers

## Further Reading

- Paper — [High-Performance DBMSs with io_uring: When and How to use it](https://arxiv.org/abs/2512.04859) (Jasny et al., 2025–26)
- Talk — [Efficient zero-copy networking using io_uring](https://kernel-recipes.org/en/2024/schedule/efficient-zero-copy-networking-using-io_uring/) (Begunkov, Wei; Kernel Recipes 2024)
- kernel.org — [io_uring zero copy Rx](https://docs.kernel.org/networking/iou-zcrx.html); [Userspace verbs access](https://www.kernel.org/doc/html/latest/infiniband/user_verbs.html)
- Blog — [Kernel Bypass Networking: DPDK, io_uring, and the RDMA Revolution](https://blog.lbenicio.dev/blog/kernel-bypass-networking-dpdk-io_uring-and-the-rdma-revolution/)
- liburing — [IOPOLL with NVMe-oF RDMA issue #1228](https://github.com/axboe/liburing/issues/1228)
- Related: [[io-uring-internals]], [[registered-resources]], [[io-uring-zero-copy-networking]], [[zero-copy-rx-zcrx]], [[rdma]], [[queue-pairs-and-completion-queues]], [[memory-registration-and-ib-umem]], [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk]], [[devmem-tcp-vs-rdma-gpudirect-vs-io-uring-zcrx]]

## LKML Highlights

- **io_uring zcrx v6 `<20241016185252.3746190-1-dw@davidwei.uk>`** — explicitly positioned as zero-copy *without* kernel bypass: vanilla TCP with header split and a page-pool provider, in contrast to RDMA and DPDK.
- **RDMA dma-buf `<1604616489-69267-1-git-send-email-jianxin.xiong@intel.com>`** — brought device-memory registration to verbs, the RDMA counterpart of zcrx and devmem dma-buf areas.
- **"Abstract page from net stack" `<20231214020530.2267499-1-almasrymina@google.com>`** — the netmem groundwork that let TCP-based zero-copy (devmem, zcrx) approach RDMA-style direct placement without a hardware transport.
