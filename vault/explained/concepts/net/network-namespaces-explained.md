---
title: "Network Namespaces — Explained"
category: explained
original: "[[network-namespaces]]"
subsystem: net
tags: [explained, networking, namespaces, containers, veth]
converted: 2026-09-25
---

# Network namespaces, explained

> Plain-language companion to [[network-namespaces|the technical note]]. Same facts, fewer identifiers.

## The problem

Containers, sandboxes and multi-tenant hosts all want separate networks on one kernel. Two containers should both be able to listen on port 80, have their own routes and firewall rules, and change settings like IP forwarding without affecting each other or the host. Running a whole kernel per environment would be far too heavy; sharing one network stack would make them collide.

## The idea in one paragraph

A **network namespace** is like a **separate country inside one building**. Each country has its own postal system (port numbers), street map (routing tables), customs rules (firewall) and phone network (sockets). They share the building (the kernel), but a call placed in one country can't accidentally reach a number in another. **Embassies**, in the form of veth pairs, provide controlled links between countries.

## Step by step

### Step 1: One object holds a whole network stack
Each namespace is one kernel object holding everything per-namespace: its list of network devices, its own loopback device, its IPv4 routing tables, its connection-tracking table, its network sysctl values, and its socket hash tables for TCP and UDP. The first namespace is created at boot; the rest are allocated on demand and reference-counted.

### Step 2: Creating one
A process calls `unshare` or `clone` asking for a new network namespace. The kernel allocates the object and then walks a global list of **per-namespace hooks** that every networking subsystem registered at start-up: IPv4, IPv6, ARP, connection tracking and so on. Each gets an "initialise your state for this namespace" call, including creating a fresh loopback device.

This is the key design choice. Subsystems don't have to add fields to the namespace object; they can ask for a private slot of per-namespace storage and look it up by ID. The namespace object doesn't grow with every new feature, at the cost of a lookup instead of a direct field access.

### Step 3: Moving devices
Physical card drivers register their devices in the first namespace. A device can be **moved** to another namespace, disappearing from the old one and appearing in the new; it belongs to exactly one at a time, which prevents routing loops through a shared device. Because moving a physical card takes it away from the host, containers usually use virtual devices instead.

### Step 4: veth pairs, the bridge between namespaces
A **veth** pair is two virtual devices wired back to back: whatever is sent on one end arrives on the other. The usual container setup puts one end inside the container (as `eth0`) and leaves the other in the host, attached to a bridge. Traffic goes: container app → `eth0` → across the boundary → host end → bridge → other containers or the internet. Macvlan, ipvlan and SR-IOV virtual functions are alternatives.

### Step 5: Separate port spaces
When a TCP packet arrives, socket lookup is given the packet's namespace and searches **only that namespace's** tables. Two containers can therefore both bind port 80 without conflict: their sockets live in different tables.

### Step 6: Separate settings
Many network settings under `/proc/sys/net` are per namespace. Enabling IP forwarding inside a container changes only that container's value, so a Kubernetes pod network can forward without turning forwarding on for the whole host. A process's network admin capability inside a user namespace only applies to network namespaces owned by that user namespace.

### Step 7: Lifetime
A namespace stays alive while anything references it: a process running in it, a device assigned to it, a socket inside it, or a bind-mounted namespace file. When the last reference goes, every subsystem's "exit" hook runs in reverse order, freeing its routing tables, connection-tracking tables and socket tables. To keep a namespace around after its creator exits, bind-mount its namespace file somewhere; that's how named namespaces (`ip netns`) work.

## The picture

```text
 host namespace                               container namespace
 ┌────────────────────────────┐              ┌──────────────────────────┐
 │ eth0 (physical)  lo         │              │ lo    eth0 (veth end)     │
 │ bridge ── veth-host ════════╪══ veth pair ═╪══▶                          │
 │ routes, firewall, conntrack │              │ own routes, firewall      │
 │ sockets: :22, :443          │              │ sockets: :80 (no clash)   │
 └────────────────────────────┘              └──────────────────────────┘
 create: unshare(new net) → run every subsystem's per-namespace init
```

## Tradeoffs

- **What it gives you:** full, independent network stacks for containers on one kernel, with separate ports, routes, firewalls and settings.
- **What it costs / requires:** per-namespace copies of tables and a loopback device; virtual devices (and a bridge or similar) to connect namespaces; a lookup for each subsystem's per-namespace state.
- **Where it bites:** a physical card can't be shared between the host and a container, only moved. A namespace that "should" be gone can linger because a stray socket or bind mount still references it.

## How it got here

- **2.6.24 (2008):** network namespaces merged (Eric Biederman), isolating devices, routing and sockets. The key debate was how far to go, and full-stack isolation won, since anything less would make container networking unreliable.
- **2.6.29 (2009):** `ip netns` tooling and named namespaces through bind mounts.
- **3.0 (2011):** connection tracking and nftables made per namespace (deferred from the first merge for complexity), letting containers have independent firewall rules.
- **3.11 (2013):** by now the basis of Docker's networking model.
- **4.15 (2018):** a socket option for binding sockets to a specific device by index.

## Related

- Technical version: [[network-namespaces]]
- [[net-explained|Networking stack]], [[ip-routing-explained|IP routing]], [[tcp-ip-stack-explained|TCP/IP]], [[network-device-and-napi-explained|Devices and NAPI]]
- [[mount-namespace-explained|Mount namespaces]], [[user-namespaces-explained|User namespaces]], [[netfilter-explained|Netfilter]], [[cgroups-explained|cgroups]]
