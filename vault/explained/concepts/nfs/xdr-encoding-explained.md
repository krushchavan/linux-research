---
title: "XDR Encoding — Explained"
category: explained
original: "[[xdr-encoding]]"
subsystem: nfs
tags: [explained, nfs, xdr, serialisation, zero-copy]
converted: 2026-09-25
---

# XDR encoding, explained

> Plain-language companion to [[xdr-encoding|the technical note]]. Same facts, fewer identifiers.

## The problem

An NFS client and server may run on very different machines: one little-endian, one big-endian; with different alignment rules and integer sizes. If each sent its in-memory structures as they are, the other would misread them. Both sides need one agreed way to lay out numbers, strings, arrays and structures on the wire.

The kernel adds a second demand: file data, the bulk of NFS traffic, shouldn't be copied needlessly between the network buffers and the page cache, and a message may be spread across several separate pieces of memory.

## The idea in one paragraph

XDR is a **tape format**. Every value sits in slots of 4 bytes on an imaginary tape, in big-endian order: an integer takes one slot, a 64-bit value two, and a string is a length followed by its bytes padded to the next 4-byte boundary. Encoding writes along the tape and decoding reads along it. There are no field names or tags; both sides must already know the exact layout, which is fixed by the RPC program, version and procedure. In the kernel, the "tape" can be split across a header, a run of page-cache pages and a tail, so file data never has to be copied into a separate buffer.

## Step by step

### Step 1: The wire rules
- integers, booleans and enums: 4 bytes, big-endian
- 64-bit integers: 8 bytes; floating point: IEEE 754, big-endian
- fixed-length opaque data: the bytes plus zero padding to a multiple of 4
- variable-length data and strings: a 4-byte length, then the bytes, then padding
- fixed arrays: elements back to back; variable arrays: a 4-byte count, then the elements
- unions: a 4-byte discriminant, then only the active branch

On little-endian machines such as x86, every integer is byte-swapped on the way in and out.

### Step 2: A buffer in three parts
One RPC message is held as a **head** (RPC and authentication headers and the first bytes of payload), an optional run of **pages**, and a **tail**. Metadata operations (getattr, lookup, readdir) fit in the head. For reads and writes, the file data lives in the pages, which point straight at the page cache.

This is the key step. Because file data is referenced where it already lives rather than copied, NFS can send read data straight from the page cache. Without this **zero copy**, NFS on 1 GbE would spend most of its CPU time copying memory.

### Step 3: A cursor over the buffer
Code rarely handles the three-part buffer directly. It uses a **stream cursor**:
- to encode, reserve the next *n* bytes and write values into them (byte-swapped)
- to decode, ask for the next *n* bytes and read them

When a value straddles a page boundary, the decoder copies those bytes into a small scratch area so the caller always gets one contiguous piece. When encoding write data, page references are embedded directly without copying.

### Step 4: One encoder and decoder per procedure
Each procedure (such as NFSv3 GETATTR) registers an encoder for its arguments and a decoder for its reply, plus the maximum size of each in 4-byte words so buffers can be sized in advance. The RPC layer calls the encoder with the cursor positioned just after the RPC header, and the decoder on the reply.

## The picture

```text
 GETATTR args on the "tape" (4-byte slots, big-endian):
 [ len of handle ][ handle bytes ......... pad ]

 one RPC message:
 ┌──────────── head ────────────┐┌── pages (page cache, no copy) ──┐┌─ tail ─┐
 │ RPC hdr │ auth │ READ args …  ││ file data │ file data │ …       ││ pad …  │
 └──────────────────────────────┘└─────────────────────────────────┘└────────┘
        ▲ cursor: reserve / decode n bytes (scratch copy if a value spans pages)
```

## Tradeoffs

- **What it gives you:** simple, fast, portable encoding that every machine agrees on, plus zero-copy handling of file data.
- **What it costs / requires:** byte-swapping every integer on little-endian CPUs (small for metadata, measurable for high-rate small writes); both sides must know the exact layout.
- **Where it bites:** messages don't describe themselves, so any mismatch in layout means a silent misreading or a length error. The only versioning is the program, version and procedure numbers in the RPC header.

## How it got here

- **Early 2.x:** encode and decode helpers doing pointer arithmetic on raw 32-bit words.
- **2.6.23 (2007):** the stream cursor, centralising page-boundary handling and bounds checking so each procedure's code became simpler and safer.
- **3.x+:** zero-copy page handling generalised for both client writes and server reads.
- **5.x+:** continuing to move every procedure onto the cursor style.

## Related

- Technical version: [[xdr-encoding]]
- [[sunrpc-explained|SunRPC]], [[nfs-explained|NFS subsystem]], [[nfs-client-explained|NFS client]], [[nfs-server-explained|NFS server]]
- [[page-cache-explained|Page cache]]
