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
- [ ] fs -> path-lookup
- [ ] fs -> mount-namespace
- [ ] fs -> writeback-infrastructure
- [ ] fs -> fsnotify
- [ ] fs -> core-in-memory-structures

# btrfs concepts
- [ ] btrfs -> multiple-b-trees
- [ ] btrfs -> subvolumes-and-snapshots
- [ ] btrfs -> transaction-model
- [ ] btrfs -> raid-and-multi-device-support
- [ ] btrfs -> checksumming-and-data-integrity

# fuse
- [ ] subsystem: fuse
- [ ] fuse -> *

# thp unresolved links
- [ ] mm -> memory-compaction

# page-reclaim unresolved links
- [ ] subsystem: block
- [ ] subsystem: memcg

# nfs concepts
- [ ] nfs -> nfs-client
- [ ] nfs -> nfs-server
- [ ] nfs -> nfsv4.1-sessions
- [ ] nfs -> pnfs
- [ ] nfs -> nfs-localio
- [ ] nfs -> sunrpc
- [ ] nfs -> xdr-encoding


