---
title: "Cgroup BPF"
category: concept
tags: [cgroups, bpf, ebpf, network-filtering, device-control, policy]
subsystem: cgroups
kernel_version: "4.10"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html
  - https://lwn.net/Articles/697462/
  - https://lwn.net/Articles/679786/
---

# Cgroup BPF

## Purpose

Cgroup BPF allows eBPF programs to be attached to cgroup directories and invoked at specific kernel hook points for all tasks in the cgroup. This replaces several v1 controllers that implemented fixed policies (net_cls, net_prio, devices) with an open-ended mechanism: operators write BPF programs to express arbitrary custom policy. The kernel guarantees the attachment semantics (which hook fires, what context the program receives, how programs from ancestor cgroups compose); the policy logic is fully in userspace-compiled BPF bytecode.

## Mental Model

Think of cgroup BPF as a smart switchboard. Each hook point is a socket on the switchboard. Operators plug BPF programs into sockets at any level of the cgroup hierarchy. When a call comes in (a packet arrives, a device is opened), the switchboard routes it through all plugged-in programs from the most-specific cgroup up to the root. Each program can accept, modify, or reject the call. The switchboard never needs to know what the programs do — it just ensures they are called in order.

## How It Works

### Program attachment

A BPF program is attached to a cgroup using the `bpf(BPF_PROG_ATTACH, ...)` syscall. The call takes three arguments: the cgroup file descriptor, the program file descriptor, and the attach type (e.g. `BPF_CGROUP_INET_INGRESS`, `BPF_CGROUP_DEVICE`). The kernel stores the program reference in `cgroup->bpf.progs[attach_type]`.

`attach_flags` controls inheritance:
- `BPF_F_ALLOW_OVERRIDE` — descendants may replace this program with their own. If a descendant has no program, the ancestor's runs. Used for default-deny policies that containers can override.
- `BPF_F_ALLOW_MULTI` — descendants may stack additional programs on top. All programs in the hierarchy run in order. Used for per-layer monitoring or filtering.
- Neither flag (default) — the program is effective only for this exact cgroup; descendants inherit it if they have no program of their own but cannot stack.

### Effective program arrays

When a program is attached or detached, `cgroup_bpf_prog_attach()` rebuilds the *effective* program arrays for the cgroup and all its descendants. The effective array for a cgroup is the ordered list of programs that will run for that cgroup, considering all ancestor programs under the specified `attach_flags`. This precomputed array is stored in `cgroup->bpf.effective[attach_type]` and is RCU-protected.

At runtime, hook sites call `BPF_CGROUP_RUN_PROG_*()` macros. These macros:
1. Load the current cgroup's effective program array via RCU.
2. Loop through each program, calling `bpf_prog_run()`.
3. If any program returns a "deny" value (program-type specific), the operation is rejected.

Because the effective array is precomputed and accessed under RCU, the common (no programs attached) case reduces to a single null pointer check. The hot path overhead is negligible for cgroups with no BPF programs.

### Program types and their hook points

**Network programs** — allow per-cgroup network policy without requiring network namespaces:
- `BPF_PROG_TYPE_CGROUP_SKB` — called on every packet sent or received by a socket owned by a task in the cgroup; the program can inspect or drop packets. Replaces `net_cls` and `net_prio`.
- `BPF_PROG_TYPE_CGROUP_SOCK` — called at socket creation; can restrict what families/types/protocols a cgroup's tasks may create.
- `BPF_PROG_TYPE_CGROUP_SOCK_ADDR` — called at `bind()`, `connect()`, `sendto()`; can rewrite addresses (transparent proxy use case).
- `BPF_PROG_TYPE_CGROUP_SOCKOPT` — called at `getsockopt()`/`setsockopt()`; can intercept socket options.

**Device access** — `BPF_PROG_TYPE_CGROUP_DEVICE` is called at every `open()` of a device file. The program receives the device type, major, minor, and access mode; it returns 0 to deny or 1 to allow. This replaces the v1 `devices` cgroup controller with a more expressive mechanism. Modern container runtimes (runc 1.0+) use this instead of the old devices controller.

**Sysctl** — `BPF_PROG_TYPE_CGROUP_SYSCTL` is called at sysctl read/write; allows per-container sysctl namespacing without full sysctl namespace isolation.

### Local storage

BPF programs may allocate per-cgroup local storage using `bpf_get_local_storage()`. This provides a persistent key-value map scoped to the (program, cgroup) pair, allowing stateful programs (e.g. tracking per-container connection counts across multiple packet arrivals).

### Detachment

`bpf(BPF_PROG_DETACH, ...)` removes a program. The kernel rebuilds all affected effective arrays and releases the program reference. Because the effective arrays are RCU-protected, in-flight executions complete safely; the program object is freed only after a grace period.

## Key Data Structures

**`struct cgroup_bpf`** (`include/linux/bpf-cgroup.h`) — BPF state embedded in every `struct cgroup`
- `effective[MAX_BPF_ATTACH_TYPE]` — per-attach-type RCU-protected arrays of programs to run; this is the hot-path lookup table
- `progs[MAX_BPF_ATTACH_TYPE]` — locally attached programs (not including inherited ones)
- `flags[MAX_BPF_ATTACH_TYPE]` — inheritance flags per attach type
- `storages` — per-program local storage references

**`struct bpf_prog_array`** (`include/linux/bpf.h`) — the precomputed list of programs for a given hook; accessed via RCU
- `items[]` — array of `{prog, cgroup_storage}` pairs; terminated by a NULL entry

## Key Functions / Entry Points

**`cgroup_bpf_prog_attach()`** (`kernel/bpf/cgroup.c`) — attaches a program; validates flags, stores in `cgroup->bpf.progs`, rebuilds effective arrays for subtree

**`cgroup_bpf_prog_detach()`** (`kernel/bpf/cgroup.c`) — removes a program; rebuilds effective arrays

**`cgroup_bpf_inherit()`** (`kernel/bpf/cgroup.c`) — called when a new cgroup is created; inherits effective arrays from parent

**`BPF_CGROUP_RUN_PROG_INET_INGRESS()` / `BPF_CGROUP_RUN_PROG_DEVICE()`** etc. — macros in `include/linux/bpf-cgroup.h`; expand to the effective-array lookup and program execution loop at each hook site

## Important Flags & Config Options

- `CONFIG_CGROUP_BPF` — enables cgroup BPF infrastructure; required for all cgroup BPF features
- `BPF_F_ALLOW_OVERRIDE` — attachment flag; descendant may replace ancestor program
- `BPF_F_ALLOW_MULTI` — attachment flag; descendant programs stack on top of ancestor programs
- Attach types: `BPF_CGROUP_INET_INGRESS`, `BPF_CGROUP_INET_EGRESS`, `BPF_CGROUP_DEVICE`, `BPF_CGROUP_SOCK_OPS`, `BPF_CGROUP_SYSCTL`, and many more

## Interactions with Other Subsystems

- **↑ Userspace**: container runtimes load BPF programs with `bpf(BPF_PROG_LOAD)` and attach them with `bpf(BPF_PROG_ATTACH)`; bpftool and libbpf are the standard toolchain
- **→ [[bpf]]**: uses the BPF verifier, JIT compiler, and program type framework; cgroup BPF programs are verified like any other BPF program
- **→ Network stack**: `BPF_CGROUP_RUN_PROG_INET_INGRESS/EGRESS` is called in `ip_rcv()` and `ip_output()` for every packet
- **← [[cgroup-core]]**: `cgroup_bpf_inherit()` is called by `cgroup_mkdir`; `cgroup_bpf_offline()` is called by `cgroup_rmdir`

## Design Decisions & Tradeoffs

**Replacing fixed controllers with BPF** was chosen because the old devices, net_cls, and net_prio controllers had fixed, inflexible policy models. A container that needed "allow /dev/null and /dev/zero but deny everything else" required writing to multiple files with specific semantics. A BPF program can express this in a few instructions and can be updated without changing kernel code.

The tradeoff is complexity: operators need BPF tooling and knowledge to configure cgroup BPF policy, whereas the old controllers were simple file writes. Production container runtimes abstract this (runc handles the BPF program lifecycle transparently), but debugging cgroup BPF policy is harder than reading a devices.list file.

**Precomputed effective arrays** solve the ancestry traversal problem. A naive implementation would walk from the task's cgroup to the root on every hook invocation (e.g. every packet), which is O(depth). By precomputing and caching the ordered list, hook invocations are O(programs_at_this_level) — typically O(1) or O(2). The cost is rebuilding the arrays on every program attach/detach, which is amortized over potentially millions of packet events.

**RCU protection** for effective arrays allows lockless reads on the hot path. The attach/detach path holds `cgroup_mutex` while rebuilding; the read path takes an RCU read lock, which is essentially free.

## How It Has Evolved

- **4.10 (2017)** — initial cgroup BPF support: `BPF_PROG_TYPE_CGROUP_SKB` for network filtering and `BPF_PROG_TYPE_CGROUP_SOCK` for socket control
- **4.15 (2018)** — `BPF_PROG_TYPE_CGROUP_DEVICE` added; v1 devices controller use cases can migrate to BPF
- **4.17 (2018)** — `BPF_PROG_TYPE_CGROUP_SOCK_ADDR` added; transparent proxy support
- **5.2 (2019)** — `BPF_PROG_TYPE_CGROUP_SYSCTL` added; per-container sysctl policy
- **5.9 (2020)** — multi-prog support (`BPF_F_ALLOW_MULTI`) extended to more attach types; cgroup local storage stabilized

## Further Reading

1. [Add eBPF hooks for cgroups — LWN.net](https://lwn.net/Articles/697462/)
2. [Control Group v2: BPF Device Controller — kernel.org](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html#device-controller)
3. [BPF cgroup programs — Cilium docs](https://docs.cilium.io/en/latest/bpf/)

## LKML Highlights

- **`20170131003108.762627-1-ast@kernel.org`** — Alexei Starovoitov's original patch adding eBPF hooks for cgroup socket filtering; the thread established the `BPF_F_ALLOW_OVERRIDE` / `BPF_F_ALLOW_MULTI` semantics still in use today
