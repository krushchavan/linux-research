---
title: "Kernel Crypto API — Explained"
category: explained
original: "[[kernel-crypto-api]]"
subsystem: crypto
tags: [explained, crypto, scatter-gather, hardware-acceleration]
converted: 2026-09-25
---

# The kernel crypto API, explained

> Plain-language companion to [[kernel-crypto-api|the technical note]]. Same facts, fewer identifiers.

## The problem

Lots of kernel code needs cryptography: IPsec, disk encryption ([[dm-crypt-explained|dm-crypt]]), file encryption ([[fscrypt-explained|fscrypt]]), TLS, WireGuard, key checking. If each carried its own copy of AES or SHA, a CPU's AES instructions or a crypto coprocessor couldn't be shared, a bug would need fixing in ten places, and auditing (or FIPS certification) would be hopeless.

Kernel data also rarely sits in one tidy buffer. Network packets and block I/O are scattered across many pages, and making a contiguous copy just to encrypt it would waste memory and CPU.

## The idea in one paragraph

Treat algorithms like **devices with drivers**. Just as the block layer hides whether storage is a spinning disk or an SSD, the crypto API hides whether AES runs as plain C, as special CPU instructions, or on an accelerator chip. A caller asks for an algorithm by name and gets a **transform handle** bound to the best available implementation. It then hands over data as a **scatter-gather list** of page fragments, which is processed in place, and the operation either finishes immediately or reports back later.

## Step by step

### Step 1: Implementations register themselves
At load time each implementation registers under a **generic name** ("aes"), a **unique driver name** ("aes-aesni"), and a **priority**. When several register the same generic name, say plain C at priority 100 and the CPU-instruction version at 300, lookups pick the highest. Callers can still request a specific driver by its unique name. Everything registered is listed in `/proc/crypto`, with self-test status.

### Step 2: Names describe compositions
This is the key design choice. A request for "cbc(aes)" means: apply the CBC **template** around the AES cipher. Templates register separately and combine with primitives on demand: "hmac(sha256)" wraps SHA-256 in HMAC, and "authenc(hmac(sha1),cbc(aes))" nests two constructions into one authenticated cipher. Each piece resolves to its best implementation, and the result is one transform handle holding the key, per-instance state and a dispatch table.

### Step 3: Set the key, then build requests
Allocating a transform doesn't encrypt anything; it only binds an algorithm, and then the key is set. Each actual operation uses a **request**: input and output scatter-gather lists, the IV, the length, and (for asynchronous use) a completion callback. Requests are allocated on the heap because they may outlive the calling function.

### Step 4: Process data where it lies
Each scatter-gather entry is a (page, offset, length) fragment. Implementations walk the list, working block by block and handling blocks that straddle fragment boundaries, without ever building one contiguous buffer. This came from the API's first user, IPsec, whose packets are already fragmented.

### Step 5: Synchronous or asynchronous, same call
Calling encrypt or decrypt returns either "done" (typical for software) or "in progress" (typical for hardware that queues the job on a DMA engine and reports back later through the callback, in softirq context). The same calling code handles both, but mustn't touch the buffers until completion, and there's no implicit locking around request data. Callers can also insist on asynchronous implementations when they allocate.

### Step 6: A queue for hardware drivers
Hardware drivers can use the **crypto engine** instead of writing their own queues. They provide three hooks (prepare DMA descriptors, submit one request, clean up afterwards), and the engine handles ordering and back-pressure.

### Step 7: A door for user space
The **AF_ALG** socket family (2.6.38) exposes the API to programs: bind a socket to an algorithm, set a key, accept an operation socket, then send data and read the result. A splice-based zero-copy path is capped at 16 pages (about 64 KB) per operation. Throughput is roughly half of OpenSSL's own AES-instruction code because of system-call overhead, so it's most useful when only the kernel can reach an accelerator.

## The picture

```text
 register:  aes-generic (prio 100)  aes-aesni (prio 300)  cbc template  hmac template
 caller:    alloc("cbc(aes)") ─▶ cbc template ∘ best "aes" = aes-aesni ─▶ transform
            set key
            request { src SG list, dst SG list, IV, length, callback }
            encrypt(request) ─▶ 0 (done now)  |  "in progress" ─▶ callback later
 SG list:   [page A +100, 1200 B] [page B +0, 4096 B] [page C +0, 800 B]  (no copying)
```

## Tradeoffs

- **What it gives you:** one shared, accelerated, self-tested implementation of each algorithm; composable constructions by name; efficient processing of fragmented kernel data; and hardware offload with no changes to callers.
- **What it costs / requires:** a complex allocation and request model, every algorithm written to walk scatter-gather lists, and callers that must handle both completion styles, a historical source of bugs (missed "in progress" handling, use-after-free in callbacks).
- **Where it bites:** priority-based selection means a buggy optimised driver silently affects every user, and skipping boot self-tests makes that worse. FIPS certification traditionally covered the whole kernel image, so unrelated kernel updates could invalidate it.

## How it got here

- **2.5.45 (2002):** the original scatter-list crypto API, motivated by IPsec.
- **2.6.x (2003–2010):** more algorithms, synchronous and asynchronous multi-block cipher types, templates, and hardware drivers. **2.6.38 (2011):** AF_ALG (Herbert Xu).
- **3.x–4.x (2012–2017):** authenticated ciphers consolidated, hash types unified, the crypto engine, and a modern symmetric-cipher interface replacing the old pair.
- **2018–2019:** Jason Donenfeld's "Zinc" proposal criticised the API as over-complex. The compromise: formally verified ChaCha20, Poly1305, Blake2s and Curve25519 went into simple direct-call libraries for WireGuard, and the main API kept its design. **5.5:** the old asynchronous cipher interface removed.
- **6.x:** a linear-buffer cipher type for simpler drivers, signature operations, and (2026, Amazon) work to make the crypto subsystem a separately certifiable loadable module for FIPS 140-3.

## Related

- Technical version: [[kernel-crypto-api]]
- [[fscrypt-explained|fscrypt]], [[dm-crypt-explained|dm-crypt]], [[dm-crypt-crypto-api-integration-explained|dm-crypt's use of the crypto API]], [[fscrypt-contents-encryption-explained|fscrypt contents encryption]]
- [[rpcsec-gss-and-kerberos-explained|RPCSEC_GSS and Kerberos]], [[dma-mapping-api-explained|DMA mapping]]
