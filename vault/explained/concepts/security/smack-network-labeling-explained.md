---
title: "Smack Network Labeling — Explained"
category: explained
original: "[[smack-network-labeling]]"
subsystem: security
tags: [explained, security, smack, netlabel, cipso]
converted: 2026-09-25
---

# Smack network labelling, explained

> Plain-language companion to [[smack-network-labeling|the technical note]]. Same facts, fewer identifiers.

## The problem

Inside one machine, Smack labels every process and file and checks every access. But without network labelling, two processes in different Smack domains on **different** machines could exchange data freely, walking straight around the policy. The protection boundary has to extend across the network: the receiver needs to know the sender's label, and apply the same rules it uses for files.

## The idea in one paragraph

Every packet leaving a Smack host **carries the sender's label** in its IP header, and every arriving packet has its label read back. The receiving kernel treats the remote peer like a process with that label and applies one rule: **sending is writing**. Data is delivered only if the sender's label may *write* to the receiver's label, the same intuition as writing to a file. Smack doesn't touch packet headers itself; it hands encoding and decoding to [[netlabel-explained|NetLabel]], which uses CIPSO for IPv4 and CALIPSO for IPv6.

## Step by step

### Step 1: Sockets inherit a label
When a process creates a socket, the socket's outgoing label and incoming label both default to the process's own label. Privileged processes can change them, but most deployments keep the defaults.

### Step 2: Tag outgoing packets
When a socket sends, Smack asks NetLabel to label it with the socket's outgoing label. The label's CIPSO form (a category bitmap derived from the label) was **pre-computed** when the label entered the [[smack-label-registry-explained|label registry]], so tagging needs no string work per packet. By default CIPSO uses domain of interpretation 3, which must match every CIPSO-speaking peer. IPv6 uses CALIPSO instead.

### Step 3: Read incoming labels
When a packet arrives, NetLabel decodes any CIPSO or CALIPSO tag, and Smack maps it back to the canonical label entry. The result is remembered on the socket. A packet **without** a tag gets the **ambient** label, the floor label "\_" by default, readable by everyone, so non-Smack machines can still talk to Smack hosts as long as the rules allow the ambient label.

### Step 4: Fixed labels for hosts that don't speak CIPSO
Administrators can assign a fixed label to an address or subnet, e.g. "everything from 192.168.1.5 is labelled webserver". These overrides are checked **before** any tag decoding and always take precedence. They let Smack make meaningful decisions in mixed networks, at the cost of trusting source addresses, which can be spoofed.

### Step 5: Check at connection time
This is the key step. Before an outgoing TCP connection is made, Smack works out the peer's expected label (from a host override or the socket's peer label) and checks that the connecting process may **write** to it. A denial fails the connect call **before any packet is sent**. For incoming connections, the label decoded from the connection request must have write access to the server process's label.

### Step 6: Check each delivery
On receive, the peer's label (the subject) must have write access to the local socket's label (the object), checked by the same [[smack-access-engine-explained|access engine]] used for files. Packets that fail are dropped.

## The picture

```text
 host A: process "Web" ── socket (out: "Web") ──▶ packet [CIPSO DOI 3: Web] ──▶ host B
                                                                   │
 host B: decode tag → "Web"   (no tag → ambient "_";  host override wins if configured)
         may "Web" write to socket label "DB"?  rule Web→DB includes w ?  deliver : drop
 connect(): local process must have write access to peer's label, else fail before sending
```

## Tradeoffs

- **What it gives you:** one policy model for files and networks, since sending is modelled as writing; labels that follow data between hosts; no user-space daemon needed for enforcement; admin interfaces only in smackfs.
- **What it costs / requires:** NetLabel support built in, and consistent CIPSO settings across peers. CIPSO was a 1992 IETF draft, never an RFC, but a de facto standard in trusted systems. Smack chose it because NetLabel already supported it, some commercial network hardware understands it, and a new protocol would have been far more work. The cost was that CIPSO is IPv4-only; IPv6 needed the separate CALIPSO standard, added later through the same NetLabel layer.
- **Where it bites:** each packet carries exactly **one** label. If Smack and SELinux are stacked, both want their own label on every packet, which one header can't hold: one of the remaining blockers to full stacking. Host overrides depend on source addresses, which can be spoofed.

## How it got here

- **2.6.23:** Smack's original submission included the CIPSO networking model; reviewers questioned relying on a draft that never became an RFC, and Casey Schaufler's answer, that it was already the de facto standard in trusted systems, was accepted.
- **2.6.30:** CIPSO integration through NetLabel, with the first smackfs network interfaces.
- **3.x:** the per-host IPv4 override table; socket label inheritance settled.
- **4.x:** IPv6 labelling with CALIPSO, and IPv6 host overrides.
- **5.x:** socket label data moved into framework-managed blobs, with more precise tracking of each socket's labelling state.

## Related

- Technical version: [[smack-network-labeling]]
- [[smack|Smack]], [[smack-access-engine-explained|Access engine]], [[smack-label-registry-explained|Label registry]], [[smack-inode-and-task-labeling-explained|Inode and task labelling]], [[smackfs-explained|smackfs]]
- [[netlabel-explained|NetLabel]], [[cipso-ipv4-engine-explained|CIPSO engine]], [[calipso-ipv6-engine-explained|CALIPSO engine]], [[net-explained|Networking stack]]
