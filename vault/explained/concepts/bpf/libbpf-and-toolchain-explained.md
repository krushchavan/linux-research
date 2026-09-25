---
title: "libbpf and the BPF Toolchain — Explained"
category: explained
original: "[[libbpf-and-toolchain]]"
subsystem: bpf
tags: [explained, bpf, libbpf, bpftool, toolchain]
converted: 2026-09-25
---

# libbpf and the BPF toolchain, explained

> Plain-language companion to [[libbpf-and-toolchain|the technical note]]. Same facts, fewer identifiers.

## The problem

The kernel offers one system call for everything BPF: create maps, load programs, attach them, query them. It's powerful but very low-level. To load one program you must pack bytecode, type information, relocation records and map handles into a single structure, and then cope with the fact that different kernel versions support different features.

Doing this by hand takes about a hundred lines of fiddly code per application, and every application would reinvent it. Getting it wrong means confusing load failures.

## The idea in one paragraph

**libbpf** is the standard C library that does all of that plumbing, a bit like a loader and dynamic linker for BPF programs. You compile your BPF C code ahead of time with Clang into an ordinary object file. libbpf opens that file, figures out what's in it, creates the maps, fixes up addresses and field offsets for the running kernel, loads each program, and attaches it to the right hook. A code generator can go one step further and produce a typed header, so your userspace code handles the whole lifecycle in about three calls.

## Step by step

### Step 1: Compile ahead of time
You write the BPF program in C and compile it with Clang's BPF target into an object file. The file contains:
- **Programs**, each in a section whose *name* hints at its type and where to attach it (for example an XDP section, or a kprobe section naming a kernel function).
- **Map definitions**, declared as a C structure listing each map's kind, key size, value size and maximum entries.
- **Global variables**, which become a hidden array map that both the BPF program and userspace can read and write.
- **Type information** (BTF) and CO-RE relocation records.

### Step 2: Open: read the object file
libbpf parses the file and builds an in-memory list of the programs and maps it found. Nothing has touched the kernel yet.

### Step 3: Load: create, fix up, and load
This is the key step, where libbpf earns its keep:
1. **Create each map** in the kernel and remember its handle.
2. **Apply CO-RE fix-ups**: for each field access recorded at compile time, look up the field's real position in the running kernel's type information and patch the instruction. (Since 5.14 libbpf can instead hand these records to the kernel to apply.)
3. **Patch map references**: instructions that refer to a map contain placeholders, which are replaced with the real map handles.
4. **Load each program**, passing bytecode and type info. If the kernel rejects something because it lacks a feature, libbpf probes what's supported and retries with fallback code.

### Step 4: Attach, guided by section names
libbpf reads each program's section name and picks the matching attach mechanism: networking configuration for XDP and traffic control, the perf-events interface for kprobes and tracepoints, the cgroup attach call for cgroup programs, and a *link* for struct_ops.

That's a convention, not a kernel rule. The kernel only cares about the program's type. The convention is handy but has accumulated many special cases.

### Step 5: Keep it running with links and pins
Attachment produces a **link** object. While the link is held open, the program stays attached. Pinning the link (or a map, or a program) to a path in the BPF filesystem keeps it alive even after the process exits, and lets other processes open it by path. That's how long-running infrastructure such as Cilium keeps its programs in place across agent restarts.

### Step 6: Skeletons: typed access with no boilerplate
The `bpftool` tool can generate a *skeleton* header from the object file. It gives you one struct with typed fields for each map, program, link and global variable, plus open-and-load, attach and destroy functions.

Your userspace code then looks like: open-and-load, set a global variable as if it were a struct field, attach, run, read a counter back, destroy. All the handle juggling disappears. The catch: if the BPF program's maps change, you must regenerate and rebuild.

### Step 7: Inspect with bpftool
`bpftool` is the companion command-line tool. It lists loaded programs, disassembles their JIT output, dumps map contents nicely formatted using type information, shows which programs are attached to network interfaces, and dumps the kernel's entire type information as one C header. That header lets you write CO-RE programs without installing kernel headers at all.

## The picture

```text
  your_prog.bpf.c ──Clang──▶ your_prog.o (programs, maps, globals, BTF, relocs)
                                   │
                         bpftool gen skeleton ──▶ your_prog.skel.h (typed API)
                                   │
   ┌──────────────────────── libbpf ──────────────────────────┐
   │ OPEN   parse sections: programs, maps, globals, BTF      │
   │ LOAD   create maps ─▶ CO-RE fix-ups ─▶ patch map refs    │
   │        ─▶ load programs (probe + fallback on failure)    │
   │ ATTACH section name ─▶ XDP / kprobe / tracepoint / ...   │
   └─────────────────────────┬────────────────────────────────┘
                             ▼
                links (pin to BPF filesystem to outlive the process)
```

## Tradeoffs

- **What it gives you:** a small, standard way to load and manage BPF programs, portable across kernels thanks to CO-RE, and no runtime compiler needed on the target.
- **What it costs / requires:** skeletons are compile-time generated, so they're typed and IDE-friendly but tied to one program layout. Generic tools instead use untyped runtime lookups by name. Production tools like Cilium and bpftrace use skeletons.
- **Where it bites:** relying on section-name magic. It's a libbpf convention with many special cases, not a kernel contract, so a misnamed section means the wrong attach or none.

## How it got here

- **Early days:** BPF programs were hand-assembled as arrays of instructions in C.
- **4.x:** BCC made BPF popular with a Python front end, compiling C to BPF at run time with LLVM.
- **5.x:** libbpf with ahead-of-time Clang compilation replaced BCC as the preferred workflow, removing the run-time LLVM dependency.
- **5.5–5.8 (2020):** global variables, skeletons, and a ring-buffer reader in libbpf.
- **5.14 (2021):** kernel-side CO-RE.
- **6.x:** libbpf developed primarily in its own repository with independent releases, synced periodically into the kernel tree. Go, Rust and Python ecosystems wrap or reimplement the same load protocol.

## Related

- Technical version: [[libbpf-and-toolchain]]
- [[bpf-explained|BPF overview]]
- [[btf-and-co-re-explained|BTF and CO-RE]]: the fix-ups libbpf applies
- [[bpf-maps-explained|BPF maps]]: created during the load step
- [[bpf-verifier-explained|The verifier]]: checks what libbpf loads
- [[bpf-ring-buffer-explained|BPF ring buffer]]: libbpf provides its reader
