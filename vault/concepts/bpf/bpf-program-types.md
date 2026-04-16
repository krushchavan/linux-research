---
title: "BPF Program Types"
category: concept
tags: [bpf, program-types, xdp, kprobe, tracepoint, sched-ext, hooks]
subsystem: bpf
kernel_version: "3.18"
researched: 2026-04-16
status: complete
sources:
  - https://lwn.net/Articles/740157/
  - https://lwn.net/Articles/972075/
  - https://kernel-internals.org/bpf/
  - https://www.kernel.org/doc/html/latest/bpf/index.html
---

# BPF Program Types

## Purpose

A BPF program cannot be a generic function pointer — the verifier needs to know which helpers are legal, what the first argument's type is, and what the return value means. Program types encode this context: each type corresponds to a specific class of kernel hook, restricts the callable API to what makes sense at that hook, and defines the semantics of the return value. Without typed programs, a tracing program could accidentally call an XDP redirect helper and corrupt the network stack.

## Mental Model

Think of program types as **contract specifications**: a program type declares "I will be called from hook X with argument type Y; I may call helpers from set Z; my return value means W." The verifier enforces the contract at load time. The attachment mechanism wires the JIT-compiled function to the specific kernel data structure that represents hook X.

## How It Works

Each program type is registered by filling in a `struct bpf_prog_type_list` and calling `bpf_register_prog_type()`. The key payload is a `struct bpf_verifier_ops` with two callbacks:

- `get_func_proto(func_id, prog)` — returns the `struct bpf_func_proto` for helper `func_id`, or NULL if that helper is not allowed for this program type. The verifier calls this on every `BPF_CALL` instruction.
- `is_valid_access(off, size, type, prog, info)` — validates whether the program may load/store the context at byte offset `off`. For `BPF_PROG_TYPE_XDP`, only `struct xdp_md` fields are permitted; for `BPF_PROG_TYPE_KPROBE`, `struct pt_regs` fields.

When the user calls `BPF_PROG_LOAD`, `bpf_prog_load()` looks up the type's `bpf_verifier_ops` and passes them to `bpf_check()`. The verifier uses them throughout abstract interpretation. After successful verification, the program is JIT-compiled.

Attachment is type-specific and often uses a separate syscall or netlink command:
- XDP: `netlink` with `IFLA_XDP` attribute, or `bpf_link_create(BPF_XDP)` in newer kernels.
- TC: `tc filter add ... bpf`.
- kprobe: `perf_event_open()` + `ioctl(PERF_EVENT_IOC_SET_BPF)`, or `bpf_link_create(BPF_PERF_EVENT)`.
- tracepoint: same as kprobe.
- cgroup: `BPF_PROG_ATTACH`.
- struct_ops: `BPF_LINK_CREATE` with struct_ops type.

### Major program types in detail

**`BPF_PROG_TYPE_SOCKET_FILTER`** (3.18) — The original eBPF program type. Attached via `SO_ATTACH_BPF` on a socket. Called on every received packet with `struct __sk_buff *` as context. Return value is the number of bytes to pass (0 = drop). Used by `tcpdump -e`, Wireshark, and seccomp.

**`BPF_PROG_TYPE_KPROBE`** (4.1) — Attached to a kprobe or kretprobe on any kernel function. Called with `struct pt_regs *` (register state at the probe point). Return value is ignored. Used for dynamic tracing without recompiling the kernel. `fentry`/`fexit` variants (5.5) attach via BPF trampoline to function prologues/epilogues with lower overhead than kprobes and full argument access.

**`BPF_PROG_TYPE_TRACEPOINT`** (4.7) — Attached to static tracepoints (`TRACE_EVENT` macros). Called with a per-tracepoint format struct. Type-safe: the verifier knows the exact layout of the context. Preferred over kprobes for stable kernel events.

**`BPF_PROG_TYPE_XDP`** (4.8) — Runs at the earliest point in the NIC receive path, before any SKB is allocated. Called with `struct xdp_md *` describing the packet data window. Returns one of:
- `XDP_PASS` — hand to normal networking stack
- `XDP_DROP` — discard (fast DDoS mitigation)
- `XDP_TX` — bounce back out the same NIC
- `XDP_REDIRECT` — forward to another NIC or CPU via a DEVMAP or CPUMAP
- `XDP_ABORTED` — error; traced via tracepoint

XDP programs can run in three modes: native (in the driver's NAPI poll), offloaded (on the SmartNIC), or generic (after SKB allocation, as a fallback). Native mode is fastest; it avoids SKB allocation entirely for dropped packets.

**`BPF_PROG_TYPE_SCHED_CLS`** / **`BPF_PROG_TYPE_SCHED_ACT`** (4.1) — TC (traffic control) programs. Attached as qdisc classifiers or actions. Called with `struct __sk_buff *`. Return value is a TC verdict (`TC_ACT_OK`, `TC_ACT_REDIRECT`, `TC_ACT_SHOT`). Used for L4 load balancing, bandwidth policing, and packet mangling in cloud environments.

**`BPF_PROG_TYPE_CGROUP_SKB`** (4.10) — Attached to a cgroup2's ingress or egress. Called for every socket send/recv within the cgroup. Used for per-container network policy without iptables overhead.

**`BPF_PROG_TYPE_PERF_EVENT`** (4.9) — Attached to `perf_event` records (hardware PMU events, software events, hardware breakpoints). Called with `struct bpf_perf_event_data *`. Used for profiling-driven BPF programs (e.g. stack-sampling profilers that record to a ring buffer).

**`BPF_PROG_TYPE_LSM`** (5.7) — Attached to LSM (Linux Security Module) hooks via `bpf_link_create`. Called with hook-specific arguments. Return value: 0 = allow, negative errno = deny. Unlike SELinux or AppArmor, LSM BPF programs are dynamically loaded and composable. Requires `CAP_BPF + CAP_MAC_ADMIN`.

**`BPF_PROG_TYPE_STRUCT_OPS`** (5.6) — A meta-type: programs implement a specific kernel vtable (e.g. `struct tcp_congestion_ops`, `struct sched_ext_ops`). Each program corresponds to one function pointer in the ops struct. The verifier uses BTF to type-check arguments against the struct definition. Loading installs the BPF-backed ops struct into the kernel's ops registry.

The most significant use of struct_ops is **sched_ext** (6.12):

- `struct sched_ext_ops` exposes callbacks mirroring `struct sched_class`: `enqueue`, `dispatch`, `select_cpu`, `init_task`, `enable/disable`.
- Tasks are moved through *dispatch queues* (DSQs): `SCX_DSQ_GLOBAL` (shared), `SCX_DSQ_LOCAL` (per-CPU), or user-created FIFOs. BPF programs enqueue tasks to DSQs; the kernel consumes them via `dispatch_consume()`.
- A watchdog timer detects indefinitely-starved tasks and unloads the BPF scheduler, falling back to CFS. This safety net allows production deployment of experimental schedulers.
- Valve (Steam Deck), Meta (web workloads), Google (ghOSt) all have sched_ext deployments.

**`BPF_PROG_TYPE_SK_SKB`** (4.14) — Verdict and parser programs for sockmap. A verdict program selects a destination socket for each received message; a parser program delineates message boundaries in a stream. Together they implement kernel-space L7 proxy logic.

## Key Data Structures

**`struct bpf_verifier_ops`** (`include/linux/bpf.h`) — per-type verifier hooks:
- `get_func_proto(func_id, prog)` — helper allow-list
- `is_valid_access(off, size, type, prog, info)` — context field access validation
- `convert_ctx_access(type, si, insns, prog, target_size)` — rewrites context field accesses to the actual kernel struct layout

**`struct bpf_prog_type_list`** — registration node linking a `bpf_prog_type` enum to its `bpf_verifier_ops`.

## Key Functions / Entry Points

**`bpf_prog_load()`** (`kernel/bpf/syscall.c`) — entry for `BPF_PROG_LOAD`; selects `verifier_ops`, runs `bpf_check()`, calls JIT.

**`bpf_prog_run()`** / `BPF_PROG_RUN()` — calls `prog->bpf_func(ctx, prog->insnsi)` via a function pointer; used at hook sites.

**`bpf_link_create()`** (`kernel/bpf/syscall.c`) — creates a `bpf_link` that holds a reference to the program and can be pinned, preventing the program from being freed when the creating process exits.

## Important Flags & Config Options

- `CONFIG_CGROUP_BPF` — enables cgroup BPF program types.
- `CONFIG_BPF_LSM` — enables LSM BPF; also requires `lsm=bpf` in kernel cmdline or `CONFIG_LSM`.
- `CONFIG_SCHED_CLASS_EXT` — enables sched_ext.
- `BPF_F_SLEEPABLE` — flag on `BPF_PROG_LOAD`; marks the program as allowed to sleep (call RCU-safe sleepable helpers). Available for kprobe, tracepoint, LSM, and iter program types on specific hooks.

## Interactions with Other Subsystems

- **→ [[net]]**: XDP hooks into NIC NAPI; TC hooks into qdisc; SK_SKB hooks into sockmap.
- **→ [[security]]**: LSM BPF attaches to security hooks; enforcement is composable with SELinux/AppArmor.
- **→ [[scheduler]]**: sched_ext provides a full BPF-implemented scheduler class.
- **→ [[cgroups]]**: Cgroup BPF programs filter network and device access per cgroup.
- **→ [[bpf-verifier]]**: Program type supplies `verifier_ops` to constrain verification.

## Design Decisions & Tradeoffs

**Typed programs vs. a single generic type** — Having one program type with runtime capability queries would be simpler but would make the verifier's helper allow-list dependent on runtime state. Typed programs allow the verifier to prove the allow-list statically. The cost is proliferation of program types (currently 30+), each requiring its own `verifier_ops`.

**struct_ops as a meta-type** — Instead of adding a new program type for each kernel vtable (TCP CC, scheduler, cpuidle governor…), struct_ops provides a generic mechanism. Adding a new struct_ops target requires only annotating the struct with BTF tags, not modifying the BPF core. The tradeoff: struct_ops programs must handle every field in the vtable, including ones they don't care about, and the BTF type-checking is more complex for the verifier.

**sched_ext DSQ model** — Rather than exposing the full `struct rq` to BPF (which would make kernel ABI changes break BPF schedulers), sched_ext hides `struct rq` behind the DSQ abstraction. BPF schedulers push/pop opaque task handles into DSQs; the kernel handles the actual `struct rq` manipulation. This decoupling allows the kernel team to change `struct rq` internals without breaking sched_ext programs.

## How It Has Evolved

- **3.18 (2014)**: `SOCKET_FILTER`, `KPROBE` (draft), `SCHED_CLS/ACT`.
- **4.1 (2015)**: `KPROBE` stabilized, `TRACEPOINT`.
- **4.8 (2016)**: `XDP` (revolutionary for DDoS mitigation).
- **4.10 (2017)**: `CGROUP_SKB/SOCK`, `PERF_EVENT`.
- **5.5 (2020)**: `fentry`/`fexit` via BPF trampolines (lower overhead than kprobes).
- **5.6 (2020)**: `STRUCT_OPS` (TCP congestion control as first use case).
- **5.7 (2020)**: `LSM` — composable kernel security policies.
- **6.12 (2024)**: `sched_ext` via struct_ops; production use at Valve, Meta, Google.

## Further Reading

1. [A thorough introduction to eBPF — LWN.net (2017)](https://lwn.net/Articles/740157/)
2. [sched_ext: Implement BPF extensible scheduler class — LWN.net (2024)](https://lwn.net/Articles/972075/)
3. [BPF and security — LWN.net (2022)](https://lwn.net/Articles/946389/)
4. [BPF program types — kernel.org docs](https://www.kernel.org/doc/html/latest/bpf/index.html)
