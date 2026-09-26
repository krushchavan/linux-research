# Linux Kernel Research Queue
# ════════════════════════════════════════════════════════════════════
#
# FORMAT
# ──────────────────────────────────────────────────────────────────
#   - [ ] topic                   Research a specific concept or topic
#   - [ ] subsystem: name         Deep-dive a whole subsystem
#   - [ ] subsystem -> topic      Research one topic within a subsystem
#   - [ ] subsystem -> *          Expand ALL topics under a subsystem
#   - [ ] patch: <message-id>     Analyse a specific LKML patch/thread
#   - [ ] person: Full Name       Profile a kernel contributor
#   - [>] topic                   In-progress — managed by agent, do not edit
#   - [x] topic                   Completed
#
# WILDCARD EXPANSION  (-> *)
# ──────────────────────────────────────────────────────────────────
#   When the agent encounters `subsystem -> *` it fetches the topic
#   list from kernel-internals.org and expands it inline into
#   individual `- [ ] subsystem -> topic` entries, then processes
#   them one per scheduled run.
#
#   Supported subsystems for wildcard expansion:
#     mm, sched, net, fs, locking, bpf, virt, security,
#     block, ipc, power, tracing, arch/arm64, arch/x86
#
# EXAMPLES
# ──────────────────────────────────────────────────────────────────
#   - [ ] mm -> *
#   - [ ] sched -> CFS
#   - [ ] io_uring internals
#   - [ ] locking -> RCU
#   - [ ] patch: 20251111105634.1684751-1-lzampier@redhat.com
#   - [ ] person: Linus Torvalds
#
# HOW THE AGENT PROCESSES THIS FILE
# ──────────────────────────────────────────────────────────────────
#   1. Resume any [>] item first (crashed or token-limited last run)
#   2. Pick the first [ ] item
#   3. If it is a wildcard (-> *), expand it into individual entries
#      and pick the first expanded entry
#   4. Mark the item [>] and set note status: in-progress
#   5. Research the topic fully
#   6. Mark the item [x] and set note status: complete
#   7. Commit and push
#
# ════════════════════════════════════════════════════════════════════

## Queue

- [x] mm -> Core Components
- [x] subsystem: fs --refresh
- [x] subsystem: vfs --refresh
- [x] subsystem: nfs
- [x] subsystem: btrfs

# --- Unresolved wiki links (auto-queued) ---

# mm concepts
- [x] mm -> page-reclaim
- [x] mm -> swap
- [x] mm -> transparent-huge-pages
- [x] mm -> address-space

# fs / vfs concepts
- [x] fs -> dentry
- [x] fs -> dentry-cache
- [x] fs -> inode-cache
- [x] fs -> file-object
- [x] fs -> filesystem-registration
- [x] fs -> path-lookup
- [x] fs -> mount-namespace
- [x] fs -> writeback-infrastructure
- [x] fs -> fsnotify
- [x] fs -> core-in-memory-structures

# btrfs concepts
- [x] btrfs -> multiple-b-trees
- [x] btrfs -> subvolumes-and-snapshots
- [x] btrfs -> transaction-model
- [x] btrfs -> raid-and-multi-device-support
- [x] btrfs -> checksumming-and-data-integrity

# fuse
- [x] subsystem: fuse
- [x] fuse -> *

# thp unresolved links
- [x] mm -> memory-compaction

# page-reclaim unresolved links
- [x] subsystem: block
- [x] subsystem: memcg

# nfs concepts
- [x] nfs -> nfs-client
- [x] nfs -> nfs-server
- [x] nfs -> nfsv4.1-sessions
- [x] nfs -> pnfs
- [x] nfs -> nfs-localio
- [x] nfs -> sunrpc
- [x] nfs -> xdr-encoding

# --- Gap-fill: identified from cross-reference crawl 2026-04-06 ---

# Round 1 — Foundation (unblocks everything else)
- [x] locking -> RCU read-copy-update
- [x] fuse -> fuse-connection
- [x] fuse -> fuse-request-queue
- [x] fuse -> fuse-wire-protocol
- [x] fuse -> fuse-vfs-integration
- [x] mm -> xarray

# Round 2 — MM depth
- [x] mm -> rmap-reverse-mapping
- [x] mm -> oom-killer
- [x] mm -> page-table-management
- [x] locking -> seqlocks-and-memory-barriers

# Round 3 — FS/VFS depth
- [x] fs -> vfs-locking-model
- [x] fs -> file-descriptor-and-open-file-table

# Round 4 — Btrfs + NFS depth
- [x] btrfs -> space-accounting-and-block-groups
- [x] btrfs -> balance-and-device-management
- [x] nfs -> delegations-and-locking
- [x] nfs -> rpcsec-gss-and-kerberos

# Round 5 — MEDIUM: MM + io_uring
- [x] mm -> get-user-pages-and-pinning
- [x] mm -> huge-pages-hugetlbfs
- [x] mm -> numa-memory-policy
- [x] io_uring internals

# Round 6 — LOW priority
- [x] fs -> extended-attributes-and-acls
- [x] fs -> inotify-and-fanotify
- [x] btrfs -> send-receive-protocol
- [x] btrfs -> qgroups
- [x] nfs -> fscache

# --- Unresolved links from rcu-read-copy-update 2026-04-06 ---
- [x] locking -> interrupt-handling
- [x] locking -> per-cpu-variables
- [x] locking -> dyntick-idle
- [x] subsystem: netfilter

# --- Unresolved links from xarray 2026-04-10 ---
- [x] mm -> radix-tree

# --- Unresolved links from oom-killer 2026-04-10 ---
- [x] mm -> memory-cgroup

# --- Unresolved links from vfs-locking-model 2026-04-11 ---
- [x] subsystem: locking

# --- Unresolved links from numa-memory-policy 2026-04-12 ---
- [x] subsystem: scheduler

# --- Unresolved links from io-uring-internals 2026-04-12 ---
- [x] subsystem: net
- [x] subsystem: security

# --- Unresolved links from extended-attributes-and-acls 2026-04-12 ---
- [x] subsystem: fscrypt
- [x] subsystem: overlayfs

# --- Unresolved links from nfs-fscache 2026-04-12 ---
- [x] subsystem: fscache
- [x] subsystem: netfs

# --- Unresolved links from netfilter 2026-04-13 ---
- [x] subsystem: bpf

# --- Unresolved links from memory-cgroup 2026-04-13 ---
- [x] mm -> folio
- [x] mm -> psi-pressure-stall-information

# --- Unresolved links from scheduler 2026-04-13 ---
- [x] subsystem: cgroups
- [x] scheduler -> preemption-model
- [x] scheduler -> pi-mutexes

# --- Unresolved links from security 2026-04-15 ---
- [x] subsystem: smack
- [x] security -> user-namespaces
- [x] security -> process-model

# --- Unresolved links from fscrypt 2026-04-15 ---
- [x] kernel-crypto-api
- [x] kernel-keyring

# --- Unresolved links from fscache 2026-04-15 ---
- [x] concept: network-filesystems overview

# --- Unresolved links from bpf 2026-04-16 ---
- [x] subsystem: tracing

# --- Unresolved links from smack 2026-04-16 ---
- [x] subsystem: netlabel
- [x] concept: securityfs

# --- Unresolved links from kernel-crypto-api 2026-04-17 ---
- [x] subsystem: dm-crypt

# --- Unresolved links from securityfs 2026-04-17 ---
- [x] concept: ima
- [x] concept: tpm

# --- Unresolved links from dm-crypt 2026-04-18 ---
- [x] subsystem: dm-integrity
- [x] subsystem: device-mapper

# --- Unresolved links from dm-integrity 2026-04-18 ---
- [x] concept: dm-bufio


# --- Added by request 2026-09-24 ---
- [x] subsystem: io_uring

# --- Unresolved links from io_uring 2026-09-24 ---
- [x] subsystem: ublk
- [x] net -> page-pool

# --- Unresolved links from ublk 2026-09-24 ---
- [x] block -> blk-mq
- [x] mm -> maple-tree

# --- Unresolved links from page-pool 2026-09-24 ---
- [x] net -> xdp
- [x] net -> devmem-tcp
- [x] concept: dma-mapping-api

# --- Unresolved links from blk-mq 2026-09-25 ---
- [x] block -> bio-layer
- [x] block -> io-scheduler

# --- Unresolved links from xdp 2026-09-25 ---
- [x] net -> af-xdp

# --- Unresolved links from bio-layer 2026-09-25 ---
- [x] fs -> iomap

# --- Unresolved links from io-scheduler 2026-09-25 ---
- [x] block -> zoned-block-devices

# --- Empty source notes found by explain-kernel 2026-09-25 (files exist but are 0 bytes) ---
- [x] btrfs -> cow-b-tree-engine
- [x] fs -> inode
- [x] fs -> superblock

# --- RDMA and kernel-bypass I/O vs io_uring (requested 2026-09-26) ---
# Foundations: the RDMA subsystem and its core mechanisms
- [x] subsystem: rdma
- [x] rdma -> verbs-api-and-uverbs
- [x] rdma -> memory-registration-and-ib-umem
- [x] rdma -> on-demand-paging-odp
- [x] rdma -> queue-pairs-and-completion-queues
- [x] rdma -> rdma-cm-connection-manager
- [x] rdma -> roce-v1-and-v2
- [x] rdma -> roce-gid-table-and-netdev-binding
- [x] rdma -> roce-congestion-control-pfc-ecn-dcqcn
- [x] rdma -> iwarp-transport
- [x] rdma -> soft-rdma-rxe-and-siw
# RDMA consumers inside the kernel
- [x] nvme -> nvme-over-fabrics-rdma-and-tcp
- [x] nfs -> nfs-over-rdma-svcrdma-xprtrdma
- [x] net -> smc-r-shared-memory-communications
# Zero-copy / peer-to-peer building blocks shared with io_uring
- [x] mm -> p2pdma-peer-to-peer-dma
- [x] dma -> dma-buf-sharing
- [x] io_uring -> zero-copy-rx-zcrx
# Device memory TCP (devmem) deep dives
- [x] net -> netmem-and-net-iov-abstraction
- [x] net -> devmem-tcp-rx-dmabuf-binding-and-token-recycling
- [x] net -> devmem-tcp-tx
- [x] net -> header-split-and-flow-steering-for-zero-copy-rx
- [x] net -> netdev-queue-management-api
- [x] net -> netdev-netlink-family
# Comparisons
- [x] io_uring vs RDMA: completion models, memory registration, and zero-copy compared
- [x] devmem TCP vs RDMA GPUDirect vs io_uring zcrx: moving data straight to accelerator memory
- [x] kernel-bypass comparison: io_uring vs RDMA vs AF_XDP vs DPDK vs SPDK
- [x] polling vs interrupts: io_uring SQPOLL/IOPOLL, NAPI busy-poll, and RDMA CQ polling

# --- Cross-framework comparisons (requested 2026-09-26) ---
- [x] comparison: zero-copy buffer ownership and return protocols (AF_XDP fill ring, zcrx refill ring, devmem tokens, provided buffer rings, RDMA SRQ) + zero-copy send paths
- [x] comparison: memory pinning and registration strategies (GUP pinning, io_uring registered buffers, RDMA MR, ODP, dma-buf attach modes, zcrx areas, AF_XDP UMEM)
- [x] comparison: RDMA transports (InfiniBand vs RoCE vs iWARP vs EFA SRD vs Ultra Ethernet)
- [x] comparison: storage fabrics (NVMe/RDMA vs NVMe/TCP vs iSER/iSCSI vs NVMe/FC vs NFS over RDMA, kernel vs SPDK targets)
- [ ] scsi -> iscsi-iser-and-lio-target
- [ ] nvme -> nvme-over-fibre-channel
