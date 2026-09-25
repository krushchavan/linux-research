---
title: "NetLabel Domain Hash Table — Explained"
category: explained
original: "[[netlabel-domain-hash-table]]"
subsystem: netlabel
tags: [explained, netlabel, labeled-networking, rcu]
converted: 2026-09-25
---

# The NetLabel domain table, explained

> Plain-language companion to [[netlabel-domain-hash-table|the technical note]]. Same facts, fewer identifiers.

## The problem

[[netlabel-explained|NetLabel]] can stamp outgoing packets with a security label using CIPSO (IPv4), CALIPSO (IPv6), or no label at all. Something has to decide which one a given socket gets. Without a policy table, every socket on the system would be labelled the same way, with no way to treat a web server differently from a database client, or one subnet differently from another.

## The idea in one paragraph

The domain table is a **firewall-style policy table, but for labelling instead of filtering**. Each row reads: "for traffic from security domain X going to address range Y, use protocol Z with DOI N." When a socket is labelled, NetLabel looks up the socket's domain, finds the matching row, and that decision sticks for the socket's lifetime.

## Step by step

### Step 1: What the key is
Each entry is keyed by a **domain string** that the security module supplies when it labels a socket. For SELinux this is the domain type (such as the one for a web server); for Smack it's the Smack label. There is always a **catch-all default entry** for any domain not configured explicitly.

### Step 2: What an entry says
Each entry holds one of four answers:
- **unlabelled:** send packets with no label option
- **CIPSO**, with a DOI: use the [[cipso-ipv4-engine-explained|CIPSO engine]]
- **CALIPSO**, with a DOI: use the [[calipso-ipv6-engine-explained|CALIPSO engine]]
- **address selector:** "it depends on the destination"; see Step 4

### Step 3: Looking it up
When a security module asks NetLabel to label a socket, NetLabel hashes the domain string, scans that bucket, and returns the first match, preferring an exact domain match over the catch-all. The answer's type decides which engine NetLabel calls next.

### Step 4: Choosing by destination (address selectors)
This is the key step. Before 2.6.28, a domain had one fixed protocol, so all of an application's traffic used the same labelling wherever it went, which blocked mixed IPv4/IPv6 networks and per-subnet policies. **Address selectors** let a domain entry hold a list of destination prefixes, each with its own protocol and DOI. The lookup walks the list and takes the first prefix covering the socket's destination; a catch-all prefix at the end (all addresses) handles the rest, usually as unlabelled.

### Step 5: Reads never wait
Lookups happen on every new socket, so they must be cheap. They run under RCU with no lock at all. Changes come from the [[netlabel-netlink-management-interface-explained|management interface]]: a writer takes a spinlock, updates the table, then waits for an RCU grace period before freeing old entries, so no reader ever sees freed memory. Every addition is also written to the audit log.

### Step 6: Unlabelled traffic, both ways
Unlabelled is the default for most systems: only traffic explicitly configured for CIPSO or CALIPSO gets labelled. The unlabelled configuration also controls **incoming** packets that arrive without a label option: they can be accepted or rejected.

## The picture

```text
 socket from domain "webserver" connects somewhere
        │  hash("webserver") → bucket → entry (else catch-all default)
        ▼
 entry type = address selector:
     192.168.1.0/24 → CIPSO,   DOI 1
     10.0.0.0/8     → CALIPSO, DOI 2
     everything else → unlabelled
        │  first matching prefix for the destination
        ▼
 NetLabel API calls that engine; decision fixed for the socket's life
```

## Tradeoffs

- **What it gives you:** per-application and per-destination labelling policy, a lock-free lookup on the hot path, and audited changes.
- **What it costs / requires:** keying on a domain *string* rather than a numeric ID means one table serves every security module, but each module must agree on what string it supplies.
- **Where it bites:** address selectors are a plain list scanned in order, not a tree. That's fast for the handful of prefixes typical deployments use, but would scale poorly to hundreds per domain, which is rare.

## How it got here

- **2.6.19:** domains mapped to a single protocol each; no address selectors.
- **2.6.28:** address selectors, allowing a protocol per destination.
- **4.8:** CALIPSO entries and IPv6 address selectors.

## Related

- Technical version: [[netlabel-domain-hash-table]]
- [[netlabel-explained|NetLabel]], [[netlabel-lsm-security-api-explained|LSM API]], [[netlabel-netlink-management-interface-explained|Management interface]], [[cipso-ipv4-engine-explained|CIPSO engine]], [[calipso-ipv6-engine-explained|CALIPSO engine]]
- [[rcu-read-copy-update-explained|RCU]], [[linux-audit|Audit]]
