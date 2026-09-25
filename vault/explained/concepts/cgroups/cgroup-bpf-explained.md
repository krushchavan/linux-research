---
title: "Cgroup BPF — Explained"
category: explained
original: "[[cgroup-bpf]]"
subsystem: cgroups
tags: [explained, cgroups, bpf, policy, networking]
converted: 2026-09-25
---

# Cgroup BPF, explained

> Plain-language companion to [[cgroup-bpf|the technical note]]. Same facts, fewer identifiers.

## The problem

cgroup v1 had a few controllers that each enforced one fixed kind of policy: which device files a group may open, how to tag or prioritise its network traffic. Their policy models were rigid. Something like "allow /dev/null and /dev/zero, deny everything else" meant writing specific entries to several files with specific meanings, and anything the designers hadn't anticipated was impossible without changing the kernel.

Operators wanted to express *arbitrary* per-group policy for networking, devices and more, while paying almost nothing on paths that run for every packet or every device open.

## The idea in one paragraph

Let operators **plug small eBPF programs into hook points on a cgroup**. Think of a switchboard: each hook (a packet arriving, a device being opened) is a socket, and programs can be plugged in at any level of the cgroup tree. When a call comes in, it's routed through the plugged-in programs that apply to the caller's group, from the most specific up towards the root, and any one of them can reject it. The kernel only guarantees *which* hooks fire, *what* each program sees, and *how* programs from ancestor groups combine; the policy itself lives in the programs.

## Step by step

### Step 1: Attach a program
A program is attached with the `bpf` system call, given a cgroup, a loaded program and an attach type (for example, incoming packets or device access). Flags decide how it combines with descendants:
- **allow override:** a descendant may replace this program; if it has none, this one runs. Good for a default-deny policy containers can override.
- **allow multi:** descendants may stack more programs on top, and all of them run in order. Good for per-layer monitoring or filtering.
- **neither:** it applies to this group, and descendants without their own inherit it, but they can't stack.

### Step 2: Precompute who runs where
This is the key step. On every attach or detach, the kernel rebuilds each affected group's **effective list**: the ordered programs that should run for that group, taking every ancestor's programs and flags into account. It's rebuilt for the whole subtree and published under RCU. Building the list once means no walk up the tree is needed on each packet, only the list for the caller's group.

### Step 3: Run programs at the hook
At each hook, the kernel reads the caller's effective list under RCU and runs each program in turn; if any returns "deny", the operation is refused. With no programs attached, the whole thing reduces to one null-pointer check, so groups without policy pay essentially nothing. Rebuilding lists on attach is amortised over potentially millions of hook invocations.

### Step 4: The kinds of programs
- **Packet programs** run on every packet sent or received by the group's sockets, and can inspect or drop it (replacing the old traffic-tagging controllers).
- **Socket-creation programs** can restrict which families, types and protocols the group may create.
- **Address programs** run at bind, connect and send-to, and can rewrite addresses, for example for a transparent proxy.
- **Socket-option programs** intercept get and set socket options.
- **Device programs** run on every open of a device file, see its type, major and minor numbers and access mode, and allow or deny. They replace the v1 devices controller; modern container runtimes (runc 1.0+) use them.
- **Sysctl programs** run on sysctl reads and writes, giving per-container sysctl policy.

### Step 5: Keep state
Programs can keep **per-cgroup local storage**, a persistent map scoped to the (program, group) pair, so they can remember things across calls, such as counting a container's connections.

### Step 6: Detach safely
Detaching rebuilds the affected effective lists and drops the program. Because lists are read under RCU, calls already running finish safely, and the program is freed only after a grace period.

## The picture

```text
 root        [program A: allow multi]
  └ system   [program B]
     └ app   (nothing attached)

 effective list for "app" (rebuilt on attach/detach):  B, A
 packet from a task in "app" ─▶ run B ─▶ run A ─▶ any "deny"? drop : pass
 group with no programs ─▶ one null check, done
```

## Tradeoffs

- **What it gives you:** arbitrary, updatable per-group policy for networking, devices and sysctls without kernel changes and without network namespaces, with near-zero cost where unused.
- **What it costs / requires:** BPF tooling and know-how (bpftool, libbpf) instead of simple file writes; list rebuilding on every attach or detach.
- **Where it bites:** debugging policy is harder than reading the old devices list file. Container runtimes hide the program lifecycle, which helps until something goes wrong.

## How it got here

- **4.10 (2017):** packet filtering and socket-creation programs (Alexei Starovoitov), with the override and multi semantics still used today.
- **4.15 (2018):** device-access programs, the replacement for the v1 devices controller.
- **4.17 (2018):** address-rewriting programs for transparent proxies.
- **5.2 (2019):** sysctl programs.
- **5.9 (2020):** stacking extended to more attach types; per-cgroup local storage stabilised.

## Related

- Technical version: [[cgroup-bpf]]
- [[cgroups-explained|cgroups]], [[cgroup-core-explained|cgroup core]], [[bpf-explained|BPF]]
- [[rcu-read-copy-update|RCU]]
