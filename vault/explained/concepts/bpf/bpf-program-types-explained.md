---
title: "BPF Program Types — Explained"
category: explained
original: "[[bpf-program-types]]"
subsystem: bpf
tags: [explained, bpf, program-types, xdp, sched-ext]
converted: 2026-09-25
---

# BPF program types, explained

> Plain-language companion to [[bpf-program-types|the technical note]]. Same facts, fewer identifiers.

## The problem

A BPF program can run in wildly different places: inside a network driver as a packet arrives, at the entry of an arbitrary kernel function, at a security checkpoint, or as the brain of the CPU scheduler. Each place hands the program different data and expects a different kind of answer.

The verifier has to check a program *before* it knows where it will run. So it needs to be told up front: what will this program receive, which kernel functions may it call, and what does its return value mean? Without that, a tracing program could call a packet-redirect function and corrupt the network stack.

## The idea in one paragraph

Every BPF program is loaded with a **type**, which works like a contract: "I'll be called from this kind of hook, with this kind of input; I may only call these kernel functions; my return value means this." The verifier enforces the contract at load time. Attaching the program to a specific hook (this network card, that kernel function, this cgroup) is a separate step, and each hook family has its own attach mechanism.

## Step by step

### Step 1: Each type supplies two rules to the verifier
A program type provides the verifier with two checks:
- **Which kernel functions are allowed.** For each call, the verifier asks the type, and gets either the function's description or "not allowed here".
- **Which parts of the input may be touched.** The input (the *context*) is a structure: packet boundaries for a network program, saved CPU registers for a probe. The type says which fields may be read or written, at what sizes. It can also silently rewrite those accesses to match the kernel's real internal layout, so programs see a stable view.

### Step 2: Load with a type
When you load a program, you name its type. The kernel picks that type's rules, runs the verifier with them, and compiles the program to native code.

### Step 3: Attach to a specific hook
Loading doesn't make the program run. Attaching does, and each family has its own route: networking configuration for XDP, the traffic-control tool for TC, the perf-events interface for probes and tracepoints, a cgroup attach call for cgroup programs. Newer kernels use a common **link** object, which holds the program attached and can be pinned so the program keeps running after the loading process exits.

### Step 4: Run on every event
At the hook, the kernel calls the program's compiled code with the context, then acts on the return value according to the contract.

## The major types

**Socket filter (3.18).** The original: attached to a socket, sees every received packet, returns how many bytes to keep (0 means drop). Used by packet-capture tools and seccomp.

**Kprobe and function entry/exit (4.1, 5.5).** Attached to almost any kernel function, receiving the CPU's register state at that point. The return value is ignored; these programs observe. The later *fentry/fexit* variants attach through a small generated trampoline, which is cheaper than a kprobe and gives direct access to the function's arguments.

**Tracepoint (4.7).** Attached to fixed trace points built into the kernel. The input layout is exactly known, so it's safer and more stable than probing arbitrary functions.

**XDP (4.8).** Runs at the earliest possible moment, inside the network driver, before the kernel has even built its usual packet structure. It returns pass (continue normally), drop (the fast path for DDoS defence), transmit (bounce back out the same card), redirect (to another card or CPU), or aborted (an error). It can run natively in the driver (fastest), offloaded onto a smart NIC, or in a slower generic mode as a fallback.

**Traffic control (4.1).** Runs later in the network stack on full packets and returns a traffic-control verdict: continue, redirect, or drop. Used for load balancing, rate policing and packet rewriting in cloud networks.

**Cgroup (4.10).** Attached to a control group, sees all network traffic from processes in it. Per-container network policy without iptables overhead.

**Perf event (4.9).** Triggered by hardware counters or timers. The basis of sampling profilers.

**Security (LSM) (5.7).** Attached to the kernel's security checkpoints. Returns 0 to allow or an error to deny. Unlike SELinux or AppArmor, these policies are loaded dynamically and can be combined.

**Socket-map programs (4.14).** A *parser* finds message boundaries in a stream and a *verdict* program picks which socket each message goes to, implementing an in-kernel application proxy.

**struct_ops (5.6).** A type for implementing a whole *table* of kernel callbacks, such as a TCP congestion-control algorithm. Each BPF program fills one slot in the table, and the verifier uses the kernel's type information to check each against its slot's signature.

## sched_ext: the biggest struct_ops user

This is the most striking use of program types. Since 6.12, BPF can replace the CPU scheduler's policy.

1. A BPF program fills in scheduling callbacks: pick a CPU for a waking task, enqueue it, dispatch work to a CPU.
2. It never touches the kernel's internal run queues. Instead, it moves tasks through **dispatch queues**: a shared global one, a per-CPU local one, or its own. The kernel then does the real run-queue work. That decoupling lets kernel developers change run-queue internals without breaking BPF schedulers.
3. A **watchdog** watches for tasks left runnable too long without running. If it fires, the kernel unloads the BPF scheduler and falls back to the normal one. That safety net is what makes experimental schedulers deployable in production (Valve's Steam Deck, Meta, Google).

## The picture

```text
                  program TYPE = contract
   ┌─────────────────────────────────────────────────────┐
   │ input: packet window | CPU registers | trace record │
   │ allowed calls: networking | tracing | security ...  │
   │ return means: pass/drop | allow/deny | ignored      │
   └─────────────────────────┬───────────────────────────┘
               load: verifier checks against contract
                             │
               attach (per-family mechanism, or a "link")
     ┌──────────┬────────────┼────────────┬─────────────┐
     ▼          ▼            ▼            ▼             ▼
  network    traffic      kernel      security     scheduler
  driver     control      function    checkpoint   callbacks
  (XDP)      (TC)         (probe)     (LSM)        (struct_ops)
```

## Tradeoffs

- **What it gives you:** the verifier can prove, at load time, exactly what each program may do at its hook.
- **What it costs / requires:** there are now 30+ types, each with its own rules. struct_ops is the escape valve: a new callback table only needs type annotations, not changes to the BPF core. But struct_ops programs must supply every slot, and type-checking them is more complex.
- **Where it bites:** confusing "loaded" with "running". A program only runs once attached, and it stops when its last attachment (or link) goes away.

## How it got here

- **3.18 (2014):** socket filters and traffic-control classifiers.
- **4.1–4.8 (2015–2016):** kprobes and tracepoints for tracing, then XDP, which transformed DDoS mitigation.
- **4.10 (2017):** cgroup and perf-event programs.
- **5.5–5.7 (2020):** cheaper function entry/exit hooks, struct_ops (first for TCP congestion control), and security programs.
- **6.12 (2024):** sched_ext merged; in production at Valve, Meta and Google.

## Related

- Technical version: [[bpf-program-types]]
- [[bpf-explained|BPF overview]]
- [[bpf-verifier-explained|The verifier]]: enforces each type's contract
- [[bpf-helpers-and-kfuncs-explained|Helpers and kfuncs]]: the per-type function menus
- [[xdp-explained|XDP]], [[net-explained|networking]], [[security|security]], [[scheduler|scheduler]], [[cgroups-explained|cgroups]]
