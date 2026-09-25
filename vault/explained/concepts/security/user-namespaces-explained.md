---
title: "User Namespaces — Explained"
category: explained
original: "[[user-namespaces]]"
subsystem: security
tags: [explained, security, namespaces, containers, capabilities]
converted: 2026-09-25
---

# User namespaces, explained

> Plain-language companion to [[user-namespaces|the technical note]]. Same facts, fewer identifiers.

## The problem

Containers routinely need operations that normally require root: bind-mounting, creating network devices, adjusting /proc. Without some form of isolation, a container runtime would have to run as real root on the host, so a container escape would mean host root. What's needed is a way for a process to be "root" for its own little world while staying an ordinary, unprivileged user as far as the host is concerned.

## The idea in one paragraph

A user namespace is a **privilege bubble**. Inside it, a process can be user 0 with every capability, own the files it creates, and manage other namespaces attached to its bubble. But the bubble itself is owned by an ordinary host user, and the kernel keeps track of that. A table of **ID mappings** translates user and group IDs inside the bubble to real IDs outside it. Anything that would affect the world *outside* the bubble is checked against the owner's real credentials, and ordinary users can't change global state.

## Step by step

### Step 1: Create the bubble
A process creates a new user namespace when cloning or unsharing. It records its parent, forming a tree rooted at the initial namespace (whose mapping covers every 32-bit ID). Namespaces can nest up to 32 deep (since 3.11).

### Step 2: Map the IDs, exactly once
A new namespace starts with **no mapping**, so every ID looks like the "overflow" ID (65534 by default) and the process can do little. The **parent** then writes mapping lines of the form "inside-ID, outside-ID, count". "0 1000 1" means user 0 inside is host user 1000. Up to 340 lines are allowed (5 before 4.16). A map can be written **only once**, so nobody can later claim a different host identity for the namespace. An unprivileged writer may only write a single line, mapping its **own** user ID, so it can't hand out host IDs it doesn't own. Helper programs let rootless containers use larger subordinate ID ranges set up by an administrator.

### Step 3: The group-dropping loophole
Inside a namespace, a process might drop supplementary groups. If a file is *denied* to a group the user belongs to, dropping that group could get around the restriction. So before an unprivileged writer may set the group map, it must first **permanently disable** group-dropping in that namespace and all its descendants (since 3.19). A privileged writer can keep it enabled.

### Step 4: Make ID mix-ups a compile error
This is the key step, and Eric Biederman's central design choice (proposed around 2012). Inside the kernel, user and group IDs are wrapped in their own small types instead of plain integers. The compiler then rejects any place that mixes a raw user-space ID with a kernel ID, or compares IDs from different namespaces. Most kernel code passes these wrapped IDs around without knowing namespaces exist. The few places that cross the boundary use explicit translations: "user-space ID as seen from namespace N → kernel ID" and back, with a variant that returns the overflow ID instead of an error for things like file-status results. All credential IDs use these types, so the rule spreads everywhere automatically. The whole kernel had to be checked for namespace awareness when it merged, rather than bugs turning up later in production.

### Step 5: Capabilities scoped to the bubble
The first process in a new namespace gets a **full capability set, valid only in that namespace** and those it owns below. There are two kinds of check:
- **global:** "does this process have the capability in the initial namespace?", which only real host root passes
- **namespaced:** "does it have the capability relative to *this* namespace?", which the bubble's root passes for its own namespace and its children, but not the parent

So a container with network-admin inside its namespace can configure its own network namespace's interfaces, but not the host's. One trap: running a new program with non-zero IDs clears capabilities. If a container's first process runs a shell before the parent has written the map, it loses them all, so runtimes wait for a "map written" signal first.

### Step 6: ID-mapped mounts (5.12+)
A namespace's mapping applies to every filesystem it sees. Containers sharing one filesystem image with different host ID ranges (100000–165535 for one, 200000–265535 for another) clash. **ID-mapped mounts** attach a mapping to an individual mount; the filesystem layer applies it before the namespace mapping, so each container sees the shared files with the ownership it expects, without a stacking filesystem like shiftfs. The mapping is fixed once applied.

### Step 7: Letting security modules decide (6.1+)
A security-module hook runs before a namespace is created, so modules can audit or refuse the attempt with a meaningful error. Its review stressed that it must support auditing, not only rejection.

## The picture

```text
 host (initial namespace)            user namespace "C" (owner: host uid 1000)
 uid 1000 (ordinary user)  ◀─map─    uid 0  "root", all capabilities *in C*
 uids 100000–165535        ◀─map─    uids 1–65535

 inside C: configure C's network namespace  → namespaced check  ✓
 inside C: load a kernel module             → global check      ✗
 file owned by host uid 1000 → appears as uid 0 inside C
```

## Tradeoffs

- **What it gives you:** rootless containers; namespace-scoped privilege; compile-time protection against ID confusion across the kernel; per-mount ownership views for shared images.
- **What it costs / requires:** maps can't be changed once written, so a running namespace can't be remapped (which affects tools like checkpoint/restore); more verbose kernel code for the ID types.
- **Where it bites:** user namespaces expose far more of the kernel to unprivileged code. Several serious vulnerabilities (CVE-2022-0185 in filesystem configuration, CVE-2023-32233 and CVE-2024-1086 in nf_tables) could only be reached from unprivileged user space through them, a structural consequence rather than a fixable bug. There's no consensus on whether unprivileged creation should be on by default: Debian disables it via a setting, Ubuntu 23.10+ restricts it through AppArmor with an allowlist, while Arch and stock Fedora leave it on. A 2023 proposal to limit which capabilities a new namespace's root receives (Jonathan Calmels) drew enthusiasm from Serge Hallyn but a rejection of its security-module hook from Paul Moore, and isn't merged.

## How it got here

- **Early 2.6:** only scaffolding; no ID mapping.
- **3.8 (2013):** usable at last, with Eric Biederman's 43-patch series adding the ID types and wiring up filesystems, networking and IPC.
- **3.11:** nesting limit of 32. **3.19:** group-dropping control.
- **4.9:** subordinate ID helpers stabilised for rootless containers. **4.16:** map limit raised from 5 to 340 lines.
- **5.12:** ID-mapped mounts. **6.1:** security-module hook for namespace creation (Frederick Lawler).
- **Ongoing:** distributions move toward restricting unprivileged creation by default in response to the vulnerabilities it exposes.

## Related

- Technical version: [[user-namespaces]]
- [[security-explained|Security subsystem]], [[capabilities-explained|Capabilities]], [[credentials-explained|Credentials]], [[lsm-framework-explained|LSM framework]], [[seccomp-bpf-explained|seccomp]], [[apparmor-explained|AppArmor]]
- [[network-namespaces-explained|Network namespaces]], [[vfs-explained|VFS]], [[cgroups-explained|cgroups]], [[nftables-explained|nftables]]
