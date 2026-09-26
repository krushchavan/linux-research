---
title: "Verbs API and uverbs"
category: concept
tags: [rdma, verbs, uverbs, uapi, ioctl, kernel-bypass]
subsystem: rdma
kernel_version: "2.6.11 (write ABI); 4.14–4.20 (ioctl ABI)"
researched: 2026-09-26
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/infiniband/user_verbs.html
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/uverbs_ioctl.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/uverbs_main.c
  - https://github.com/torvalds/linux/blob/master/drivers/infiniband/core/rdma_core.c
  - https://github.com/torvalds/linux/blob/master/include/uapi/rdma/rdma_user_ioctl_cmds.h
  - https://github.com/torvalds/linux/blob/master/include/rdma/uverbs_ioctl.h
  - https://lwn.net/Articles/733179/
  - https://lwn.net/Articles/1060674/
  - https://patchwork.kernel.org/project/linux-rdma/patch/20181203205827.GA25410@ziepe.ca/
  - https://github.com/linux-rdma/rdma-core
---

# Verbs API and uverbs

## Purpose

"Verbs" is the abstract operation set defined by the InfiniBand specification: allocate a protection domain, register memory, create a completion queue or queue pair, modify its state, post work, poll completions. Linux implements verbs twice. **Kernel verbs** (`ib_alloc_pd()`, `ib_create_qp()`, `ib_post_send()` ...) serve in-kernel ULPs. **uverbs** (`ib_uverbs`) exposes the control half of the same API to unprivileged userspace, and it is *designed* to hand the data half over to userspace entirely. uverbs exists so that a process can own real NIC hardware queues safely: every object is validated, tied to the process, charged to cgroups, and destroyed when the process dies or the device is unplugged.

## Mental Model

uverbs is a **setup wizard for a direct line**. Every call through it (create CQ, create QP, register MR) is slow, checked and accounted. Its output is a set of memory mappings (the queue rings and a doorbell page on the NIC's BAR) plus keys. Once the wizard finishes, the application talks to the NIC through those mappings with ordinary loads and stores, and the wizard is out of the loop until something needs to be created, changed or destroyed. Compare io_uring: both give userspace shared rings, but in io_uring the kernel consumes the SQ. In verbs, the *NIC* consumes it.

## How It Works

**Opening the device and creating a context.** udev creates `/dev/infiniband/uverbsN`, one per RDMA device (the kernel docs state the interface "should be safe for use by non-privileged processes"). libibverbs, from rdma-core, opens it and loads a **provider library** matched on `driver_id` (libmlx5, libbnxt_re, librxe ...). The first command, `GET_CONTEXT` / `UVERBS_METHOD_ALLOC_UCONTEXT`, allocates an `ib_ucontext`. The provider's `alloc_ucontext` returns driver-private data through `udata`, for example UAR (doorbell) page indexes and the BlueFlame register size. Userspace then `mmap()`s these pages. Drivers publish mmap-able regions with `rdma_user_mmap_entry_insert()`, which returns an opaque offset. The mmap handler looks up the entry, so userspace can only map what the driver explicitly offered, and every mapping can later be revoked.

**Two ABIs, one dispatcher.** The original ABI (2005) sent commands through `write()`: a `struct ib_uverbs_cmd_hdr` with a command number, followed by a fixed struct containing a 64-bit pointer to the response buffer. Using `write()` as an RPC turned out to be a security problem. `write()` carries no notion of "this caller really intended this", so a setuid program tricked into writing attacker-controlled bytes to an inherited fd would execute privileged RDMA commands. The fix, `ib_safe_file_access()`, rejects writes when the credentials differ from the opener's or when called from a kernel context. It broke some fork patterns and made the ABI rigid: every new field meant a new "extended" command.

The **ioctl ABI** (Matan Barak's 2017 series, completed by Jason Gunthorpe around 4.20) replaced this with one ioctl, `RDMA_VERBS_IOCTL`. Its argument is `struct ib_uverbs_ioctl_hdr`, containing `object_id`, `method_id`, `driver_id` and `num_attrs`, followed by an array of `struct ib_uverbs_attr` in *type-length-pointer* form. `ib_uverbs_ioctl()` checks the header, enters an SRCU read section on `disassociate_srcu` (so hot-unplug can wait for it), and calls `ib_uverbs_cmd_verbs()`. That function looks up `(object, method)` in a per-device **uapi radix tree**. The tree is assembled at device registration by merging the core's declared methods with the driver's own (`driver_def`), so a driver can add objects, methods or even extra attributes to core methods. That is how mlx5 **DevX** exposes near-raw firmware commands without new core code.

**Declarative validation.** Each method is declared with macros such as `DECLARE_UVERBS_NAMED_METHOD(UVERBS_METHOD_CQ_CREATE, UVERBS_ATTR_IDR(..., UVERBS_ACCESS_NEW, UA_MANDATORY), UVERBS_ATTR_PTR_IN(...), UVERBS_ATTR_PTR_OUT(...))`. Before the handler runs, `ib_uverbs_run_method()` → `uverbs_process_attr()` walks the user's attributes and does the following:
- copies small `PTR_IN` payloads inline, and checks the sizes of large ones
- resolves `IDR` attributes (object handles) to `ib_uobject`s and takes the declared lock. `UVERBS_ACCESS_READ` is shared: `usecnt` is incremented unless it is -1. `WRITE` and `DESTROY` are exclusive: `usecnt` goes from 0 to -1. `NEW` allocates a fresh uobject with `rdma_alloc_begin_uobject()`.
- resolves `FD` and `RAW_FD` attributes (completion channels, async event fds, dma-buf fds)
- rejects unknown mandatory attributes with `-EPROTONOSUPPORT`, and ignores unknown optional ones. That rule is what makes forward and backward compatibility possible.

The handler receives a fully validated `struct uverbs_attr_bundle` and calls typed accessors (`uverbs_attr_get_obj()`, `uverbs_copy_from()`, `uverbs_copy_to()`). After it returns, `bundle_destroy()` commits new uobjects on success (`rdma_alloc_commit_uobject()` makes them visible in the file's xarray) or aborts them on failure, and drops the locks. Small bundles are built on the stack to keep the hot control commands cheap.

Legacy write() commands now go through the same tree (`UVERBS_METHOD_INVOKE_WRITE` and `uapi_get_write`). rdma-core can therefore run in ioctl-only mode, which sidesteps the write() credential issues.

**Object lifetime and teardown order.** Each object type is declared with a destroy function and a **destroy order** (`UVERBS_TYPE_ALLOC_IDR(order, ...)`). MRs and QPs go before CQs, and CQs before PDs. On `close()` of the uverbs fd, process exit, or device disassociation, `uverbs_destroy_ufile_hw()` destroys every uobject in dependency order with the appropriate `enum rdma_remove_reason`. `RDMA_REMOVE_CLOSE` and `RDMA_REMOVE_DRIVER_REMOVE` *must* succeed, whereas an explicit user DESTROY is allowed to fail with `-EBUSY` if the object is still referenced. The per-file `hw_destroy_rwsem` blocks new object creation while teardown runs.

**Events and completion channels.** Two fd-based objects deliver asynchronous notifications. The **async event file** reports QP errors, port changes and `DEVICE_FATAL`. **Completion channels** (`ibv_create_comp_channel`) are how an application sleeps instead of busy-polling: it arms a CQ with `ibv_req_notify_cq()` (a doorbell write, no syscall), then blocks in `read()` or `epoll` on the channel fd, and the kernel's CQ interrupt handler posts an event. This is the only place the kernel sits in the per-I/O path, and only when the application asks for it.

**What uverbs deliberately does *not* do.** `ibv_post_send`, `ibv_post_recv` and `ibv_poll_cq` never enter the kernel on hardware providers. The provider library formats WQEs into the mmapped queue, issues a memory barrier and writes the doorbell. The `POST_SEND`/`POST_RECV`/`POLL_CQ` uverbs commands exist, but only software providers (rxe, siw) and some older drivers use them.

**Kernel verbs.** In-kernel consumers call the same operations directly: `ib_alloc_pd()`, `ib_create_qp()`/`ib_create_qp_kernel()`, `ib_alloc_cq()`, `ib_post_send()`. These are thin wrappers over `device->ops`, plus core bookkeeping (restrack, usecnt). The midlayer locking rules say that `post_send`, `post_recv`, `poll_cq`, `req_notify_cq` and the AH ops must not sleep and are callable from any context, while everything else may sleep.

## Key Data Structures

**`struct ib_uverbs_ioctl_hdr` / `struct ib_uverbs_attr`** (`include/uapi/rdma/rdma_user_ioctl_cmds.h`) — the wire format. The header has `object_id`, `method_id`, `driver_id` and `num_attrs`. Each attribute has `attr_id`, `len`, `flags` (`UVERBS_ATTR_F_MANDATORY`, `UVERBS_ATTR_F_VALID_OUTPUT`) and `data` (inline value, user pointer, or object/fd handle).

**`struct ib_uobject`** (`include/rdma/ib_verbs.h`) — a user-visible handle.
- `id` — index in the file's object xarray, which is the number userspace passes back
- `usecnt` — >0 shared readers, -1 exclusive owner
- `object` — the kernel `ib_qp`/`ib_cq`/`ib_mr`
- `uapi_object` — type descriptor (destroy fn, order)
- `cg_obj` — rdma cgroup charge

**`struct uverbs_attr_bundle`** (`include/rdma/uverbs_ioctl.h`) — the validated per-call argument set given to handlers; includes `ufile`, `context`, `driver_udata`, and the attrs array.

**`struct ib_uverbs_file`** (`uverbs.h`) — one open of `uverbsN`: `ucontext`, `uobjects` list, `hw_destroy_rwsem`, mmap entries, `disassociate_page`.

## Key Functions / Entry Points

- **`ib_uverbs_ioctl()`** → **`ib_uverbs_cmd_verbs()`** → **`ib_uverbs_run_method()`** (`uverbs_ioctl.c`) — ioctl dispatch and validation
- **`ib_uverbs_write()`** (`uverbs_main.c`) — legacy path, guarded by `ib_safe_file_access()`
- **`rdma_alloc_begin_uobject()` / `rdma_alloc_commit_uobject()` / `rdma_lookup_get_uobject()`** (`rdma_core.c`) — object creation and locking
- **`uverbs_destroy_ufile_hw()`** (`rdma_core.c`) — ordered teardown on close, exit or disassociate
- **`rdma_user_mmap_entry_insert()` / `rdma_user_mmap_io()`** (`ib_core_uverbs.c`) — safe, revocable mmap of doorbells and queues
- **`uverbs_uapi_*`** (`uverbs_uapi.c`) — building the per-device method radix tree from core and driver definitions

## Important Flags & Config Options

- `CONFIG_INFINIBAND_USER_ACCESS` — builds `ib_uverbs` (and ucma)
- rdma-core build flag `-DIOCTL_MODE=ioctl|write|both`
- `ib_device.uverbs_cmd_mask` — which legacy commands a driver supports
- `UVERBS_ATTR_F_MANDATORY` — forward-compat contract: unknown mandatory → fail, unknown optional → ignore
- `ucaps` (`/dev/infiniband/ucapN`, 6.x) — capability fds granting privileged uverbs features (e.g. mlx5 DevX local/remote) to unprivileged processes

## Interactions with Other Subsystems

- **↑ Userspace**: libibverbs + provider libs (rdma-core); higher layers UCX, libfabric (verbs provider), NCCL, MPI, SPDK NVMe-oF, DPDK mlx5 PMD (which uses verbs/DevX for setup)
- **→ mm**: MR registration (see [[memory-registration-and-ib-umem]]), mmap of device BARs (`rdma_user_mmap_io` → `io_remap_pfn_range`)
- **→ cgroups**: every uobject charges the rdma controller (`hca_object`); every ucontext charges `hca_handle`
- **→ dma-buf**: FD attributes carry dma-buf fds for MR registration, and (2026) the DMABUF export object
- **← Device core**: disassociation on removal (see [[ib-device-and-client-model]])

## Design Decisions & Tradeoffs

- **Control through the kernel, data around it.** This is the fundamental kernel-bypass bargain. It gives the lowest possible latency (no syscall, no interrupt when polling). The price is that the kernel can't account, schedule, trace or filter per operation, and security depends on hardware enforcing PD/lkey/rkey checks.
- **ioctl + TLV attributes over fixed structs.** This fixed the write() credential problem and made the ABI extensible (optional attributes, driver namespaces). It costs a more complex parser, which is offset by moving validation out of hundreds of handlers into one place.
- **Driver-extensible uapi (DevX).** Vendors can expose features without waiting for a core abstraction. Critics worry this lets the ABI become "firmware passthrough", which is why DevX needs capabilities (`ucaps`) for dangerous modes.
- **udata as an escape hatch.** Most core commands carry opaque driver-specific in/out buffers. 2026 work added udata helpers and written uABI compatibility rules, because driver-private structs had accumulated inconsistent zero-extension and size handling.

## How It Has Evolved

- **2.6.11 (2005)** — write()-based uverbs merged with the OpenIB stack
- **4.6 (2016)** — `ib_safe_file_access()` added after the write()-as-ioctl credential issue (CVE-2016-4565)
- **4.14–4.16** — ioctl infrastructure (objects, methods, attributes), first methods (CQ create, flow actions, DM)
- **4.18–4.20** — DevX; `UVERBS_METHOD_INVOKE_WRITE` tunnels all write() commands through ioctl; rdma-core gains ioctl-only mode
- **5.x** — `rdma_user_mmap_entry` API (5.5) for revocable mmaps; async event and completion channel fds as proper uobjects
- **6.x** — `ucaps` capability devices; completion counters (`comp_cntrs`) as an alternative to CQEs; dma-buf export object type (2026); unified `ib_uverbs_buffer_desc` for passing VA-or-dma-buf buffers to any umem-taking method (2026); udata helpers (2026)

## Further Reading

- kernel.org — [Userspace verbs access](https://www.kernel.org/doc/html/latest/infiniband/user_verbs.html)
- LWN — [IB/core: SG IOCTL based RDMA ABI](https://lwn.net/Articles/733179/)
- LWN — [Provide udata helpers and use them in bnxt_re](https://lwn.net/Articles/1060674/) (2026)
- patchwork — [rdma-core: Allow all commands to be invoked by ioctl](https://patchwork.kernel.org/project/linux-rdma/patch/20181203205827.GA25410@ziepe.ca/)
- rdma-core — `libibverbs/man/` and `Documentation/` in https://github.com/linux-rdma/rdma-core
- Related: [[rdma]], [[queue-pairs-and-completion-queues]], [[io_uring]]

## LKML Highlights

- **`<1501765627-104860-1-git-send-email-matanb@mellanox.com>`** — "IB/core: SG IOCTL based RDMA ABI". Introduced the object/method/attribute hierarchy with type-length-pointer attributes, per-context IDR, and core-managed uobject locking, so that "drivers declare supported objects, their deallocation functions, and release ordering".
- **`<20181203205827.GA25410@ziepe.ca>`** (rdma-core) — Jason Gunthorpe: allow every verb to be invoked through ioctl (`INVOKE_WRITE`), with `IOCTL_MODE=ioctl` removing the write() path entirely. This works around the fork and credential limits created by the write() security fixes.
- **udata helpers (2026, LWN 1060674)** — documented uABI compatibility rules for driver-private udata and converted bnxt_re as the first user.
