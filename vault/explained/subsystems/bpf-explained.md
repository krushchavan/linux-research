---
title: "BPF (eBPF) — Explained"
category: explained
original: "[[bpf]]"
subsystem: bpf
tags: [explained, bpf, ebpf, verifier, jit]
converted: 2026-09-25
---

# BPF (eBPF), explained

> Plain-language companion to [[bpf|the technical note]]. Same facts, fewer identifiers.

## The problem this subsystem solves

Sometimes you want to change what the kernel does: drop an attack packet at the network card, count every call to a kernel function, enforce a security rule, or even pick which task runs next on a CPU. Traditionally that meant writing a kernel module or patching the kernel, then recompiling and rebooting. A bug in that code can crash the machine or corrupt memory, because kernel code is trusted completely.

The tension: you want code that runs *inside* the kernel, at kernel speed, with no system-call overhead, but written by someone the kernel can't trust to get it right. BPF resolves this by checking the program *before* it ever runs, proving it can't loop forever, read out of bounds, or corrupt kernel state. Once it passes, it runs as native machine code with no runtime sandbox at all.

## The big picture

Think of BPF as a kernel extension bus. You write a small program in a restricted form of C, the compiler turns it into BPF bytecode, and you hand it to the kernel. The kernel inspects every possible path through it, compiles it to native code, and wires it to an event. Small shared data stores called *maps* are the mailboxes between the running program and userspace.

```text
 LOAD PATH (once)
  your C code ──▶ compiler ──▶ BPF bytecode ──▶ kernel
                                                  │
                         type info fix-ups (BTF / CO-RE)
                                                  │
                                    verifier: "is this provably safe?"
                                         │ yes              │ no ──▶ rejected
                                         ▼
                                  JIT: bytecode ──▶ native code
                                         │
                                   attach to a hook
                                         ▼
 RUN TIME (every event)
  packet arrives / function called / task wakes ──▶ program runs
                                                      │  ▲
                                                      ▼  │
                                                     MAPS  ◀──▶ userspace
                                                  (shared state, events)
```

## The pieces

### The verifier: the safety gatekeeper
See [[bpf-verifier]].

Without the verifier, arbitrary code running in the kernel could read past the end of a buffer, follow a stale pointer, or spin forever. The verifier proves, before a single instruction runs, that none of this can happen.

1. **Check the shape.** It first builds a graph of the program's control flow and rejects unreachable code and unbounded loops.
2. **Simulate every path.** It then walks each possible execution path instruction by instruction. Instead of real values, it tracks what it *knows* about each register: its kind (a plain number, a pointer to a map entry, a pointer to the stack, and so on), which bits are known and which are uncertain, and the minimum and maximum it could hold. For example, after loading one byte, it knows the top 56 bits are zero and the low 8 are unknown.
3. **Prove every memory access.** Before any read or write through a pointer, it must be able to prove the offset stays inside the object.
4. **Prune to stay fast.** Each branch doubles the paths to explore, which would be exponential. So the verifier remembers the states it has already proven safe at each point. If it arrives again with a state that is no looser than one it already checked, it skips it. Tracking which registers are never read again lets more states match.

Because of Spectre (2017–2019), the verifier also has to simulate *speculative* execution paths, something no comparable system does.

### Maps: the shared mailboxes
See [[bpf-maps]].

BPF programs run in interrupt or kernel context and can't make blocking system calls. Maps are the only structured way to share state between a program and userspace, or between programs.

1. Userspace asks the kernel to create a map. The kernel allocates the backing storage and returns a handle, which can also be pinned to a special filesystem so it outlives the process.
2. A BPF program looks up an entry and gets a pointer to the value. The verifier has already checked that the program checks for "not found" and stays in bounds.
3. Userspace reads and updates the same map through system calls.

Different map types fit different jobs: fixed arrays (fastest), hash tables, per-CPU versions that avoid locking for counters, least-recently-used hashes that evict old entries (good for connection tracking), longest-prefix-match tables for IP routing, tables of other programs for chaining, a ring buffer for streaming events, and socket maps for redirecting traffic between sockets.

### The JIT compiler: native speed
See [[bpf-jit-compiler-explained|bpf-jit-compiler]].

The bytecode interpreter is about 3× slower than native code and is itself a Spectre attack surface. So after verification, a per-architecture compiler translates bytecode into real machine instructions.

1. BPF's register set was designed to map almost one-to-one onto modern CPUs, including the standard calling convention for function arguments. Translation is mostly mechanical.
2. Calls to kernel helpers become direct calls to their addresses.
3. Large constants are scrambled at compile time (*constant blinding*) so an attacker can't smuggle chosen machine code into the image as "data".

It covers x86-64, arm64, arm32, ppc64, s390x, mips64, sparc64, arc and riscv64. A kernel option can remove the interpreter entirely.

### Program types: what a program is allowed to be
See [[bpf-program-types]].

A program's *type* fixes three things: what data it receives, which kernel functions it may call, and what its return value means. That's how the kernel stops a packet filter from calling a scheduler-only function.

Major families:
- **XDP**: runs in the network driver before the kernel's packet structure is even built. Returns pass, drop, redirect or transmit.
- **Traffic control**: runs later in the network stack, on full packets.
- **Tracing**: kprobes, tracepoints, entry/exit hooks and perf events. Return value ignored.
- **Cgroup**: allow or deny network or device access per container.
- **Socket redirection**, **security (LSM) hooks** that return allow/deny, and **struct_ops**, which lets BPF implement a whole table of kernel callbacks.

The biggest struct_ops user is **sched_ext** (6.12+), which lets a BPF program replace the CPU scheduling policy.

### Helpers and kfuncs: the approved kernel API
See [[bpf-helpers-and-kfuncs-explained|bpf-helpers-and-kfuncs]].

The verifier can't reason about arbitrary kernel functions, so programs may only call a curated set.

1. **Helpers** are the original, *stable* API: map lookups, a cheap clock, packet redirection, ring-buffer writes, spinlocks. Each one declares what argument types it accepts, and once released its signature is frozen forever. That caused a pile-up of near-duplicate helpers.
2. **kfuncs** are the newer answer: ordinary kernel functions marked as callable, with **no stability promise**. The verifier checks calls using the kernel's own type information, which lets it enforce richer rules, such as "this pointer must be a trusted task pointer, not any number".

### BTF and CO-RE: one binary, many kernels
See [[btf-and-co-re]].

Kernel data structures change layout between versions, so a program compiled for one kernel reads the wrong field on another.

1. The kernel embeds a compact description of all its types, called **BTF**.
2. The compiler records, next to each field access, *which* struct and field it meant.
3. At load time the loader looks up the field's real position in the running kernel's BTF and patches the program. This is **CO-RE**, "compile once, run everywhere". Since 5.14 the kernel can do this patching itself, for loaders that don't use the standard library.

BTF also lets tools pretty-print map contents and lets the verifier type-check kfunc calls.

### The ring buffer: streaming events out
See [[bpf-ring-buffer]].

Tracing tools push huge numbers of events to userspace. The older mechanism gave each CPU its own buffer, which wasted memory and forced readers to poll every CPU.

1. The BPF ring buffer is one shared buffer that userspace maps read-only into its own memory.
2. A program *reserves* a slot (the only step that takes a lock), fills it in place, then *commits* or *discards* it. The verifier guarantees every reserved slot is eventually committed or discarded.
3. Userspace waits with epoll and reads records directly from the shared pages. Nothing is copied.
4. Wakeups can be batched so a sleeping reader isn't woken for every single event. A reverse variant lets userspace send data *to* BPF.

### libbpf and tools: the plumbing
See [[libbpf-and-toolchain]].

The raw system call needs bytecode, type info, relocation records and map handles packed into one structure. libbpf is the standard library that does this.

1. It opens the compiled object file and finds programs, maps and attach hints.
2. It creates the maps, applies CO-RE fix-ups, loads each program, and attaches it through whatever mechanism the hook needs.
3. A *skeleton* generator produces a typed header so your userspace code can open, load, attach and tear down with a few calls.

`bpftool` is the companion command-line tool for listing programs, dumping maps and type info, and viewing JIT output.

## A request's journey

Dropping attack traffic at the network card with XDP:

1. **Compile.** Clang turns the C program into bytecode, noting that it reads the "protocol" field of the IP header.
2. **Open.** libbpf parses the object file and finds one XDP program and one hash map (of blocked source addresses).
3. **Create the map.** The kernel allocates the hash table and returns a handle.
4. **Fix up and load.** libbpf reads the running kernel's type info, patches the field offset, and loads the program. The verifier proves every map access is in bounds and that only XDP-allowed helpers are called. The JIT compiles it.
5. **Attach.** The network driver installs the program as its receive hook.
6. **Run.** For every incoming packet, the driver calls the program. It reads the source IP, looks it up in the map, and returns "drop" or "pass", all before the kernel has allocated its usual packet structure.

## Tradeoffs

- **What it gives you:** kernel-speed extensions with no recompile or reboot, and a safety proof up front, so the running program has zero sandbox overhead (unlike WebAssembly's runtime checks).
- **What it costs / requires:** the verifier is large and complex, and its bugs are security holes. Every relaxation (loops, function calls, iterators) made it more complex. It grew to about 30,000 lines before being split up in 7.1. Programs must be written in a way the verifier can prove safe.
- **Where it bites:** kfunc-based programs can break across kernel versions, which is fine for in-tree tools and painful for third-party ones. And BPF is a powerful kernel-read tool, so it's privileged: unprivileged BPF is off by default on most distributions, and loading programs needs dedicated capabilities.

## How it got here

- **Before 3.18:** "classic" BPF, two 32-bit registers, only for packet filtering (tcpdump).
- **3.18 (2014):** Alexei Starovoitov's eBPF redesign: eleven 64-bit registers, the bpf() system call, maps, and an x86-64 JIT.
- **4.16–5.3 (2018–2019):** function calls between BPF programs, then bounded loops the verifier can prove terminate.
- **5.8–5.15 (2020–2021):** the ring buffer, security hooks and sleepable programs, kernel-side CO-RE, and splitting BPF privileges out of the catch-all admin capability after Spectre.
- **6.12 (2024):** sched_ext merged, letting BPF replace the scheduler.
- **7.1 (2026):** the verifier split into several files; a static stack-liveness analysis roughly halves verification time on complex programs; new maintainers.

## Related

- Technical version: [[bpf]]
- [[bpf-verifier|The verifier]], [[bpf-maps|maps]], [[bpf-jit-compiler-explained|the JIT]], [[bpf-program-types|program types]]
- [[bpf-helpers-and-kfuncs-explained|Helpers and kfuncs]], [[btf-and-co-re|BTF and CO-RE]], [[bpf-ring-buffer|the ring buffer]], [[libbpf-and-toolchain|libbpf]]
- [[xdp|XDP]]: the earliest networking hook
- [[net|Networking]], [[scheduler|scheduler]], [[security|security]], [[cgroups|cgroups]], [[tracing|tracing]]
