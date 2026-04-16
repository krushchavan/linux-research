---
title: "libbpf and BPF Toolchain"
category: concept
tags: [bpf, libbpf, bpftool, toolchain, skeleton, userspace]
subsystem: bpf
kernel_version: "4.x"
researched: 2026-04-16
status: complete
sources:
  - https://lwn.net/Articles/909095/
  - https://kernel-internals.org/bpf/
  - https://www.kernel.org/doc/html/latest/bpf/index.html
  - https://lwn.net/Articles/740157/
---

# libbpf and BPF Toolchain

## Purpose

The `bpf()` syscall is low-level: loading a program requires assembling a `union bpf_attr` with bytecode pointers, BTF blobs, relocation records, and map fds — then iterating over load failures to handle feature differences between kernel versions. Without an abstraction layer, every BPF application would reimplement this plumbing. libbpf is the canonical C library that handles ELF parsing, CO-RE relocations, map creation, program loading, and attachment, reducing a hundred lines of syscall machinery to three function calls.

## Mental Model

libbpf is the **build system + dynamic linker for BPF programs**. `bpf_object__open()` is the equivalent of parsing an ELF executable's section headers; `bpf_object__load()` is the equivalent of `execve()` loading segments and resolving relocations; `bpf_program__attach()` is the equivalent of calling `mmap()` to wire the program to an event. The *skeleton* workflow autogenerates typed C wrappers that make map and global variable access feel like ordinary struct field access.

## How It Works

### ELF parsing phase (`bpf_object__open`)

libbpf reads the `.o` ELF produced by Clang's BPF backend. It discovers:
- **Programs** from sections named `xdp/`, `kprobe/`, `tp/`, `tc/`, `lsm/`, `struct_ops/`, etc. The section name encodes the program type and attachment point.
- **Maps** from the `.maps` section: a C struct whose fields name maps with attributes (`type`, `key_size`, `value_size`, `max_entries`). Macros like `BPF_MAP_DEF` expand these.
- **Global variables** from `.bss`, `.data`, `.rodata` sections — mapped to a hidden `BPF_MAP_TYPE_ARRAY` accessible from both BPF and userspace.
- **BTF** from `.BTF` and `.BTF.ext` — type info and CO-RE relocation records.

### Load phase (`bpf_object__load`)

1. **Create maps**: For each discovered map, call `BPF_MAP_CREATE`. The map fd is stored in the `bpf_map` object.
2. **Apply CO-RE relocations**: For each `bpf_core_relo` in `.BTF.ext`, query the running kernel's BTF, compute the correct field offset, and patch the BPF instruction's immediate. Since kernel 5.14, libbpf can alternatively pass relocation records to the kernel to process there.
3. **Fix up map references**: BPF instructions that reference maps contain placeholder immediate values; libbpf replaces them with the actual map fds.
4. **Load programs**: Call `BPF_PROG_LOAD` for each program, passing bytecode, BTF, and relocation records. If the load fails due to a verifier rejection, libbpf retries with a backward-compatible feature probe and fallback bytecode.

### Attach phase (`bpf_program__attach`)

libbpf uses the section name heuristic to choose the attachment mechanism:
- `xdp/` → `bpf_xdp_attach()` (netlink)
- `kprobe/` → `perf_event_open(PERF_TYPE_TRACEPOINT)` + `PERF_EVENT_IOC_SET_BPF`
- `tp/` → `perf_event_open` with tracepoint id from `/sys/kernel/tracing/events/`
- `tc/` → netlink with `tcf_bpf`
- `cgroup/` → `BPF_PROG_ATTACH`
- `struct_ops/` → `BPF_LINK_CREATE` with `bpf_link` pinning

`bpf_link_create()` wraps the program + attachment into a `bpf_link` object. The link holds a reference to the program; as long as the link fd is open, the program stays attached. Pinning the link to bpffs (`/sys/fs/bpf/<path>`) persists the attachment beyond the creating process's lifetime.

### Skeleton workflow

`bpftool gen skeleton <prog.o> > prog.skel.h` generates a header that includes:

```c
struct prog_bpf {
    struct { int my_map_fd; } maps;
    struct { struct bpf_program *xdp_prog; } progs;
    struct { struct bpf_link *xdp_prog; } links;
    struct prog_bpf__bss { __u64 counter; } *bss;
};

struct prog_bpf *prog_bpf__open_and_load(void);
int prog_bpf__attach(struct prog_bpf *skel);
void prog_bpf__destroy(struct prog_bpf *skel);
```

Userspace code:
```c
struct prog_bpf *skel = prog_bpf__open_and_load();
skel->bss->counter = 0;   // set global variable
prog_bpf__attach(skel);
// ... event loop ...
printf("%llu\n", skel->bss->counter);
prog_bpf__destroy(skel);
```

The skeleton eliminates all manual `bpf_object`, map fd, and attach-type boilerplate.

### bpftool

`bpftool` is the kernel-provided CLI tool for BPF introspection and management:
- `bpftool prog show` — list loaded programs with type, id, jited size, map ids.
- `bpftool prog dump jited id <id>` — disassemble JIT image using arch's disassembler.
- `bpftool map dump id <id>` — dump map contents with BTF pretty-printing.
- `bpftool btf dump file /sys/kernel/btf/vmlinux format c` — dump kernel BTF as C headers (used to generate `vmlinux.h` for CO-RE-based programs that don't need the full kernel headers).
- `bpftool gen skeleton` — generate skeleton header.
- `bpftool net show` — list TC and XDP programs attached to interfaces.

### bpffs (BPF filesystem)

Mounted at `/sys/fs/bpf`, bpffs provides persistent identifiers for BPF objects. Programs, maps, and links can be pinned to paths here; other processes can open them by path via `BPF_OBJ_GET`. This is how long-running BPF infrastructure (e.g. Cilium's per-endpoint programs) survives agent restarts.

## Key Data Structures

**`struct bpf_object`** (`tools/lib/bpf/libbpf_internal.h`) — opaque; contains:
- `programs` — list of `struct bpf_program`
- `maps` — list of `struct bpf_map`
- `btf` — parsed BTF from the object file
- `btf_vmlinux` — running kernel's BTF (fetched once, cached)
- ELF parse state (section headers, relocation sections)

**`struct bpf_program`** — one BPF program within the object:
- `type` — `enum bpf_prog_type`
- `expected_attach_type` — `enum bpf_attach_type`
- `insns` — `struct bpf_insn *` array (BPF bytecode)
- `fd` — fd returned by `BPF_PROG_LOAD`

**`struct bpf_map`** — one map within the object:
- `def` — `struct bpf_map_def` with type/size/flags
- `fd` — fd returned by `BPF_MAP_CREATE`
- `btf_key_type_id` / `btf_value_type_id`

## Key Functions / Entry Points

**`bpf_object__open_file(path, opts)`** — parse ELF; return `struct bpf_object *`.

**`bpf_object__load(obj)`** — create maps, relocate, load programs; return 0 or -errno.

**`bpf_program__attach(prog)`** — auto-attach using section name heuristic; return `struct bpf_link *`.

**`bpf_ring_buffer__new(map_fd, sample_cb, ctx, flags)`** — create ring buffer consumer.

**`bpf_ring_buffer__poll(rb, timeout_ms)`** — consume ring buffer records; call `sample_cb` per record.

**`bpf_object__find_map_by_name(obj, name)`** — look up a map within a loaded object for manual fd access.

## Important Flags & Config Options

- `libbpf_set_strict_mode(LIBBPF_STRICT_ALL)` — enables all strict-mode checks (rejects legacy section name formats, enforces API correctness).
- `BPF_F_TEST_RND_HI32` — in `bpf_prog_load` opts; randomizes upper 32 bits of 64-bit registers to catch programs that depend on undefined zero-extension.
- `vmlinux.h` — a self-contained C header generated by `bpftool btf dump ... format c`; allows BPF C source to access any kernel type without installing kernel headers.

## Interactions with Other Subsystems

- **→ [[bpf-verifier]]**: libbpf passes the bytecode + BTF + relocation records to `BPF_PROG_LOAD`; the verifier processes them.
- **→ [[btf-and-co-re]]**: CO-RE relocation is libbpf's core value-add; it queries the kernel's BTF and patches offsets before loading.
- **→ [[bpf-maps]]**: libbpf creates maps via `BPF_MAP_CREATE`, wires fd references into bytecode.
- **↑ Userspace**: libbpf is a C library; Go (cilium/ebpf), Rust (aya), Python (bcc) all wrap or re-implement the same load protocol.

## Design Decisions & Tradeoffs

**Skeleton as codegen vs. runtime introspection** — The skeleton approach generates typed accessors at compile time, making map access safe and IDE-friendly, but requires a rebuild if the BPF program changes its map structure. Runtime-introspection APIs (`bpf_object__find_map_by_name`) work with any program but are untyped. Production tools (Cilium, bpftrace) use skeletons; generic infrastructure tends to use runtime APIs.

**libbpf as in-kernel → out-of-tree** — libbpf was originally maintained only in the kernel tree (`tools/lib/bpf/`). A mirror at `github.com/libbpf/libbpf` is now the primary development location, with periodic syncs into the kernel tree. This allows libbpf releases to be decoupled from kernel releases and makes it easier for userspace projects to pin a specific libbpf version.

**Section names as attachment hints** — Using ELF section names (`xdp/`, `kprobe/tcp_sendmsg`) to encode attachment type is a convention, not a kernel requirement. The kernel only cares about `prog_type` in `bpf_attr`. libbpf's section-name heuristic is convenient but has accumulated many special cases over time.

## How It Has Evolved

- **Early BPF**: Programs hand-assembled in C arrays; no library support.
- **4.x**: BCC (BPF Compiler Collection) popularized Python-fronted BPF; compiles C to BPF at runtime using LLVM.
- **5.x**: libbpf + Clang offline compilation replaced BCC as the preferred workflow; avoids runtime LLVM dependency.
- **5.5 (2020)**: Global variables via hidden arrays; skeleton workflow introduced.
- **5.8 (2020)**: Ring buffer consumer in libbpf.
- **5.14 (2021)**: Kernel-side CO-RE; libbpf can pass relocation records to kernel.
- **6.x**: libbpf out-of-tree development; independent versioning (`libbpf_version.h`).
- **7.1 (2026)**: `bpf_program__clone()` API for loading program variants with different attach BTF IDs; libbpf starts v1.8 development cycle.

## Further Reading

1. [A thorough introduction to eBPF — LWN.net (2017)](https://lwn.net/Articles/740157/)
2. [BPF as a safer kernel programming environment — LWN.net (2022)](https://lwn.net/Articles/909095/)
3. [libbpf docs — kernel.org](https://www.kernel.org/doc/html/latest/bpf/libbpf/index.html)
