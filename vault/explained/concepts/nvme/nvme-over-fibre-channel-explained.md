---
title: "NVMe over Fibre Channel (FC-NVMe) — Explained"
category: explained
original: "[[nvme-over-fibre-channel]]"
subsystem: nvme
tags: [explained, nvme, nvme-of, fibre-channel]
converted: 2026-09-26
---

# NVMe over Fibre Channel, explained

> Plain-language companion to [[nvme-over-fibre-channel|the technical note]]. Same facts, fewer identifiers.

## The problem

Many enterprises have spent decades building **Fibre Channel SANs**: dedicated storage networks that never drop frames, with zoning, name services, specialised adapters (HBAs) and teams who know how to run them. Traditionally these networks carried SCSI.

NVMe's big advantage over SCSI is **many independent queues, one per CPU**, and NVMe over fabrics brings that to networked storage. But the RDMA and TCP versions would mean building or repurposing an Ethernet network. **NVMe over Fibre Channel** lets these organisations get NVMe's queue model on the network they already have, with SCSI and NVMe traffic side by side on the same adapters and switches.

## The idea in one paragraph

Fibre Channel is a private freight railway that already carries SCSI cargo, and FC-NVMe adds **a new cargo type on the same tracks**. A host and a storage subsystem first sign a **contract** (an *association*, one per NVMe controller), then open **a siding per CPU** (one connection per NVMe queue). Each command is one **shipment**: the command goes out, data follows, and a receipt comes back. The adapter drives the train, so the host CPU never touches the cargo. In Linux the work is split between a **shipping company**, a generic NVMe-over-FC layer that plans shipments, and **locomotive contractors**, the HBA drivers, which only know how to run trains.

## Step by step

### Step 1: Signing the contract and opening sidings
Before any I/O, the host sends special **link-service** requests: "create association" (which also opens the admin queue) and then "create I/O connection" for each I/O queue. Each association corresponds to one NVMe controller. After that, the normal NVMe-over-fabrics connect and setup commands run inside each connection, exactly as they would over RDMA or TCP ([[nvme-over-fabrics-rdma-and-tcp-explained|NVMe over Fabrics]]).

### Step 2: One command, one exchange
Each NVMe command becomes one Fibre Channel **exchange**. The host sends a command message containing the 64-byte NVMe command.
- For a **read**, the target sends the data and then a response.
- For a **write**, the target first says "ready to receive" when it has buffers, and then the host sends the data. With **first burst** (if both sides agree), the host sends the first chunk of data without waiting, saving a round trip.

The HBA runs the whole exchange in hardware and firmware.

### Step 3: Tiny responses for the common case
A full NVMe completion is 16 bytes plus extra fields. For a successful command where nothing unusual happened, the target may send **a short all-zeros response** instead, and the host builds the success completion itself. The full response is still sent periodically, so the host can track queue progress, and always on errors. It is a small saving per I/O, but at millions of I/Os per second it adds up.

### Step 4: How Linux divides the work
This is the key step. Linux puts **all the NVMe-over-FC logic in one generic layer** (one for the host, one for the target) and asks HBA drivers only to register ports and run exchanges.
- When an adapter port comes up, the driver registers it with the NVMe layer. When the Fibre Channel name service reveals a remote port offering NVMe storage, the driver registers that too. Addresses are the ports' worldwide names.
- To send a command, the NVMe layer prepares the command message and the data's memory list, and hands them to the driver in one call. The driver reports back with how much data moved and the response.
- On the target side, one driver operation covers "fetch the write data", "send the read data" and "send the response", and the regular NVMe target core does the rest, with a block device, file or real NVMe drive behind it.

The payoff: NVMe behaves the same across vendors, and a **software loopback driver** can emulate a whole Fibre Channel fabric in memory for testing without hardware. The cost is a large, callback-heavy interface with subtle rules around aborts and teardown, which is where most bug fixes land.

### Step 5: Devices appear on their own
When a remote port offering NVMe discovery appears, the kernel raises an event, and a udev rule from the NVMe tools runs "connect to everything this port offers". A boot-time service replays ports found before userspace was ready. The result is the classic SAN experience: plug in the cable and the storage shows up.

### Step 6: When a path disappears
Two timers are involved. Fibre Channel keeps a vanished remote port in memory for a **device-loss timeout**. NVMe keeps trying to reconnect a controller for a **controller-loss timeout**. The NVMe layer honours the smaller of the two. If the port comes back in time (the fabric announces it), the connection is re-established automatically. Native NVMe multipath switches I/O between paths through different adapters or fabrics in the meantime. Badly set timers are a common cause of "paths never come back" or "I/O hangs too long".

### Step 7: Recovering from lost frames
Fibre Channel doesn't drop frames because of congestion, but bit errors and link events still lose them. In the first version of the standard, a lost frame could leave a command hanging until a timeout of tens of seconds, followed by a reset of the whole association. **FC-NVMe-2** (2020) added **sequence-level error recovery**: a new "flush" probe and a "responder detected an error" message let both sides spot a missing frame within about 2 seconds and resend only that piece, instead of waiting around 60 seconds and aborting. Linux's NVMe layers were updated for the new standard around 2019–2020, and the Broadcom driver implements the recovery.

### Step 8: The hardware drivers
- **Broadcom/Emulex (lpfc)** supports both host and target mode, and chooses per port whether to carry SCSI, NVMe or both.
- **Marvell/QLogic (qla2xxx)** supports host mode (its target mode is SCSI-only, through the LIO target, [[iscsi-iser-and-lio-target|LIO]]).
- Both run **SCSI and NVMe on the same port at once**, so a host can use old SCSI volumes and new NVMe namespaces from the same array.
- Enterprise distributions have fully supported NVMe over FC since around RHEL 7.6 and 8.0.

## The picture

```text
 host CPU                                                    storage target
 ┌──────────────┐   ┌───────────┐   FC fabric    ┌───────────┐   ┌──────────────┐
 │ blk-mq queue │──▶│ NVMe-FC   │   (lossless,   │ NVMe-FC   │──▶│ NVMe target  │
 │ per CPU      │   │ layer     │    zoned)      │ target    │   │ core → disk  │
 └──────────────┘   └─────┬─────┘                └─────▲─────┘   └──────────────┘
                          │ "run this exchange"        │
                    ┌─────▼─────┐                ┌─────┴─────┐
                    │ HBA driver│◀══ command ═══▶│ HBA driver│
                    │ + HBA     │◀══ data ══════▶│ + HBA     │
                    └───────────┘◀══ response ══▶└───────────┘
   setup once: create association → create I/O connection per queue
```

## Tradeoffs

- **What it gives you:** NVMe's per-CPU queues on an existing Fibre Channel SAN, with hardware data movement (no copies, no software checksums), a network that is lossless by design without tuning, and SCSI and NVMe side by side for gradual migration.
- **What it costs / requires:** a separate, specialised network and adapters. A complex driver interface. Adapter resources shared between the SCSI and NVMe personalities.
- **Where it bites:** timer settings and error recovery. Before FC-NVMe-2, a single lost frame could mean a long stall and a full reset. Even now, the interaction between the Fibre Channel and NVMe timeouts decides how quickly paths fail over and recover.

## How it got here

- **2016–2017:** Fibre Channel standard for NVMe completed; Linux's host layer, target layer and loopback driver merged (4.10).
- **4.11–4.14:** Broadcom host and target support, then QLogic host support; first enterprise tech preview.
- **2018–2019:** automatic connection through udev; NVMe multipath by default; full enterprise support for both vendors.
- **2019–2020:** updates for FC-NVMe-2, including target-initiated disconnect and sequence-level error recovery; the new standard published in August 2020.
- **2021–2026:** hardening of teardown and abort races, loopback fixes driven by automated tests, and in-band authentication shared with the other NVMe transports.

## Related

- Technical version: [[nvme-over-fibre-channel]]
- [[nvme-over-fabrics-rdma-and-tcp-explained|NVMe over Fabrics (RDMA and TCP)]], [[storage-fabrics-nvme-of-iser-iscsi-nvme-fc-nfs-rdma-explained|Storage fabrics compared]]
- [[blk-mq-explained|blk-mq]], [[iscsi-iser-and-lio-target|iSCSI, iSER and LIO]]
