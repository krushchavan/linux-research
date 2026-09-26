---
title: "iSCSI, iSER and the LIO Target — Explained"
category: explained
original: "[[iscsi-iser-and-lio-target]]"
subsystem: scsi
tags: [explained, scsi, iscsi, lio, iser]
converted: 2026-09-26
---

# iSCSI, iSER and the LIO target, explained

> Plain-language companion to [[iscsi-iser-and-lio-target|the technical note]]. Same facts, fewer identifiers.

## The problem

Before NVMe over fabrics, the standard way to share block storage over an ordinary IP network was **iSCSI**: take SCSI commands, the same command language local SAS and SATA disks speak, and carry them over TCP. It needed no special network, unlike Fibre Channel, and was cheap to deploy. It became the default storage network protocol for virtualisation clusters and small-to-mid storage arrays. **iSER** later let the same protocol use RDMA to move data.

Linux has both ends:
- the **initiator** (open-iscsi), which makes remote volumes appear as local SCSI disks
- the **target** (LIO), a general-purpose kernel engine that serves SCSI over many transports from one core.

Two design ideas are worth understanding: splitting a rarely used, complex control path from a fast data path, and LIO's separation of transports ("fabrics") from storage ("backstores").

## The idea in one paragraph

LIO is a **universal disk emulator with many front doors**. The core speaks SCSI: it answers reads, writes, capacity questions, reservations and path-preference queries. Each **front door** accepts SCSI commands from one kind of transport (iSCSI over TCP, iSER over RDMA, a Fibre Channel adapter, a virtual machine). Behind the core is a **backstore**: a block device, a file, a real SCSI device, RAM, or a user-space program. Any door can be wired to any backstore. The initiator, open-iscsi, is **a phone line with an operator**. A user-space daemon dials, logs in and redials after a disconnect, but once the call is up the conversation (the data) runs in the kernel with no operator involved.

## Step by step

### Step 1: What iSCSI puts on the wire
iSCSI wraps SCSI commands and data in messages over TCP. A **session** between host and target starts with a **login**: optional CHAP authentication, then negotiation of message sizes, burst sizes, checksums and error recovery. After that:
- a write command can carry **some data with it** (immediate data), up to a negotiated amount
- for more, the target sends **"ready to transfer"** messages asking for the rest in bursts
- reads come back as data messages followed by a status message
- periodic pings check that the link is alive.

Command sequence numbers give the target a **window** of commands it will accept, which is iSCSI's flow control. Optional CRC checksums strengthen TCP's weak checksum but cost CPU.

### Step 2: The initiator splits control and data
open-iscsi puts the **whole control path in user space**: a database of known targets, discovery, login negotiation and recovery policy. The kernel has only the **data path**:
- a transport layer that shows sessions in sysfs and talks to the daemon over netlink
- shared iSCSI session logic (command window, tracking, timeouts, aborts)
- the TCP transport itself, which sends messages on a kernel socket and copies received data into the command's buffers.

This is the key step. The daemon logs in over a socket it created itself, and **once negotiation succeeds, it hands that socket to the kernel**, which takes over the data path. Complex, rarely run negotiation code stays out of the kernel, while every I/O stays in it.

Transports are pluggable: software TCP, **iSER**, or adapters that offload iSCSI and TCP in hardware. Each session appears as a SCSI host, and each remote volume becomes an ordinary disk, so filesystems, LVM and multipath ([[device-mapper-explained|device mapper]]) work unchanged. The flip side is that the SCSI layer and one queue per session (not per CPU) are why iSCSI scales worse than NVMe over fabrics ([[blk-mq-explained|blk-mq]]).

### Step 3: When the connection breaks
A missed ping or a socket error fails the connection. The kernel pauses the session's disks and starts a **replacement timer** (120 seconds by default) while the daemon tries to log in again. If it succeeds, I/O resumes. If the timer runs out, pending I/O fails upward so multipath can switch paths. With multipath the timer is usually cut to 5–15 seconds for fast failover.

Linux chose **one connection per session plus the generic multipath layer**, rather than iSCSI's own multi-connection sessions. That kept the initiator simple.

### Step 4: iSER, the same protocol with RDMA moving the data
**iSER** keeps iSCSI's names, login and SCSI commands, but after login the connection switches to RDMA.
- Commands and responses travel as RDMA messages.
- The initiator registers its data buffer and tells the target where it is.
- The **target moves the data**: for a read it writes straight into the initiator's memory, and for a write it reads straight from it. There are no "ready to transfer" round trips, no data messages and no copies on either side.

Linux has the initiator side (chosen with the same tools as normal iSCSI) and the target side (plugged into LIO). Both use the shared RDMA connection manager ([[rdma-cm-connection-manager-explained|RDMA CM]]) and fast per-command memory registration ([[memory-registration-and-ib-umem-explained|memory registration]]). The card can generate and check end-to-end data-integrity tags. The target uses the kernel's common RDMA read/write helpers ([[rdma-rw-api-explained|RDMA read/write API]]). iSER brought RDMA-class latency to existing iSCSI setups, but it kept SCSI's per-session queues and has mostly been replaced by NVMe over RDMA for new flash storage.

### Step 5: How LIO was chosen
Linux's first in-kernel target (2006) did most of its work in user space and was slow. Two external projects competed to replace it: **SCST** (broad adapter support, stricter SCSI compliance) and **LIO**. In late 2010 the SCSI maintainer chose LIO, citing its configuration model, its developers' willingness to redesign on request, and features such as path-preference reporting and stronger error recovery. A review trimmed about 10,000 lines before merge. The target core landed in 2.6.38 and the iSCSI front door in 3.1.

### Step 6: Inside LIO, core, front doors and backstores
- The **core** implements SCSI target behaviour: answering and emulating commands (including space reclaim, compare-and-write and copy offload), **persistent reservations** (which clustered filesystems and failover clusters need), **path-state reporting** (so the host's multipath prefers optimal paths), task management, and access lists that decide which host sees which volumes.
- **Front doors** ("fabrics") turn a transport into SCSI commands: iSCSI, iSER, Fibre Channel adapters in target mode, FCoE, SRP over RDMA, **vhost** (serving a virtual SCSI adapter straight to KVM guests), a local loopback adapter, USB gadget and others.
- **Backstores** hold the data: any block device (the usual choice), a file, pass-through to a real SCSI device, a RAM disk, or a user-space program.

All configuration is **files in configfs**, with no daemon. The `targetcli` tool is a shell over that tree and saves and restores it.

### Step 7: A command's path through the iSCSI target
A receive thread per connection reads messages from the socket and turns a command into LIO's internal command, tied to the host's access list and volume. The core checks reservations and path state, then either emulates the command or passes it to the backstore (a block-device backstore builds block I/O, [[bio-layer-explained|bio layer]]). On completion, a transmit thread sends the data and status. For large writes, the target first sends "ready to transfer" requests and gathers the data before executing.

### Step 8: Backstores in user space (TCMU)
Some storage is only practical from user space: Ceph RBD, Gluster, qcow images, compression or encryption libraries. **TCMU** (3.18) adds a *user* backstore that forwards SCSI commands to a program through shared memory, reusing the kernel's existing user-space I/O device mechanism. The shared region holds a small header, a **lock-free command ring** and a **data area**. The kernel writes a command and signals. The program does the I/O, writes the status and signals back. Device setup events travel over netlink. The **tcmu-runner** daemon hides these details behind plug-ins, and the Ceph iSCSI gateway is built on it. The cost is a copy through the data area and a trip to user space per command. The gain is keeping all of LIO's front doors, access control, path reporting and reservations for user-space storage. It is the SCSI counterpart of [[ublk-explained|ublk]] for block devices.

## The picture

```text
 INITIATOR (open-iscsi)                          TARGET (LIO)
 ┌───────────── user ─────────────┐              ┌── front doors ──┐  ┌─ core ─┐  ┌─ backstores ─┐
 │ iscsid: discovery, login,      │              │ iSCSI (TCP)     │  │ SCSI   │  │ block device │
 │ recovery  ── hands socket ─┐   │              │ iSER (RDMA)     │─▶│ emul., │─▶│ file         │
 └────────────────────────────┼───┘              │ Fibre Channel   │  │ reserv-│  │ SCSI pass-thr│
 ┌───────────── kernel ───────▼───┐   TCP/RDMA   │ vhost (VMs)     │  │ ations,│  │ RAM          │
 │ SCSI disk ◀─ iSCSI session ◀───┼─────────────▶│ loopback …      │  │ ALUA   │  │ user (TCMU)──┼─▶ tcmu-runner
 │ /dev/sdX     (TCP or iSER)     │              └─────────────────┘  └────────┘  └──────────────┘   (Ceph, Gluster)
 └────────────────────────────────┘                     all configured through configfs (targetcli)
```

## Tradeoffs

- **What it gives you:** block storage over any IP network with mature tooling. RDMA data movement through iSER. One target engine that serves many transports, with the reservations and path reporting that clusters need. User-space storage through TCMU.
- **What it costs / requires:** SCSI's per-session queueing and a heavy core. Data copies on the TCP path. A dependency on the user-space daemon for recovery, which is why it starts early when the root disk is on iSCSI. Persistence of target configuration handled by tooling rather than the kernel.
- **Where it bites:** recovery timers and scaling. The default replacement timer is long for multipath setups, and against fast flash the protocol, not the disk, becomes the bottleneck. That is why new deployments move to NVMe over TCP or RDMA.

## How it got here

- **2005 (2.6.13):** open-iscsi merged with a TCP data path and a netlink control channel.
- **2006 (2.6.19):** iSER initiator; the slow user-space-heavy target merged.
- **2011 (2.6.38, 3.1):** LIO replaces it after the LIO-versus-SCST decision; iSCSI, Fibre Channel, SRP and vhost front doors follow.
- **2013–2014 (3.10–3.18):** iSER target; end-to-end integrity support; user-space backstores (TCMU).
- **5.x–6.x:** iSER moved to the shared RDMA helpers; the target's command submission reworked; iSCSI steadily overtaken by NVMe over TCP for new flash storage, while remaining the most widely deployed IP storage protocol.

## Related

- Technical version: [[iscsi-iser-and-lio-target]]
- [[storage-fabrics-nvme-of-iser-iscsi-nvme-fc-nfs-rdma-explained|Storage fabrics compared]], [[nvme-over-fabrics-rdma-and-tcp-explained|NVMe over Fabrics]], [[nvme-over-fibre-channel-explained|NVMe over Fibre Channel]]
- [[rdma-cm-connection-manager-explained|RDMA CM]], [[rdma-rw-api-explained|RDMA read/write API]], [[memory-registration-and-ib-umem-explained|Memory registration]]
- [[device-mapper-explained|Device mapper]], [[blk-mq-explained|blk-mq]], [[bio-layer-explained|Bio layer]], [[ublk-explained|ublk]], [[tcp-ip-stack-explained|TCP/IP stack]]
