---
title: "RPCSEC_GSS and Kerberos — Explained"
category: explained
original: "[[rpcsec-gss-and-kerberos]]"
subsystem: nfs
tags: [explained, nfs, kerberos, rpcsec-gss, security]
converted: 2026-09-25
---

# RPCSEC_GSS and Kerberos, explained

> Plain-language companion to [[rpcsec-gss-and-kerberos|the technical note]]. Same facts, fewer identifiers.

## The problem

With plain NFS authentication (AUTH_SYS), the client simply states "I am user 1000, group 100", and the server believes it. Anyone who controls a client machine, or can forge packets, can claim to be anyone. Nothing stops traffic from being read or altered in transit either.

Real security means proving identity cryptographically on every call and optionally protecting the data itself, without sending passwords over the wire and without slowing down every read and write. The hard part is that establishing trust (talking to a Kerberos server, managing tickets) is complex, while protecting each packet must be fast.

## The idea in one paragraph

RPCSEC_GSS wraps **every RPC in a security envelope**. Before a call leaves the client, a small cryptographic token is attached: a signature over the call (integrity), or the whole payload encrypted (privacy). The server checks it against a shared secret before acting. That secret is a key derived from a **Kerberos service ticket**, obtained beforehand from a Key Distribution Center, so no password ever crosses the network. Linux splits the work: user-space daemons do the slow, complicated part of getting tickets and setting up a security context; the kernel does only the fast per-packet signing, checking and encryption.

## Step by step

### Step 1: Choose a protection level
Mounts and exports use one of three levels, all Kerberos V5 underneath:
- **krb5:** identity is proven, data travels in the clear
- **krb5i:** identity plus a signature on each call, so tampering is detected
- **krb5p:** identity, signature, and the payload encrypted

The level is negotiated at mount time or set in the server's export configuration.

### Step 2: The kernel asks user space for a context
This is the key design choice. When a call needs credentials for a user and none are cached, the kernel sends an **upcall** through a small pseudo-filesystem used as a meeting point with user-space daemons:
1. the RPC machinery sees that the call's credential is missing or expired
2. a message containing only the user's ID is queued on the pipe
3. the call sleeps; other calls needing the same user's credentials wait on the same message, so one upcall serves them all
4. the `rpc.gssd` (or `gssproxy`) daemon reads the ID, uses that user's Kerberos credentials, performs the full exchange with the Key Distribution Center, and writes the resulting security context back down the pipe
5. the kernel unpacks it: the handle the server will recognise, the session key, and the sequence window
6. all the waiting calls wake and proceed

The kernel never touches a Kerberos ticket, only the derived session key and a context handle. Doing the full protocol in the kernel would mean pulling in a large Kerberos implementation, credential caches, keytabs and policy logic, a big attack surface in privileged code. The cost is one trip to user space per new user, spread over the ticket's lifetime (typically 10 hours).

### Step 3: Cache credentials per user
Each RPC connection keeps a per-user table of credentials, each pointing to its live security context, its protection level and an expiry time. Credentials are refreshed in the background before they expire.

### Step 4: Protect each outgoing call
For every call, the client adds the security header:
1. the context handle, so the server can find the matching key
2. the next **sequence number**, taken atomically; numbers prevent replay attacks
3. depending on the level: a signature over the header only, a signature over header and payload, or the whole body encrypted

Replies are checked the same way. A bad signature fails the call with a permission error; running out of sequence numbers forces a new context.

### Step 5: Check on the server
For each incoming call the server:
1. finds the context by the handle in the call (new contexts go up to `gssproxy` or the legacy daemon, just as on the client)
2. checks the sequence number against a sliding **replay window** of 128 entries, kept as a bitmask: accept if within the window and unseen, drop if already seen (a replay) or too old
3. verifies the signature or decrypts the body
4. records the verified user and group IDs, and hands the call to the NFS server

The 128-entry window is a trade between memory and tolerance of packets arriving out of order on busy networks; the standard requires at least one.

### Step 6: The crypto itself
The Kerberos mechanism is registered with the kernel's GSS layer. It imports the context blob from user space into a key record, then signs with HMAC and encrypts with AES in ciphertext-stealing mode, all through the kernel crypto API with no user-space library. Supported encryption types include AES-128 and AES-256 with HMAC-SHA1, and the newer AES with HMAC-SHA256/384 types. DES3 and RC4 variants are being removed as weak.

### Step 7: Two server-side upcall paths
- **Legacy (`rpc.svcgssd`):** a text protocol over the pipe, with tokens capped at 2 KiB. That's too small for large Active Directory tickets carrying authorisation data, or for users in very many groups.
- **Modern (`gssproxy`):** an RPC protocol over a Unix socket with no token limit. It's switched on by writing to a control file before the NFS server starts, and the choice lasts until reboot.

Rather than versioning the legacy protocol, whose buffer limit couldn't be raised safely, the modern path was added as an opt-in replacement.

## The picture

```text
 CLIENT                                                   SERVER
 call as uid 1000 ─ no credential? ─▶ upcall(uid) ─▶ rpc.gssd ─▶ Kerberos KDC
                  ◀── context (handle, session key) ◀──┘
 call + [handle | seq 812 | signature or encrypted body] ──────▶ find context
                                                                 seq in window & unseen?
                                                                 verify / decrypt
                                                                 → run as verified uid
```

## Tradeoffs

- **What it gives you:** cryptographically verified identity on every call, optional integrity and encryption, replay protection, and no passwords on the wire, with per-packet work kept in the kernel for speed.
- **What it costs / requires:** a Kerberos infrastructure (KDC, keytabs, daemons), a user-space round trip for each new user, and crypto work on every packet (especially with krb5p).
- **Where it bites:** the legacy server upcall's 2 KiB limit breaks with large Active Directory tickets or users in many groups; switching to `gssproxy` fixes it, but only if done before the NFS server starts, and it can't be undone without a reboot.

## How it got here

- **2003:** RPCSEC_GSS arrives (Trond Myklebust, J. Bruce Fields), with the pipe-based upcall. The key design debate, context setup in the kernel versus user space, went to user space.
- **2007–2010:** AES encryption types, plus RC4 for Active Directory interoperability.
- **2012:** `gssproxy` support for the server, fixing token-size and group-count limits.
- **2016:** RC4 and DES3 deprecated in Kerberos standards; kept for compatibility.
- **2020–2022:** AES with SHA-2 encryption types. **2023–2024:** removing the weak legacy types.

## Related

- Technical version: [[rpcsec-gss-and-kerberos]]
- [[nfs-explained|NFS subsystem]], [[sunrpc|SUNRPC]], [[xdr-encoding|XDR]], [[nfs-client-explained|NFS client]], [[nfs-server-explained|NFS server]]
- [[kernel-crypto-api|Kernel crypto API]], [[security|Security]]
