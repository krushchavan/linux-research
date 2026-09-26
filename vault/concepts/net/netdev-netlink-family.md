---
title: "The netdev Generic Netlink Family"
category: concept
tags: [net, netlink, ynl, page-pool, napi, devmem]
subsystem: net
kernel_version: "6.3 (netdev family, xdp-features); 6.8 (queue/napi-get); 6.9 (qstats); 6.12 (bind-rx); 6.16 (bind-tx); 2026 (queue-create)"
researched: 2026-09-26
status: complete
explained: "[[netdev-netlink-family-explained]]"
sources:
  - https://github.com/torvalds/linux/blob/master/Documentation/netlink/specs/netdev.yaml
  - https://github.com/torvalds/linux/blob/master/net/core/netdev-genl.c
  - https://lwn.net/Articles/920499/
  - https://lwn.net/Articles/921377/
  - https://lwn.net/Articles/953110/
  - https://lwn.net/Articles/941737/
  - https://lwn.net/Articles/987621/
  - https://ratatoskr.run/netdev/2026/04/7945760/t
---

# The netdev Generic Netlink Family

> 📘 Plain-language version: [[netdev-netlink-family-explained]]

## Purpose

`rtnetlink` (`ip link`) has configured network devices since the 1990s, but it's a monolithic, hard-to-extend message format that grew by accretion. When XDP, page pools, NAPI instances, per-queue statistics and zero-copy memory providers needed a userspace interface, the networking maintainers created a new, **spec-first generic netlink family called `netdev`**. It is defined in YAML (`Documentation/netlink/specs/netdev.yaml`) and code-generated into kernel policy tables, uAPI headers and a userspace library (**YNL**). It is the control plane for most of the recent zero-copy work: `bind-rx`/`bind-tx` for [[devmem-tcp]], `queue-get` showing io_uring and devmem providers, `page-pool-get` for [[page-pool]] introspection, `napi-set` for busy-poll tuning, and in 2026 `queue-create` for netkit queue leasing ([[netdev-queue-management-api]]).

## Mental Model

If rtnetlink is the **old building's paper form**, which has been photocopied and annotated for 30 years, the netdev family is a **typed web API with a published schema**. The YAML spec is the source of truth. Kernel parsing policies, the uAPI enum values, the documentation and a client library are all generated from it, so they can't drift. Each object type (dev, page-pool, queue, napi, qstats, dmabuf) is a resource with `get` (do/dump) operations and change notifications on multicast groups, plus a few actions (`bind-rx`, `bind-tx`, `napi-set`, `queue-create`).

## How It Works

**Spec and codegen.** `netdev.yaml` declares `definitions` (enums and flags such as `xdp-act`, `xdp-rx-metadata`, `xsk-flags`, `queue-type`, `qstats-scope`, `napi-threaded`), `attribute-sets` (dev, page-pool, page-pool-stats, napi, queue, qstats, dmabuf, lease, io-uring-provider-info …), `operations`, and `mcast-groups` (`mgmt`, `page-pool`). `tools/net/ynl/ynl-gen-c.py` generates `net/core/netdev-genl-gen.[ch]` (policies and op tables) and `include/uapi/linux/netdev.h`. The hand-written handlers live in `net/core/netdev-genl.c`. Userspace uses the Python CLI (`tools/net/ynl/cli.py --spec netdev.yaml --dump queue-get`) or the generated C library (`ynl_sock_create(&ynl_netdev_family)`, `netdev_bind_rx()`), which is what `ncdevmem` and the zcrx selftests use.

**Operations (current tree).**
- **`dev-get`** (+ `dev-add/del/change-ntf` on `mgmt`) — per-device capability bitmaps: `xdp-features` (basic, redirect, ndo-xmit, xsk-zerocopy, hw-offload, rx-sg, ndo-xmit-sg), `xdp-zc-max-segs`, `xdp-rx-metadata-features` (timestamp, hash, VLAN tag), `xsk-features` (tx-timestamp, tx-checksum, tx-launch-time-fifo). This replaced guessing XDP support from driver names; libbpf's `bpf_xdp_query()` reads it ([[xdp]], [[af-xdp]]).
- **`page-pool-get`** (+ add/del/change notifications on `page-pool`) and **`page-pool-stats-get`** — each pool's id, ifindex, NAPI id, `inflight` buffers and memory, `detach-time` (pools lingering after their device went away, a leak signal), `dmabuf` id if a devmem provider backs it, `io-uring` provider info (`rx-buf-len`), and allocation/recycle counters ([[page-pool]]).
- **`queue-get`** — per queue: id, type (rx/tx), ifindex, NAPI id, and attached provider (`dmabuf` id, `io-uring` info), AF_XDP socket, and `lease` (for leased virtual queues). This is how an operator verifies a zero-copy binding took effect.
- **`napi-get`** / **`napi-set`** — NAPI instance id, IRQ, poller thread PID. `napi-set` (admin) tunes per-NAPI `defer-hard-irqs`, `gro-flush-timeout`, `irq-suspend-timeout` (the epoll-driven "IRQ suspension" busy-poll mode) and `threaded` NAPI. It's used with `SO_INCOMING_NAPI_ID` and epoll busy-poll to pin applications to queues ([[network-device-and-napi]]).
- **`qstats-get`** — standardized per-device or per-queue statistics (`scope`: device or queue): rx/tx packets and bytes, `alloc-fail`, `hw-drops`, `hw-drop-overruns`, csum and GSO/GRO counters, and so on, replacing inconsistent driver-specific `ethtool -S` names for common counters.
- **`bind-rx`** (`uns-admin-perm`) — bind a dma-buf to RX queues as a devmem provider, with optional `rx-page-size`; reply `id` ([[devmem-tcp-rx-dmabuf-binding-and-token-recycling]]).
- **`bind-tx`** (intentionally unprivileged) — DMA-map a dma-buf for devmem TX; reply `id` ([[devmem-tcp-tx]]).
- **`queue-create`** (2026) — create an RX queue on a virtual device (netkit) with a nested `lease {ifindex, queue, netns-id}` to a physical queue ([[netdev-queue-management-api]]).

**Per-socket state for bindings.** Devmem bindings must die with their owner. The family uses **generic netlink socket private data**: `genl_sk_priv_get(&netdev_nl_family, sk)` returns a `struct netdev_nl_sock` (a mutex plus a list of bindings) allocated per netlink socket (`netdev_nl_sock_priv_init()`). When the socket closes, `netdev_nl_sock_priv_destroy()` unbinds every binding on the list. That is how "close the netlink socket to unbind" and "crash-safe unbind" work without new syscalls.

**Locking.** Handlers take the per-netdev **instance lock** (`netdev_get_by_index_lock()`, `netdev_lock()`), not RTNL, for devices that opted into ops locking. Dumps iterate with RCU or xarray cursors. Notifications go out on multicast groups so tools such as `ynl --subscribe page-pool` can watch pool lifecycle.

**Namespaces.** Lookups use `genl_info_net(info)` (the netlink socket's netns). `CAP_NET_ADMIN` checks are per user namespace for `uns-admin-perm` ops, so containers with their own netns can bind queues on devices they own, or on leased queues. That combination is what makes pod-level zero-copy possible.

## Key Data Structures

**`netdev.yaml`** — the schema: definitions, attribute-sets, operations, mcast-groups.

**Generated `netdev_nl_family`** (`netdev-genl-gen.c`) — genl family with per-op policies, flags (`GENL_ADMIN_PERM`, `GENL_UNS_ADMIN_PERM`), and `sock_priv_size`/init/destroy hooks.

**`struct netdev_nl_sock`** (`include/net/netdev_netlink.h`) — per-socket `lock` and `bindings` list.

**uAPI enums** (`include/uapi/linux/netdev.h`) — `NETDEV_CMD_*`, `NETDEV_A_*`, `enum netdev_xdp_act`, `enum netdev_queue_type`, `enum netdev_qstats_scope`.

## Key Functions / Entry Points

- **`netdev_nl_dev_get_doit()` / `_dumpit()`**, **`netdev_nl_page_pool_get_*()`** (in `page_pool_user.c`), **`netdev_nl_queue_get_*()`**, **`netdev_nl_napi_get_*()` / `netdev_nl_napi_set_doit()`**, **`netdev_nl_qstats_get_dumpit()`**
- **`netdev_nl_bind_rx_doit()` / `netdev_nl_bind_tx_doit()` / `netdev_nl_queue_create_doit()`**
- **`netdev_nl_sock_priv_init()` / `netdev_nl_sock_priv_destroy()`** — binding lifetime
- **`netdev_genl_dev_notify()`** — dev change notifications

## Important Flags & Config Options

- Operations and permissions: `bind-rx` (`uns-admin-perm`), `bind-tx` (unprivileged), `napi-set` (`admin-perm`), `queue-create` (admin in netns)
- Multicast groups: `mgmt` (dev add/del/change), `page-pool` (pool add/del/change)
- Tools: `tools/net/ynl/cli.py`, generated `libynl` C bindings, `ynl` in newer distros; `ethtool` uses its own ethtool-netlink family, a sibling spec
- Driver hooks that feed it: `xdp_features`, `xdp_metadata_ops`, `stat_ops` (qstats), `netif_napi_set_irq()`, `netif_queue_set_napi()`

## Interactions with Other Subsystems

- **↑ Userspace**: libbpf (XDP feature query), YNL CLI and C library, `ncdevmem`, orchestration agents (Cilium for netkit leasing), observability tools
- **→ netdev core**: device iteration, instance lock, queue and NAPI bookkeeping ([[network-device-and-napi]])
- **→ page pool**: pool introspection and notifications ([[page-pool]])
- **→ devmem / io_uring zcrx**: bindings and provider reporting ([[devmem-tcp]], [[zero-copy-rx-zcrx]])
- **→ XDP / AF_XDP**: feature advertisement ([[xdp]], [[af-xdp]])
- **Compared with RDMA netlink (`NETLINK_RDMA` nldev)**: both are admin control planes exposing hardware-resource introspection and links. RDMA's predates the YAML spec approach and uses a dedicated netlink protocol with iproute2 `rdma` as the tool ([[rdma-netlink-restrack-and-cgroup]])

## Design Decisions & Tradeoffs

- **Spec-first, codegen everything.** Consistent validation and documentation, and a free client library in several languages. New attributes are cheap and forward-compatible. It costs a build dependency on the generator and some rigidity (attribute layouts must fit the schema model).
- **New family instead of extending rtnetlink.** Avoids rtnetlink's legacy (RTNL lock, sprawling IFLA namespace) and allows per-object dumps with notifications. The price is two interfaces for "device configuration", split by vintage.
- **Socket-scoped resources.** Tying bindings to netlink socket lifetime gives crash safety without new file types, but means an orchestrator must keep a socket open (or hand the work to the application).
- **Privilege split.** Queue-affecting ops need admin (in the user namespace), while caller-local ops (`bind-tx`) don't, following the principle of least privilege per operation.

## How It Has Evolved

- **6.2–6.3 (2023)** — YNL specs and codegen (Jakub Kicinski); `netdev` family with `dev-get` and xdp-features (Lorenzo Bianconi, Kicinski)
- **6.5–6.7** — XDP RX metadata and XSK features; page-pool introspection (`page-pool-get`, stats, notifications)
- **6.8** — `queue-get` and `napi-get` (Amritha Nambiar)
- **6.9–6.10** — `qstats-get` standardized statistics
- **6.12** — `bind-rx` for devmem TCP; per-socket priv for binding lifetime; `napi-set` (defer-hard-irqs, gro-flush-timeout) and later `irq-suspend-timeout` (6.13) and `threaded` (6.1x)
- **6.15–6.16** — io_uring provider reporting; `bind-tx`
- **2026** — `rx-page-size` on bind-rx; `lease` attributes and `queue-create` for netkit

## Further Reading

- Source — [`Documentation/netlink/specs/netdev.yaml`](https://github.com/torvalds/linux/blob/master/Documentation/netlink/specs/netdev.yaml)
- LWN — [Netlink protocol specs](https://lwn.net/Articles/920499/) (2023)
- LWN — [xdp: introduce xdp-feature support](https://lwn.net/Articles/921377/) (2023)
- LWN — [Introduce queue and NAPI support in netdev-genl](https://lwn.net/Articles/953110/) (2023)
- LWN — [tools/net/ynl: netlink-raw families](https://lwn.net/Articles/941737/)
- Related: [[netdev-queue-management-api]], [[devmem-tcp]], [[page-pool]], [[network-device-and-napi]]

## LKML Highlights

- **`<20230119003613.111778-1-kuba@kernel.org>`** — "Netlink protocol specs" (Jakub Kicinski). YAML specs, C codegen, docs and a generic YNL client, demonstrated by regenerating FOU. It became the required path for new netlink families.
- **`<170114286635.10303.8773144948795839629.stgit@anambiarhost.jf.intel.com>`** — queue and NAPI support in netdev-genl (Amritha Nambiar). Exposed queue→NAPI→IRQ/thread mapping to support busy polling and zero-copy placement. Read-only at first, then `napi-set` added configuration.
- **"netkit: Support for io_uring zero-copy and AF_XDP" v11 (Daniel Borkmann, David Wei, April 2026)** — added `queue-create` and nested `lease` attributes, reusing the family for container queue leasing.
