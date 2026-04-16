---
title: "BPF Verifier"
category: concept
tags: [bpf, verifier, abstract-interpretation, safety, static-analysis]
subsystem: bpf
kernel_version: "3.18"
researched: 2026-04-16
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/bpf/verifier.html
  - https://lwn.net/Articles/982077/
  - https://lwn.net/Articles/740157/
  - https://lwn.net/Articles/946389/
  - https://lore.kernel.org/all/20260309121033.2594457-2-bqe@google.com/
---

# BPF Verifier

## Purpose

Without the verifier, loading a BPF program would be equivalent to `insmod` with no kernel module signing: arbitrary C code executing in ring 0. The verifier proves, before a single JIT-compiled instruction executes, that the program terminates, never accesses memory out of bounds, never reads uninitialized data, and only calls kernel APIs appropriate for its program type. Every verified property is a theorem about *all possible inputs*, not just a test case.

## Mental Model

The verifier is a **theorem prover disguised as a program analyzer**. It does not run the program on actual data; instead it simulates execution with abstract "summary" values that represent entire sets of possible runtime values. If it can prove that every execution path is safe, the program loads. If even one abstract path is unsafe, the program is rejected — with a diagnostic pointing to the offending instruction.

This technique has a formal name: *abstract interpretation*. The abstract domain the verifier uses is a product of a type lattice (what kind of value), a tnum (which bits are known), and interval bounds (what numeric range). Every instruction is a *transfer function* that maps an abstract pre-state to an abstract post-state.

## How It Works

### Phase 1: Control-flow graph construction

`bpf_check()` (`kernel/bpf/verifier.c`) is the top-level entry point, called from `bpf_prog_load()`. It first calls `check_cfg()` (`kernel/bpf/cfg.c`), which builds the program's control-flow graph with a DFS walk. Loops are only permitted in two narrow cases: bounded counted loops (where the verifier can determine a finite iteration count) and iterator-based loops (where a specific `bpf_iter_<type>_next()` kfunc signals the loop boundary). Any other back-edge is rejected. Unreachable instructions (no path from the entry point) are also rejected at this stage — they could hide malicious code that would never be reached in normal flow but might be jumped to via a speculative execution gadget.

### Phase 2: Abstract interpretation

The main loop is `do_check()`. It maintains a `struct bpf_verifier_state` containing an abstract state for every register (R0–R10) and every stack slot. For each BPF instruction it calls a per-instruction handler that computes the new abstract state.

Each register's abstract state is a `struct bpf_reg_state`:
- `type` — the register's kind: `NOT_INIT` (unwritten), `SCALAR_VALUE` (a number), `PTR_TO_CTX`, `PTR_TO_MAP_VALUE`, `PTR_TO_STACK`, `PTR_TO_PACKET`, `PTR_TO_SOCKET`, and nullable variants.
- `var_off` — a *tnum* (tristate number): a pair `(mask, value)` where a 1 in `mask` means the bit at that position is unknown, a 0 means the `value` bit is authoritative. After a byte read, the tnum is `(0xff, 0x00)` — the low 8 bits could be anything, the upper 56 are zero.
- `umin_value` / `umax_value` — unsigned minimum and maximum, tracking numeric range.
- `smin_value` / `smax_value` — signed equivalents for signed-comparison branches.
- `id` — a monotonically-incrementing integer linking copies of the same pointer, so that a range check on one copy constrains its duplicate.

When an ALU instruction runs, the transfer function narrows or widens bounds. `reg += 4` adds 4 to both `umin_value` and `umax_value`. `reg &= mask` intersects the tnum mask with `mask`. Branching on `reg < 16` splits the state: the true arm gains `umax_value = min(umax_value, 15)` and the false arm gains `umin_value = max(umin_value, 16)`. After both arms are explored, the verifier *joins* (takes the pointwise least upper bound of) the resulting states.

Memory access (`check_mem_access()`) validates that the pointer type permits access, computes the total offset using `var_off.value + umin_value` for the lower bound and `var_off.value + umax_value` for the upper, and proves both are within the object's bounds. Misaligned accesses are caught through tnum arithmetic. If proof fails, verification is rejected with a human-readable log entry.

Function calls are validated by `check_helper_call()` / `check_kfunc_call()`. The verifier fetches the `struct bpf_func_proto` for the helper (or resolves the kfunc via BTF), checks each argument type matches the proto's constraint, and then resets R1–R5 to `NOT_INIT` and updates R0 to the return type. Callee-saved registers R6–R9 survive unchanged.

### Speculative execution simulation

After Jann Horn demonstrated Spectre-based information leaks through BPF programs, the verifier was extended to simulate *speculative* execution. On a conditional branch, it runs both arms even when one is statically unreachable, ensuring that even transiently-executed code cannot leak kernel addresses through side channels. This is enforced by the `sanitize_ptr_alu()` and masking-based BPF_F_POISON_PTR_ON_SPEC techniques.

### Pruning and state caching

Without pruning, the number of abstract states to explore would be exponential in the number of branches. The verifier maintains a *state cache* (a per-instruction list of `struct bpf_verifier_state_list`). Each time it finishes verifying a join point, it adds the resulting state to the cache. When it arrives at a join point again (via a different path), it calls `states_equal()` (`kernel/bpf/states.c`):

- For scalars, the new state's bounds must be a *subset* of the cached state's bounds (i.e. the cached state is at least as constrained). If the cached state was verified safe with wider unknowns, the narrower new state is certainly safe too.
- For pointers, types and offsets must match exactly.

*Liveness* further improves pruning. The liveness pass (`kernel/bpf/liveness.c`) computes, for each instruction, which registers are *live* (subsequently read). A register that is live-dead in the cached state can be ignored in the comparison — its value doesn't matter for future safety. Kernel 7.1 replaced the previous dynamic liveness tracking with a static forward data-flow analysis, cutting verification time by ~2× for programs with complex stacks.

When a branch's new state is *subsumed* by a cached state, the branch is pruned: `do_check()` returns immediately without exploring further, because the cached proof covers the new path.

## Key Data Structures

**`struct bpf_reg_state`** (`include/linux/bpf_verifier.h`) — the per-register abstract value.
- `type` — register category enum
- `var_off` — `struct tnum {u64 value, mask}` — tnum encoding
- `umin_value` / `umax_value` / `smin_value` / `smax_value` — numeric bounds
- `id` — shared pointer origin ID
- `off` / `delta` — constant offset within the pointed-to object

**`struct bpf_verifier_state`** (`include/linux/bpf_verifier.h`) — full abstract machine state at one point.
- `regs[MAX_BPF_REG]` — array of `bpf_reg_state`
- `stack[MAX_BPF_STACK / 8]` — per-8-byte stack slot abstract states
- `active_locks` / `active_rcu_locks` — tracks held spinlocks and RCU read sections
- `curframe` — index into `frame[]` for the current function call depth

**`struct bpf_verifier_env`** — global verification state.
- `insn_state[]` / `insn_stack[]` — DFS CFG walk tracking
- `states[]` — per-instruction state caches
- `log` — `struct bpf_verifier_log` for the human-readable rejection reason

## Key Functions / Entry Points

**`bpf_check()`** (`kernel/bpf/verifier.c`) — called from `bpf_prog_load()`; orchestrates both phases and JIT invocation.

**`check_cfg()`** (`kernel/bpf/cfg.c`) — DFS CFG construction, loop detection, SCC computation.

**`do_check()`** (`kernel/bpf/verifier.c`) — main abstract interpretation loop; dispatches per-instruction handlers.

**`check_mem_access()`** — validates pointer type, computes and bounds-checks the effective address.

**`states_equal()` / `regsafe()`** (`kernel/bpf/states.c`) — pruning subsumption test.

**`compute_live_registers()`** (`kernel/bpf/liveness.c`) — static forward data-flow analysis for register liveness.

**`adjust_reg_min_max_vals()`** — transfer function for ALU operations on scalar registers.

## Important Flags & Config Options

- `CONFIG_BPF_JIT_ALWAYS_ON` — removes the interpreter entirely; forces JIT, blocking Spectre v2 interpreter gadgets.
- `BPF_UNPRIV_DEFAULT_OFF` (Kconfig) — unprivileged BPF disabled by default; most distros ship with this on.
- `bpf_attr.log_level` — 0 = no log, 1 = verifier stats, 2 = verbose per-instruction, 4 = debug.
- `net.core.bpf_jit_harden` sysctl — 1 = constant blinding for unprivileged, 2 = always.

## Interactions with Other Subsystems

- **↑ Userspace**: `BPF_PROG_LOAD` is the entry point; the verifier log is returned via the `log_buf` field of `union bpf_attr`.
- **→ [[bpf-jit-compiler]]**: Once `bpf_check()` succeeds, `bpf_prog_select_runtime()` invokes the architecture JIT. The verifier annotates programs with auxiliary data (`insn_aux_data[]`) used by the JIT for constant-blinding and instruction replacement.
- **→ [[btf-and-co-re]]**: kfunc argument type checking resolves types through BTF. The verifier fetches `btf_vmlinux` to validate pointer types passed to kfuncs.
- **→ [[bpf-program-types]]**: `verifier_ops->get_func_proto()` gates which helpers each program type may call; `is_valid_access()` gates which context fields it may read.

## Design Decisions & Tradeoffs

**Abstract interpretation over concrete testing** — A test suite can only cover paths it was designed to hit. Abstract interpretation covers all paths simultaneously, at the cost of imprecision (some safe programs are rejected because the abstract domain cannot express their safety). The tnum+interval combination strikes a balance: expressive enough to verify realistic programs, simple enough to keep verification time polynomial.

**Polynomial verification time with hard limits** — The verifier imposes a maximum instruction count (currently 1 million verified instructions) and a maximum stack depth (8 frames, relaxed for global subprogs in 7.1). These prevent DoS via exponential-blowup programs at the cost of rejecting legitimately complex programs.

**Liveness for pruning, not just optimization** — Liveness was introduced not to report unused registers but to *improve pruning*: by ignoring dead registers in state comparisons, more states become equivalent, so more branches are pruned. The 7.1 static liveness rewrite (replacing the dynamic mark-and-propagate approach with a forward data-flow analysis) halved verification time for some programs.

## How It Has Evolved

- **3.18 (2014)**: Initial verifier for eBPF; two-pass DAG + state simulation.
- **4.14 (2017)**: Pointer arithmetic tracking, tnum introduction.
- **5.3 (2019)**: Bounded loop support via trip-count analysis.
- **5.9 (2020)**: Speculative execution simulation for Spectre mitigation.
- **5.20 (2022)**: Iterator-based loop support with `bpf_iter_<type>_next()`.
- **6.4 (2023)**: Open-coded iterator protocol; verifier recognizes loop re-entry as safe.
- **7.1 (2026)**: Static stack liveness (forward data-flow); verifier.c split into cfg.c, states.c, backtrack.c, liveness.c, fixups.c.

## Further Reading

1. [A look inside the BPF verifier — LWN.net (2024)](https://lwn.net/Articles/982077/)
2. [eBPF verifier — kernel.org docs](https://www.kernel.org/doc/html/latest/bpf/verifier.html)
3. [A thorough introduction to eBPF — LWN.net (2017)](https://lwn.net/Articles/740157/)
4. [BPF and security — LWN.net (2022)](https://lwn.net/Articles/946389/)

## LKML Highlights

- **RFC: Structured verifier docs** (`20260309121033.2594457-2-bqe@google.com`): Proposes five-part formal documentation for the verifier covering abstract interpretation, value lattices, data flow transfer functions, pruning/subsumption, and advanced contexts. Alexei Starovoitov rejected it tersely ("don't waste maintainer time"), highlighting the tension between formal documentation and the verifier team's development velocity.
