---
title: "Verbs API and uverbs — Explained"
category: explained
original: "[[verbs-api-and-uverbs]]"
subsystem: rdma
tags: [explained, rdma, verbs, uverbs, ioctl]
converted: 2026-09-26
---

# Verbs and user-space access, explained

> Plain-language companion to [[verbs-api-and-uverbs|the technical note]]. Same facts, fewer identifiers.

## The problem

"Verbs" is the set of operations the InfiniBand specification defines: allocate a protection domain, register memory, create completion queues and queue pairs, change their state, post work, poll completions. Kernel users call them directly. But ordinary, unprivileged applications also want to own real card queues, which means handing hardware to a process safely: every object validated, tied to its process, charged to cgroups, and destroyed when the process dies or the card is unplugged, while still letting the data path skip the kernel entirely.

## The idea in one paragraph

User-space verbs access is a **setup wizard for a direct line**. Every call through it (create a completion queue, create a queue pair, register memory) is slow, checked and accounted. What it produces is a set of memory mappings (the queue rings and a doorbell page on the card) plus keys. Once setup is done, the application talks to the card through those mappings with ordinary loads and stores, and the wizard is out of the loop until something needs creating, changing or destroying. io_uring also gives user space shared rings, but there the kernel consumes the submission ring; here the *card* does.

## Step by step

### Step 1: Open the device and get a context
Each RDMA device has a device file (`/dev/infiniband/uverbsN`), designed to be safe for unprivileged processes. The user-space library opens it and loads the matching vendor library. The first command creates a **user context**, and the driver returns private details, such as which doorbell pages to use. User space then maps those pages. Drivers publish mappable regions with an opaque offset, so a process can map only what the driver explicitly offered, and every mapping can later be revoked.

### Step 2: Two interfaces, one dispatcher
The original interface (2005) passed commands through `write()`: a header with a command number and a fixed struct pointing at a response buffer. Using `write()` as a remote-procedure call turned out to be a security hole: `write()` carries no sense of "the caller meant this", so a setuid program tricked into writing attacker-chosen bytes to an inherited file would run privileged RDMA commands. The 2016 fix rejects writes when credentials differ from the opener's or come from kernel context (CVE-2016-4565), but it broke some fork patterns and left the interface rigid, with a new "extended" command for every new field.

The **ioctl interface** (Matan Barak, 2017, completed by Jason Gunthorpe around 4.20) uses one ioctl whose argument names an object, a method and a driver, followed by a list of typed attributes. The kernel looks the object and method up in a per-device tree built at registration from the core's methods *plus the driver's own*, so a driver can add objects, methods or even extra attributes to core methods. That's how mlx5's **DevX** exposes near-raw firmware commands without new core code. Legacy `write()` commands now go through the same tree, so libraries can run ioctl-only.

### Step 3: Validate everything before the handler runs
This is the key step. Each method **declares** its attributes: which are mandatory, which are inputs and outputs, which are object handles and with what locking, which are file descriptors. Before the handler runs, the kernel:
- copies small inputs and size-checks large ones
- turns handles into objects and locks them: shared for reading, exclusive for writing or destroying, or allocates a new object for creation
- resolves file-descriptor arguments (completion channels, event files, dma-buf files)
- rejects unknown **mandatory** attributes and ignores unknown **optional** ones, which is what makes forward and backward compatibility work

The handler receives an already-checked bundle. Afterwards, new objects are committed (made visible) on success or thrown away on failure, and locks dropped. Small bundles live on the stack so frequent control commands stay cheap.

### Step 4: Teardown in dependency order
Each object type declares its destroy function and an **order**: memory regions and queue pairs before completion queues, completion queues before protection domains. When the device file closes, the process exits, or the device is disassociated, everything is destroyed in that order, and those forced destroys must succeed, whereas an explicit user destroy may fail with "busy" if the object is still in use. New creations are blocked while teardown runs.

### Step 5: Events and sleeping
Two file-based objects deliver notifications: an **async event file** (queue-pair errors, port changes, device failure) and **completion channels**. To sleep instead of busy-polling, an application arms a completion queue (a doorbell write, no system call), then blocks on the channel file (read or epoll); the kernel's interrupt handler posts an event. That's the only place the kernel enters the per-I/O path, and only when asked.

### Step 6: What deliberately doesn't go through the kernel
On hardware devices, posting sends and receives and polling completions **never** enter the kernel: the vendor library writes entries into the mapped queue, issues a barrier and writes the doorbell. Kernel commands for these exist, but only software providers (rxe, siw) and some older drivers use them.

### Step 7: Kernel verbs
In-kernel users call the same operations directly, as thin wrappers over the device's operations plus core bookkeeping. Posting, polling, arming and address-handle operations must not sleep and work from any context; everything else may sleep.

## The picture

```text
 open /dev/infiniband/uverbs0 ─▶ create context ─▶ mmap doorbell page + queue rings
 ioctl {object=CQ, method=CREATE, attrs=[handle NEW, in…, out…]}
   ─▶ method tree (core + driver extras) ─▶ validate + lock ─▶ handler ─▶ commit
 data path (no kernel): write WQE into mapped ring → barrier → store to doorbell
                        read completion entries from mapped CQ
 close / exit / unplug ─▶ destroy in order: MR, QP → CQ → PD → context
```

## Tradeoffs

- **What it gives you:** the lowest possible latency (no system call, and no interrupt when polling) with real hardware queues owned by unprivileged processes; one place for validation instead of hundreds of handlers; an extensible interface with driver namespaces.
- **What it costs / requires:** the kernel can't account, schedule, trace or filter individual operations; security depends on the hardware enforcing protection domains and keys. The attribute parser is complex.
- **Where it bites:** driver-extensible interfaces let vendors ship features without a core abstraction, but critics fear "firmware passthrough", so dangerous DevX modes need capability files. Driver-private data blobs accumulated inconsistent size and extension handling, prompting written compatibility rules in 2026.

## How it got here

- **2.6.11 (2005):** the write-based interface arrives with the OpenIB stack.
- **4.6 (2016):** credential checks for the write-as-RPC hole.
- **4.14–4.16:** the ioctl infrastructure and first methods. **4.18–4.20:** DevX; all write commands routed through ioctl; ioctl-only libraries.
- **5.x:** revocable mapping entries (5.5); event and completion-channel files as proper objects.
- **6.x:** capability devices; completion counters as an alternative to completion entries; dma-buf export objects and unified buffer descriptors (2026); helpers for driver-private data (2026).

## Related

- Technical version: [[verbs-api-and-uverbs]]
- [[rdma-explained|RDMA subsystem]], [[queue-pairs-and-completion-queues-explained|Queue pairs and CQs]], [[memory-registration-and-ib-umem-explained|Memory registration]], [[ib-device-and-client-model-explained|Device and client model]], [[rdma-netlink-restrack-and-cgroup-explained|Netlink, restrack and cgroup]]
- [[io_uring-explained|io_uring]]
