---
title: "Kernel Hardening — Explained"
category: explained
original: "[[kernel-hardening]]"
subsystem: security
tags: [explained, security, hardening, kaslr, spectre]
converted: 2026-09-25
---

# Kernel hardening, explained

> Plain-language companion to [[kernel-hardening|the technical note]]. Same facts, fewer identifiers.

## The problem

The kernel is large and written in C, so it will always contain memory-safety bugs. Access control doesn't help once one of those bugs is hit: a properly confined process that triggers a kernel bug can use it to escape its confinement entirely. And some CPUs leak kernel memory through speculative execution even when the code is correct.

## The idea in one paragraph

Assume bugs exist, and make each step of **turning a bug into an exploit** harder. An attacker usually needs to know where things are in memory, overwrite a return address or function pointer, redirect execution somewhere useful, and read data they shouldn't. Hardening puts a separate obstacle in front of each step: randomise addresses, detect overwrites, forbid jumps into user memory, check indirect calls, bounds-check copies, and close speculative-execution side channels. None of it prevents bugs; it makes exploiting them expensive.

## Step by step

### Step 1: Hide where things are (KASLR)
Exploits usually need an address: a code gadget, a function, a data structure. **Kernel address space layout randomisation** loads the kernel at a random address on each boot. The choice is made in the early decompression stage, using hardware random numbers, timer jitter or firmware-supplied seeds. KASLR is only as good as the secrecy of kernel addresses, so any **pointer leak** to user space defeats it. The kernel hides pointers from logs and /proc files by policy (a setting can show them to everyone, to root only, or to nobody) and doesn't export the full symbol table by default.

### Step 2: Detect stack overwrites
With **stack protectors**, the compiler puts a random **canary** value between a function's local variables and its saved return address. Just before returning, the function checks it; if a buffer overflow has changed it, the kernel panics instead of returning to an attacker-chosen address. The "strong" variant protects every function that has an array on the stack or takes the address of a local, which covers most vulnerable patterns. On arm64, a **shadow call stack** goes further: return addresses live on a separate protected stack, so smashing the normal stack can't redirect control at all.

### Step 3: Keep the kernel out of user memory
This is the key step against the simplest attacks. **SMEP** (PXN on Arm) makes the CPU fault if the kernel tries to *execute* code in a user page, so an attacker can't redirect the kernel to their own shellcode. **SMAP** (PAN on Arm) makes it fault if the kernel *reads or writes* user memory unexpectedly, so a bug that dereferences a user-supplied pointer crashes instead of quietly following it. Legitimate copies to and from user space lower the barrier briefly with special instructions; any other path that touches user memory faults.

### Step 4: Check copies across the boundary
**Hardened usercopy** checks every copy between kernel and user memory: the kernel-side pointer must point to a real allocated object, and the copy must not be larger than that object. This blocks heap overflows and memory disclosure through the copy routines.

### Step 5: Bounds-check common memory functions
**Fortify source** wraps functions like memcpy and strcpy with checks based on the destination's size, known at compile time. If an operation would overflow, the kernel stops immediately with a stack trace pointing at the exact call site.

### Step 6: Check indirect calls (CFI)
With **control-flow integrity** (built with Clang), every indirect call checks that its target has the type signature the function pointer promises. An attacker who overwrites a function pointer must also point it at a function with a compatible signature; random kernel code almost never matches, so the kernel panics instead. CFI is to wrong-type jumps inside the kernel what SMEP is to jumps into user memory.

### Step 7: Close speculative side channels
- **Meltdown:** user code could speculatively read kernel memory and leak it through cache timing. **Kernel page-table isolation** gives user mode its own page tables that don't map the kernel (apart from a tiny entry trampoline), at the cost of a page-table switch and TLB flush on every kernel entry and exit.
- **Spectre v1:** mis-trained branches could speculatively read past array bounds. A special index-masking sequence clamps the index so even speculation can't go out of bounds.
- **Spectre v2:** user code could poison the indirect-branch predictor to steer kernel calls. **Retpolines** replace indirect calls with a sequence the CPU can't speculate through; predictor barriers and restrictions at context switch, and a newer always-on hardware mode, are the alternatives.

### Step 8: Reduce what leaks
Other options zero stack frames and new allocations so stale data can't leak, and a few settings restrict what unprivileged users can see or do: kernel logs, performance events (a side-channel risk), and loading BPF programs. BPF's JIT compiler has its own hardening against attackers scanning for gadgets in JIT-compiled code.

## The picture

```text
 exploit chain:  find address ─▶ overwrite ─▶ redirect execution ─▶ read secrets
 obstacle:          KASLR       canaries,      SMEP/SMAP, CFI       page-table isolation,
                    pointer     shadow stack,                       Spectre masking,
                    hiding      usercopy &                          retpolines,
                                fortify checks                      zero-init
```

## Tradeoffs

- **What it gives you:** defence even when the bug isn't known yet; each layer blocks a different step, so an attacker must beat several at once.
- **What it costs / requires:** page-table isolation adds a costly switch on every kernel entry; canaries and bounds checks add small per-call costs; CFI and shadow call stacks need Clang/LLVM, and the shadow stack is arm64-only.
- **Where it bites:** KASLR fails completely if a single kernel pointer leaks. Hardening complements access control rather than replacing it: seccomp limits which system calls can reach kernel bugs, and hardening makes those bugs harder to exploit.

## How it got here

- **Meltdown and Spectre (2017 CVEs):** these brought page-table isolation, speculation-safe indexing, retpolines and branch-predictor controls.
- **Later CPUs:** added an enhanced always-on branch-restriction mode that avoids the per-switch cost.

## Related

- Technical version: [[kernel-hardening]]
- [[security-explained|Security subsystem]], [[lsm-framework-explained|LSM framework]], [[seccomp-bpf-explained|seccomp]], [[capabilities-explained|Capabilities]]
- [[bpf-explained|BPF]], [[bpf-jit-compiler-explained|BPF JIT compiler]]
