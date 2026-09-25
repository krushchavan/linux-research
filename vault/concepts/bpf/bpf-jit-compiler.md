---
title: "BPF JIT Compiler"
category: concept
tags: [bpf, jit, compilation, x86, arm64, performance]
subsystem: bpf
kernel_version: "3.0"
researched: 2026-04-16
status: complete
explained: "[[bpf-jit-compiler-explained]]"
sources:
  - https://lwn.net/Articles/437981/
  - https://lwn.net/Articles/740157/
  - https://lwn.net/Articles/946389/
  - https://www.kernel.org/doc/html/latest/bpf/index.html
---

# BPF JIT Compiler

> 📘 Plain-language version: [[bpf-jit-compiler-explained]]

## Purpose

The BPF interpreter executes bytecode one instruction at a time through a C switch statement — roughly 3–5× slower than native code and also a Spectre v2 gadget (a branch predictor can be trained to speculate through the interpreter's dispatch logic, leaking kernel memory). The JIT compiler translates verified BPF bytecode to native machine instructions before the program is first invoked, eliminating both problems: execution speed matches hand-written C, and there is no interpreter dispatch table to exploit.

## Mental Model

The JIT is an **instruction-level template engine**: for each BPF opcode it emits one or a few host instructions, leveraging the fact that the BPF register model was deliberately designed to map 1:1 onto modern 64-bit ISAs. The hard part is not the translation itself but the surrounding machinery: patching call targets after all subprograms are assembled, constant-blinding to prevent JIT-spray, and dealing with architecture-specific constraints like instruction alignment and branch encoding limits.

## How It Works

After `bpf_check()` succeeds, `bpf_prog_select_runtime()` checks whether a JIT is available for the current architecture. If yes, it calls `bpf_int_jit_compile()` (x86-64) or the equivalent arch function. The JIT allocates an executable memory region via `bpf_jit_binary_alloc()`, iterates over the verified BPF instruction array, and for each BPF instruction calls an emitter function that appends native bytes.

### Register mapping

BPF defines eleven registers R0–R10. These map onto host registers so that no register-saving preamble is needed for most helper calls (the BPF calling convention aligns with the host ABI):

| BPF Register | Role | x86-64 | arm64 |
|-------------|------|--------|-------|
| R0 | Return value | RAX | X0 |
| R1–R5 | Arguments | RDI, RSI, RDX, RCX, R8 | X0–X4 |
| R6–R9 | Callee-saved | RBX, R13, R14, R15 | X19–X22 |
| R10 | Frame pointer (read-only) | RBP | X29 |

This alignment means a BPF `call` helper instruction translates to a single `callq <addr>` on x86-64 with no argument shuffling. On arm64, `BLR` or `BL` serves the same role.

### Translation loop

The core translation loop (`do_jit()` on x86-64, `build_insn()` on arm64) runs at least twice: once to compute instruction offsets and once to emit with correct branch targets. Because x86-64 branch displacements are encoded relative to the end of the instruction, and because BPF jumps are in BPF instruction units while x86 jumps use byte offsets, a two-pass approach is needed. In rare cases involving 8-bit vs 32-bit displacement choices, a third pass runs.

For each BPF opcode:
- `BPF_ALU64_REG(ADD, dst, src)` → `addq src, dst` (one x86 instruction)
- `BPF_LDX_MEM(DW, dst, src, off)` → `movq [src + off], dst`
- `BPF_JMP_REG(JLT, dst, src, off)` → `cmpq src, dst; jl <target>`
- `BPF_CALL` → `callq <helper_address>` after patching the 32-bit relative displacement

Load-immediate `BPF_LD_IMM64` is a two-instruction BPF encoding (16 bytes); it translates to `movabsq $imm64, dst` on x86-64.

### Constant blinding

To prevent JIT-spray attacks (where an attacker crafts BPF immediates so the JIT emits native instruction bytes that, if executed at an off-by-one address, decode as useful ROP gadgets), `bpf_jit_blind_constants()` XOR-folds large immediates before emission. A 64-bit immediate `v` is replaced by `(v ^ rnd) ^ rnd` where `rnd` is a per-JIT-run random value. The two operations are emitted separately, so the literal value `v` never appears in the instruction stream.

### BPF-to-BPF calls and subprograms

When a BPF program calls a static subprogram or a global function (`BPF_CALL` with `off != 0`), the verifier assigns each subprogram its own `bpf_prog *`. The JIT compiles each subprogram separately, producing independent JIT images. After all images are produced, a fixup pass patches the call target addresses into the `callq` instructions. This is why `bpf_prog_select_runtime()` recurses over `prog->aux->func[]`.

Tail calls (`bpf_tail_call()`) are handled differently: the JIT emits a bounds check on the index, loads the target program pointer from the `PROG_ARRAY` map, and does a **longjmp-style stack frame replacement** — the current stack frame is discarded and execution continues at the target's JIT image entry. This is a direct `jmp` to the target's text, not a `call`.

### Architecture support

Supported architectures as of kernel 6.x: x86-64, arm64, arm32, ppc64 (BE and LE), s390x, mips64, sparc64, arc, riscv64. Each architecture provides its own JIT in `arch/<arch>/net/bpf_jit*.c`. New architectures start with interpreter-only mode and add JIT support incrementally.

`CONFIG_BPF_JIT_ALWAYS_ON` removes the interpreter at compile time; any machine without a JIT for its architecture refuses to load BPF programs at runtime.

## Key Data Structures

**`struct bpf_prog`** (`include/linux/filter.h`) — the compiled program:
- `jited` — bool; set when `bpf_func` points to a valid JIT image
- `bpf_func` — `unsigned int (*)(const void *ctx, const struct bpf_insn *insn)` — the native entry point
- `jited_len` — size of the JIT text in bytes
- `aux` — `struct bpf_prog_aux *`; holds references to subprogram `bpf_prog` array, maps, BTF

**`struct jit_context`** (x86-64, `arch/x86/net/bpf_jit_comp.c`) — per-JIT-run scratchpad:
- `cleanup_addr` — address of the function epilogue (for early returns)
- `prog` — output image pointer

## Key Functions / Entry Points

**`bpf_prog_select_runtime()`** (`kernel/bpf/core.c`) — selects JIT or interpreter; iterates over subprograms.

**`bpf_int_jit_compile()`** (`arch/x86/net/bpf_jit_comp.c`) — x86-64 top-level JIT; calls `do_jit()` up to three times.

**`do_jit()`** — inner translation loop; emits one or more x86 bytes per BPF instruction; fills `addrs[]` with per-instruction byte offsets.

**`bpf_jit_blind_constants()`** (`kernel/bpf/core.c`) — rewrites BPF instructions with XOR-folded immediates.

**`bpf_jit_binary_alloc()`** / **`bpf_jit_binary_finalize()`** — allocates RWX → RX executable memory from the `BPF_JIT` vmalloc region.

## Important Flags & Config Options

- `CONFIG_BPF_JIT` — enables JIT; required for `BPF_JIT_ALWAYS_ON`.
- `CONFIG_BPF_JIT_ALWAYS_ON` — removes interpreter; all programs must JIT or load fails.
- `net.core.bpf_jit_enable` sysctl — 0 = disabled (interpreter only), 1 = enabled, 2 = enabled + dump JIT image to kernel log.
- `net.core.bpf_jit_harden` sysctl — 0 = no blinding, 1 = blind constants for unprivileged BPF programs, 2 = always blind.
- `net.core.bpf_jit_kallsyms` sysctl — expose JIT image addresses in `/proc/kallsyms`.

## Interactions with Other Subsystems

- **→ [[bpf-verifier]]**: Receives the post-verification `bpf_prog`. The verifier's `insn_aux_data[]` annotations guide instruction patching (e.g. replacing calls to deprecated helpers, inlining map lookups for specific map types).
- **→ [[bpf-program-types]]**: Each program type specifies which context struct the JIT passes as R1 at program entry.
- **↑ Userspace**: `net.core.bpf_jit_enable = 2` causes the kernel to print JIT images to `dmesg`; `bpftool prog dump jited` disassembles them.

## Design Decisions & Tradeoffs

**One-to-one register mapping as a design goal** — Alexei Starovoitov deliberately designed the eBPF ISA (in contrast to classic BPF's two-register design) so that the 10 general-purpose registers map directly onto host registers, enabling trivial JIT without a register allocator. The price is that BPF programs must manage spills manually (via the stack), and the fixed 512-byte stack is a hard limit.

**Two-pass vs. three-pass JIT** — The first pass computes byte offsets for each BPF instruction. On x86-64, short (8-bit) and long (32-bit) branch encodings produce different instruction lengths. If a branch that was encoded as short in pass 1 turns out to need a long encoding in pass 2 (because the offset changed), a third pass is needed. This is rare in practice but must be handled to guarantee convergence.

**JIT-spray mitigation via constant blinding** — Blinding adds two instructions per large immediate, a ~5–10% overhead on immediate-heavy programs. `bpf_jit_harden = 1` applies blinding only to unprivileged programs; privileged programs are trusted not to craft spray gadgets.

## How It Has Evolved

- **3.0 (2011)**: First BPF JIT, x86-64 only (Eric Dumazet). Classic BPF only.
- **3.18 (2014)**: eBPF JIT on x86-64.
- **4.6 (2016)**: arm64 JIT.
- **4.14 (2017)**: `CONFIG_BPF_JIT_ALWAYS_ON` added after Spectre v2 disclosure.
- **4.16 (2018)**: BPF-to-BPF call support in x86-64 and arm64 JITs.
- **5.x**: JIT support added for ppc64, s390x, mips64, riscv64.
- **7.1 (2026)**: arm64 JIT gains `ORR`-based MOV for general-purpose registers (Puranjay Mohan); s390x gains `get_preempt_count()` kfunc.

## Further Reading

1. [A JIT for packet filters — LWN.net (2011)](https://lwn.net/Articles/437981/)
2. [A thorough introduction to eBPF — LWN.net (2017)](https://lwn.net/Articles/740157/)
3. [BPF and security — LWN.net (2022)](https://lwn.net/Articles/946389/)
