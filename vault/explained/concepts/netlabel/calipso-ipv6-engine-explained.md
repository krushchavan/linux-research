---
title: "CALIPSO/IPv6 Engine — Explained"
category: explained
original: "[[calipso-ipv6-engine]]"
subsystem: netlabel
tags: [explained, netlabel, calipso, ipv6, labeled-networking]
converted: 2026-09-25
---

# The CALIPSO (IPv6) engine, explained

> Plain-language companion to [[calipso-ipv6-engine|the technical note]]. Same facts, fewer identifiers.

## The problem

[[netlabel-explained|NetLabel]] lets security modules like SELinux carry a sender's security label (clearance level and categories) across the network, so the receiving host can enforce mandatory access control. For a decade it could only do this for IPv4, using CIPSO. As IPv6 became unavoidable in government and multilevel-security networks, labels needed a home in IPv6 packets too, ideally without the security modules noticing any difference.

## The idea in one paragraph

If [[cipso-ipv4-engine-explained|CIPSO]] is a stamp on the back of an envelope, **CALIPSO** is a security badge clipped to the outside of a courier's bag. It rides in the IPv6 **hop-by-hop** extension header, which every router along the path must inspect. It carries the same information as CIPSO (a sensitivity level and a category bitmap) in the envelope format that suits IPv6, and security modules reach it through exactly the same NetLabel interface.

## Step by step

### Step 1: Same front door as CIPSO
A security module labels a socket the same way whatever the IP version. NetLabel's [[netlabel-domain-hash-table-explained|domain table]] decides which engine to use, and for IPv6 destinations configured for CALIPSO, calls into the CALIPSO engine. Security modules never call CALIPSO directly.

### Step 2: Configure a DOI
As with CIPSO, an administrator defines a **Domain of Interpretation** with a number, using `netlabelctl calipso add`. The DOI number goes into every CALIPSO option. Unlike CIPSO, RFC 5570 has **no translating mode**: the label in the packet is the sender's label as-is, and the DOI only supplies the context for interpreting it. Every node in the network must share the same DOI definition and numbering.

### Step 3: Nothing to configure for incoming traffic
Once the kernel knows a DOI, it automatically decodes CALIPSO labels on any arriving IPv6 traffic using it. Only the outgoing side needs mapping rules, which makes deployment simpler than setups needing matching inbound and outbound rules.

### Step 4: Sending
When a socket is labelled for CALIPSO, the engine finds the DOI, encodes the level and categories from NetLabel's label record into a CALIPSO option, and attaches it to the socket's IPv6 extension headers. Every packet the socket sends then carries it. The option holds the DOI, a sensitivity level (0 to 255), a variable-length category bitmap, and a checksum covering the DOI, level and categories.

### Step 5: Receiving
IPv6 parses hop-by-hop options before handing packets up, validating the CALIPSO option's format and checksum. In its receive hook, the security module asks NetLabel for the packet's label; the CALIPSO engine locates the option, finds the DOI, decodes the level and categories, and returns them in the same neutral label record CIPSO would produce.

### Step 6: Invisible to SELinux
This is the key point. SELinux uses the same code path for CALIPSO as for CIPSO: translate its context to levels and categories on the way out, map the decoded record back to a context on the way in. The security module sees no difference between IPv4 and IPv6 labelling.

## The picture

```text
 IPv6 packet
 [ IPv6 header ][ hop-by-hop header: CALIPSO { DOI | level | categories | checksum } ][ TCP … ]
                   ▲ every router on the path inspects it

 SELinux ─▶ NetLabel API ─▶ domain table: IPv6 dest → CALIPSO, DOI 3 ─▶ CALIPSO engine
 arrival: IPv6 validates option ─▶ receive hook ─▶ decode ─▶ same label record as CIPSO
```

## Tradeoffs

- **What it gives you:** labelled networking over IPv6 with no changes for security modules, automatic decoding of incoming labels, and labels visible to multilevel-security-aware routers.
- **What it costs / requires:** hop-by-hop options mean every router on the path must process them, adding overhead at each hop; every host must share identical DOI numbering.
- **Where it bites:** with no translating DOI mode, heterogeneous networks that number levels differently can't interoperate. RFC 5570 requires hop-by-hop placement; a destination-only option would have been cheaper for routers but would have prevented enforcement inside the network.

## How it got here

- **4.8 (2016):** merged as a 19-patch series by Huw Davies (CodeWeavers), reviewed by Paul Moore, with SELinux, Smack and the domain table updated for a second protocol type; the domain table tells CIPSO and CALIPSO entries apart by address family. It arrived a decade after CIPSO because multilevel-security environments were slow to adopt IPv6.
- **After 4.8:** minor fixes to checksum calculation and option building, with no major redesign.

## Related

- Technical version: [[calipso-ipv6-engine]]
- [[netlabel-explained|NetLabel]], [[cipso-ipv4-engine-explained|CIPSO engine]], [[netlabel-lsm-security-api-explained|LSM API]], [[netlabel-domain-hash-table-explained|Domain table]]
- [[selinux-explained|SELinux]], [[smack-explained|Smack]], [[net-explained|Networking stack]]
