---
title: "Devmem TCP vs GPUDirect RDMA vs io_uring zcrx: Moving Network Data Straight to Accelerator Memory"
category: concept
tags: [comparison, devmem, gpudirect, rdma, io_uring, dma-buf]
subsystem: comparisons
kernel_version: "RDMA dma-buf 5.12; devmem RX 6.12 / TX 6.16; zcrx 6.15 (dma-buf areas 6.16)"
researched: 2026-09-26
status: complete
explained: "[[devmem-tcp-vs-rdma-gpudirect-vs-io-uring-zcrx-explained]]"
sources:
  - https://docs.nvidia.com/cuda/gpudirect-rdma/index.html
  - https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/24.6.2/gpu-operator-rdma.html
  - https://kubernetes.recipes/recipes/networking/gpudirect-rdma-dma-buf/
  - https://oneuptime.com/blog/post/2026-08-14-gpudirect-rdma-acs-iommu-topology/view
  - https://docs.kernel.org/networking/devmem.html
  - https://docs.kernel.org/networking/iou-zcrx.html
  - https://lwn.net/Articles/979549/
  - https://lwn.net/Articles/836484/
  - https://github.com/google/nccl-plugin-gpudirecttcpx
  - https://docs.cloud.google.com/cluster-toolkit/docs/machine-learning/a3-mega-enable-gpudirect-tcpxo
---

# Devmem TCP vs GPUDirect RDMA vs io_uring zcrx: Moving Network Data Straight to Accelerator Memory

> 📘 Plain-language version: [[devmem-tcp-vs-rdma-gpudirect-vs-io-uring-zcrx-explained]]

> Comparison note under `comparisons/`. Builds on [[devmem-tcp]], [[memory-registration-and-ib-umem]], [[zero-copy-rx-zcrx]], [[dma-buf-sharing]] and [[p2pdma-peer-to-peer-dma]].

## Purpose

Distributed AI training and inference constantly move tensors between GPUs on different machines. The naive path, GPU → host RAM → NIC → wire → NIC → host RAM → GPU, costs two PCIe crossings through the root complex per side, host memory bandwidth, and CPU time. Linux now has **three** ways to make the NIC DMA directly to and from accelerator memory, all built on **dma-buf** as the common currency for "device memory another driver can DMA to":
1. **GPUDirect RDMA**: register GPU memory as an RDMA **memory region** and let the RDMA transport (InfiniBand/RoCE) place data by rkey.
2. **Devmem TCP**: bind GPU memory to a NIC **RX queue's page pool** so kernel TCP receives payloads into it, and send from it with `MSG_ZEROCOPY`.
3. **io_uring zcrx with a dma-buf area**: the same RX mechanism as devmem, but with io_uring's completion rings and refill queue.

They differ in who runs the transport, what the network must provide, how buffers are returned, and how much of the kernel's networking stays in the loop.

## Mental Model

All three are ways to **deliver freight straight to a warehouse behind a locked gate** (GPU HBM). **GPUDirect RDMA** hires a **private courier with its own road network** (the RDMA NIC and fabric): the sender addresses each crate to "gate key R, shelf X", and the courier delivers it there, with no one at either office involved. **Devmem TCP** and **zcrx** use the **public postal service** (kernel TCP over any Ethernet): the post office still reads every envelope and handles lost mail, but a special sorting rule (header split + steering to a dedicated queue) sends the *contents* of certain mail straight through the gate, while the envelopes go to the office. Devmem tells the recipient via **receipts in the mailbox** (socket cmsgs, returned by setsockopt). zcrx posts them on a **shared noticeboard** (CQEs, returned through a refill ring).

## How It Works

### Common foundation: getting a DMA-able handle to GPU memory

- The GPU driver **exports** a dma-buf for a GPU allocation: NVIDIA open kernel modules (Turing+, Linux 5.12+ for RDMA import), AMD `amdgpu`, Intel `xe`, or `udmabuf` for testing.
- The importing NIC path **attaches** and maps it, getting DMA addresses valid for that NIC. When the NIC and GPU sit under the same PCIe switch, that is a **P2P bus address** (`PCI_P2PDMA_MAP_BUS_ADDR`), and traffic never crosses the root complex. Otherwise it goes through an allowlisted host bridge ([[p2pdma-peer-to-peer-dma]]).
- Topology rules are shared: GPU and NIC under a common switch for performance, **ACS** redirect disabled on that switch or P2P TLPs bounce off the root complex, and IOMMU configuration that permits the mapping. NVIDIA's docs historically required 1:1 IOMMU mappings for the legacy path.

### 1. GPUDirect RDMA

- **Registration**: `ibv_reg_dmabuf_mr(pd, offset, len, iova, dmabuf_fd, access)` → provider `reg_user_mr_dmabuf` → `ib_umem_dmabuf_get()` (dynamic, ODP-capable NICs like mlx5) or `ib_umem_dmabuf_get_pinned()` (other NICs), with 2026 adding pinned-*revocable* import. The NIC's MTT points at GPU BAR pages. The legacy alternative, **`nvidia-peermem`** (the out-of-tree "peer memory client" API via `nvidia_p2p_get_pages()`, never merged upstream), is now discouraged in favour of dma-buf ([[memory-registration-and-ib-umem]]).
- **Data path**: NCCL's net plugin (or UCX, NIXL) posts RDMA WRITE/SEND WRs whose SGEs use the GPU MR's lkey, and the remote side's rkey names *its* GPU memory. The NIC reads HBM via PCIe P2P, the RDMA transport carries it, and the remote NIC writes into remote HBM. **No kernel involvement per transfer on either side, and no header processing by any CPU.**
- **Completion and buffer reuse**: CQEs polled by the proxy thread. Buffer reuse is governed by the collective's protocol, since the memory is permanently registered.
- **Requirements**: RDMA NICs (ConnectX, BlueField, etc.) end to end; InfiniBand, or RoCE with PFC/ECN tuning ([[roce-congestion-control-pfc-ecn-dcqcn]]); QP and MR state per peer.

### 2. Devmem TCP

- **RX binding**: netdev netlink `bind-rx {ifindex, dmabuf fd, queues}` → a static dma-buf attach, the genpool of `net_iov`s, and a page-pool memory provider on the chosen queues, installed via per-queue restart ([[devmem-tcp-rx-dmabuf-binding-and-token-recycling]], [[netdev-queue-management-api]]).
- **RX data path**: NIC header split puts headers in host pages and payload in GPU memory, and flow steering pins the flow to the bound queue ([[header-split-and-flow-steering-for-zero-copy-rx]]). Kernel TCP processes headers (ACKs, reordering, congestion control) on **unreadable** skbs. `recvmsg(MSG_SOCK_DEVMEM)` returns `SCM_DEVMEM_DMABUF {frag_offset, frag_size, frag_token}` cmsgs, and the application launches GPU kernels on those offsets.
- **RX buffer return**: `setsockopt(SO_DEVMEM_DONTNEED, tokens)` (≤128 ranges / 1024 frags per call).
- **TX**: `bind-tx` + `sendmsg(MSG_ZEROCOPY)` with `SCM_DEVMEM_DMABUF` and offset iovecs, and `MSG_ERRQUEUE` completions ([[devmem-tcp-tx]]).
- **Requirements**: an Ethernet NIC with netmem support, header split, n-tuple steering and checksum offload (gve, mlx5, bnxt, fbnic, idpf …). **Any TCP peer** works, over any routed, lossy network.
- **Deployment lineage**: Google built devmem to support GPU networking on its A3 VMs (the "GPUDirect-TCPX" NCCL plugin), then pushed the mechanism upstream. A3-Mega's TCPXO uses an IPU-offloaded variant.

### 3. io_uring zcrx with a dma-buf area

- **Registration**: `IORING_REGISTER_ZCRX_IFQ` with `area.flags = IORING_ZCRX_AREA_DMABUF`, `dmabuf_fd` → `io_import_dmabuf()` (static attach, `DMA_FROM_DEVICE`), the same `netif_mp_open_rxq()` binding path as devmem.
- **RX data path**: identical NIC requirements (header split, steering, dedicated queue). Completions are **CQEs** carrying `(area_id, offset)` and length, posted from `RECV_ZC` multishot requests.
- **Buffer return**: write `{off, len}` into the **refill ring** in shared memory, with no syscall. The kernel drains it when the NIC needs buffers.
- **Differences from devmem**: ring-based completion and return instead of cmsg + setsockopt. Copy fallback is **not possible** for dma-buf areas (the kernel can't read GPU memory), so unsteered data can't be delivered through zcrx in that case. Export/import lets several rings share an ifq. Events report allocation failures.
- **TX**: io_uring `SEND_ZC` supports registered *host* buffers, and sending from dma-bufs through io_uring isn't in mainline, so GPU TX uses devmem `bind-tx` + `sendmsg`.

### Side-by-side

| Aspect | GPUDirect RDMA | Devmem TCP | io_uring zcrx (dma-buf) |
|---|---|---|---|
| Transport | RDMA (IB / RoCE / iWARP) in NIC hardware | Kernel TCP | Kernel TCP |
| Network requirements | RDMA fabric; RoCE needs PFC/ECN tuning | Any IP network | Any IP network |
| Peer requirements | RDMA-capable peer | Any TCP peer | Any TCP peer |
| NIC features | RDMA NIC; ODP or pinned dma-buf MR support | Header split, steering, csum offload, netmem driver | Same as devmem |
| Placement decided by | Wire protocol (rkey + address) | RX queue a flow hashes to | RX queue a flow hashes to |
| Kernel per packet | None | Header/TCP processing | Header/TCP processing |
| Receiver CPU | None (one-sided) | Per-packet stack + recvmsg | Per-packet stack + ring handling |
| Buffer return | Application protocol (MR stays registered) | `SO_DEVMEM_DONTNEED` tokens | Refill ring |
| Completion API | Verbs CQ | recvmsg cmsgs / MSG_ERRQUEUE (TX) | io_uring CQEs |
| TX from GPU | Yes (RDMA WRITE/SEND) | Yes (`bind-tx`, `MSG_ZEROCOPY`) | Not in mainline (use devmem TX) |
| Queue dedication | No | Yes (bound RX queues) | Yes (bound RX queue) |
| Firewall/tc/BPF on payload | Not applicable (bypass) | Headers only, payload unreadable | Headers only |
| Privilege | uverbs (unprivileged, cgroup-limited) | `bind-rx` needs CAP_NET_ADMIN (netns); `bind-tx` unprivileged | Ring registration (unprivileged, rlimits), queue config by admin |
| Containers | SR-IOV VFs / macvlan RDMA | netkit queue leasing (2026) | netkit queue leasing (2026) |

## Key Data Structures

- GPUDirect RDMA: `struct ib_umem_dmabuf`, `struct ib_mr` (`lkey`/`rkey`)
- Devmem: `struct net_devmem_dmabuf_binding`, `struct net_iov` (`NET_IOV_DMABUF`), `sk->sk_user_frags`
- zcrx: `struct io_zcrx_ifq`, `struct io_zcrx_area` (`mem.is_dmabuf`), `struct io_uring_zcrx_cqe`
- Shared: `struct dma_buf_attachment`, `struct sg_table`, `struct p2pdma_provider`

## Key Functions / Entry Points

- `ib_umem_dmabuf_get()` / `ib_umem_dmabuf_get_pinned()` (`drivers/infiniband/core/umem_dmabuf.c`)
- `net_devmem_bind_dmabuf()`, `tcp_recvmsg_dmabuf()`, `sock_devmem_dontneed()`, `zerocopy_fill_skb_from_devmem()`
- `io_import_dmabuf()`, `io_pp_zc_alloc_netmems()`, `io_zcrx_queue_cqe()`
- `netif_mp_open_rxq()` (shared by devmem and zcrx)

## Important Flags & Config Options

- GPUDirect RDMA: `IB_ACCESS_*` on dma-buf MRs; NCCL `NCCL_NET_GDR_LEVEL`, `NCCL_DMABUF_ENABLE`; perftest `--use_cuda_dmabuf`
- Devmem: `CONFIG_NET_DEVMEM`, `MSG_SOCK_DEVMEM`, `SO_DEVMEM_DONTNEED`, `SCM_DEVMEM_DMABUF`, `SCM_DEVMEM_LINEAR`
- zcrx: `CONFIG_IO_URING_ZCRX`, `IORING_ZCRX_AREA_DMABUF`, `IORING_OP_RECV_ZC`
- Topology: ACS redirect off on the GPU/NIC switch; `CONFIG_PCI_P2PDMA`; IOMMU mode

## Interactions with Other Subsystems

- **GPU drivers** export dma-bufs; recent revocation semantics affect which importers are allowed ([[dma-buf-sharing]])
- **PCIe P2P** routing and addressing ([[p2pdma-peer-to-peer-dma]])
- **RDMA core** for GPUDirect ([[rdma]]); **netmem / page pool / queue API** for devmem and zcrx ([[netmem-and-net-iov-abstraction]], [[page-pool]], [[netdev-queue-management-api]])
- **Collective libraries** (NCCL/RCCL net plugins, UCX, NIXL) choose among them per cluster
- See also [[io-uring-vs-rdma]] and [[kernel-bypass-comparison-io-uring-rdma-af-xdp-dpdk-spdk]]

## Design Decisions & Tradeoffs

- **Hardware transport vs kernel TCP.** GPUDirect RDMA gives the lowest latency (≈2 µs class) and zero CPU, but needs an RDMA fabric and its operational burden. Devmem and zcrx accept per-packet CPU header processing to gain **any-network, any-peer** deployability and the kernel's congestion control. That was the explicit bet behind Google's devmem work.
- **Placement knowledge.** RDMA knows exactly where every byte goes. TCP-based schemes rely on header split and steering, so they need dedicated queues, careful ethtool setup, and payloads that are unreadable to the host (no software checksum, no payload BPF, no tcpdump of data).
- **Buffer lifecycle.** RDMA MRs stay registered and applications manage reuse. Devmem and zcrx lend NIC buffers to the application, so slow returns starve the RX queue and cause drops. zcrx's refill ring makes returns cheaper than devmem's setsockopt.
- **Pinning and revocation.** All three currently use pinned (static) dma-buf attachments on most hardware, so GPU memory can't be evicted while bound. RDMA alone supports *dynamic* attach on ODP NICs, and 2026 revocation work (VFIO, RDMA pinned-revocable) pushes all importers towards bounded revoke.
- **API ergonomics.** Verbs is a specialist API (QPs, keys, CM). Devmem uses sockets plus cmsgs. zcrx uses io_uring. Libraries such as NCCL plugins hide the differences, which is why all three coexist.

## How It Has Evolved

- **2013–2021** — GPUDirect RDMA via NVIDIA's out-of-tree `nv_peer_mem`/`nvidia-peermem` peer-memory client (never upstreamed)
- **5.12 (2021)** — RDMA dma-buf MRs, the upstream path for GPUDirect RDMA; NVIDIA open kernel modules export dma-bufs
- **2022–2023** — Google proposes device memory TCP (LPC 2022, RFCs 2023); GPUDirect-TCPX deployed on A3 VMs
- **6.12 (2024)** — devmem TCP RX upstream
- **6.15–6.16 (2025)** — io_uring zcrx; dma-buf areas; devmem TX
- **2026** — dma-buf revocation semantics; RDMA dma-buf export and pinned-revocable import; zcrx events and multi-area; netkit queue leasing brings devmem and zcrx into Kubernetes pods

## Further Reading

- NVIDIA — [GPUDirect RDMA documentation](https://docs.nvidia.com/cuda/gpudirect-rdma/index.html); [GPU Operator: GPUDirect RDMA and Storage](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/24.6.2/gpu-operator-rdma.html)
- kernel.org — [Device Memory TCP](https://docs.kernel.org/networking/devmem.html); [io_uring zero copy Rx](https://docs.kernel.org/networking/iou-zcrx.html)
- LWN — [Direct-to-device networking](https://lwn.net/Articles/979549/); [RDMA: Add dma-buf support](https://lwn.net/Articles/836484/)
- Google — [NCCL GPUDirect-TCPX plugin](https://github.com/google/nccl-plugin-gpudirecttcpx); [GPUDirect-TCPXO on A3 Mega](https://docs.cloud.google.com/cluster-toolkit/docs/machine-learning/a3-mega-enable-gpudirect-tcpxo)
- Troubleshooting — [Debug GPUDirect RDMA across ACS, IOMMU, and PCIe topology](https://oneuptime.com/blog/post/2026-08-14-gpudirect-rdma-acs-iommu-topology/view)
- Related: [[devmem-tcp]], [[zero-copy-rx-zcrx]], [[memory-registration-and-ib-umem]], [[dma-buf-sharing]], [[io-uring-vs-rdma]]

## LKML Highlights

- **`<1604616489-69267-1-git-send-email-jianxin.xiong@intel.com>`** — RDMA dma-buf support, the upstream replacement for peer-memory hacks, and the foundation of modern GPUDirect RDMA on Linux.
- **Device Memory TCP (Mina Almasry, 2023–24)** — the argument that TCP with header split can deliver device-to-device transfers on commodity NICs. Review established unreadable skbs and netmem instead of fake struct pages for GPU memory.
- **io_uring zcrx dma-buf areas (Pavel Begunkov / David Wei, 2025)** — extended zcrx to device memory using the same provider framework, giving io_uring applications devmem-equivalent GPU receive with ring-based buffer return.
