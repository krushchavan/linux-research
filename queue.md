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
- [ ] mm -> memory-cgroup

# --- Unresolved links from vfs-locking-model 2026-04-11 ---
- [ ] subsystem: locking

# --- Unresolved links from numa-memory-policy 2026-04-12 ---
- [ ] subsystem: scheduler

# --- Unresolved links from io-uring-internals 2026-04-12 ---
- [ ] subsystem: net
- [ ] subsystem: security

# --- Unresolved links from extended-attributes-and-acls 2026-04-12 ---
- [ ] subsystem: fscrypt
- [ ] subsystem: overlayfs

# --- Unresolved links from nfs-fscache 2026-04-12 ---
- [ ] subsystem: fscache
- [ ] subsystem: netfs

# --- Unresolved links from netfilter 2026-04-13 ---
- [ ] subsystem: bpf

