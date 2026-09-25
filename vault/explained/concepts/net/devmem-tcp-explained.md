---
title: "Device Memory TCP (devmem TCP) — Explained"
category: explained
original: "[[devmem-tcp]]"
subsystem: net
tags: [explained, networking, zero-copy, dma-buf, gpu]
converted: 2026-09-25
---

# Device-memory TCP, explained

> Plain-language companion to [[devmem-tcp|the technical note]]. Same facts, fewer identifiers.

## The problem

Distributed machine-learning jobs shuttle huge tensors between accelerators on different machines. Normally each transfer goes GPU → host RAM (a PCIe copy) → NIC → network → NIC → host RAM → GPU (another PCIe copy). The host CPU never needs to look at the data, yet host memory bandwidth and PCIe bandwidth are both burned, and the data crosses the root complex twice.

RDMA and GPUDirect avoid those copies, but need special fabrics and bypass TCP altogether, losing its congestion control, retransmission and firewalling. The goal here is to keep an ordinary **kernel TCP** connection, but have the payload land directly in **device memory**.

## The idea in one paragraph

It's **mail delivered into a sealed vault**. The post office (the kernel's TCP stack) still reads every envelope (the headers), tracks deliveries, sends receipts and resends lost letters. But the letters' contents go straight into a vault (GPU memory) that the post office never opens. The recipient gets a slip saying "your letter is in vault 7, shelf 1234, 4096 bytes", and hands the slip back when it has emptied that shelf. The network card splits each packet so that headers go to normal host memory and payloads go to the device.

## Step by step

### Step 1: Prepare the network card
Three NIC features make it possible to put only the right payloads in device memory (the same ones [[io-uring-zero-copy-networking-explained|io_uring zero-copy receive]] needs):
- **header/data split:** each packet's headers go to one buffer, its payload to another
- **flow steering:** the application's flows are sent to a chosen receive queue
- **RSS reconfiguration:** nothing else lands on that queue

### Step 2: Bind device memory to a queue
The application exports accelerator memory as a **dma-buf**, the kernel's standard object for sharing buffers between devices. It then asks, over a netlink interface, to bind that dma-buf to specific receive queues. The kernel:
1. maps the dma-buf for the NIC, getting its DMA addresses
2. cuts those addresses into page-sized chunks, each described by a small **net_iov** descriptor, kept in an allocator
3. installs this as the queue's [[page-pool-explained|page pool]] **memory provider** and restarts the queue

The binding lives as long as the netlink socket, so if the process dies, the queue is automatically unbound.

### Step 3: Why not ordinary pages
Device memory has no page structures: it isn't system RAM, and GPU drivers deliberately don't create pages for it. The networking stack, though, was built around pages. The fix was **netmem**: a tagged reference that is *either* a page *or* a net_iov. The page pool, skb fragments and TCP receive path were all converted to carry it, and a net_iov holds just the fields the page pool needs (its pool, DMA address, reference count) without pretending to be a page.

### Step 4: Receive into the vault
This is the key step. The driver refills its receive descriptors from the page pool as usual, but now gets net_iovs backed by the dma-buf. The NIC writes each payload straight into GPU memory and the header into a normal host page. The resulting skb has the header in its linear part and fragments pointing at device memory, and it's marked **unreadable**. That's a hard rule for the rest of the stack: nothing may touch those payload bytes. So:
- no software checksum (the NIC must have verified it)
- no copying to user space, and no pulling payload into the header area
- no loopback, no packet capture of payloads, no BPF access to payloads for these flows
- merging only combines fragments of the same kind

TCP works normally: sequence numbers, acknowledgements, windows and retransmission all live in the headers.

### Step 5: Tell the application where its data is
The application calls `recvmsg` with a device-memory flag. Instead of copying bytes, the kernel walks the receive queue and returns **control messages**:
- **device data:** an offset into the dma-buf, a size, the buffer's ID, and a **token** for this piece
- **linear data:** this part landed in host memory (for example, header split didn't separate it); it's copied out normally

The kernel keeps a reference on each piece delivered, tracked per socket by token, so the NIC can't overwrite data the application hasn't used yet. The application then runs its GPU kernels on the data at those offsets.

### Step 6: Hand the shelves back
When finished, the application returns ranges of tokens through a socket option; the references drop and the chunks go back to the page pool for the NIC to reuse. Each call is capped (the docs cite 128 tokens and 1,024 fragments). An application that holds tokens too long starves the queue and causes packet drops, the main operational hazard.

### Step 7: Sending from device memory
Transmit support binds a dma-buf for the sending direction, then uses zero-copy `sendmsg` where the data describes *offsets into the dma-buf*, not user pointers. The NIC reads the payload straight from device memory, and completions arrive on the error queue as for ordinary zero-copy sends. Before transmission, the kernel checks that the packet is leaving through the device the dma-buf was bound to.

### Step 8: When things go wrong
A flow not steered to the bound queue lands in host memory and is reported as linear data: correct, but slower. If the provider runs out of chunks, the NIC drops packets and TCP retransmits. Binding is refused if the device can't checksum or split headers. Unbinding restarts the queue on ordinary pages.

## The picture

```text
 GPU memory (dma-buf) ◀── payloads ── NIC ── headers ──▶ host pages
        ▲ bound as the queue's page-pool provider               │
        │                                                  TCP stack (seq, ACK, windows)
 app: recvmsg(device flag) ◀── slips: {buffer 7, offset 1234, 4096 bytes, token 55}
      run GPU work on the data at that offset
      setsockopt(return tokens 55–60) ─▶ chunks back to the page pool ─▶ NIC refills
```

## Tradeoffs

- **What it gives you:** payloads delivered straight into accelerator memory over plain kernel TCP, with no host copies, and working with any TCP peer and any dma-buf exporter (GPU, accelerator, or a host-memory stand-in for testing).
- **What it costs / requires:** NICs with header split, checksum offload and flow steering; the host CPU still processes every header; unreadable flows lose features that need payload access.
- **Where it bites:** buffer lifetime becomes the application's job; slow consumers cause drops rather than TCP back-pressure. Making unreadable skbs safe meant auditing every stack path that might touch payload bytes.

## How it got here

- **2022–2023:** proposals from Google (Mina Almasry and colleagues), and groundwork abstracting pages out of the network stack.
- **6.10–6.11:** netmem references, memory-provider hooks and the queue-management API.
- **6.12 (2024):** device-memory TCP receive merged, first on Google's gve driver. MM and GPU reviewers (notably Christoph Hellwig and Jason Gunthorpe) had resisted fake pages, which forced the netmem design through 14+ revisions.
- **6.15:** io_uring zero-copy receive reuses the same provider machinery; mlx5, bnxt and others add support.
- **2025–2026:** device-memory transmit, netmem descriptors split out from page structures, and continued driver and token-handling work.

## Related

- Technical version: [[devmem-tcp]]
- [[page-pool-explained|Page pool]], [[io-uring-zero-copy-networking-explained|io_uring zero-copy receive]], [[net-explained|Networking stack]], [[sk-buff-explained|skb]], [[tcp-ip-stack-explained|TCP/IP]], [[network-device-and-napi-explained|Devices and NAPI]]
- [[dma-mapping-api-explained|DMA mapping]]
