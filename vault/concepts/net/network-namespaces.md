---
title: "Network Namespaces"
category: concept
tags: [networking, namespaces, containers, isolation, veth, net-ns]
subsystem: net
kernel_version: "2.6.24"
researched: 2026-04-14
status: complete
explained: "[[network-namespaces-explained]]"
sources:
  - https://lwn.net/Articles/580893/
  - https://lwn.net/Articles/219794/
  - https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html
---

# Network Namespaces

> 📘 Plain-language version: [[network-namespaces-explained]]

## Purpose

A network namespace provides a complete, isolated copy of the network stack — its own interfaces, routing tables, firewall rules, port space, sockets, and sysctl parameters — so that multiple independent environments can coexist on the same kernel without conflicting. This is the primitive that enables container networking (Docker, Kubernetes), process network sandboxing, and multi-tenant environments.

## Mental Model

A network namespace is like a **separate country inside a single building**. Each country (namespace) has its own postal system (port space), its own street map (routing tables), its own customs rules (iptables/nftables), and its own telephone network (sockets). The countries share the same physical building (kernel), but a phone call placed in one country cannot accidentally reach a number in another country. Embassies (veth pairs) provide controlled communication channels between countries.

## How It Works

**The `struct net` object.** Every network namespace is represented by a `struct net` (`include/net/net_namespace.h`). The initial namespace (`init_net`) is statically allocated at boot. All subsequent namespaces are allocated with `copy_net_ns()` and reference-counted. `struct net` holds the complete per-namespace state:
- `dev_base_head` — list of all `net_device`s assigned to this namespace
- `ipv4.fib_main` / `ipv4.fib_default` — independent IPv4 routing tables
- `ct.hash` — per-namespace conntrack table (if `CONFIG_NF_CONNTRACK`)
- Per-namespace sysctl values (like `ipv4.sysctl_ip_forward`)
- Per-namespace socket hash tables for TCP and UDP demultiplexing

**Creating a namespace.** A process calls `unshare(CLONE_NEWNET)` or `clone(CLONE_NEWNET)`. The kernel calls `copy_net_ns()`, which allocates a new `struct net` and calls `setup_net(net, user_ns)`. `setup_net()` walks the global `pernet_list` — a list of `struct pernet_operations` registered by each subsystem at init time. For each subsystem (IPv4, IPv6, ARP, conntrack, etc.), it calls `ops->init(net)` to initialise that subsystem's per-namespace state. This is the same pattern as module init but scoped to one namespace.

**Device assignment.** Physical NIC drivers create `net_device`s and register them into the initial namespace. A device can be moved to another namespace via `dev_change_net_namespace()` (the `ip link set dev eth0 netns <pid|nsname>` command). Only one namespace owns a device at a time; the device disappears from its old namespace and appears in the new one. Physical devices **cannot** be in a non-initial namespace while remaining accessible from the host — they must be moved entirely, which is why containers typically use virtual devices.

**veth pairs: the namespace bridge.** A `veth` pair is created as two virtual `net_device`s wired together: a packet transmitted on one end is received on the other. The standard container setup places one veth end inside the container's namespace (`eth0`) and leaves the other end (`veth0`) in the host namespace. Traffic flows: container app → `eth0` → crosses namespace → `veth0` → host bridge → other containers or the internet.

**Port isolation.** Each namespace has its own `tcp_hashinfo` and `udp_table` (accessed via `net->ipv4.tcp_death_row` and similar). `tcp_v4_rcv()` calls `__inet_lookup()` with the incoming packet's `net *` pointer, so it only searches that namespace's established socket table. Two containers can both bind `0.0.0.0:80` without conflict because their sockets are in different per-namespace hash tables.

**sysctl isolation.** Many `/proc/sys/net/` parameters are per-namespace. When a process in a namespace writes `/proc/sys/net/ipv4/ip_forward`, it only changes `net->ipv4.sysctl_ip_forward` for that namespace. The initial namespace's value is unchanged. This allows containers to independently enable IP forwarding for Kubernetes pod routing without enabling it globally.

**Namespace lifetime and cleanup.** A namespace is alive as long as any of these hold: a process has it as its network namespace, a `net_device` is assigned to it, a socket exists in it, or a bind-mounted `/proc/<pid>/ns/net` file holds a reference. When the last reference drops, `net_free()` calls each subsystem's `ops->exit()` callback (reverse order of `init()`), freeing all per-namespace state. This is where per-namespace conntrack tables, routing tables, and socket hash tables are freed.

**Namespace persistence via bind-mounts.** By default, a namespace disappears when the last process using it exits. To keep it alive (e.g., for a "named" namespace that outlives its creating process), the namespace can be bind-mounted: `mount --bind /proc/<pid>/ns/net /var/run/netns/mynet`. The bind-mount holds a reference. `ip netns` commands use this mechanism.

## Key Data Structures

**`struct net`** (`include/net/net_namespace.h`) — the namespace object.
- `dev_base_head` — list of all `net_device` in this namespace
- `loopback_dev` — the `lo` loopback device (created fresh per namespace)
- `ipv4.fib_main` / `ipv4.fib_default` — main and default IPv4 routing tables
- `ipv4.sysctl_ip_forward` — per-namespace forwarding flag
- `ns.inum` — inode number (the number in `/proc/net/ns/net`)
- `user_ns` — owning user namespace (for capability checks)
- `ct` — embedded struct with per-namespace conntrack state

**`struct pernet_operations`** (`include/net/net_namespace.h`) — subsystem registration.
- `init(net)` — called when a namespace is created; initialise per-namespace state
- `exit(net)` — called when a namespace is destroyed; free state
- `id` / `size` — optional: allocate a slab in `net->gen->ptr[]` for this subsystem's state without adding a field to `struct net`

## Key Functions / Entry Points

**`copy_net_ns()`** (`net/core/net_namespace.c`) — allocates and initialises a new `struct net`; called by `unshare(CLONE_NEWNET)`.

**`setup_net(net, user_ns)`** — walks `pernet_list`, calling `ops->init(net)` for each subsystem.

**`register_pernet_subsys(ops)`** — subsystems call this at module/init time to register their `pernet_operations`.

**`dev_change_net_namespace(dev, net, pat)`** (`net/core/dev.c`) — moves a `net_device` between namespaces; disconnects from old namespace's lists and connects to new.

**`get_net_ns_by_fd(fd)`** / **`get_net_ns_by_pid(pid)`** — retrieve a `struct net *` from a namespace file descriptor or process PID; used by `ip netns exec`.

## Important Flags & Config Options

- `CONFIG_NET_NS` — enable network namespace support (required for container networking)
- `unshare(CLONE_NEWNET)` — creates a new network namespace for the calling process
- `ip netns add myns` — creates a named (persistent) network namespace
- `ip netns exec myns <command>` — runs command inside the namespace
- `ip link set dev eth0 netns myns` — moves eth0 into myns
- `ip link add veth0 type veth peer name eth0` — creates a veth pair
- `/proc/sys/net/core/somaxconn` — per-namespace listen backlog limit

## Interactions with Other Subsystems

- **↑ Userspace**: `clone(CLONE_NEWNET)`, `unshare(CLONE_NEWNET)`, `setns(fd, CLONE_NEWNET)` syscalls; `ip netns` commands; Docker / containerd / nerdctl use these to create container namespaces
- **→ [[ip-routing]]**: each namespace has independent FIB tables; `fib_lookup()` takes `net *` as its first argument; all routing decisions are namespace-local
- **→ [[netfilter]]**: conntrack tables, nftables rulesets, and iptables tables are all per-namespace; `NF_HOOK()` passes `net *` to all hooks
- **→ [[tcp-ip-stack]]**: `tcp_hashinfo` socket demultiplexing is per-namespace; `tcp_v4_rcv()` looks up sockets in the packet's namespace only
- **← [[security]]**: user namespaces bound to network namespaces control which capabilities are effective; `CAP_NET_ADMIN` inside a user namespace only governs that network namespace

## Design Decisions & Tradeoffs

**`pernet_operations` late binding** — Rather than requiring every subsystem to declare all its per-namespace state in `struct net`, the `pernet_operations` + optional `gen->ptr[]` slab system allows subsystems to dynamically allocate their per-namespace state. This keeps `struct net` from growing unboundedly as features are added. The tradeoff is that subsystem code must look up its state via `net_generic(net, id)` rather than a direct field access.

**Physical device exclusivity** — A physical device can only be in one namespace at a time. This prevents unexpected routing loops (a packet entering on eth0 in namespace A cannot accidentally loop through eth0 in namespace B). The tradeoff is that advanced use cases (guest VMs that need hardware access) must use veth, macvlan, or SR-IOV VFs.

**Loopback per-namespace** — Each namespace gets its own `lo` device. This allows containers to bind `127.0.0.1` for localhost communication independently. The loopback is created during `setup_net()` in `loopback_net_init()`.

## How It Has Evolved

| Version | Change |
|---------|--------|
| 2.6.24 (2008) | Network namespaces merged (Eric Biederman); initial isolation of devices, routing, sockets |
| 2.6.29 (2009) | `ip netns` userspace tooling and named namespace bind-mounts |
| 3.0 (2011) | netfilter (conntrack, nftables) made per-namespace |
| 3.11 (2013) | Network namespaces became the foundation for Docker networking model |
| 4.15 (2018) | `SO_BINDTOIFINDEX` enables socket binding to specific namespace devices |

## Further Reading

1. [Namespaces in operation, part 7: Network namespaces (LWN, 2013)](https://lwn.net/Articles/580893/) — practical guide with veth pair examples
2. [Network namespaces (LWN, 2007)](https://lwn.net/Articles/219794/) — original design discussion
3. [Namespaces overview (LWN, 2013)](https://lwn.net/Articles/531114/) — broader namespace context

## LKML Highlights

- **Initial merge (2008)**: Eric Biederman's network namespace series was the largest namespace implementation. The key design debate was how much isolation to provide (just devices and routing? or also sockets and ports?). The decision was full stack isolation — any less would make container networking unreliable.
- **Netfilter namespace isolation (2011)**: Making conntrack and nftables per-namespace was deferred from the initial merge due to complexity. Completing it in 3.0 enabled containers to have independent firewall rules — critical for Kubernetes NetworkPolicy.
