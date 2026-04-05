---
title: "SunRPC (kernel RPC layer)"
category: concept
tags: [nfs, rpc, sunrpc, transport, xdr, authentication]
subsystem: nfs
kernel_version: "2.0"
researched: 2026-04-05
status: complete
sources:
  - https://github.com/torvalds/linux/blob/master/net/sunrpc/clnt.c
  - https://github.com/torvalds/linux/blob/master/net/sunrpc/xprt.c
  - https://github.com/torvalds/linux/blob/master/include/linux/sunrpc/xprt.h
  - https://www.kernel.org/doc/html/latest/filesystems/nfs/rpc-cache.html
  - https://docs.kernel.org/admin-guide/sysctl/sunrpc.html
---

# SunRPC (kernel RPC layer)

## Purpose

SunRPC (`net/sunrpc/`) is the kernel's implementation of the Sun Remote Procedure Call protocol (RFC 5531, formerly RFC 1831). It provides the transport and authentication plumbing used by NFS (client and server), NLM (Network Lock Manager), NSM (Network Status Monitor), and rpcbind. Rather than each network filesystem reimplementing socket management, retransmission, backoff, and authentication, all of this is centralised in the sunrpc layer. Keeping it in-kernel avoids context switches that a user-space RPC daemon would require on every request.

## Mental Model

SunRPC is a **typed, reliable call/reply protocol on top of UDP or TCP**. Think of it as a lightweight function-call dispatcher: the caller specifies a program number, version, procedure number, and arguments; the framework handles serialisation (XDR), transport, retransmission on timeout, and authentication verification; and the caller gets back a result or an error. The kernel's async design means "calling" an RPC allocates a `rpc_task` — a state-machine work unit — rather than blocking a thread, allowing many RPCs to be in-flight simultaneously.

## How It Works

### The three-tier object model

```
rpc_clnt          — logical client; one per (server addr, program, version, auth flavour)
  └── rpc_xprt   — transport; one per physical connection (TCP socket, UDP socket, RDMA)
        └── rpc_task — one per in-flight RPC call
```

**`rpc_clnt`** (`include/linux/sunrpc/clnt.h`) is the handle NFS and other callers keep. It holds default timeout parameters, the authentication credential (`rpc_auth`), a reference to the transport, and the program/version/procedure table. One `rpc_clnt` may be shared across many concurrent `rpc_task`s.

**`rpc_xprt`** (`include/linux/sunrpc/xprt.h`) represents a single physical connection. Multiple `rpc_clnt` objects can share one transport (e.g. NFS and NLM using the same TCP connection to the same server). The transport manages:
- A **slot table** (`xprt_request_waitlist`): limits concurrent in-flight requests to avoid overwhelming the server. When slots are exhausted, new tasks queue on `xprt->backlog`.
- A **congestion window** (`cwnd`): adjusted using a time-smoothed estimator, analogous to TCP's cwnd, to rate-limit retransmissions.
- Pending send queue and receive queue, drained by a workqueue thread.

**`rpc_task`** (`include/linux/sunrpc/sched.h`) is the unit of work. It is a state machine with a sequence of callback functions (`tk_action`) that advance it through the RPC lifecycle: reserve slot → encode → transmit → wait for reply → decode → complete.

### Request lifecycle

1. **Allocate**: `rpc_run_task()` allocates an `rpc_task` from the slab pool, associates it with the `rpc_clnt`, and calls `xprt_reserve()` to claim a slot.

2. **Encode**: The procedure's XDR encode function serialises the request arguments into an `xdr_buf`. The RPC header (program, version, procedure, XID, credentials) is prepended.

3. **Transmit**: `xprt_transmit()` hands the `xdr_buf` to the transport. For TCP, this calls `kernel_sendmsg()`; for UDP, `kernel_sendmsg()` with a datagram socket. RDMA transports post a work request directly.

4. **Wait for reply**: The task sleeps on a waitqueue associated with its XID (transaction ID). A per-transport receive workqueue (`xs_tcp_data_receive_workfn` for TCP) reads incoming data, looks up the XID in a hash table (`xprt->recv_queue`), and wakes the matching task.

5. **Decode**: The procedure's XDR decode function unmarshals the reply into kernel structs.

6. **Complete / retry**: On success, the task calls the completion callback. On timeout (no reply within `rpc_timeout`), `xprt_adjust_cwnd()` shrinks the congestion window and the task is re-queued for retransmission with exponential backoff (`rpc_delay()`). On `RPC_AUTH_BADVERF` the credential may be refreshed and the call retried.

### Transport switch — `rpc_xprt_ops`

Transports are pluggable via `struct rpc_xprt_ops`:
- `xs_udp_ops` — UDP (stateless; request retransmission handled by sunrpc)
- `xs_tcp_ops` — TCP (connection management, reconnect on error)
- `xprt_rdma_ops` — RDMA (for high-performance NFS over InfiniBand/RoCE)

The transport switch was introduced to allow RDMA and QUIC (experimental) transports without forking the RPC core.

### Authentication — `rpc_auth`

Authentication is also pluggable. Each `rpc_clnt` holds an `rpc_auth` (credential cache) with flavour-specific ops:
- `AUTH_NULL` — no authentication
- `AUTH_UNIX` (AUTH_SYS) — UID/GID in the call credential; no verification
- `RPCSEC_GSS` — Kerberos/GSSAPI; provides integrity and optionally privacy; credentials expire and must be renewed

On the server side, credential verification happens in `svc_authenticate()` before the procedure handler is called.

### RPC cache — server-side upcall

The NFS server needs to resolve IP addresses to client names, client names to export options, and UIDs to user identities. Rather than kernel code querying LDAP or DNS directly, sunrpc provides the **RPC cache** (`net/sunrpc/cache.c`): a kernel-side cache with a user-space upcall channel via `/proc/net/rpc/*/channel`. When a cache miss occurs:
1. The kernel creates a deferred request and writes the lookup key to the channel.
2. `rpc.idmapd`, `rpc.mountd`, or other daemons read the key, resolve it, and write back the answer.
3. The deferred request is re-queued and completes with the fresh value.
4. Entries expire per TTL and trigger new upcalls.

### The svc layer — server-side RPC

The server side uses `struct svc_serv` / `struct svc_rqst` rather than `rpc_clnt`/`rpc_task`:
- `svc_serv` — one per RPC service instance (e.g. the NFS server); holds a pool of kernel threads and listened sockets.
- `svc_rqst` — one per server thread; holds the XDR buffers for the current incoming request and outgoing reply.
- `svc_process()` — main dispatch loop: decode RPC header, authenticate, dispatch to procedure handler, encode reply.

## Key Data Structures

**`rpc_clnt`** (`include/linux/sunrpc/clnt.h`) — logical RPC client.
- `cl_xprt` — the transport
- `cl_auth` — credential cache
- `cl_timeout` — default timeout / retransmit parameters
- `cl_procinfo` — procedure descriptor table (XDR codecs per procedure)

**`rpc_xprt`** (`include/linux/sunrpc/xprt.h`) — physical transport connection.
- `recv_queue` — hash table of pending `rpc_rqst` structs indexed by XID
- `cwnd` — congestion window (number of in-flight requests)
- `max_reqs` — hard limit on concurrent requests (slot table size)
- `ops` — `rpc_xprt_ops` vtable (UDP/TCP/RDMA)

**`rpc_task`** (`include/linux/sunrpc/sched.h`) — in-flight RPC state machine.
- `tk_action` — current state-machine callback
- `tk_rqstp` — the associated `rpc_rqst` (XDR buffers, XID, slot)
- `tk_timeout` — remaining time before retransmit
- `tk_flags` — `RPC_TASK_ASYNC`, `RPC_TASK_SOFT`, etc.

**`rpc_rqst`** (`include/linux/sunrpc/xprt.h`) — per-call wire-state: XID, send/receive `xdr_buf`, slot reservation.

## Key Functions / Entry Points

**`rpc_run_task()`** (`net/sunrpc/clnt.c`) — allocates `rpc_task`, reserves slot, starts state machine; called by all NFS procedure functions.

**`xprt_transmit()`** (`net/sunrpc/xprt.c`) — sends encoded request via transport ops.

**`xprt_complete_rqst()`** (`net/sunrpc/xprt.c`) — called by receive path to match an incoming reply to its `rpc_rqst` by XID and wake the waiting task.

**`rpc_delay()`** (`net/sunrpc/sched.c`) — puts a task to sleep for a timeout period (used for retransmission backoff and `NFS4ERR_DELAY` handling).

**`svc_process()`** (`net/sunrpc/svc.c`) — server-side dispatch: decode header, authenticate, call procedure handler, encode reply.

**`sunrpc_cache_lookup_rcu()`** (`net/sunrpc/cache.c`) — RCU-safe lookup in an RPC cache; returns cached value or triggers upcall on miss.

## Important Flags & Config Options

| Symbol / sysctl | Effect |
|---|---|
| `/proc/sys/sunrpc/rpc_debug` | Bitmask for RPC subsystem debug output (for developers) |
| `/proc/sys/sunrpc/nfs_debug` | NFS-specific debug output |
| `RPC_TASK_ASYNC` | Task flag: completion happens via callback rather than blocking the caller |
| `RPC_TASK_SOFT` | Task flag: return error after `retrans` timeouts (vs hard: retry forever) |
| `CONFIG_SUNRPC_XPRT_RDMA` | Enables the RDMA transport |
| `CONFIG_RPCSEC_GSS_KRB5` | Enables Kerberos authentication for NFS |

## Interactions with Other Subsystems

- **↑ NFS client**: every NFS operation becomes an `rpc_task`; the NFS client calls `rpc_run_task()` and waits for (or is called back by) completion.
- **↑ NFS server (knfsd)**: uses `svc_serv` / `svc_rqst` for incoming request handling; uses `rpc_clnt` for NFSv4 callbacks to clients.
- **→ [[xdr-encoding]]**: all argument/result serialisation uses XDR; sunrpc calls the procedure's `p_encode` / `p_decode` functions.
- **→ Socket layer**: TCP and UDP transports use `kernel_sendmsg()` / `kernel_recvmsg()` directly.
- **→ RDMA (`xprtrdma`)**: posts work requests to the RDMA queue pair rather than calling socket functions.
- **← `rpc.idmapd`, `rpc.mountd`**: user-space daemons service the RPC cache upcall channels.

## Design Decisions & Tradeoffs

**Async task model**: `rpc_task` as a state machine (rather than a dedicated per-RPC kernel thread) allows thousands of concurrent RPCs with a small thread pool. The tradeoff is code complexity — the state machine callbacks must be re-entrant and the task's state must be fully captured in `rpc_task` / `rpc_rqst`.

**XID-based reply matching**: replies are matched to pending requests by XID (a 32-bit random ID in the RPC header). This is O(1) with a hash table but requires a non-colliding XID space. UDP retransmissions use the same XID so the server can detect duplicates.

**Congestion window**: the sunrpc-level cwnd is orthogonal to TCP's cwnd — it limits the number of concurrent in-flight RPCs regardless of what TCP's flow control allows. This prevents a server from being overwhelmed even on a high-bandwidth link.

**Pluggable transports and auth**: adding RDMA and Kerberos support without forking the RPC core required the `rpc_xprt_ops` and `rpc_authops` vtables. This modularity enables future transports (QUIC is being explored) without touching NFS or NLM.

## How It Has Evolved

- **2.0 (pre-history)**: SunRPC merged with the original Linux NFS client.
- **2.6.x**: Async RPC task model fully implemented; RPCSEC_GSS (Kerberos) added.
- **3.3 (2012)**: RDMA transport (`xprtrdma`) merged.
- **5.4 (2019)**: RPC-over-TLS prototype work began (RFC 9289 compliant).
- **6.x**: Ongoing RDMA improvements; QUIC transport experimental work.

## Further Reading

1. **Kernel source — `net/sunrpc/clnt.c`**: https://github.com/torvalds/linux/blob/master/net/sunrpc/clnt.c — the client entry points.
2. **Kernel source — `net/sunrpc/xprt.c`**: https://github.com/torvalds/linux/blob/master/net/sunrpc/xprt.c — transport slot management and congestion control.
3. **Kernel docs — RPC Cache**: https://www.kernel.org/doc/html/latest/filesystems/nfs/rpc-cache.html
