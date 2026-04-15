---
title: "Kernel Hardening"
category: concept
tags: [security, hardening, kaslr, smep, smap, spectre, meltdown, cfi]
subsystem: security
kernel_version: "3.14"
researched: 2026-04-15
status: complete
sources:
  - https://kernel-internals.org/security/kernel-hardening/
---

# Kernel Hardening

## Overview

Kernel hardening is a collection of compile-time and runtime mitigations that raise the cost of exploiting kernel vulnerabilities. These mechanisms do not prevent bugs from existing but make it substantially harder to turn a memory-corruption bug into arbitrary code execution, privilege escalation, or information disclosure. Hardening is complementary to access control: even if a process is properly confined by LSM policies, a kernel vulnerability could let it escape that confinement — hardening features make such escapes harder.

## How It Works

Hardening operates in several orthogonal dimensions: address randomisation, stack protection, supervisor-mode access controls, copy hardening, compiler-based integrity checks, and CPU vulnerability mitigations. Each dimension attacks a different phase of the exploit chain.

### KASLR — Kernel Address Space Layout Randomisation

KASLR randomises the physical base address at which the kernel and modules are loaded on each boot. An attacker who has found a kernel vulnerability typically needs to know the address of a gadget (for ROP), a function (for ret2kernel), or a data structure. KASLR makes these addresses unpredictable.

The randomisation happens in the decompressor before the kernel proper runs. On x86-64, the decompressor calls `choose_random_location()`, which gathers entropy from RDRAND, TSC, ACPI timer jitter, or UEFI-provided random seeds, then maps the kernel at a random alignment within a fixed-size window. On arm64, a similar mechanism in the bootloader or EFI stub applies the random offset before page tables are set.

KASLR is defeated by **kernel pointer leaks** — any mechanism that causes a kernel virtual address to appear in userspace (e.g. uninitialized stack memory, `/proc/kallsyms`, error messages). The kernel mitigates this with:
- `kptr_restrict` sysctl: 0 = show pointers to all, 1 = show to root, 2 = never show
- `%pK` printf format: automatically applies `kptr_restrict` policy
- `CONFIG_KALLSYMS_ALL=n` by default in production kernels

### Stack Canaries

`CONFIG_STACKPROTECTOR_STRONG` instructs GCC or Clang to insert a random canary value between a function's local variables and its saved return address on the stack. The canary is checked just before the function returns; a corrupted canary means the return address was overwritten by a stack buffer overflow.

On function entry, the compiler inserts:
```asm
mov rax, qword ptr fs:[<canary_offset>]   ; load per-CPU canary
mov qword ptr [rsp-8], rax                ; place before return addr
```

On return:
```asm
mov rax, qword ptr [rsp-8]
xor rax, qword ptr fs:[<canary_offset>]   ; compare
jne __stack_chk_fail                      ; panic if mismatch
```

`CONFIG_STACKPROTECTOR_STRONG` (vs. the weaker default) adds protection to any function that takes the address of a local variable or has an array on the stack, covering the vast majority of vulnerable patterns.

Shadow Call Stack (`CONFIG_SHADOW_CALL_STACK`, arm64/LLVM only) is a stronger variant: a separate, hardware-protected stack holds only return addresses. The regular stack can be arbitrarily corrupted without affecting control flow, because return addresses are always fetched from the shadow stack.

### SMEP and SMAP

**SMEP** (Supervisor Mode Execution Prevention, Intel; PXN on ARM64) raises a fault if the kernel attempts to execute instructions from a page mapped user-accessible. Without SMEP, an attacker who controls a kernel code pointer could redirect execution to shellcode in a user-page. SMEP makes ret2user attacks impossible.

**SMAP** (Supervisor Mode Access Prevention, Intel; PAN on ARM64) raises a fault if the kernel *reads or writes* a user-accessible page without explicit intent. Without SMAP, an attacker could craft a kernel-mode operation that dereferences a user-controlled pointer (a "userspace pointer dereference" vulnerability). SMAP makes this fault rather than silently proceeding.

Legitimate kernel-to-user copies (`copy_to_user()`, `copy_from_user()`) explicitly lower the SMAP barrier for the duration of the copy using `stac`/`clac` instructions (x86) or `uaccess_enable()`/`uaccess_disable()` (ARM64). Any kernel path that does not use these macros will fault under SMAP if it touches user memory.

### HARDENED_USERCOPY

`CONFIG_HARDENED_USERCOPY` adds checks to `copy_to_user()` and `copy_from_user()` to verify:
1. The kernel-side pointer refers to a valid slab object (not an arbitrary address)
2. The copy size does not exceed the size of the object

This prevents a class of attacks where a kernel function copies more data than the destination buffer can hold (kernel heap overflow via copy) or copies from an unallocated region (kernel memory disclosure).

### FORTIFY_SOURCE

`CONFIG_FORTIFY_SOURCE` replaces standard functions (`memcpy`, `strcpy`, `strncpy`, `memset`, etc.) with wrappers that use `__builtin_object_size()` to determine the destination's compile-time size. If the requested operation size exceeds the destination, `fortify_panic()` triggers a kernel BUG immediately.

This catches the majority of fixed-size buffer overflows and overreads at the exact call site, with the stack trace pointing directly to the offending function.

### Spectre and Meltdown Mitigations

**Meltdown (CVE-2017-5754)** — Speculative out-of-order execution allowed userspace to read kernel memory via cache timing side channels. The fix is KPTI (Kernel Page-Table Isolation): the kernel uses separate page table roots for user mode and kernel mode. Userspace page tables do not map kernel memory (except for the tiny trampoline needed to re-enter the kernel). Context switches between user and kernel now require a CR3 switch (costly TLB flush) but eliminate the Meltdown side channel.

**Spectre v1 (CVE-2017-5753)** — Speculative conditional branches could be mis-trained to speculatively access out-of-bounds array elements, leaking values via cache timing. The mitigation is `array_index_nospec(index, size)`, a conditional-move sequence that zeros the index if `index >= size` in a way that removes the speculative data dependency, preventing the CPU from speculatively accessing the out-of-bounds element.

**Spectre v2 (CVE-2017-5715)** — Indirect branch predictors could be poisoned from userspace to redirect kernel indirect calls to attacker-chosen gadgets. Mitigations include:
- **Retpolines**: replace indirect calls with a controlled loop that the CPU cannot speculate past: `call __retpoline_rax; jmp __retpoline_rax; pause; lfence; ret` sequence.
- **IBRS/IBPB** (Indirect Branch Restricted Speculation / Indirect Branch Predictor Barrier): CPU MSR writes at context switch to flush the branch predictor.
- **Enhanced IBRS**: a newer CPU mode that keeps IBRS active throughout kernel execution without MSR overhead.

### Control Flow Integrity (CFI)

`CONFIG_CFI_CLANG` (requires Clang) instruments every indirect call to verify that the callee's type signature matches the pointer's declared type. A function pointer overwrite by an attacker still requires pointing to a function with a compatible signature — random kernel code is unlikely to match, causing a kernel panic at the corrupted call site rather than arbitrary code execution.

CFI is the compile-time analogue of SMEP: SMEP blocks ret2user (execution in user pages); CFI blocks ret2kernel (execution at wrong-type function pointers in kernel pages).

## Key Config Options

| Config | Protection |
|--------|-----------|
| `CONFIG_STACKPROTECTOR_STRONG` | Stack canaries on vulnerable functions |
| `CONFIG_SHADOW_CALL_STACK` | Hardware-protected return address stack (arm64) |
| `CONFIG_RANDOMIZE_BASE` / `CONFIG_KASLR` | KASLR |
| `CONFIG_PAGE_TABLE_ISOLATION` | KPTI (Meltdown mitigation) |
| `CONFIG_HARDENED_USERCOPY` | Bounds-checked copy_{to,from}_user |
| `CONFIG_FORTIFY_SOURCE` | Compile-time bounds checks on memcpy/strcpy |
| `CONFIG_CFI_CLANG` | Type-checked indirect calls (Clang) |
| `CONFIG_INIT_STACK_ALL_ZERO` | Zero-initialise stack frames (prevents info leaks) |
| `CONFIG_INIT_ON_ALLOC_DEFAULT_ON` | Zero slab/page allocations on alloc |

## Key sysctl Knobs

- `kernel.kptr_restrict` — controls kernel pointer exposure (0/1/2)
- `kernel.dmesg_restrict` — controls dmesg access by unprivileged users
- `kernel.perf_event_paranoid` — restricts perf_events (side-channel risk)
- `kernel.unprivileged_bpf_disabled` — disables BPF program loading by unprivileged users

## Interactions

- **[[lsm-framework]]** — hardening is orthogonal to access control; both layers are needed
- **[[seccomp-bpf]]** — seccomp and hardening together form a sandbox; seccomp prevents dangerous syscalls, hardening raises the cost of exploiting kernel bugs reached via allowed syscalls
- **[[bpf]]** — BPF JIT hardening (`CONFIG_BPF_JIT_ALWAYS_ON`, `bpf_jit_harden`) applies KASLR-like randomisation to JIT-compiled BPF programs to prevent gadget scanning
