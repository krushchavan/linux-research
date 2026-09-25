---
title: "XDR Encoding (eXternal Data Representation)"
category: concept
tags: [nfs, xdr, rpc, serialization, sunrpc, encoding]
subsystem: nfs
kernel_version: "2.0"
researched: 2026-04-05
status: complete
explained: "[[xdr-encoding-explained]]"
sources:
  - https://github.com/torvalds/linux/blob/master/net/sunrpc/xdr.c
  - https://github.com/torvalds/linux/blob/master/include/linux/sunrpc/xdr.h
  - https://en.wikipedia.org/wiki/External_Data_Representation
  - https://web.cs.wpi.edu/~rek/DCS/D04/SunRPC.html
---

# XDR Encoding (eXternal Data Representation)

> 📘 Plain-language version: [[xdr-encoding-explained]]

## Purpose

RPC clients and servers may run on machines with different endianness, alignment requirements, and integer sizes. XDR (RFC 4506, originally RFC 1832) provides a canonical network byte order for serialising C-style data structures — integers, strings, arrays, unions, structures — so that heterogeneous systems can communicate correctly. The Linux kernel implements XDR in `net/sunrpc/xdr.c` and uses it for all NFS, NLM, and NSM message encoding/decoding.

## Mental Model

XDR is a **tape format**: every value occupies a 4-byte-aligned slot on an imaginary tape. Integers take one slot; 64-bit values take two; strings pad to the next 4-byte boundary after their length prefix. Encoding writes left-to-right onto the tape; decoding reads left-to-right. There is no skip list or field ID — the parser must know the exact message layout from the procedure schema. This simplicity makes encoding fast but requires both sides to agree on the schema (enforced by the RPC program/version/procedure identifier).

## How It Works

### Wire format rules

XDR defines a small set of encoding rules (RFC 4506, Section 4):

| Type | Wire size | Format |
|---|---|---|
| `int` / `unsigned int` | 4 bytes | Big-endian two's complement / unsigned |
| `hyper` / `unsigned hyper` | 8 bytes | Big-endian 64-bit |
| `float` / `double` | 4 / 8 bytes | IEEE 754 big-endian |
| `bool` | 4 bytes | 0 = false, 1 = true |
| `enum` | 4 bytes | Signed integer |
| `opaque[N]` (fixed) | `roundup(N, 4)` bytes | Raw bytes + padding zeros |
| `opaque<N>` (variable) | 4-byte length + `roundup(N, 4)` bytes | Length prefix + data + padding |
| `string<N>` | Same as variable opaque | UTF-8 / ASCII; length prefix counts bytes not including null |
| `T array[N]` (fixed) | `N × sizeof(T)` encoded back-to-back | No count prefix |
| `T array<N>` (variable) | 4-byte count + encoded elements | Count then elements |
| `union` | 4-byte discriminant + arm | Only the active arm is serialised |
| `void` | 0 bytes | Used as a union arm for no-data cases |

All values are **big-endian** (network byte order) and **4-byte aligned**. On little-endian x86, each integer field must be byte-swapped on encode and decode — `cpu_to_be32()` / `be32_to_cpu()` in the kernel.

### The kernel's `xdr_buf` — scatter/gather XDR buffer

Network I/O in the kernel uses scatter/gather to avoid copying. The kernel XDR layer uses `xdr_buf` to represent an RPC message spanning multiple memory regions:

```c
struct xdr_buf {
    struct kvec   head[1];   /* linear header: RPC/auth headers + first bytes of payload */
    struct bio_vec *bvecs;   /* optional page vector (for zero-copy file data) */
    struct kvec   tail[1];   /* linear trailer: any tail bytes after pages */
    struct page  **pages;    /* page array for page-based payload */
    unsigned int  page_base; /* offset into first page */
    unsigned int  page_len;  /* bytes of page data */
    unsigned int  buflen;    /* total buffer space allocated */
    unsigned int  len;       /* total message length (head + pages + tail) */
};
```

For metadata-only operations (GETATTR, LOOKUP, READDIR), the entire message fits in `head`. For read/write data operations, file data goes in `pages` (pointing directly to the page cache), avoiding a copy between the network buffer and the file data — **zero-copy I/O**.

### `xdr_stream` — cursor-based encode/decode

Rather than exposing `xdr_buf` directly, most XDR code uses `xdr_stream` as a cursor:

```c
struct xdr_stream {
    __be32       *p;           /* current write/read position */
    struct xdr_buf *buf;       /* the underlying buffer */
    struct kvec  *iov;         /* current kvec being written/read */
    struct kvec   scratch;     /* temporary kvec for partial reads */
    struct page **page_ptr;    /* current page in the pages array */
    unsigned int  nwords;      /* remaining words in current iov */
    ...
};
```

**Encoding** uses `xdr_reserve_space(xdr, n)` to advance the cursor by `n` bytes and return a pointer to write into. The caller writes the value with `*p++ = cpu_to_be32(val)`. An inline helper like `xdr_encode_u32()` wraps this pattern.

**Decoding** uses `xdr_inline_decode(xdr, n)` to read the next `n` bytes from the current position (returning a pointer into the buffer if linear, or copying to a scratch buffer if the data spans a page boundary). Callers read with `be32_to_cpup(p++)`.

### Per-procedure codec functions

Each NFS procedure defines an encode and decode function pair registered in the `rpc_procinfo` table:

```c
/* NFSv3 GETATTR */
static const struct rpc_procinfo nfs3_procedures[] = {
    [NFS3PROC_GETATTR] = {
        .p_proc   = NFS3PROC_GETATTR,
        .p_encode = nfs3_xdr_enc_getattr3args,
        .p_decode = nfs3_xdr_dec_getattr3res,
        .p_arglen = NFS3_getattr3args_sz,
        .p_replen = NFS3_getattr3res_sz,
        ...
    },
    ...
};
```

`p_arglen` / `p_replen` are the maximum XDR sizes in 4-byte words, used to pre-allocate `xdr_buf` space. The sunrpc layer calls `p_encode` with the `xdr_stream` positioned after the RPC header; `p_decode` is called on the received reply.

### Handling page boundaries

A recurring complication is that `xdr_buf.pages` may contain data that crosses page boundaries. `xdr_inline_decode()` detects this and falls back to copying bytes into `xdr_stream.scratch` — a small temporary buffer — so the caller always gets a contiguous pointer. For write data, the encoder uses `xdr_write_pages()` to embed page references directly in the buffer without copying.

## Key Data Structures

**`xdr_buf`** (`include/linux/sunrpc/xdr.h`) — scatter/gather buffer for one RPC message; head (linear) + pages (zero-copy data) + tail (linear).

**`xdr_stream`** (`include/linux/sunrpc/xdr.h`) — cursor into an `xdr_buf`; tracks current position and handles page-boundary crossings transparently.

**`rpc_procinfo`** (`include/linux/sunrpc/clnt.h`) — per-procedure descriptor: encode/decode function pointers, maximum argument/reply sizes.

## Key Functions / Entry Points

**`xdr_init_encode(xdr, buf, p, rqstp)`** (`net/sunrpc/xdr.c`) — initialises an `xdr_stream` for encoding into `buf`.

**`xdr_init_decode(xdr, buf, p, rqstp)`** (`net/sunrpc/xdr.c`) — initialises an `xdr_stream` for decoding from `buf`.

**`xdr_reserve_space(xdr, n)`** (`include/linux/sunrpc/xdr.h`) — advances the encoder cursor by `n` bytes; returns pointer to write into.

**`xdr_inline_decode(xdr, n)`** (`include/linux/sunrpc/xdr.h`) — reads `n` bytes from the decoder cursor; handles page-boundary copying via scratch buffer.

**`xdr_write_pages(xdr, pages, base, len)`** (`net/sunrpc/xdr.c`) — embeds page data into the buffer for zero-copy writes.

**`xdr_read_pages(xdr, len)`** (`net/sunrpc/xdr.c`) — consumes `len` bytes from the page region during decode (e.g. for NFS READ reply data).

**`xdr_encode_string()` / `xdr_decode_string_inplace()`** — common helpers for variable-length string encode/decode.

## Important Flags & Config Options

XDR has no Kconfig options of its own — it is always compiled when `CONFIG_SUNRPC` is enabled. The `XDR_QUADLEN(n)` macro computes `roundup(n, 4) / 4` and is used pervasively to calculate buffer sizes.

## Interactions with Other Subsystems

- **→ [[sunrpc]]**: every RPC call's encode/decode functions operate on `xdr_stream`s that are backed by `xdr_buf`s managed by the sunrpc transport layer.
- **→ Page cache**: zero-copy NFS READ/WRITE passes page cache pages directly via `xdr_buf.pages`, bypassing any extra copy between socket and file data.
- **← All RPC procedures (NFS, NLM, NSM, rpcbind)**: every protocol that uses sunrpc defines XDR codec functions for each operation.

## Design Decisions & Tradeoffs

**4-byte aligned, big-endian**: XDR chose big-endian in the 1980s when network protocols (IP, TCP) standardised on big-endian. Today most CPUs are little-endian (x86, ARM in LE mode), so every integer encode/decode requires a byte-swap. The performance cost is small for metadata-heavy workloads but measurable for high-IOPS small-write workloads.

**Schema-implied, no field IDs**: XDR messages have no self-describing structure — the parser must know the exact field sequence from the procedure schema. This is compact and fast but means any schema mismatch causes silent misparse or a length error. Protocol versioning (program/version/procedure IDs in the RPC header) is the only versioning mechanism.

**Scatter/gather via `xdr_buf`**: The head/pages/tail design lets the kernel send NFS READ data directly from the page cache without copying it through an intermediate buffer. This is critical for NFS throughput — without zero-copy, 1 GbE NFS would spend most CPU time in memcpy.

**`xdr_stream` cursor**: Earlier kernel XDR code used `xdr_buf` directly with manual pointer arithmetic. The `xdr_stream` abstraction (added in ~2.6.23) centralises page-boundary handling and bounds checking, making codec functions simpler and safer.

## How It Has Evolved

- **Early 2.x**: Basic XDR using `xdr_encode_*` / `xdr_decode_*` functions operating on `__be32 *` pointers directly.
- **2.6.23 (2007)**: `xdr_stream` introduced to handle page-boundary crossings and simplify codec functions.
- **3.x+**: Zero-copy page encoding generalised; `xdr_buf` scatter/gather used for both client (NFS WRITE) and server (NFS READ) zero-copy paths.
- **5.x+**: Ongoing work to use `xdr_stream` consistently across all codec functions (replacing legacy pointer-arithmetic patterns).

## Further Reading

1. **RFC 4506** — XDR specification: https://www.rfc-editor.org/rfc/rfc4506
2. **Kernel source — `net/sunrpc/xdr.c`**: https://github.com/torvalds/linux/blob/master/net/sunrpc/xdr.c
3. **Kernel header — `include/linux/sunrpc/xdr.h`**: https://github.com/torvalds/linux/blob/master/include/linux/sunrpc/xdr.h
