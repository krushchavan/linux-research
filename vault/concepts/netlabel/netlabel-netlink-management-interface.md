---
title: "NetLabel Netlink Management Interface"
category: concept
tags: [netlabel, netlink, security, labeled-networking, userspace]
subsystem: netlabel
kernel_version: "2.6.19"
researched: 2026-04-17
status: complete
explained: "[[netlabel-netlink-management-interface-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/netlabel/introduction.html
  - https://lwn.net/Articles/185491/
  - https://linux.die.net/man/8/netlabelctl
---

# NetLabel Netlink Management Interface

> 📘 Plain-language version: [[netlabel-netlink-management-interface-explained]]

## Purpose

The Netlink management interface is the channel through which user-space administrators configure [[netlabel]]: adding and removing domain mappings, defining DOI translation tables, and querying current state. Without it, NetLabel would have no way to be configured at runtime and would be useful only with compile-time hardcoded policy.

## Mental Model

The Netlink interface is to NetLabel what `iptables`/`nft` is to netfilter: a structured message-passing channel that lets an unprivileged-looking user-space tool make privileged kernel changes. The kernel side registers several Generic NETLINK families (one per logical area of configuration), and the `netlabelctl` tool sends commands to those families by constructing attribute-encoded messages.

## How It Works

### Generic NETLINK Families

NetLabel registers three Generic NETLINK families using `genl_register_family()`:

| Family name       | Purpose                                    |
|-------------------|--------------------------------------------|
| `NLBL_MGMT`       | Domain mappings (add/remove/list/default)  |
| `NLBL_CIPSOV4`    | CIPSO/IPv4 DOI definitions                 |
| `NLBL_CALIPSO`    | CALIPSO/IPv6 DOI definitions               |

Each family registers a set of operation callbacks — one per command type. Commands are encoded as a `u8` command ID in the Netlink message header (`nlmsghdr.nlmsg_type`), and attributes are encoded as a stream of `nlattr` structures following the header.

### NLBL_MGMT Commands

The management family handles the domain hash table:

- **`NLBL_MGMT_C_ADD`**: Add a domain mapping. Attributes include the domain string (`NLBL_MGMT_A_DOMAIN`), the protocol type (`NLBL_MGMT_A_PROTOCOL`), and (for CIPSO/CALIPSO) the DOI number (`NLBL_MGMT_A_CV4DOI` or `NLBL_MGMT_A_CALDOI`). Address selector entries carry additional IPv4/IPv6 address and mask attributes.
- **`NLBL_MGMT_C_REMOVE`**: Remove a domain mapping by name.
- **`NLBL_MGMT_C_LIST`**: Dump a single domain entry.
- **`NLBL_MGMT_C_LISTALL`**: Dump all domain entries (uses Netlink multipart replies).
- **`NLBL_MGMT_C_ADDDEF`** / **`NLBL_MGMT_C_REMOVEDEF`**: Set/clear the default catch-all domain entry (the NULL-domain entry in the hash table).
- **`NLBL_MGMT_C_LISTDEF`**: Query the current default.

### NLBL_CIPSOV4 Commands

- **`NLBL_CIPSOV4_C_ADD`**: Define a new CIPSO DOI with its type (TRANS/PASS/LOCAL) and mapping tables. For TRANS type, the mapping tables are encoded as arrays of `(local_level, remote_level)` pairs and category bitmap pairs.
- **`NLBL_CIPSOV4_C_REMOVE`**: Remove a DOI by number.
- **`NLBL_CIPSOV4_C_LIST`**: Query a specific DOI's configuration.
- **`NLBL_CIPSOV4_C_LISTALL`**: Dump all CIPSO DOIs.

### NLBL_CALIPSO Commands

- **`NLBL_CALIPSO_C_ADD`**: Define a new CALIPSO DOI (currently only PASS type).
- **`NLBL_CALIPSO_C_REMOVE`**, **`NLBL_CALIPSO_C_LIST`**, **`NLBL_CALIPSO_C_LISTALL`**: analogous to CIPSO equivalents.

### Privilege Requirements

All mutating commands require `CAP_NET_ADMIN`. Read-only commands (LIST, LISTALL) can be performed by any process. The kernel validates the capability before processing any message.

### Audit Integration

Every successful mutation command (add/remove domain, add/remove DOI) calls `netlbl_domhsh_audit_add()` or the DOI-equivalent function, which generates an audit record via `audit_log_start()`. The record includes the operation, the domain name or DOI number, and the protocol type. This ensures all NetLabel policy changes are traceable in the kernel audit log, which is important for [[linux-audit]] in MLS deployments where policy changes must be accounted for.

### netlabelctl User-Space Tool

The `netlabelctl` command-line tool (from the `netlabel-tools` package) is the reference client. It serializes administrator commands into the correct Netlink message format and sends them to the kernel. Key subcommands:

```
netlabelctl map add default protocol:unlbl
netlabelctl map add domain:httpd_t protocol:cipsov4,doi:1
netlabelctl cipsov4 add trans doi:1 tags:1 levels:0,0 cats:0,0
netlabelctl calipso add doi:2
netlabelctl map add domain:webserver address:192.168.1.0/24 protocol:cipsov4,doi:1
```

Queries return structured output that the tool formats for display:

```
netlabelctl map list
netlabelctl cipsov4 list doi:1
```

## Key Data Structures

The management interface does not have its own primary structs — it decodes Netlink attributes directly into calls to the [[netlabel-domain-hash-table]] and protocol engine functions.

**`struct genl_family`** — the registered Generic NETLINK family; contains the family ID, name, max attribute count, and operation table.

**`struct nlattr` stream** — each Netlink message carries a sequence of type-length-value attributes encoding the command parameters.

## Key Functions / Entry Points

**`netlbl_mgmt_add()`** (`net/netlabel/netlabel_mgmt.c`) — handles `NLBL_MGMT_C_ADD`; validates attributes and calls `netlbl_domhsh_add()`.

**`netlbl_mgmt_listall()`** — dumps the domain table; uses `netlbl_domhsh_walk()` to iterate and `genlmsg_put()` to build multipart replies.

**`netlbl_cipsov4_add()`** (`net/netlabel/netlabel_cipso_v4.c`) — validates DOI attributes, builds a `cipso_v4_doi`, and calls `cipso_v4_doi_add()`.

**`netlbl_calipso_add()`** (`net/netlabel/netlabel_calipso.c`) — analogous for CALIPSO.

**`netlbl_netlink_init()`** — registers all three Generic NETLINK families at kernel init time; called from `netlbl_init()`.

## Important Flags & Config Options

- `CONFIG_NETLABEL` — must be enabled; all three families are registered at once.
- `CONFIG_AUDIT` — without this, audit records are elided but configuration still works.

## Interactions with Other Subsystems

- **↑ Userspace**: `netlabelctl` (or custom tools) communicate via `NETLINK_GENERIC` sockets.
- **→ [[netlabel-domain-hash-table]]**: All domain add/remove/list operations call into the domain hash table.
- **→ [[cipso-ipv4-engine]] / [[calipso-ipv6-engine]]**: DOI add/remove operations call the protocol engine DOI management functions.
- **→ [[audit]]**: Mutation events generate audit records.
- **← Kernel init**: `netlbl_netlink_init()` is called from `netlbl_init()` during subsystem initialization.

## Design Decisions & Tradeoffs

**Generic NETLINK over a custom socket**: NetLabel uses Generic NETLINK rather than a custom socket type or a procfs/sysfs interface. This was the modern approach in 2006 (iproute2 and other tools had just adopted it), providing structured attribute encoding, versioning support, and multicast group notifications — features that procfs cannot provide.

**Three families vs. one**: Splitting into `NLBL_MGMT`, `NLBL_CIPSOV4`, and `NLBL_CALIPSO` keeps each family's attribute namespace small and self-consistent. The alternative (a single family with many commands) would have mixed unrelated attributes in the same policy table.

## How It Has Evolved

- **2.6.19**: `NLBL_MGMT` and `NLBL_CIPSOV4` families registered.
- **2.6.28**: `NLBL_MGMT_C_ADD` extended with address selector attributes.
- **4.8**: `NLBL_CALIPSO` family added alongside the CALIPSO engine.

## Further Reading

1. [NetLabel Introduction — kernel.org](https://www.kernel.org/doc/html/latest/netlabel/introduction.html)
2. [netlabelctl(8) man page](https://linux.die.net/man/8/netlabelctl)
3. [NetLabel LWN overview](https://lwn.net/Articles/185491/)
