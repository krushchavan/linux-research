---
title: "Network Device & NAPI"
category: concept
tags: [networking, napi, net-device, driver, interrupt-coalescing, softirq]
subsystem: net
kernel_version: "2.4.20"
researched: 2026-04-14
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/networking/napi.html
  - https://www.kernel.org/doc/html/latest/networking/scaling.html
  - https://lwn.net/Articles/833840/
  - https://lwn.net/Articles/244640/
---

# Network Device & NAPI

## Purpose

`struct net_device` is the kernel's abstraction for every network interface — Ethernet cards, Wi-Fi adapters, virtual devices, tunnels. NAPI (originally "New API", now just a name) is the interrupt-mitigation mechanism that allows a NIC driver to batch-process received packets under softirq context instead of taking one hardware interrupt per packet, eliminating the interrupt-storm problem at high packet rates.

## Mental Model

Imagine a toll plaza. Without NAPI, every car (packet) rings a separate bell (interrupt) to summon the toll collector (CPU). At rush hour, the collector spends all time answering bells and no time collecting tolls. NAPI installs a "busy light" on the plaza: the first car rings the bell, the collector disables the bell and works through all waiting cars in batch. Only when the plaza empties does the collector re-enable the bell. Under light traffic the bell still works normally (low latency); under heavy traffic the collector polls continuously (high throughput).

## How It Works

**Device registration.** A NIC driver calls `alloc_netdev()` (or `alloc_etherdev()`) to allocate a `net_device`, fills in its `net_device_ops` table, and calls `register_netdev()`. Registration links the device into the global `net_device` list under its network namespace and creates the `/sys/class/net/<ifname>` sysfs entry. From this point on, the kernel can call `ndo_open()` when `ip link set up` is issued.

**The receive interrupt path.** When a packet arrives at the NIC hardware, the DMA engine writes the packet bytes into a pre-allocated ring buffer descriptor and raises a hardware interrupt. The driver's interrupt service routine (ISR) runs in hard-IRQ context:

1. Acknowledges the interrupt to the NIC hardware.
2. Calls `napi_schedule(&dev->napi)`, which sets `NAPI_STATE_SCHED` and raises the per-CPU `NET_RX_SOFTIRQ` softirq flag.
3. Masks further receive interrupts on this queue via `napi_disable_irq()` or equivalent.
4. Returns immediately.

The soft IRQ runs after hard IRQ returns, in `net_rx_action()` (`net/core/dev.c`). This function iterates all `napi_struct` instances queued for this CPU and calls each one's `poll()` function with a `budget` (default 64 packets from `netdev_budget` per instance, capped at `net.core.netdev_budget` total per round).

**The driver's poll loop.** Inside `poll()`, the driver:
1. Reads the NIC's RX descriptor ring, consuming completed descriptors.
2. For each descriptor, allocates an `sk_buff` (or reuses a pre-allocated one from a page pool).
3. Fills the skb with the DMA-transferred packet bytes.
4. Calls `napi_gro_receive(napi, skb)` to pass the packet up the stack.
5. Replenishes the descriptor ring with fresh DMA-mapped pages.

If the ring is exhausted before `budget` packets are consumed, the driver has "done all the work." It calls `napi_complete_done(napi, work_done)`, which clears `NAPI_STATE_SCHED` and re-enables the NIC's receive interrupt. If the driver consumed exactly `budget` packets without emptying the ring, it returns `budget` — NAPI assumes there's more work and reschedules, suppressing the hardware interrupt.

**GRO (Generic Receive Offload).** `napi_gro_receive()` routes packets through the GRO engine before delivering to the protocol stack. GRO holds packets temporarily in a per-NAPI `gro_list` and coalesces consecutive TCP segments from the same flow into one larger `sk_buff`. This reduces the number of `ip_rcv()` and `tcp_rcv()` calls, cutting per-packet overhead. When the GRO window closes (on budget exhaustion, or when a non-coalescible packet arrives), `napi_gro_flush()` delivers the coalesced super-segment to `netif_receive_skb()`.

**Threaded NAPI (Linux 5.11).** By default, NAPI runs in softirq context, which means it borrows CPU time from whatever process happened to be running. This is "nearly invisible to the scheduler" and can cause latency jitter. Threaded NAPI creates a dedicated per-queue kernel thread (`napi/eth0-0`, `napi/eth0-1`, etc.) that sleeps until woken by `napi_schedule()`. The thread then calls the driver's `poll()` in process context under the normal scheduler, enabling:
- CPU affinity pinning via `taskset` or `cpuset`
- Nice/priority control
- Scheduler visibility (the thread shows up in `top` and `perf`)

Enable per-device: `echo 1 > /sys/class/net/eth0/threaded` or via ethtool.

**The transmit path.** Applications call `write()` or `sendmsg()`, which chains through the socket layer to `dev_queue_xmit()`. This function runs the packet through the qdisc (traffic control), then calls `dev_hard_start_xmit()`, which calls `ndo_start_xmit()` in the driver. The driver places the packet in the TX descriptor ring and notifies the NIC. When transmission completes, the TX interrupt handler calls `dev_kfree_skb_irq()` to free the skb.

**Multi-queue and RSS/RPS.** Modern NICs support multiple RX/TX queues. RSS (Receive Side Scaling) hashes incoming flows to queues in hardware, distributing load across CPUs with each queue assigned an IRQ affinity. When hardware RSS is unavailable, RPS (Receive Packet Steering) performs the same hash in software post-NAPI, then re-queues the skb on the target CPU's backlog for `netif_receive_skb()`.

## Key Data Structures

**`struct net_device`** (`include/linux/netdevice.h`) — the per-interface kernel object.
- `netdev_ops` — `const struct net_device_ops *`: driver callbacks
- `features` / `hw_features` — bitmask of `NETIF_F_*` offload capabilities
- `num_tx_queues` / `real_num_tx_queues` — configured vs. active TX queue count
- `_rx[]` — array of `netdev_rx_queue` structs (one per RX queue; holds XPS and BPF filter info)
- `nd_net` — owning network namespace
- `priv_flags` — `IFF_*` flags: `IFF_UP`, `IFF_RUNNING`, `IFF_PROMISC`, `IFF_SLAVE`, etc.
- `gso_max_size` — maximum GSO segment size; prevents oversized TSO from confusing legacy hardware

**`struct napi_struct`** (`include/linux/netdevice.h`) — one per receive queue.
- `poll` — driver's poll function: `int (*poll)(struct napi_struct *, int budget)`
- `state` — atomic bitfield: `NAPI_STATE_SCHED`, `NAPI_STATE_DISABLE`, `NAPI_STATE_THREADED`, `NAPI_STATE_PREFER_BUSY_POLL`
- `gro_hash[]` — per-NAPI GRO hash table for in-progress coalescing
- `poll_list` — link into the per-CPU softirq work list

**`struct net_device_ops`** (`include/linux/netdevice.h`) — the driver vtable.
- `ndo_open` / `ndo_stop` — called on `ip link set up/down`
- `ndo_start_xmit` — transmit one skb; returns `NETDEV_TX_OK` or `NETDEV_TX_BUSY`
- `ndo_set_mac_address`, `ndo_change_mtu` — configuration operations
- `ndo_get_stats64` — provide 64-bit interface statistics
- `ndo_bpf` — handle XDP BPF program attachment/detachment

## Key Functions / Entry Points

**`netif_napi_add(dev, napi, poll)`** — registers a NAPI instance; sets its `poll` callback; called during driver `ndo_open`.

**`napi_enable()` / `napi_disable()`** — enable/disable NAPI polling; `napi_disable()` waits for any ongoing poll to complete, making it safe to call from `ndo_stop`.

**`napi_schedule(napi)`** — called from ISR to request a poll; marks `NAPI_STATE_SCHED` and raises `NET_RX_SOFTIRQ`.

**`napi_complete_done(napi, work)`** — called when poll exhausts the ring; re-enables the hardware interrupt; updates NAPI statistics.

**`napi_gro_receive(napi, skb)`** — routes skb through GRO; may hold packet for coalescing; eventually calls `netif_receive_skb()`.

**`netif_receive_skb(skb)`** (`net/core/dev.c`) — delivers skb to the protocol demux (`ptype_base` table); each registered protocol handler (IP, ARP, etc.) is called in order.

**`dev_queue_xmit(skb)`** (`net/core/dev.c`) — top-level transmit entry point; runs qdisc, calls `dev_hard_start_xmit()`.

**`register_netdev(dev)`** — makes the device visible to userspace via sysfs and netlink; assigns the ifindex.

## Important Flags & Config Options

- `/proc/sys/net/core/netdev_budget` — max packets processed per NAPI softirq round across all devices (default 300)
- `/proc/sys/net/core/netdev_budget_usecs` — max microseconds per softirq round (default 2000)
- `/proc/sys/net/core/netdev_max_backlog` — per-CPU softirq input queue length; packets dropped if exceeded
- `SO_BUSY_POLL` socket option — enables busy-poll: userspace spins calling NAPI poll before blocking on `epoll`; trades CPU for latency (microsecond-range latency reduction)
- `/sys/class/net/<dev>/threaded` — enable threaded NAPI per device
- `ethtool -C eth0 rx-usecs 50` — set interrupt coalescing: only interrupt after 50 µs idle (reduces IRQ rate at cost of latency)
- `ethtool -L eth0 combined 8` — set number of combined RX/TX queue pairs (RSS queue count)

## Interactions with Other Subsystems

- **↑ Userspace**: `ioctl(SIOCGIFFLAGS)`, `ip link`, `ethtool` manipulate `net_device` state; `/sys/class/net/` exposes statistics and configuration
- **→ [[sk-buff]]**: drivers allocate `sk_buff`s in the NAPI poll path; `ndo_start_xmit()` receives an skb from the qdisc
- **→ [[traffic-control-qdisc]]**: `dev_queue_xmit()` enqueues into the device's root qdisc before calling the driver
- **→ [[xdp-express-data-path]]**: `ndo_bpf()` handles XDP attachment; the driver calls `bpf_prog_run_xdp()` inside its interrupt handler before NAPI
- **← [[netfilter]]**: no direct dependency; netfilter hooks are called by the IP layer after NAPI delivers the skb

## Design Decisions & Tradeoffs

**NAPI polling vs. per-packet interrupt** — The interrupt-per-packet model (pre-2.4.20) caused "receive livelock": at high pps, the CPU spent 100% of time handling interrupts and never ran the TCP processing code. NAPI solved this by making packet arrival edge-triggered (interrupt on first) rather than level-triggered (interrupt per packet). The tradeoff is slightly higher latency for the very first packet of a burst, which now waits for the softirq to schedule.

**Softirq vs. threaded NAPI** — Softirq context is CPU-efficient (no thread context switch) but invisible to the scheduler. Threaded NAPI makes the poll loop a schedulable entity, enabling affinity and priority control. The overhead is a context switch per poll activation — negligible at high pps but measurable at low pps.

**GRO coalescing** — GRO reduces IP/TCP calls by 10-40x for bulk TCP transfers. The tradeoff is increased latency for packets that get held in the GRO hash waiting for more coalescing candidates. A maximum hold time (`GRO_MAX_HEAD`) bounds the worst case.

## How It Has Evolved

| Version | Change |
|---------|--------|
| 2.4.20 (2002) | NAPI introduced by Jamal Hadi Salim and others |
| 2.6.29 (2009) | GRO added; software receive offload to complement hardware LRO |
| 3.11 (2013) | Multi-queue aware NAPI; one `napi_struct` per RX queue |
| 5.1 (2019) | Page pool API for high-performance skb allocation recycling |
| 5.11 (2021) | Threaded NAPI: dedicated per-device kernel threads |
| 6.0 (2022) | NAPI busy-poll improvements for io_uring networking |

## Further Reading

1. [NAPI polling in kernel threads (LWN, 2021)](https://lwn.net/Articles/833840/) — motivation, design, and scheduler integration
2. [Newer, newer NAPI (LWN, 2007)](https://lwn.net/Articles/244640/) — multi-queue NAPI evolution
3. [Batch processing of network packets (LWN, 2018)](https://lwn.net/Articles/763056/) — GRO and hardware offload interaction
4. [kernel.org: NAPI documentation](https://www.kernel.org/doc/html/latest/networking/napi.html) — official API reference including threaded NAPI and busy-poll
5. [kernel.org: Scaling in the Linux Networking Stack](https://www.kernel.org/doc/html/latest/networking/scaling.html) — RSS, RPS, RFS, XPS configuration

## LKML Highlights

- **NAPI introduction (2001-2002)**: The original NAPI RFC by Jeff Garzik and Alexey Kuznetsov described the "receive livelock" problem and proposed the edge-triggered poll model. The discussion centred on whether drivers should be required to implement poll (too much churn) or whether a generic fallback existed — `netif_rx()` became the fallback for drivers that didn't implement NAPI.
- **Threaded NAPI (2021)**: Sebastian Andersen's series faced concern that creating a kernel thread per queue would be wasteful on servers with 128-queue NICs. The solution was making it opt-in per-device and per-queue, with the traditional softirq path remaining the default.
