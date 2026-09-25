---
title: "BPF Verifier — Explained"
category: explained
original: "[[bpf-verifier]]"
subsystem: bpf
tags: [explained, bpf, verifier, static-analysis]
converted: 2026-09-25
---

# The BPF verifier, explained

> Plain-language companion to [[bpf-verifier|the technical note]]. Same facts, fewer identifiers.

## The problem

Loading a BPF program means running someone else's code inside the kernel, with full kernel privileges. Without a check, that's like loading an unsigned kernel module: one bad pointer and the machine crashes or leaks secrets.

Testing isn't enough. A test only covers the inputs you thought of. The kernel needs to know the program is safe for **every possible input**: it always finishes, never reads or writes outside the memory it's allowed, never reads uninitialized data, and only calls kernel functions permitted for its kind of program. And it needs to know this *before* the first instruction runs.

## The idea in one paragraph

The verifier doesn't run the program on real data. It runs it on *descriptions* of data. Instead of "this register holds 42", it tracks "this register holds a number between 0 and 255 whose top 56 bits are zero", or "this register points into a map value, 16 bytes in". Each instruction updates those descriptions. At every branch it follows both ways. If every path it explores is safe for every value the descriptions allow, the program loads; if even one could be unsafe, it's rejected with a message pointing at the offending instruction. The formal name for this is *abstract interpretation*.

## Step by step

### Step 1: Check the program's shape
First the verifier maps out every possible jump between instructions (the control-flow graph).

- **Loops** are only allowed in two narrow forms: counted loops where the verifier can work out a finite number of iterations, and loops driven by a special kernel *iterator* function that marks where the loop ends. Any other backward jump is rejected, because it might never finish.
- **Unreachable code** is rejected too. Code that can never be reached normally could still hide something an attacker jumps to via speculative execution.

### Step 2: Describe every register and stack slot
For each of the eleven registers and every stack slot, the verifier keeps a description with several parts:
- **Kind:** not yet written, a plain number, or a pointer of a particular sort (to the program's input, to a map value, to the stack, to packet data, to a socket), including "pointer that might be null".
- **Known bits:** a pair of numbers saying which bits are definitely known and what they are. After loading a single byte, the low 8 bits are unknown and the top 56 are known to be zero. This is called a *tnum* ("tristate number").
- **Range:** the smallest and largest value it could be, tracked both as unsigned and as signed.
- **Identity:** a tag linking copies of the same pointer, so a bounds check on one copy also protects the other.

### Step 3: Update descriptions instruction by instruction
Each instruction transforms the descriptions. Adding 4 shifts the range up by 4. Masking with a constant makes more bits known. A comparison branch *splits* the world: if the code branches on "value < 16", the path where it's true now knows the maximum is 15, and the other path knows the minimum is 16.

This is how a program "earns" a memory access. You check the index against the size, and on the branch where the check passed, the verifier now knows the index is in range.

### Step 4: Prove every memory access
Before any load or store through a pointer, the verifier asks: does this kind of pointer allow access at all? Then it computes the lowest and highest possible offset from the pointer's range and proves both fall inside the object. Misaligned accesses are caught from the known-bits information. If the proof fails, the program is rejected, with a readable log explaining where.

### Step 5: Check function calls
For each call, the verifier looks up what arguments the function accepts and checks each argument's description against it. After the call, the five argument registers are marked "unwritten" (garbage), the return register gets the function's return type, and the four preserved registers keep their descriptions.

### Step 6: Also check paths the CPU might only *imagine*
After Jann Horn showed Spectre attacks leaking kernel memory through BPF programs, the verifier began simulating *speculative* execution too. Modern CPUs sometimes run the wrong side of a branch briefly before correcting themselves, and that brief run can leak data through timing side channels. So the verifier checks both sides of a branch even when one is logically impossible, and adds masking so pointer arithmetic can't reach out of bounds even speculatively.

### Step 7: Prune to avoid exponential blowup
This is the key step for making it practical. Every branch doubles the number of paths. With dozens of branches, exploring each one separately would take forever.

So at points where paths merge, the verifier saves the state it proved safe. When it arrives at the same point along a different path, it compares: if the new state is **at least as constrained** as a saved one (every number's range sits inside the saved range, every pointer matches exactly), then whatever the saved state could safely do, this one can too. The rest of the path is skipped.

### Step 8: Ignore registers that no longer matter
A register that will never be read again can't affect safety, so it's left out of the comparison. That makes many more states match and many more paths get pruned. This *liveness* analysis exists for pruning, not for reporting unused registers. In 7.1 it was rewritten as a static analysis done up front, roughly halving verification time for programs with complex stack use.

### Step 9: Stop at hard limits
To keep a malicious program from making the verifier itself run forever, there are hard caps: about one million verified instructions, and a maximum call depth of 8 frames (relaxed for global functions in 7.1). Exceed them and the program is rejected, even if it's actually safe.

## The picture

```text
 program ──▶ [1] map all jumps: no wild loops, no dead code
                    │
                    ▼
            [2-5] walk paths with descriptions, not values
                    │
        r = byte          r: number, 0..255, top 56 bits = 0
        if r < 16 ──┬── true:  r: 0..15   ──▶ array[r]  ✓ proven in bounds
                    └── false: r: 16..255 ──▶ ...
                    │
            [7-8] reached this point before with a looser,
                  already-proven state?  ── yes ──▶ prune (skip)
                    │ no
                    ▼
            all paths safe ──▶ load and JIT      any path unsafe ──▶ reject + log
```

## Tradeoffs

- **What it gives you:** safety guarantees that hold for every input, checked once, so the running program needs no runtime checks at all.
- **What it costs / requires:** imprecision. Descriptions are approximations, so some programs that are actually safe get rejected, and developers learn to write code "the verifier's way". The combination of known-bits plus ranges is a deliberate middle ground: expressive enough for real programs, cheap enough to verify in reasonable time.
- **Where it bites:** the verifier is complex, and a verifier bug is a kernel security hole. Every feature that makes programs more expressive (loops, function calls, iterators) adds to that complexity. That's also why unprivileged BPF is off by default on most distributions.

## How it got here

- **3.18 (2014):** the first eBPF verifier: shape check plus state simulation.
- **4.14 (2017):** pointer arithmetic tracking and the known-bits representation.
- **5.3 (2019):** bounded loops, by working out iteration counts.
- **5.9 (2020):** simulation of speculative execution for Spectre.
- **5.20–6.4 (2022–2023):** iterator-driven loops, then open-coded iterators.
- **7.1 (2026):** static liveness analysis (about 2× faster verification) and the verifier split out of one huge file into several. A proposal around this time for formal verifier documentation was turned down by the maintainer, showing the tension between documentation and development speed.

## Related

- Technical version: [[bpf-verifier]]
- [[bpf-explained|BPF overview]]
- [[bpf-jit-compiler-explained|The JIT compiler]]: runs once the verifier approves
- [[bpf-program-types-explained|Program types]]: decide which calls and input fields are allowed
- [[bpf-helpers-and-kfuncs-explained|Helpers and kfuncs]]: the calls the verifier type-checks
- [[btf-and-co-re-explained|BTF]]: the type information used to check kfunc calls
