---
title: "NFSv4.1 Sessions"
category: concept
tags: [nfs, nfsv4.1, sessions, exactly-once, slot-table, rpc]
subsystem: nfs
kernel_version: "2.6.38"
researched: 2026-04-05
status: complete
sources:
  - https://lwn.net/Articles/898262/
  - https://www.kernel.org/doc/html/v5.18/filesystems/nfs/nfs41-server.html
  - https://www.kernel.org/doc/Documentation/filesystems/nfs/nfs41-server.txt
  - https://www.rfc-editor.org/rfc/rfc5661
---

# NFSv4.1 Sessions

## Purpose

NFSv4.0 suffered from a fundamental protocol weakness: there was no reliable way to detect and suppress duplicate non-idempotent operations (e.g. `RENAME`, `REMOVE`, `SETATTR`). If the network dropped a reply and the client retried, the server could execute the operation twice. NFSv4.1 sessions (RFC 5661, later revised as RFC 8881) solve this with a **slot-and-sequence-number** mechanism that gives every request a unique, server-verifiable identity, enabling the server to cache replies and deduplicate retries. Sessions also solve connection multiplexing (multiple TCP connections can carry traffic for one logical session), enable the pNFS parallel data path, and provide a **back channel** for server-to-client callbacks (replacing the separate callback connection of NFSv4.0).

## Mental Model

A session is like a database cursor shared between client and server. The client pre-allocates a fixed number of **slots** (like rows in the cursor table). Every RPC request occupies one slot and carries a **sequence number** — the count of how many times that slot has been used. The server executes each request and caches the reply, keyed by `(session_id, slot_id, sequence_number)`. If the client retries with the same `(session, slot, seqno)`, the server returns the cached reply without re-executing. The client moves to the next sequence number only after receiving a valid reply, ensuring exactly-once semantics for the entire sequence of operations on each slot.

## How It Works

### Session creation — `CREATE_SESSION`

The client establishes a session with a `CREATE_SESSION` compound operation (after `EXCHANGE_ID` to negotiate a `clientid`). The arguments include:

- **fore channel parameters**: `ca_maxrequestsize`, `ca_maxresponsesize`, `ca_maxrequests` (maximum simultaneous outstanding requests = number of slots)
- **back channel parameters**: same fields for the server→client callback channel

The server replies with the negotiated parameters and a `sessionid` (16-byte opaque value). The `ca_maxrequests` value establishes the slot table size: the server allocates space to cache one reply per slot.

### The SEQUENCE operation and slot table

Every COMPOUND RPC in NFSv4.1 must begin with a `SEQUENCE` operation containing:

```
sessionid      [16 bytes] — identifies which session this belongs to
sequenceid     [u32]      — current sequence number for this slot
slotid         [u32]      — which slot (0 … ca_maxrequests-1)
highest_slotid [u32]      — hint: highest slot the client currently needs
cachethis      [bool]     — whether the server must cache this reply
```

The server processes the SEQUENCE operation before any other operation in the compound:

1. Look up the session in the session table.
2. Verify the `slotid` is within range.
3. Check `sequenceid`:
   - Equal to cached + 1: this is a new request → execute and cache reply.
   - Equal to cached: this is a retry → return cached reply without re-executing.
   - Any other value: `NFS4ERR_SEQ_MISORDERED`.
4. Mark the slot as busy (future requests on the same slot wait or return `NFS4ERR_DELAY`).

The slot is released and the cached reply is updated only after the request completes. Non-idempotent operations (the ones that matter) cannot be in-flight on the same slot simultaneously.

### Reply caching and exactly-once semantics

`cachethis=true` requests always have their reply cached. `cachethis=false` can be used for idempotent operations (READ, GETATTR) to save server memory. If `cachethis=false` and the client retries, the server re-executes rather than returning a cached reply — safe only because idempotent operations produce the same result when repeated.

This model eliminates the "at-most-once" problem of NFSv4.0: the client is guaranteed that if it receives a successful reply to `RENAME`, the rename happened exactly once, even if the network replayed or duplicated the request.

### Back channel — server-to-client callbacks

NFSv4.0 used a separate TCP connection (set up via `SETCLIENTID_CONFIRM`) for the server to send callback operations (e.g. `CB_RECALL` to revoke a delegation). This separate connection was fragile and caused firewall/NAT problems. NFSv4.1 uses the **same TCP connection** in the opposite direction: the server sends callback COMPOUND RPCs using the back channel parameters negotiated in `CREATE_SESSION`. The client processes `CB_SEQUENCE` (analogous to SEQUENCE but for callbacks), followed by callback operations.

This allows delegations to work reliably through firewalls and NATs without any additional connection management. The back channel also carries `CB_LAYOUTRECALL` for pNFS layout revocation.

### Dynamic slot table adjustments

The server can suggest slot table changes via the `target_highest_slotid` field in the SEQUENCE reply. If the server is under memory pressure, it sets `target_highest_slotid` below the current `ca_maxrequests` to ask the client to reduce concurrency. The client gradually reduces its highest active slot, and the server frees memory once no requests are using the higher slots. This dynamic renegotiation avoids the need to tear down and recreate the session.

### Linux implementation

The Linux NFSv4.1 client (`fs/nfs/nfs4session.c`) maintains `nfs4_session` and `nfs4_slot_table` structs:

```c
struct nfs4_session {
    nfs4_sessionid      sess_id;
    struct nfs4_slot_table fc_slot_table; /* fore channel */
    struct nfs4_slot_table bc_slot_table; /* back channel */
    struct nfs_client     *clp;
    ...
};

struct nfs4_slot_table {
    struct nfs4_slot *slots;        /* array of slots */
    u32              max_slots;
    u32              max_transport_limit;  /* max slots considering transport */
    struct nfs4_slot *highest_used_slotid;
    ...
};
```

The client uses `nfs41_setup_sequence()` to acquire a slot before an RPC and `nfs41_sequence_done()` to release it after the reply. Slot acquisition blocks if all slots are busy (`NFS4ERR_DELAY` from server, or local wait queue).

### Interaction with pNFS

Sessions are the transport mechanism for pNFS control operations. pNFS layout operations (`LAYOUTGET`, `LAYOUTCOMMIT`, `LAYOUTRETURN`) use ordinary fore channel slots. `CB_LAYOUTRECALL` callbacks from the storage device (DS) or metadata server (MDS) use the back channel. The session's reliable exactly-once semantics ensure that layout state changes are atomic and recoverable.

## Key Data Structures

**`nfs4_session`** (`fs/nfs/nfs4session.h`) — one per client-server connection; holds session ID and fore/back channel slot tables.

**`nfs4_slot`** (`fs/nfs/nfs4session.h`) — one per slot; tracks `seq_nr` (current sequence number) and cached reply state.

**`nfs4_slot_table`** (`fs/nfs/nfs4session.h`) — the slot table for one channel; holds the slot array, max count, and waitqueue for slot acquisition.

**`nfs41_sequence_args`** / **`nfs41_sequence_res`** — XDR types for the SEQUENCE operation; encoded at the head of every fore channel compound.

## Key Functions / Entry Points

**`nfs41_setup_sequence()`** (`fs/nfs/nfs4session.c`) — acquires a slot and fills `nfs41_sequence_args` before an RPC.

**`nfs41_sequence_done()`** (`fs/nfs/nfs4session.c`) — processes SEQUENCE reply, detects slot status, releases slot or handles `NFS4ERR_DELAY`.

**`nfs41_proc_create_session()`** (`fs/nfs/nfs4proc.c`) — sends `CREATE_SESSION`; populates `nfs4_session`.

**`nfsd41_proc_sequence()`** (`fs/nfsd/nfs4proc.c`) — server-side SEQUENCE handler; performs reply cache lookup, executes or returns cached reply.

## Important Flags & Config Options

| Option | Effect |
|---|---|
| `max_session_slots=N` | Client kernel parameter; cap on slots negotiated in `CREATE_SESSION` (default: 64) |
| `max_session_cb_slots=N` | Cap on back channel slots |
| `NFSv4_1` / `NFSv4_2` | Enabled by `vers=4.1` / `vers=4.2` mount options |
| `cachethis` in SEQUENCE | `true` = server must cache reply; `false` = skip caching for idempotent ops |

## Interactions with Other Subsystems

- **↑ Userspace**: sessions are transparent; enabled by `vers=4.1` or `vers=4.2` at mount. `nfsstat -m` shows session parameters.
- **→ [[sunrpc]]**: each slot maps to an RPC task; slot acquisition gates the RPC from being submitted until a slot is free.
- **→ [[pnfs]]**: pNFS layout operations use fore channel slots; `CB_LAYOUTRECALL` uses the back channel.
- **← [[nfs-client]]**: the client acquires and releases slots for every compound RPC.
- **← [[nfs-server]]**: the server maintains the session table and reply cache.

## Design Decisions & Tradeoffs

**Fixed slot table vs. dynamic**: The slot count is negotiated at session creation and can only be reduced dynamically (via `target_highest_slotid`). Increasing requires `BIND_CONN_TO_SESSION` or recreating the session. This simplifies implementation at the cost of flexibility for burst workloads.

**Per-slot reply cache vs. global**: Keying the reply cache on `(session_id, slot_id, sequence_number)` allows O(1) lookup (direct array index by slot) rather than the NFSv4.0 DRC (Duplicate Request Cache) which required hash table lookup on all incoming operations. The downside is per-slot cache memory is always allocated, even for idempotent-only workloads.

**Back channel on the same connection**: Eliminates the separate callback connection of NFSv4.0, which required the client to listen on a port reachable from the server — problematic through NAT and firewalls. The back channel uses the same TCP connection in reverse. The cost is that a client behind a strict firewall can now receive callbacks it couldn't receive in NFSv4.0, requiring firewall policy changes.

## How It Has Evolved

- **2.6.38 (2011)**: NFSv4.1 client and server merged into mainline.
- **3.7 (2012)**: Improved back channel implementation.
- **3.9 (2013)**: Dynamic slot table renegotiation (`target_highest_slotid` fully implemented).
- **5.3 (2019)**: NFSv4.2 (`CREATE_SESSION` for v4.2) fully supported.

## Further Reading

1. **RFC 8881** (obsoletes RFC 5661): https://www.rfc-editor.org/rfc/rfc8881 — The definitive NFSv4.1 spec; Section 2.10 covers sessions.
2. **LWN — "NFS: the new millennium"** (2021): https://lwn.net/Articles/898262/ — Context on NFSv4 evolution including sessions.
3. **Kernel docs — NFSv4.1 Server Implementation**: https://www.kernel.org/doc/html/v5.18/filesystems/nfs/nfs41-server.html
