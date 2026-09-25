---
title: "BPF JIT Compiler — Explained"
category: explained
original: "[[bpf-jit-compiler]]"
subsystem: bpf
tags: [explained, bpf, jit, performance]
converted: 2026-09-25
---

# The BPF JIT compiler, explained

> Plain-language companion to [[bpf-jit-compiler|the technical note]]. Same facts, fewer identifiers.

## The problem

A BPF program arrives in the kernel as bytecode: instructions for an imaginary machine. The simplest way to run it is an interpreter, a loop that reads each instruction and jumps to the code that performs it. That has two problems.

- **It's slow.** Interpreting costs roughly 3–5× more than running native code. For a program that runs on every network packet, that matters.
- **It's a security hole.** The interpreter's "look up the instruction, jump to its handler" pattern is exactly what Spectre variant 2 exploits. An attacker can train the CPU's branch predictor to speculatively run the wrong handler and leak kernel memory.

## The idea in one paragraph

Once the verifier has approved a program, the kernel translates it into real machine code for the CPU it's running on, before the program first runs. This is a *just-in-time* (JIT) compiler. It's unusually simple, because BPF's imaginary machine was designed to look like a real 64-bit CPU: each BPF register has a natural home in a real register, so most BPF instructions become one or a few native instructions, like filling in a template. The hard parts are around the edges: getting jump distances right, linking separately compiled functions together, and stopping attackers from hiding machine code inside constants.

## Step by step

### Step 1: Decide whether to compile
After verification succeeds, the kernel checks whether this CPU architecture has a JIT. If it does, it allocates a chunk of executable memory for the output. If the kernel was built to *require* the JIT (removing the interpreter entirely), a machine without one simply refuses to load BPF programs.

### Step 2: Map registers one-to-one
BPF has eleven registers: one for return values, five for function arguments, four that survive function calls, and a read-only frame pointer. Each is assigned a fixed real register, and the assignment matches the platform's own calling convention.

This is the key design choice. Because BPF's argument registers *are* the CPU's argument registers, a call to a kernel helper needs no shuffling. It becomes a single native call instruction. And there's no need for a register allocator, which is the complicated part of most compilers.

### Step 3: Translate instruction by instruction
The compiler walks the verified instructions and emits native code for each: an add becomes an add, a memory load becomes a move from an address plus offset, a conditional jump becomes a compare followed by a branch, a helper call becomes a direct call to that helper's address.

### Step 4: Run it more than once to get jumps right
BPF jumps are measured in BPF instructions, but real jumps are measured in bytes, and you don't know how many bytes each instruction will take until you've emitted it. So the compiler runs at least twice: first to learn every instruction's byte position, then again to emit correct jump targets.

On x86 there's a wrinkle: a short jump fits in a 1-byte distance, a long one needs 4 bytes. Changing one jump's size shifts everything after it, which can change other jumps. Occasionally a third pass is needed before the sizes settle.

### Step 5: Blind large constants
An attacker who controls a program's constant values could pick numbers whose bytes, if the CPU started executing one byte off, decode as useful malicious instructions. This is called *JIT spraying*.

To stop it, the compiler replaces each large constant with a value XOR'd with a random number, followed by a second instruction that XORs the random number back out. The result is the same, but the attacker's chosen bytes never appear in the machine code. This costs two extra instructions per large constant, about 5–10% on constant-heavy programs. By default it can apply only to unprivileged programs, or be forced on for all.

### Step 6: Link functions together
A BPF program can call its own sub-functions. Each is compiled as a separate chunk of machine code. Only once all chunks exist and their addresses are known does a final pass go back and patch in the real call targets.

### Step 7: Tail calls replace the current program
A *tail call* is different from a normal call: one program hands off to another and never comes back. The compiler emits a bounds check on the index, looks up the target program in a program table, throws away the current stack frame, and jumps straight into the target's code.

## The picture

```text
 verified BPF bytecode
        │
        ▼
 ┌──────────────── JIT ────────────────┐
 │ pass 1: emit, record byte offsets   │
 │ pass 2: emit again with real jumps  │
 │ (pass 3 if a jump changed size)     │
 │                                     │
 │ BPF reg  ──fixed──▶ CPU reg         │
 │ add      ──────────▶ add            │
 │ load     ──────────▶ mov [base+off] │
 │ call helper ───────▶ direct call    │
 │ big constant ──────▶ (c^rnd) ^ rnd  │  ← blinding
 └─────────────────┬───────────────────┘
                   ▼
   sub-function images ── patch call addresses ──▶ executable code
```

## Tradeoffs

- **What it gives you:** near-native speed, and no interpreter dispatch loop for Spectre attacks to abuse.
- **What it costs / requires:** a separate JIT per architecture (x86-64, arm64, arm32, ppc64, s390x, mips64, sparc64, arc and riscv64 so far). New architectures start interpreter-only. Because there's no register allocator, BPF programs spill to the stack themselves, and the stack is a hard 512 bytes.
- **Where it bites:** blinding costs speed on constant-heavy programs. And if you force JIT-only mode on a machine with no JIT for its architecture, BPF stops working entirely.

## How it got here

- **3.0 (2011):** the first BPF JIT, x86-64 only, by Eric Dumazet, for classic packet-filter BPF.
- **3.18 (2014):** JIT for the new extended BPF on x86-64. The new instruction set was designed by Alexei Starovoitov precisely so it would map cleanly onto real CPUs.
- **4.6 (2016):** arm64 JIT.
- **4.14 (2017):** option to remove the interpreter entirely, added after Spectre v2 was disclosed.
- **4.16 (2018):** BPF-to-BPF function calls supported in the x86-64 and arm64 JITs.
- **5.x onward:** more architectures, and continued refinements in 7.1 (2026).

## Related

- Technical version: [[bpf-jit-compiler]]
- [[bpf-explained|BPF overview]]
- [[bpf-verifier|The verifier]]: runs first, and marks instructions the JIT may rewrite
- [[bpf-helpers-and-kfuncs-explained|Helpers and kfuncs]]: what the direct calls point to
- [[bpf-program-types-explained|Program types]]: decide what input the compiled program receives
