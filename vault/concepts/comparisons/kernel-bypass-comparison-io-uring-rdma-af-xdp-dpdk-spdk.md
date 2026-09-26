---
title: "Kernel-Bypass Comparison: io_uring vs RDMA vs AF_XDP vs DPDK vs SPDK"
category: concept
tags: [comparison, kernel-bypass, io_uring, rdma, af-xdp, dpdk]
subsystem: comparisons
kernel_version: "RDMA 2.6.11; DPDK (VFIO) 3.6+; AF_XDP 4.18; io_uring 5.1; zcrx 6.15"
researched: 2026-09-26
status: complete
sources:
  - https://spdk.io/doc/userspace.html
  - https://spdk.io/doc/nvme.html
  - https://spdk.io/news/2024/06/24/Performance_Report_Update/
  - https://muratkarslioglu.com/blog/io-uring-spdk-kernel-bypass/
  - https://doc.dpdk.org/guides/nics/mlx5.html
  - https://medium.com/@rickijen/dpdk-migrating-mlx5-pmd-to-af-xdp-pmd-with-ebpf-and-performing-benchmarks-6c4d5afef7a4
  - https://blog.lbenicio.dev/blog/kernel-bypass-networking-dpdk-io_uring-and-the-rdma-revolution/
  - https://arxiv.org/abs/2512.04859
  - https://docs.kernel.org/networking/iou-zcrx.html
  - https://www.kernel.org/doc/html/latest/infiniband/user_verbs.html
---

# Kernel-Bypass Comparison: io_uring vs RDMA vs AF_XDP vs DPDK vs SPDK

> Comparison note under `comparisons/`. See also [[io-uring-vs-rdma]] (a deeper two-way comparison) and [[polling-vs-interrupts-io-uring-napi-rdma-cq]].

## Purpose

"Kernel bypass" covers very different designs that all attack the same costs (syscalls, interrupts, context switches, copies, and generic-stack processing) but take different amounts of the kernel out of the path and give up different things in return. This note puts five Linux-relevant approaches on one axis, from "kernel does everything, just cheaper to talk to" to "kernel only hands over the device":

| Approach | What is bypassed | Who owns the device |
|---|---|---|
| **io_uring** | Syscall-per-op and (optionally) interrupts and copies; *not* the kernel's I/O stacks | Kernel |
| **AF_XDP** | The network stack (skbs, TCP/IP) for steered queues; driver and XDP stay in-kernel | Kernel (per-queue sharing) |
| **RDMA verbs** | The kernel *and* the remote CPU on the data path; transport runs in NIC hardware | Kernel owns control plane, NIC runs data plane |
| **DPDK** | Everything: userspace poll-mode drivers own NIC queues | Userspace (VFIO), or bifurcated (mlx5) |
| **SPDK** | Everything for storage: userspace NVMe driver owns the SSD | Userspace (VFIO) |

## Mental Model

Picture a **spectrum of how much of the restaurant you rent**:
- **io_uring**: you still eat in the restaurant (kernel), but you get a **tablet to order in batches** instead of calling a waiter for each dish.
- **AF_XDP**: you get a **private pass-through window to the kitchen's raw-ingredient delivery** for some tables. The kitchen (driver/XDP) still unpacks deliveries, but skips cooking (the stack).
- **RDMA**: you hire a **robot courier** that moves boxes between your pantry and another house's pantry without anyone at either house.
- **DPDK / SPDK**: you **rent the whole kitchen** (the device) and run it yourself with your own staff (poll-mode drivers). Nobody else can use it, and you enforce your own health code.

## How It Works

### io_uring — kernel-executed, interface-optimized

- **Mechanism**: shared SQ/CQ rings. Batching or SQPOLL removes per-op syscalls. Registered files and buffers remove per-op fd lookup and pinning. IOPOLL polls NVMe completion queues (no interrupts). `uring_cmd` passes NVMe commands through (`/dev/ngXnY`). Networking gets `SEND_ZC` and **zcrx** (zero-copy RX through kernel TCP via header split + steering) ([[io-uring-internals]], [[sqpoll]], [[registered-resources]], [[uring-cmd-passthrough]], [[zero-copy-rx-zcrx]]).
- **Keeps**: VFS, page cache (optional), filesystems, TCP/IP, netfilter, cgroups, multi-tenant sharing of every device, standard tooling.
- **Costs**: kernel stack processing per operation remains (block layer, TCP), plus an io_uring-specific attack surface (some distros restrict it).
- **Storage numbers (reported)**: FAST '24 measured `io_uring_cmd` NVMe passthrough "within 9–16%" of SPDK, and secondary summaries put a fully optimized io_uring stack at about 80% of SPDK peak IOPS. For DBMSs, Jasny et al. (2025–26) show gains depend on architecture (14% for PostgreSQL with their guidelines).

### AF_XDP — bypass the network stack, keep the driver

- **Mechanism**: an XDP program redirects frames from a NIC queue into an `AF_XDP` socket whose **UMEM** (user memory) holds the frames. FILL/RX/TX/COMPLETION rings carry frame indexes. Zero-copy mode lets the NIC DMA straight into UMEM. `need_wakeup` and busy-poll (`SO_PREFER_BUSY_POLL`) remove syscalls and interrupts ([[af-xdp]], [[xdp]]).
- **Keeps**: the kernel driver and device ownership. Non-steered traffic still flows through the normal stack on the same NIC. XDP programs can filter and steer. Security model: `CAP_NET_RAW`/`CAP_BPF`, per-queue binding.
- **Gives up**: the TCP/IP stack for those frames. Applications get raw L2 frames and must bring their own protocol processing (or run a userspace stack).
- **Used by**: packet processing (load balancers, NFV, capture), and **DPDK's AF_XDP PMD**, which runs DPDK apps on unmodified kernel drivers.

### RDMA verbs — hardware transport, kernel control plane

- **Mechanism**: the kernel (uverbs) creates QPs, CQs and MRs, pins and maps memory, and brokers connections. Afterwards userspace writes WQEs and rings MMIO doorbells, and polls CQEs, all in shared memory. The NIC executes the reliable transport and places data by rkey on the remote host ([[rdma]], [[verbs-api-and-uverbs]], [[queue-pairs-and-completion-queues]]).
- **Keeps**: kernel-managed device and resource lifetime, cgroup limits, multi-process sharing via PDs/QPs, hot-unplug safety.
- **Gives up**: per-operation kernel visibility (no firewall or qdisc on RDMA traffic), and requires RDMA NICs on both ends plus (for RoCE) a tuned fabric.
- **Unique property**: **one-sided operations with zero remote CPU**. No other approach here can write into another machine's memory without software running there.

### DPDK — userspace owns the NIC

- **Mechanism**: the NIC (or VF) is unbound from its kernel driver and bound to **`vfio-pci`** (or legacy `uio`). DPDK's **poll-mode driver (PMD)** maps the device BARs and DMA rings into the process, uses **hugepage**-backed `mbuf` pools as DMA-safe memory (mapped through the IOMMU by VFIO), and dedicates cores to busy-polling RX/TX queues in a run-to-completion loop. There are no interrupts, no syscalls and no kernel involvement per packet.
- **Variants**: **bifurcated** drivers (mlx5) keep the device bound to `mlx5_core`. DPDK's mlx5 PMD uses verbs/DevX (the RDMA subsystem's userspace interface) to create raw packet queues, and flow rules steer selected traffic to DPDK while the kernel keeps the rest. The **AF_XDP PMD** runs over kernel drivers at some cost in throughput.
- **Gives up**: kernel networking entirely for owned queues (bring your own TCP/IP stack, e.g. F-Stack or TLDK, or do L2/L3 processing), device sharing with the kernel (except bifurcated), standard tools, and power efficiency (dedicated spinning cores).

### SPDK — userspace owns the SSD

- **Mechanism**: NVMe devices are unbound from `nvme` and bound to `vfio-pci`/`uio`. SPDK's userspace NVMe driver maps the controller registers and allocates submission/completion queues in DMA-safe (hugepage) memory. Each application thread gets **its own NVMe queue pair**, so there is no locking. Completions are **polled**: interrupts can't practically be routed to userspace, they add jitter and context switches, and polling a CQ is just a cached memory read.
- **Also includes**: bdev layer, NVMe-oF **target** (RDMA and TCP transports, the userspace counterpart of `nvmet`), vhost-user for VMs, and an `io_uring` bdev for using kernel devices when bypass isn't possible ([[nvme-over-fabrics-rdma-and-tcp]]).
- **Numbers (reported)**: about 1M+ IOPS per core; 4.2M IOPS on 5 cores across 8 NVMe drives (VU Amsterdam, CHEOPS/SYSTOR). HotStorage '25 ("SPDK+") measured ~85% of polling cycles wasted spinning on empty CQs at moderate load, which is the power cost of always-poll.
- **Gives up**: filesystems, page cache, kernel NVMe multipath and sharing the device with other processes. Recovery and management are the application's job.

### Comparison matrix

| Dimension | io_uring | AF_XDP | RDMA verbs | DPDK | SPDK |
|---|---|---|---|---|---|
| Domain | Files, block, sockets, passthrough | Raw packets (L2) | Remote memory / messaging | Raw packets (L2+) | NVMe storage |
| Kernel stack in data path | Yes (TCP, block, VFS) | Driver + XDP only | No (after setup) | No | No |
| Device shared with kernel | Yes | Yes (per queue) | Yes (per QP) | No (yes if bifurcated) | No |
| Per-op syscall | No (batched / SQPOLL) | No (need_wakeup) | No | No | No |
| Interrupts | Optional (IOPOLL/busy-poll) | Optional (busy-poll) | Optional (CQ poll or arm) | None (poll) | None (poll) |
| Zero-copy | Registered buffers, SEND_ZC, zcrx | UMEM zero-copy mode | Inherent (MRs) | Inherent (mbufs) | Inherent |
| Remote CPU needed | Yes | Yes | **No (one-sided)** | Yes | Yes (target side) |
| Protocol stack | Kernel | Bring your own | NIC hardware | Bring your own | NVMe (userspace driver) |
| Security enforcement | Kernel per op | Kernel at bind + XDP | NIC keys + kernel setup | IOMMU (VFIO) only | IOMMU (VFIO) only |
| Special hardware | No (zcrx needs HDS/steering) | XDP-capable driver | RDMA NIC (+ fabric) | PMD-supported NIC | NVMe |
| Core dedication | Optional (SQPOLL thread) | Optional | Optional | Typical | Typical |
| Tooling/observability | Standard + io_uring tracepoints | Standard netdev + XDP stats | NIC counters, rdma tool | App-provided | App-provided |

### Choosing

- **Default to io_uring** for servers, databases and storage engines that want lower overhead without leaving the kernel's semantics. Add IOPOLL/passthrough for NVMe and zcrx for high-bandwidth TCP receive.
- **AF_XDP** when you need raw-packet processing at high rates but want to keep the kernel driver and share the NIC with normal traffic.
- **RDMA** for cluster fabrics where microsecond latency, zero remote CPU or GPU-direct transfers justify RDMA NICs (AI collectives, HPC, disaggregated storage, distributed caches).
- **DPDK** for dedicated packet-processing appliances (vRouters, 5G UPF, firewalls) that need every cycle and can own the NIC.
- **SPDK** for dedicated storage targets and appliances where cores can be burned for maximal IOPS per SSD and kernel features aren't needed.

## Key Data Structures

- io_uring: `struct io_ring_ctx`, `io_uring_sqe`/`cqe`, `io_mapped_ubuf`, `io_zcrx_ifq`
- AF_XDP: `struct xdp_sock`, `struct xsk_buff_pool`, UMEM, the four rings
- RDMA: `struct ib_qp`, `ib_cq`, `ib_mr`, `ib_umem`
- DPDK (userspace): `rte_mbuf`, `rte_mempool`, `rte_eth_dev`; kernel side `vfio_pci_core_device`
- SPDK (userspace): `spdk_nvme_ctrlr`, `spdk_nvme_qpair`; kernel side VFIO

## Key Functions / Entry Points

- io_uring: `io_uring_enter()`, `io_sq_thread()`, `io_do_iopoll()`
- AF_XDP: `xsk_bind()`, `xsk_rcv()`, `ndo_xsk_wakeup`
- RDMA: uverbs ioctl, provider `post_send`/`poll_cq` in userspace, `ib_umem_get_va()`
- DPDK/SPDK: `vfio_pci` (`VFIO_DEVICE_GET_REGION_INFO`, `VFIO_IOMMU_MAP_DMA`), then userspace only

## Important Flags & Config Options

- io_uring: `IORING_SETUP_SQPOLL`, `IORING_SETUP_IOPOLL`, `nvme.poll_queues`, `IORING_REGISTER_BUFFERS`, `IORING_OP_RECV_ZC`
- AF_XDP: `XDP_ZEROCOPY`, `XDP_USE_NEED_WAKEUP`, `SO_PREFER_BUSY_POLL`
- RDMA: `IB_ACCESS_*`, `RLIMIT_MEMLOCK`, `rdma.max` cgroup
- DPDK/SPDK: `vfio-pci` binding (`dpdk-devbind.py`, `setup.sh`), hugepages (`vm.nr_hugepages`), `iommu=pt`/`intel_iommu=on`, isolated cores (`isolcpus`, `nohz_full`)

## Interactions with Other Subsystems

- **VFIO / IOMMU**: the safety net for DPDK and SPDK; also used by RDMA for dma-buf export of VFIO device memory ([[p2pdma-peer-to-peer-dma]])
- **mm**: hugepages and long-term pinning are shared by all ([[get-user-pages-and-pinning]], [[huge-pages-hugetlbfs]])
- **net**: AF_XDP and zcrx both bind to NIC queues through core helpers; netkit queue leasing (2026) extends both into containers ([[netdev-queue-management-api]])
- **block / NVMe**: io_uring passthrough and polled queues vs SPDK userspace queues ([[blk-mq]])

## Design Decisions & Tradeoffs

- **Generality vs speed.** The more of the kernel you bypass, the less you get for free: io_uring keeps everything, AF_XDP drops the network stack, and DPDK/SPDK drop the driver and device sharing. RDMA is orthogonal: it keeps kernel ownership but moves the transport into hardware.
- **Polling vs power.** Every approach reaches peak numbers by polling, and SPDK's own research shows the waste. io_uring, AF_XDP and RDMA let you switch between polling and interrupts, while DPDK and SPDK are built around polling. See [[polling-vs-interrupts-io-uring-napi-rdma-cq]].
- **Security model.** Kernel-mediated approaches enforce policy per operation (io_uring) or at bind time (AF_XDP, RDMA setup). VFIO-based bypass trusts the application with the whole device, constrained only by the IOMMU.
- **Convergence.** Kernel features keep absorbing bypass wins: io_uring passthrough approaches SPDK, AF_XDP gives DPDK a kernel-friendly backend, zcrx and devmem bring zero-copy RX to kernel TCP, and queue leasing brings them into containers. The remaining gaps are protocol processing cost (TCP vs none) and one-sided remote access (only RDMA).

## How It Has Evolved

- **2005** — RDMA verbs in Linux
- **2010–2013** — DPDK (Intel, open-sourced 2013) on UIO, then VFIO (Linux 3.6, 2012)
- **2015** — SPDK (Intel) userspace NVMe driver
- **2018** — AF_XDP (4.18); DPDK AF_XDP PMD (19.05)
- **2019** — io_uring (5.1)
- **2022–2024** — io_uring NVMe passthrough (`uring_cmd`, 5.19); FAST '24 shows passthrough within 9–16% of SPDK
- **2024–2025** — devmem TCP (6.12), io_uring zcrx (6.15), AF_XDP multi-buffer and TX metadata
- **2026** — netkit queue leasing (AF_XDP + providers in containers); zcrx events and export; SPDK+ research on power-efficient polling

## Further Reading

- SPDK — [User Space Drivers](https://spdk.io/doc/userspace.html); [NVMe Driver](https://spdk.io/doc/nvme.html); [24.05 performance report](https://spdk.io/news/2024/06/24/Performance_Report_Update/)
- DPDK — [NVIDIA mlx5 PMD (bifurcated)](https://doc.dpdk.org/guides/nics/mlx5.html); [mlx5 PMD vs AF_XDP PMD benchmarks](https://medium.com/@rickijen/dpdk-migrating-mlx5-pmd-to-af-xdp-pmd-with-ebpf-and-performing-benchmarks-6c4d5afef7a4)
- Blog — [io_uring, SPDK, and the Kernel Bypass Wars](https://muratkarslioglu.com/blog/io-uring-spdk-kernel-bypass/) (collects FAST '24, CHEOPS/SYSTOR, HotStorage '25 numbers)
- Blog — [Kernel Bypass Networking: DPDK, io_uring, and the RDMA Revolution](https://blog.lbenicio.dev/blog/kernel-bypass-networking-dpdk-io_uring-and-the-rdma-revolution/)
- Paper — [High-Performance DBMSs with io_uring](https://arxiv.org/abs/2512.04859)
- Related: [[io-uring-vs-rdma]], [[af-xdp]], [[rdma]], [[zero-copy-rx-zcrx]], [[uring-cmd-passthrough]], [[devmem-tcp-vs-rdma-gpudirect-vs-io-uring-zcrx]]

## LKML Highlights

- **AF_XDP introduction (Björn Töpel, Magnus Karlsson, 2018)** — framed explicitly as a way to get "DPDK-like" performance while keeping the kernel driver, which is the design point between the kernel stack and full bypass ([[af-xdp]]).
- **io_uring NVMe passthrough (Kanchan Joshi et al., 2022, 5.19)** — `uring_cmd` for NVMe character devices, the kernel's answer to SPDK-style direct queue access. Later measured within 9–16% of SPDK (FAST '24).
- **io_uring zcrx v6 `<20241016185252.3746190-1-dw@davidwei.uk>`** — zero-copy TCP receive *without* bypass, positioned against DPDK and RDMA as keeping the kernel stack while removing the copy.
