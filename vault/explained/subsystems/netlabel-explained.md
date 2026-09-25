---
title: "NetLabel — Explained"
category: explained
original: "[[netlabel]]"
subsystem: netlabel
tags: [explained, netlabel, cipso, calipso, lsm, labeled-networking]
converted: 2026-09-25
---

# NetLabel, explained

> Plain-language companion to [[netlabel|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Mandatory access control systems like SELinux and Smack give every process a security label, such as a clearance level ("secret") plus categories ("project A, project B"), and enforce rules like "a process may only read data at or below its own level". Within one machine, the kernel always knows who is who. But as soon as data crosses the network, the receiving machine has no idea what clearance the sender had, so it can't enforce the policy.

What's needed is a way to **stamp packets with the sender's label** and read those stamps on arrival, in a wire format both machines agree on, without tying each security module to one particular format.

## The big picture

NetLabel is the kernel's **passport office for packets**. When a process on a trusted system sends data, NetLabel stamps its packets with a label (the passport) encoding the sender's clearance. On a remote trusted system, NetLabel reads and checks the stamp before the data reaches the application. The security module is the policy officer deciding which labels are acceptable; NetLabel is only the mechanism for applying and reading stamps, translating between the module's idea of a label and the agreed wire format.

```text
 netlabelctl ─(netlink)─▶ management interface ─▶ domain table (which protocol for whom)
                                                       │
 SELinux / Smack ─▶ LSM security API (protocol-neutral) ┤
                                                       ├─▶ CIPSO engine ─▶ IPv4 IP option
                                                       └─▶ CALIPSO engine ─▶ IPv6 hop-by-hop option
```

The layering is strict: security modules only ever call the protocol-neutral API; that API consults the domain table to pick a protocol, then hands off to the right engine; the engines talk to the IP stack.

## The pieces

### The CIPSO engine (IPv4)
CIPSO carries a label in an **IPv4 IP option**. It comes from a 1992 IETF draft that was never ratified, but became the de facto standard for labelled networking (used by Trusted Solaris and other multilevel-security systems). When a security module labels a socket, the engine attaches a CIPSO option to it, and from then on **every packet the socket sends carries it automatically**, with no per-packet work by the security module.

Incoming packets' CIPSO options are validated by IPv4 before reaching the socket layer; malformed ones, or ones naming an unknown DOI, are dropped. The security module then asks NetLabel to decode the label.

Translation is governed by a **Domain of Interpretation (DOI)**: a numbered table mapping CIPSO's integer levels and category bitmaps to the local system's labels. Three kinds:
- **translated:** administrator-configured tables map between local and network numbering, so hosts can number levels differently
- **pass-through:** numbers are used as-is, so both ends must agree on numbering
- **local:** carries the full local label, only over loopback, never off the machine

See [[cipso-ipv4-engine-explained|the CIPSO engine]].

### The CALIPSO engine (IPv6)
CALIPSO (RFC 5570, merged in 4.8) does the same job for IPv6, using a **hop-by-hop option** that routers along the path can inspect. To security modules the interface is identical. Linux automatically decodes incoming CALIPSO labels for any known DOI, so administrators only configure the outgoing side. See [[calipso-ipv6-engine-explained|the CALIPSO engine]].

### The domain table
This is the routing table for labelling: given a socket's security **domain** (roughly, its application's security context), which protocol should it use? Each entry says CIPSO (with a DOI), CALIPSO, unlabelled, or an **address selector**, and a default entry catches everything not configured. Lookups use RCU, since the table is read far more often than written.

Address selectors (2.6.28) let one domain choose a protocol by **destination**: CIPSO to one subnet, CALIPSO to another, unlabelled for the rest. Before this, all of an application's traffic had to use one protocol, which blocked mixed IPv4/IPv6 deployments. See [[netlabel-domain-hash-table-explained|the domain table]].

### The management interface
Administrators configure everything with `netlabelctl`, which talks to the kernel over Generic Netlink: add, remove and list domain mappings and DOI definitions. Changes are serialised with a spinlock (readers use RCU), and every configuration change produces an **audit record**. See [[netlabel-netlink-management-interface|the management interface]].

### The security-module API
This is the key design choice. SELinux and Smack deal only with a **protocol-neutral label record**: a sensitivity level, a category bitmap, a security ID, the domain, and flags saying which fields are valid.
- **Sending:** the module fills in the record and asks NetLabel to label the socket; NetLabel picks the protocol from the domain table and has the engine attach the option.
- **Receiving:** in its "socket receives a packet" hook, the module asks NetLabel for the packet's label; NetLabel finds a CIPSO or CALIPSO option and decodes it, or returns the configured default for unlabelled traffic. The module maps the result to its own security ID and enforces policy.

A **label cache** remembers "this wire label means that security ID", so repeated packets with the same label skip both NetLabel's translation and the module's own lookup, a big win for busy trusted connections. See [[netlabel-lsm-security-api-explained|the LSM API]].

## A request's journey

An SELinux process with categories c1 and c2 sends over TCP, and the receiver checks it:

1. **Label the socket.** SELinux fills in a label record (domain "myapp", level 0, categories c1, c2) and asks NetLabel to label the socket.
2. **Choose a protocol.** The domain table says "myapp" uses CIPSO with DOI 1.
3. **Attach the option.** The CIPSO engine translates level and categories through DOI 1's tables, builds the IP option, and attaches it to the socket. Every later packet carries it.
4. **Arrival.** On the receiving host, IPv4 validates the option's format.
5. **Decode.** SELinux's receive hook asks NetLabel for the label; the CIPSO engine finds DOI 1 and translates back, or finds it in the cache.
6. **Enforce.** SELinux maps the decoded label to its own security ID and applies policy. This is the key moment: the receiving host can now enforce mandatory access control based on the *remote* sender's clearance.

## Tradeoffs

- **What it gives you:** labels that travel with the packet between hosts; one API that SELinux and Smack both use, which is why Smack needed almost no networking code; no application changes; and much better performance than Labeled IPsec, which needs encryption, key exchange and IKE daemons everywhere.
- **What it costs / requires:** every participating host must share DOI definitions; CIPSO labels only carry levels and categories, not arbitrary security contexts; a fixed-size label cache that must be sized sensibly.
- **Where it bites:** compared with SECMARK (labels that stay local to one host and are easier to configure), NetLabel is harder to set up, but it's the one that enables real cross-host enforcement. LSM stacking complicates it, since multiple active modules may each want to label the same packet.

## How it got here

- **2.6.19 (2006):** initial merge by Paul Moore (HP): CIPSO/IPv4, SELinux integration and the netlink management interface. The key debate, whether CIPSO should live inside SELinux or be a shared framework, went to the shared framework.
- **2.6.20 (2007):** Smack integration, proving the protocol-neutral design.
- **2.6.28 (2008):** address selectors for per-destination protocols.
- **4.8 (2016):** CALIPSO for IPv6, a 19-patch series by Huw Davies (CodeWeavers), reviewed by Paul Moore.
- **Ongoing:** Paul Moore maintains it; LSM stacking work (Casey Schaufler) is forcing changes to NetLabel's single-module assumptions.

## Related

- Technical version: [[netlabel]]
- [[cipso-ipv4-engine-explained|CIPSO engine]], [[calipso-ipv6-engine-explained|CALIPSO engine]], [[netlabel-domain-hash-table-explained|Domain table]], [[netlabel-netlink-management-interface|Management interface]], [[netlabel-lsm-security-api-explained|LSM API]]
- [[selinux|SELinux]], [[smack|Smack]], [[smack-network-labeling|Smack network labelling]], [[lsm-framework|LSM framework]], [[linux-audit|Audit]]
- [[net-explained|Networking stack]], [[netfilter-explained|Netfilter (SECMARK)]]
