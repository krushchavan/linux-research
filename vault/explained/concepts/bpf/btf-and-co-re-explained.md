---
title: "BTF and CO-RE — Explained"
category: explained
original: "[[btf-and-co-re]]"
subsystem: bpf
tags: [explained, bpf, btf, co-re, portability]
converted: 2026-09-25
---

# BTF and CO-RE, explained

> Plain-language companion to [[btf-and-co-re|the technical note]]. Same facts, fewer identifiers.

## The problem

Tracing programs constantly read kernel data structures: "give me this task's memory descriptor, then its flags". In compiled code that becomes "read 8 bytes at offset 1,184 from this pointer". The offset comes from the kernel headers the program was compiled against.

Kernel structures change all the time. A field gets added, moved or renamed, and on the next kernel version offset 1,184 points at something else. The program silently reads garbage. The old fix was to ship full kernel headers and a compiler to every machine and recompile the program there, which is heavy, slow and fragile.

## The idea in one paragraph

Two pieces solve this together. **BTF** (BPF Type Format) is a compact dictionary of every type in the running kernel (structs, fields, enums, function signatures) built into the kernel image itself. **CO-RE** ("compile once, run everywhere") changes how programs are compiled: instead of baking in "offset 1,184", the compiler also writes down "this instruction reads field *flags* of the *memory descriptor* struct". At load time, the loader looks the field up in the running kernel's BTF and patches in the right offset. One binary now runs across kernel versions.

## Step by step

### Step 1: The kernel describes itself
When the kernel is built, a tool extracts the type information and stores it in a special section of the kernel image. Each record describes one type: an integer (width, signed or not), a struct or union (its fields: name, type, bit position), an array, a function and its signature, a global variable, or a tag annotating another type.

Compared with the standard debug format (DWARF), BTF is purpose-built and stripped down: about 10× smaller for the same type info, adding roughly 1–2 MB to the kernel image, small enough to ship in production. The cost is that it can't express everything DWARF can.

### Step 2: Load and expose it at boot
At boot, the kernel reads and validates this section and keeps it as the global type dictionary. Userspace can read it through a file in sysfs.

Kernel modules carry their own *split* BTF that refers back to the main kernel's types instead of duplicating them.

### Step 3: The compiler records what you meant
When a BPF program is compiled with CO-RE support, each field access produces two things:
- a normal instruction using the offset from the headers it was compiled with, and
- a **relocation record** saying which struct and which chain of fields that instruction meant (for example "task → memory descriptor → flags").

### Step 4: The loader patches offsets
This is the key step. Before handing the program to the kernel, the loader (normally libbpf) goes through every relocation record, looks up the named struct and field in the *running* kernel's BTF, computes the field's real position, and rewrites the instruction's offset.

### Step 5: Handle fields that don't exist
Sometimes a field is gone entirely because the struct was refactored. A program can ask "does this field exist on this kernel?" and take a different path if not, instead of failing to load.

### Step 6: Let the kernel do the patching itself
Since 5.14 the kernel can apply relocation records itself if they're passed in at load time. This was done for three reasons:
- **Signed programs.** If the loader rewrites a program, its signature no longer matches. Kernel-side patching keeps the signed bytes intact.
- **Other languages.** Loaders that don't use libbpf (such as Go's BPF library) get CO-RE without reimplementing the algorithm.
- **Better errors.** Failures show up in the verifier's log.

### Step 7: The verifier uses BTF too
Beyond portability, the verifier relies on BTF to understand types:
- checking that arguments passed to kfuncs have the right types,
- knowing precisely what's inside a map value,
- following ownership tags on kernel pointers stored in maps,
- checking calls to global functions against their declared signatures instead of re-verifying the function for every caller.

### Step 8: Stay forward-compatible
New kinds of BTF record keep being added. Older tools used to fail on a kind they didn't recognise. In 7.1, a *layout* record was added so that older tools can learn the size of an unknown kind and skip over it.

## The picture

```text
 BUILD TIME (your machine)                  LOAD TIME (target machine)
 ┌───────────────────────────┐              ┌─────────────────────────────┐
 │ source: task->mm->flags   │              │ running kernel's BTF        │
 │          │                │              │ (type dictionary in image)  │
 │ compiler ▼                │              │   memory descriptor:        │
 │ instr: read @ offset 1184 │──binary────▶ │     flags @ offset 1200     │
 │ reloc: "mm struct, flags" │              │          │                  │
 └───────────────────────────┘              │ loader patches 1184 → 1200  │
                                            │          ▼                  │
                                            │ verifier ─▶ JIT ─▶ runs     │
                                            └─────────────────────────────┘
```

## Tradeoffs

- **What it gives you:** one compiled BPF binary that runs across many kernel versions, no headers or compiler on the target, plus rich type info for the verifier and for tools that pretty-print maps.
- **What it costs / requires:** the kernel must be built with BTF enabled, which adds 1–2 MB to the image. Kernel-side relocation added kernel complexity and a new interface that must be maintained.
- **Where it bites:** CO-RE fixes *where* fields are, not *what they mean*. If a field is removed or its semantics change, the program has to handle that itself. And it does nothing for changes to kfunc signatures.

## How it got here

- **4.18 (2018):** BTF introduced, first for pretty-printing map contents.
- **5.2 (2019):** extra info for functions and source lines, so tools can show source alongside code.
- **5.8 (2020):** CO-RE in libbpf.
- **5.13–5.15 (2021):** the verifier type-checks kfuncs with BTF, kernel-side CO-RE arrives, and new tag kinds carry pointer-ownership annotations.
- **6.x:** split BTF for modules and trusted-pointer tracking.
- **7.1 (2026):** layout records for forward compatibility, by Alan Maguire.

## Related

- Technical version: [[btf-and-co-re]]
- [[bpf-explained|BPF overview]]
- [[bpf-verifier-explained|The verifier]]: uses BTF for type checking
- [[bpf-helpers-and-kfuncs-explained|Helpers and kfuncs]]: kfuncs are found and checked through BTF
- [[bpf-maps-explained|BPF maps]]: BTF lets tools print their contents
- [[libbpf-and-toolchain|libbpf]]: the loader that applies CO-RE relocations
