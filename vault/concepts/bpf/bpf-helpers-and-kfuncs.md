---
title: "BPF Helpers and kfuncs"
category: concept
tags: [bpf, helpers, kfuncs, api, kernel-functions]
subsystem: bpf
kernel_version: "3.18"
researched: 2026-04-16
status: complete
explained: "[[bpf-helpers-and-kfuncs-explained]]"
sources:
  - https://lwn.net/Articles/856005/
  - https://lwn.net/Articles/740157/
  - https://www.kernel.org/doc/html/latest/bpf/kfuncs.html
  - https://lwn.net/Articles/921088/
---

# BPF Helpers and kfuncs

> 📘 Plain-language version: [[bpf-helpers-and-kfuncs-explained]]

## Purpose

BPF programs run in the kernel but cannot call arbitrary kernel functions: the verifier cannot track the safety of an open-ended call graph. Helpers and kfuncs are the curated, type-checked kernel APIs available to BPF programs. They provide the bridge between the isolated BPF sandbox and the rest of the kernel — for map access, timing, networking, memory, and subsystem-specific operations — while keeping the verifier's safety guarantees intact.

## Mental Model

Think of helpers as **a stable kernel library ABI, and kfuncs as a versionable plugin interface**. Helpers are frozen forever once released (like POSIX syscalls); kfuncs are stable only within a kernel version (like internal C APIs). The split allows the BPF subsystem to expose powerful kernel capabilities without locking in every function signature for eternity.

## How It Works

### Helpers

A helper is a C function in the kernel whose signature is recorded in a `struct bpf_func_proto`. This struct lists:
- `func` — the C function pointer (e.g. `bpf_map_lookup_elem`)
- `gpl_only` — whether the calling program must have a GPL-compatible license
- `ret_type` — `enum bpf_return_type`: `RET_INTEGER`, `RET_PTR_TO_MAP_VALUE_OR_NULL`, `RET_PTR_TO_SOCKET`, etc.
- `arg1_type` … `arg5_type` — per-argument constraints: `ARG_PTR_TO_MAP`, `ARG_ANYTHING`, `ARG_PTR_TO_MEM`, etc.

At program load time, each `BPF_CALL` instruction contains a helper ID from `enum bpf_func_id` (defined in `include/uapi/linux/bpf.h`). The verifier calls `prog->ops->get_func_proto(func_id, prog)` to retrieve the proto. If `get_func_proto()` returns NULL, the helper is not permitted for this program type — verification fails. If it returns a proto, the verifier:
1. Checks each argument's abstract type in `bpf_reg_state` matches the proto's constraint.
2. Updates the return register R0's type to `ret_type`.
3. Marks R1–R5 as `NOT_INIT` (helpers are not required to preserve them).

At JIT time, the `BPF_CALL` instruction is translated to a direct `callq <func_addr>` — not a syscall, not an indirect call. This is why BPF helper calls are fast: they are ordinary function calls from the JIT-generated native code into the kernel's `.text`.

Helper semantics are **permanently frozen**: once a helper is part of UAPI (`include/uapi/linux/bpf.h`), its arguments, return type, and behaviour cannot change. This has led to a proliferation of near-duplicate helpers (e.g. `bpf_perf_event_output` vs `bpf_ringbuf_output`).

Key helpers:
| Helper | Purpose |
|--------|---------|
| `bpf_map_lookup_elem(map, key)` | O(1) map lookup; returns ptr or NULL |
| `bpf_map_update_elem(map, key, val, flags)` | Insert/update map entry |
| `bpf_map_delete_elem(map, key)` | Remove map entry |
| `bpf_ktime_get_ns()` | Monotonic clock (no syscall) |
| `bpf_get_current_pid_tgid()` | Current PID/TGID for tracing |
| `bpf_get_current_task()` | Returns `struct task_struct *` (trusted) |
| `bpf_perf_event_output(ctx, map, flags, data, size)` | Write to perf ring buffer |
| `bpf_ringbuf_reserve/commit/discard` | Zero-copy ring buffer writes |
| `bpf_redirect(ifindex, flags)` | XDP/TC packet redirect |
| `bpf_tail_call(ctx, prog_array, index)` | Program-to-program trampoline (frame replace) |
| `bpf_probe_read_kernel(dst, size, src)` | Safe kernel memory read in tracing context |
| `bpf_spin_lock(lock)` / `bpf_spin_unlock(lock)` | Per-map-value spinlock |
| `bpf_skb_store_bytes(skb, off, from, len, flags)` | In-place packet edit |
| `bpf_xdp_adjust_head(xdp_md, delta)` | Move XDP packet data pointer |

### kfuncs

kfuncs ("kernel functions") extend the helper concept to arbitrary kernel internal functions. A kernel developer annotates a function with `__bpf_kfunc` and registers it in a `BTF_KFUNCS_START` / `BTF_KFUNCS_END` block, associating it with specific program types via `bpf_kfunc_set`.

Unlike helpers, kfuncs:
- Are **not in UAPI** — they are regular kernel functions exposed temporarily.
- Have **no ABI stability** between kernel versions. A kfunc can be renamed, removed, or have its signature changed in the next release.
- Are resolved by **BTF type ID**, not by a `BPF_FUNC_*` enum. The verifier finds the function in BTF, checks the caller's argument types against BTF's record of the function's parameter types, and validates ownership semantics (trusted vs. untrusted pointer, ref-counted vs. raw, etc.).
- Can return **kernel object pointers** with rich ownership models: `__kptr`, `__kptr_ref` (reference-counted), `__sz` (sizing annotation), `__k` (trusted kernel pointer).

The verifier's kfunc analysis (`check_kfunc_call()`) is significantly more complex than helper analysis because it must reason about pointer provenance through BTF type metadata. For example, a kfunc that takes a `struct task_struct *` marked with `KF_TRUSTED_ARGS` requires the verifier to prove the pointer was obtained from a trusted source (e.g. `bpf_task_acquire()`), not from an arbitrary map value.

kfuncs are the mechanism underlying:
- **BPF data structures**: red-black trees (`bpf_rbtree_*`), linked lists (`bpf_list_*`), min-heaps — all implemented as kfuncs operating on BPF-allocated nodes.
- **sched_ext helpers**: `scx_bpf_consume(dsq)`, `scx_bpf_dispatch(p, dsq, slice, enq_flags)`.
- **cpumap / devmap operations**: `bpf_cpumap_push_task()`.
- **Network subsystem kfuncs**: `bpf_sk_assign()`, `bpf_sock_destroy()`.

A kfunc that proves sufficiently stable and widely useful can be *promoted* to a helper, gaining ABI stability at the cost of a frozen signature.

### BPF global functions

Since 5.5, BPF programs can define *global* subprograms (functions with external linkage in the BPF object). These are verified independently by the verifier (once for all callers, rather than once per call site). The verifier uses the argument type annotations from BTF to determine what the callee may do with each argument. Global functions can be replaced at runtime via `BPF_F_REPLACE` without reloading the entire program.

## Key Data Structures

**`struct bpf_func_proto`** (`include/linux/bpf.h`) — helper descriptor:
- `func` — C function pointer
- `gpl_only` — license restriction
- `ret_type` — `enum bpf_return_type`
- `arg{1..5}_type` — `enum bpf_arg_type` per argument
- `arg{1..5}_btf_id` — for pointer arguments, the expected BTF type ID

**`struct bpf_kfunc_desc_tab`** — per-prog-type table of allowed kfuncs; maps `btf_id → KF_* flags`.

KF_ flags (selected):
- `KF_ACQUIRE` — kfunc returns a reference that the caller must release
- `KF_RELEASE` — kfunc releases a reference
- `KF_TRUSTED_ARGS` — all pointer arguments must be "trusted" (acquired from another kfunc or helper)
- `KF_SLEEPABLE` — kfunc may sleep; only callable from sleepable programs
- `KF_DESTRUCTIVE` — marks kfuncs like `bpf_panic()` that have irreversible effects

## Key Functions / Entry Points

**`check_helper_call()`** (`kernel/bpf/verifier.c`) — validates a `BPF_CALL` to a helper; updates register types.

**`check_kfunc_call()`** — resolves kfunc by BTF ID, validates argument types and ownership.

**`bpf_base_func_proto()`** (`kernel/bpf/helpers.c`) — returns proto for helpers available to all program types (map ops, time, tail call, etc.).

**`bpf_get_func_proto()`** — per-prog-type dispatch; e.g. XDP type returns XDP-specific helpers in addition to base set.

## Important Flags & Config Options

- `gpl_only = true` in `struct bpf_func_proto` — program must declare `char _license[] = "GPL"` or load fails.
- `KF_SLEEPABLE` — kfunc requires `BPF_F_SLEEPABLE` on the calling program.
- `CONFIG_BPF_EVENTS` — enables tracing helpers (`bpf_probe_read_*`, `bpf_perf_event_output`).

## Interactions with Other Subsystems

- **→ [[bpf-verifier]]**: Every helper/kfunc call is type-checked by the verifier before any code is JIT-compiled.
- **→ [[bpf-maps]]**: The majority of commonly-used helpers (lookup, update, delete) operate on maps.
- **→ [[net]]**: Network helpers (`bpf_redirect`, `bpf_skb_store_bytes`, `bpf_sk_assign`) manipulate SKBs and sockets.
- **→ [[scheduler]]**: sched_ext exposes scheduler operations as kfuncs (`scx_bpf_dispatch`, `scx_bpf_consume`).
- **→ [[btf-and-co-re]]**: kfunc validation is entirely BTF-driven; without `CONFIG_DEBUG_INFO_BTF` kfuncs cannot be used.

## Design Decisions & Tradeoffs

**Frozen helper ABI vs. evolving kfuncs** — Freezing helpers guarantees that programs compiled against kernel 5.x still load on 6.x. But it means the BPF subsystem cannot fix design mistakes in existing helpers. kfuncs solve this at the cost of portability: programs using kfuncs may need to be recompiled for each kernel release. CO-RE partially mitigates this for struct field accesses but not for function signature changes.

**Centralized get_func_proto vs. per-helper registration** — All helpers are centrally enumerated in `enum bpf_func_id`. This makes the UAPI surface explicit but requires kernel patches to add new helpers. kfuncs solved the discoverability problem via BTF: any annotated function is automatically discoverable by the verifier without modifying the BPF core.

**Ownership semantics via KF_ACQUIRE/RELEASE** — Without explicit ownership tracking, a BPF program could call a kfunc that returns an object, never release it, and leak kernel memory. The `KF_ACQUIRE` / `KF_RELEASE` flags tell the verifier to track the reference count, rejecting programs that return without releasing all acquired references. This is a form of resource safety that classical helpers could not express.

## How It Has Evolved

- **3.18 (2014)**: Initial helper set: map ops, socket filter, perf output.
- **4.x**: Expansion to XDP, TC, kprobe, cgroup helpers.
- **5.8 (2020)**: Ring buffer helpers (`bpf_ringbuf_reserve/commit/discard`).
- **5.13 (2021)**: kfuncs introduced with TCP CC ops (`tcp_cong_avoid_ai` etc.).
- **5.15 (2021)**: kfunc framework generalized; `KF_ACQUIRE/RELEASE/TRUSTED_ARGS` flags.
- **6.1 (2022)**: BPF data structures (rbtree, linked list) via kfuncs.
- **6.12 (2024)**: sched_ext kfuncs (`scx_bpf_*`).
- **7.1 (2026)**: `KF_IMPLICIT_ARGS` for passing struct metadata without explicit arguments (Ihor Solodrai).

## Further Reading

1. [Calling kernel functions from BPF — LWN.net (2021)](https://lwn.net/Articles/856005/)
2. [Magic kernel functions for BPF — LWN.net (2024)](https://lwn.net/Articles/1044824/)
3. [Reconsidering BPF ABI stability — LWN.net (2022)](https://lwn.net/Articles/921088/)
4. [BPF Kernel Functions (kfuncs) — kernel.org docs](https://www.kernel.org/doc/html/latest/bpf/kfuncs.html)
