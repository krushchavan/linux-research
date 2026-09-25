---
title: "ublk Zero-Copy"
category: concept
tags: [ublk, zero-copy, io_uring, registered-buffers, shared-memory]
subsystem: ublk
kernel_version: "6.15"
researched: 2026-09-24
status: complete
explained: "[[ublk-zero-copy-explained]]"
sources:
  - https://www.kernel.org/doc/html/latest/block/ublk.html
  - https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/ublk_cmd.h
  - https://raw.githubusercontent.com/torvalds/linux/master/drivers/block/ublk_drv.c
  - https://lwn.net/Articles/926118/
  - https://lwn.net/Articles/923383/
  - https://lwn.net/Articles/1007721/
  - https://ratatoskr.run/linux-block/2026/03/6435925/t
  - https://kernelnewbies.org/Linux_6.16
  - https://kernelnewbies.org/Linux_6.17
---

# ublk Zero-Copy

> 📘 Plain-language version: [[ublk-zero-copy-explained]]

## Purpose

In ublk's default mode every byte crosses the user/kernel boundary twice. WRITE data is copied from the client's request pages into the server's buffer, and then the server writes it again to its backend. READs do the reverse. For large I/O this copy is the main thing that makes ublk slower than an in-kernel driver. Zero-copy lets the server's backend I/O operate *directly on the client request's pages*, or lets client and server share the pages outright.

## Mental Model

In copy mode the server gets a photocopy of the parcel. Registered-buffer zero-copy gives the server **a claim ticket for the original parcel**, which it can hand to the courier (a fixed-buffer io_uring op) without ever opening it. Shared-memory zero-copy is different again: client and server agreed beforehand to **use the same warehouse shelf**, so the kernel only has to say which shelf position.

## How It Works

**Starting point: copy mode.** `ublk_map_io()`/`ublk_unmap_io()` walk the request's bio_vecs with `rq_for_each_segment()`. `ublk_copy_user_bvec()` maps each page with `kmap_local_page()` and copies to or from the server address in the descriptor. It is simple and safe, and costs one memcpy per byte.

**Step 1: user copy (`UBLK_F_USER_COPY`, ~6.5).** The server doesn't give a buffer address. It calls `pread()`/`pwrite()` on `/dev/ublkcN` at an offset past `UBLKSRV_IO_BUF_OFFSET` that encodes `(q_id, tag, byte offset)`. `ublk_ch_read_iter()`/`write_iter()` look up the request and copy only the requested range. This is still a copy, but the server decides when, how much and into what, which helps servers that transform data (compression, encryption) or split one request into several backend operations. It was the interim answer while real zero-copy was debated, and it is also the path used for integrity metadata (7.0).

**The design detour (2023–2025).** Three designs competed:
- Xiaoguang Wang (Alibaba) proposed a `BPF_PROG_TYPE_UBLK` program that would issue backend I/O from kernel context.
- Ming Lei built "fused" io_uring commands: a primary uring_cmd leased the request buffer to a linked secondary SQE. They were merged for 6.4, then reverted after io_uring maintainers judged them too intrusive.
- Pavel Begunkov sketched a splice-into-registered-buffer approach, but it was never completed.

Keith Busch's 2025 series resolved it by making kernel-owned pages look like ordinary [[registered-resources|registered buffers]].

**Step 2: registered-buffer zero-copy (`UBLK_F_SUPPORT_ZERO_COPY`, 6.15).** When the server gets a request, it picks a free index in a *sparse* registered-buffer table of some io_uring (not necessarily the ring that carries ublk commands) and sends `UBLK_U_IO_REGISTER_IO_BUF {q_id, tag, addr=index}`. `ublk_register_io_buf()` looks up and references the request (`__ublk_check_and_get_req()`) and calls `io_buffer_register_request()`. That wraps the request's bvec in an `io_mapped_ubuf` of the new kernel-buffer type and installs it at the index, with `ublk_io_release()` as the release callback. The server can now use that index in any number of fixed-buffer ops, for example `IORING_OP_WRITE_FIXED` to the backing file or `SEND_ZC` with a fixed buffer to a socket. Data moves from the client's pages straight to the backend. When done, `UBLK_U_IO_UNREGISTER_IO_BUF` removes it. The request cannot complete until every registration is gone, which the reference count (`io->ref`) enforces. Since the server could otherwise expose uninitialised client memory, or read pages it shouldn't, this mode requires `CAP_SYS_ADMIN`, and the server must report accurate result lengths.

**Step 3: automatic registration (`UBLK_F_AUTO_BUF_REG`, 6.16).** Registration and unregistration cost two extra uring_cmds per I/O and create an ordering dependency. With auto-reg, the server puts a `struct ublk_auto_buf_reg {index, flags}` in the FETCH/COMMIT SQE's `addr`. During dispatch `ublk_auto_buf_register()` registers the request buffer at that index on the *same* ring before the CQE is posted, and commit unregisters it. If registration fails (index busy, table full: max 16K entries) and `UBLK_AUTO_BUF_REG_FALLBACK` is set, the command completes with `UBLK_IO_F_NEED_REG_BUF` so the server can fall back. Otherwise the I/O fails. `ublk_auto_buf_io_setup()` accounts the registration as `task_registered_buffers = 1`, a cheap per-task counter, instead of atomic refcount traffic.

**Step 4: registration off the daemon (`UBLK_F_BUF_REG_OFF_DAEMON`, 6.17).** Registration was originally restricted to the slot's daemon task. This flag lets any task register or unregister, using the atomic `io->ref`. At completion `ublk_sub_req_ref()` folds the per-task counter into the atomic one, so either path drains correctly.

**Step 5: shared-memory zero-copy (`UBLK_F_SHMEM_ZC`, 2026).** Some deployments control both ends, for example a database that talks to a ublk device served by a sidecar. Both `mmap(MAP_SHARED)` the same memfd or hugetlbfs file. The server sends `UBLK_U_CMD_REG_BUF` with a `struct ublk_shmem_buf_reg {addr, size, flags}`. The kernel pins those pages ([[get-user-pages-and-pinning]]) and inserts their PFN ranges into a [[maple-tree]] (`ub->buf_tree`). When a client `O_DIRECT` request arrives, `ublk_setup_iod()` calls `ublk_try_buf_match()`. If every page of the request lies contiguously inside one registered buffer, it sets `UBLK_IO_F_SHMEM_ZC` and encodes `(buffer index, offset)` in `iod->addr`, and the server reads the data through its own mapping with no copy and no per-I/O registration. Anything that doesn't match silently falls back to copy mode. `UBLK_SHMEM_BUF_READ_ONLY` covers read-only sharing. The limits are that it requires client cooperation, `O_DIRECT`, and contiguity within one buffer.

## Key Data Structures

**`struct ublk_auto_buf_reg`** (uapi) — `index` (buffer-table slot), `flags` (`UBLK_AUTO_BUF_REG_FALLBACK`), reserved fields that must be zero; encoded into `sqe->addr` with `ublk_auto_buf_reg_to_sqe_addr()`.

**`struct ublk_io`** zero-copy fields (`drivers/block/ublk_drv.c`)
- `ref` — atomic references from off-task registrations
- `task_registered_buffers` — on-task registrations (non-atomic fast path)
- `flags & UBLK_IO_FLAG_AUTO_BUF_REG` — auto-registered buffer present

**`struct ublk_shmem_buf_reg`** (uapi) — `addr`, `size`, `flags` for `REG_BUF`.

## Key Functions / Entry Points

**`ublk_copy_user_pages()`** — default copy path.
**`ublk_ch_read_iter()` / `ublk_ch_write_iter()`** — user-copy mode.
**`ublk_register_io_buf()` / `ublk_daemon_register_io_buf()`** — explicit registration.
**`ublk_auto_buf_register()`, `ublk_auto_buf_io_setup()`** — automatic registration.
**`ublk_io_release()`** — callback when io_uring drops the last reference to a registered request buffer.
**`io_buffer_register_bvec()` / `io_buffer_unregister_bvec()`** (`io_uring/rsrc.c`) — io_uring kernel-buffer API.
**`ublk_try_buf_match()`** — PFN lookup for shared-memory zero-copy.

## Important Flags & Config Options

- `UBLK_F_USER_COPY` — pread/pwrite data path.
- `UBLK_F_SUPPORT_ZERO_COPY` — explicit register/unregister (needs `CAP_SYS_ADMIN`).
- `UBLK_F_AUTO_BUF_REG` (+ `UBLK_AUTO_BUF_REG_FALLBACK`) — kernel-managed registration.
- `UBLK_F_BUF_REG_OFF_DAEMON` — register from any task.
- `UBLK_F_SHMEM_ZC` (+ `UBLK_SHMEM_BUF_READ_ONLY`) — shared-memory PFN matching.

## Interactions with Other Subsystems

- **↑ Userspace**: server must manage a sparse buffer table (`io_uring_register_buffers_sparse()`) and issue fixed-buffer ops. For shmem-ZC, client and server share a memfd/hugetlbfs mapping ([[huge-pages-hugetlbfs]]).
- **→ [[registered-resources]]**: kernel bvec nodes in io_uring's buffer table.
- **→ [[uring-cmd-passthrough]]**: registration commands and fixed-buffer uring_cmds.
- **→ [[get-user-pages-and-pinning]]**: `REG_BUF` pins shared pages long term.
- **→ [[io-uring-zero-copy-networking]]**: registered request buffers can feed `SEND_ZC` for network-backed devices.

## Design Decisions & Tradeoffs

- **Make kernel buffers look like user buffers.** The winning design needed no new io_uring opcode semantics, so every fixed-buffer op (file, socket, passthrough) worked immediately. Fused commands would have required per-op support.
- **Explicit versus automatic registration.** Explicit gives full control and supports several rings. Auto-reg saves two commands per I/O but ties the buffer to the command ring and a server-chosen index, with a fallback for when the index is busy.
- **Safety versus speed.** Direct access to client pages means a buggy server can leak stale memory in READ replies. The kernel requires `CAP_SYS_ADMIN` for registration zero-copy and puts the responsibility for accurate result sizes on the server.
- **Shared memory as a separate opt-in path.** PFN matching avoids all per-I/O setup but only helps cooperating clients. It is transparent (non-matching I/O still works), so it can be enabled without breaking anyone.

## How It Has Evolved

- **6.0** — `UBLK_F_SUPPORT_ZERO_COPY` bit reserved, not implemented.
- **2023** — BPF, fused-command and splice proposals. Fused commands were merged for 6.4, then reverted.
- **~6.5** — `UBLK_F_USER_COPY`.
- **6.15** — kernel bvec registration in io_uring, `REGISTER_IO_BUF`/`UNREGISTER_IO_BUF` (Keith Busch).
- **6.16** — `UBLK_F_AUTO_BUF_REG`.
- **6.17** — `UBLK_F_BUF_REG_OFF_DAEMON`.
- **2026** — `UBLK_F_SHMEM_ZC` (Ming Lei; uAPI debated with Caleb Sander Mateos).

## Further Reading

1. [Zero-copy I/O for ublk, three different ways — LWN (2023)](https://lwn.net/Articles/926118/)
2. [ublk zero-copy support — LWN patch posting (2025)](https://lwn.net/Articles/1007721/)
3. [Add io_uring & ebpf based methods to implement zero-copy for ublk — LWN](https://lwn.net/Articles/923383/)
4. [ublk driver documentation — Zero copy section, kernel.org](https://www.kernel.org/doc/html/latest/block/ublk.html)
5. [PATCH v2 00/10: ublk: add shared memory zero-copy — archive](https://ratatoskr.run/linux-block/2026/03/6435925/t)

## LKML Highlights

- **"io_uring/ublk: add IORING_OP_FUSED_CMD" (Ming Lei, 2023)** — fused primary/secondary commands leasing a request buffer. Begunkov called it "complicated and intrusive", and it was eventually reverted.
- **"ublk zero-copy support" (Keith Busch, Feb 2025)** — a KBUF resource node in io_uring. Feedback asked that kernel-registered resources "behave more similar to user registered buffers", and that shaped the final API.
- **"ublk: add shared memory zero-copy support" (Ming Lei, Mar 2026)** — PFN matching via maple tree. Review focused on whether `iod->addr` should carry index+offset or a virtual address.
