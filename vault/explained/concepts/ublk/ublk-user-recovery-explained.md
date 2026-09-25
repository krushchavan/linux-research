---
title: "ublk User Recovery — Explained"
category: explained
original: "[[ublk-user-recovery]]"
subsystem: ublk
tags: [explained, ublk, crash-recovery, block]
converted: 2026-09-25
---

# ublk user recovery, explained

> Plain-language companion to [[ublk-user-recovery|the technical note]]. Same facts, fewer identifiers.

## The problem

Moving a block driver into user space means it can crash like any other process. Without special handling, a server crash makes the disk vanish and fails every outstanding I/O. To a mounted filesystem, that looks exactly like someone yanking the disk out.

So the kernel should keep the disk alive while a replacement server takes over. But there's a hard question in the middle: what about a request the old server was *halfway* through? It may or may not have reached the backend. Redoing it could duplicate a write; failing it could lose one that actually succeeded. Only the backend knows which is safe.

## The idea in one paragraph

It's **a call-centre transfer**. The caller (the filesystem) is put on hold (the queue is quiesced) while the agent who dropped the call is replaced. The new agent picks up the same line (same disk, same slots) and carries on. Policy flags chosen when the device was created decide what happens to the question the old agent was mid-way through: drop it with an error, ask it again, or tell every caller "try later" until someone picks up. The kernel only keeps the disk itself alive; rebuilding everything else is the new server's job.

## Step by step

### Step 1: Notice the server is gone
When the server process exits or crashes, its io_uring rings are torn down, which cancels every pending "fetch" command. ublk marks the device and its queues as cancelling and **quiesces** the queues, so the block layer stops dispatching to them. Each still-pending fetch is completed with an abort.

### Step 2: Wait for zero-copy buffers to drain
When the server's channel is finally closed, a background job takes over. First it waits until no zero-copy buffer references remain. A request can't be failed or requeued while some backend I/O might still be touching its pages. If references remain, the job reschedules itself and tries again.

### Step 3: Apply the policy to requests
This is the key step. Requests fall into two groups: those the server hadn't seen yet, and those it **owned** (delivered but not committed). The device's policy decides:
- **No recovery:** owned requests fail with an I/O error, and the device is stopped and removed.
- **Recovery (6.1):** owned requests are **failed**, because the kernel can't know whether the old server's write landed. Undelivered requests are **requeued**. The device becomes *quiesced*: the disk stays present and new I/O waits in the block layer.
- **Recovery with reissue (6.1):** owned requests are requeued too, and will be sent again to the new server. Only safe for backends where a duplicate write is harmless (idempotent or read-only).
- **Recovery with fail-fast (~6.13):** the device enters a failing state where outstanding *and new* I/O fails immediately until recovery completes. This suits clients like multipath or databases that would rather get a quick error than hang.

### Step 4: Reset the channel
Every slot's state is reinitialised, the old server's identity and memory are forgotten, and the device's channel can be opened again.

### Step 5: The new server takes over
A supervisor (systemd, an orchestrator) starts a replacement, which:
1. sends "start recovery". The kernel checks the device is quiesced or failing and the old server is gone.
2. opens the channel, maps the descriptors and re-posts fetches for every slot. It must rebuild its own state (reopen image files, reconnect to storage); the kernel only preserved the disk.
3. sends "end recovery". The kernel waits until every slot is ready, records the new server, marks the device live and unquiesces the queues. Requeued requests flow to the new process.

### Step 6: Planned handover
To upgrade a server without crashing it, a "quiesce" command (6.16) drives the same transition on purpose: queues are paused, fetches cancelled, and the old server exits cleanly. The new one follows the same start and end recovery steps.

### Step 7: If recovery never happens
If the replacement also dies, the same path runs again. If nobody recovers, I/O stays held (quiesced) or failing until an admin stops and deletes the device. Request timeouts still apply, and on unprivileged devices a stuck server is killed.

## The picture

```text
 server crashes
      │ rings torn down → pending fetches cancelled, queues paused
      ▼
 wait until no zero-copy buffers in use
      │
      ▼
 requests: not yet delivered → requeue
           delivered (owned) → fail  │ requeue (reissue) │ fail + fail new I/O (fail-fast)
      │
      ▼
 disk still present; I/O waiting (quiesced) or failing
      │
 new server: start recovery → reopen, re-post fetches → end recovery
      │
      ▼
 queues resume; requeued I/O goes to the new server
```

## Tradeoffs

- **What it gives you:** a server crash or upgrade that clients may never notice, with a correctness policy matched to the backend.
- **What it costs / requires:** servers must be written to be restartable and rebuild their own state; there are three policies to understand; teardown waits for zero-copy buffers, trading promptness for memory safety.
- **Where it bites:** holding I/O by default makes quick recoveries invisible, but with no supervisor to restart the server, I/O can block indefinitely. That's why the fail-fast policy exists. Choosing "reissue" for a backend where duplicate writes aren't harmless can corrupt data.

## How it got here

- **6.1 (2022):** recovery and reissue, by Ziyang Zhang (Alibaba), proposed weeks after ublk merged. Debate with Ming Lei over failing versus reissuing produced the separate reissue option.
- **~6.13:** fail-fast recovery (Uday Shankar).
- **6.15–6.17:** the release path reworked to wait for registered zero-copy buffers.
- **6.16:** quiesce for planned upgrades (Ming Lei).
- **7.0:** cancellation paths for batch mode.

## Related

- Technical version: [[ublk-user-recovery]]
- [[ublk-explained|ublk]]: the subsystem overview
- [[ublk-io-command-protocol-explained|I/O command protocol]]: the fetches that get cancelled
- [[ublk-control-plane-explained|Control plane]]: where recovery commands and policy flags live
- [[ublk-zero-copy]]: why teardown waits for buffers
- [[blk-mq-explained|blk-mq]]: quiesce and requeue provide the "on hold" behaviour
