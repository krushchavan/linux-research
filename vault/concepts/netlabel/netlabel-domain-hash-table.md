---
title: "NetLabel Domain Hash Table"
category: concept
tags: [netlabel, security, labeled-networking, rcu, hash-table]
subsystem: netlabel
kernel_version: "2.6.19"
researched: 2026-04-17
status: complete
explained: "[[netlabel-domain-hash-table-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/netlabel/introduction.html
  - https://www.paul-moore.com/blog/d/2009/02/netlabel_address_selectors.html
  - https://lwn.net/Articles/185491/
---

# NetLabel Domain Hash Table

> 📘 Plain-language version: [[netlabel-domain-hash-table-explained]]

## Purpose

The domain hash table is [[netlabel]]'s policy routing table: given a socket's LSM security domain (the application's security context label), it answers "which wire labeling protocol and DOI should be used for outbound packets?" Without it there would be no way to configure different labeling behaviors for different applications, destinations, or address families — every socket would use the same default.

## Mental Model

Think of the domain hash table as a firewall policy table, but for *labeling* rather than *filtering*. Each row says: "for traffic from domain X going to address range Y, use protocol Z with DOI N." The system walks the table on each new socket, finds the matching row, and locks in the labeling decision for that socket's lifetime.

## How It Works

### Domain Entries

The table maps LSM domain strings to `netlbl_dommap` structures. A domain string is an identifier set by the LSM in the `netlbl_lsm_secattr.domain` field before calling `netlbl_sock_setattr()`. For SELinux this is the SELinux domain type (e.g. `"httpd_t"`); for Smack it is the Smack label. There is always a catch-all entry with `domain = NULL` that matches any traffic whose domain is not explicitly configured.

Each `netlbl_dommap` entry specifies one of four protocol types:
- `NETLBL_NLTYPE_UNLABELED` — send packets with no label (no CIPSO/CALIPSO option).
- `NETLBL_NLTYPE_CIPSO4` — use the [[cipso-ipv4-engine]] with a specified DOI.
- `NETLBL_NLTYPE_CALIPSO` — use the [[calipso-ipv6-engine]] with a specified DOI.
- `NETLBL_NLTYPE_ADDRSELECT` — delegate to an address selector list (see below).

### Lookup Path

When an LSM calls `netlbl_sock_setattr()`, the KAPI calls `netlbl_domhsh_getentry(domain)` (or the address-family–aware variant `netlbl_domhsh_getentry_af(domain, family, addr)` when address selectors are involved). The function:

1. Computes a hash of the domain string.
2. Scans the appropriate bucket of the hash table under RCU read lock.
3. Returns the first matching entry (exact domain match preferred over the NULL catch-all).

The result is a `netlbl_dommap` pointer whose type field drives the rest of the KAPI's behavior.

### Address Selectors (kernel 2.6.28)

Before 2.6.28, each domain entry had a single fixed protocol type. This meant every socket in that domain used the same labeling protocol regardless of where it was connecting. In mixed IPv4/IPv6 networks or in deployments that needed different protocols for different subnets, this was a blocking limitation.

Address selectors solve this by allowing a domain entry to have type `NETLBL_NLTYPE_ADDRSELECT` and a linked list of `netlbl_domaddr_map` entries. Each entry in the list pairs a destination address prefix (IPv4 CIDR or IPv6 prefix) with a protocol type and DOI. When the KAPI looks up such an entry, it iterates the address list and selects the first prefix that covers the socket's destination address. A catch-all prefix (`0.0.0.0/0` or `::/0`) at the end of the list handles unmatched destinations (typically configured as UNLABELED).

Example configuration intent:
```
domain "webserver":
  192.168.1.0/24 → CIPSO DOI #1
  10.0.0.0/8     → CALIPSO DOI #2
  0.0.0.0/0      → UNLABELED
```

### Locking Model

The hash table is protected by a combination of RCU and a spinlock:
- **Reads** (lookups during `sock_setattr`) hold the RCU read lock only — no contention with writers.
- **Writes** (domain add/remove via the Netlink interface) acquire a spinlock, modify the table, then call `synchronize_rcu()` before freeing old entries.

This design makes the lookup path (which happens on every new socket) completely lock-free in the common case.

### Default Entry and Unlabeled Traffic

The `NETLBL_NLTYPE_UNLABELED` type is important: it tells the KAPI not to attach any label to outgoing packets. This is the default for most systems — only traffic explicitly configured for CIPSO/CALIPSO gets labeled. The unlabeled configuration also governs how *incoming* unlabeled packets are handled: the NetLabel unlabeled subsystem (`netlabel_unlabeled.c`) can be configured to accept or reject packets that arrive without a CIPSO/CALIPSO option.

## Key Data Structures

**`struct netlbl_dommap`** (`net/netlabel/netlabel_domainhash.h`) — one per configured domain.
- `domain` — the domain name string (NULL for the default catch-all)
- `type` — `NETLBL_NLTYPE_*` constant
- `def` — union: a pointer to `netlbl_domaddr4_map` / `netlbl_domaddr6_map` (for ADDRSELECT) or a `cipso_v4_doi *` / `calipso_doi *` (for direct protocol entries)
- `rcu` — RCU head for safe asynchronous freeing

**`struct netlbl_domaddr4_map`** — one node per IPv4 address selector entry.
- `addr`, `mask` — the destination address and mask
- `def` — the protocol type and DOI for this prefix

**`struct netlbl_domaddr6_map`** — same for IPv6.

## Key Functions / Entry Points

**`netlbl_domhsh_getentry()`** (`net/netlabel/netlabel_domainhash.c`) — fast RCU read path; looks up by domain string; hot on every new socket.

**`netlbl_domhsh_getentry_af()`** — extended lookup that also filters on address family and walks address selectors.

**`netlbl_domhsh_add()`** — inserts a new domain mapping; called by the Netlink management handler; acquires the write spinlock.

**`netlbl_domhsh_remove()`** — removes a domain mapping; must wait for RCU grace period before freeing.

**`netlbl_domhsh_audit_add()`** — emits an audit record for every domain addition; called inside `netlbl_domhsh_add()`.

## Important Flags & Config Options

No dedicated Kconfig; always compiled when `CONFIG_NETLABEL=y`. The table size (number of hash buckets) is a compile-time constant in `netlabel_domainhash.c`.

## Interactions with Other Subsystems

- **← [[netlabel-netlink-management-interface]]**: All mutations (add, remove) originate from the Netlink interface.
- **→ [[netlabel-lsm-security-api]]**: The KAPI is the exclusive reader; it translates lookup results into protocol engine calls.
- **→ [[audit]]**: Every domain addition generates an audit record via `audit_log_start()`.
- **→ [[cipso-ipv4-engine]] / [[calipso-ipv6-engine]]**: The protocol type returned by the hash table determines which engine the KAPI invokes.

## Design Decisions & Tradeoffs

**Domain string as key, not secid**: The hash table is keyed on the domain *string* rather than a numeric security ID. This means the table is shared across all LSMs without any LSM-specific representation, which simplifies the kernel code but requires each LSM to agree on what string it puts in `secattr.domain`. SELinux uses the domain type name; Smack uses the Smack label.

**Address selectors as a list, not a trie**: Address selectors use a linear list scan rather than a radix trie. For typical deployments with only a handful of prefixes per domain this is fast enough, and it avoids the complexity of a trie. The tradeoff is poor scalability if a domain has hundreds of address selectors, but such configurations are rare.

## How It Has Evolved

- **2.6.19**: Simple domain → single protocol mapping; no address selectors.
- **2.6.28**: Address selectors added, enabling per-destination protocol selection.
- **4.8**: Extended to support `NETLBL_NLTYPE_CALIPSO` entries and `AF_INET6` address selector nodes.

## Further Reading

1. [NetLabel Address Selectors — Paul Moore](https://www.paul-moore.com/blog/d/2009/02/netlabel_address_selectors.html)
2. [NetLabel Introduction — kernel.org](https://www.kernel.org/doc/html/latest/netlabel/introduction.html)
