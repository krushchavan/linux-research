---
title: "BPF Helpers and kfuncs — Explained"
category: explained
original: "[[bpf-helpers-and-kfuncs]]"
subsystem: bpf
tags: [explained, bpf, helpers, kfuncs]
converted: 2026-09-25
---

# BPF helpers and kfuncs, explained

> Plain-language companion to [[bpf-helpers-and-kfuncs|the technical note]]. Same facts, fewer identifiers.

## The problem

A BPF program runs inside the kernel, but on its own it can do very little: arithmetic, reading its input, and branching. To be useful it has to call into the kernel to look up a map entry, read the clock, redirect a packet, or grab a task.

It can't call any kernel function it likes. The verifier has to prove the program safe, and it can only do that if it knows exactly what each called function accepts, returns and does. An open-ended call into arbitrary kernel code would break that proof.

So the kernel offers a curated menu of callable functions. The hard part is the menu's *promise*: if every entry is guaranteed never to change, the kernel is stuck with every design mistake forever. If entries can change, programs break across kernel versions.

## The idea in one paragraph

There are two menus. **Helpers** are the original one: a fixed, numbered list whose signatures are frozen forever, like system calls. **kfuncs** are the newer one: ordinary kernel functions marked as callable, described by the kernel's own type information (BTF), and allowed to change between releases, like internal kernel APIs. Both are type-checked by the verifier, and both compile to plain direct function calls, so they're fast.

## Step by step

### Step 1: Each helper publishes a contract
Every helper comes with a description: what each of its (up to five) arguments must be (a map, a pointer to memory, anything), what it returns (a number, a pointer to a map value *or nothing*, a socket), and whether only GPL-licensed programs may call it.

### Step 2: The program type decides what's on the menu
When the verifier meets a call, it asks the program's type whether that helper is allowed. A packet filter gets networking helpers; a tracing program gets tracing helpers; everyone gets the basics (maps, time, tail calls). If the answer is "not allowed", the program is rejected. This is how a network program is stopped from calling scheduler-only functions.

### Step 3: The verifier checks the call like a type checker
It compares what it knows about each argument register against the contract. After the call, it records the return type in the result register and marks the argument registers as garbage, since the helper isn't required to preserve them. If the return type is "pointer or nothing", the program must check for nothing before using it.

### Step 4: The call becomes a plain function call
When the program is compiled to native code, the call becomes a direct call to the helper's address in the kernel. No system call, no indirection. That's why helpers are cheap.

### Step 5: Frozen forever, and the cost of that
Once a helper ships, its arguments, return type and behaviour can never change. Mistakes can only be fixed by adding a new, slightly different helper, which is why there are near-duplicates (for example, two ways to output events, one for the old perf buffer and one for the newer ring buffer).

### Step 6: kfuncs, the flexible menu
A kernel developer marks an ordinary kernel function as callable from BPF and says which program types may use it. There's no central numbered list to update. The verifier finds the function by its entry in the kernel's type information and checks each argument against the real parameter types. These functions carry **no stability promise**: they can be renamed, changed or removed next release.

### Step 7: Tracking ownership
This is the key step. Because kfuncs can hand out real kernel objects, the verifier needs to know who owns what. kfuncs are tagged with properties like "returns a reference you must release", "releases a reference", "only accepts *trusted* pointers", "may sleep", or "has irreversible effects" (like triggering a panic).

With those tags, the verifier tracks references like a borrow checker. A program that acquires a task reference and exits without releasing it is rejected, so it can't leak kernel memory. A function demanding a trusted pointer won't accept one that was read out of a map; it has to come from something like an "acquire task" call. Helpers could never express rules like this.

### Step 8: Global functions
Since 5.5, a BPF program can define its own *global* functions. The verifier checks each one once, on its own, using its declared argument types, rather than re-checking it at every call site. They can also be swapped out at run time without reloading the whole program.

### Step 9: Graduation
A kfunc that proves stable and widely useful can be promoted to a helper. It gains the stability guarantee and gives up the freedom to change.

## The picture

```text
   BPF program:  call X(args)
                     │
                     ▼
        ┌─────── verifier ───────┐
        │  Is X on this program  │── no ──▶ reject
        │  type's menu?          │
        └───────────┬────────────┘
          helper    │     kfunc
     (numbered,     │    (found via kernel type info,
      frozen)       │     may change each release)
        ┌───────────┴────────────┐
        │ check argument types   │
        │ track refs: acquire ──▶ must release before exit
        │ trusted pointers only? │
        └───────────┬────────────┘
                    ▼
        JIT: direct native call into kernel code
```

## Tradeoffs

- **What it gives you:** helpers give old programs a guarantee they'll keep loading on new kernels. kfuncs let the kernel expose powerful features quickly (data structures, scheduler operations, socket operations) with strong ownership checking.
- **What it costs / requires:** helpers can never be fixed, so they accumulate duplicates. kfuncs require the kernel's type information to be built in, and programs using them may need rebuilding for each release. CO-RE smooths over struct layout changes, but not changes to function signatures.
- **Where it bites:** people assume everything BPF can call is a stable API. Only helpers are. A tool built on kfuncs can break on the next kernel upgrade, which is fine for in-tree tools and painful for third-party ones.

## How it got here

- **3.18 (2014):** the first helpers: maps, socket filtering, perf output.
- **5.8 (2020):** ring-buffer helpers.
- **5.13–5.15 (2021):** kfuncs introduced (first for TCP congestion-control code), then generalized with acquire/release/trusted-argument tagging.
- **6.1 (2022):** red-black trees and linked lists for BPF, built entirely from kfuncs.
- **6.12 (2024):** sched_ext exposes its scheduling operations as kfuncs.
- **7.1 (2026):** kfuncs can receive hidden, implicit arguments carrying extra metadata.

## Related

- Technical version: [[bpf-helpers-and-kfuncs]]
- [[bpf-explained|BPF overview]]
- [[bpf-verifier|The verifier]]: does all the checking described here
- [[bpf-maps-explained|Maps]]: what most helpers operate on
- [[btf-and-co-re|BTF and CO-RE]]: the type information kfuncs depend on
- [[bpf-program-types-explained|Program types]]: decide which menu a program gets
