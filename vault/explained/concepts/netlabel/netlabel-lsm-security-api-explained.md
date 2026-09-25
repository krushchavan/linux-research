---
title: "NetLabel LSM Security API — Explained"
category: explained
original: "[[netlabel-lsm-security-api]]"
subsystem: netlabel
tags: [explained, netlabel, lsm, selinux, labeled-networking]
converted: 2026-09-25
---

# The NetLabel security-module API, explained

> Plain-language companion to [[netlabel-lsm-security-api|the technical note]]. Same facts, fewer identifiers.

## The problem

Security modules like SELinux and Smack want to label network traffic, but the wire formats differ: CIPSO puts the label in an IPv4 option, CALIPSO in an IPv6 hop-by-hop header. If every module had to handle every format itself, each new protocol would mean new code in every module, a maintenance burden that keeps growing.

## The idea in one paragraph

The API is an **interpreter between two vocabularies**. The security module speaks in its own security contexts; the network speaks in CIPSO or CALIPSO bytes. In between sits one **format-neutral label record**: a sensitivity level, a category bitmap, and a few extras. The module only ever fills in or reads that record; NetLabel consults its [[netlabel-domain-hash-table-explained|domain table]] to decide which wire format applies, and does the translation.

## Step by step

### Step 1: The shared record
The record carries a sensitivity level, a set of categories, the socket's domain string, optionally a security ID, and a set of **flags saying which fields are actually filled in**. Checking those flags is mandatory, because not every protocol fills every field. The category set is stored as a chain of 64-bit chunks, so large category sets don't need one huge fixed-size bitmap.

### Step 2: Labelling a socket (outgoing)
The module:
1. starts an empty record
2. sets the domain string for this socket
3. translates its own security context into a level and categories, and sets the matching flags
4. asks NetLabel to label the socket
5. frees the record

NetLabel looks up the domain (and destination) in the domain table and hands off to the [[cipso-ipv4-engine-explained|CIPSO]] or [[calipso-ipv6-engine-explained|CALIPSO]] engine. If the answer is "unlabelled", it removes any existing label from the socket.

### Step 3: Labelling at connection time
Two extra entry points exist because the destination matters once address selectors are in play: one labels a socket when a TCP **connect** names its destination, and one labels the half-open connection for an **incoming** TCP request, so the label is settled before the three-way handshake completes. Both were added in 2.6.28 along with address selectors.

### Step 4: Reading a packet's label (incoming)
In its "socket receives a packet" hook, the module asks NetLabel for the packet's label. NetLabel looks for a CIPSO or CALIPSO option:
- **none present:** apply the configured policy for unlabelled traffic
- **present:** pass it to the right engine to decode

The module then checks the flags. If only a level and categories came back, it translates them into its own security ID (SELinux has a dedicated function for this) and enforces policy.

### Step 5: The cache shortcut
This is the key step. Decoding a CIPSO option and then asking the security module to look up the matching context is expensive on a busy connection. So NetLabel keeps a cache from **raw network label bytes to the module's security ID**. On a hit, the record comes back with the security ID already set and a flag saying so, skipping both NetLabel's translation and the module's own lookup in one step. Entries are added after a successful decode, and the whole cache is thrown away when any DOI is removed.

### Step 6: Rejections and fast checks
When a module rejects a labelled packet, NetLabel can send back the right **ICMP error**, so the remote side fails fast instead of timing out. A quick "is NetLabel configured at all?" check lets modules skip all label work on systems where every domain is unlabelled.

## The picture

```text
 SELinux / Smack                          the network
 ───────────────                          ───────────
 security context                         CIPSO option (IPv4)
      │ translate                         CALIPSO option (IPv6)
      ▼                                        ▲ │
 neutral record {level, categories,            │ │
                 domain, flags}  ─▶ NetLabel ──┘ │  outgoing: domain table picks engine
      ▲                              │           │
      └──── security ID ◀── cache? ──┴───────────┘  incoming: decode, or cache hit
```

## Tradeoffs

- **What it gives you:** one code path in each security module for every labelling protocol; Smack was added in 2.6.20 with no changes to the API. The cache makes repeated labels nearly free.
- **What it costs / requires:** a slightly thicker abstraction layer. Everything is expressed as levels and categories, because that's what CIPSO and CALIPSO carry natively, so only policies expressible in those terms can use NetLabel directly. Smack, whose labels are arbitrary strings, provides its own mapping.
- **Where it bites:** cache invalidation is all-or-nothing: removing one DOI discards cached entries for every DOI. That's safe, and acceptable because DOIs rarely change at runtime.

## How it got here

- **2.6.19:** the initial API (label a socket, read a packet's label, add to cache), built from the start to be shared among security modules rather than SELinux-specific, though SELinux was the only user.
- **2.6.20:** Smack integration proved the design general, with no API changes.
- **2.6.28:** connection-time labelling for outgoing connects and incoming requests, supporting address selectors.
- **4.8:** IPv6 support, dispatching to CALIPSO.

## Related

- Technical version: [[netlabel-lsm-security-api]]
- [[netlabel-explained|NetLabel]], [[netlabel-domain-hash-table-explained|Domain table]], [[cipso-ipv4-engine-explained|CIPSO engine]], [[calipso-ipv6-engine-explained|CALIPSO engine]], [[netlabel-netlink-management-interface-explained|Management interface]]
- [[selinux|SELinux]], [[smack|Smack]], [[smack-network-labeling|Smack network labelling]], [[lsm-framework-explained|LSM framework]]
