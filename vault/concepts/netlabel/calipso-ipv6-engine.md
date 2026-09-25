---
title: "CALIPSO/IPv6 Engine"
category: concept
tags: [netlabel, calipso, ipv6, security, labeled-networking, rfc5570]
subsystem: netlabel
kernel_version: "4.8"
researched: 2026-04-17
status: complete
explained: "[[calipso-ipv6-engine-explained]]"
sources:
  - https://www.paul-moore.com/blog/d/2016/12/calipso_intro.html
  - https://lwn.net/Articles/204905/
  - https://lore.kernel.org/all/1455715329-9601-7-git-send-email-huw@codeweavers.com/
---

# CALIPSO/IPv6 Engine

> 📘 Plain-language version: [[calipso-ipv6-engine-explained]]

## Purpose

CALIPSO (Common Architecture Label IPv6 Security Option, RFC 5570) is the IPv6 counterpart to the [[cipso-ipv4-engine]]. It embeds MLS/MCS security labels in an IPv6 hop-by-hop extension header, enabling mandatory access control enforcement across IPv6 networks. Before CALIPSO was merged (kernel 4.8), NetLabel had no in-band labeled networking support for IPv6.

## Mental Model

If [[cipso-ipv4-engine]] is a stamp on the back of an envelope, CALIPSO is a security badge clipped to the outside of a courier's bag — it rides in the hop-by-hop extension header that every router along the path is required to inspect. Both mechanisms carry the same information (security level and category bitmap) but in different envelope formats appropriate to their respective IP versions.

## How It Works

### Architectural Relationship to CIPSO

CALIPSO and CIPSO are separate protocol engines but share the same [[netlabel-lsm-security-api]] interface. An LSM calls `netlbl_sock_setattr()` regardless of IP version; the KAPI consults the [[netlabel-domain-hash-table]] to determine which engine to invoke, and for IPv6 destinations configured to use CALIPSO it calls into `net/ipv6/calipso.c`.

### DOI and Configuration

CALIPSO uses the same DOI concept as CIPSO: an administrator defines a CALIPSO DOI with a numeric ID via `netlabelctl calipso add doi:N ...`. The DOI is embedded in every CALIPSO hop-by-hop option. In contrast to CIPSO's three DOI types, CALIPSO (per RFC 5570) uses a simpler model: the security label in the packet corresponds directly to the sender's MLS/MCS label — there is no separate "trans" vs "pass" distinction at the protocol level. The DOI provides the context in which those labels are interpreted; all participating nodes in the network must share the same DOI definition.

Incoming CALIPSO traffic does not require explicit ingress configuration. Once the kernel knows about a CALIPSO DOI, it automatically interprets CALIPSO labels on any arriving IPv6 traffic that uses that DOI. This simplifies deployment compared to configurations that require symmetric inbound/outbound rules.

### Outbound Path

When an LSM configures an IPv6 socket for CALIPSO labeling, `calipso_sock_setattr()` is called. It:

1. Retrieves the `calipso_doi` structure for the requested DOI.
2. Encodes the MLS/MCS label from `netlbl_lsm_secattr` into a CALIPSO hop-by-hop option.
3. Attaches the option to the socket's IPv6 extension header anchor (`ipv6_txoptions`).

Subsequent packets from the socket carry the hop-by-hop option. Because CALIPSO is a hop-by-hop option (next header value 0), every IPv6 router on the path must examine it before forwarding — CALIPSO labels are therefore visible to intermediate network equipment, not just endpoints.

### CALIPSO Option Format (RFC 5570)

The CALIPSO option appears inside an IPv6 Hop-by-Hop Options extension header:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Option Type  |  Option Length|       Domain of Interp. (Hi)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|      Domain of Interpretation (Lo)    |  Cmpt Length  |  Sens |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Checksum    |                Categories ...                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

The `Sens` field is the sensitivity level (0–255); `Categories` is a variable-length bitmap; `Checksum` covers the DOI, sensitivity, and categories fields.

### Inbound Path

The IPv6 layer parses hop-by-hop options before passing the packet to higher layers. When a CALIPSO option is encountered, the kernel validates its format and checksum. In the `socket_sock_rcv_skb()` hook the LSM calls `netlbl_skbuff_getattr(skb, AF_INET6, &secattr)`, which routes to `calipso_skbuff_getattr()`. This function:

1. Locates the CALIPSO hop-by-hop option in the packet.
2. Finds the matching `calipso_doi`.
3. Decodes the sensitivity level and category bitmap into `secattr.attr.mls`.
4. Returns the populated `secattr` to the KAPI, which returns it to the LSM.

### SELinux Integration Example

After CALIPSO is configured, SELinux handles it transparently through the same code path it uses for CIPSO. When a socket is created for an IPv6 connection to a CALIPSO-configured peer, SELinux calls `netlbl_sock_setattr()` with the socket's security context translated to MLS attributes. The KAPI routes to the CALIPSO engine. On the receive side the CALIPSO label is decoded into `secattr` and SELinux maps it back to a security context via `security_netlbl_secattr_to_sid()`. The LSM code sees no difference between CIPSO and CALIPSO.

## Key Data Structures

**`struct calipso_doi`** (`include/net/calipso.h`) — analogous to `cipso_v4_doi`; one instance per configured CALIPSO DOI.
- `doi` — 32-bit DOI identifier
- `type` — currently always `CALIPSO_MAP_PASS`; CALIPSO does not define a translating mode in RFC 5570
- `refcount` — reference count
- `rcu` — RCU head for lockless deletion

## Key Functions / Entry Points

**`calipso_doi_add()`** (`net/ipv6/calipso.c`) — registers a new CALIPSO DOI; called by the NetLabel Netlink interface.

**`calipso_sock_setattr()`** — attaches a CALIPSO hop-by-hop option to an IPv6 socket; called by the KAPI.

**`calipso_skbuff_getattr()`** — decodes the CALIPSO option from an incoming IPv6 packet; called by `netlbl_skbuff_getattr()`.

**`calipso_doi_remove()`** — removes a DOI and decrements the reference count.

## Important Flags & Config Options

- `CONFIG_CALIPSO` — enables CALIPSO/IPv6; requires kernel ≥ 4.8.
- Requires `netlabel-tools` ≥ 0.30.0 for the `netlabelctl calipso` subcommand.

## Interactions with Other Subsystems

- **↑ Userspace**: `netlabelctl calipso add doi:N ...` registers DOIs; address mappings via `netlabelctl map add domain:... address:... protocol:calipso,N`.
- **→ [[net]] (IPv6)**: CALIPSO options are embedded in IPv6 hop-by-hop extension headers via `ipv6_txoptions`. The IPv6 layer processes the option during forwarding.
- **← [[netlabel-lsm-security-api]]**: Exclusive caller; LSMs never call CALIPSO functions directly.
- **← [[selinux]] / [[smack]]**: Both LSMs use CALIPSO via the shared KAPI after IPv6 address mappings are configured.

## Design Decisions & Tradeoffs

**Hop-by-hop vs. destination option**: RFC 5570 mandates hop-by-hop placement, meaning every intermediate router must inspect the CALIPSO option. This is architecturally correct for MLS networks (labels should be visible to MLS-aware routers) but adds overhead on every hop. An alternative would have been a destination option (only processed at endpoints), but this would prevent network-level enforcement.

**No TRANS DOI type**: Unlike CIPSO, CALIPSO RFC 5570 does not define a translating DOI mode. Two systems must use the same numeric label values within a DOI. This simplifies the implementation at the cost of inflexibility in heterogeneous networks.

**Late arrival (4.8, 2016)**: CALIPSO arrived a decade after CIPSO because IPv6 adoption in MLS/government environments was slow and CIPSO was sufficient. When IPv6 became unavoidable in those environments, Huw Davies (CodeWeavers) contributed the implementation.

## How It Has Evolved

- **4.8 (2016)**: Initial merge as a 19-patch series by Huw Davies, reviewed by Paul Moore. Included updates to SELinux, Smack, and the [[netlabel-domain-hash-table]] to support a second IPv6 protocol type (`NETLBL_NLTYPE_CALIPSO`).
- **Post-4.8**: Minor fixes to the checksum calculation and hop-by-hop option building; no major architectural changes.

## Further Reading

1. [IPv6 Labeled Networking with CALIPSO — Paul Moore](https://www.paul-moore.com/blog/d/2016/12/calipso_intro.html)
2. RFC 5570 — Common Architecture Label IPv6 Security Option
3. [CALIPSO LKML patch series](https://lore.kernel.org/all/1455715329-9601-7-git-send-email-huw@codeweavers.com/)

## LKML Highlights

- **RFC PATCH v3 series (2016)**: Huw Davies submitted the 19-patch CALIPSO series. Key discussion: how the domain hash table should distinguish CIPSO (IPv4) from CALIPSO (IPv6) entries without duplicating logic — resolved by keying entries on address family (`AF_INET` vs `AF_INET6`) within the domain hash. Message-ID: `1455715329-9601-7-git-send-email-huw@codeweavers.com`
