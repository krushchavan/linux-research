---
title: "BTF and CO-RE"
category: concept
tags: [bpf, btf, co-re, portability, type-system, relocations]
subsystem: bpf
kernel_version: "4.18"
researched: 2026-04-16
status: complete
explained: "[[btf-and-co-re-explained]]"
sources:
  - https://lwn.net/Articles/875879/
  - https://lwn.net/Articles/909095/
  - https://www.kernel.org/doc/html/latest/bpf/btf.html
  - https://kernel-internals.org/bpf/
---

# BTF and CO-RE

> 📘 Plain-language version: [[btf-and-co-re-explained]]

## Purpose

A BPF program compiled against the header files of kernel 5.10 breaks on 5.15 if a struct field it accesses was renamed or moved. Without type information, the only fix is to ship the full kernel headers with each deployment and recompile the BPF program on the target machine. BTF (BPF Type Format) encodes the complete type graph of the running kernel into the kernel image itself, and CO-RE (Compile Once – Run Everywhere) uses that graph to automatically patch field offsets when a pre-compiled BPF binary is loaded — making a single ELF object run portably across kernel versions.

## Mental Model

BTF is the kernel's **self-describing type dictionary**: an efficient binary encoding of every struct, union, enum, and function signature in the running kernel. CO-RE is the **link-time relocation** pass for BPF: instead of hard-coding `offsetof(struct iphdr, protocol) = 9`, the compiler emits a relocation record saying "access field `protocol` of `struct iphdr`"; at load time the loader patches the offset to match the current kernel's BTF.

## How It Works

### BTF encoding

BTF is a compact binary format stored in the `.BTF` ELF section of the kernel image (and in BPF object files). It encodes types as an array of `struct btf_type` records, each followed by type-specific data:

- **`BTF_KIND_INT`**: integer type with bit-width and signedness.
- **`BTF_KIND_STRUCT` / `BTF_KIND_UNION`**: aggregate with a list of `struct btf_member` records (name offset, type ID, bit offset).
- **`BTF_KIND_ARRAY`**: element type + count.
- **`BTF_KIND_FUNC`** / **`BTF_KIND_FUNC_PROTO`**: function with prototype.
- **`BTF_KIND_VAR`**: global variable.
- **`BTF_KIND_DECL_TAG`** / **`BTF_KIND_TYPE_TAG`**: annotations used to mark kfunc ownership semantics (`__kptr`, `__kptr_ref`, `__trusted`, etc.).
- **`BTF_KIND_LAYOUT`** (7.1, Alan Maguire): encodes unknown BTF kinds' size so future kernels can skip them gracefully.

At boot, `btf_parse_vmlinux()` reads the `.BTF` section, validates it, and stores the result as `btf_vmlinux` — a globally accessible `struct btf *`. User programs access it via `/sys/kernel/btf/vmlinux` (a read-only file exposing the raw bytes) or through the `BPF_BTF_GET_FD_BY_ID` syscall command.

Split BTF (introduced for kernel modules) allows each module to carry its own `.BTF` section referencing the vmlinux BTF as a base, without duplicating all type definitions. `btf__add_btf()` in libbpf merges split BTFs; kernel 7.1 extended this to support multiple module BTFs in bpftool.

### CO-RE: compile-side

When Clang compiles a BPF C source with `bpf_core_read(dst, size, src)` or `__builtin_preserve_access_index()`, it:
1. Records the field access chain (e.g. `task->mm->flags`) in the `.BTF.ext` ELF section as a `bpf_core_relo` record.
2. Emits the BPF instruction with the offset computed from the *compilation-time* kernel headers.
3. Associates the instruction with the relocation record by byte offset.

### CO-RE: load-side

libbpf's `bpf_object__load()` performs the relocation pass before calling `BPF_PROG_LOAD`:
1. Parse all `bpf_core_relo` records from `.BTF.ext`.
2. For each record, look up the named struct in the running kernel's BTF (obtained from `/sys/kernel/btf/vmlinux` or `BPF_BTF_GET_FD_BY_ID`).
3. Compute the field's actual `bit_offset` in the running kernel.
4. Patch the BPF instruction's immediate field with the correct offset.
5. If the field does not exist in the running kernel (struct was refactored), apply the `bpf_core_relo`'s existence check: programs can use `bpf_core_field_exists(struct_type, field)` to handle missing fields gracefully.

Since kernel 5.14, the kernel itself processes `struct bpf_core_relo` records passed in `bpf_attr.core_relo_cnt` / `bpf_attr.core_relos`. This allows languages that do not use libbpf (e.g. Go's `cilium/ebpf` package) to get CO-RE by passing relocation records directly to the kernel, without implementing the relocation algorithm themselves. The verifier log receives CO-RE debug/error messages via the standard log mechanism.

### BTF use by the verifier

Beyond CO-RE, the verifier uses BTF heavily:
- **kfunc type checking**: `check_kfunc_call()` resolves the callee's BTF type ID, walks its parameter types, and validates that the caller's arguments match.
- **Map type inference**: Maps with `btf_value_type_id` let the verifier infer `PTR_TO_MAP_VALUE` member types precisely.
- **kptr ownership**: Type tags (`__kptr`, `__kptr_ref`) embedded in struct BTF tell the verifier how to track pointer lifetimes in map values.
- **Function signatures for global subprogs**: BTF function prototypes let the verifier check callers at their call sites rather than re-verifying the callee body for each call.

## Key Data Structures

**`struct btf`** (`include/linux/btf.h`) — opaque reference-counted BTF object:
- `types[]` — array of `struct btf_type *` indexed by type ID
- `strings` — string table for names
- `base_btf` — pointer to base vmlinux BTF (for module split BTF)

**`struct btf_type`** (`include/uapi/linux/btf.h`) — one type record:
- `name_off` — offset into string table
- `info` — `BTF_INFO_KIND(kind) | BTF_INFO_VLEN(vlen)` packed word
- `size` / `type` — union: aggregate size or element type ID

**`struct bpf_core_relo`** (`include/uapi/linux/bpf.h`) — one CO-RE relocation:
- `insn_off` — byte offset of the BPF instruction to patch
- `type_id` — BTF type ID of the accessed struct
- `access_str_off` — "0:1:2" style accessor string (field indices)
- `kind` — `BPF_CORE_FIELD_BYTE_OFFSET`, `BPF_CORE_FIELD_EXISTS`, etc.

## Key Functions / Entry Points

**`btf_parse_vmlinux()`** (`kernel/bpf/btf.c`) — called at boot; reads `.BTF` section, validates, stores in `btf_vmlinux`.

**`btf_check_func_arg_match()`** — matches a kfunc call's argument list against the BTF function prototype.

**`bpf_core_apply_relo_insn()`** (`tools/lib/bpf/relo_core.c`) — libbpf side: applies one CO-RE relocation; shared code with the kernel since 5.14.

**`btf_type_by_id(btf, id)`** — retrieves a type by ID; `btf_name_by_offset(btf, name_off)` retrieves the name string.

## Important Flags & Config Options

- `CONFIG_DEBUG_INFO_BTF` — embeds BTF in the kernel image. Required for CO-RE. Built by `pahole --btf_encode` during `make`.
- `CONFIG_DEBUG_INFO_BTF_MODULES` — embeds per-module split BTF.
- `BPF_F_TOKEN_FD` (in progress) — future: associate a BPF token with prog/map creation to delegate BTF access permissions without `CAP_BPF`.
- `bpf_core_read(dst, sz, src)` macro — CO-RE-safe field read; expands to `__builtin_preserve_access_index`.

## Interactions with Other Subsystems

- **→ [[bpf-verifier]]**: kfunc type validation, kptr tracking, global subprog signature checking all go through BTF.
- **→ [[bpf-maps]]**: Map values annotated with BTF type IDs enable kptr storage and bpftool pretty-printing.
- **→ [[bpf-helpers-and-kfuncs]]**: Every kfunc is resolved by BTF ID; ownership annotations are BTF type tags.
- **↑ Userspace**: `/sys/kernel/btf/vmlinux` and `/sys/kernel/btf/<module>` expose BTF to libbpf and bpftool.

## Design Decisions & Tradeoffs

**BTF over DWARF** — DWARF is the standard debug format but is verbose and complex. BTF was purpose-built for BPF: it is simpler (no location expressions, no call-frame info), more compact (10× smaller than DWARF for equivalent type info), and embeddable in production kernels (`CONFIG_DEBUG_INFO_BTF` adds ~1–2 MB to the kernel image). The cost is that BTF is less expressive — it cannot encode everything DWARF can.

**Kernel-side CO-RE** — Moving CO-RE relocation into the kernel (5.14) was motivated by three needs: (1) enabling signed BPF programs (libbpf-processed programs would lose the signature), (2) supporting languages that cannot easily vendor libbpf, (3) better error reporting through the verifier log. The tradeoff is added kernel complexity and a new uAPI surface that must be maintained.

**Incremental BTF kinds** — New BTF kinds have been added over time (`DECL_TAG`, `TYPE_TAG`, `LAYOUT`). The `BTF_KIND_LAYOUT` addition in 7.1 solves the forward-compatibility problem: older libbpf versions can parse BTF files with unknown kinds by using the layout metadata to skip them, instead of failing.

## How It Has Evolved

- **4.18 (2018)**: BTF introduced; type metadata for map pretty-printing.
- **5.2 (2019)**: `.BTF.ext` for function info and line info; bpftool can show source lines.
- **5.8 (2020)**: CO-RE in libbpf; `bpf_core_read()` macro; `__builtin_preserve_access_index`.
- **5.13 (2021)**: kfunc BTF type checking in the verifier.
- **5.14 (2021)**: Kernel-side CO-RE (`bpf_core_relo` in `bpf_attr`).
- **5.15 (2021)**: `BTF_KIND_DECL_TAG` and `BTF_KIND_TYPE_TAG` for kptr annotations.
- **6.x**: Split BTF for kernel modules; kptr / kptr_ref / trusted pointer tracking.
- **7.1 (2026)**: `BTF_KIND_LAYOUT` for forward-compatible unknown kind handling (Alan Maguire).

## Further Reading

1. [bpf: CO-RE support in the kernel — LWN.net (2021)](https://lwn.net/Articles/875879/)
2. [BPF as a safer kernel programming environment — LWN.net (2022)](https://lwn.net/Articles/909095/)
3. [BPF Type Format (BTF) — kernel.org docs](https://www.kernel.org/doc/html/latest/bpf/btf.html)
