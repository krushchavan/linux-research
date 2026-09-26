---
title: "NVMe over Fibre Channel (FC-NVMe)"
category: concept
tags: [nvme, nvme-of, fibre-channel, storage, san]
subsystem: nvme
kernel_version: "4.10 (nvme-fc host, nvmet-fc target, fcloop); lpfc 4.11; qla2xxx 4.14; FC-NVMe-2 disconnect/SLER support ~5.x"
researched: 2026-09-26
status: complete
sources:
  - https://github.com/torvalds/linux/blob/master/include/linux/nvme-fc-driver.h
  - https://github.com/torvalds/linux/blob/master/drivers/nvme/target/fcloop.c
  - https://lore.kernel.org/linux-nvme/1c072286-4c7f-7906-24eb-bdda0a7760ec@suse.de/T/
  - https://lore.kernel.org/linux-nvme/20190927215136.3096-3-jsmart2021@gmail.com/
  - https://www.mail-archive.com/linux-scsi@vger.kernel.org/msg84219.html
  - https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/configuring-nvme-over-fabrics-using-nvme-fc_managing-storage-devices
  - https://access.redhat.com/solutions/3522911
  - https://documentation.suse.com/sles/15-SP5/html/SLES-all/cha-nvmeof.html
  - https://fibrechannel.org/fibre-channel-new-technologies-fc-nvme-2/
  - https://fibrechannel.org/answers-to-fc-nvme-2-questions/
  - https://blogs.marvell.com/2020/08/put-a-cherry-on-top-introducing-fc-nvme-v2/
---

# NVMe over Fibre Channel (FC-NVMe)

> Transport sibling of [[nvme-over-fabrics-rdma-and-tcp]]. Compared with the other storage fabrics in [[storage-fabrics-nvme-of-iser-iscsi-nvme-fc-nfs-rdma]].

## Purpose

Enterprises have decades of investment in **Fibre Channel SANs**: dedicated, lossless storage networks with zoning, name services, mature HBAs and operations teams. NVMe over Fabrics over RDMA or TCP would require them to build or repurpose an Ethernet fabric. **FC-NVMe** (T11 FC-NVMe, 2017; FC-NVMe-2, 2020) instead defines how NVMe commands, data and completions ride on Fibre Channel. The same HBAs and switches can carry traditional SCSI (FCP) and NVMe side by side, and a data centre can move to NVMe's per-CPU queue model without changing its network. In Linux the transport is split into a generic **`nvme-fc`** host / **`nvmet-fc`** target layer and **LLDD** (low-level driver) HBA drivers, so NVMe logic lives once and each HBA vendor only moves frames.

## Mental Model

Fibre Channel is a **private freight railway** that already runs trains of SCSI cargo. FC-NVMe adds a **new cargo type** (FC-4 type NVMe) on the same tracks. A host and a subsystem first sign a **contract** (an *association*, one per NVMe controller), then open a numbered **siding per CPU** (an I/O *connection*, one per NVMe queue). Each NVMe command is a **shipment** (an FC *exchange*): the command IU goes out, data frames follow (with a "ready for your freight" signal for writes), and a delivery receipt comes back. The HBA drives the train, so the host CPU never touches the cargo. The Linux split is like a **shipping company (nvme-fc)** that plans shipments and a **locomotive contractor (lpfc, qla2xxx)** that only knows how to run trains.

## How It Works

### The FC-NVMe protocol

FC-NVMe maps NVMe-oF onto the FC-4 layer (FC-4 type 0x28, next to FCP's 0x08):
- **Associations and connections via Link Services (LS).** Before any command, the host sends FC-NVMe LS requests: **Create Association** (which also creates the admin queue connection and names the host and subsystem NQNs), then **Create I/O Connection** for each I/O queue, and **Disconnect Association** at teardown. An association corresponds to one NVMe controller. The NVMe-oF Fabrics Connect command then runs *inside* each connection as usual.
- **One exchange per command.** The host sends an **NVMe CMD IU** carrying the 64-byte SQE. For a **read**, the target sends data frames and then a response. For a **write**, the target sends **XFER_RDY** when it has buffers, and the host sends the data. With **first burst** (negotiated), the host sends initial data without waiting, saving a round trip.
- **Compact responses.** The target returns either a full **ERSP IU** (extended response, carrying the 16-byte NVMe CQE plus transferred length and a response sequence number) or, for successful commands where nothing interesting changed, a short **all-zeros response** that the host expands into a synthetic success CQE. The ERSP is required periodically (so the host can track SQ head) and on any error. This keeps common-case completions tiny.
- **Lossless fabric underneath.** FC's buffer-to-buffer credits mean congestion never drops frames. Errors come from bit errors or link events. FC-NVMe v1 recovered only at the command/association level, and a lost frame could leave an exchange hanging until timeouts of tens of seconds.
- **FC-NVMe-2 (2020)** added **Sequence Level Error Recovery (SLER)**: a new **FLUSH** link service and **RED** (Responder Error Detected) let initiator and target detect a missing frame within about 2 s and retransmit the sequence instead of aborting the command after roughly 60 s. It also added **confirmed completion** and formalised **Disconnect** semantics. Linux's nvme-fc/nvmet-fc were synced with FC-NVMe-2 headers and gained association disconnect support (James Smart, 2019–2020), and lpfc added NVMe SLER support.

### Linux host: nvme-fc

`drivers/nvme/host/fc.c` is a fabrics transport like `nvme-rdma` or `nvme-tcp`, so it shares `fabrics.c`, multipath, authentication and the blk-mq integration ([[nvme-over-fabrics-rdma-and-tcp]], [[blk-mq]]). What's different is that it never touches the wire. Everything goes through `struct nvme_fc_port_template`, which an HBA driver supplies:
1. **Port registration.** When an FC HBA port comes up, the LLDD calls **`nvme_fc_register_localport()`** with its WWNN/WWPN and template. When the FC name server (fabric login, PRLI with NVMe FC-4 type) reveals a remote port offering NVMe target or discovery service, the LLDD calls **`nvme_fc_register_remoteport()`**. Addresses are written as `nn-0x<WWNN>:pn-0x<WWPN>`.
2. **Auto-connect.** Registering a remote port with the discovery role makes nvme-fc emit a **udev event** (`FC_EVENT=nvmediscovery`). nvme-cli's udev rule and the `nvmefc-boot-connections` service then run `nvme connect-all --transport=fc --traddr=nn-..:pn-.. --host-traddr=nn-..:pn-..`. This is how FC LUN-style "plug in the cable and devices appear" behaviour is reproduced for NVMe. A boot-time replay handles ports discovered before userspace was ready.
3. **Create controller.** `nvme_fc_create_ctrl()` finds the matching local/remote port pair and creates the admin queue. The LLDD's **`create_queue`** allocates HBA resources for each queue (typically affinitised to a hardware queue), and **`ls_req`** sends Create Association / Create I/O Connection (`struct nvmefc_ls_req`). Then the normal Fabrics Connect, Identify and I/O queue setup proceeds. `map_queues` lets the LLDD align blk-mq hardware contexts with its own queues.
4. **I/O.** `nvme_fc_queue_rq()` builds the CMD IU in a per-request `nvme_fc_fcp_op`, DMA-maps the data scatterlist, and calls the LLDD's **`fcp_io`** with a `struct nvmefc_fcp_req` (command IU address/length, response buffer, `first_sgl`/`sg_cnt`, `io_dir`, `done` callback). The HBA runs the whole exchange (XFER_RDY, data frames, response) in hardware and firmware. On completion the LLDD fills `rcv_rsplen`, `transferred_length` and `status` and calls `done()`. nvme-fc then either parses the ERSP or synthesises a success CQE from a zero response, checks the transferred length, and completes the block request.
5. **Aborts and errors.** `fcp_abort` asks the HBA to abort an exchange (ABTS). The LLDD must still call `done()` for the original request. Any serious error resets the whole association: the controller enters RESETTING, outstanding I/O is aborted, and the association is re-created.

**Connectivity loss** involves two timers. The FC transport's per-remote-port **`dev_loss_tmo`** (how long a vanished port is remembered, set via `nvme_fc_set_remoteport_devloss()`) and NVMe's **`ctrl_loss_tmo`** (how long to keep trying to reconnect a controller). nvme-fc uses the smaller of the two. If the remote port returns within that window (an RSCN from the fabric), it reconnects automatically. Native NVMe multipath with ANA handles path failover between associations through different HBA ports or fabrics.

### Linux target: nvmet-fc

`drivers/nvme/target/fc.c` plugs FC into the generic `nvmet` core (configfs ports with `trtype=fc`, `traddr=nn-..:pn-..`). The HBA driver (target mode) registers with **`nvmet_fc_register_targetport()`** and `struct nvmet_fc_target_template`:
- incoming LS requests (`nvmet_fc_rcv_ls_req()`, with a *hosthandle* identifying the remote port) create associations and queues,
- incoming commands arrive through **`nvmet_fc_rcv_fcp_req()`**, which hands the CMD IU to the nvmet core,
- data movement and responses are driven by one LLDD op, **`fcp_op`**, with `NVMET_FCOP_WRITEDATA` (send XFER_RDY and fetch write data into target buffers), `NVMET_FCOP_READDATA` (send read data, optionally with the response), and `NVMET_FCOP_RSP`,
- `defer_rcv` handles the case where the target had no command context available on arrival, so the HBA must hold the frame until one frees up, and `discovery_event` asks the LLDD to trigger initiator rescans (RSCN) when discovery information changes.

Backends are the usual nvmet ones: block device, file, or NVMe passthrough.

### HBA drivers (LLDDs) and fcloop

- **lpfc** (Broadcom/Emulex): host (4.11) and **target** mode. Target ports are selected with `lpfc_enable_nvmet=<WWPN list>`, and `lpfc_enable_fc4_type` chooses FCP, NVMe or both per port. It carries most FC-NVMe-2 features including SLER.
- **qla2xxx** (Marvell/QLogic): host support (4.14, FC-NVMe on QLE269x/27xx and later, enabled by default via `ql2xnvmeenable`). Its SCSI target mode (`tcm_qla2xxx`) is part of LIO rather than nvmet ([[iscsi-iser-and-lio-target]]).
- Both drivers run **SCSI FCP and NVMe on the same port** simultaneously. A host can mount legacy SCSI LUNs and NVMe namespaces from the same array.
- **fcloop** (`drivers/nvme/target/fcloop.c`) is a software LLDD that registers a local port, remote ports and target ports and loops LS and FCP operations between nvme-fc and nvmet-fc in memory. It is how FC-NVMe is tested without hardware (blktests `nvme` tests with `nvme_trtype=fc`), and recent fixes harden its handling of remote ports disappearing mid-LS.

Enterprise support: RHEL 7.5 tech preview (lpfc), fully supported in 7.6 (lpfc) and in 8.0 for both lpfc and qla2xxx. SUSE supports it similarly.

## Key Data Structures

**`struct nvme_fc_port_template`** (`include/linux/nvme-fc-driver.h`) — host LLDD ops: `localport_delete`, `remoteport_delete`, `create_queue`/`delete_queue`, `ls_req`/`ls_abort`, `fcp_io`/`fcp_abort`, `xmt_ls_rsp`, `map_queues`; sizes (`max_hw_queues`, `max_sgl_segments`, `dma_boundary`, private sizes).

**`struct nvme_fc_local_port` / `struct nvme_fc_remote_port`** — registered FC ports: `node_name`, `port_name`, `port_role` (initiator, target, discovery), `port_id`, `dev_loss_tmo`, state.

**`struct nvmefc_fcp_req`** — one NVMe command exchange handed to the LLDD: `cmdaddr`/`cmdlen`, `rspaddr`/`rsplen`, `first_sgl`/`sg_cnt`, `payload_length`, `io_dir`, `done`, and LLDD-filled `rcv_rsplen`, `transferred_length`, `status`.

**`struct nvmefc_ls_req`** — a Link Service request (Create Association, Create Connection, Disconnect) with request/response buffers and `done`.

**`struct nvmet_fc_target_template` / `struct nvmefc_tgt_fcp_req`** — target LLDD ops (`fcp_op`, `fcp_abort`, `fcp_req_release`, `defer_rcv`, `xmt_ls_rsp`, `discovery_event`) and the per-command target exchange (`op`, `sg`, `offset`, `transfer_length`, `rspaddr`).

**`struct nvme_fc_ctrl`** (`drivers/nvme/host/fc.c`) — host controller = one association: local/remote port refs, `association_id`, queues, reconnect work, `ioabort_wait`.

## Key Functions / Entry Points

- **`nvme_fc_register_localport()` / `nvme_fc_register_remoteport()`** — LLDD → nvme-fc port registration; the remote-port call can emit the discovery udev event.
- **`nvme_fc_create_ctrl()`** — `nvme connect -t fc` entry; builds association and queues.
- **`nvme_fc_queue_rq()` → LLDD `fcp_io`** — per-I/O submission; **`nvme_fc_fcpio_done()`** — completion, ERSP parsing or synthetic CQE.
- **`nvme_fc_set_remoteport_devloss()`** — ties FC dev_loss to NVMe reconnect.
- **`nvmet_fc_register_targetport()`**, **`nvmet_fc_rcv_ls_req()`**, **`nvmet_fc_rcv_fcp_req()`** — target entry points.
- **`fcloop_fcp_req()` / `fcloop_t2h_ls_req()`** (`drivers/nvme/target/fcloop.c`) — software loopback paths.

## Important Flags & Config Options

- **Kconfig**: `CONFIG_NVME_FC`, `CONFIG_NVME_TARGET_FC`, `CONFIG_NVME_TARGET_FCLOOP`, `CONFIG_SCSI_LPFC`, `CONFIG_SCSI_QLA_FC`, `CONFIG_NVME_MULTIPATH`.
- **lpfc**: `lpfc_enable_fc4_type` (1 = FCP, 2 = NVMe, 3 = both), `lpfc_enable_nvmet=<WWPNs>` (target ports), `lpfc_nvme_seg_cnt`, `lpfc_hdw_queue`.
- **qla2xxx**: `ql2xnvmeenable`.
- **nvme-cli**: `--transport=fc --traddr=nn-0x..:pn-0x.. --host-traddr=nn-0x..:pn-0x..`, `--ctrl-loss-tmo`, `--keep-alive-tmo` (Red Hat notes raising it above the 5 s default can be necessary); `nvmefc-boot-connections.service` and the `70-nvmf-autoconnect` udev rule.
- **FC transport**: remote port `dev_loss_tmo` (sysfs `fc_remote_ports`).

## Interactions with Other Subsystems

- **↑ Userspace**: nvme-cli/libnvme (connect-all, discovery), udev autoconnect rules, `nvmetcli` for targets, HBA vendor tools for zoning and firmware.
- **→ NVMe fabrics core**: shares Fabrics Connect, keep-alive, authentication, ANA multipath and controller state machine with RDMA and TCP ([[nvme-over-fabrics-rdma-and-tcp]]).
- **→ Block layer**: blk-mq hardware contexts mapped to HBA queues ([[blk-mq]]).
- **→ SCSI FC transport**: the same HBA drivers also register SCSI hosts with `scsi_transport_fc`; FC login, name-server and RSCN handling are shared between SCSI and NVMe personalities.
- **← nvmet core**: target side reuses subsystems, namespaces, ANA groups and backends common to all nvmet transports.

## Design Decisions & Tradeoffs

- **Generic transport + thin LLDD.** Unlike SCSI FC, where each HBA driver historically implemented much of the protocol, nvme-fc/nvmet-fc own all NVMe-over-FC logic and LLDDs only register ports and run exchanges. That kept NVMe semantics consistent across vendors and made fcloop possible. The cost is a large, callback-heavy API with subtle ownership rules around aborts and teardown, which is where most bug fixes land.
- **Lossless fabric, hardware data movement.** Like RDMA, the HBA places data directly, so there are no receive copies and no software checksums. Unlike RoCE, the lossless property is native to FC and needs no PFC tuning. The price is a separate, specialised network and HBAs.
- **Zero-length success responses.** Sending a full CQE only when needed saves bandwidth and HBA work per I/O, at the cost of the host tracking SQ head and sequence numbers to validate synthetic completions.
- **Association-level recovery (v1) vs sequence-level recovery (v2).** v1 kept the protocol simple but turned a single lost frame into a long timeout and an association reset. FC-NVMe-2's SLER adds link-service complexity to bring recovery down to seconds, which matters because NVMe's low latencies make stalls very visible.
- **Two timers for connectivity loss.** Honouring both FC `dev_loss_tmo` and NVMe `ctrl_loss_tmo` respects FC administrators' expectations while fitting NVMe's reconnect model. Misconfigured timers are a common source of "paths never come back" or "I/O hangs too long" reports.
- **Dual protocol on one port.** Letting FCP and NVMe coexist eases migration, but splits HBA resources (exchanges, queues) between personalities, which the `enable_fc4_type` knobs control.

## How It Has Evolved

- **2016–2017** — T11 FC-NVMe standard completed; James Smart (Broadcom) posts nvme-fc, nvmet-fc and fcloop, merged in **4.10**.
- **4.11–4.14** — lpfc NVMe host and target support; qla2xxx FC-NVMe host support; RHEL 7.5 tech preview.
- **2018–2019** — auto-connect via udev discovery events and `nvmefc-boot-connections`; native NVMe multipath default in enterprise distros; RHEL 8 fully supports lpfc and qla2xxx NVMe/FC.
- **2019–2020** — FC-NVMe-2 header sync, Disconnect Association support (29-patch series), LLDD API revision for LS reception on the host (needed for target-initiated LS); lpfc sequence-level error recovery; FC-NVMe-2 published (August 2020).
- **2021–2026** — hardening of association teardown and abort races, fcloop fixes driven by blktests, and in-band DH-HMAC-CHAP authentication (common to all NVMe-oF transports) usable over FC.

## Further Reading

1. [Fibre Channel Industry Association: FC-NVMe-2 overview](https://fibrechannel.org/fibre-channel-new-technologies-fc-nvme-2/) and [FC-NVMe-2 Q&A](https://fibrechannel.org/answers-to-fc-nvme-2-questions/)
2. [Marvell: Introducing FC-NVMe v2](https://blogs.marvell.com/2020/08/put-a-cherry-on-top-introducing-fc-nvme-v2/)
3. [Red Hat: Configuring NVMe/FC](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/configuring-nvme-over-fabrics-using-nvme-fc_managing-storage-devices); [support status](https://access.redhat.com/solutions/3522911); [SUSE: NVMe-oF](https://documentation.suse.com/sles/15-SP5/html/SLES-all/cha-nvmeof.html)
4. Source: [`include/linux/nvme-fc-driver.h`](https://github.com/torvalds/linux/blob/master/include/linux/nvme-fc-driver.h), [`drivers/nvme/target/fcloop.c`](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/fcloop.c)
5. Vault: [[nvme-over-fabrics-rdma-and-tcp]], [[storage-fabrics-nvme-of-iser-iscsi-nvme-fc-nfs-rdma]]

## LKML Highlights

- **"nvme-fc/nvmet-fc: Add FC-NVME-2 disconnect association support" (James Smart, linux-nvme, 2020, 29 patches)** — reworked LS handling so the host can *receive* LS requests (target-initiated Disconnect), revising the LLDD API for both sides and fcloop; reviewers (Hannes Reinecke et al.) focused on the association-teardown races it closed.
- **"nvme-fc and nvmet-fc: sync with FC-NVME-2 header changes" (James Smart, 2019, `<20190927215136.3096-3-jsmart2021@gmail.com>`)** — aligned wire structures with the revised standard ahead of SLER and disconnect support.
- **"lpfc: Add NVMe sequence level error recovery support" (linux-scsi, 2019)** — HBA-side implementation of FC-NVMe-2 SLER, showing the split where the standard's error recovery lives mostly in the LLDD and firmware rather than in nvme-fc.
