---
title: "Smack Network Labeling"
category: concept
tags: [security, smack, lsm, networking, cipso, netlabel, mac]
subsystem: security
kernel_version: "2.6.30"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html
  - https://www.kernel.org/doc/html/v5.4/netlabel/cipso_ipv4.html
  - https://github.com/torvalds/linux/blob/master/security/smack/smack.h
  - https://github.com/torvalds/linux/blob/master/security/smack/smack_lsm.c
  - https://www.static.linuxfound.org/jp_uploads/seminar20080709/paul_moore-r1.pdf
---

# Smack Network Labeling

## Purpose

Smack enforces MAC policy inside a single host using xattrs and task credentials, but without network labeling, two processes in different Smack domains on *different* hosts could communicate freely. Smack network labeling extends the MAC boundary across IP networks by embedding Smack labels in outgoing packets (via CIPSO/CALIPSO) and decoding labels from incoming packets, so the access engine can apply the same subject→object rules to network traffic as it does to file access.

## Mental Model

Every packet that leaves a Smack-enabled host carries a sticky label in its IP header. Every packet that arrives is read for its label. The receiving kernel treats a network peer as if it were a process with a specific Smack label: before handing data to a socket, it checks whether the sending peer's label has write access to the receiving process's label. This models sending data as "writing to the receiver" — the same intuition used for files.

## How It Works

Smack delegates all wire-format label encoding and decoding to the [[netlabel]] kernel subsystem. NetLabel provides an abstraction over CIPSO (for IPv4) and CALIPSO (for IPv6), so Smack never touches IP option headers directly.

### Outbound labeling

When a task sends data through a socket, the kernel eventually calls `smack_netlabel()` (via `smack_ip_output()` and hooks on `sock_sendmsg()`). This function looks up the socket's outbound label from `socket_smack.smk_out` — which defaults to the creating task's `smk_task` at socket creation time (`smack_sk_alloc_security()`). It then calls `netlbl_sock_setattr()` with the pre-computed `struct netlbl_lsm_secattr` stored in `smack_known->smk_netlabel`. NetLabel encodes this as a CIPSO Type 1 tag appended to the IPv4 options header, using DOI 3 (configurable via `smackfs/doi`). For IPv6, NetLabel uses CALIPSO (RFC 5570) instead.

The `smk_netlabel` field is computed once at label import time by `smk_netlbl_mls()`, which maps the label's hash into a CIPSO category bitmask. This avoids per-packet string operations: tagging a packet costs one pointer lookup and a netlink message to the NetLabel stack.

### Inbound label decoding

When a packet arrives, `smack_socket_sock_rcv_skb()` is called. It invokes `netlbl_skbuff_getattr()` to decode any CIPSO/CALIPSO tag from the packet's IP options. If a tag is found, NetLabel returns a `netlbl_lsm_secattr` structure, which Smack maps back to a canonical `smack_known` pointer by walking the label registry. This resolved label is stored in `socket_smack.smk_packet` for the duration of the connection.

If no CIPSO tag is present, the packet is treated as carrying the `ambient` label (configurable via `smackfs/ambient`, default `"_"` which is the floor label — readable by everyone). This allows non-Smack peers to communicate with Smack hosts as long as the ambient label has the right access rules.

### Per-host overrides

Not all network peers support CIPSO. The `smackfs/netlabel` interface creates `struct smk_net4addr` (IPv4) or `struct smk_net6addr` (IPv6) entries that bypass CIPSO decoding: packets from `192.168.1.5/32` are always given label `"webserver"`, regardless of CIPSO content. These overrides are consulted in `smack_socket_sock_rcv_skb()` *before* CIPSO decoding, so they take absolute precedence.

### Connection-time access check

For TCP and other connected protocols, `smack_socket_connect()` is called before the connection is established. It resolves the peer's expected label (from the destination address via `smk_net4addr` lookup, or from the socket's configured `smk_packet`) and checks that the connecting task has **write access** to that label. Smack models a connection as "the local process writes to the remote peer", so write permission is required to establish a socket connection to a labeled host. A denial here blocks the `connect(2)` call before any SYN is sent.

For incoming connections, `smack_inet_conn_request()` validates that the connecting peer's label (decoded from the CIPSO tag in the SYN packet) has write access to the server process's label.

### Socket label inheritance

Sockets inherit their Smack label from the task that created them (`smack_sk_alloc_security()` copies `current->smk_task` into `socket_smack.smk_out`). The `smk_in` label defaults to the same value and is used for incoming connection checks. Privileged processes may change `smk_out` and `smk_in` via socket options `SO_PEERSEC` (read) and internal netlink interfaces, but most deployments leave the defaults.

## Key Data Structures

**`struct socket_smack`** (`security/smack/smack.h`) — Smack security blob for a socket.
- `smk_out` — outbound label; embedded in CIPSO tags on all outgoing packets from this socket
- `smk_in` — inbound label; used for access checks on incoming connections
- `smk_packet` — label decoded from the most recently received CIPSO/CALIPSO packet; updated per-packet on connected sockets
- `smk_state` — `SMACK_NETLBL_UNSET` / `SMACK_NETLBL_UNLABELED` / `SMACK_NETLBL_LABELED`; tracks whether NetLabel has been configured for this socket

**`struct smk_net4addr`** (`security/smack/smack.h`) — per-host IPv4 label override.
- `smk_host` — IPv4 address (`struct in_addr`)
- `smk_mask` — IPv4 network mask
- `smk_label` — canonical `smack_known*` to assign to matching packets

**`struct smk_net6addr`** (`security/smack/smack.h`) — per-host IPv6 label override (same fields adapted for IPv6).

## Key Functions / Entry Points

**`smack_netlabel()`** (`security/smack/smack_lsm.c`) — applies the outbound Smack label to a socket via `netlbl_sock_setattr()`; called at connect/bind time.

**`smack_socket_connect()`** (`security/smack/smack_lsm.c`) — checks that the connecting task has write access to the peer label before `connect(2)` returns; blocks the syscall on denial.

**`smack_socket_sock_rcv_skb()`** (`security/smack/smack_lsm.c`) — decodes incoming CIPSO/CALIPSO label; checks write access from peer label to local socket label; drops packet on denial.

**`smack_inet_conn_request()`** (`security/smack/smack_lsm.c`) — validates incoming TCP SYN: peer CIPSO label must have write access to the server process label.

**`smk_netlbl_mls()`** (`security/smack/smack_lsm.c`) — converts a Smack label string into a NetLabel MLS attribute (CIPSO category bitmask); called once at label import time.

## Important Flags & Config Options

- `smackfs/doi` — CIPSO Domain of Interpretation (default 3); must match all CIPSO-speaking peers
- `smackfs/ambient` — label for unlabeled incoming packets (default `"_"`)
- `smackfs/cipso2` — CIPSO DOI/level/category → Smack label mapping; written for each label that needs network representation
- `smackfs/netlabel` — per-host address → label overrides for non-CIPSO peers
- `CONFIG_IPV6` — required for CALIPSO/IPv6 network labeling support
- `CONFIG_NETLABEL` — required; Smack network labeling is entirely disabled without this

## Interactions with Other Subsystems

- **↑ Userspace**: `smackfs/netlabel` and `smackfs/cipso2` are the only administration points; no userspace daemon needed for enforcement
- **→ [[netlabel]]**: all CIPSO/CALIPSO encoding/decoding is delegated to NetLabel; Smack only passes `netlbl_lsm_secattr` structures
- **→ [[smack-access-engine]]**: `smk_access()` is called with the decoded peer label as subject and local socket label as object; same decision function as file access
- **← [[net]]**: socket hooks (`smack_socket_connect`, `smack_socket_sock_rcv_skb`) are called by the network stack at socket operation boundaries
- **← [[smack-label-registry]]**: decoded CIPSO labels are resolved to canonical `smack_known` entries via `smk_find_entry()`

## Design Decisions & Tradeoffs

**CIPSO as the wire protocol** — CIPSO is an IETF draft (never RFC) from 1992 that became a de facto standard in trusted operating systems. Smack chose it because NetLabel already supported it, it is understood by some commercial network hardware, and implementing a new labeled-network protocol would have been a much larger undertaking. The cost is that CIPSO is IPv4-only; IPv6 required a separate standard (CALIPSO, RFC 5570) that Smack added later via the same NetLabel abstraction.

**Sending = writing** — modeling a network send as a *write* from the sender to the receiver is intuitive for confidentiality: if A cannot write to B, A cannot send B data (preventing information leakage). It also means socket connection permissions mirror file write permissions, keeping the policy mental model uniform.

**Single CIPSO label per packet** — each packet carries exactly one Smack label. When LSM stacking enables Smack and SELinux to coexist, both modules will want to embed their own label in each packet, but the CIPSO header can only carry one security context. This is one of the remaining blockers for full LSM stacking.

**Per-host overrides for legacy peers** — the `netlabel` overrides allow Smack to operate in mixed environments where some peers do not support CIPSO. By assigning a fixed label to a legacy host's address, the policy can still make meaningful access decisions about traffic from that host. The tradeoff is that label assignment then depends on the source IP, which can be spoofed.

## How It Has Evolved

- **2.6.30**: CIPSO integration via NetLabel added; initial `smackfs/netlabel` and `smackfs/cipso2` interfaces.
- **3.x**: `smk_net4addr` per-host override table added; socket label inheritance model stabilised.
- **4.x**: CALIPSO (IPv6) support added via NetLabel CALIPSO engine; `smk_net6addr` struct added.
- **5.x**: socket labeling refactored to use LSM-managed blobs rather than raw `sk->sk_security` pointer; socket Smack state tracks `SMACK_NETLBL_*` transitions more precisely.

## Further Reading

1. [Smack — kernel.org documentation (networking section)](https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html)
2. [NetLabel CIPSO/IPv4 Protocol Engine — kernel.org](https://www.kernel.org/doc/html/v5.4/netlabel/cipso_ipv4.html)
3. [Paul Moore: NetLabel and Smack — Linux Foundation slides (2008)](https://www.static.linuxfound.org/jp_uploads/seminar20080709/paul_moore-r1.pdf)

## LKML Highlights

- **[PATCH] Version 7 (2.6.23) Smack** — original submission included the CIPSO networking model; reviewers questioned whether CIPSO was the right choice given its IETF draft (not RFC) status; Casey Schaufler's response that it was already a de facto standard in trusted OS history was accepted.
