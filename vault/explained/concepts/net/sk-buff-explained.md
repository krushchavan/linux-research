---
title: "sk_buff: The Network Packet Buffer — Explained"
category: explained
original: "[[sk-buff]]"
subsystem: net
tags: [explained, networking, skb, zero-copy, offload]
converted: 2026-09-25
---

# The skb (network packet buffer), explained

> Plain-language companion to [[sk-buff|the technical note]]. Same facts, fewer identifiers.

## The problem

A packet passes through many layers: driver, Ethernet, IP, TCP, socket. Each layer adds or removes its own header, makes decisions and remembers things about the packet. If each layer copied the packet into a new buffer to add or strip a header, the stack would spend most of its time copying bytes.

Packets also come in awkward shapes: a large TCP send may be 64 KB spread across many pages; multicast sends one packet to many receivers; hardware may already have checked (or be about to compute) checksums. One structure has to represent all of this and still let every layer work quickly.

## The idea in one paragraph

An **skb** is like a **shipping manifest travelling with a package on a conveyor belt**. The package (the packet bytes) sits still in a buffer. The manifest records where the package currently starts and ends, who owns it, which route it's taking, and notes added along the way. "Adding a header" is stapling a cover sheet to the front and moving the "start here" arrow; the package doesn't move. "Stripping a header" moves the arrow forward.

## Step by step

### Step 1: Allocate the buffer with room at both ends
A driver receiving a packet allocates an skb: a small metadata structure plus a separate data buffer. Four pointers divide the buffer:
- **head** to **data**: headroom, space reserved in front for lower layers' headers
- **data** to **tail**: the packet as currently seen
- **tail** to **end**: tailroom, space for appending

The driver writes the received bytes at the data pointer and advances the tail by that many.

### Step 2: Headers by pointer moves
This is the key step. Handing a packet from Ethernet to IP just moves the data pointer forward past the Ethernet header (**pull**); the bytes are still there, only out of view. TCP adding its header before IP sends moves the data pointer back into the headroom (**push**). Each is one arithmetic operation, with no copying.

Drivers reserve headroom up front for the headers they expect; modern drivers allow 192 bytes, enough for Ethernet (14), VLAN (4), IP (20) and TCP (up to 60). If a layer finds too little headroom, the skb must be reallocated, which is expensive.

### Step 3: Big packets in pieces
One linear buffer can't always hold everything. For segmentation offload, TCP may build a single skb describing 64 KB of data: the start in the linear buffer, the rest as **page fragments** (page, offset, length) listed in a shared-info area just past the buffer's end, which can also chain further skbs for IP fragments. The skb records how many bytes live in fragments. Code that needs to read headers sequentially first asks the stack to make sure the first *n* bytes are in the linear part, pulling them in from fragments if necessary.

### Step 4: Sharing without copying
There are two reference counts: one on the metadata structure, and one on the shared data buffer, split so it can also track who may write the headers. A **clone** gets its own metadata but shares the data buffer, which is how multicast works: one packet, then clones for the other receivers. A layer that wants to change the headers of a shared skb must check first, and make a full **copy** if needed; forgetting to check can corrupt another path's view of the packet.

### Step 5: Checksum status
The skb records how far checksumming has got:
- **none:** software must check or compute it
- **unnecessary:** hardware already verified it on receive, so skip the software check
- **complete:** hardware supplied a running sum; software can verify it in one step
- **partial:** hardware must compute it on transmit, with the skb recording where to start and where to put the result

### Step 6: Private notes for each layer
Every layer needs somewhere to keep temporary state (TCP sequence details, IP options, IPsec transform info) without disturbing the others. The skb has a 48-byte **scratch area** that each protocol treats as its own structure while it owns the packet. Layers are trusted not to read each other's notes. Longer-lived extra state goes in a proper **extension** mechanism added in 5.0.

### Step 7: Freeing
There are two ways to free an skb: one for normal consumption and one for drops. They differ only in how they're reported to tracing, which is what makes drop monitoring possible.

## The picture

```text
 one buffer, four pointers:
 [head]──headroom──[data]══ packet ══[tail]──tailroom──[end][shared info: page frags …]

 receive:  Ethernet ─pull 14─▶ IP ─pull 20─▶ TCP ─pull─▶ payload   (arrow moves, bytes stay)
 send:     payload ─push TCP─▶ push IP ─▶ push Ethernet             (into headroom)

 multicast: skb ─clone─▶ skb′ ─clone─▶ skb″   (own metadata, shared data)
```

## Tradeoffs

- **What it gives you:** constant-time header handling at every layer, no payload copies through the stack, scatter-gather for huge offloaded packets, cheap clones, and checksum offload bookkeeping.
- **What it costs / requires:** an extra pointer dereference to reach packet bytes; every layer must check for sharing before editing headers; headroom has to be guessed in advance.
- **Where it bites:** reference-count confusion has caused real vulnerabilities, such as skbs freed too early. Too little headroom forces expensive reallocations.

## How it got here

- **2.4 (2001):** page fragments added for scatter-gather DMA; before that, large sends had to be copied into one contiguous buffer.
- **2.6.14 (2005):** segmentation-offload fields describing large packets to drivers. Herbert Xu's generic segmentation work moved segmentation out of TCP into a shared layer, so drivers without support get pre-cut packets.
- **Zero-copy send:** skbs can hold references to pinned user pages, freed only after the card has finished transmitting, which avoids the copy for large TCP sends.
- **5.0 (2019):** the extension mechanism, replacing ad-hoc fields for IPsec, bridging and more.

## Related

- Technical version: [[sk-buff]]
- [[net-explained|Networking stack]], [[network-device-and-napi-explained|Devices and NAPI]], [[ip-routing-explained|IP routing]], [[tcp-ip-stack-explained|TCP/IP]]
- [[page-pool-explained|Page pool]], [[xdp-explained|XDP]], [[netfilter-explained|Netfilter]], [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking]]
