---
title: "CIPSO/IPv4 Engine — Explained"
category: explained
original: "[[cipso-ipv4-engine]]"
subsystem: netlabel
tags: [explained, netlabel, cipso, ipv4, labeled-networking]
converted: 2026-09-25
---

# The CIPSO (IPv4) engine, explained

> Plain-language companion to [[cipso-ipv4-engine|the technical note]]. Same facts, fewer identifiers.

## The problem

Security modules such as SELinux enforce rules based on a process's clearance level and categories. When a process on one trusted machine talks to another over IPv4, the receiver needs to know the sender's clearance to apply its own policy, and both sides need to agree on what the numbers mean, even if they number their levels differently internally. There also has to be a way to reject forged or garbled labels before they cause harm.

## The idea in one paragraph

CIPSO is a **tamper-evident wax seal on a government envelope**. The sender presses its clearance level into the seal (an IPv4 option in the header); routers along the way can see the seal without breaking it; the recipient checks it before deciding whether to accept the contents. The **Domain of Interpretation (DOI)** is the codebook both sides agree on in advance, saying what the numbers in the seal mean. The seal is attached once per socket and copied onto every packet automatically.

## Step by step

### Step 1: Define a codebook (DOI)
Before anything is labelled, an administrator defines at least one DOI with `netlabelctl`. Its number is written into every CIPSO option, telling the receiver how to read the level and categories. Three types:
- **translated:** tables map local levels to network levels and back, plus a category mapping. Host A can call "Secret" level 3 and host B level 7, as long as both agree network level 5 means "Secret" in this DOI.
- **pass-through:** no translation; the numbers on the wire must match both sides' local numbering. Simpler, less flexible.
- **local:** for loopback only. CIPSO's numbers can't represent arbitrary security contexts, but on the same machine the full label can be carried as-is; these packets never leave the host.

### Step 2: Attach the seal to a socket
When a security module labels an IPv4 socket, NetLabel's [[netlabel-lsm-security-api-explained|API]] hands it to the CIPSO engine, which:
1. finds the requested DOI
2. translates the neutral label record (level and category bitmap) into a binary CIPSO option using that DOI's tables
3. stores the option on the socket

This is the key step. From then on, the IP output path copies the stored option into **every packet** the socket sends, with no per-packet work by the security module. Labelling per socket keeps it simple and fast, but means one socket can't send at different levels; the module must open separate sockets. Re-labelling a socket later is possible but unusual.

### Step 3: The option on the wire
The option has a type byte (registered as one that's copied when packets are fragmented), a length, the 4-byte DOI, and one or more **tags**. The most common tag carries a sensitivity level plus a category bitmap.

### Step 4: Check at the door
An arriving packet's CIPSO option is **validated in the IP layer**, before the packet reaches any socket. If it's malformed or names an unknown DOI, the packet is dropped with an ICMP error. Security modules never have to cope with garbage options.

### Step 5: Decode, with a cache
In its receive hook, the security module asks NetLabel for the label, and the CIPSO engine:
1. reads the DOI number and finds its definition
2. checks the per-DOI **cache**, keyed by a hash of the raw option bytes; on a hit, returns the already-translated label and security ID at once
3. on a miss, translates the level and categories through the DOI's tables, fills in the label record, and caches it

The module then maps the record to its own security ID and enforces policy. Since most connections keep one label for their whole life, the cache hit rate is high.

## The picture

```text
 sender:  label socket once ─▶ DOI 1 (translated): local "Secret"=3 → network 5
          option [type | len | DOI 1 | tag: level 5, categories c1 c2] on every packet
 wire:    routers can see the option
 receiver: IP layer validates (bad / unknown DOI → drop + ICMP)
          receive hook ─▶ cache hit? → security ID : translate network 5 → local 7, cache it
          SELinux enforces
```

## Tradeoffs

- **What it gives you:** interoperable labelled networking over IPv4 (compatible with Trusted Solaris and other multilevel-security systems), no per-packet work for security modules, early rejection of bad labels, and cheap decoding thanks to the cache.
- **What it costs / requires:** shared DOI definitions on every host; the cache (a fixed-size table per DOI) trades memory for CPU and can be tuned for small embedded systems.
- **Where it bites:** one label per socket; numeric labels that can't carry arbitrary security contexts except over loopback. It's based on a draft that was never an RFC, chosen for real-world compatibility over protocol elegance.

## How it got here

- **2.6.19 (2006):** first merge (Paul Moore), with only the level-plus-categories tag, translated and pass-through DOIs, and SELinux as the only user. The guiding constraint was to "tread as lightly as possible" on the core networking stack, hence labels set per socket, not per-packet hooks.
- **2.6.20+:** the local DOI type for loopback; Smack became a second user with no changes needed to the engine.
- **2.6.28:** chosen per destination by the domain table's address selectors.
- **6.x:** clean-ups, audit integration, and correct ICMP errors when a labelled packet is rejected.

## Related

- Technical version: [[cipso-ipv4-engine]]
- [[netlabel-explained|NetLabel]], [[calipso-ipv6-engine-explained|CALIPSO engine]], [[netlabel-lsm-security-api-explained|LSM API]], [[netlabel-domain-hash-table-explained|Domain table]], [[netlabel-netlink-management-interface-explained|Management interface]]
- [[selinux-explained|SELinux]], [[smack|Smack]], [[net-explained|Networking stack]]
