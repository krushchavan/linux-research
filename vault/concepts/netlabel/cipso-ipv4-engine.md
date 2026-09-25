---
title: "CIPSO/IPv4 Engine"
category: concept
tags: [netlabel, cipso, ipv4, security, labeled-networking]
subsystem: netlabel
kernel_version: "2.6.19"
researched: 2026-04-17
status: complete
explained: "[[cipso-ipv4-engine-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/netlabel/cipso_ipv4.html
  - https://lwn.net/Articles/204905/
  - https://docs.kernel.org/netlabel/cipso_ipv4.html
  - https://docs.huihoo.com/doxygen/linux/kernel/3.7/structnetlbl__lsm__secattr.html
---

# CIPSO/IPv4 Engine

> 📘 Plain-language version: [[cipso-ipv4-engine-explained]]

## Purpose

The CIPSO (Commercial IP Security Option) engine is [[netlabel]]'s protocol engine for attaching security labels to IPv4 packets. It embeds a label into the IPv4 options field of every packet sent from a labeled socket, enabling remote trusted systems to enforce mandatory access control based on the sender's security clearance. Without this engine there is no way to propagate security context across an IPv4 network between MLS-capable hosts.

## Mental Model

Think of CIPSO as a tamper-evident wax seal on a government envelope. The sender stamps the seal (the CIPSO IP option) with their security clearance level; every router along the path can see the seal without breaking it; and the recipient verifies the seal before deciding whether to accept the contents. The DOI is the codebook that both sender and recipient agree on in advance — it defines what the numbers in the seal actually mean.

## How It Works

### Domain of Interpretation (DOI)

Before any packet can be labeled, an administrator must define at least one DOI via `netlabelctl` (which eventually calls `cipso_v4_doi_add()`). A DOI is a numbered mapping table identified by a 32-bit integer embedded in every CIPSO option header. The DOI number is what tells the receiving system how to interpret the sensitivity level and category bitmap in the packet.

There are three DOI types that govern how translation happens:

**TRANS (translating)**: The DOI holds two parallel arrays — `lvl_loc[]` mapping local sensitivity levels to network levels, and `lvl_rem[]` mapping the reverse. Category translation uses a bitmap that maps local category numbers to network category numbers. This type allows two systems that use different internal numbering to interoperate: host A might use local level 3 for "Secret" while host B uses local level 7, but both agree that network level 5 means "Secret" within this DOI.

**PASS (passthrough)**: No translation is performed. The CIPSO numbers are used as-is on the wire and must match the local security levels exactly. Both endpoints must share the same numbering scheme. Simpler to configure but less flexible than TRANS.

**LOCAL**: A special pseudo-protocol for loopback traffic. Instead of a proper CIPSO option, the full binary LSM security label is carried over the loopback interface only. This exists because CIPSO's numeric encoding cannot represent arbitrary security contexts, but for localhost communication the label can be transmitted verbatim. Packets with the LOCAL type are never forwarded off-host.

### Outbound Path

When an LSM calls `netlbl_sock_setattr()` for an IPv4 socket, the [[netlabel-lsm-security-api]] routes the call to `cipso_v4_sock_setattr(sk, doi, secattr)`. This function:

1. Looks up the `cipso_v4_doi` structure for the requested DOI number.
2. Translates the `netlbl_lsm_secattr` (containing `attr.mls.lvl` and `attr.mls.cat`) into a binary CIPSO option using the DOI's mapping table.
3. Allocates an `ip_options` structure and stores the encoded CIPSO option in it.
4. Attaches the option to `inet_sk(sk)->inet_opt`.

From this point on, the kernel's IP output path (`ip_options_build()`) automatically copies the stored option into the IP header of every packet the socket emits. No per-packet LSM call is required — the option is baked into the socket once and replicated for each packet.

Labels can be changed after socket creation (e.g. if a process changes security level mid-session) by calling `cipso_v4_sock_setattr()` again, though this is unusual in practice.

### CIPSO Option Format

The CIPSO IPv4 option has the structure:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Type (0x86)  |    Length     |         DOI (32-bit)          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   DOI (cont)  |  Tag Type     | Tag Length    | Sensitivity   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                   Category Bitmap ...                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

The option type byte `0x86` is registered as a Class 2, Number 6 IP option (copied, not routed). The DOI occupies 4 bytes. The tag type field identifies the encoding format; tag type 1 (sensitivity + category bitmap) is the most common.

### Inbound Path

When an IPv4 packet carrying a CIPSO option arrives, the IPv4 layer validates the option format in `cipso_v4_validate()`. If the option is syntactically invalid or references an unknown DOI, the packet is dropped with an ICMP error. This automatic validation happens before the packet reaches the socket layer, so the LSM need not worry about malformed options.

When the packet reaches the socket layer, the LSM's `socket_sock_rcv_skb()` hook calls `netlbl_skbuff_getattr(skb, AF_INET, &secattr)`. The KAPI detects the CIPSO option in the sk_buff's IP header and calls `cipso_v4_skbuff_getattr()`, which:

1. Extracts the DOI number from the option.
2. Looks up the `cipso_v4_doi` structure.
3. **Cache check**: calls `cipso_v4_cache_check()`. If the option bytes hash to a known entry in the per-DOI cache, the cached `netlbl_lsm_secattr` (with its pre-translated `secid`) is returned immediately. This is the fast path for established connections.
4. **Cache miss**: translates the sensitivity level and category bitmap using the DOI's mapping tables, populates `secattr.attr.mls.lvl` and `secattr.attr.mls.cat`, and stores the result in the cache via `cipso_v4_cache_add()`.

The LSM receives the populated `secattr`, converts it to an internal security ID (e.g. SELinux calls `security_netlbl_secattr_to_sid()`), and enforces its access control policy.

### Label Mapping Cache

The cache is a fixed-size hash table of `cipso_v4_doi_entry` nodes allocated per-DOI. The cache key is a hash of the raw CIPSO option bytes; the value is the translated `netlbl_lsm_secattr` plus the LSM's `secid`. Cache entries are created on first decode and invalidated when the DOI definition is removed.

The cache trades memory for CPU: once a label is decoded once, all subsequent packets with the same label are processed with only a hash lookup. In practice, most connections use the same label for their entire lifetime, so the cache hit rate is high.

## Key Data Structures

**`struct cipso_v4_doi`** (`include/net/cipso_ipv4.h`) — one instance per configured DOI; the root of all CIPSO state for that DOI.
- `doi` — 32-bit identifier embedded in every CIPSO option using this DOI
- `type` — `CIPSO_V4_MAP_TRANS`, `CIPSO_V4_MAP_PASS`, or `CIPSO_V4_MAP_LOCAL`
- `map.std.lvl.local[]` / `map.std.lvl.remote[]` — TRANS type: local↔network sensitivity level arrays
- `map.std.cat.local` / `map.std.cat.remote` — TRANS type: category bitmap translation
- `cache` — pointer to the hash table of decoded label entries
- `flags` — `CIPSO_V4_DOI_F_V1` set when valid; cleared atomically when being removed
- `refcount` — reference count; DOI freed only when zero (all sockets released)
- `list` — links DOIs into the global `cipso_v4_doi_list`

## Key Functions / Entry Points

**`cipso_v4_doi_add()`** (`net/ipv4/cipso_ipv4.c`) — called by `netlbl_cipsov4_add()` when the Netlink interface receives a new DOI; validates the DOI, inserts into `cipso_v4_doi_list`, allocates the cache.

**`cipso_v4_sock_setattr()`** — attaches a CIPSO option to a socket; called by the NetLabel LSM API for outbound labeling.

**`cipso_v4_skbuff_getattr()`** — decodes the CIPSO option from an sk_buff; called by `netlbl_skbuff_getattr()` in the inbound path.

**`cipso_v4_validate()`** — validates a CIPSO option at the IP layer; called before the packet reaches the socket; drops the packet if invalid.

**`cipso_v4_cache_add()`** — inserts a decoded label into the per-DOI cache after a cache miss.

**`cipso_v4_doi_remove()`** — removes a DOI; invalidates the cache and decrements the refcount.

## Important Flags & Config Options

- `CONFIG_CIPSO_IPV4` — compiles the CIPSO engine; typically auto-selected by `CONFIG_NETLABEL` which is pulled in by SELinux or Smack.
- `CONFIG_CIPSO_IPV4_DEBUG` — enables additional consistency checks; not for production.
- `CIPSO_V4_CACHE_BUCKETS` / `CIPSO_V4_CACHE_MAXSIZE` — compile-time constants that control the per-DOI cache hash table size and maximum entries. Tuning is rarely needed but relevant in embedded builds with memory pressure.

## Interactions with Other Subsystems

- **↑ Userspace**: `netlabelctl cipsov4 add trans doi:N ...` configures DOI mappings via Generic NETLINK; `netlabelctl cipsov4 list` dumps them.
- **→ [[net]] (IPv4)**: CIPSO options are embedded in `ip_options` structures that the IPv4 output path copies into packet headers. Inbound validation hooks into the IP option parsing phase.
- **← [[netlabel-lsm-security-api]]**: The KAPI is the only caller; LSMs never call CIPSO functions directly.
- **← [[selinux]]**: SELinux calls the KAPI for both outbound labeling and inbound context derivation.
- **← [[smack]]**: Smack uses the KAPI identically to SELinux; uses `smack_netlabel()` as its entry point.

## Design Decisions & Tradeoffs

**Why the IETF draft, not a real RFC?** The CIPSO draft from 1992 was never ratified, but it was already implemented in Trusted Solaris and other commercial MLS systems. Using it meant Linux could interoperate with existing infrastructure without inventing a new protocol. The decision sacrificed protocol elegance for real-world compatibility.

**DOI per socket, not per packet**: The CIPSO option is set at socket level so all packets from a socket carry the same label. This is simpler and faster than per-packet labeling but means a single socket cannot send packets at different security levels — the LSM must open separate sockets for different clearances.

## How It Has Evolved

- **2.6.19**: Initial merge — only tag type 1 (sensitivity + category bitmap) supported; only TRANS and PASS DOI types; SELinux only.
- **2.6.20+**: LOCAL DOI type added for loopback; Smack support via the shared KAPI.
- **2.6.28**: Address selector integration — the CIPSO engine is now selected per-destination by the domain hash table, not only per-domain.
- **6.x**: Continued cleanup and audit integration; `cipso_v4_skbuff_err()` added to generate correct ICMP errors when a CIPSO-labeled packet is rejected.

## Further Reading

1. [Netlabel: CIPSO labeling for Linux (LWN)](https://lwn.net/Articles/204905/)
2. [NetLabel CIPSO/IPv4 Protocol Engine — kernel.org](https://docs.kernel.org/netlabel/cipso_ipv4.html)
3. IETF CIPSO Draft (July 1992) — referenced in the kernel documentation but not published as an RFC.

## LKML Highlights

- **CIPSO RFC submission (2006)**: Paul Moore's initial patch series framed CIPSO as "tread as lightly as possible on the core networking stack" — the key constraint that led to the socket-level option design rather than per-packet hooks.
- **Smack CIPSO integration**: The addition of Smack as a second NetLabel consumer required no changes to the CIPSO engine, validating the protocol-agnostic API design.
