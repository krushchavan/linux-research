---
title: "NetLabel Netlink Management Interface — Explained"
category: explained
original: "[[netlabel-netlink-management-interface]]"
subsystem: netlabel
tags: [explained, netlabel, netlink, audit, labeled-networking]
converted: 2026-09-25
---

# The NetLabel management interface, explained

> Plain-language companion to [[netlabel-netlink-management-interface|the technical note]]. Same facts, fewer identifiers.

## The problem

[[netlabel-explained|NetLabel]]'s behaviour depends on policy: which applications get which labelling protocol, and what each DOI's translation tables look like. That policy differs from site to site and changes over time. Without a runtime configuration channel, it would have to be hard-coded into the kernel at build time, which would make NetLabel close to useless.

## The idea in one paragraph

The management interface is to NetLabel what `nft` is to netfilter: a structured **message channel from a user-space tool into the kernel**. The kernel registers a few message "families" over Generic Netlink, one per area of configuration, and the `netlabelctl` tool builds messages, each carrying a command and a list of typed attributes, and sends them. The kernel decodes each message straight into calls on the domain table or the protocol engines, and logs every change to the audit log.

## Step by step

### Step 1: Three families, one per job
At boot NetLabel registers three Generic Netlink families:
- **management:** the [[netlabel-domain-hash-table-explained|domain table]] (add, remove, list, set or clear the default entry)
- **CIPSO:** IPv4 DOI definitions
- **CALIPSO:** IPv6 DOI definitions

Each family has one handler per command. Splitting them keeps each family's set of attributes small and consistent, rather than mixing unrelated ones in one big table.

### Step 2: Configure a mapping
An administrator runs something like "map domain httpd to CIPSO, DOI 1", or "for domain webserver, send to 192.168.1.0/24 with CIPSO DOI 1". The tool encodes the domain name, protocol, DOI number, and (for address selectors) the address and mask as attributes; the kernel checks them and inserts the entry into the domain table.

### Step 3: Define a DOI
For CIPSO, the add command carries the DOI type (translated, pass-through or local) and, for translated DOIs, the mapping tables as pairs of local and network levels, and pairs of category numbers. The kernel builds the DOI definition and hands it to the [[cipso-ipv4-engine-explained|CIPSO engine]]. CALIPSO DOIs are simpler, since pass-through is the only type.

### Step 4: Check who's asking
Every command that **changes** anything requires the network-administration capability. Listing and dumping the configuration is open to any process. The kernel checks the capability before processing the message.

### Step 5: Leave an audit trail
This is the key step for its intended users. Every successful change (adding or removing a domain mapping or a DOI) writes an **audit record** naming the operation, the domain or DOI, and the protocol. In multilevel-security deployments, policy changes must be accounted for, so this is a requirement, not a nicety. Without audit support in the kernel, configuration still works but no records are written.

### Step 6: Read it back
List commands return one entry; "list all" commands walk the table and send the results back as a multi-part reply, which `netlabelctl` formats for display.

## The picture

```text
 netlabelctl map add domain:webserver address:192.168.1.0/24 protocol:cipsov4,doi:1
      │  message = command + typed attributes
      ▼  Generic Netlink
 ┌── management family ──▶ domain table
 ├── CIPSO family ───────▶ CIPSO engine (DOI definitions)
 └── CALIPSO family ─────▶ CALIPSO engine (DOI definitions)
      │ changes need admin capability; reads are open
      ▼
 audit log: "added domain webserver, CIPSO, DOI 1"
```

## Tradeoffs

- **What it gives you:** runtime configuration with structured, versionable messages; open read access for inspection; every change traceable in the audit log.
- **What it costs / requires:** a dedicated user-space tool that speaks the message format; the kernel does no more than decode attributes and call into the table and engines.
- **Where it bites:** a procfs or sysfs interface would have been easier to poke at by hand, but couldn't offer structured attributes, versioning or multicast notifications. Generic Netlink was the modern choice in 2006, which iproute2 and other tools had recently adopted.

## How it got here

- **2.6.19:** management and CIPSO families.
- **2.6.28:** domain mappings gain address-selector attributes.
- **4.8:** CALIPSO family added along with the CALIPSO engine.

## Related

- Technical version: [[netlabel-netlink-management-interface]]
- [[netlabel-explained|NetLabel]], [[netlabel-domain-hash-table-explained|Domain table]], [[cipso-ipv4-engine-explained|CIPSO engine]], [[calipso-ipv6-engine-explained|CALIPSO engine]], [[netlabel-lsm-security-api-explained|LSM API]]
- [[linux-audit-explained|Audit]], [[nftables-explained|nftables]]
