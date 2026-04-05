---
title: "NFS LOCALIO"
category: concept
tags: [nfs, localio, loopback, performance, rpc-bypass, containers]
subsystem: nfs
kernel_version: "6.13"
researched: 2026-04-05
status: complete
sources:
  - https://docs.kernel.org/filesystems/nfs/localio.html
  - https://lwn.net/Articles/986514/
  - https://patchwork.kernel.org/project/linux-nfs/patch/20240626182438.69539-8-snitzer@kernel.org/
  - https://lwn.net/Articles/594969/
---

# NFS LOCALIO

## Purpose

When an NFS client and server run on the same host (or in co-located containers on the same host), every read/write still traverses the full RPC stack: XDR encoding, socket send, loopback network, socket receive, XDR decoding — wasting CPU and latency. NFS LOCALIO (merged ~6.13) detects this co-location and switches qualifying I/O operations to bypass the network entirely, calling directly into `nfsd_file` (the server's cached file handle) from the client path. The result is throughput approaching direct local filesystem performance for containers that mount NFS from a server running on the same node.

## Mental Model

Think of LOCALIO as a **short-circuit relay**: the NFS client normally sends a message over a wire to the server and waits for a reply. When LOCALIO is active, the client instead opens a door directly into the server's internal file cache and reads/writes directly, with the same credential checks but none of the serialisation overhead. The door is only opened after a cryptographic handshake confirms both parties are truly co-resident in kernel memory.

## How It Works

### Locality detection — the UUID handshake

IP-based co-location detection is unreliable: containers may have separate network namespaces with overlapping addresses, iptables may intercept traffic, and virtual IPs change. LOCALIO uses a **shared-memory nonce** approach instead:

1. The NFS client generates a short-lived UUID and registers it in a kernel-shared structure (`nfs_uuid_t`) in the `nfs_common` module.
2. During mount (or connection setup), the client sends the UUID to the server via a `UUID_IS_LOCAL` auxiliary RPC.
3. The server looks for the UUID in the same `nfs_uuid_t` shared memory. If found, both client and server are in the same kernel instance → co-located.
4. The server also verifies that both share the same network namespace (important for container scenarios where two containers on the same host have separate `net_ns`).

If locality is confirmed, the client stores a reference to the server's `nfsd_net` structure and activates the local I/O path. This handshake is performed per-mount and re-evaluated on reconnect.

The `UUID_IS_LOCAL` method replaces an older `GETUUID` protocol explored in earlier loopback NFS proposals; generating the nonce on the client side (rather than fetching one from the server) removes a round-trip and avoids races.

### Local I/O path

Once locality is established, the client's read/write path diverges:

**Normal path** (remote NFS):
```
nfs_readpages() → nfs_pgio_header → rpc_task → XDR encode → socket → [network] → nfsd → VFS read → XDR encode → socket → [network] → XDR decode
```

**LOCALIO path**:
```
nfs_readpages() → nfs_local_doio() → nfsd_file (server's cached file handle) → VFS read
```

`nfs_local_open_fh()` translates the client's NFS file handle into an `nfsd_file` by calling into the server's file cache. `nfs_local_doio()` then issues `vfs_read()` / `vfs_write()` directly on that file, using the client task's credentials. `nfs_local_commit()` handles `COMMIT` (fsync) similarly.

Using `nfsd_file` (rather than a raw `struct file`) is deliberate: it benefits from the nfsd filecache's garbage collection and reference counting, avoids opening a fresh `struct file` on every I/O, and re-uses the server's page cache warmth.

### Credential handling and safety

LOCALIO only supports `AUTH_UNIX` (the standard `sec=sys` mount option). Kerberos (`sec=krb5`) and other RPCSEC_GSS flavours are not supported — the local path skips GSS context handling that normally happens in the RPC layer.

To prevent writeback deadlocks (the NFS client's writeback path must not block on the same page it is trying to write while the server-side write path waits for the same page), the client sets a flag on the `nfsd_file` that suppresses server-side writeback during local writes.

`nfsd_net_ref` (a percpu refcount) is held by the client across all in-flight local I/Os. This prevents the server's network namespace from being destroyed while local I/O is active — a critical safety property for container teardown scenarios.

### Fallback

If the locality check fails (different host, different net namespace, non-AUTH_UNIX), the mount falls back to the normal RPC path transparently. LOCALIO is opportunistic — it degrades gracefully rather than failing the mount.

## Key Data Structures

**`nfs_uuid_t`** (`include/linux/nfs_common.h`) — the shared-memory nonce structure; holds the client-generated UUID and is visible to both client and server code via the `nfs_common` module.

**`nfsd_file`** (`fs/nfsd/filecache.h`) — the server's cached open file; used directly by the local I/O path instead of going through RPC.

**`nfsd_net`** (`fs/nfsd/netns.h`) — per-network-namespace server state; the client holds a reference to this during active local I/O.

## Key Functions / Entry Points

**`nfs_local_open_fh()`** (`fs/nfs/localio.c`) — translates an NFS file handle into an `nfsd_file`; called once per inode on first local I/O.

**`nfs_local_doio()`** (`fs/nfs/localio.c`) — performs the actual local read or write via `vfs_read()`/`vfs_write()` on the `nfsd_file`.

**`nfs_local_commit()`** (`fs/nfs/localio.c`) — handles `COMMIT` (data sync) locally via `vfs_fsync_range()`.

**`nfsd_uuid_is_local()`** (`fs/nfsd/localio.c`) — server-side handler for the `UUID_IS_LOCAL` RPC; checks shared memory and net namespace.

## Important Flags & Config Options

| Symbol / Option | Effect |
|---|---|
| `CONFIG_NFS_LOCALIO` | Enables LOCALIO support in the NFS client |
| `CONFIG_NFSD_LOCALIO` | Enables LOCALIO support in the NFS server |
| `sec=sys` | Required; LOCALIO does not support Kerberos or other GSS security flavours |
| `localio` / `nolocalio` | Mount options to explicitly enable or disable LOCALIO (default: enabled if `CONFIG_NFS_LOCALIO` and locality detected) |

## Interactions with Other Subsystems

- **→ [[nfs-client]]**: LOCALIO is a fast path within the client; the normal client machinery handles mount, metadata (GETATTR, LOOKUP), and fallback I/O.
- **→ [[nfs-server]]**: the client directly accesses `nfsd_file` objects from the server's file cache; the server must have `CONFIG_NFSD_LOCALIO` to participate.
- **→ VFS**: both the `nfs_local_doio()` read/write and the server-side `nfsd_file` operations go through the VFS, preserving normal permission checks.
- **← Container runtime**: the primary deployment scenario is containers on the same host mounting an NFS server (e.g. a Kubernetes pod mounting a hostPath-backed NFS); LOCALIO provides near-local performance for these workloads.

## Design Decisions & Tradeoffs

**Nonce on client, not server**: Earlier loopback NFS proposals had the server generate and publish a UUID; the client would fetch it and compare. LOCALIO inverts this: the client generates the nonce and the server verifies it. This eliminates a round-trip and avoids a race between UUID generation and verification.

**Using `nfsd_file` instead of raw `struct file`**: The filecache avoids per-I/O open/close overhead and shares the page cache with other clients accessing the same file. The alternative (opening a fresh kernel file per inode) would be correct but slower, and would miss the GC benefits of the filecache.

**AUTH_UNIX only**: Supporting Kerberos would require running GSS context setup locally, adding significant complexity. Since the primary use case is trusted same-host containers, AUTH_UNIX is sufficient for the initial implementation.

**Percpu refcount on `nfsd_net`**: Holding a reference on the server's net namespace prevents a teardown race during container removal. The percpu design keeps the fast path cache-friendly.

## How It Has Evolved

- **6.13 (2025)**: Initial LOCALIO support merged; covers read, write, and commit bypass for NFSv3 and NFSv4 mounts with AUTH_UNIX.
- Active development: expanding to support more authentication flavours and improving the locality detection for multi-network-namespace edge cases.

## Further Reading

1. **Kernel docs — NFS LOCALIO**: https://docs.kernel.org/filesystems/nfs/localio.html
2. **LWN — "nfs/nfsd: add support for localio"** (2024): https://lwn.net/Articles/986514/
3. **LWN — "Loopback NFS: theory and practice"** (2013): https://lwn.net/Articles/595652/ — The earlier loopback NFS investigation that motivated LOCALIO.
