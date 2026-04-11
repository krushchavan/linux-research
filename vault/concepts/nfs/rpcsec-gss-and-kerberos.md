---
title: "RPCSEC_GSS and Kerberos"
category: concept
tags: [nfs, security, kerberos, rpcsec_gss, sunrpc, authentication]
subsystem: nfs
kernel_version: "2.6.12"
researched: 2026-04-11
status: complete
sources:
  - https://docs.kernel.org/filesystems/nfs/rpc-server-gss.html
  - https://lwn.net/Articles/19844/
  - https://lwn.net/Articles/19845/
  - https://lwn.net/Articles/19847/
  - https://github.com/torvalds/linux/blob/master/net/sunrpc/auth_gss/auth_gss.c
  - https://github.com/torvalds/linux/blob/master/net/sunrpc/auth_gss/svcauth_gss.c
  - https://github.com/torvalds/linux/blob/master/net/sunrpc/auth_gss/gss_krb5_mech.c
  - https://datatracker.ietf.org/doc/html/rfc2203
  - https://datatracker.ietf.org/doc/html/rfc5403
---

# RPCSEC_GSS and Kerberos

## Purpose

RPCSEC_GSS is the security flavor that layers the Generic Security Services API (GSS-API) on top of Sun RPC, providing per-call authentication, integrity, and optional encryption for NFS traffic. Without it, NFS authentication relies only on AUTH_SYS — a trivially forgeable uid/gid pair the client asserts on its own honor. RPCSEC_GSS, mandated for NFSv4 by RFC 3010 (later RFC 3530), closes that hole by cryptographically binding each RPC call to a verified identity, using Kerberos V5 as the underlying security mechanism in the Linux kernel.

## Mental Model

Think of RPCSEC_GSS as a **security wrapper applied to every RPC envelope**. Before a call leaves the client, a tiny cryptographic token is stapled to the header: either a Message Authentication Code (integrity mode) or a fully encrypted payload (privacy mode). The server unwraps it, checks the token against a shared secret, and only then processes the call. The shared secret is a **Kerberos service ticket** — obtained from a Key Distribution Center (KDC) before the first call — so no password ever travels on the wire. The Linux kernel deliberately handles only the fast path (per-packet signing and verification); the slow, complex path (obtaining the Kerberos ticket and negotiating the security context) is delegated to userspace daemons.

## How It Works

### Security pseudoflavors

NFS mount options and server exports use one of three security pseudoflavors, all backed by RPCSEC_GSS with Kerberos V5:

| Pseudoflavor | Protection |
|---|---|
| `krb5`  | Authentication only — identity is cryptographically verified but data is in the clear |
| `krb5i` | Authentication + integrity — each RPC carries a HMAC that detects tampering in transit |
| `krb5p` | Authentication + integrity + privacy — payload is fully encrypted |

The pseudoflavor is negotiated at mount time (NFSv4 `SECINFO` operation) or declared in the server's `/etc/exports`. The kernel encodes the chosen service level as the `gc_proc` and service type fields in the GSS verifier.

### Kernel vs. userspace split

The Linux kernel's implementation draws a deliberate boundary: **context establishment lives in userspace, per-packet protection lives in the kernel**.

Context establishment is genuinely GSSAPI: it requires multiple round-trips to the KDC, handling of credential caches, ticket renewal, keytab lookups, and the full Kerberos AS and TGS exchange. Pulling this into the kernel would mean linking in a substantial chunk of MIT Kerberos, re-implementing the credential cache lifecycle, and managing complex policy decisions — all inappropriate for kernel code. So the kernel never touches a Kerberos ticket directly; it only ever holds the derived session key and a context handle.

Per-packet protection must be fast — it executes on every single NFS read and write. It is a tight crypto operation: a HMAC-SHA1 or AES-CBC-CTS with HMAC over the RPC header and payload, applied using keys already resident in `struct gss_krb5_ctx`. Running this in kernel eliminates the context-switch cost that a user-space signer would impose on every I/O.

### The upcall: asking userspace to establish a context

When an RPC task needs a GSS credential and none is cached, the authentication layer fires an **upcall** through `rpc_pipefs` — a small pseudo-filesystem (`/var/lib/nfs/rpc_pipefs/`) that serves as a character-device-style rendezvous between the kernel and userspace daemons.

The flow is:

1. `gss_refresh()` is invoked by the SunRPC call machinery when `task->tk_rqstp->rq_cred` is found to be absent or expired.
2. A `gss_upcall_msg` is allocated and enqueued on the pipe for the appropriate mechanism (`krb5`). The only datum passed upward is the UID of the user needing credentials.
3. The RPC task is put to sleep on `gss_msg->waitq` via `rpc_sleep_on()`. Multiple tasks needing the same credential share the same wait queue, so a single upcall services all of them.
4. The `rpc.gssd` daemon (or `gssproxy`) reads the UID from the pipe, consults the Kerberos credential cache for that user, performs the full Kerberos exchange with the KDC, and writes the resulting serialised GSS context back down the pipe.
5. `gss_pipe_downcall()` parses the blob from userspace: it extracts the on-wire context handle (`gc_wire_ctx`), the session key, the sequence number window, and the opaque `gss_ctx_id_t`. These are packed into a `struct gss_cl_ctx` and associated with a `gss_cred` in the credential cache.
6. All sleeping tasks are woken and proceed to marshal their calls with the new context.

### The credential cache and `gss_cred`

Each `rpc_clnt` has an `rpc_auth` associated with it; for RPCSEC_GSS this is a `struct gss_auth`. The auth manages a per-uid hash table of `struct gss_cred` objects (each wrapping a base `struct rpc_cred`). A lookup by UID either returns a valid cached credential or triggers the upcall above.

The `gss_cred` holds:
- A pointer to the `gss_cl_ctx` — the live cryptographic context.
- The pseudoflavor (`gc_service`), which selects integrity vs. privacy at marshal time.
- An expiry timestamp; credentials are refreshed before expiry by a background thread.

### Marshaling a call (client side)

When a credential is valid, `gss_marshal()` appends the RPCSEC_GSS credential header to the outgoing XDR buffer:

1. It serialises the GSS wire context handle (`gc_wire_ctx`) so the server can look up the matching context.
2. It atomically increments `gc_seq` (protected by `gc_seq_lock`) to obtain this call's sequence number. Sequence numbers prevent replay attacks: the server keeps a sliding window and rejects duplicates.
3. Depending on the service level:
   - `RPC_GSS_SVC_NONE`: the verifier carries `gss_get_mic()` over the RPC header only.
   - `RPC_GSS_SVC_INTEGRITY`: `gss_get_mic()` covers header + payload; the MIC is appended as the verifier.
   - `RPC_GSS_SVC_PRIVACY`: `gss_wrap()` encrypts the entire call body; the wrapped blob replaces the original payload.

### Verifying a reply (client side)

`gss_verify_header()` checks the server's verifier in the reply. For integrity and privacy modes, `gss_verify_mic()` or `gss_unwrap()` are called with the session key. Any mismatch causes the call to fail with `EACCES`; sequence number exhaustion (counter approaching `MAXSEQ` = 0x80000000) triggers `RPCSEC_GSS_CTXPROBLEM`, prompting context re-establishment.

### Server side: `svcauth_gss`

On the server, `net/sunrpc/auth_gss/svcauth_gss.c` is the counterpart. For each incoming request:

1. `svcauth_gss()` looks up the GSS context by the wire handle carried in the credential. Contexts are stored in the `rpcsec_context` Sun RPC cache.
2. The server's upcall path mirrors the client: if a new context arrives (from an `RPCSEC_GSS_INIT` call), the server fires an upcall to `rpc.svcgssd` (legacy) or `gssproxy` (modern) to accept the client's context token.
3. For data calls, `gss_check_seq_num()` validates the sequence number against a sliding **replay window** of `GSS_SEQ_WIN` (128) entries stored as a bitmask. If the sequence number falls within the window and the bit is clear, it is accepted and marked. If the bit is already set, the call is a replay and is dropped. If the number is below `sd_max - GSS_SEQ_WIN`, it is too old and also dropped.
4. `gss_verify_mic()` or `gss_unwrap()` checks message integrity or decrypts the body.
5. On success, `svcauth_gss()` fills in the `svc_cred` with the verified UID/GID, and the NFS server proceeds normally.

### The Kerberos V5 mechanism (`gss_krb5_mech.c`)

The actual cryptographic operations are registered as a `gss_api_mech` with OID `1.2.840.113554.1.2.2` (krb5). The mechanism struct exposes:

- `gss_import_sec_context()` — deserialises the context blob passed down by `rpc.gssd` into a `struct krb5_ctx` containing the session key, enctype, and sequence numbers.
- `gss_get_mic()` / `gss_verify_mic()` — compute and verify an HMAC over the token using the session key. For AES enctypes this is HMAC-SHA1-96 (RFC 3962) or HMAC-SHA256/384 (RFC 8009).
- `gss_wrap()` / `gss_unwrap()` — encrypt/decrypt using AES-CBC-CTS (token version 2, used by modern Kerberos) or DES3-CBC-SHA1 (legacy, deprecated). The kernel crypto API (`crypto_skcipher`, `crypto_ahash`) is used directly; no user-space crypto library involvement.

Supported encryption types as of kernel 6.x:
- `aes128-cts-hmac-sha1-96` (enctype 17, RFC 3962) — default for modern deployments
- `aes256-cts-hmac-sha1-96` (enctype 18, RFC 3962)
- `aes128-cts-hmac-sha256-128` (enctype 19, RFC 8009)
- `aes256-cts-hmac-sha384-192` (enctype 20, RFC 8009)
- DES3 and RC4 variants — historically present, progressively removed for being cryptographically weak

### Legacy vs. modern upcall mechanisms (server side)

Two upcall paths co-exist for `nfsd`:

**Legacy** (`rpc.svcgssd`, nfs-utils): A text-based protocol over a `rpc_pipefs` pipe. Token size is capped at **2 KiB** and the total buffer at 4 KiB, which is insufficient for large Kerberos deployments that use PAC (Privilege Attribute Certificate) extensions or where users belong to many groups.

**Modern** (`gssproxy`): Uses kernel RPC over a Unix socket (`/var/run/gssproxy.sock`). No token size limits. Activated by writing `1` to `/proc/net/rpc/use-gss-proxy` before `nfsd` starts. This choice is **permanent for the life of the kernel session** — switching back requires a reboot. The modern mechanism also avoids the group membership limit (>65,000 groups) that breaks the legacy path.

## Key Data Structures

**`struct gss_cl_ctx`** (`include/linux/sunrpc/gss_api.h`) — a single live security context on the client, shared across all calls using the same Kerberos session key.
- `gc_proc` — procedure type: `RPC_GSS_PROC_DATA` for normal calls, `RPC_GSS_PROC_INIT` during context establishment
- `gc_seq` — monotonically increasing sequence number for this context; incremented atomically before each marshaled call
- `gc_seq_lock` — spinlock protecting `gc_seq` increment
- `gc_gss_ctx` — opaque `gss_ctx_id_t` handle representing the mechanism's internal state (contains the `krb5_ctx`)
- `gc_wire_ctx` — serialised handle sent on the wire so the server can look up the matching context
- `gc_win` — sequence number window size (agreed during context establishment)

**`struct gss_cred`** (`net/sunrpc/auth_gss/auth_gss.c`) — per-user GSS credential, embedded in an `rpc_cred`.
- `gc_ctx` — pointer to the `gss_cl_ctx` (reference counted with `gss_get_ctx()` / `gss_put_ctx()`)
- `gc_service` — service level: `RPC_GSS_SVC_NONE`, `_INTEGRITY`, or `_PRIVACY`
- `gc_base.cr_expire` — expiry time; the background refresher wakes up before this

**`struct krb5_ctx`** (`net/sunrpc/auth_gss/gss_krb5.h`) — Kerberos-specific context, pointed to by `gss_cl_ctx.gc_gss_ctx`.
- `enctype` — negotiated encryption type (AES-128, AES-256, etc.)
- `Ksess` — the session key bytes
- `seq_send`, `seq_recv` — atomic sequence counters
- `initiate` — 1 if this is the initiator side (client)

**`struct gss_api_mech`** (`include/linux/sunrpc/gss_api.h`) — mechanism vtable, one per GSS mechanism (only krb5 in practice).
- `gm_oid` — mechanism OID
- `gm_ops` — pointer to function table with `gss_import_sec_context`, `gss_get_mic`, `gss_verify_mic`, `gss_wrap`, `gss_unwrap`, `gss_delete_sec_context`

## Key Functions / Entry Points

**`gss_refresh()`** (`net/sunrpc/auth_gss/auth_gss.c`) — called by the SunRPC scheduler when a task's credential is absent or stale; triggers the upcall or waits on an in-flight one.

**`gss_marshal()`** — called per-call to prepend the RPCSEC_GSS credential/verifier to the XDR buffer; increments sequence number, calls `gss_get_mic()` or `gss_wrap()`.

**`gss_pipe_upcall()`** — invoked by `rpc_pipefs` when the daemon reads from the pipe; writes the UID to the read buffer.

**`gss_pipe_downcall()`** — invoked by `rpc_pipefs` when the daemon writes a context blob; deserialises into `gss_cl_ctx` and wakes waiting tasks.

**`svcauth_gss()`** (`net/sunrpc/auth_gss/svcauth_gss.c`) — server-side authentication function; looks up the context, checks sequence number, verifies/decrypts the call body.

**`gss_check_seq_num()`** — server-side replay detection; validates against the 128-entry window bitmask.

**`gss_import_sec_context()`** — mechanism entry point that turns a blob from `rpc.gssd` into a live `krb5_ctx` with keys loaded into the kernel crypto API.

**`gss_wrap()` / `gss_unwrap()`** (`net/sunrpc/auth_gss/gss_krb5_wrap.c`) — encrypt/decrypt a token using AES-CBC-CTS and append/verify the HMAC.

## Important Flags & Config Options

**`CONFIG_RPCSEC_GSS_KRB5`** — enables the Kerberos V5 GSS mechanism; without it, `krb5`, `krb5i`, `krb5p` mount options fail. Mandatory for RFC 3530 (NFSv4) compliance.

**`/proc/net/rpc/use-gss-proxy`** — write `1` before starting `nfsd` to switch from the legacy `rpc.svcgssd` upcall path to the `gssproxy` path. Irreversible per-boot; the legacy path is the default for backward compatibility.

**`/proc/net/rpc/auth.rpcsec.context`** (Sun RPC cache) — displays active server-side GSS contexts; useful for diagnosing context expiry or mismatched sequence numbers.

**`sunrpc.min_resvport` / `sunrpc.max_resvport`** (`/proc/sys/sunrpc/`) — control reserved-port policy for the RPC layer, relevant when Kerberos NFSv3 deployments rely on port-based access control.

## Interactions with Other Subsystems

- **↑ Userspace**: `rpc.gssd` reads upcall messages from `rpc_pipefs`, performs the full Kerberos exchange (talking to the KDC), and writes the serialised context back down. `gssproxy` provides the same service over a Unix socket with a proper RPC protocol. No kernel-to-KDC traffic ever occurs directly.
- **→ [[sunrpc]]**: RPCSEC_GSS registers as an `rpc_authops` with the SunRPC auth framework; the scheduler calls `gss_refresh()` and `gss_marshal()` as part of the standard task lifecycle.
- **→ [[xdr-encoding]]**: The GSS verifier and wrapped/MIC'd payload are XDR-encoded inline with the RPC header by `gss_marshal()` and decoded by `gss_verify_header()`.
- **→ Kernel Crypto API**: All symmetric encryption (AES) and HMAC operations use `crypto_skcipher` and `crypto_ahash` directly, avoiding any user-space crypto library.
- **← [[nfs-client]]**: The NFS client creates a `gss_auth` when mounting with `sec=krb5*`, and all `nfs_pgio_*` calls inherit that auth flavor.
- **← [[nfs-server]]**: The NFS server's request dispatcher calls `svcauth_gss()` as the authentication step before dispatching any NFSv4 operation.

## Design Decisions & Tradeoffs

**Kernel/userspace split at context establishment.** The defining architectural choice. Implementing GSSAPI fully in-kernel would drag in credential caches, keytab management, Kerberos protocol state machines, and complex policy logic, creating an enormous attack surface in privileged code. The cost is a synchronous context-switch on the first access for each new user — but this is a one-time cost amortised over the lifetime of the Kerberos ticket (typically 10 hours). Per-packet operations remain in-kernel to avoid per-I/O context switches.

**rpc_pipefs as the upcall channel.** Using a pseudo-filesystem rather than a netlink socket or ioctl was an explicit design choice: it keeps the interface file-descriptor based (easy to `select(2)`), avoids kernel/userspace ABI rigidity of ioctls, and lets the daemon's read/write calls follow the standard `file_operations` path already familiar to the rest of the kernel.

**Single mechanism: KRB5 only.** RFC 2203 allows any GSS mechanism; SPKM-3 was theoretically supported by earlier patches but was never widely deployed and was eventually dropped. Focusing on KRB5 allows tight integration with the kernel's crypto subsystem and avoids maintaining dead code. The OID is hardcoded into `gss_krb5_mech`.

**Sequence number replay window (128 entries).** The window size of `GSS_SEQ_WIN = 128` is a tradeoff between memory (one 128-bit bitmask per context) and tolerance for out-of-order packets in high-throughput environments. RFC 2203 requires *at least* a 1-entry window; 128 was chosen to handle typical network reordering without excess memory cost.

**gssproxy migration.** The legacy `rpc.svcgssd` upcall's 2 KiB token limit was a hardcoded buffer boundary that could not be safely enlarged without breaking the binary protocol. Rather than versioning the legacy protocol, a clean break to an RPC-over-Unix-socket protocol (`gssproxy`) was introduced, with opt-in via a sysctl to avoid disrupting existing deployments.

## How It Has Evolved

**2003 (2.6 era)**: Initial RPCSEC_GSS support merged by Trond Myklebust and J. Bruce Fields, implementing RFC 2203. Only DES3-CBC-SHA1 and RC4-HMAC enctypes were supported at first. The rpc_pipefs upcall mechanism was introduced at the same time.

**2007–2010**: AES support added (RFC 3962 enctypes 17 and 18), replacing DES3 as the recommended enctype. RC4-HMAC (arcfour-hmac) support added for interoperability with Active Directory Kerberos.

**2012**: `gssproxy` support introduced for the server side, controlled by `/proc/net/rpc/use-gss-proxy`, resolving the 2 KiB token size and 65K group limits of the legacy path.

**2016**: RC4-HMAC and DES3-CBC-SHA1 began to be deprecated in Kerberos standards; Linux kernel support was retained for backward compatibility but flagged for removal.

**2020–2022**: AES-SHA2 enctypes (RFC 8009, enctypes 19 and 20) added, providing AES-128 with HMAC-SHA256-128 and AES-256 with HMAC-SHA384-192, bringing the kernel in line with modern Kerberos deployments.

**2023–2024**: Work to remove legacy weak enctypes (DES3, arcfour-hmac) from the kernel, mirroring IETF deprecation in RFC 8429.

## Further Reading

1. [Kernel RPCSEC_GSS server documentation](https://docs.kernel.org/filesystems/nfs/rpc-server-gss.html) — official doc covering upcall mechanisms and gssproxy configuration
2. [LWN: Secure user authentication for NFS using RPCSEC_GSS (series)](https://lwn.net/Articles/19844/) — the original patch series explaining the design choices, 6 parts
3. [RFC 2203: RPCSEC_GSS Protocol Specification](https://datatracker.ietf.org/doc/html/rfc2203) — original protocol spec
4. [RFC 5403: RPCSEC_GSS v2](https://datatracker.ietf.org/doc/html/rfc5403) — adds channel bindings
5. [RFC 3962: AES Encryption for Kerberos 5](https://datatracker.ietf.org/doc/html/rfc3962) — defines the AES enctypes used by the kernel
6. [RFC 8009: AES Encryption with SHA-2](https://datatracker.ietf.org/doc/html/rfc8009) — modern AES-SHA2 enctypes
7. [gssd(8) man page](https://man7.org/linux/man-pages/man8/rpc.gssd.8.html) — how the userspace daemon operates

## LKML Highlights

- **Original RPCSEC_GSS series** (`lwn.net/Articles/19844/`): A 6-part patch series from 2003 by Trond Myklebust introducing the core architecture. The key design debate was whether to handle context establishment in-kernel (rejected as too complex) or in user space via rpc_pipefs (accepted). The series establishes the credential-cache decoupling that allows upcalls to serve multiple waiting tasks.
- **gssproxy server-side support** (2012, linux-nfs list): A 4-patch series adding the RPC-over-Unix-socket upcall path to resolve the `rpc.svcgssd` 2 KiB token limit; the commit message explicitly calls out Active Directory PAC tokens as the trigger.
