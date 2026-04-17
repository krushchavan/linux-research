---
title: "NetLabel LSM Security API"
category: concept
tags: [netlabel, lsm, security, labeled-networking, api]
subsystem: netlabel
kernel_version: "2.6.19"
researched: 2026-04-17
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/netlabel/lsm_interface.html
  - https://docs.huihoo.com/doxygen/linux/kernel/3.7/structnetlbl__lsm__secattr.html
  - https://docs.huihoo.com/doxygen/linux/kernel/3.7/include_2net_2netlabel_8h_source.html
  - https://lwn.net/Articles/185491/
---

# NetLabel LSM Security API

## Purpose

The NetLabel LSM Security API is the protocol-agnostic interface through which Linux Security Modules interact with [[netlabel]]. It hides whether CIPSO or CALIPSO is in use so that SELinux and Smack can be written once and work correctly with any configured labeling protocol. Without this layer, each LSM would need separate code paths for every on-the-wire label format — a maintenance burden that grows with every new protocol.

## Mental Model

The LSM API is a language interpreter between two different vocabularies. The LSM speaks in security contexts (SELinux SIDs, Smack labels); the network speaks in CIPSO option bytes or CALIPSO hop-by-hop headers. The LSM API is the translator that converts between these two representations, consulting the [[netlabel-domain-hash-table]] to know which language the network on the other side is using.

## How It Works

### The Central Data Type: `netlbl_lsm_secattr`

The `netlbl_lsm_secattr` structure is the shared "sentence" that travels between the LSM and the NetLabel internals. It represents a security label in a wire-format-neutral way. Before calling any outbound API, the LSM fills this structure with the socket's security context translated into MLS terms. After calling any inbound API, the LSM reads MLS attributes back from the structure and converts them to its own internal security identifier.

The `flags` bitmask is critical: it indicates which fields are actually populated. Checking `flags` before reading any field is mandatory because not all protocols populate all attributes.

```c
struct netlbl_lsm_secattr {
    u32 flags;          /* NETLBL_SECATTR_* bitmask */
    u32 type;           /* NLTYPE_* — which protocol filled this */
    char *domain;       /* set by LSM before outbound call */
    netlbl_lsm_cache *cache; /* non-NULL when cache path is active */
    union {
        struct {
            netlbl_lsm_catmap *cat; /* MLS category bitmap */
            u32 lvl;                /* MLS sensitivity level */
        } mls;
        u32 secid;                  /* LSM-internal security ID */
    } attr;
};
```

`NETLBL_SECATTR_MLS_LVL` and `NETLBL_SECATTR_MLS_CAT` indicate that `attr.mls.lvl` and `attr.mls.cat` are valid — set on both outbound calls and inbound results from CIPSO/CALIPSO. `NETLBL_SECATTR_SECID` indicates `attr.secid` is valid — used when the cache short-circuits the full decode.

### Outbound Flow: Labeling a Socket

An LSM labels a socket by:

1. Calling `netlbl_secattr_init(&secattr)` to zero the structure.
2. Setting `secattr.domain` to the domain string identifying this socket's security context.
3. Translating the socket's security context into MLS attributes: `secattr.attr.mls.lvl = level; secattr.attr.mls.cat = catmap; secattr.flags |= NETLBL_SECATTR_MLS_LVL | NETLBL_SECATTR_MLS_CAT`.
4. Calling `netlbl_sock_setattr(sk, family, &secattr)`.
5. Calling `netlbl_secattr_destroy(&secattr)` to free the category bitmap and domain string.

Inside `netlbl_sock_setattr()`, the KAPI:
- Calls `netlbl_domhsh_getentry_af(secattr.domain, family, dst_addr)` to look up the labeling policy.
- Dispatches to `cipso_v4_sock_setattr()` or `calipso_sock_setattr()` based on the returned entry type.
- If the entry type is `UNLABELED`, removes any existing label from the socket.

### Inbound Flow: Decoding a Packet's Label

An LSM decodes a labeled packet in its `socket_sock_rcv_skb()` hook by:

1. Calling `netlbl_secattr_init(&secattr)`.
2. Calling `netlbl_skbuff_getattr(skb, family, &secattr)`.
3. Checking `secattr.flags`:
   - If `NETLBL_SECATTR_SECID` is set, the cache was hit — `secattr.attr.secid` is the LSM's security ID, directly usable without translation.
   - Otherwise, translate `secattr.attr.mls.lvl` and `secattr.attr.mls.cat` into an internal security ID (e.g. `security_netlbl_secattr_to_sid()` in SELinux).
4. Enforcing access control based on the resolved security ID.
5. Calling `netlbl_secattr_destroy(&secattr)`.

Inside `netlbl_skbuff_getattr()`, the KAPI:
- Inspects the sk_buff for a CIPSO IPv4 option or CALIPSO hop-by-hop option.
- If neither is present, calls `netlbl_unlabel_getattr()` to apply the configured unlabeled traffic policy.
- If a CIPSO or CALIPSO option is present, routes to the appropriate engine's `skbuff_getattr` function.
- Checks the label cache; on a hit, sets `NETLBL_SECATTR_SECID` in flags and returns immediately.

### The Label Mapping Cache

The cache stores `(network label bytes → LSM secid)` mappings. Its purpose is to eliminate repeated work: decoding a CIPSO option and calling back into the LSM's context lookup can be expensive for high-throughput connections. The cache bypasses both NetLabel's translation logic and the LSM's `secattr_to_sid()` call in one step.

Cache entries are populated by `netlbl_cache_add()`, which the protocol engine (or the LSM itself) calls after a successful decode. The cache is invalidated wholesale when a DOI is removed (`cipso_v4_doi_remove()` → `netlbl_cache_invalidate()`).

### Other API Functions

Beyond `sock_setattr` and `skbuff_getattr`, the API provides:

- `netlbl_sock_getattr()` — retrieves the label currently on a socket (used for audit logging or policy queries).
- `netlbl_conn_setattr()` — labels a socket based on the destination address; used during the TCP `connect()` path when the destination address is known before the socket is fully connected.
- `netlbl_req_setattr()` — labels a request socket (`struct request_sock`) for incoming TCP connections in the SYN-received state; ensures that the connection's label is established before the three-way handshake completes.
- `netlbl_skbuff_err()` — sends an appropriate ICMP error when a labeled packet is rejected by the LSM. This is important for interoperability: without it, a rejected labeled connection would time out instead of failing fast.
- `netlbl_enabled()` — returns true if any NetLabel labeling is configured (at least one domain entry uses something other than UNLABELED); allows LSMs to skip the label check overhead when NetLabel is unconfigured.

## Key Data Structures

**`struct netlbl_lsm_secattr`** (`include/net/netlabel.h`) — see above.

**`struct netlbl_lsm_cache`** (`include/net/netlabel.h`) — the cache reference embedded in `netlbl_lsm_secattr`.
- `refcount` — atomic reference count; multiple sockets may share the same cache entry
- `free` — function pointer for freeing LSM-specific data in the cache (allows LSMs to cache opaque pointers)
- `data` — LSM-specific data pointer (e.g. an LSM security ID or a pointer to a security context struct)

**`struct netlbl_lsm_catmap`** (`include/net/netlabel.h`) — a linked-list bitmap representing an MLS category set. Categories are encoded as bits in 64-bit integers; the list allows representing large category sets without a fixed-size bitmap.
- `startbit` — the category number of the first bit in this node
- `bitmap[]` — 64-bit words of category bits
- `next` — next catmap node for categories beyond the first 240

## Key Functions / Entry Points

**`netlbl_sock_setattr()`** (`net/netlabel/netlabel_kapi.c`) — LSM outbound entry point; labels a socket; consults the domain hash table; dispatches to the protocol engine.

**`netlbl_skbuff_getattr()`** — LSM inbound entry point; decodes the label from an arriving packet; returns a `netlbl_lsm_secattr`; handles cache lookup.

**`netlbl_conn_setattr()`** — labels a socket for a specific destination; used during TCP `connect()`.

**`netlbl_req_setattr()`** — labels a TCP request socket during the SYN-received state.

**`netlbl_skbuff_err()`** — generates ICMP error for rejected labeled packets.

**`netlbl_cache_add()`** — stores a decoded `(secattr → secid)` mapping; called by protocol engines after a cache miss.

**`netlbl_cache_invalidate()`** — invalidates all cache entries; called when a DOI is removed.

**`netlbl_enabled()`** — fast check: returns false if all domains are configured as UNLABELED.

**`netlbl_secattr_init()`** / **`netlbl_secattr_destroy()`** — lifecycle management; `destroy` frees `domain` string and `attr.mls.cat` catmap.

## Important Flags & Config Options

`NETLBL_SECATTR_*` bitmask values (in `include/net/netlabel.h`):
- `NETLBL_SECATTR_DOMAIN` — `domain` field is valid
- `NETLBL_SECATTR_MLS_LVL` — `attr.mls.lvl` is valid
- `NETLBL_SECATTR_MLS_CAT` — `attr.mls.cat` is valid (and non-NULL)
- `NETLBL_SECATTR_SECID` — `attr.secid` is valid (cache hit path)
- `NETLBL_SECATTR_CACHE` — cache pointer is valid

## Interactions with Other Subsystems

- **← [[selinux]]**: SELinux calls `netlbl_sock_setattr()` from its socket creation hooks and `netlbl_skbuff_getattr()` from `selinux_socket_sock_rcv_skb()`. It uses `security_netlbl_secattr_to_sid()` to convert `secattr` to a SID.
- **← [[smack]]**: Smack calls the same KAPI functions from its network hooks; uses its own label-to-MLS mapping.
- **→ [[netlabel-domain-hash-table]]**: Every outbound call consults the domain hash table.
- **→ [[cipso-ipv4-engine]] / [[calipso-ipv6-engine]]**: The KAPI dispatches to the appropriate engine for both inbound and outbound operations.
- **← [[lsm]] hooks**: The KAPI is invoked from `socket_sock_rcv_skb()`, `socket_create()`, `socket_connect()`, and `inet_conn_request()` LSM hooks.

## Design Decisions & Tradeoffs

**Protocol-agnostic by design**: The API was explicitly designed as a shared layer for multiple LSMs. The initial patch series comment was "designed to be shared amongst multiple LSMs rather than being LSM-specific." This meant accepting a slightly thicker abstraction layer in exchange for a single codebase that both SELinux and Smack (added later) could use without changes.

**MLS as the common currency**: The API translates everything to MLS (level + category bitmap) as the wire representation. This is because CIPSO and CALIPSO both encode MLS attributes natively. The consequence is that only MAC policies that can express their access control in MLS terms can use NetLabel — a policy based on arbitrary string labels would need its own translation layer (which is exactly what Smack provides via `smack_netlabel()`).

**Cache invalidation is coarse**: The cache is invalidated wholesale when any DOI is removed. This is safe but potentially over-invalidates — if only one DOI is removed, cache entries for other DOIs are also discarded. A finer-grained strategy (per-DOI cache invalidation) would be possible but adds complexity that was deemed unnecessary given how infrequently DOIs are changed at runtime.

## How It Has Evolved

- **2.6.19**: Initial API; `netlbl_sock_setattr()`, `netlbl_skbuff_getattr()`, `netlbl_cache_add()`. SELinux only.
- **2.6.20**: Smack integration demonstrated the API's generality — no API changes needed.
- **2.6.28**: `netlbl_conn_setattr()` and `netlbl_req_setattr()` added to support TCP connection-time labeling with address selectors.
- **4.8**: API extended to accept `AF_INET6` family parameter to dispatch to CALIPSO.

## Further Reading

1. [NetLabel LSM Interface — kernel.org](https://www.kernel.org/doc/html/latest/netlabel/lsm_interface.html)
2. [netlbl_lsm_secattr struct (kernel doxygen)](https://docs.huihoo.com/doxygen/linux/kernel/3.7/structnetlbl__lsm__secattr.html)
3. [NetLabel LWN overview](https://lwn.net/Articles/185491/)
