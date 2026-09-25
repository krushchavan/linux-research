---
title: "sk_buff: The Network Packet Buffer"
category: concept
tags: [networking, sk-buff, packet-buffer, memory, zero-copy]
subsystem: net
kernel_version: "2.0"
researched: 2026-04-14
status: complete
explained: "[[sk-buff-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/networking/skbuff.html
  - https://lwn.net/Articles/775255/
  - https://lwn.net/Articles/715811/
---

# sk_buff: The Network Packet Buffer

> 📘 Plain-language version: [[sk-buff-explained]]

## Purpose

`struct sk_buff` is the universal representation of a network packet as it travels through every layer of the Linux networking stack. Every subsystem — drivers, IP, TCP, socket layer — manipulates the same structure without copying the payload, because the design keeps packet data in a separate buffer and only updates pointer offsets as headers are added or stripped.

## Mental Model

Think of an `sk_buff` as a **shipping manifest that travels with a package on a conveyor belt**. The package itself (packet bytes) sits in a fixed buffer. The manifest (`sk_buff`) records: where the package starts and ends right now, who owns it, what route it's taking, and annotations accumulated along the way. When a layer "adds a header", it's like stapling a new cover sheet to the front of the manifest and moving the "start here" arrow — the package itself doesn't move. When a layer strips a header, the arrow moves forward.

## How It Works

When a NIC driver receives a packet, it calls `alloc_skb(size, GFP_ATOMIC)`, which allocates the metadata struct and a contiguous data buffer in one call via `kmalloc`. The buffer is divided into four regions using four pointer offsets stored in the `sk_buff`:

```
[head]...[headroom]...[data]...[payload bytes]...[tail]...[tailroom]...[end]
                              ^                 ^
                        skb->data          skb->tail
```

`skb->len = skb->tail - skb->data` (for purely linear buffers) gives the current logical packet length. The headroom (`skb->data - skb->head`) is reserved for lower layers to prepend headers without reallocation. The driver fills from `skb->data` and calls `skb_put(skb, len)` to advance `tail` by the received byte count.

**Layer operations are O(1) pointer moves.** When the Ethernet driver hands the skb to the IP layer, `skb_pull(skb, ETH_HLEN)` advances `data` past the Ethernet header — the bytes aren't erased, just excluded from the current view. When TCP wants to add a header before IP sends, it calls `skb_push(skb, sizeof(tcphdr))` to move `data` backward into headroom. Both are single arithmetic operations.

**Scatter-gather for large packets.** A single linear buffer can't always hold everything. For TSO (TCP Segmentation Offload), a TCP socket might produce an `sk_buff` representing 64 KB of data. The first portion lives in the linear buffer; additional pages are chained as `skb_frag_t` structs in `skb_shared_info.frags[]`. The `skb_shared_info` struct lives just past `skb->end` in the same allocation:

```c
struct skb_shared_info {
    __u8        nr_frags;           /* number of page fragments */
    skb_frag_t  frags[MAX_SKB_FRAGS]; /* page + offset + length */
    struct sk_buff *frag_list;      /* chained skbs for IP fragments */
    ...
};
```

`skb->data_len` holds the bytes in fragments; `skb->len - skb->data_len` is the bytes in the linear buffer. Code that needs sequential byte access calls `pskb_may_pull(skb, n)` to ensure the first `n` bytes are in the linear buffer, potentially pulling from fragments.

**Reference counting and cloning.** `sk_buff.users` is a refcount on the metadata struct. `skb_shared_info.dataref` is a split 16-bit counter: the upper 8 bits count `skb_clone()` users who share the data buffer; the lower 8 bits count users who may write the header. `skb_clone()` creates a second `sk_buff` that points to the same data buffer (increments `dataref`) but has its own metadata. This is how multicast works: one send produces one `sk_buff`, then `skb_clone()` produces N-1 clones for the other receivers. If a layer needs to modify headers of a cloned skb, `skb_share_check()` detects sharing and calls `skb_copy()` to make a fully independent copy.

**Checksum offload** is tracked via `skb->ip_summed`:
- `CHECKSUM_NONE`: no checksum computed yet; software must verify or compute
- `CHECKSUM_UNNECESSARY`: hardware verified the checksum on receive; skip software verify
- `CHECKSUM_COMPLETE`: hardware provided a running checksum in `skb->csum`; software can verify with one fold
- `CHECKSUM_PARTIAL`: hardware must compute the checksum on transmit; `csum_start` and `csum_offset` tell the hardware where to start and where to store the result

**The `cb[]` scratch space.** Each layer needs to store temporary state (TCP sequence numbers, XFRM transform info, IP options) without polluting other layers' view. `sk_buff.cb[48]` is an untyped 48-byte area that each protocol casts to its own struct. TCP uses it for `struct tcp_skb_cb`; IP uses it for `struct inet_skb_parm`. Layers are trusted not to read each other's scratch space.

## Key Data Structures

**`struct sk_buff`** (`include/linux/skbuff.h`) — the per-packet metadata struct.
- `next` / `prev` — doubly-linked list pointers for queues (socket receive queue, qdisc queue)
- `dev` — associated `net_device`; changes as the skb traverses the stack
- `sk` — owning socket (NULL until enqueued to a socket)
- `_skb_refdst` — cached `dst_entry` pointer for the routing decision
- `data` / `head` / `tail` / `end` — the four buffer boundary pointers
- `len` — total logical length (linear + fragment bytes)
- `data_len` — bytes in page fragments only
- `ip_summed` — checksum state
- `hash` / `l4_hash` — cached Toeplitz or software flow hash
- `cb[48]` — per-layer scratch space
- `priority` — SO_PRIORITY or DSCP-derived value; used by the qdisc

**`skb_frag_t`** (`include/linux/skbuff.h`) — one page fragment reference.
- `bv_page` — `struct page *`: the memory page
- `bv_offset` — byte offset within the page
- `bv_len` — byte count of valid data in this fragment

## Key Functions / Entry Points

**`alloc_skb()`** (`net/core/skbuff.c`) — allocates `sk_buff` + data buffer; called by drivers and the socket layer.

**`dev_alloc_skb()`** — `alloc_skb()` with `GFP_ATOMIC` and extra headroom for DMA alignment; the standard driver allocation call.

**`skb_push(skb, len)`** — extends `data` backward by `len` bytes to prepend a header; aborts if headroom is insufficient.

**`skb_pull(skb, len)`** — advances `data` forward by `len` bytes to strip a header.

**`skb_put(skb, len)`** — extends `tail` forward by `len` bytes to append data.

**`skb_clone(skb, gfp)`** — shallow copy; shares data buffer; increments `dataref`; fast path for multicast.

**`skb_copy(skb, gfp)`** — full copy; independent data buffer; used when modification is needed on a shared skb.

**`pskb_may_pull(skb, len)`** — ensures `len` bytes are in the linear buffer; pulls from fragments if needed; called before header parsing in IP/TCP receive paths.

**`skb_orphan(skb)`** — detaches the skb from its socket (zeroes `sk`, calls socket's `sk_destruct`); called when the skb leaves the socket's send queue.

**`kfree_skb()`** / **`consume_skb()`** — free the skb (consume is the "no error" path, kfree is the "dropped" path; they differ in drop accounting via tracepoints).

## Important Flags & Config Options

- `net.core.rmem_default` / `net.core.rmem_max` — default/max socket receive buffer; controls how many skbs a socket's receive queue holds before drops
- `net.core.wmem_default` / `net.core.wmem_max` — socket send buffer size
- `CONFIG_NET_SKB_RECYCLING` — experimental per-CPU skb free-list to reduce allocator pressure on high-pps paths
- `SKBTX_HW_TSTAMP` flag in `skb_shinfo->tx_flags` — requests hardware TX timestamping; used by PTP/IEEE 1588 implementations

## Interactions with Other Subsystems

- **↑ Userspace**: `sendmsg()` / `recvmsg()` copy data between `sk_buff` and user pages; `MSG_ZEROCOPY` avoids the copy by pinning user pages and attaching them as page fragments
- **→ [[network-device-and-napi]]**: drivers allocate skbs in their NAPI poll path; on transmit, `ndo_start_xmit()` receives an skb and maps its fragments to DMA descriptors
- **→ [[ip-routing]]**: `skb->_skb_refdst` is set by `ip_route_input()` and consumed by `ip_forward()` / `ip_local_deliver()`
- **← [[netfilter]]**: netfilter hooks receive an `sk_buff *` as their primary argument; `skb->_nfct` holds the conntrack entry pointer; `skb->nf_bridge` holds bridge info

## Design Decisions & Tradeoffs

**No embedded data** — Keeping data in a separate allocation means the `sk_buff` struct itself can be small and cache-hot. The tradeoff is the extra pointer dereference to access packet bytes, but this is dominated by the benefit of avoiding copies.

**Headroom allocation upfront** — Drivers allocate with enough headroom for all headers they anticipate (NET_SKB_PAD bytes of headroom). This is a heuristic; if it's wrong, `skb_realloc_headroom()` must copy the metadata struct, which is expensive. Modern drivers allocate 192 bytes of headroom to cover Ethernet (14) + VLAN (4) + IP (20) + TCP (60) headers.

**`dataref` split counter** — The two-level reference count (metadata vs data) lets `skb_clone()` avoid data copies while still allowing header modifications without writer-writer races. The downside is subtle: a driver that modifies an skb it received must check `skb_shared()` first or risk corrupting another path's view.

## How It Has Evolved

- **2.4 (2001)**: Frags array added to support scatter-gather DMA; prior to this, large TSO-like operations required copying everything into one contiguous buffer.
- **2.6.14 (2005)**: `skb_shared_info` added `gso_size` / `gso_segs` fields to describe GSO packets to drivers; drivers that don't support GSO see pre-segmented packets.
- **4.1 (2015)**: `MSG_ZEROCOPY` infrastructure added; skb can hold `struct ubuf_info` references to user pages, eliminating the copy for large TCP sends.
- **5.0 (2019)**: `sk_buff` extension mechanism (`skb_ext`) merged; replaces ad-hoc `__pkt_type_offset` unions with a clean extensible API for IPsec, bridge, and other per-skb fields.

## Further Reading

1. [sk_buff: add extension infrastructure (LWN, 2019)](https://lwn.net/Articles/775255/) — motivation and design of the extension mechanism
2. [The case of the prematurely freed SKB (LWN, 2016)](https://lwn.net/Articles/715811/) — real vulnerability caused by reference count confusion
3. [kernel.org: sk_buff reference](https://www.kernel.org/doc/html/latest/networking/skbuff.html) — checksum offload state machine documentation
4. *Understanding Linux Network Internals* (Benvenuti, O'Reilly) — Chapter 2 covers sk_buff comprehensively

## LKML Highlights

- **GSO introduction (2006)**: Herbert Xu's GSO series moved the segmentation from TCP into a generic layer between TCP and the driver, so that new protocols could benefit without per-protocol code. The key insight was storing `gso_size` in `skb_shared_info` rather than the `sk_buff`, keeping the common case cheap.
- **MSG_ZEROCOPY (2018)**: The zero-copy send infrastructure needed a mechanism to delay freeing user pages until the NIC DMA completes. The solution was adding `ubuf_info` callbacks tracked in `skb_shinfo->destructor_arg`, invoked when the last reference to the skb is dropped.
