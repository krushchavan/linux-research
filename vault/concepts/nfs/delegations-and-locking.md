---
title: "NFS Delegations and Locking"
category: concept
tags: [nfs, nfsv4, delegations, locking, stateid, cache-coherency]
subsystem: nfs
kernel_version: "2.6.22"
researched: 2026-04-11
status: complete
sources:
  - https://lwn.net/Articles/898262/
  - https://lwn.net/Articles/560080/
  - https://lwn.net/Articles/965661/
  - https://wiki.linux-nfs.org/wiki/index.php/Cluster_Coherent_NFSv4_and_Delegations
  - https://wiki.linux-nfs.org/wiki/index.php/Cluster_Coherent_NFS_and_Byte_Range_Locking
  - https://docs.huihoo.com/doxygen/linux/kernel/3.7/delegation_8c_source.html
  - https://github.com/torvalds/linux/blob/master/fs/nfs/nfs4_fs.h
  - https://docs.kernel.org/filesystems/nfs/nfs41-server.html
  - https://lore.kernel.org/all/CAM5tNy4sUR3TseB5g8Ce3T1-hVLOhvBAKhnbeVxv-WK5Ztue9g@mail.gmail.com/
---

# NFS Delegations and Locking

## Purpose

NFSv3 and earlier had no notion of server-granted exclusive access: every client had to poll the server with GETATTR on each open to check whether another client had modified the file, generating constant network traffic even on uncontested files. NFSv4 addresses this with **delegations** — a server-issued promise that a client can cache a file aggressively because the server will notify (recall) the delegation before allowing any conflicting access. Delegations also subsume byte-range locking: while a delegation is held, the client manages locks entirely locally, without talking to the server. Separately, NFSv4 replaces the fragile out-of-band NLM (Network Lock Manager) protocol used by NFSv3 with in-protocol stateful byte-range locking, giving the server full visibility and allowing clean crash recovery.

## Mental Model

Think of a delegation as a **checked-out lease on a file**: the server hands the client a stateid and says "you own this file for now — serve opens, reads, and locks from your cache, and I'll call you before I give anyone else access." The client is free to accumulate dirty pages, local lock state, and even new open references without touching the server. The server maintains its end by blocking any conflicting access until the delegation is returned. For byte-range locking without a delegation, the model is simpler: every LOCK/LOCKU is a synchronous RPC, and the server tracks all lock state under the client's lease, ready to reclaim it cleanly if the server reboots.

## How It Works

### Delegation Grant

Delegations are granted at file OPEN time. The server includes a `DELEGATION` result in the OPEN compound reply, carrying a `stateid` and a type — `OPEN_DELEGATE_READ` or `OPEN_DELEGATE_WRITE`. The client's NFS code absorbs this via `nfs_inode_set_delegation()` in `fs/nfs/delegation.c`. It allocates an `nfs_delegation` and links it into the inode:

```c
/* simplified from fs/nfs/delegation.c */
struct nfs_delegation {
    struct list_head super_list;   /* per-server list of all delegations */
    const struct cred *cred;       /* credentials used to hold delegation */
    struct inode *inode;           /* associated inode */
    nfs4_stateid stateid;          /* stateid returned by server */
    fmode_t type;                  /* FMODE_READ or FMODE_WRITE */
    unsigned long pagemod_limit;   /* max dirty pages before flush */
    unsigned long flags;           /* NFS_DELEGATION_RETURN, _REFERENCED, etc. */
    spinlock_t lock;
    struct rcu_head rcu;
};
```

Once the delegation is installed, `nfs_inode` records it:

```c
struct nfs_inode {
    ...
    struct nfs_delegation __rcu *delegation; /* NULL if none held */
    fmode_t         delegation_state;        /* R/W/RW */
    ...
};
```

With a read delegation in hand the client knows: no other client will write this file. It can serve subsequent OPEN calls locally, skip GETATTR revalidation, and omit per-lock notifications to the server entirely. With a write delegation (theoretical — the Linux NFSD never grants them in practice) the client would additionally be free to serve other clients' read opens locally.

### Delegation Use: Local State and Implicit Locks

While a read delegation is held, `nfs4_state` tracks any byte-range locks the process has acquired:

```c
struct nfs4_state {
    struct nfs4_state_owner *owner;   /* open-owner: cred + seqid sequencing */
    struct inode            *inode;
    nfs4_stateid             stateid;      /* current effective stateid */
    nfs4_stateid             open_stateid; /* explicit OPEN stateid */
    unsigned int             n_rdonly, n_wronly, n_rdwr; /* access refcounts */
    fmode_t                  state;        /* actual R/W/RW on server */
    spinlock_t               state_lock;   /* protects lock_states */
    seqlock_t                seqlock;      /* protects stateid / open_stateid */
    struct list_head         lock_states;  /* list of nfs4_lock_state */
};
```

Each byte-range lock is represented by an `nfs4_lock_state`:

```c
struct nfs4_lock_state {
    struct nfs4_state   *ls_state;    /* parent open state */
    nfs4_stateid         ls_stateid;  /* lock stateid from server */
    struct nfs_seqid_counter ls_seqid;
    fl_owner_t           ls_owner;   /* POSIX lock owner (process/OFD) */
    unsigned long        ls_flags;   /* LOCK_INITIALIZED, LOCK_LOST, etc. */
};
```

While the delegation is current, any LOCK or LOCKU the application issues is cached locally in the `lock_states` list — the server sees nothing. This is why `nfs_reclaim_locks()` bails out immediately if a delegation is held: there is nothing to reclaim, because no lock RPCs were ever sent.

### Delegation Recall

When a second client opens the file for write, the NFSD cannot grant that access while a read delegation is outstanding. It issues a `CB_RECALL` callback over the backchannel (NFSv4.1) or a dedicated callback connection (NFSv4.0) to the delegation holder.

On receipt, the client's callback thread invokes `nfs_async_inode_return_delegation()`, which sets `NFS_DELEGATION_RETURN` in the delegation's flags and schedules a workqueue task to drive the full return sequence:

1. **Flush dirty pages** — any cached writes must reach the server before the stateid is relinquished.
2. **Reclaim open state** — `nfs_delegation_claim_opens()` walks every `nfs4_state` that relied on the delegation stateid and issues explicit OPEN RPCs to recover the open_stateid. This is necessary because the delegation stateid was substituting for the open stateid during the delegation period.
3. **Reclaim lock state** — `nfs_delegation_claim_locks()` walks the `lock_states` list for each recovered state and sends LOCK RPCs to register each byte-range lock with the server. Only after this does the server have visibility into what the client has been holding.
4. **Send DELEGRETURN** — `nfs4_proc_delegreturn()` in `fs/nfs/nfs4proc.c` sends the DELEGRETURN RPC, passing the delegation stateid. The server acknowledges and destroys the delegation.
5. **Free the structure** — the `nfs_delegation` is unlinked from `nfs_inode` and freed asynchronously via RCU to avoid races with concurrent readers.

Meanwhile the server returns `NFS4ERR_DELAY` to the conflicting client's OPEN until the DELEGRETURN arrives.

VFS lease infrastructure mediates the recall when delegations interact with local access. Delegations register themselves as `FL_DELEG` leases on the inode. If any local operation (e.g. a directio write) would conflict, `break_lease()` fires the `lm_break` callback on the registered `lock_manager_operations`, which triggers the same return sequence.

### Delegation Expiry and Other Return Paths

Beyond server-initiated recall, delegations are returned in several other situations:

- **Lease expiry** — NFSv4 leases must be renewed every `lease_time` seconds. If the client fails to renew (network partition, client crash), the server drops all client state after the grace window. When the client recovers, it discovers the delegation is gone via `NFS4ERR_EXPIRED` or `NFS4ERR_BAD_STATEID`. `nfs_expire_all_delegations()` handles mass expiry during recovery.
- **Unmount** — `nfs_inode_return_delegation_noreclaim()` returns all delegations without reclaiming lock state (the mount is going away).
- **Memory pressure** — `nfs_expire_unreferenced_delegations()` reclaims delegations no longer referenced by open files.
- **Proactive return before mutation** — the client's VFS hooks (e.g. `nfs_setattr`, `vfs_unlink`) check for an outstanding delegation and return it proactively before issuing the conflicting operation. This avoids a round-trip where the server would recall and then the client would immediately return.

**Same-client optimisation**: Linux NFSD detects when the client causing the conflict is the same client that holds the delegation. In that case it skips the CB_RECALL entirely, relying on the client to handle the conflict locally — a pragmatic optimisation that avoids a full recall/return round-trip for patterns like `open("foo"); unlink("foo"); write(fd); close(fd);`.

### Byte-Range Locking Without a Delegation

When no delegation is held, byte-range locking is a fully networked operation. The client sends:

- **LOCK** — acquires a shared (READ) or exclusive (WRITE) byte-range lock. If the lock state is new, the first LOCK request includes the open_stateid so the server can associate the lock with the correct open. The server returns a `lock_stateid`, which becomes the lock's identity.
- **LOCKT** — tests whether a byte range is already locked by another client, without acquiring anything.
- **LOCKU** — releases all or part of a lock range, returning an updated `lock_stateid`.

A critical protocol difference from POSIX: **NFSv4 byte-range locks are non-blocking at the protocol level**. The server returns `NFS4ERR_LOCK_DENIED` immediately if the range is contested. The client must retry. This means remote clients compete poorly against local processes and other NFSv4 clients sharing the same `fl_block` queue, which orders all competing requesters in FIFO. To avoid a client disappearing mid-wait (taking a provisional lock nobody can ever grant), the implementation uses provisional locks that supersede ordinary contending requests but can be revoked if the client stops polling.

NFSv4.1 partially addresses this by adding a CANCEL mechanism, allowing a client to withdraw a pending lock request rather than just abandoning the poll.

### Lock Recovery After Server Restart

When the NFS server reboots, it enters a **grace period** (default 90 seconds). During this window it accepts only RECLAIM (i.e. re-acquire previously held state) operations, not fresh lock requests, allowing legitimate clients to recover their locks before anyone else can steal them.

The client detects the restart when it receives `NFS4ERR_STALE_CLIENTID` or finds its TCP connection reset. Recovery proceeds:

1. Re-establish client ID — `nfs4_proc_setclientid()` and `SETCLIENTID_CONFIRM`.
2. Reclaim open state — `nfs4_proc_open_confirm()` for each previously open file using the `CLAIM_PREVIOUS` claim type.
3. Reclaim lock state — LOCK with `reclaim=true` for each previously held lock.
4. In NFSv4.1, send `RECLAIM_COMPLETE` so the server can exit the grace period early once all clients are done.

If a client fails to complete reclaim before the grace period ends, the server returns `NFS4ERR_NO_GRACE` and the client must surface `EIO` or `EBADF` to applications — the locks are simply lost.

Lease expiry (client fails to renew in time) is handled similarly on the client side: `nfs4_state_manager()` in `fs/nfs/nfs4state.c` drives the recovery state machine, transitioning states from `NFS4CLNT_CHECK_LEASE` through `NFS4CLNT_RECLAIM_REBOOT` or `NFS4CLNT_RECLAIM_NOGRACE`.

## Key Data Structures

**`struct nfs_delegation`** (`fs/nfs/delegation.h`) — per-inode delegation object on the client.
- `stateid` — the 16-byte stateid received from the server; passed back in DELEGRETURN.
- `type` — `FMODE_READ` or `FMODE_WRITE`; determines what operations are locally serviced.
- `flags` — `NFS_DELEGATION_RETURN` (recall pending), `NFS_DELEGATION_REFERENCED` (touched since last GC), `NFS_DELEGATION_INODE_FREEING` (inode is being dropped).
- `cred` — credentials tied to the delegation; used when sending DELEGRETURN.

**`struct nfs4_state`** (`fs/nfs/nfs4_fs.h`) — client-side per-(owner, inode) open state.
- `stateid` / `open_stateid` — effective stateid (may be delegation stateid while delegation is current) and explicit OPEN stateid.
- `lock_states` — list of `nfs4_lock_state`, one per lock owner.
- `seqlock` — protects concurrent stateid updates (callback vs. RPC reply races).

**`struct nfs4_lock_state`** (`fs/nfs/nfs4_fs.h`) — per-lock-owner byte-range lock state.
- `ls_stateid` — the lock stateid; must be passed in LOCK/LOCKU operations.
- `ls_owner` — identifies the POSIX process (or OFD) holding the lock.
- `ls_flags` — `NFS_LOCK_INITIALIZED` (server-acknowledged), `NFS_LOCK_LOST` (lease expired).

**`struct nfs4_state_owner`** (`fs/nfs/nfs4_fs.h`) — per-open-owner seqid sequencing context.
- `so_seqid` — serialises compound calls for a given open-owner to prevent seqid gaps.
- `so_states` — list of all `nfs4_state` belonging to this owner.

## Key Functions / Entry Points

**`nfs_inode_set_delegation()`** (`fs/nfs/delegation.c`) — called from `nfs4_opendata_get_inode()` after OPEN reply; allocates and installs the delegation.

**`nfs_async_inode_return_delegation()`** (`fs/nfs/delegation.c`) — called from callback handler (CB_RECALL); marks the delegation for return and schedules the workqueue task.

**`nfs4_proc_delegreturn()`** (`fs/nfs/nfs4proc.c`) — issues the DELEGRETURN RPC; called from the delegation return workqueue.

**`nfs_delegation_claim_opens()`** (`fs/nfs/delegation.c`) — reclaims open state from the server during recall; walks all `nfs4_state` objects referencing the delegation.

**`nfs_delegation_claim_locks()`** (`fs/nfs/delegation.c`) — sends LOCK RPCs to re-register byte-range locks after delegation recall; populates `ls_stateid` for each `nfs4_lock_state`.

**`nfs4_state_manager()`** (`fs/nfs/nfs4state.c`) — the recovery state machine; drives reboot reclaim, lease renewal, and state re-establishment.

**`break_lease()`** (`fs/locks.c`) — VFS hook; fires the `lm_break` callback on FL_DELEG leases when local access would conflict, triggering delegation return.

## Important Flags & Config Options

**`/proc/sys/fs/nfs/nfs_congestion_kb`** — not directly delegation-related, but influences when the client throttles writeback before returning a delegation.

**`nfs.enable_ino64`** — no delegation effect, but inode numbering affects delegation coherency checks.

**`/proc/fs/nfsd/nfsv4gracetime`** — controls the grace period (seconds) the server waits for clients to reclaim state after a reboot. Shortening it risks clients losing locks; lengthening it delays availability after restart.

**`/proc/fs/nfsd/nfsv4leasetime`** — lease duration in seconds. Delegations are held only as long as the lease is renewed. Shorter leases recover state faster after client crashes but increase renewal traffic.

**`CONFIG_NFS_V4`** — must be enabled for NFSv4 delegation and in-protocol locking. Without it the kernel falls back to NFSv3 + NLM.

## Interactions with Other Subsystems

- **↑ Userspace**: Applications see no difference — `open(2)`, `read(2)`, `write(2)`, `fcntl(2)` LOCK all work normally. The delegation machinery is entirely transparent; performance is the only observable signal.
- **→ [[VFS Locking Model]]**: Delegations are implemented as `FL_DELEG` leases in the VFS file-lock layer. `setlease()`, `getlease()`, and `break_lease()` coordinate delegation lifecycle with the local lock table. The VFS `lock_manager_operations` struct's `lm_break` callback is the hook the NFS client registers.
- **→ [[SunRPC]]**: All LOCK, LOCKU, LOCKT, DELEGRETURN, and CB_RECALL RPCs flow through the SunRPC layer. NFSv4.1 CB_RECALL travels on the session backchannel, which is the reverse direction of the same TCP connection used for client requests.
- **→ [[NFSv4.1 Sessions]]**: Sessions provide exactly-once semantics for LOCK operations, eliminating the duplicate-request ambiguity that plagued NFSv4.0. The backchannel within the session carries CB_RECALL, removing the need for a separate callback connection.
- **← Page Cache**: Delegation return requires flushing dirty pages via `nfs_wb_all()` before DELEGRETURN is sent, coupling delegation lifecycle tightly to writeback.
- **← [[NFS Server]]**: NFSD maintains the server-side delegation table in `nfs4state.c`. It tracks which client holds which delegation for which inode and manages the CB_RECALL flow.

## Design Decisions & Tradeoffs

**Read delegations only on Linux NFSD**: The Linux server deliberately never grants write delegations. Write delegations require the server to refuse all other clients' reads, which demands a fully reliable callback channel — if the client is unreachable, the server is stuck blocking reads indefinitely. The Linux maintainers decided the operational risk outweighed the benefit, since write workloads accessing the same file from multiple clients are relatively rare.

**Non-blocking lock protocol**: NFSv4 byte-range locks are non-blocking at the RPC level. This avoids server-side blocking but requires the client to poll, which creates fairness problems relative to local processes sharing the same inode via POSIX locks. The provisional-lock mechanism and the `fl_block` FIFO queue are an attempt to restore fairness, but the fundamental limitation is the protocol's absence of a server-push grant notification. NFSv4.1 adds CANCEL to let clients withdraw gracefully, but still lacks a server-pushed GRANT.

**Delegation vs. lease dualism**: A delegation stateid substitutes for the open stateid while it is current. This means the client uses one stateid for both open access and cache coherency, simplifying the state machine at the cost of a more complex recall sequence (opens must be individually reclaimed when the delegation falls). The seqlock on `nfs4_state` guards against races between callback delivery and concurrent RPC replies updating the stateid.

**Same-client skip optimisation**: When the client causing a delegation conflict is the same client holding the delegation, Linux NFSD skips CB_RECALL. This is an implementation choice not mandated by RFC 8881, but it meaningfully reduces overhead for common patterns (write-then-delete temporaries). The tradeoff is that a delegation whose file has been removed persists until the client does DELEGRETURN explicitly, holding the inode in memory with nlinks=0.

## How It Has Evolved

- **NFSv4.0 (2000, RFC 3530)**: Introduced delegations and in-protocol byte-range locking. Delegations used a separate callback connection; establishing it reliably was fragile behind NAT.
- **NFSv4.1 (2010, RFC 5661)**: Sessions with a backchannel replaced the separate callback connection, making CB_RECALL far more reliable. Added RECLAIM_COMPLETE for faster grace-period exit. Added CANCEL for locking.
- **Directory delegations (~2013, take 9–11)**: A long-running patch series (nine iterations by 2013) attempted to add directory delegations (GET_DIR_DELEGATION), allowing clients to cache directory contents without polling. The `FL_DELEG` flag and `struct inode **` plumbing in `fs/namei.c` come from this era.
- **Directory delegations shipped (2023–2024, RFC 8881)**: After nearly a decade of iteration, VFS-side directory delegation breaks (`try_break_deleg` in `vfs_link`, `vfs_rename`, `vfs_unlink`) landed in the kernel, enabling GET_DIR_DELEGATION in NFSD for lookup-heavy workloads.
- **Ongoing**: Delegation state recovery races between concurrent OPEN and DELEGRETURN have been fixed repeatedly (e.g. linux 4.2, 4.19 stable backports). The interplay between delegation stateids and open stateids remains an active source of subtle bugs.

## Further Reading

1. [NFS: the new millennium — LWN.net](https://lwn.net/Articles/898262/) — excellent overview of NFSv4 state model including stateids and delegations.
2. [Implement NFSv4 delegations, take 9 — LWN.net](https://lwn.net/Articles/560080/) — deep dive into the delegation recall implementation challenge (lock ordering, inode ** threading).
3. [vfs, nfsd, nfs: implement directory delegations — LWN.net](https://lwn.net/Articles/965661/) — covers GET_DIR_DELEGATION and VFS break hooks.
4. [Cluster Coherent NFSv4 and Byte Range Locking — linux-nfs.org](https://wiki.linux-nfs.org/wiki/index.php/Cluster_Coherent_NFS_and_Byte_Range_Locking) — detailed analysis of fairness problems and provisional lock design.
5. [Cluster Coherent NFSv4 and Delegations — linux-nfs.org](https://wiki.linux-nfs.org/wiki/index.php/Cluster_Coherent_NFSv4_and_Delegations) — delegation protocol mechanics and VFS integration.
6. [NFSv4.1 Server Implementation — kernel.org](https://docs.kernel.org/filesystems/nfs/nfs41-server.html) — conformance table showing which operations are implemented.
7. RFC 8881 — NFSv4.1 specification; sections 10 (client-side state), 18.10–18.12 (LOCK/LOCKT/LOCKU), 18.6 (DELEGRETURN).

## LKML Highlights

> **Thread: "simple NFSv4.1/4.2 test of remove while holding a delegation" (Jun 2025)**
> Message-ID: `CAM5tNy4sUR3TseB5g8Ce3T1-hVLOhvBAKhnbeVxv-WK5Ztue9g@mail.gmail.com`
> Rick Macklem discovers that Linux NFSD skips CB_RECALL when the same client causes a delegation conflict (e.g. REMOVE while holding a write delegation). Jeff Layton explains the underlying VFS invariant: the delegation holds an inode reference, so the file persists in-core with nlinks=0 until DELEGRETURN, making the filehandle valid even after unlink. Reveals a live design debate about whether NFS4ERR_STALE should be returned after REMOVE completes.

> **Series: "Implement NFSv4 delegations, take 9" (2013)**
> Message-ID: `560080` (LWN)
> The ninth iteration of directory-delegation support. Key insight: dropping inode locks before waiting for delegation breaks (rather than waiting under the lock) prevents deadlocks with unresponsive clients. Introduced `struct inode **` threading through VFS path functions so callers can pass `NULL` to prefer failure over blocking — a pattern that propagated throughout `fs/namei.c`.
