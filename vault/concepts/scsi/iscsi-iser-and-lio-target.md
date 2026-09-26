---
title: "iSCSI, iSER and the LIO Target"
category: concept
tags: [scsi, iscsi, iser, lio, storage, rdma]
subsystem: scsi
kernel_version: "open-iscsi 2.6.13; iSER initiator 2.6.19; LIO target core 2.6.38; iSCSI target 3.1; isert 3.10; TCMU 3.18"
researched: 2026-09-26
status: complete
sources:
  - https://github.com/open-iscsi/open-iscsi/blob/master/README
  - https://docs.kernel.org/target/tcmu-design.html
  - https://docs.kernel.org/driver-api/target.html
  - https://lwn.net/Articles/424004/
  - https://lwn.net/Articles/420691/
  - https://lwn.net/Articles/434603/
  - https://en.wikipedia.org/wiki/LIO_(SCSI_target)
  - https://github.com/open-iscsi/tcmu-runner
  - https://events.static.linuxfound.org/sites/events/files/slides/tcmu-bobw_0.pdf
  - https://docs.nvidia.com/networking/display/mlnxofedv551032/iscsi+extensions+for+rdma+(iser)
  - https://www.iol.unh.edu/knowledge/implementation-and-comparison-iscsi-over-rdma
---

# iSCSI, iSER and the LIO Target

> Part of the storage-fabrics comparison: [[storage-fabrics-nvme-of-iser-iscsi-nvme-fc-nfs-rdma]]. NVMe-era counterpart: [[nvme-over-fabrics-rdma-and-tcp]].

## Purpose

Before NVMe over fabrics, the standard way to share block storage over an IP network was **iSCSI**: carry SCSI commands, the same command set used by local SAS/SATA disks, over TCP. It needed no special network (unlike Fibre Channel) and was cheap to deploy, so it became the default SAN protocol for virtualisation clusters and small-to-mid storage arrays. **iSER** later let the same protocol use RDMA for data movement. Linux has both sides: the **initiator** (open-iscsi, with `iscsi_tcp` or `ib_iser`), which makes remote LUNs appear as local SCSI disks, and the **target** (LIO), a general-purpose in-kernel SCSI target engine that serves iSCSI, iSER, Fibre Channel, SRP, vhost and loopback from one core. The split between a fast kernel data path and a userspace control plane, and LIO's fabric/backstore separation, are the design ideas worth understanding.

## Mental Model

LIO is a **universal disk emulator with many front doors**. The *core* speaks SCSI (it knows how to answer READ, WRITE, INQUIRY, reservations and ALUA queries). Each *fabric module* is a door that accepts SCSI commands from one kind of transport (iSCSI over TCP, iSER over RDMA, a Fibre Channel HBA, a virtual machine through vhost). Each *backstore* is what's behind the core: a block device, a file, a raw SCSI device, RAM, or a userspace program. Any door can be wired to any backstore through configfs.

open-iscsi, the initiator, is a **phone line with an operator**. The operator (`iscsid` in userspace) dials, logs in, redials after a disconnect and handles discovery. Once the call is up, the conversation (the data path) runs in the kernel with no operator involvement.

## How It Works

### 1. The iSCSI protocol in brief

iSCSI (RFC 3720, consolidated as RFC 7143) encapsulates SCSI **CDBs** and data in **PDUs** over TCP, port 3260. Names are IQNs (e.g. `iqn.2003-01.org.linux-iscsi.host:target1`). A **session** between an initiator and a target portal group is built from one or more TCP **connections**, although the Linux initiator uses one connection per session and relies on dm-multipath across sessions instead of multiple connections per session (MC/S). Session setup is a **login** phase (security negotiation with optional CHAP, then operational parameter negotiation: `MaxRecvDataSegmentLength`, `FirstBurstLength`, `MaxBurstLength`, `ImmediateData`, `InitialR2T`, digests, error recovery level). The full-feature phase then carries:
- **SCSI Command** PDUs, optionally with **immediate data** (write data in the same PDU) or **unsolicited Data-Out** up to `FirstBurstLength`
- **R2T** (Ready To Transfer) from the target, soliciting further write data in bursts of up to `MaxBurstLength`
- **Data-In** PDUs for reads (optionally with status piggybacked), and **SCSI Response** PDUs
- **NOP-Out/NOP-In** pings for liveness, **Task Management** (abort, LUN reset), Text (SendTargets discovery), Logout.

Command sequence numbers (CmdSN/MaxCmdSN) give the target a **command window**, iSCSI's flow control across the session. Header and data **digests** (CRC32c) are optional, because TCP's checksum is weak but digests cost CPU. Error recovery levels 0–2 range from "drop the session" to connection-level recovery.

### 2. The initiator: open-iscsi

open-iscsi splits the work across the user/kernel boundary:
- **Userspace (`iscsid`, `iscsiadm`)**: the whole control plane. That covers the persistent **node database** (`/var/lib/iscsi`), **discovery** (SendTargets, iSNS), login and logout negotiation, connection-level error handling, and NOP handling policy. `iscsiadm -m discovery -t st -p <ip>` finds targets, and `iscsiadm -m node --login` logs in.
- **Kernel**: the data path, in three modules. **`scsi_transport_iscsi`** is the transport class, which exposes sessions and connections in sysfs and talks to `iscsid` over a **netlink** channel (create session, bind connection, set parameters, start/stop, connection error events). **`libiscsi`** is the generic iSCSI session logic: CmdSN window, task tracking, R2T handling, timeouts and aborts, shared by all transports. **`iscsi_tcp`** / **`libiscsi_tcp`** is the software TCP transport: it sends PDUs on a kernel socket and receives them in the socket's data-ready path, copying data into the SCSI command's scatterlist.

Login happens *in userspace* over a socket that `iscsid` creates. Once negotiated, the socket fd is **handed to the kernel** (bind connection), which takes over the data path. That keeps the complex, rarely executed negotiation code out of the kernel while the hot path stays in it.

**Transports are pluggable** through `struct iscsi_transport`. An **iface** record selects one by `iface.transport_name`: `tcp` (software), **`iser`** (RDMA), and offload HBAs (`cxgb4i` Chelsio, `bnx2i` Broadcom, `qla4xxx` QLogic, `be2iscsi` Emulex) that run parts of iSCSI and TCP in hardware.

The session appears to the SCSI midlayer as a **SCSI host**. Each target LUN becomes a `scsi_device` and a `/dev/sdX` block device through `sd`, so everything above (filesystems, [[device-mapper]] multipath, LVM) works unchanged. The SCSI midlayer and its single queue per session, rather than per CPU, are also why iSCSI scales worse than NVMe-oF ([[blk-mq]]).

**Failure handling**: a NOP-Out timeout or socket error fails the connection. The kernel blocks the session's SCSI devices and starts **`replacement_timeout`** (default 120 s), while `iscsid` tries to re-login. If it succeeds, I/O resumes. If the timer expires, outstanding and new I/O is failed upward so dm-multipath can switch paths. For multipath setups, `replacement_timeout` is typically lowered (e.g. 5–15 s) so path failover is fast.

### 3. iSER: iSCSI with RDMA data movement

**iSER** (RFC 5046, updated by RFC 7145) keeps iSCSI's naming, login, session model and SCSI semantics, but after login switches the connection to an **RDMA datamover**:
- iSCSI control PDUs (command, response, NOP, TMF) travel as **RDMA SENDs** into pre-posted receive buffers.
- The initiator **registers** its data buffer and advertises `{STag/rkey, VA}` in the iSER header (read STag for reads, write STag for writes).
- The **target moves the data**: for a SCSI READ it **RDMA WRITEs** into the initiator's buffer before sending the response, and for a SCSI WRITE it **RDMA READs** from the initiator's buffer. There are **no R2T PDUs and no Data-In/Data-Out PDUs**, and no copies on either side.

Linux's initiator **`ib_iser`** (`drivers/infiniband/ulp/iser/`, 2.6.19) registers as an `iscsi_transport`, so the same `iscsiadm` workflow applies (`iface.transport_name=iser`). Connection setup uses **rdma_cm** ([[rdma-cm-connection-manager]]). Data buffers are registered per command with **fast registration MRs** from a per-connection pool, or skip registration when a single contiguous buffer can use the global DMA lkey. **T10-PI** protection information is offloaded with signature (integrity) MRs, so the HCA generates and verifies guard tags ([[memory-registration-and-ib-umem]]). The target side is **`ib_isert`** (`drivers/infiniband/ulp/isert/`, 3.10), an LIO fabric that reuses the iSCSI target's login code and uses the core **`rdma_rw`** API to build RDMA READ/WRITE chains ([[rdma-rw-api]]). iSER runs on InfiniBand, RoCE or iWARP.

iSER brought RDMA-class latency and near-zero CPU data movement to existing iSCSI deployments. It keeps SCSI's per-session queueing, though, and it has largely been displaced by NVMe/RDMA for new flash storage.

### 4. The LIO target: core, fabrics, backstores

**History.** Linux's first in-tree target, **STGT** (2006), did most SCSI processing in userspace and was slow. Two out-of-tree kernel targets competed to replace it: **SCST** (pushing for inclusion since 2008, broad HBA support) and **LIO** (Nicholas Bellinger, Rising Tide Systems). In late 2010 SCSI maintainer James Bottomley chose LIO, citing its configfs-based configuration, willingness to redesign on request and advanced features (ALUA, error recovery level 2, MC/S). Christoph Hellwig's review cut about 10,000 lines before merge. The **target core** landed in **2.6.38**, the iSCSI fabric in **3.1**, and others followed ([LWN](https://lwn.net/Articles/424004/)).

**Architecture (`drivers/target/`).**
- **Target core** (`target_core_mod`) implements SCSI target semantics: command parsing and emulation (INQUIRY, READ CAPACITY, MODE SENSE, VPD pages, UNMAP, WRITE SAME, COMPARE AND WRITE, EXTENDED COPY), **persistent reservations** (SPC-3/4 PR, needed by clustered filesystems and Windows failover clusters), **ALUA** (asymmetric logical unit access: target port groups with active/optimized, non-optimized, standby states so initiators' multipath chooses the best path), task management, and LUN masking through ACLs (node ACLs mapping initiator names to LUNs).
- **Fabric modules** implement `struct target_core_fabric_ops` and translate a transport into `struct se_cmd`s. Examples: `iscsi_target_mod` (iSCSI/TCP), `ib_isert` (iSER), `tcm_qla2xxx` (Fibre Channel via QLogic HBAs in target mode), `tcm_fc` (FCoE), `ib_srpt` (SRP over RDMA), `vhost-scsi` (serves a virtual SCSI HBA straight to KVM guests), `tcm_loop` (a local SCSI HBA, for testing or exposing backstores as local SCSI devices), `tcm_usb_gadget`, `efct`. A fabric calls `target_init_cmd()` / `target_submit_prep()` / `target_submit()` (older: `target_submit_cmd()`), and the core calls back `write_pending` (fetch write data: send R2T, or post RDMA READ), `queue_data_in` (send read data) and `queue_status`.
- **Backstores** implement `struct target_backend_ops`: **iblock** (any Linux block device via bios, the common choice), **fileio** (a file, buffered or O_DIRECT), **pscsi** (pass SCSI commands through to a real SCSI device), **rd_mcp** (RAM disk), and **user / TCMU** (below).

**Configuration is entirely through configfs** (`/sys/kernel/config/target/`): backstores under `core/`, and per fabric a tree of targets (`iqn…`), target portal groups (`tpgt_1`), `lun/`, `acls/`, `np/` (network portals) and attribute files. The userspace tool **targetcli** (and the `rtslib` library) is a shell over this tree and saves and restores it as JSON. There is no daemon; the kernel holds all state.

**Command flow (iSCSI target).** A per-connection RX thread reads PDUs from the socket and turns a SCSI Command PDU into an `se_cmd` bound to the session's `se_node_acl` and LUN. The core checks reservations and ALUA state, emulates the command or dispatches it to the backstore (iblock builds and submits bios, [[bio-layer]]), and on completion calls the fabric's `queue_data_in`/`queue_status`. The TX thread then sends Data-In and Response PDUs. For writes beyond immediate/unsolicited data, `write_pending` sends R2Ts and the RX thread gathers Data-Out into the command's scatterlist before execution.

### 5. TCMU: backstores in userspace

Some backends can only be written sensibly in userspace: **Ceph RBD**, **Gluster (GLFS)**, qcow images, compression or encryption libraries. **TCMU** (`target_core_user`, 3.18, Andy Grover and others) adds a *user* backstore that forwards SCSI commands to a userspace process. It reuses the **UIO** subsystem: each TCMU device is a UIO device whose mmap-able region contains:
- a **mailbox** (version, command ring head/tail),
- a lock-free **command ring** of entries (`TCMU_OP_CMD` with the CDB and iovecs pointing into the data area, and `TCMU_OP_PAD` for wrap-around),
- a **data area** holding command payloads.

The kernel writes a command entry and signals the UIO fd. Userspace reads the CDB, performs the I/O against its backend, writes the status (and any sense data) into the entry, advances the tail, and writes the UIO fd to wake the kernel. Device add/remove and reconfiguration events go over a generic **netlink** family. **tcmu-runner** hides UIO, netlink and threading behind a C plugin API (`user:rbd`, `user:glfs`, `user:qcow`), and the Ceph iSCSI gateway (`ceph-iscsi`) is built on it. TCMU makes the "data copied between kernel and user" cost explicit, but keeps LIO's fabrics, ACLs, ALUA and reservations for userspace backends. It is the SCSI analogue of [[ublk]] for block devices.

## Key Data Structures

**`struct iscsi_cls_session` / `struct iscsi_session`** (`include/scsi/scsi_transport_iscsi.h`, `include/scsi/libiscsi.h`) — initiator session: `cmdsn`, `max_cmdsn`, recovery timer (`recovery_tmo` = replacement_timeout), connection list, task pool.

**`struct iscsi_transport`** — pluggable initiator transport ops: `create_session`, `bind_conn`, `xmit_task`, `set_param`, `ep_connect` (for iSER/offload endpoints).

**`struct iser_conn` / `struct iser_fr_pool`** (`drivers/infiniband/ulp/iser/iscsi_iser.h`) — iSER connection with its RDMA QP and pool of fast-registration descriptors (with optional signature MR).

**`struct se_cmd`** (`include/target/target_core_base.h`) — a SCSI command inside LIO: CDB, `t_data_sg` scatterlist, `se_lun`, `se_sess`, state flags, `transport_state`, sense buffer.

**`struct se_device` / `struct se_lun` / `struct se_node_acl` / `struct se_portal_group`** — backstore device (with ALUA groups and PR state), exported LUN, initiator ACL, and portal group (TPG).

**`struct target_core_fabric_ops` / `struct target_backend_ops`** — the fabric and backstore plug-in interfaces.

**`struct tcmu_mailbox` / `struct tcmu_cmd_entry`** (`include/uapi/linux/target_core_user.h`) — TCMU shared ring header and entries.

## Key Functions / Entry Points

- **`iscsi_queuecommand()`** (`drivers/scsi/libiscsi.c`) — SCSI midlayer → iSCSI initiator submission.
- **`iscsi_tcp_recv_skb()` / `iscsi_sw_tcp_data_ready()`** (`drivers/scsi/iscsi_tcp.c`, `libiscsi_tcp.c`) — software initiator receive path.
- **`iscsi_session_recovery_timedout()`** — replacement_timeout expiry, fails I/O upward.
- **`iser_send_command()` / `iser_reg_rdma_mem()`** (`drivers/infiniband/ulp/iser/`) — iSER command send and buffer registration.
- **`target_submit_cmd()` / `target_submit()`** (`drivers/target/target_core_transport.c`) — fabric → core submission.
- **`iscsit_handle_scsi_cmd()`** (`drivers/target/iscsi/iscsi_target.c`) — iSCSI target command intake.
- **`isert_put_datain()` / `isert_get_dataout()`** (`drivers/infiniband/ulp/isert/ib_isert.c`) — iSER target RDMA WRITE/READ via `rdma_rw`.
- **`tcmu_queue_cmd()`** (`drivers/target/target_core_user.c`) — place a command on the TCMU ring.

## Important Flags & Config Options

- **Kconfig**: `CONFIG_ISCSI_TCP`, `CONFIG_SCSI_ISCSI_ATTRS`, `CONFIG_INFINIBAND_ISER`; `CONFIG_TARGET_CORE`, `CONFIG_ISCSI_TARGET`, `CONFIG_INFINIBAND_ISERT`, `CONFIG_TCM_IBLOCK`, `CONFIG_TCM_FILEIO`, `CONFIG_TCM_PSCSI`, `CONFIG_TCM_USER2`, `CONFIG_LOOPBACK_TARGET`, `CONFIG_VHOST_SCSI`, `CONFIG_TCM_QLA2XXX`.
- **open-iscsi (`iscsid.conf` / node records)**: `node.session.timeo.replacement_timeout`, `node.conn[0].timeo.noop_out_interval`/`noop_out_timeout`, `node.session.cmds_max`, `node.session.queue_depth`, `node.conn[0].iscsi.HeaderDigest`/`DataDigest`, `node.session.auth.authmethod` (CHAP), `iface.transport_name`.
- **Negotiated keys**: `ImmediateData`, `InitialR2T`, `FirstBurstLength`, `MaxBurstLength`, `MaxRecvDataSegmentLength`, `ErrorRecoveryLevel`.
- **LIO TPG attributes** (configfs): `authentication`, `generate_node_acls` (demo mode), `cache_dynamic_acls`, `default_cmdsn_depth`; device attributes `emulate_tpu` (UNMAP), `emulate_write_cache`, `block_size`, `max_unmap_lba_count`; iSER enable via `np/<portal>/iser`.
- **ib_iser module params**: `max_sectors`, `pi_enable`, `always_register`.

## Interactions with Other Subsystems

- **↑ Userspace**: `iscsiadm`/`iscsid` (netlink to `scsi_transport_iscsi`), `targetcli`/rtslib (configfs), tcmu-runner (UIO + netlink), multipathd.
- **→ SCSI midlayer**: initiator sessions are SCSI hosts; disks via `sd`; error handling via SCSI EH and the transport class.
- **→ Networking**: kernel TCP sockets for iSCSI (both sides) ([[tcp-ip-stack]]).
- **→ RDMA**: iSER/isert use rdma_cm, fast registration, signature MRs and `rdma_rw` ([[rdma]]).
- **→ Block layer**: the iblock backstore submits bios; initiator disks feed [[device-mapper]] multipath and filesystems.
- **← KVM**: vhost-scsi serves LIO LUNs to guests.

## Design Decisions & Tradeoffs

- **Control plane in userspace, data plane in kernel (open-iscsi).** Login negotiation, discovery and recovery policy are complex and rare, so they live in `iscsid`. Only the per-I/O path is in the kernel. The socket handoff after login is the seam. The cost is a dependency on `iscsid` being alive for recovery, which is why it is started early in boot for iSCSI root disks.
- **One connection per session plus dm-multipath, not MC/S.** Linux chose to let the generic multipath layer handle path redundancy and load spreading instead of implementing iSCSI's own multi-connection sessions in the initiator. That simplified the initiator at the cost of per-session (not per-CPU) queueing.
- **Generic SCSI target core with pluggable fabrics and backstores (LIO).** One implementation of reservations, ALUA and SCSI emulation serves every transport, which is what won LIO its place over SCST. It keeps SCSI's single-queue heritage, though, and it's a large, complex core for what NVMe targets do much more simply.
- **configfs, no daemon.** All target state lives in the kernel, and configuration is file operations. That makes restarts and automation straightforward, but persistence must be handled by tooling (targetcli save/restore).
- **iSER keeps iSCSI's semantics.** Reusing iSCSI login, naming and management let deployments adopt RDMA with minimal change, but also kept SCSI's overheads that NVMe-oF later removed.
- **TCMU through UIO.** Using an existing shared-memory mechanism avoided a new character device ABI and made userspace backends possible. The price is a data copy through the ring's data area and a userspace hop per command.

## How It Has Evolved

- **2.6.13 (2005)** — open-iscsi (merged from the linux-iscsi and open-iscsi projects) with `iscsi_tcp` and the netlink control interface.
- **2.6.19 (2006)** — iSER initiator; STGT userspace target framework merged.
- **2.6.38 (2011)** — LIO target core replaces STGT as the in-kernel target after the LIO vs SCST decision; `tcm_loop` and FCoE fabrics.
- **3.1 (2011)** — iSCSI target fabric; later SRP target (`ib_srpt`), `tcm_qla2xxx`, vhost-scsi (3.6).
- **3.10 (2013)** — iSER target (`ib_isert`); T10-PI end-to-end support across iSER initiator and target (3.15–3.16).
- **3.18 (2014)** — TCMU userspace backstore; tcmu-runner and the Ceph iSCSI gateway build on it.
- **5.x–6.x** — iSER moved to the generic `rdma_rw` and CQ pool APIs; target core submission API reworked (`target_submit_prep`/`target_submit`); new fabrics (`efct` FC); iSCSI steadily displaced by NVMe/TCP for new flash storage while remaining the most widely deployed IP SAN protocol.

## Further Reading

1. [LWN: A tale of two SCSI targets](https://lwn.net/Articles/424004/); [Shooting at SCSI targets](https://lwn.net/Articles/420691/); [tcm_loop multi-fabric LLD](https://lwn.net/Articles/434603/)
2. [kernel.org: TCM Userspace Design](https://docs.kernel.org/target/tcmu-design.html); [Target core API](https://docs.kernel.org/driver-api/target.html)
3. [open-iscsi README](https://github.com/open-iscsi/open-iscsi/blob/master/README); [tcmu-runner](https://github.com/open-iscsi/tcmu-runner); [LIO and TCMU: the best of both worlds (slides)](https://events.static.linuxfound.org/sites/events/files/slides/tcmu-bobw_0.pdf)
4. [NVIDIA: iSER](https://docs.nvidia.com/networking/display/mlnxofedv551032/iscsi+extensions+for+rdma+(iser)); [UNH-IOL: iSCSI over RDMA](https://www.iol.unh.edu/knowledge/implementation-and-comparison-iscsi-over-rdma)
5. [Wikipedia: LIO (SCSI target)](https://en.wikipedia.org/wiki/LIO_(SCSI_target))

## LKML Highlights

- **LIO vs SCST (linux-scsi, late 2010)** — the target-subsystem selection debate. Bottomley favoured LIO for configfs configuration and responsiveness to review, while SCST advocates pointed to broader hardware support and stricter SCSI compliance; LIO was merged for 2.6.38 with the expectation that missing features would be ported.
- **"target: Add TCMU userspace backstore" (Andy Grover, 2014)** — debated using UIO and a shared ring versus a new device interface; UIO won for reuse, with netlink for device events.
- **iSER/isert conversion to `rdma_rw` (Christoph Hellwig, Sagi Grimberg, 2016)** — moved the iSER target onto the generic RDMA read/write API shared with NVMe-oF and NFS/RDMA, removing iWARP- and signature-MR special cases from the ULP.
