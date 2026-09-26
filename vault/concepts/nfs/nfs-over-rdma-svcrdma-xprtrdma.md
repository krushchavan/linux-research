---
title: "NFS over RDMA (xprtrdma and svcrdma)"
category: concept
tags: [nfs, rdma, sunrpc, rpc-over-rdma, direct-data-placement, storage-networking]
subsystem: nfs
kernel_version: "2.6.24 (client, xprtrdma); 2.6.25 (server, svcrdma)"
researched: 2026-09-26
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/nfs/nfs-rdma.html
  - https://www.rfc-editor.org/rfc/rfc8166.html
  - https://datatracker.ietf.org/doc/html/rfc8267
  - https://datatracker.ietf.org/doc/html/rfc5667
  - https://datatracker.ietf.org/meeting/99/materials/slides-99-nfsv4-nfsrdma-next-steps-chuck-lever-00
  - https://datatracker.ietf.org/doc/html/draft-ietf-nfsv4-nfs-ulb-v2
  - https://ratatoskr.run/linux-nfs/2026/05/17031295/t
  - https://docs.netapp.com/us-en/ontap/nfs-rdma/
  - https://github.com/torvalds/linux/tree/master/net/sunrpc/xprtrdma
---

# NFS over RDMA (xprtrdma and svcrdma)

## Purpose

NFS runs on **SunRPC**, which normally uses TCP: every READ reply and WRITE call carries file data inside the RPC byte stream, so both client and server copy it through socket buffers and spend CPU in the TCP stack. **RPC-over-RDMA** (RFC 8166, NFS binding RFC 8267) replaces the transport under SunRPC with RDMA. Small RPCs travel as RDMA SENDs, and bulk data (read and write payloads, large replies) moves by **Direct Data Placement**: the *server's* NIC RDMA-WRITEs read data straight into the client's page-cache pages, and RDMA-READs write data straight out of them. In Linux the client-side transport is **xprtrdma** and the server-side one is **svcrdma**, both in `net/sunrpc/xprtrdma/` and plugged into the generic `rpc_xprt` and `svc_xprt` frameworks ([[sunrpc]]). NFS itself (v3, v4.x) is unchanged. It's `mount -o rdma,port=20049`.

## Mental Model

An RPC message is a **letter with attachments**. Over TCP, the attachments are stapled into the letter, and everyone who handles the letter handles the whole bundle. RPC-over-RDMA sends just the **letter** (the RPC header and small arguments, "inline") in a SEND, with a **claim ticket** for each attachment: a *chunk* naming `{handle (rkey), length, offset}` in the sender's registered memory. The receiver picks up attachments directly from the sender's shelves (RDMA READ) or delivers results straight onto the requester's shelves (RDMA WRITE). The rule of RPC-over-RDMA v1 is that **the server always does the RDMA operations**. The client only registers memory and hands out tickets, so the server controls its own resource use and the client never needs to trust or reach into the server's memory.

## How It Works

**Transport setup.** The client mount (`proto=rdma`, port 20049 by convention) creates an `rpcrdma_xprt` (`transport.c`). `rpcrdma_xprt_connect()` uses rdma_cm to resolve and connect ([[rdma-cm-connection-manager]]), creating an RC QP and CQs. Connection private data advertises the **inline thresholds** (maximum size of a message sent in a single SEND; RFC 8166 defaults to 1024 bytes, and Linux negotiates up to 4 KiB). The server enables RDMA with `echo rdma 20049 > /proc/fs/nfsd/portlist`, creating an svcrdma listener (`svc_rdma_transport.c`). Both sides pre-post **receive buffers**. **Credits** in every RPC-over-RDMA header grant the peer how many outstanding requests it may have, so the client never sends more SENDs than the server has receive buffers posted. This is RPC-level flow control replacing TCP's window.

**The RPC-over-RDMA header.** Every message starts with `xid`, version, credits, a procedure (`RDMA_MSG`, `RDMA_NOMSG`, `RDMA_ERROR`, `RDMA_DONE`) and three chunk lists:
- **Read list** — segments the *server* must RDMA READ from the client (e.g. NFS WRITE payload). Each read segment names its XDR position in the message.
- **Write list** — client buffers the server should RDMA WRITE result data into (e.g. an NFS READ reply's data).
- **Reply chunk** — a client buffer for the *entire* reply when it might exceed the inline threshold (READDIR, large GETATTR, ACLs).

A message whose call body is too big to send inline goes as `RDMA_NOMSG` with a *position-zero read chunk* containing the whole call (`rpcrdma_areadch`).

**Client send path (`rpc_rdma.c`, `frwr_ops.c`).** `xprt_rdma_send_request()` → `rpcrdma_marshal_req()` decides the chunk strategy for each RPC (`enum rpcrdma_chunktype`: `rpcrdma_noch`, `_noch_pullup`, `_noch_mapped` for inline sends; `rpcrdma_readch`/`areadch` for read chunks; `rpcrdma_writech`; `rpcrdma_replych`). The NFS upper layer tells it *which* part of the XDR buffer is DDP-eligible (RFC 8267 says only bulk data, e.g. READ/WRITE payload and READLINK/READDIR data, may be chunked). For each chunk, **`frwr_map()`** takes a pre-allocated MR (`struct rpcrdma_mr`) and maps the page-cache pages of the `xdr_buf` into it, and `rpcrdma_encode_read_list()`, `_write_list()` or `_reply_chunk()` write the `{rkey, length, offset}` segments into the header. **`frwr_send()`** posts a chain: one `IB_WR_REG_MR` per MR, then the SEND carrying the header and inline part. Inline data uses DMA-mapped SGEs from the pages where possible (`noch_mapped`), or is pulled up into a contiguous buffer.

**Server receive and execute (`svc_rdma_recvfrom.c`, `svc_rdma_rw.c`).** A receive completion hands the buffer to `svc_rdma_recvfrom()`, which parses the header into a **parsed chunk list** (`svc_rdma_pcl.c`: `struct svc_rdma_pcl` of `svc_rdma_chunk`s and segments). If there's a read list, `svc_rdma_process_read_list()` builds RDMA READs with the core `rdma_rw` API ([[rdma-rw-api]]), waits for them, and splices the pulled data into the `svc_rqst`'s pages at the right XDR positions, so nfsd sees a normal, complete RPC call. nfsd then runs the operation (e.g. `nfsd_write` → VFS).

**Server reply (`svc_rdma_sendto.c`).** `svc_rdma_sendto()` looks at the reply. For a READ, the data pages go to the client's **write chunk** via RDMA WRITE (`rdma_rw` contexts, `svc_rdma_send_write_list`). If the reply body doesn't fit inline, it's RDMA-written into the **reply chunk**. Finally the RPC-over-RDMA reply header (plus any inline body) is sent with a SEND, as **SEND_WITH_INV** carrying the client's rkey when the client advertised support, so the client's MR is invalidated remotely. RC ordering guarantees the WRITEs land before the SEND arrives.

**Client reply handling.** `rpcrdma_reply_handler()` runs from the receive completion. It checks xid and credits, updates the congestion window (`rpcrdma_reset_cwnd`/credit grant), fixes up the `xdr_buf` for data that arrived by RDMA WRITE (`rpcrdma_inline_fixup`), and makes sure every MR used by the RPC is invalidated. It trusts the remote invalidation, or posts `IB_WR_LOCAL_INV` (`frwr_unmap_async()`, or `frwr_unmap_sync()` for a signalled RPC) *before* completing the RPC to the NFS layer. That last step is a security invariant: no page may return to the page cache while a remote peer could still write into it.

**Backchannel (NFSv4.1+).** Server-to-client callbacks (CB_RECALL for delegations) run over the same connection with roles reversed (`backchannel.c`, `svc_rdma_backchannel.c`), using a small reserved number of credits ([[nfsv4.1-sessions]]).

**Error and disconnect.** On a QP error or disconnect, pending RPCs are retransmitted after reconnect (NFSv3) or replayed through the session slot table (NFSv4.1). MRs that might have been exposed are "recycled": re-registered with a new key before reuse. `RDMA_ERROR` replies report version mismatches or chunk-too-large errors.

## Key Data Structures

**`struct rpcrdma_xprt`** (`xprt_rdma.h`) — client transport: embeds `rpc_xprt`; `rx_ep` (endpoint: `cm_id`, QP, inline thresholds, `re_max_requests`), `rx_buf` (`rpcrdma_buffer`: request/reply pools, MR list, credits).

**`struct rpcrdma_req`** — one outgoing RPC: send buffer, `rl_sendctx` (SGEs for inline send), `rl_registered` (MRs used), chunk types.

**`struct rpcrdma_mr`** — a fast-registration MR: `mr_ibmr`, scatterlist, `mr_handle`/`mr_length`/`mr_offset` (the segment advertised), reg/inv WRs and CQEs.

**`struct svcxprt_rdma`** (`include/linux/sunrpc/svc_rdma.h`) — server transport: `sc_cm_id`, `sc_qp`, `sc_sq_cq`/`sc_rq_cq`, `sc_max_requests`, `sc_max_req_size`, `sc_ord`, rw context cache.

**`struct svc_rdma_recv_ctxt`** — one received request: parsed read/write/reply chunk lists (`rc_read_pcl`, `rc_write_pcl`, `rc_reply_pcl`), pages.

**`struct svc_rdma_pcl` / `struct svc_rdma_chunk` / `struct svc_rdma_segment`** (`svc_rdma_pcl.h`) — parsed chunk lists: position, length, handle, offset.

## Key Functions / Entry Points

- **`xprt_rdma_send_request()` → `rpcrdma_marshal_req()` → `frwr_map()` / `frwr_send()`** — client send
- **`rpcrdma_reply_handler()` / `rpcrdma_complete_rqst()` / `frwr_unmap_async()`** — client reply and MR invalidation
- **`rpcrdma_xprt_connect()` / `rpcrdma_ep_create()`** (`verbs.c`) — connection and QP setup
- **`svc_rdma_recvfrom()` → `pcl_*` parsing → `svc_rdma_process_read_list()`** — server receive and read-chunk pull
- **`svc_rdma_sendto()`** — server reply: write list, reply chunk, SEND(_WITH_INV)
- **`svc_rdma_accept()` / `svc_rdma_create()`** (`svc_rdma_transport.c`) — listener and accept

## Important Flags & Config Options

- `CONFIG_SUNRPC_XPRT_RDMA` — builds `rpcrdma.ko` (client + server; historically separate `xprtrdma.ko`/`svcrdma.ko`)
- Mount: `-o rdma,port=20049` (or `proto=rdma`); `nconnect=` for multiple connections (RDMA supports it since 5.x)
- Server: `/proc/fs/nfsd/portlist` ← `rdma 20049`; exports may need `insecure` (client ports are not privileged)
- Client sysctls `/proc/sys/sunrpc/`: `rdma_max_inline_read`, `rdma_max_inline_write`, `rdma_memreg_strategy`, `rdma_pad_optimize`, `rdma_inline_write_padding`
- Server sysctls `/proc/sys/sunrpc/svc_rdma/`: `max_requests` (credits), `max_req_size`, `max_outbound_read_requests` (ORD), plus `rdma_stat_*` counters
- Tracepoints: `rpcrdma:*` (`xprtrdma_*`, `svcrdma_*`), very thorough

## Interactions with Other Subsystems

- **↑ Userspace**: `mount.nfs` (nfs-utils), `nfsstat`, `/proc/fs/nfsd/portlist`, `nfstest_rdma`
- **→ SunRPC**: implements `rpc_xprt_ops` (client) and `svc_xprt_ops` (server); XDR buffers (`xdr_buf`) are mapped directly ([[sunrpc]], [[xdr-encoding]])
- **→ RDMA core**: rdma_cm, CQ API, FRWR MRs, `rdma_rw` on the server, remote invalidation ([[rdma]], [[rdma-rw-api]])
- **→ page cache / VFS**: client READ data lands directly in page-cache pages, and server WRITE data is pulled into `svc_rqst` pages and then written via VFS ([[page-cache]])
- **← NFS client and server**: [[nfs-client]] marks DDP-eligible payloads, and [[nfs-server]] (nfsd) sees ordinary RPCs
- **Compared with io_uring**: io_uring accelerates the *application* side (async file I/O on an NFS mount). RPC-over-RDMA accelerates the *transport* under it. A userspace NFS client (libnfs) could use io_uring networking, but loses the page-cache direct placement

## Design Decisions & Tradeoffs

- **Server-driven data movement.** The server issues all RDMA READs and WRITEs, so a server never exposes its memory, and it paces transfers with its own ORD limits. The cost is a round trip for client→server bulk data (the server must read it), which is why small writes go inline.
- **Inline threshold vs chunks.** Messages under the threshold go in one SEND (cheap for small metadata ops). Larger ones need registration and extra RDMA operations. The threshold negotiation, and the complexity of "might this reply be large?" (reply chunks allocated speculatively), is a major source of implementation complexity and bugs, and motivated RPC-over-RDMA v2 drafts.
- **DDP only for bulk data.** RFC 8267 limits which XDR items may be chunked, to keep parsing tractable. Everything else must be inline or in a reply chunk.
- **Invalidate before completing.** Guarantees page-cache pages can't be overwritten by a buggy or malicious server after the RPC completes. It costs a LOCAL_INV round trip, avoided by SEND_WITH_INV when the server supports it.
- **Security of the parser.** The server parses peer-supplied chunk lists and turns them into RDMA operations and page offsets, which is fertile ground for arithmetic bugs. 2026 hardening (Chuck Lever, Chris Mason) added bounds checks against inline lengths, segment caps, and fixed a zero-segment wraparound in `pcl_for_each_segment()`.

## How It Has Evolved

- **2.6.24 / 2.6.25 (2008)** — xprtrdma client (Tom Talpey, NetApp) and svcrdma server (Tom Tucker, Open Grid Computing)
- **2010** — RFC 5666 (RPC-over-RDMA v1) and RFC 5667 (NFS DDP)
- **3.x–4.x** — Chuck Lever (Oracle) takes over client maintenance; FMR and physical registration modes removed in favour of FRWR (4.x); remote invalidation (4.9); backchannel for NFSv4.1 (4.4)
- **2017** — RFC 8166 and RFC 8267 revise v1 based on implementation experience
- **4.20–5.x** — svcrdma rebuilt on `rdma_rw` (4.1x); `nconnect` for RDMA (5.x); extensive tracepoints
- **5.10–6.x** — svcrdma parsed-chunk-list (pcl) rewrite (5.11), `noch_mapped` zero-copy inline sends, CQ pool usage
- **2026** — svcrdma chunk-list hardening against crafted peer values; ongoing Write-chunk payload fixes; RPC-over-RDMA v2 (extensible headers, reliable reply) in IETF drafts

## Further Reading

- kernel.org — [NFS/RDMA admin guide](https://www.kernel.org/doc/html/latest/admin-guide/nfs/nfs-rdma.html)
- IETF — [RFC 8166: RPC-over-RDMA Version 1](https://www.rfc-editor.org/rfc/rfc8166.html); [RFC 8267: NFS Upper-Layer Binding](https://datatracker.ietf.org/doc/html/rfc8267); [NFS ULB v2 draft](https://datatracker.ietf.org/doc/html/draft-ietf-nfsv4-nfs-ulb-v2)
- Chuck Lever — [NFS/RDMA Next Steps (IETF 99 slides)](https://datatracker.ietf.org/meeting/99/materials/slides-99-nfsv4-nfsrdma-next-steps-chuck-lever-00)
- NetApp — [NFS over RDMA in ONTAP](https://docs.netapp.com/us-en/ontap/nfs-rdma/) (commercial server perspective, GPUDirect Storage)
- Related: [[sunrpc]], [[nfs-client]], [[nfs-server]], [[rdma-rw-api]], [[rdma]]

## LKML Highlights

- **"svcrdma: harden parsed chunk list handling" (Chuck Lever with Chris Mason, May 2026)** — six patches closing unsigned underflows from peer-supplied chunk positions and lengths ("exposing slab memory to the Reply channel or driving oversized allocations"), a zero-segment wrap in `pcl_for_each_segment()`, and uncapped segment lengths. Validation was consolidated after decode.
- **"xprtrdma: Fix Write chunk payload …" (Aug 2026)** — continuing correctness work on how the client computes write-chunk extents, showing how subtle DDP boundaries remain.
- **svcrdma conversion to rdma_rw and pcl (Chuck Lever, 2017–2020)** — replaced hand-rolled RDMA READ/WRITE code with the core API and a parsed chunk list, simplifying iWARP support and removing classes of bugs. (Message-ids unavailable: lore was unreachable this session.)
